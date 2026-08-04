function ts_avg = ts_average_simple(ts, varargin)
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
% Output
%   ts_avg              : [n_points x 1] double vector. No printing, no side-effects.
%
% Notes
%   - If smoothing is enabled, window length in samples N = round(SmoothingWindowMs/1000 * SRate),
%     then forced to be odd (if even, N = N + 1). NaNs are omitted in both aggregation and smoothing.

% ----- Validate required positional -----
if ~(isnumeric(ts) && ismatrix(ts) && ~isempty(ts))
    error('ts_average_simple:InvalidTS', ...
        'ts must be a non-empty numeric 2-D matrix [n_points x n_series].');
end

% ----- Parse Name–Value options -----
p = inputParser;
p.FunctionName = 'ts_average_simple';
addParameter(p, 'Aggregator', "mean");
addParameter(p, 'SmoothingWindowMs', 0);
addParameter(p, 'SRate', []);
parse(p, varargin{:});

agg = lower(string(p.Results.Aggregator));
if ~(agg == "mean" || agg == "median")
    error('ts_average_simple:InvalidAggregator', 'Aggregator must be "mean" or "median".');
end

win_ms = p.Results.SmoothingWindowMs;
if isempty(win_ms), win_ms = 0; end
if ~(isscalar(win_ms) && isnumeric(win_ms) && isfinite(win_ms))
    error('ts_average_simple:InvalidWindow', 'SmoothingWindowMs must be a finite numeric scalar (ms).');
end
if win_ms < 0
    error('ts_average_simple:NegativeWindow', ...
        'SmoothingWindowMs must be >= 0. Use 0 to disable smoothing.');
end

srate = p.Results.SRate;
smoothing_on = (win_ms > 0);
if smoothing_on
    if ~(isscalar(srate) && isnumeric(srate) && isfinite(srate) && srate > 0)
        error('ts_average_simple:InvalidSRate', ...
            'SRate (Hz) must be a positive finite numeric scalar when SmoothingWindowMs > 0.');
    end
end

% ----- Aggregate across columns (NaN-robust) -----
switch agg
    case "mean"
        ts_avg = mean(ts, 2, 'omitnan');
    case "median"
        ts_avg = median(ts, 2, 'omitnan');
end

% ----- Optional Gaussian smoothing via smoothdata -----
if smoothing_on
    N = round((win_ms / 1000) * srate);
    if N < 1, N = 1; end
    if mod(N, 2) == 0, N = N + 1; end  % force odd for symmetry
    ts_avg = smoothdata(ts_avg, 'gaussian', N, 'omitnan');
end

% ----- Precision -----
ts_avg = double(ts_avg);
end