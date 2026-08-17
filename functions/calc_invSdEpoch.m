function out = calc_invSdEpoch(eeg, Fs, t_ms) %#ok<INUSD>
% calc_invSdEpoch() - Inverse of population standard deviation for entire epoch
% (1 / max(sd, sdFloorEff)), where sdFloorEff is scale-adaptive.
%
% Usage:
%   >> out = calc_invSdEpoch(eeg, Fs, t_ms)
%
% Inputs
%   eeg   - [numeric] 1D epoch time series (single channel, single epoch)
%   Fs    - [numeric] sampling rate (Hz) (unused; kept for a consistent signature)
%   t_ms  - [numeric] time vector (ms) (unused; kept for a consistent signature)
%
% Outputs
%   out   - scalar >= 0 and finite (due to flooring), or NaN if no finite samples

% Force row vector (lightweight)
x = double(eeg(:)');

% Ignore NaNs (and Infs, for safety)
x = x(isfinite(x));
if isempty(x)
    out = NaN;
    return;
end

% Population standard deviation (normalised by N)
sd = sqrt(var(x, 1));

% ---- Scale-adaptive SD floor (aligned with Norm-metric conventions) ----
centre = median(x);
mad0   = median(abs(x - centre));          % unscaled MAD

sigma_abs = 10 * eps(max(1, abs(centre))); % floating-point precision floor
sigma_rel = 1e-6 * mad0;                   % scale-adaptive floor

sdFloorEff = max(sigma_abs, sigma_rel);
% -----------------------------------------------------------------------

% Floor to avoid Inf when sd is 0 (or extremely small)
sdEff = max(sd, sdFloorEff);

out = 1 / sdEff;

end
