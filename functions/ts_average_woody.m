function [ts_avg, woody_shifts_samples] = ts_average_woody(ts, varargin)
%TS_AVERAGE_WOODY Woody-style iterative latency alignment and averaging.
%   [ts_avg, woody_shifts_samples] = TS_AVERAGE_WOODY(ts, ...
%       'TimesMs', times_ms, 'SRate', srate, ...
%       'ROI', [t_start_ms t_end_ms], 'MaxShiftMs', W_ms, 'Iterations', K, ...
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
%                  A post-stimulus window used only for lag estimation. Must lie within TimesMs.
%   'MaxShiftMs' : scalar >= 0, default 50. Allowed lag range is ±MaxShiftMs, converted to integer samples.
%   'Iterations' : positive integer, default 3. Fixed number of iterations; no convergence logic.
%
% Final averaging options (Name–Value)
%   'Aggregator'        : "mean" (default) or "median" (case-insensitive). Applied only to the final average.
%   'SmoothingWindowMs' : scalar >= 0, default 0 (off). If > 0, Gaussian smoothing on the final average.
%
% Outputs
%   ts_avg               : [n_points x 1] double. Final average over the full epoch using user-selected options.
%   woody_shifts_samples : [1 x n_series] double (integers). Per-epoch lag (samples) from the last iteration.
%
% Behaviour & policy
%   • Sign convention: +k moves the epoch later (to the right). -k moves earlier (left).
%   • Similarity metric: Pearson's r (corr) on the ROI only; choose the largest positive r
%     (ties → smallest |lag|, then lowest lag). If max r ≤ 0 or non-finite, use lag = 0.
%   • Iteration template: built from the (full-length) shifted epochs via ts_average_simple with
%       Aggregator = "median", SmoothingWindowMs = 50 ms (independent of user's final options).
%   • Per-iteration lag search uses the original (unshifted) epochs compared to the current template ROI.
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
[T, N] = size(ts);

% ----- Parse Name–Value inputs -----
p = inputParser;
p.FunctionName = 'ts_average_woody';

addParameter(p, 'TimesMs', []);
addParameter(p, 'SRate', []);
addParameter(p, 'ROI', [0 1000]);             % ms
addParameter(p, 'MaxShiftMs', 50);            % ms
addParameter(p, 'Iterations', 3);             % positive integer
addParameter(p, 'Aggregator', "mean");        % for final average
addParameter(p, 'SmoothingWindowMs', 0);      % for final average

parse(p, varargin{:});

times_ms = p.Results.TimesMs;
srate    = p.Results.SRate;
roi_ms   = p.Results.ROI;
W_ms     = p.Results.MaxShiftMs;
K        = p.Results.Iterations;
agg      = lower(string(p.Results.Aggregator));
win_ms   = p.Results.SmoothingWindowMs;

% ----- Validate required NVs (TimesMs, SRate) -----
if ~(isnumeric(times_ms) && isvector(times_ms) && numel(times_ms) == T)
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
if ~(isscalar(srate) && isnumeric(srate) && isfinite(srate) && srate > 0)
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
if ~(isnumeric(roi_ms) && numel(roi_ms) == 2 && all(isfinite(roi_ms)))
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
if ~(isscalar(W_ms) && isnumeric(W_ms) && isfinite(W_ms) && W_ms >= 0)
    error('ts_average_woody:InvalidMaxShiftMs', 'MaxShiftMs must be a finite scalar >= 0 (ms).');
end
L_user = round(W_ms / dt_med);          % samples (integer, may be 0)

% Iterations
if ~(isscalar(K) && isnumeric(K) && isfinite(K) && K >= 1 && mod(K,1) == 0)
    error('ts_average_woody:InvalidIterations', 'Iterations must be a positive integer.');
end

% Aggregator (final)
if ~(agg == "mean" || agg == "median")
    error('ts_average_woody:InvalidAggregator', 'Aggregator must be "mean" or "median".');
end

% SmoothingWindowMs (final)
if ~(isscalar(win_ms) && isnumeric(win_ms) && isfinite(win_ms) && win_ms >= 0)
    error('ts_average_woody:InvalidSmoothingWindow', ...
        'SmoothingWindowMs must be a finite scalar >= 0 (ms).');
end

% ----- Determine global lag bounds (keep ROI+lag in-bounds) -----
distLeft  = i1 - 1;        % samples available to shift left
distRight = T - i2;        % samples available to shift right
L_bound   = floor(min(distLeft, distRight));
L_max     = min(L_user, L_bound);
lags_all  = (-L_max : L_max).';    % column vector of candidate lags
% (If L_max == 0, only lag 0 is considered.)

% ----- Iterations -----
ts0 = ts;                             % original epochs (never altered)
shifts_prev = zeros(N,1);             % start with all zeros

for it = 1:K
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
        rVals = -inf(numel(lags_all), 1);
        for a = 1:numel(lags_all)
            lag = lags_all(a);
            idx = idxROI + lag;
            % (idx guaranteed in-bounds by global L_max)
            seg = ts0(idx, j);

            % If any NaN in the segment, treat as invalid (r = -Inf)
            if any(~isfinite(seg))
                r = -inf;
            else
                r = corr(seg, template_roi, 'Type','Pearson');
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
        else
            tol = max(1e-12, 1e-9 * abs(rmax));
            cand = find(abs(rVals - rmax) <= tol);
            if numel(cand) > 1
                [~, kmin] = min(abs(lags_all(cand)));
                bestAbs = abs(lags_all(cand(kmin)));
                cand = cand(abs(lags_all(cand)) == bestAbs);
                chosen = lags_all(cand(1));
            else
                chosen = lags_all(cand);
            end
        end
        shifts_iter(j) = chosen;
    end

    % 4) Prepare for next iteration
    shifts_prev = shifts_iter;
end

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

ts_avg = ts_average_simple(ts_final_shifted, ...
    'Aggregator', agg, ...
    'SmoothingWindowMs', win_ms, ...
    'SRate', srate);

% Ensure output is column double
ts_avg = double(ts_avg(:));
end