function [ts_avg, info] = ts_average_NRFshifted(ts, shifts, varargin)
%TS_AVERAGE_NRFSHIFTED Align by per-series shifts, then average; optional smoothing.
%   ts_avg = TS_AVERAGE_NRFSHIFTED(ts, shifts)
%   ts_avg = TS_AVERAGE_NRFSHIFTED(ts, shifts, 'Aggregator',"mean"|"median", ...
%                                  'SmoothingWindowMs',win_ms, 'SRate',srate)
%
% Required inputs
%   ts      : [n_points x n_series] numeric matrix (time down rows). May contain NaNs.
%   shifts  : [1 x n_series] or [n_series x 1] numeric vector of integer sample shifts.
%             Sign convention (matches SIMPLE/jittercorrect):
%             • k > 0 moves the series earlier (left, advance in time).
%             • k < 0 moves the series later (right, delay in time).
%
% Name–Value pairs (optional)
%   'Aggregator'        : "mean" (default) or "median" (case-insensitive). Applied across columns with omit-NaN.
%   'SmoothingWindowMs' : scalar window length in milliseconds for Gaussian smoothing (default 0 = off).
%   'SRate'             : sampling rate in Hz (required iff SmoothingWindowMs > 0).
%
% Outputs
%   ts_avg : [n_points x 1] double vector. No printing, no side-effects.
%   info   : struct recording shifts, admitted series, pointwise contributor
%            counts, aggregator, and the realised smoothing window.
%
% Behaviour
%   • Each column is shifted by its integer 'shifts' value with non-circular, NaN padding to preserve length.
%   • Aggregation across columns is NaN-robust.
%   • Optional centred Gaussian smoothing (window converted from ms to samples); odd window length is enforced.
%   • Sign convention matches SIMPLE/jittercorrect: +k = left (earlier), −k = right (later).

% ----- minimal validation of requireds -----
if ~(isnumeric(ts) && ismatrix(ts) && ~isempty(ts))
    error('ts_average_NRFshifted:InvalidTS', ...
        'ts must be a non-empty numeric 2-D matrix [n_points x n_series].');
end
if ~isreal(ts) || any(isinf(ts(:)))
    error('ts_average_NRFshifted:InvalidTSValues', ...
        'ts must be real and may contain finite values or NaNs, but not Inf.');
end
[T, N] = size(ts);

if ~(isnumeric(shifts) && isreal(shifts) && isvector(shifts) && ~isempty(shifts))
    error('ts_average_NRFshifted:InvalidShifts', ...
        'shifts must be a non-empty numeric vector with length equal to size(ts,2).');
end
shifts = shifts(:);
if numel(shifts) ~= N
    error('ts_average_NRFshifted:ShiftsLengthMismatch', ...
        'Length of shifts (%d) must equal number of series (%d).', numel(shifts), N);
end
if any(~isfinite(shifts))
    error('ts_average_NRFshifted:NonFiniteShift', 'All shifts must be finite.');
end
if any(mod(shifts,1) ~= 0)
    error('ts_average_NRFshifted:NonIntegerShift', 'All shifts must be integer-valued samples.');
end
if any(abs(shifts) >= T)
    error('ts_average_NRFshifted:ShiftOutsideEpoch', ...
        'Every absolute shift must be smaller than the epoch length (%d samples).', T);
end

% ----- parse Name–Value options -----
p = inputParser;
p.FunctionName = 'ts_average_NRFshifted';
addParameter(p, 'Aggregator', "mean");
addParameter(p, 'SmoothingWindowMs', 0);
addParameter(p, 'SRate', []);
parse(p, varargin{:});

agg = lower(string(p.Results.Aggregator));
if ~(isscalar(agg) && (agg == "mean" || agg == "median"))
    error('ts_average_NRFshifted:InvalidAggregator', 'Aggregator must be "mean" or "median".');
end

win_ms = p.Results.SmoothingWindowMs;
if ~(isscalar(win_ms) && isnumeric(win_ms) && isreal(win_ms) && isfinite(win_ms))
    error('ts_average_NRFshifted:InvalidWindow', 'SmoothingWindowMs must be a finite numeric scalar (ms).');
end
if win_ms < 0
    error('ts_average_NRFshifted:NegativeWindow', ...
        'SmoothingWindowMs must be >= 0. Use 0 to disable smoothing.');
end

srate = p.Results.SRate;
smoothing_on = (win_ms > 0);
if smoothing_on
    if ~(isscalar(srate) && isnumeric(srate) && isreal(srate) && isfinite(srate) && srate > 0)
        error('ts_average_NRFshifted:InvalidSRate', ...
            'SRate (Hz) must be a positive finite numeric scalar when SmoothingWindowMs > 0.');
    end
end

Nwin = 0;
effective_win_ms = 0;

% ----- apply per-series shifts with NaN padding (non-circular) -----
% Sign convention matches SIMPLE/jittercorrect:
%   k > 0  => left shift (earlier):   ts_avg(t) uses ts(t + k)
%   k < 0  => right shift (later):    ts_avg(t) uses ts(t - |k|)
ts_shifted = NaN(T, N); % double; aggregation returns double; okay if ts is single
for j = 1:N
    k = shifts(j);
    if k == 0
        ts_shifted(:, j) = ts(:, j);
    elseif k > 0
        % Move earlier (left): drop first k samples, pad tail with NaNs
        if k < T
            ts_shifted(1:T-k, j) = ts(1+k:T, j);
        else
            % entire column becomes NaN (no valid overlap)
        end
    else % k < 0
        kk = -k; % abs shift
        % Move later (right): pad head with NaNs, drop last kk samples
        if kk < T
            ts_shifted(1+kk:T, j) = ts(1:T-kk, j);
        else
            % entire column becomes NaN
        end
    end
end

% ----- aggregate across columns (NaN-robust) -----
switch agg
    case "mean"
        ts_avg = mean(ts_shifted, 2, 'omitnan');
    case "median"
        ts_avg = median(ts_shifted, 2, 'omitnan');
end

% ----- optional Gaussian smoothing (post-aggregation) -----
if smoothing_on
    Nwin = round((win_ms / 1000) * srate);
    if Nwin < 1, Nwin = 1; end
    if mod(Nwin, 2) == 0, Nwin = Nwin + 1; end % force odd
    effective_win_ms = 1000 * Nwin / srate;
    ts_avg = smoothdata(ts_avg, 'gaussian', Nwin, 'omitnan');
end

% ----- precision -----
ts_avg = double(ts_avg);

% ----- Transparent method metadata -----
info = struct();
info.aggregator                    = char(agg);
info.n_input_series                = N;
info.shifts_samples                = reshape(double(shifts), 1, []);
info.n_contributors_by_time_pre_smoothing = sum(~isnan(ts_shifted), 2);
info.common_support_mask_pre_smoothing = ...
    info.n_contributors_by_time_pre_smoothing == N;
info.smoothing_requested_ms        = double(win_ms);
info.smoothing_window_samples      = double(Nwin);
info.smoothing_window_effective_ms = double(effective_win_ms);
end
