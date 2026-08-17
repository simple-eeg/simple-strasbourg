function RobustSlopeNorm = calc_RobustSlopeNorm(eeg, Fs, t_ms) %#ok<INUSD>
% calc_RobustSlopeNorm
% Compute a scale-normalised robust absolute linear trend (slope) over the entire epoch.
%
% Inputs
%   eeg   : 1-D epoch vector (single channel, single epoch)
%   Fs    : sampling rate (unused; included for calculator signature consistency)
%   t_ms  : time vector in ms (used as predictor for slope; must align with eeg samples)
%
% Output
%   RobustSlopeNorm : absolute robust slope of robust-normalised signal vs t_ms
%                     (normalised units per ms).
%
% Behaviour
%   - Drops non-finite samples (NaN/Inf) in eeg, and applies the same mask to t_ms.
%   - Requires at least 10 finite samples; otherwise returns NaN.
%   - Robust normalisation uses centre = median and spread = 1.4826 * MAD about median.
%   - Near-flatline epochs return 0 (interpretable as no trend).
%   - Uses robust linear regression (robustfit) to estimate slope.

% Default output
RobustSlopeNorm = NaN;

% Basic input handling
x = double(eeg(:))';
t = double(t_ms(:))';

% Require alignment before masking
if numel(t) ~= numel(x)
    return
end

% Drop non-finite samples based on eeg (and propagate to t_ms)
mask = isfinite(x) & isfinite(t);
x = x(mask);
t = t(mask);

% Minimum usable sample count
if numel(x) < 10
    return
end

% Require t to vary
if range(t) == 0
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
    RobustSlopeNorm = 0;
    return
end

% Robust normalisation
x = (x - centre) ./ robustSigma;

% Robust linear fit: x ~= b0 + b1*t
% robustfit returns [b0; b1] for one predictor
b = robustfit(t, x);
slope = b(2);

RobustSlopeNorm = abs(slope);

% Final safety
if ~isfinite(RobustSlopeNorm)
    RobustSlopeNorm = NaN;
end

end