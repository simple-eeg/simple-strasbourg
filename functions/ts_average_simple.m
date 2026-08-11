function [ts_avg, info] = ts_average_simple(ts, varargin)
%TS_AVERAGE_SIMPLE Group average with optional Gaussian smoothing (Name–Value API).
%   ts_avg = TS_AVERAGE_SIMPLE(ts)
%   ts_avg = TS_AVERAGE_SIMPLE(ts, 'Aggregator',"mean"|"median", ...
%                                'SmoothingWindowMs',win_ms, 'SRate',srate)
%
% Required positional input
%   ts                  : [n_points x n_series] numeric matrix (time down rows). May contain NaNs.
%
% Name–Value pairs (all optional)
%   'Aggregator'        : "mean" (default) or "median" (case-insensitive).
%                         Applied across columns with omit-NaN.
%   'SmoothingWindowMs' : scalar window length in milliseconds for Gaussian smoothing (default 0 = off).
%   'SRate'             : sampling rate in Hz (required iff SmoothingWindowMs > 0).
%
% Outputs
%   ts_avg              : [n_points x 1] double vector. No printing, no side-effects.
%   info                : struct recording the admitted series count, pointwise
%                         contributor counts, aggregator, and realised smoothing window.
%
% Notes
%   - If smoothing is enabled, window length in samples N = round(SmoothingWindowMs/1000 * SRate),
%     then forced to be odd (if even, N = N + 1). NaNs are omitted in both aggregation and smoothing.

% ----- Validate required positional -----
if ~(isnumeric(ts) && ismatrix(ts) && ~isempty(ts))
    error('ts_average_simple:InvalidTS', ...
        'ts must be a non-empty numeric 2-D matrix [n_points x n_series].');
end
if ~isreal(ts) || any(isinf(ts(:)))
    error('ts_average_simple:InvalidTSValues', ...
        'ts must be real and may contain finite values or NaNs, but not Inf.');
end

% ----- Parse Name–Value options -----
p = inputParser;
p.FunctionName = 'ts_average_simple';
addParameter(p, 'Aggregator', "mean");
addParameter(p, 'SmoothingWindowMs', 0);
addParameter(p, 'SRate', []);
parse(p, varargin{:});

agg = lower(string(p.Results.Aggregator));
if ~(isscalar(agg) && (agg == "mean" || agg == "median"))
    error('ts_average_simple:InvalidAggregator', 'Aggregator must be "mean" or "median".');
end

win_ms = p.Results.SmoothingWindowMs;
if isempty(win_ms), win_ms = 0; end
if ~(isscalar(win_ms) && isnumeric(win_ms) && isreal(win_ms) && isfinite(win_ms))
    error('ts_average_simple:InvalidWindow', 'SmoothingWindowMs must be a finite numeric scalar (ms).');
end
if win_ms < 0
    error('ts_average_simple:NegativeWindow', ...
        'SmoothingWindowMs must be >= 0. Use 0 to disable smoothing.');
end

srate = p.Results.SRate;
smoothing_on = (win_ms > 0);
if smoothing_on
    if ~(isscalar(srate) && isnumeric(srate) && isreal(srate) && isfinite(srate) && srate > 0)
        error('ts_average_simple:InvalidSRate', ...
            'SRate (Hz) must be a positive finite numeric scalar when SmoothingWindowMs > 0.');
    end
end

Nwin = 0;
effective_win_ms = 0;

% ----- Aggregate across columns (NaN-robust) -----
switch agg
    case "mean"
        ts_avg = mean(ts, 2, 'omitnan');
    case "median"
        ts_avg = median(ts, 2, 'omitnan');
end

% ----- Optional Gaussian smoothing via smoothdata -----
if smoothing_on
    Nwin = round((win_ms / 1000) * srate);
    if Nwin < 1, Nwin = 1; end
    if mod(Nwin, 2) == 0, Nwin = Nwin + 1; end  % force odd for symmetry
    effective_win_ms = 1000 * Nwin / srate;
    ts_avg = smoothdata(ts_avg, 'gaussian', Nwin, 'omitnan');
end

% ----- Precision -----
ts_avg = double(ts_avg);

% ----- Transparent method metadata -----
info = struct();
info.aggregator                    = char(agg);
info.n_input_series                = size(ts, 2);
info.n_contributors_by_time_pre_smoothing = sum(~isnan(ts), 2);
info.common_support_mask_pre_smoothing = ...
    info.n_contributors_by_time_pre_smoothing == info.n_input_series;
info.smoothing_requested_ms        = double(win_ms);
info.smoothing_window_samples      = double(Nwin);
info.smoothing_window_effective_ms = double(effective_win_ms);
end
