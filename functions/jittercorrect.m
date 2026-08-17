% jittercorrect() - Calculate the cross-correlation between signal and
%                   NRF and shift signal to align with the NRF.
%
% Usage:
%   >> [new_data, shift, NRF_resampled] = jittercorrect(data,NRF,fs,fs_NRF, jitter, ...
%                                                                       NRF_start_time)
%
% Inputs:
%   data                - data epoch vector
%   NRF                 - NRF vector
%   fs                  - sampling rate of data; must match fs_NRF
%   fs_NRF              - sampling rate of NRF; must match fs
%   jitter              - Jitter correction in ms
%   NRF_start_time      - elapsed milliseconds from the start of the data
%                         vector to the NRF projection start
%
% Outputs:
%   new_data            - non-circularly shifted full data vector, with
%                         vacated samples zero-padded
%   shift               - signed integer shift in samples; positive values
%                         advance/left-shift data and negative values
%                         delay/right-shift data
%   NRF_resampled       - same-rate input NRF returned unchanged; no
%                         resampling is performed


function [new_data, shift, NRF_resampled] = jittercorrect(data,NRF,fs,fs_NRF, jitter, ...
    NRF_start_time)


% rejig data where necessary
if find(size(data)>1)>1; data = data'; end
if find(size(NRF)>1)>1; NRF = NRF'; end
new_data=data;

% Require matching data and NRF sampling rates; no resampling is performed.
if fs ~= fs_NRF
    error('Trying to resample NRF to match data. This function is not supported yet. Provide pre-resampled NRF instead.')
end
NRF_resampled = NRF;

% convert to sampling index
NRF_start = ceil((NRF_start_time-jitter)/1000*fs) + 1;
NRF_end = ceil((NRF_start_time+jitter)/1000*fs + length(NRF)-1) + 1;
jitter=jitter/1000*fs;

% check jitter is within bounds
if length(data) < NRF_end
    error('The NRF is out of data bounds. Data length (in samples) must be greater than or equal to the required search length (in samples).')
elseif NRF_start < 1
    error('The NRF is out of data bounds. Jitter must be less than NRF_start_time.')
end

% Calculate the shift that maximises signed Pearson r.

% Build the search region and integer lag range
x_epoch = data(NRF_start:NRF_end);
nrfLen = length(NRF);
J = round(jitter);

% Ensure windows stay inside x_epoch
maxJ = max(0, floor((numel(x_epoch) - nrfLen)/2));
if J > maxJ
    J = maxJ;
end

lags = (-J:J).';
rValues = -inf(numel(lags),1);

% Evaluate Pearson correlation for each candidate lag (no zero-padding)
for i = 1:numel(lags)
    lag = lags(i);
    idxStart = J + 1 + lag;
    idxEnd   = J + nrfLen + lag;
    win = x_epoch(idxStart:idxEnd);
    r = corr(win, NRF, 'Type','Pearson');
    if isnan(r)
        r = -inf;
    end
    rValues(i) = r;
end

% Select maximum r. Within tolerance, prefer smallest |lag|, then lowest
% lag; if every candidate is invalid, select zero lag.
maxR = max(rValues);
if ~isfinite(maxR)
    [~, bestIdx] = min(abs(lags));
else
    tol = max(1e-12, 1e-9 * abs(maxR));
    candidates = find(abs(rValues - maxR) <= tol);
    if numel(candidates) > 1
        [~, k] = min(abs(lags(candidates)));
        minAbs = abs(lags(candidates(k)));
        candidates = candidates(abs(lags(candidates)) == minAbs);
        bestIdx = candidates(1);
    else
        bestIdx = candidates;
    end
end

shift = lags(bestIdx);

% Apply a non-circular shift and zero-pad vacated samples to retain length.
if shift<0
    new_data=[zeros(abs(shift),1);new_data(1:(end-abs(shift)))];
else
    new_data=[new_data(shift+1:end);zeros(shift,1)];
end
new_data = new_data';
end
