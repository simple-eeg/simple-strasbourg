% quality_control_features() - Calculate quality-control features for an
%                              epoched dataset.
%
% Usage:
%   >> [EEG] = quality_control_features(EEG);
%
% Inputs:
%   EEG       - EEGLAB EEG structure
%
% Outputs:
%   EEG       - EEGLAB EEG structure containing the qc features for each
%               epoch.
%
% Features are saved into a separate struct of each EEG epoch,
% EEG.epoch(x).qc.
%
% Field descriptions (one value per channel):
%
% EEG.epoch.qc.Channels: channel names.
% EEG.epoch.qc.maxAbsEpoch: maximum absolute amplitude over the epoch.
% EEG.epoch.qc.maxAbsBaseline: maximum absolute amplitude before 0 ms.
% EEG.epoch.qc.maxAbsPost: maximum absolute amplitude at or after 0 ms.
% EEG.epoch.qc.sdEpoch: population standard deviation over the epoch.
% EEG.epoch.qc.invSdEpoch: inverse population standard deviation, with the
%                         calculator's scale-adaptive floor.
% EEG.epoch.qc.MeanAbsDiffNorm: mean absolute first difference after robust
%                              normalisation.
% EEG.epoch.qc.MaxAbsDiffNorm: maximum absolute first difference after
%                             robust normalisation.
% EEG.epoch.qc.RobustSlopeNorm: absolute robust slope after robust
%                              normalisation.
% EEG.epoch.qc.AutoCorrLag1Pos: Fisher transform atanh(r) of lag-1
%                              autocorrelation.
% EEG.epoch.qc.AutoCorrLag1Neg: 1-r for lag-1 autocorrelation r.
% EEG.epoch.qc.KatzFDNorm: Katz fractal dimension after robust
%                         normalisation.

function [EEG] = quality_control_features(EEG)

% Initial checks
% --------------
if nargin < 1
    help quality_control_features;
    return
end

if length(EEG)==1 && isempty(EEG.epoch) % error if data not epoched
    error('No epoched data. Please epoch the EEGLAB dataset first.')
end

% Process multiple datasets
% -------------------------
if length(EEG) > 1
    EEG = eeg_eval('quality_control_features', EEG, 'warning', 'off');
    return;
end

% Calculate qc features
% ---------------------------
Fs = EEG.srate;

% Time axis in ms (preferred: EEG.times; fallback: construct from xmin/pnts/srate)
if isfield(EEG, 'times') && ~isempty(EEG.times)
    t_ms = double(EEG.times(:)'); % force row vector
else
    if ~isfield(EEG, 'xmin') || ~isfield(EEG, 'pnts') || isempty(EEG.xmin) || isempty(EEG.pnts)
        error('Cannot construct t_ms: EEG.times missing and EEG.xmin/EEG.pnts not available.');
    end
    t_s  = double(EEG.xmin) + (0:(double(EEG.pnts)-1)) / double(EEG.srate);
    t_ms = 1000 * t_s; % already row
end

for epochn = 1:length(EEG.epoch)
    nchans = length(EEG.chanlocs);

    % Initialise qc feature fields
    EEG.epoch(epochn).qc = struct();
    EEG.epoch(epochn).qc.Channels = {EEG.chanlocs.labels};
    EEG.epoch(epochn).qc.maxAbsEpoch      = NaN(1, nchans);
    EEG.epoch(epochn).qc.maxAbsBaseline   = NaN(1, nchans);
    EEG.epoch(epochn).qc.maxAbsPost       = NaN(1, nchans);
    EEG.epoch(epochn).qc.sdEpoch          = NaN(1, nchans);
    EEG.epoch(epochn).qc.invSdEpoch       = NaN(1, nchans);
    EEG.epoch(epochn).qc.MeanAbsDiffNorm  = NaN(1, nchans);
    EEG.epoch(epochn).qc.MaxAbsDiffNorm   = NaN(1, nchans);
    EEG.epoch(epochn).qc.RobustSlopeNorm  = NaN(1, nchans);
    EEG.epoch(epochn).qc.AutoCorrLag1Pos  = NaN(1, nchans);
    EEG.epoch(epochn).qc.AutoCorrLag1Neg  = NaN(1, nchans);
    EEG.epoch(epochn).qc.KatzFDNorm       = NaN(1, nchans);

    for n = 1:nchans
        eeg = EEG.data(n,:,epochn);

        % Current quality-control features
        % --------------------------------

        % Amplitude extremes in defined windows
        EEG.epoch(epochn).qc.maxAbsEpoch(n)     = calc_maxAbsEpoch(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.maxAbsBaseline(n)  = calc_maxAbsBaseline(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.maxAbsPost(n)      = calc_maxAbsPost(eeg, Fs, t_ms);

        % Overall dispersion and flatness
        EEG.epoch(epochn).qc.sdEpoch(n)         = calc_sdEpoch(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.invSdEpoch(n)      = calc_invSdEpoch(eeg, Fs, t_ms);

        % Scale-normalised roughness and discontinuities
        EEG.epoch(epochn).qc.MeanAbsDiffNorm(n) = calc_MeanAbsDiffNorm(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.MaxAbsDiffNorm(n)  = calc_MaxAbsDiffNorm(eeg, Fs, t_ms);

        % Scale-normalised structure and complexity
        EEG.epoch(epochn).qc.RobustSlopeNorm(n) = calc_RobustSlopeNorm(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.AutoCorrLag1Pos(n) = calc_AutoCorrLag1Pos(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.AutoCorrLag1Neg(n) = calc_AutoCorrLag1Neg(eeg, Fs, t_ms);
        EEG.epoch(epochn).qc.KatzFDNorm(n)      = calc_KatzFDNorm(eeg, Fs, t_ms);

    end
end
end
