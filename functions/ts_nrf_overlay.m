function [overlay_ts, fit] = ts_nrf_overlay(y_ts, nrfName, times_ms, fit_time_ms, jitter_ms)
%TS_NRF_OVERLAY  Align and fit an NRF template to a time series, returning an overlay.
%
%   [overlay_ts, fit] = TS_NRF_OVERLAY(y_ts, nrfName, times_ms, fit_time_ms, jitter_ms)
%
% Inputs (positional, required)
%   y_ts        : [n_points x 1] numeric column vector (target time series).
%                 May contain NaNs outside the search region.
%   nrfName     : string/char. Base name (e.g., 'noxious_NRF_500Hz') or full path
%                 to the NRF .mat file. The .mat must contain variables:
%                   - NRF : [L x 1] numeric vector
%                   - fs  : scalar sampling rate (Hz)
%   times_ms    : [n_points x 1] numeric column vector (milliseconds), strictly
%                 increasing and approximately uniformly sampled.
%   fit_time_ms : scalar (ms). Anchor start time for the NRF (e.g., 400).
%   jitter_ms   : scalar (ms). Half-width of the search band around the anchor.
%
% Behaviour
%   - No resampling is performed. The NRF fs must match the effective sampling
%     rate implied by times_ms (within a tight tolerance).
%   - Alignment uses Pearson's r: evaluate the correlation between the NRF and
%     each equal-length window within the jitter band; choose the lag with the
%     maximum (most positive) r. Ties within numerical tolerance are broken by
%     choosing the start closest to the anchor.
%   - A final amplitude fit is then performed on the best window using either:
%       * OLS with intercept (fitlm), or
%       * AR(1) feasible GLS (fGLS) on demeaned data (no intercept).
%   - NaN policy: if any NaN appears anywhere in the union of all candidate
%     samples in the jitter band, the function errors.
%
% Outputs
%   overlay_ts  : [n_points x 1] numeric column vector. NRF template, shifted and
%                 scaled to best fit y_ts within the jitter region, NaN-padded
%                 outside the template support so that length(overlay_ts) ==
%                 length(y_ts).
%
%   fit         : struct with provenance and fit metrics, including:
%       method          : 'ols' or 'fgls_ar1'
%       nrfFile         : full path to the NRF .mat file used
%       fs              : NRF sampling rate (Hz)
%       dt_ms           : median time step (ms)
%       anchor_ms       : fit_time_ms (for reference)
%       jitter_ms       : jitter_ms (for reference)
%       n_points        : length(y_ts)
%       nrf_length      : length(NRF) in samples
%       i0              : anchor index in y_ts (nearest to fit_time_ms)
%       s_best          : chosen start index of the NRF segment in y_ts
%       x_shift_samples : s_best - i0 (signed)
%       x_shift_ms      : same shift in ms
%       scale           : fitted NRF scale (response magnitude)
%       y_offset        : fitted vertical offset
%       stderr          : standard error of the scale parameter
%       r_max           : maximum Pearson correlation over all candidate lags
%
% Notes
%   - The function tries to locate the NRF file. If not found, it will attempt
%     to call start_simple_headless (if available) once to initialise paths,
%     then retry. If still missing, it errors with guidance.
%   - To switch between OLS and fGLS AR(1), edit the local 'fit_method' variable
%     below. The external interface is unchanged.

% -------------------------------------------------------------------------
% 0) Developer toggle: choose final fit method (NOT exposed to callers)
% -------------------------------------------------------------------------
% Allowed values:
%   'ols'       : classic ordinary least squares with intercept (fitlm)
%   'fgls_ar1'  : AR(1) feasible GLS on demeaned data (no intercept)
fit_method = 'ols';   % default; change manually to 'fgls_ar1' if desired

% -------------------------------------------------------------------------
% 1) Validate inputs
% -------------------------------------------------------------------------
if nargin ~= 5
    error('ts_nrf_overlay:NotEnoughInputs', ...
        'Provide y_ts, nrfName, times_ms, fit_time_ms, and jitter_ms.');
end

% y_ts
if ~(isnumeric(y_ts) && isvector(y_ts) && ~isempty(y_ts))
    error('ts_nrf_overlay:InvalidY', 'y_ts must be a non-empty numeric vector.');
end
y_ts = y_ts(:);  % force column
n_points = numel(y_ts);

% nrfName
if ~(ischar(nrfName) || (isstring(nrfName) && isscalar(nrfName)))
    error('ts_nrf_overlay:InvalidNRFName', ...
        'nrfName must be a character vector or scalar string.');
end
nrfName = string(nrfName);

% times_ms
if ~(isnumeric(times_ms) && isvector(times_ms) && numel(times_ms) == n_points)
    error('ts_nrf_overlay:InvalidTimes', ...
        'times_ms must be a numeric vector with the same length as y_ts.');
end
times_ms = times_ms(:);
dt = diff(times_ms);
if ~all(isfinite(times_ms)) || ~all(dt > 0)
    error('ts_nrf_overlay:TimesNotMonotonic', ...
        'times_ms must be strictly increasing and finite.');
end
dt_med = median(dt);
tol_uniform = max(1e-9, 1e-6 * dt_med);
if max(abs(dt - dt_med)) > tol_uniform
    error('ts_nrf_overlay:TimesNotUniform', ...
        'times_ms is not approximately uniform.');
end
srate_eff = 1000 / dt_med;

% fit_time_ms & jitter_ms
if ~(isscalar(fit_time_ms) && isnumeric(fit_time_ms) && isfinite(fit_time_ms))
    error('ts_nrf_overlay:InvalidAnchor', 'fit_time_ms must be a finite numeric scalar (ms).');
end
if ~(isscalar(jitter_ms) && isnumeric(jitter_ms) && isfinite(jitter_ms))
    error('ts_nrf_overlay:InvalidJitter', 'jitter_ms must be a finite numeric scalar (ms).');
end
if jitter_ms < 0
    error('ts_nrf_overlay:JitterNegative', 'jitter_ms must be >= 0.');
end

% -------------------------------------------------------------------------
% 2) Locate and load NRF template
% -------------------------------------------------------------------------
nrfFile = "";

% If a path or .mat is provided, use it as-is (append .mat if needed)
if contains(nrfName, filesep) || endsWith(nrfName, ".mat", 'IgnoreCase', true)
    candidate = char(nrfName);
    if ~endsWith(candidate, '.mat', 'IgnoreCase', true)
        candidate = [candidate '.mat'];
    end
    if exist(candidate, 'file')
        nrfFile = string(candidate);
    end
else
    % Base name only: try which
    w = which(char(nrfName + ".mat"));
    if ~isempty(w); nrfFile = string(w); end
end

% If not found, try start_simple_headless (if available), then retry
if nrfFile == ""
    if exist('start_simple_headless', 'file')
        try
            start_simple_headless('check', false);
        catch %#ok<CTCH>
            % ignore initialisation errors; we'll fail gracefully below if still not found
        end
        w = which(char(nrfName + ".mat"));
        if ~isempty(w); nrfFile = string(w); end
    end
end

if nrfFile == ""
    error('ts_nrf_overlay:NRFNotFound', ...
        'NRF "%s" not found. Ensure the NRF .mat is on the path (e.g., call start_simple_headless), or pass a full path.', nrfName);
end

S = load(nrfFile);
if ~isfield(S, 'NRF') || ~isfield(S, 'fs')
    error('ts_nrf_overlay:BadNRFFile', ...
        'NRF file must contain variables "NRF" (vector) and "fs" (Hz).');
end
NRF = S.NRF(:);
fs  = double(S.fs);
L   = numel(NRF);

if ~isnumeric(NRF) || ~isvector(NRF) || L < 2 || ~isfinite(fs) || fs <= 0
    error('ts_nrf_overlay:BadNRFVars', ...
        'NRF must be a numeric vector (length >= 2) and fs a positive finite scalar.');
end
if var(NRF) == 0
    error('ts_nrf_overlay:NRFZeroVariance', ...
        'NRF appears to have zero variance; correlation is undefined.');
end

% -------------------------------------------------------------------------
% 3) Sampling rate consistency (no resampling)
% -------------------------------------------------------------------------
tol_fs = max(1e-9, 1e-6 * fs);
if abs(fs - srate_eff) > tol_fs
    error('ts_nrf_overlay:FsMismatch', ...
        'Sampling rate mismatch: NRF fs=%.9g Hz, series rate=%.9g Hz. Resampling is not supported.', fs, srate_eff);
end

% -------------------------------------------------------------------------
% 4) Map anchor and jitter to indices, and build candidate windows
% -------------------------------------------------------------------------
% Nearest-sample anchor
[~, i0] = min(abs(times_ms - fit_time_ms));  % anchor index
J = round(jitter_ms / dt_med);               % half-width in samples (integer)
starts_raw = (i0 - J) : (i0 + J);

% Keep starts that fit fully within data bounds
starts = starts_raw(starts_raw >= 1 & starts_raw + L - 1 <= n_points);
if isempty(starts)
    error('ts_nrf_overlay:OutOfBounds', ...
        'NRF window exceeds data bounds. Adjust fit_time_ms and/or jitter_ms.');
end

% Disallow NaNs in the union of candidate samples
idx_union = starts(1):(starts(end) + L - 1);
if any(isnan(y_ts(idx_union)))
    error('ts_nrf_overlay:NaNInSearchRegion', ...
        'NaN found within the search region (union of all candidate windows).');
end

% Build candidate matrix (equal-length windows)
K = numel(starts);
IDX = starts + (0:L-1)';        % implicit expansion (L x K)
Y = y_ts(IDX);                  % (L x K), each column a candidate segment

% -------------------------------------------------------------------------
% 5) Pearson r per candidate (max positive r)
% -------------------------------------------------------------------------
r = zeros(1, K);
for k = 1:K
    r(k) = corr(Y(:,k), NRF);
end
r_max = max(r);
% Tie tolerance: absolute/relative hybrid
tol_tie = max(1e-12, 1e-9 * abs(r_max));
is_tie = (r_max - r) <= tol_tie;
tie_idx = find(is_tie);

if numel(tie_idx) > 1
    % Choose the start closest to the anchor (least absolute shift)
    [~, relmin] = min(abs(starts(tie_idx) - i0));
    k_best = tie_idx(relmin);
else
    [~, k_best] = max(r);
end
s_best = starts(k_best);

% Extract best window
y_seg = Y(:, k_best);           % [L x 1] segment of data

% -------------------------------------------------------------------------
% 6) Final amplitude fit on best window (OLS vs fGLS AR(1))
% -------------------------------------------------------------------------
switch lower(string(fit_method))
    case "ols"
        % Design matrix includes intercept explicitly; Intercept=false
        X = [ones(L,1), NRF];
        mdl = fitlm(X, y_seg, 'linear', 'Intercept', false);
        coefs = mdl.Coefficients.Estimate;     % [intercept; slope]
        ses   = mdl.Coefficients.SE;           % standard errors
        y_offset = coefs(1);
        scale    = coefs(2);
        % Standard error for the scale term (slope on NRF)
        if numel(ses) >= 2
            stderr = ses(2);
        else
            stderr = NaN;
        end

    case "fgls_ar1"
        % Demean NRF and data; no intercept in the model
        x_seg   = NRF;
        x_mean  = mean(x_seg);
        y_mean  = mean(y_seg);
        X_dm    = x_seg - x_mean;
        y_dm    = y_seg - y_mean;

        % fGLS AR(1): we assume signature [beta, stderr] = fgls(X, y, ...)
        try
            [beta_hat, stderr_all] = fgls(X_dm, y_dm, ...
                'Intercept', false, ...
                'InnovMdl', "AR", ...
                'ARLags', 1, ...
                'NumIter', 5, ...
                'Plot', "off");
        catch ME
            error('ts_nrf_overlay:FGLSFailed', ...
                'fGLS AR(1) fit failed: %s', ME.message);
        end

        % beta_hat should be scalar (one regressor); stderr_all may be scalar or vector
        if numel(beta_hat) ~= 1
            warning('ts_nrf_overlay:FGLSUnexpectedBeta', ...
                'fGLS beta_hat has length %d; using the first element.', numel(beta_hat));
        end
        scale = beta_hat(1);

        if isempty(stderr_all)
            stderr = NaN;
        else
            stderr = stderr_all(1);
        end

        % Back out an equivalent intercept on the original (non-demeaned) variables:
        % y_seg ≈ y_offset + scale * x_seg
        % with y_offset = mean(y_seg) - scale * mean(x_seg)
        y_offset = y_mean - scale * x_mean;

    otherwise
        error('ts_nrf_overlay:UnknownFitMethod', ...
            'Unknown fit_method: %s. Allowed: ''ols'' or ''fgls_ar1''.', fit_method);
end

% -------------------------------------------------------------------------
% 7) Build NaN-padded overlay time series
% -------------------------------------------------------------------------
overlay_ts = nan(n_points, 1);
overlay_ts(s_best : s_best + L - 1) = y_offset + scale * NRF;

% -------------------------------------------------------------------------
% 8) Package fit metadata
% -------------------------------------------------------------------------
x_shift_samples = s_best - i0;
x_shift_ms      = x_shift_samples * dt_med;

fit = struct();
fit.method          = char(lower(string(fit_method)));
fit.nrfFile         = char(nrfFile);
fit.fs              = fs;
fit.dt_ms           = dt_med;
fit.anchor_ms       = fit_time_ms;
fit.jitter_ms       = jitter_ms;
fit.n_points        = n_points;
fit.nrf_length      = L;
fit.i0              = i0;
fit.s_best          = s_best;
fit.x_shift_samples = x_shift_samples;
fit.x_shift_ms      = x_shift_ms;
fit.scale           = scale;
fit.y_offset        = y_offset;
fit.stderr          = stderr;
fit.r_max           = r_max;
end