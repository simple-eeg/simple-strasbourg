%% step_4_quant_1_QC_feature_extraction.m
% Purpose
%   - Read dataset_list.csv
%   - For all rows in dataset_list.csv, load processed .set, compute QC features for ALL requested channels present
%   - Store QC nested-by-channel: EEG.epoch(e).QC.<Channel>.<metric>, with QC.Channels listing
%   - Remove the aggregated EEG.epoch(e).qc written by quality_control_features
%   - Overwrite the same .set file
%   - Write EEG.etc.simple.qc with options_requested and options_effective
%
% Policies
%   - If processed .set file missing: WARN and continue
%   - If no epochs: WARN and continue (do not resave)
%   - If none of the requested channels are present: WARN and continue (do not resave)

log_command_window('start');
clear; clc;

%% Project setup
baseDir         = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
functionsFolder = fullfile(baseDir, 'functions');
if exist(functionsFolder, 'dir'); addpath(functionsFolder); end

dataListPath    = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

% Initialize EEGLAB + SIMPLE
eeglab;
assert(exist('quality_control_features','file') == 2, 'quality_control_features.m not found on path.');

%% ---- User-editable QC options (REQUESTED) ----
channels_of_interest = {'Cz','CZ'};   % exact, case-sensitive labels
qc_features = { ...
    'maxAbsEpoch', ...
    'sdEpoch', ...
    'invSdEpoch', ...
    'MeanAbsDiffNorm', ...
    'MaxAbsDiffNorm', ...
    'RobustSlopeNorm', ...
    'AutoCorrLag1Pos', ...
    'AutoCorrLag1Neg', ...
    'KatzFDNorm' ...
    };

%% Load dataset_list.csv
fprintf('Loading: %s\n', dataListPath);
opts = detectImportOptions(dataListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');
forceStr = {'subjectID','sessionID','runID','EEGfile_processed','path_processed'};
forceStr = intersect(forceStr, opts.VariableNames, 'stable');
opts = setvartype(opts, forceStr, 'string');
T = readtable(dataListPath, opts);

need = {'EEGfile_processed','path_processed'};
miss = setdiff(need, T.Properties.VariableNames);
if ~isempty(miss), error('Missing required columns in dataset_list.csv: %s', strjoin(miss, ', ')); end

N = height(T);
rowsToDo  = (1:N).';
totalToDo = N;

processedCount      = 0;
skipped_missingFile = 0;
skipped_noEpochs    = 0;
skipped_noChannels  = 0;

%% Iterate files
for idx = 1:totalToDo
    r = rowsToDo(idx);
    relPath = strtrim(string(T.path_processed(r)));
    setName = strtrim(string(T.EEGfile_processed(r)));
    if any(strlength([relPath, setName]) == 0)
        fprintf('[%d/%d] Row %d missing processed path/name. Skipping.\n', idx, totalToDo, r);
        continue;
    end

    srcFile = fullfile(baseDir, relPath, setName);
    fprintf('[%d/%d] QC %s  ->  overwrite in place\n', idx, totalToDo, setName);

    if ~isfile(srcFile)
        fprintf('   [warn] Processed file not found, skipping row %d: %s\n', r, srcFile);
        skipped_missingFile = skipped_missingFile + 1;
        continue;
    end

    % Load dataset
    [srcFolderAbs, srcStem, srcExt] = fileparts(srcFile);
    EEG = pop_loadset('filename', char(srcStem + srcExt), 'filepath', char(srcFolderAbs));

    % Must be epoched
    if ~isfield(EEG,'epoch') || isempty(EEG.epoch)
        fprintf('   [warn] No epochs present for this file (row %d). Skipping.\n', r);
        skipped_noEpochs = skipped_noEpochs + 1;
        continue;
    end

    % Channel presence
    labels  = {EEG.chanlocs.labels};
    present = intersect(channels_of_interest, labels, 'stable');
    if isempty(present)
        fprintf('   [warn] None of requested channels present (row %d). Requested: %s\n', r, strjoin(channels_of_interest, ', '));
        skipped_noChannels = skipped_noChannels + 1;
        continue;
    else
        missing = setdiff(channels_of_interest, present, 'stable');
        if ~isempty(missing)
            fprintf('   [info] Using subset of requested channels. Present: %s | Missing: %s\n', strjoin(present,','), strjoin(missing,','));
        else
            fprintf('   [info] Channels present: %s\n', strjoin(present,','));
        end
    end

    % Compute QC on a temporary selection (do NOT reduce channels in saved EEG)
    EEG_selected = pop_select(EEG, 'channel', present);

    % Run QC (produces EEG_selected.epoch(e).qc aggregated vectors)
    EEG_selected = quality_control_features(EEG_selected);

    % Build nested-by-channel QC in the original EEG and remove aggregated qc
    for e = 1:numel(EEG_selected.epoch)
        if ~isfield(EEG_selected.epoch(e),'qc') || isempty(EEG_selected.epoch(e).qc)
            continue;
        end
        qcAgg = EEG_selected.epoch(e).qc;

        QCNest = struct;
        QCNest.Channels = qcAgg.Channels;  % enumeration

        % Per-channel copy of selected features
        for ci = 1:numel(qcAgg.Channels)
            chLabel = qcAgg.Channels{ci};
            chField = matlab.lang.makeValidName(chLabel);
            QCNest.(chField).Label = chLabel;

            for f = 1:numel(qc_features)
                feat = qc_features{f};
                if isfield(qcAgg, feat)
                    vals = qcAgg.(feat);
                    if numel(vals) >= ci
                        QCNest.(chField).(feat) = vals(ci);
                    else
                        QCNest.(chField).(feat) = NaN;
                    end
                end
            end
        end

        % Write into original EEG’s epoch and remove any previous aggregated qc
        EEG.epoch(e).QC = QCNest;
        if isfield(EEG.epoch(e), 'qc')
            EEG.epoch(e) = rmfield(EEG.epoch(e), 'qc');
        end
    end

    % ----------------- Write provenance flags -----------------
    dtISO = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
    if ~isfield(EEG,'etc') || isempty(EEG.etc), EEG.etc = struct; end
    if ~isfield(EEG.etc,'simple') || isempty(EEG.etc.simple), EEG.etc.simple = struct; end

    EEG.etc.simple.qc = struct( ...
        'applied',           true, ...
        'timestamp',         dtISO, ...
        'options_requested', struct( ...
        'channels_requested', {channels_of_interest}, ...
        'features_kept',      {qc_features} ...
        ), ...
        'options_effective', struct( ...
        'channels_processed', {present}, ...
        'channels_succeeded', {present}, ...           % QC normally succeeds for present channels
        'features_kept',      {qc_features}, ...
        'n_epochs',           numel(EEG_selected.epoch) ...
        ) ...
        );
    % ----------------------------------------------------------

    % Overwrite in place
    pop_saveset(EEG, 'savemode', 'resave');
    processedCount = processedCount + 1;
    fprintf('   -> QC saved\n');
end

fprintf('QC complete. Files updated: %d / %d | Skipped missing: %d | Skipped no-epochs: %d | Skipped no-channels: %d\n', ...
    processedCount, totalToDo, skipped_missingFile, skipped_noEpochs, skipped_noChannels);

log_command_window('stop');
