function AutoCorrLag1Pos = calc_AutoCorrLag1Pos(eeg, Fs, t_ms) %#ok<INUSD>
% calc_AutoCorrLag1Pos
% Compute lag-1 autocorrelation of a robust-normalised signal over the entire epoch.
%
% Inputs
%   eeg   : 1-D epoch vector (single channel, single epoch)
%   Fs    : sampling rate (unused; included for calculator signature consistency)
%   t_ms  : time vector in ms (unused; included for calculator signature consistency)
%
% Output
%   AutoCorrLag1Pos : scalar Fisher transform atanh(r), where r is the
%                     Pearson correlation between x_norm(t) and x_norm(t+1).
%
% Behaviour
%   - Drops non-finite samples (NaN/Inf).
%   - Requires at least 10 finite samples; otherwise returns NaN.
%   - Robust normalisation uses centre = median and spread = 1.4826 * MAD about median.
%   - Near-flatline epochs return NaN (autocorrelation undefined for constant signals).

% Default output
AutoCorrLag1Pos = NaN;

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
    return
end

% Robust normalisation
x = (x - centre) ./ robustSigma;

% Lag-1 autocorrelation (Pearson correlation)
x0 = x(1:end-1);
x1 = x(2:end);

r = corr(x0', x1');
AutoCorrLag1Pos = atanh(r);

% Final safety
if ~isfinite(AutoCorrLag1Pos)
    AutoCorrLag1Pos = NaN;
end

end
