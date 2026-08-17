% calc_maxAbsBaseline() - Max absolute amplitude in baseline window (t_ms < 0).
%
% Usage:
%   >> out = calc_maxAbsBaseline(eeg, Fs, t_ms)
%
% Inputs
%   eeg   - [numeric] 1D epoch time series (single channel, single epoch)
%   Fs    - [numeric] sampling rate (Hz) (unused; kept for a consistent signature)
%   t_ms  - [numeric] time vector (ms), same length as eeg
%
% Outputs
%   out   - scalar >= 0, or NaN if baseline window empty / all-NaN

function out = calc_maxAbsBaseline(eeg, Fs, t_ms) %#ok<INUSD>

% Force row vectors (lightweight, no heavy validation)
eeg  = double(eeg(:)');
t_ms = double(t_ms(:)');

% Guard: time vector must align with eeg samples
if numel(t_ms) ~= numel(eeg)
    out = NaN;
    return;
end

% Select baseline samples
mask = (t_ms < 0);
if ~any(mask)
    out = NaN;
    return;
end

x = eeg(mask);

% Ignore NaNs (and Infs, for safety)
x = x(isfinite(x));
if isempty(x)
    out = NaN;
    return;
end

out = max(abs(x));

end