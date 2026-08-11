function [ts_avg, woody_shifts_samples, info] = ts_average_woody(ts, varargin)
%TS_AVERAGE_WOODY Woody-style iterative latency alignment and averaging.
%   [ts_avg, woody_shifts_samples] = TS_AVERAGE_WOODY(ts, ...
%       'TimesMs', times_ms, 'SRate', srate, ...
%       'ROI', [t_start_ms t_end_ms], 'MaxShiftMs', W_ms, 'MaxIterations', Kmax, ...
%       'Aggregator', "mean"|"median", 'SmoothingWindowMs', win_ms)
%
% Required positional input
%   ts      : [n_points x n_series] numeric matrix (time down rows, series across columns).
%             May contain NaNs.
%
% Required Name–Value inputs
%   'TimesMs' : [n_points x 1] numeric vector (ms), strictly increasing and ~uniform; aligned to ts.
%   'SRate'   : positive scalar sampling rate in Hz.
%
% Woody procedure options (Name–Value)
%   'ROI'        : [t_start_ms t_end_ms], default [0 1000].
%                  A post-stimulus window used only for lag estimation. Must lie within TimesMs
%                  and leave the complete requested shift margin on both sides.
%   'MaxShiftMs' : scalar >= 0, default 50. Requested symmetric shift range,
%                  converted to the nearest integer number of samples.
%   'MaxIterations' : positive integer, default 100. Maximum alignment iterations.
%                     The helper stops only at an exact applied-shift-vector fixed point,
%                     and errors on a repeated nonconsecutive state or cap exhaustion.
%
% Final averaging options (Name–Value)
%   'Aggregator'        : "mean" (default) or "median" (case-insensitive). Applied only to the final average.
%   'SmoothingWindowMs' : scalar >= 0, default 0 (off). If > 0, Gaussian smoothing on the final average.
%
% Outputs
%   ts_avg               : [n_points x 1] double. Final average over the full epoch using user-selected options.
%   woody_shifts_samples : [1 x n_series] double (integers). Per-epoch applied shift
%                           from the last iteration, where +k moves later/right.
%   info                 : struct containing realised ROI/shift geometry,
%                           iteration diagnostics, and pointwise contributor counts.
%
% Behaviour & policy
%   • Sign convention: +k moves the epoch later (to the right). -k moves earlier (left).
%   • Similarity metric: Pearson's r (corr) on the ROI only; choose the applied shift
%     with the largest positive r (ties → smallest |shift|, then lowest shift).
%     The source-window search lag is the negative of the applied shift. If max
%     r <= 0 or non-finite, use applied shift = 0.
%   • Iteration template: built from the (full-length) shifted epochs via ts_average_simple with
%       Aggregator = "median", SmoothingWindowMs = 50 ms (independent of user's final options).
%   • Per-iteration lag search uses the original (unshifted) epochs compared to the current template ROI.
%   • Convergence uses exact equality of the complete integer applied-shift vector. The
%     initial all-zero vector is state 0. No numerical or correlation tolerance is used.
%     A repeated nonconsecutive state is a cycle and no final average is accepted.
%   • The requested ROI/shift geometry must permit every symmetric candidate over
%     identical observed samples; the function errors rather than shrinking either request.
%   • Shifting is non-circular with NaN padding to preserve length.
%   • No printing, no plots, no side-effects.
%
% Dependencies
%   • Requires ts_average_simple on the MATLAB path.

% ----- Validate ts -----
if ~(isnumeric(ts) && ismatrix(ts) && ~isempty(ts))
    error('ts_average_woody:InvalidTS', ...
        'ts must be a non-empty numeric 2-D matrix [n_points x n_series].');
end
if ~isreal(ts) || any(isinf(ts(:)))
    error('ts_average_woody:InvalidTSValues', ...
        'ts must be real and may contain finite values or NaNs, but not Inf.');
end
[T, N] = size(ts);
if T < 2
    error('ts_average_woody:TooFewTimeSamples', ...
        'ts and TimesMs must contain at least two time samples.');
end

% ----- Parse Name–Value inputs -----
p = inputParser;
p.FunctionName = 'ts_average_woody';

addParameter(p, 'TimesMs', []);
addParameter(p, 'SRate', []);
addParameter(p, 'ROI', [0 1000]);             % ms
addParameter(p, 'MaxShiftMs', 50);            % ms
addParameter(p, 'MaxIterations', 100);        % positive integer safety cap
addParameter(p, 'Iterations', []);            % recognised only for an actionable migration error
addParameter(p, 'Aggregator', "mean");        % for final average
addParameter(p, 'SmoothingWindowMs', 0);      % for final average

parse(p, varargin{:});

times_ms = p.Results.TimesMs;
srate    = p.Results.SRate;
roi_ms   = p.Results.ROI;
W_ms     = p.Results.MaxShiftMs;
Kmax     = p.Results.MaxIterations;
agg      = lower(string(p.Results.Aggregator));
win_ms   = p.Results.SmoothingWindowMs;

if ~any(strcmp('Iterations', p.UsingDefaults))
    error('ts_average_woody:LegacyIterationsUnsupported', ...
        ['The legacy ''Iterations'' option specified a fixed iteration count and is no longer supported. ', ...
         'Use ''MaxIterations'' to set the safety cap for exact fixed-point convergence.']);
end

% ----- Validate required NVs (TimesMs, SRate) -----
if ~(isnumeric(times_ms) && isreal(times_ms) && isvector(times_ms) && numel(times_ms) == T)
    error('ts_average_woody:InvalidTimes', ...
        'TimesMs must be a numeric vector aligned to ts with length %d.', T);
end
times_ms = times_ms(:);
dt = diff(times_ms);
if ~all(isfinite(times_ms)) || ~all(dt > 0)
    error('ts_average_woody:TimesNotMonotonic', ...
        'TimesMs must be strictly increasing and finite.');
end
dt_med = median(dt);
tol_uniform = max(1e-9, 1e-6 * dt_med);
if max(abs(dt - dt_med)) > tol_uniform
    error('ts_average_woody:TimesNotUniform', ...
        'TimesMs is not approximately uniform.');
end
if ~(isscalar(srate) && isnumeric(srate) && isreal(srate) && isfinite(srate) && srate > 0)
    error('ts_average_woody:InvalidSRate', ...
        'SRate must be a positive finite numeric scalar (Hz).');
end
% Optional consistency check between TimesMs and SRate
srate_eff = 1000 / dt_med;
tol_fs = max(1e-9, 1e-6 * srate);
if abs(srate - srate_eff) > tol_fs
    error('ts_average_woody:SRateMismatch', ...
        'SRate (%.9g Hz) disagrees with TimesMs spacing (%.9g Hz).', srate, srate_eff);
end

% ----- Validate Woody options -----
% ROI
if ~(isnumeric(roi_ms) && isreal(roi_ms) && numel(roi_ms) == 2 && all(isfinite(roi_ms)))
    error('ts_average_woody:InvalidROI', 'ROI must be a 1x2 finite numeric vector [t_start_ms t_end_ms].');
end
roi_ms = double(roi_ms(:).'); % ensure row [1x2]
if ~(roi_ms(1) < roi_ms(2))
    error('ts_average_woody:InvalidROI', 'ROI must be strictly increasing: [t_start_ms t_end_ms] with start < end.');
end
if roi_ms(1) < times_ms(1) || roi_ms(2) > times_ms(end)
    error('ts_average_woody:ROIOutOfBounds', 'ROI must lie fully within the epoch time range.');
end
% Map ROI to nearest-sample indices
[~, i1] = min(abs(times_ms - roi_ms(1)));
[~, i2] = min(abs(times_ms - roi_ms(2)));
if i1 >= i2
    error('ts_average_woody:ROISampleDegenerate', 'ROI mapping resulted in empty/degenerate index range.');
end

% MaxShiftMs
if ~(isscalar(W_ms) && isnumeric(W_ms) && isreal(W_ms) && isfinite(W_ms) && W_ms >= 0)
    error('ts_average_woody:InvalidMaxShiftMs', 'MaxShiftMs must be a finite scalar >= 0 (ms).');
end
L_user = round(W_ms / dt_med);          % samples (integer, may be 0)
if W_ms > 0 && L_user == 0
    error('ts_average_woody:MaxShiftBelowOneSample', ...
        'MaxShiftMs=%g ms rounds to zero samples at dt=%g ms. Use 0 explicitly or request at least one sample.', ...
        W_ms, dt_med);
end

% Maximum iterations
if ~(isscalar(Kmax) && isnumeric(Kmax) && isreal(Kmax) && isfinite(Kmax) && Kmax >= 1 && mod(Kmax,1) == 0)
    error('ts_average_woody:InvalidMaxIterations', 'MaxIterations must be a positive integer.');
end

% Aggregator (final)
if ~(isscalar(agg) && (agg == "mean" || agg == "median"))
    error('ts_average_woody:InvalidAggregator', 'Aggregator must be "mean" or "median".');
end

% SmoothingWindowMs (final)
if ~(isscalar(win_ms) && isnumeric(win_ms) && isreal(win_ms) && isfinite(win_ms) && win_ms >= 0)
    error('ts_average_woody:InvalidSmoothingWindow', ...
        'SmoothingWindowMs must be a finite scalar >= 0 (ms).');
end

% ----- Require full symmetric lag support around the requested ROI -----
distLeft  = i1 - 1;        % samples available to shift left
distRight = T - i2;        % samples available to shift right
L_bound   = floor(min(distLeft, distRight));
if L_user > L_bound
    error('ts_average_woody:InsufficientROIMargin', ...
        ['ROI [%g %g] ms maps to [%g %g] ms and supports at most +/-%.9g ms ', ...
         '(%d samples), but MaxShiftMs=%g requests %d samples. Leave the full ', ...
         'requested margin on both sides of the ROI.'], ...
        roi_ms(1), roi_ms(2), times_ms(i1), times_ms(i2), ...
        L_bound * dt_med, L_bound, W_ms, L_user);
end
L_max = L_user;
applied_shifts_all = (-L_max : L_max).';

% ----- Iterations -----
ts0 = ts;                             % original epochs (never altered)
shifts_prev = zeros(N,1);             % start with all zeros
shift_history = zeros(Kmax, N);       % updated states S1..SK
shift_state_history = zeros(Kmax + 1, N); % includes initial state S0
rmax_history = nan(Kmax, N);
no_positive_history = false(Kmax, N);
iterations_executed = 0;
converged = false;
termination_reason = '';

for it = 1:Kmax
    % 1) Build template from shifted epochs (full-length), using fixed internal policy
    ts_shifted = NaN(T, N, 'like', double(ts0));  % store as double for averaging
    for j = 1:N
        k = shifts_prev(j);
        if k == 0
            ts_shifted(:, j) = ts0(:, j);
        elseif k > 0
            if k < T
                ts_shifted(1+k:T, j) = ts0(1:T-k, j);
            else
                % fully NaN column (already NaN)
            end
        else % k < 0
            kk = -k;
            if kk < T
                ts_shifted(1:T-kk, j) = ts0(1+kk:T, j);
            else
                % fully NaN column
            end
        end
    end

    template_full = ts_average_simple(ts_shifted, ...
        'Aggregator', "median", ...
        'SmoothingWindowMs', 50, ...
        'SRate', srate);

    % 2) Crop template to ROI
    template_roi = template_full(i1:i2);
    if any(~isfinite(template_roi))
        error('ts_average_woody:TemplateNaN', ...
            'Template ROI contains non-finite values; cannot compute correlations.');
    end
    if std(template_roi) == 0
        error('ts_average_woody:TemplateZeroVariance', ...
            'Template ROI appears to have zero variance; correlation is undefined.');
    end

    % Precompute ROI index vector once
    idxROI = (i1:i2).';          % column vector of indices in ROI
    Lroi   = numel(idxROI);

    % 3) Lag search per epoch using ORIGINAL epochs (ts0)
    shifts_iter = zeros(N,1);
    for j = 1:N
        % Evaluate Pearson r for each candidate lag
        rVals = -inf(numel(applied_shifts_all), 1);
        rVals_raw = nan(numel(applied_shifts_all), 1);
        for a = 1:numel(applied_shifts_all)
            applied_shift = applied_shifts_all(a);
            % Applying +k moves the waveform later/right, so the samples
            % visible at the template ROI come from idxROI-k in the source.
            idx = idxROI - applied_shift;
            % (idx guaranteed in-bounds by global L_max)
            seg = ts0(idx, j);

            % If any NaN in the segment, treat as invalid (r = -Inf)
            if any(~isfinite(seg))
                r = -inf;
            else
                r = corr(seg, template_roi, 'Type','Pearson');
                rVals_raw(a) = r;
                if ~(isfinite(r) && r > 0)
                    r = -inf;  % only positive r are considered; non-positive -> -Inf
                end
            end
            rVals(a) = r;
        end

        % Choose the lag with largest positive r (ties: smallest |lag|, then lowest lag)
        rmax = max(rVals);
        if ~isfinite(rmax) || rmax <= 0
            chosen = 0; % no positive correlation found
            no_positive_history(it, j) = true;
        else
            tol = max(1e-12, 1e-9 * abs(rmax));
            cand = find(abs(rVals - rmax) <= tol);
            if numel(cand) > 1
                [~, kmin] = min(abs(applied_shifts_all(cand)));
                bestAbs = abs(applied_shifts_all(cand(kmin)));
                cand = cand(abs(applied_shifts_all(cand)) == bestAbs);
                chosen = applied_shifts_all(cand(1));
            else
                chosen = applied_shifts_all(cand);
            end
        end
        shifts_iter(j) = chosen;
        finite_raw = rVals_raw(isfinite(rVals_raw));
        if ~isempty(finite_raw)
            rmax_history(it, j) = max(finite_raw);
        end
    end

    % 4) Prepare for next iteration
    shift_history(it, :) = shifts_iter.';
    shift_state_history(it + 1, :) = shifts_iter.';
    iterations_executed = it;

    changed_by_item = shifts_iter ~= shifts_prev;
    changed_count = sum(changed_by_item);
    max_abs_change = max(abs(double(shifts_iter) - double(shifts_prev)));

    % Exact fixed point: the current complete state equals its predecessor.
    if isequal(shifts_iter, shifts_prev)
        converged = true;
        termination_reason = 'fixed_point';
        shifts_prev = shifts_iter;
        break;
    end

    % A match to any earlier nonconsecutive state is a deterministic cycle.
    matched_row = [];
    if it >= 2
        matched_row = find(all(shift_state_history(1:it-1, :) == shifts_iter.', 2), 1, 'first');
    end
    if ~isempty(matched_row)
        matched_state_iteration = matched_row - 1; % initial all-zero state is iteration 0
        cycle_length = it - matched_state_iteration;
        error('ts_average_woody:CycleDetected', ...
            ['Woody alignment entered a repeated shift-state cycle at iteration %d: ', ...
             'the state matches iteration %d (cycle length %d). Relative to iteration %d, ', ...
             '%d/%d item shifts changed and the largest absolute change was %d samples. ', ...
             'No Woody average was accepted.'], ...
            it, matched_state_iteration, cycle_length, it-1, changed_count, N, ...
            round(max_abs_change));
    end

    % The maximum is a safety cap, never an accepted unconverged result.
    if it == Kmax
        error('ts_average_woody:MaximumIterationsReached', ...
            ['Woody alignment reached MaxIterations=%d without an exact fixed point. ', ...
             'On the final update, %d/%d item shifts changed and the largest absolute ', ...
             'change was %d samples. No Woody average was accepted.'], ...
            Kmax, changed_count, N, round(max_abs_change));
    end

    shifts_prev = shifts_iter;
end

if ~converged
    error('ts_average_woody:InternalConvergenceState', ...
        'Woody alignment ended without a fixed point or a registered failure. No Woody average was accepted.');
end

% Retain only the states and diagnostics that were actually executed.
shift_history = shift_history(1:iterations_executed, :);
shift_state_history = shift_state_history(1:iterations_executed + 1, :);
rmax_history = rmax_history(1:iterations_executed, :);
no_positive_history = no_positive_history(1:iterations_executed, :);

% ----- Final application of lags to ORIGINAL epochs; then final average -----
woody_shifts_samples = reshape(shifts_prev, 1, []);  % row vector

ts_final_shifted = NaN(T, N, 'like', double(ts0));
for j = 1:N
    k = shifts_prev(j);
    if k == 0
        ts_final_shifted(:, j) = ts0(:, j);
    elseif k > 0
        if k < T
            ts_final_shifted(1+k:T, j) = ts0(1:T-k, j);
        else
            % fully NaN column
        end
    else % k < 0
        kk = -k;
        if kk < T
            ts_final_shifted(1:T-kk, j) = ts0(1+kk:T, j);
        else
            % fully NaN column
        end
    end
end

[ts_avg, final_info] = ts_average_simple(ts_final_shifted, ...
    'Aggregator', agg, ...
    'SmoothingWindowMs', win_ms, ...
    'SRate', srate);

% Ensure output is column double
ts_avg = double(ts_avg(:));

% ----- Transparent method and iteration metadata -----
info = struct();
info.roi_requested_ms              = roi_ms;
info.roi_realised_ms               = [times_ms(i1), times_ms(i2)];
info.roi_sample_indices            = [i1, i2];
info.max_shift_requested_ms        = double(W_ms);
info.max_shift_samples             = double(L_max);
info.max_shift_realised_ms         = double(L_max * dt_med);
info.applied_shift_candidates      = reshape(double(applied_shifts_all), 1, []);
info.max_iterations_requested      = double(Kmax);
info.iterations_executed           = double(iterations_executed);
info.converged                     = converged;
info.termination_reason            = termination_reason;
info.fixed_point_iteration         = double(iterations_executed);
info.applied_shift_history_samples = double(shift_history);
info.applied_shift_state_history_samples = double(shift_state_history);
info.shift_state_iteration_numbers = reshape(double(0:iterations_executed), [], 1);
info.source_window_lag_history_samples = -double(shift_history);
info.rmax_history                  = double(rmax_history);
info.no_positive_history           = no_positive_history;
info.boundary_hit_history          = abs(shift_history) == L_max & L_max > 0;
info.final_shifts_samples          = woody_shifts_samples;
info.final_boundary_hit_count      = sum(abs(woody_shifts_samples) == L_max & L_max > 0);
info.final_no_positive_count       = sum(no_positive_history(end, :));
info.final_iteration_changed_by_item = ...
    shift_state_history(end, :) ~= shift_state_history(end-1, :);
info.final_iteration_stable       = ~any(info.final_iteration_changed_by_item);
info.final_iteration_changed_count = sum(info.final_iteration_changed_by_item);
info.final_iteration_max_abs_change_samples = max(abs( ...
    double(shift_state_history(end, :)) - double(shift_state_history(end-1, :))));
info.n_input_series                = N;
info.n_contributors_by_time_pre_smoothing = final_info.n_contributors_by_time_pre_smoothing;
info.common_support_mask_pre_smoothing = final_info.common_support_mask_pre_smoothing;
info.aggregator                    = final_info.aggregator;
info.smoothing_requested_ms        = final_info.smoothing_requested_ms;
info.smoothing_window_samples      = final_info.smoothing_window_samples;
info.smoothing_window_effective_ms = final_info.smoothing_window_effective_ms;
end
