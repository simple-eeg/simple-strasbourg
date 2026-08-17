function KatzFDNorm = calc_KatzFDNorm(eeg, Fs, t_ms) %#ok<INUSD>
% calc_KatzFDNorm
% Compute Katz Fractal Dimension (KFD) on the entire epoch after robust normalisation.
%
% Inputs
%   eeg   : 1-D epoch vector (single channel, single epoch)
%   Fs    : sampling rate (unused; included for calculator signature consistency)
%   t_ms  : time vector in ms (unused; included for calculator signature consistency)
%
% Output
%   KatzFDNorm : scalar Katz FD computed on robust-normalised signal.
%
% Behaviour
%   - Drops non-finite samples (NaN/Inf).
%   - Requires at least 10 finite samples; otherwise returns NaN.
%   - Robust normalisation uses centre = median and spread = 1.4826 * MAD about median.
%   - Near-flatline epochs return 1 (interpretable as straight-line/flatline-like).
%     Near-flatline is defined by:
%         robustSigma <= max(sigma_abs, sigma_rel)
%       where:
%         sigma_abs = 10 * eps(max(1, abs(centre)))  (floating-point precision floor)
%         sigma_rel = 1e-6 * mad0                    (scale-adaptive floor)
%   - Katz FD uses Euclidean geometry with unit step in sample index.

% Default output
KatzFDNorm = NaN;

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
    KatzFDNorm = 1;
    return
end

% Robust normalisation
x = (x - centre) ./ robustSigma;

% Katz FD computation on normalised series
N = numel(x);
n = N - 1;
if n <= 0
    return
end

% Curve length L: sum of Euclidean distances between successive points
dx = diff(x);
L = sum(sqrt(1 + dx.^2));

% Diameter d: maximum distance from first point to any later point
idx = 2:N;
dists = sqrt((1 - idx).^2 + (x(1) - x(idx)).^2);
d = max(dists);

% Safety checks
if ~(isfinite(L) && isfinite(d)) || L <= 0 || d <= 0
    return
end

% Katz FD formula
KatzFDNorm = log10(n) / (log10(n) + log10(d / L));

% Final safety
if ~isfinite(KatzFDNorm)
    KatzFDNorm = NaN;
end

end