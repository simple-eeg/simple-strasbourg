% calc_sdEpoch() - Population standard deviation of entire epoch (normalised by N), ignoring NaNs.
%
% Usage:
%   >> out = calc_sdEpoch(eeg, Fs, t_ms)
%
% Inputs
%   eeg   - [numeric] 1D epoch time series (single channel, single epoch)
%   Fs    - [numeric] sampling rate (Hz) (unused; kept for a consistent signature)
%   t_ms  - [numeric] time vector (ms) (unused; kept for a consistent signature)
%
% Outputs
%   out   - scalar >= 0, or NaN if all samples are NaN/Inf

function out = calc_sdEpoch(eeg, Fs, t_ms) %#ok<INUSD>

% Force row vector (lightweight)
x = double(eeg(:)');

% Ignore NaNs (and Infs, for safety)
x = x(isfinite(x));
if isempty(x)
    out = NaN;
    return;
end

% Population standard deviation: normalised by N (MATLAB: var(x, 1))
out = sqrt(var(x, 1));

end