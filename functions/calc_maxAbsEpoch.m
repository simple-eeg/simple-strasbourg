% calc_maxAbsEpoch() - Max absolute amplitude over the entire epoch.
%
% Usage:
%   >> out = calc_maxAbsEpoch(eeg, Fs, t_ms)
%
% Inputs
%   eeg   - [numeric] 1D epoch time series (single channel, single epoch)
%   Fs    - [numeric] sampling rate (Hz) (unused; kept for a consistent signature)
%   t_ms  - [numeric] time vector (ms) (unused; kept for a consistent signature)
%
% Outputs
%   maxAbsEpoch   - scalar >= 0, or NaN if eeg empty / all-NaN

function maxAbsEpoch = calc_maxAbsEpoch(eeg, Fs, t_ms) %#ok<INUSD>

% Force row vector (lightweight, no heavy validation)
eeg = double(eeg(:)');

% Ignore NaNs (and Infs, for safety)
x = eeg(isfinite(eeg));
if isempty(x)
    maxAbsEpoch = NaN;
    return;
end

maxAbsEpoch = max(abs(x));

end