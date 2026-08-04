%% step_4_quant_3_NRF_feature_extraction.m
% Purpose
%   - Map epoch event types (from CSV) to INI "profiles" for each NRF family
%     (early_NRF, noxious_NRF, noxious_preterm_NRF).
%   - Use a per-(profile,channel) cache so each pair is computed once per dataset,
%     then reuse its per-epoch results for all mapped epochs.
%   - Store results compactly at EEG.epoch(e).NRF.(Channel).(NRFName).
%
% Storage & policy (agreed):
%   - EEG.epoch(e).NRF.(Channel).(NRFName) with fields:
%       projectionTimes, pearsonR, shift_all, cosineSimilarity,
%       fglsCoef, fglsVarCoef, olsCoef,
%       channel_label, eventtype, template_dur_ms, profile(=struct: name + 6 INI options)
%   - Drop large arrays: shifted_data_all, NRF_resampled.
%   - Exactly one scalar start per profile (pre ≤ 0 XOR post ≥ 0). Other empty.
%   - Runtime checks per dataset: abs_start_ms >= jitter; sample-grid alignment.
%   - Case-sensitive eventtype matching; CSV cells empty or a single profile name.
%   - Channels only from the profile; silently skip those not present.
%   - Clear all previous results under EEG.epoch(e).NRF before writing.
%
% Inputs expected:
%   - INI: data_lists/nrf_config.ini
%   - CSV: data/info/epoch_types/epoch_type_summary.csv
%          columns: Type, early_NRF, noxious_NRF, noxious_preterm_NRF
%   - EEG list: data_lists/dataset_list.csv
%          columns: EEGfile_processed, path_processed

log_command_window('start');
clear; clc;

%% --- User-configurable paths & settings (edit here) ---
baseDir         = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
config_path     = fullfile(baseDir, 'data_lists', 'nrf_config.ini');
epoch_csv       = fullfile(baseDir, 'data', 'info', 'epoch_types', 'epoch_type_summary.csv');
dataListPath    = fullfile(baseDir, 'data_lists', 'dataset_list.csv');
functionsFolder = fullfile(baseDir, 'functions');

% Fixed NRF family names (mapping columns in CSV)
families = {'early_NRF','noxious_NRF','noxious_preterm_NRF'};

%% --- Initialize SIMPLE/EEGLAB environment ---
% Ensure your local functions folder is on path (contains NRFUtils.m)
if exist(functionsFolder, 'dir'); addpath(functionsFolder); end

eeglab; % adds EEGLAB + SIMPLE; SIMPLE puts its NRFs folder on the MATLAB path
assert(exist('pop_estimate_response','file') == 2, 'pop_estimate_response.m not found on path.');
assert(exist('NRFUtils','class') == 8, 'NRFUtils.m not found or not on path.');

%% --- Parse & validate INI profiles ---
profiles = NRFUtils.parseIni(config_path);
profiles = NRFUtils.validateProfiles(profiles); % adds p.proj_scalar and enforces sign/emptiness rules

%% --- Read CSV mapping: Type -> profileName (per family) ---
map = NRFUtils.readEpochTypeMapping(epoch_csv, profiles, families);

%% --- Load EEG dataset list ---
fprintf('Loading dataset list: %s\n', dataListPath);
opts = detectImportOptions(dataListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');
forceStrCols = {'subjectID','sessionID','runID','EEGfile_processed','path_processed'};
forceStrCols = intersect(forceStrCols, opts.VariableNames, 'stable');
opts = setvartype(opts, forceStrCols, 'string');
T = readtable(dataListPath, opts);

needCols = {'EEGfile_processed','path_processed'};
missingCols = setdiff(needCols, T.Properties.VariableNames);
if ~isempty(missingCols)
    error('Missing required columns in dataset_list.csv: %s', strjoin(missingCols, ', '));
end

%% --- Process datasets ---
N = height(T);
files_processed = 0; files_saved = 0; total_epochs_seen = 0; total_fits_done = 0;

for i = 1:N

    fRel = T.EEGfile_processed(i);
    pRel = T.path_processed(i);
    if ismissing(fRel) || fRel == "" || ismissing(pRel) || pRel == ""
        continue;
    end

    setFile = char(fRel);
    setDir  = char(fullfile(baseDir, char(pRel)));
    setAbs  = fullfile(setDir, setFile);

    if ~exist(setAbs, 'file')
        fprintf('[%d/%d] %s — file not found, skipping.\n', i, N, setFile);
        continue;
    end

    fprintf('[%d/%d] %s — starting NRF extraction\n', i, N, setFile);
    EEG = pop_loadset('filename', setFile, 'filepath', setDir);
    files_processed = files_processed + 1;

    % Validate each epoch has a single eventtype (not a cell array)
    nEpochs = numel(EEG.epoch);
    for e = 1:nEpochs
        rawET = EEG.epoch(e).eventtype;
        if iscell(rawET) || (isstring(rawET) && numel(rawET) ~= 1)
            error('Epoch %d has multi-event eventtype; exactly one string/char required.', e);
        end
    end

    % Dataset labels (case-sensitive)
    labels = {EEG.chanlocs.labels};

    % Epoch types present in this dataset
    epoch_types_in_set = cell(1, nEpochs);
    for e = 1:nEpochs, epoch_types_in_set{e} = char(EEG.epoch(e).eventtype); end
    unique_types_in_set = unique(epoch_types_in_set, 'stable');

    % Profiles that actually apply to this dataset (based on CSV mapping)
    used_profile_names = {};
    for f = 1:numel(families)
        fam = families{f};
        thisMap = map.(fam);
        for ut = 1:numel(unique_types_in_set)
            etype = unique_types_in_set{ut};
            if isKey(thisMap, etype)
                used_profile_names{end+1} = thisMap(etype); %#ok<AGROW>
            end
        end
    end
    used_profile_names = unique(used_profile_names, 'stable');

    % Consolidated channels presence for this dataset (across used profiles)
    requested_all = {};
    for up = 1:numel(used_profile_names)
        pname = used_profile_names{up};
        chs = profiles.(pname).channel; % cellstr as in INI
        for c = 1:numel(chs)
            if ~any(strcmp(requested_all, chs{c})) % dedupe, case-sensitive
                requested_all{end+1} = chs{c}; %#ok<AGROW>
            end
        end
    end
    present = intersect(requested_all, labels, 'stable');
    missing = setdiff(requested_all, labels, 'stable');
    % Print in the exact style as Option 1: "A , B , C"
    present_str = ''; if ~isempty(present), present_str = strjoin(present, ' , '); end
    missing_str = ''; if ~isempty(missing), missing_str = strjoin(missing, ' , '); end
    fprintf('   channels — present: %s | missing: %s\n', present_str, missing_str);

    % --- Clear previous NRF results (keep QC subtree intact) ---
    for e = 1:nEpochs
        EEG.epoch(e).NRF = struct();
    end

    % Dataset-level zero_t (ms): time from epoch start to the stimulus "0 ms"
    zero_t_ms = -(EEG.xmin) * 1000;  % e.g., EEG.xmin = -1 s -> zero_t_ms = 1000

    % --- Build caches once per (profile, channel) using NRFUtils ---
    [fit_cache, templ_info] = NRFUtils.fitAndCache(EEG, profiles, used_profile_names, labels, zero_t_ms);

    % --- Iterate epochs and write only mapped outputs (reusing cache) ---
    fits_done = 0;
    for e = 1:nEpochs
        etype = char(EEG.epoch(e).eventtype); % exact, case-sensitive

        for f = 1:numel(families)
            fam = families{f};
            famMap = map.(fam);
            if ~isKey(famMap, etype), continue; end

            pname = famMap(etype);
            p = profiles.(pname);

            % Channels present for this profile in this dataset
            ch_list = {};
            for c = 1:numel(p.channel)
                if any(strcmp(labels, p.channel{c}))
                    ch_list{end+1} = p.channel{c}; %#ok<AGROW>
                end
            end
            if isempty(ch_list), continue; end

            % For each present channel, pull the per-epoch result from the cache
            for c = 1:numel(ch_list)
                ch = ch_list{c};

                if ~isfield(fit_cache, pname) || ~isfield(fit_cache.(pname), ch)
                    % Should not happen; cache built above only for present channels
                    continue;
                end
                EEG_fit = fit_cache.(pname).(ch);

                if ~isfield(EEG_fit.epoch(e), p.NRFName)
                    error('Internal: expected cached EEG_fit.epoch(%d).%s to exist.', e, p.NRFName);
                end
                R = EEG_fit.epoch(e).(p.NRFName);

                % Drop large/redundant fields
                if isfield(R, 'shifted_data_all'), R = rmfield(R, 'shifted_data_all'); end
                if isfield(R, 'NRF_resampled'),     R = rmfield(R, 'NRF_resampled');     end

                % Add tiny helpers
                R.channel_label   = ch;
                R.eventtype       = etype;
                R.template_dur_ms = templ_info.(p.NRFName).duration_ms;
                R.profile = struct( ...
                    'name',                 pname, ...
                    'NRFName',              p.NRFName, ...
                    'baselineLength',       p.baselineLength, ...
                    'jitter',               p.jitter, ...
                    'channel',              {p.channel}, ...         % full list from INI
                    'projectionTimes_pre',  p.projectionTimes_pre, ...
                    'projectionTimes_post', p.projectionTimes_post );

                % Store under NRF subtree
                EEG.epoch(e).NRF.(ch).(p.NRFName) = R;
                fits_done = fits_done + 1;
            end
        end
    end

    % Save in place if any fits were written
    if fits_done > 0
        EEG.filepath = setDir;
        EEG.filename = setFile;
        pop_saveset(EEG, 'filename', setFile, 'filepath', setDir, 'savemode', 'resave');
        files_saved = files_saved + 1;
    end
    total_epochs_seen = total_epochs_seen + nEpochs;
    total_fits_done   = total_fits_done + fits_done;

    fprintf('   -> fits saved: %d\n', fits_done);
end

%% --- Final summary ---
fprintf('NRF extraction complete.\n');
fprintf('Files processed: %d | Files saved: %d | Epochs seen: %d | Fits written: %d\n', ...
    files_processed, files_saved, total_epochs_seen, total_fits_done);

log_command_window('stop');
