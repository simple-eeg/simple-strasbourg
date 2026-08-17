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
%   - Non-finite policy: if any NaN or Inf appears anywhere in the union of
%     all candidate samples in the jitter band, the function errors.
%   - Every requested jitter candidate must contain the complete NRF. If the
%     epoch cannot support the full requested search, the function errors
%     before alignment or amplitude fitting; it never clips the search range
%     or fits a partial template.
%
% Outputs
%   overlay_ts  : [n_points x 1] numeric column vector. NRF template, shifted and
%                 scaled to best fit y_ts within the jitter region, NaN-padded
%                 outside the template support so that length(overlay_ts) ==
%                 length(y_ts).
%
%   fit         : struct with provenance and fit metrics, including:
%       method          : 'ols' or 'fgls_ar1'
%       nrfName         : validated logical NRF template basename
%       nrfFile         : full path to the NRF .mat file used
%       fs              : NRF sampling rate (Hz)
%       dt_ms           : median time step (ms)
%       anchor_ms       : fit_time_ms (for reference)
%       anchor_realised_ms : nearest sampled anchor time actually used
%       jitter_ms       : jitter_ms (for reference)
%       support_policy  : 'full_template_all_requested_shifts'
%       full_template_required / partial_template_support_used : support flags
%       requested_shift_samples / requested_shift_ms : requested search range
%       realised_shift_samples / realised_shift_ms   : evaluated search range
%       search_was_clipped : always false for an accepted fit
%       n_candidate_windows : number of complete NRF windows evaluated
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
%   - Logical basenames resolve only against this repository's NRFs folder.
%     Explicit template paths remain supported. Ambient MATLAB-path lookup is
%     deliberately not used.
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
if ~isreal(y_ts) || any(isinf(y_ts))
    error('ts_nrf_overlay:InvalidYValues', ...
        'y_ts must be real and may contain finite values or NaNs, but not Inf.');
end
n_points = numel(y_ts);
if n_points < 2
    error('ts_nrf_overlay:InvalidY', 'y_ts must contain at least two samples.');
end

% nrfName
if ~(ischar(nrfName) || (isstring(nrfName) && isscalar(nrfName)))
    error('ts_nrf_overlay:InvalidNRFName', ...
        'nrfName must be a character vector or scalar string.');
end
nrfName = string(nrfName);
if ismissing(nrfName) || strlength(strtrim(nrfName)) == 0
    error('ts_nrf_overlay:InvalidNRFName', 'nrfName must be non-empty.');
end
nrfName = strtrim(nrfName);

% times_ms
if ~(isnumeric(times_ms) && isreal(times_ms) && isvector(times_ms) && numel(times_ms) == n_points)
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
if ~(isscalar(fit_time_ms) && isnumeric(fit_time_ms) && isreal(fit_time_ms) && isfinite(fit_time_ms))
    error('ts_nrf_overlay:InvalidAnchor', 'fit_time_ms must be a finite numeric scalar (ms).');
end
if ~(isscalar(jitter_ms) && isnumeric(jitter_ms) && isreal(jitter_ms) && isfinite(jitter_ms))
    error('ts_nrf_overlay:InvalidJitter', 'jitter_ms must be a finite numeric scalar (ms).');
end
if jitter_ms < 0
    error('ts_nrf_overlay:JitterNegative', 'jitter_ms must be >= 0.');
end

% -------------------------------------------------------------------------
% 2) Locate and load NRF template
% -------------------------------------------------------------------------
functionsFolder = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(functionsFolder);
[logicalNRFName, nrfFile] = NRFUtils.resolveTemplateFile(nrfName, repositoryRoot);

S = load(nrfFile);
if ~isfield(S, 'NRF') || ~isfield(S, 'fs')
    error('ts_nrf_overlay:BadNRFFile', ...
        'NRF file must contain variables "NRF" (vector) and "fs" (Hz).');
end
if ~(isnumeric(S.NRF) && isreal(S.NRF) && isvector(S.NRF) && numel(S.NRF) >= 2) || ...
        ~(isnumeric(S.fs) && isreal(S.fs) && isscalar(S.fs))
    error('ts_nrf_overlay:BadNRFVars', ...
        'NRF must be a real numeric vector (length >= 2) and fs a real numeric scalar.');
end
NRF = S.NRF(:);
fs  = double(S.fs);
L   = numel(NRF);

if ~isfinite(fs) || fs <= 0
    error('ts_nrf_overlay:BadNRFVars', ...
        'NRF must be a numeric vector (length >= 2) and fs a positive finite scalar.');
end
if ~isreal(NRF) || any(~isfinite(NRF))
    error('ts_nrf_overlay:BadNRFValues', ...
        'NRF must contain only real, finite values.');
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

% Require the complete NRF at every requested start. Do not silently narrow
% the requested jitter range or compare partial templates.
valid_start_min = 1;
valid_start_max = n_points - L + 1;
requested_shift_samples = [starts_raw(1) - i0, starts_raw(end) - i0];

if valid_start_max < valid_start_min
    error('ts_nrf_overlay:FullTemplateSearchOutOfBounds', ...
        ['Full-template support is required for every requested shift, but ', ...
         'the %d-sample NRF is longer than the %d-sample epoch [%.9g %.9g] ms. ', ...
         'Use a shorter NRF or extend the epoch. No alignment or amplitude ', ...
         'fit was performed.'], ...
        L, n_points, times_ms(1), times_ms(end));
end

supported_shift_samples = [valid_start_min - i0, valid_start_max - i0];
if starts_raw(1) < valid_start_min || starts_raw(end) > valid_start_max
    error('ts_nrf_overlay:FullTemplateSearchOutOfBounds', ...
        ['Full-template support is required for every requested shift. ', ...
         'Around requested anchor %.9g ms (nearest sample %.9g ms), shifts ', ...
         '[%d %d] samples ([%.9g %.9g] ms) were requested, but the ', ...
         '%d-sample NRF within epoch [%.9g %.9g] ms supports only shifts ', ...
         '[%d %d] samples ([%.9g %.9g] ms). Change the anchor, reduce ', ...
         'jitter, extend the epoch, or remove this overlay from the active ', ...
         'compute list. No alignment or amplitude fit was performed.'], ...
        fit_time_ms, times_ms(i0), ...
        requested_shift_samples(1), requested_shift_samples(2), ...
        requested_shift_samples(1) * dt_med, ...
        requested_shift_samples(2) * dt_med, ...
        L, times_ms(1), times_ms(end), ...
        supported_shift_samples(1), supported_shift_samples(2), ...
        supported_shift_samples(1) * dt_med, ...
        supported_shift_samples(2) * dt_med);
end

starts = starts_raw;
search_was_clipped = false;

% Disallow non-finite values in the union of candidate samples
idx_union = starts(1):(starts(end) + L - 1);
if any(~isfinite(y_ts(idx_union)))
    error('ts_nrf_overlay:NonFiniteSearchRegion', ...
        'A non-finite value was found within the union of candidate windows.');
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
finite_r = isfinite(r);
if ~any(finite_r)
    error('ts_nrf_overlay:NoFiniteCorrelation', ...
        'No candidate NRF window produced a finite Pearson correlation.');
end
r_for_selection = r;
r_for_selection(~finite_r) = -Inf;
r_max = max(r_for_selection);
% Tie tolerance: absolute/relative hybrid
tol_tie = max(1e-12, 1e-9 * abs(r_max));
is_tie = finite_r & ((r_max - r_for_selection) <= tol_tie);
tie_idx = find(is_tie);

if numel(tie_idx) > 1
    % Choose the start closest to the anchor (least absolute shift)
    [~, relmin] = min(abs(starts(tie_idx) - i0));
    k_best = tie_idx(relmin);
else
    [~, k_best] = max(r_for_selection);
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
fit.nrfName         = logicalNRFName;
fit.nrfFile         = nrfFile;
fit.fs              = fs;
fit.dt_ms           = dt_med;
fit.anchor_ms       = fit_time_ms;
fit.anchor_realised_ms = times_ms(i0);
fit.jitter_ms       = jitter_ms;
fit.support_policy  = 'full_template_all_requested_shifts';
fit.full_template_required = true;
fit.partial_template_support_used = false;
fit.requested_shift_samples = [starts_raw(1) - i0, starts_raw(end) - i0];
fit.requested_shift_ms      = fit.requested_shift_samples * dt_med;
fit.realised_shift_samples  = [starts(1) - i0, starts(end) - i0];
fit.realised_shift_ms       = fit.realised_shift_samples * dt_med;
fit.search_was_clipped      = search_was_clipped;
fit.n_candidate_windows     = K;
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
