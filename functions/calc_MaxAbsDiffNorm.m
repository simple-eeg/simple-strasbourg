function MaxAbsDiffNorm = calc_MaxAbsDiffNorm(eeg, Fs, t_ms) %#ok<INUSD>
% calc_MaxAbsDiffNorm
% Compute a scale-normalised maximum step-size metric on the entire epoch:
% max absolute first difference of a robust-normalised signal.
%
% Inputs
%   eeg   : 1-D epoch vector (single channel, single epoch)
%   Fs    : sampling rate (unused; included for calculator signature consistency)
%   t_ms  : time vector in ms (unused; included for calculator signature consistency)
%
% Output
%   MaxAbsDiffNorm : scalar max(|diff(x_norm)|), where x_norm is robust-normalised.
%
% Behaviour
%   - Drops non-finite samples (NaN/Inf).
%   - Requires at least 10 finite samples; otherwise returns NaN.
%   - Robust normalisation uses centre = median and spread = 1.4826 * MAD about median.
%   - Near-flatline epochs return 0 (interpretable as no step changes).
%     Near-flatline is defined by:
%         robustSigma <= max(sigma_abs, sigma_rel)
%       where:
%         sigma_abs = 10 * eps(max(1, abs(centre)))  (floating-point precision floor)
%         sigma_rel = 1e-6 * mad0                    (scale-adaptive floor)

% Default output
MaxAbsDiffNorm = NaN;

% Basic input handling: force row vector, double precision
x = double(eeg(:))';
x = x(isfinite(x));

% Minimum usable sample count
if numel(x) < 10
    return
end

% Robust centre and dispersion (MAD about median)
centre = median(x);
mad0   = median(abs(x - centre));          % unscaled MAD
robustSigma = 1.4826 * mad0;               % SD-like robust spread

% Scale-adaptive near-flatline rule
sigma_abs = 10 * eps(max(1, abs(centre)));
sigma_rel = 1e-6 * mad0;
sigma_thr = max(sigma_abs, sigma_rel);

if robustSigma <= sigma_thr
    MaxAbsDiffNorm = 0;
    return
end

% Robust normalisation
x = (x - centre) ./ robustSigma;

% Max absolute first difference
dx = diff(x);
MaxAbsDiffNorm = max(abs(dx));

% Final safety
if ~isfinite(MaxAbsDiffNorm)
    MaxAbsDiffNorm = NaN;
end

end