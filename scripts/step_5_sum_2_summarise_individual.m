%% step_5_sum_2_summarise_individual.m
% Purpose
%   For each dataset in dataset_list.csv:
%     • Load the processed .set.
%     • Select epochs whose eventtype is in a user-specified list (case-sensitive).
%     • Select channels from a user-specified list (case-sensitive); use those present.
%     • Extract per-epoch, per-channel QC and NRF features into CSVs.
%     • Export selected epoch time series (channels x points x epochs) into a MAT file.
%     • Always write concise CSV headers; write empty CSVs if no rows; only write MAT when data exist.
%     • Filenames use the original stem (e.g., sub-…_ses-…_run-…_eeg_*.*) and go to the dataset's path_summary.
%
% Inputs (spreadsheet)
%   <baseDir>/data_lists/dataset_list.csv  (requires columns:)
%     subjectID, sessionID, runID, EEGfile_processed, path_processed, path_summary
%
% Outputs (per dataset in its <baseDir>/<path_summary>/ folder)
%   <stem>_qc_features.csv
%   <stem>_nrf_features.csv
%   <stem>_epochs_index.csv
%   <stem>_epochs.mat   (only if at least one epoch × channel exported)
%
% Policies & Behaviors
%   • Case-sensitive matching for event types, channels, and NRF names.
%   • If ANY epoch in a dataset has a multi-event label (cell/array), SKIP that dataset entirely.
%   • If a requested QC/NRF row is missing any requested features, skip that row (don't fill with NaNs).
%   • If no selected epochs or no present channels → write empty CSVs (headers only); do not write MAT.
%   • Idempotent: re-running overwrites per-dataset outputs.

log_command_window('start');
clear; clc;

%% 0) User-configurable parameters

baseDir  = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
fileList = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

% Explicit, case-sensitive lists the user controls:

% one or more channels; only those present per dataset are used
selected_channels = {...
    'Cz', ...
    'CZ' ...
    };

% only these epochs will be exported
selected_epoch_types = { ...
    'touch', ...
    'touch_prestim', ...
    'cannula', ...
    'cannula_prestim' ...
    };

% per-channel, per-epoch QC metrics to extract
selected_qc_features = { ...
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

% NRF names (as stored under EEG.epoch(e).NRF.<channel>.<NRFName>)
selected_nrf_names = { ...
    'noxious_preterm_NRF_500Hz' ...
    };

%% 1) Initialize EEGLAB — read-only use
eeglab;
assert(exist('pop_loadset','file') == 2, 'EEGLAB ''pop_loadset'' not found on the MATLAB path.');

%% 2) Read spreadsheet and validate required input columns

fprintf('Loading dataset list: %s\n', fileList);
opts = detectImportOptions(fileList, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');

forceStr = {'subjectID','sessionID','runID', ...
    'EEGfile_processed','path_processed','path_summary'};
for k = 1:numel(forceStr)
    if any(strcmpi(opts.VariableNames, forceStr{k}))
        opts = setvaropts(opts, forceStr{k}, 'Type', 'string');
    end
end

T = readtable(fileList, opts);

need = {'subjectID','sessionID','runID','EEGfile_processed','path_processed','path_summary'};
missing = setdiff(need, T.Properties.VariableNames);
assert(isempty(missing), 'Missing required columns in dataset_list.csv: %s', strjoin(missing, ', '));

% Normalize to strings; treat <missing> as empty strings
for i = 1:numel(need)
    col = need{i};
    T.(col) = string(T.(col));
    T.(col)(ismissing(T.(col))) = "";
end

N = height(T);

%% 3) Counters for overall run summary

datasets_seen             = 0;
datasets_skipped_multievt = 0;
datasets_missing_set      = 0;
datasets_no_epochs        = 0;
datasets_no_channels      = 0;

total_qc_rows_written     = 0;
total_nrf_rows_written    = 0;
total_epochs_mat_written  = 0;

%% 4) Iterate datasets row-by-row

for r = 1:N
    % Resolve spreadsheet IDs and paths
    subj = strtrim(T.subjectID(r));
    sess = strtrim(T.sessionID(r));
    run  = strtrim(T.runID(r));

    setName = strtrim(T.EEGfile_processed(r));
    inRel   = strtrim(T.path_processed(r));
    outRel  = strtrim(T.path_summary(r));

    if strlength(setName)==0 || strlength(inRel)==0 || strlength(outRel)==0
        % Not actionable; skip quietly
        continue
    end

    datasets_seen = datasets_seen + 1;

    % Absolute paths
    inDir   = fullfile(baseDir, inRel);
    inSet   = fullfile(inDir, char(setName));
    outDir  = fullfile(baseDir, outRel);

    % Derive stem (filename without .set) for output names
    [~, stem, srcExt] = fileparts(char(setName)); %#ok<ASGLU>  % srcExt not needed here
    out_qc_csv   = fullfile(outDir, [stem '_qc_features.csv']);
    out_nrf_csv  = fullfile(outDir, [stem '_nrf_features.csv']);
    out_idx_csv  = fullfile(outDir, [stem '_epochs_index.csv']);
    out_epochs   = fullfile(outDir, [stem '_epochs.mat']);

    fprintf('[%d/%d] %s  ->  %s\n', r, N, setName, outRel);

    % Create output directory if needed (recursively)
    if ~exist(outDir, 'dir')
        ok = mkdir(outDir);
        if ~ok
            warning('   [warn] Failed to create output directory: %s. Skipping dataset.', outDir);
            continue
        end
    end

    % If the processed .set is missing, skip (do not write outputs)
    if ~isfile(inSet)
        fprintf('   [warn] Processed .set not found. Skipping this dataset: %s\n', inSet);
        datasets_missing_set = datasets_missing_set + 1;
        continue
    end

    % Load dataset
    try
        EEG = pop_loadset(char(inSet));
    catch ME
        fprintf('   [warn] Failed to load .set: %s. Skipping this dataset.\n', ME.message);
        datasets_missing_set = datasets_missing_set + 1;
        continue
    end

    % Require epochs
    if ~isfield(EEG,'epoch') || isempty(EEG.epoch)
        fprintf('   [info] No epochs present. Writing EMPTY CSVs; no MAT.\n');
        % Write headers-only CSVs; skip MAT
        write_empty_qc_csv(out_qc_csv, selected_qc_features);
        write_empty_nrf_csv(out_nrf_csv);
        write_empty_index_csv(out_idx_csv);
        datasets_no_epochs = datasets_no_epochs + 1;
        continue
    end

    % Enforce single-event epoch labels: skip entire dataset if any epoch label is multi-valued
    nEpoch = numel(EEG.epoch);
    hasMultiEventLabel = false;
    for e = 1:nEpoch
        et = [];
        if isfield(EEG.epoch(e),'eventtype')
            et = EEG.epoch(e).eventtype;
        end
        if iscell(et) || (isstring(et) && numel(et) ~= 1)
            hasMultiEventLabel = true;
            break
        end
    end
    if hasMultiEventLabel
        fprintf('   [ERROR] Dataset has multi-event epoch labels. Skipping ENTIRE dataset.\n');
        datasets_skipped_multievt = datasets_skipped_multievt + 1;
        continue
    end

    % Determine present channels from the selected list
    labels_all = {EEG.chanlocs.labels};
    present = intersect(selected_channels, labels_all, 'stable');

    if isempty(present)
        fprintf('   [info] None of the requested channels present. Writing EMPTY CSVs; no MAT.\n');
        write_empty_qc_csv(out_qc_csv, selected_qc_features);
        write_empty_nrf_csv(out_nrf_csv);
        write_empty_index_csv(out_idx_csv);
        datasets_no_channels = datasets_no_channels + 1;
        continue
    else
        missingCh = setdiff(selected_channels, present, 'stable');
        if ~isempty(missingCh)
            fprintf('   [info] Using subset of requested channels. Present: %s | Missing: %s\n', ...
                strjoin(present, ', '), strjoin(missingCh, ', '));
        else
            fprintf('   [info] Channels present: %s\n', strjoin(present, ', '));
        end
    end

    % --------------------------
    % Build row accumulators
    % --------------------------
    qc_rows  = [];  % table to accumulate QC rows
    nrf_rows = [];  % table to accumulate NRF rows

    % Index info for epochs.mat and epochs_index.csv
    selEpochIdx         = [];           % list of epoch indices kept
    selEpochTypes       = strings(0,1); % matching event type (one per epoch)
    selEpochAnnots      = strings(0,1); % matching event annotation (one per epoch)

    % --------------------------
    % Precompute: channel indices
    % --------------------------
    [~, chIdx] = ismember(present, labels_all);
    chIdx = chIdx(:)'; % row vector of indices
    nCh   = numel(chIdx);

    % ---------------------------------------
    % Pass 1: discover selected epochs & IDs
    % ---------------------------------------
    % Identify selected epochs and record their types and annotations (no latency extraction).

    for e = 1:nEpoch
        % Skip if epoch's label not in the selected list (case-sensitive)
        epoch_label = string(EEG.epoch(e).eventtype);   % guaranteed scalar string/char by earlier check
        if ~any(strcmp(selected_epoch_types, char(epoch_label)))
            continue
        end

        % Derive event annotation (1×1 cell or char), allow empty/missing
        event_annot = "";
        if isfield(EEG.epoch(e), 'eventannotation') && ~isempty(EEG.epoch(e).eventannotation)
            ea = EEG.epoch(e).eventannotation;
            if iscell(ea)
                if ~isempty(ea)
                    ea = ea{1};
                else
                    ea = "";
                end
            end
            if ~isempty(ea)
                event_annot = string(ea);
            end
        end

        % Keep this epoch
        selEpochIdx(end+1,1)    = e;             %#ok<AGROW>
        selEpochTypes(end+1,1)  = epoch_label;   %#ok<AGROW>
        selEpochAnnots(end+1,1) = event_annot;   %#ok<AGROW>
    end

    % If no selected epochs, write empty CSVs; no MAT
    if isempty(selEpochIdx)
        fprintf('   [info] No selected epoch types present. Writing EMPTY CSVs; no MAT.\n');
        write_empty_qc_csv(out_qc_csv, selected_qc_features);
        write_empty_nrf_csv(out_nrf_csv);
        write_empty_index_csv(out_idx_csv);
        datasets_no_epochs = datasets_no_epochs + 1;
        continue
    end

    % ---------------------------------------
    % Pass 2: QC rows
    % ---------------------------------------
    % Build a long table with one row per (epoch, channel) when all requested
    % features exist. We assemble rows directly into 'qc_rows' (no placeholder table).

    % Column order for the QC CSV (no event_latency_samples)
    qc_colNames = ['subjectID','sessionID','runID', ...
        'epoch_index','channel','eventtype','eventannotation', selected_qc_features];

    for ii = 1:numel(selEpochIdx)
        e = selEpochIdx(ii);
        epoch_label = selEpochTypes(ii);
        event_annot = selEpochAnnots(ii);

        for c = 1:nCh
            chLabel = present{c};
            chField = matlab.lang.makeValidName(chLabel);

            % Locate per-epoch QC struct and the channel subfield
            if ~isfield(EEG.epoch(e), 'QC') || isempty(EEG.epoch(e).QC)
                continue
            end
            if ~isfield(EEG.epoch(e).QC, chField) || isempty(EEG.epoch(e).QC.(chField))
                continue
            end

            chQC = EEG.epoch(e).QC.(chField);

            % Collect requested features; skip this row if any missing or NaN
            featVals = nan(1, numel(selected_qc_features));
            ok = true;
            for f = 1:numel(selected_qc_features)
                featName = selected_qc_features{f};
                if ~isfield(chQC, featName) || isempty(chQC.(featName)) || ~isfinite(chQC.(featName))
                    ok = false; break
                end
                featVals(f) = double(chQC.(featName));
            end
            if ~ok
                continue
            end

            % Assemble one row into a cell array in the correct column order
            rowCells = [{char(subj)}, {char(sess)}, {char(run)}, ...
                e, {chLabel}, {char(epoch_label)}, {char(event_annot)}, ...
                num2cell(featVals)];
            rowTbl   = cell2table(rowCells, 'VariableNames', qc_colNames);

            if isempty(qc_rows)
                qc_rows = rowTbl;
            else
                qc_rows = [qc_rows; rowTbl]; %#ok<AGROW>
            end
        end
    end

    % ---------------------------------------
    % Pass 3: NRF rows
    % ---------------------------------------

    nrf_colNames = {'subjectID','sessionID','runID', ...
        'epoch_index','channel','eventtype','eventannotation', ...
        'NRFName','template_dur_ms','projectionTimes_ms','shift_samples', ...
        'pearsonR','cosineSimilarity', ...
        'olsCoef','fglsCoef','fglsVarCoef'};

    for ii = 1:numel(selEpochIdx)
        e = selEpochIdx(ii);
        epoch_label = selEpochTypes(ii);
        event_annot = selEpochAnnots(ii);

        % If no NRF subtree, nothing to export for this epoch
        if ~isfield(EEG.epoch(e), 'NRF') || isempty(EEG.epoch(e).NRF)
            continue
        end

        for c = 1:numel(present)
            chLabel = present{c};
            chField = matlab.lang.makeValidName(chLabel);
            if ~isfield(EEG.epoch(e).NRF, chField) || isempty(EEG.epoch(e).NRF.(chField))
                continue
            end

            for nn = 1:numel(selected_nrf_names)
                nrfName = selected_nrf_names{nn};
                if ~isfield(EEG.epoch(e).NRF.(chField), nrfName) || isempty(EEG.epoch(e).NRF.(chField).(nrfName))
                    continue
                end
                R = EEG.epoch(e).NRF.(chField).(nrfName);

                % Pull fields; skip row if any key field missing
                needFields = {'projectionTimes','pearsonR','cosineSimilarity','shift_all', ...
                    'fglsCoef','fglsVarCoef','olsCoef','template_dur_ms'};
                ok = true;
                for ff = 1:numel(needFields)
                    if ~isfield(R, needFields{ff}) || isempty(R.(needFields{ff}))
                        ok = false; break
                    end
                end
                if ~ok, continue; end

                % NRFName comes from R.profile.NRFName if present; else use struct name
                nrfNameOut = nrfName;
                if isfield(R, 'profile') && isfield(R.profile, 'NRFName') && ~isempty(R.profile.NRFName)
                    nrfNameOut = char(R.profile.NRFName);
                end

                row = {char(subj), char(sess), char(run), ...
                    e, chLabel, char(epoch_label), char(event_annot), ...
                    nrfNameOut, double(R.template_dur_ms), double(R.projectionTimes), double(R.shift_all), ...
                    double(R.pearsonR), double(R.cosineSimilarity), ...
                    double(R.olsCoef), double(R.fglsCoef), double(R.fglsVarCoef)};

                rowTbl = cell2table(row, 'VariableNames', nrf_colNames);
                if isempty(nrf_rows)
                    nrf_rows = rowTbl;
                else
                    nrf_rows = [nrf_rows; rowTbl]; %#ok<AGROW>
                end
            end
        end
    end

    % ---------------------------------------
    % Pass 4: epochs.mat and epochs_index.csv
    % ---------------------------------------
    % Export channels x points x epochs array for selected epochs and present channels.
    % Write epochs_index.csv (one row per epoch) regardless; only write MAT if any epochs exist.

    % Indices of selected epochs (already collected)
    nSelE = numel(selEpochIdx);

    % Prepare epochs_index.csv (headers always written)
    idx_tbl = table( ...
        repmat(string(subj), nSelE, 1), ...
        repmat(string(sess), nSelE, 1), ...
        repmat(string(run),  nSelE, 1), ...
        selEpochIdx, ...
        selEpochTypes, ...
        selEpochAnnots, ...
        repmat(numel(present), nSelE, 1), ...
        repmat(EEG.pnts,      nSelE, 1), ...
        'VariableNames', {'subjectID','sessionID','runID','epoch_index','eventtype','eventannotation','n_channels','n_points'} ...
        );

    % Build epochs struct only if we have something to store
    wrote_mat = false;
    if nSelE > 0 && nCh > 0
        % Preallocate data array: channels x points x epochs
        data = zeros(nCh, EEG.pnts, nSelE, 'like', EEG.data);

        for k = 1:nSelE
            e = selEpochIdx(k);
            data(:,:,k) = EEG.data(chIdx, :, e);
        end

        epochs = struct();
        epochs.data                 = data;
        epochs.times_ms             = EEG.times;         % exact EEGLAB time vector for epochs
        epochs.channels             = present;           % cellstr of channel labels (selected & present)
        epochs.epoch_index          = selEpochIdx;       % corresponding epoch indices (1-based)
        epochs.eventtype            = cellstr(selEpochTypes);
        epochs.eventannotation      = cellstr(selEpochAnnots);
        epochs.subjectID            = char(subj);
        epochs.sessionID            = char(sess);
        epochs.runID                = char(run);
        epochs.srate                = EEG.srate;

        save(out_epochs, 'epochs', '-v7'); % -v7 is fine; use -v7.3 if very large
        wrote_mat = true;
        total_epochs_mat_written = total_epochs_mat_written + 1;
    end

    % ---------------------------------------
    % Pass 5: Write CSVs to disk (overwrite)
    % ---------------------------------------

    % QC CSV (headers even if empty)
    if isempty(qc_rows)
        write_empty_qc_csv(out_qc_csv, selected_qc_features);
    else
        writetable(qc_rows, out_qc_csv);
        total_qc_rows_written = total_qc_rows_written + height(qc_rows);
    end

    % NRF CSV (headers even if empty)
    if isempty(nrf_rows)
        write_empty_nrf_csv(out_nrf_csv);
    else
        writetable(nrf_rows, out_nrf_csv);
        total_nrf_rows_written = total_nrf_rows_written + height(nrf_rows);
    end

    % Epochs index CSV (always write)
    if isempty(idx_tbl)
        write_empty_index_csv(out_idx_csv);
    else
        writetable(idx_tbl, out_idx_csv);
    end

    % ---------------------------------------
    % Per-dataset summary line
    % ---------------------------------------
    qcN  = 0; if ~isempty(qc_rows),  qcN  = height(qc_rows);  end
    nrfN = 0; if ~isempty(nrf_rows), nrfN = height(nrf_rows); end
    fprintf('   -> QC rows: %d | NRF rows: %d | epochs.mat: %s\n', qcN, nrfN, ternary(wrote_mat, 'yes', 'no'));
end

%% 5) Overall run summary
fprintf('\nSummary (per-dataset extraction):\n');
fprintf('  Datasets seen:                    %d\n', datasets_seen);
fprintf('  Skipped (multi-event epochs):     %d\n', datasets_skipped_multievt);
fprintf('  Missing/failed .set loads:        %d\n', datasets_missing_set);
fprintf('  No epochs (or none selected):     %d\n', datasets_no_epochs);
fprintf('  No requested channels present:    %d\n', datasets_no_channels);
fprintf('  Total QC rows written:            %d\n', total_qc_rows_written);
fprintf('  Total NRF rows written:           %d\n', total_nrf_rows_written);
fprintf('  epochs.mat files written:         %d\n', total_epochs_mat_written);

log_command_window('stop');

%% Local helper functions
% These are only for CSV header writing.

function write_empty_qc_csv(path, qc_feats)
baseCols = {'subjectID','sessionID','runID','epoch_index','channel','eventtype','eventannotation'};
allCols = [baseCols, qc_feats(:)'];
Tempty = cell2table(cell(0, numel(allCols)), 'VariableNames', allCols);
writetable(Tempty, path);
end

function write_empty_nrf_csv(path)
cols = {'subjectID','sessionID','runID', ...
    'epoch_index','channel','eventtype','eventannotation', ...
    'NRFName','template_dur_ms','projectionTimes_ms','shift_samples', ...
    'pearsonR','cosineSimilarity', ...
    'olsCoef','fglsCoef','fglsVarCoef'};
Tempty = cell2table(cell(0, numel(cols)), 'VariableNames', cols);
writetable(Tempty, path);
end

function write_empty_index_csv(path)
cols = {'subjectID','sessionID','runID','epoch_index','eventtype','eventannotation', ...
    'n_channels','n_points'};
Tempty = cell2table(cell(0, numel(cols)), 'VariableNames', cols);
writetable(Tempty, path);
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end