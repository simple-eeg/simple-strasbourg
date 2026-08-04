%% step_4_quant_2_get_epochs.m
% Purpose
%   Inventory epoch labels in processed datasets and write user-friendly summaries.
%
%   This script reads the processed .set files listed in data_lists/dataset_list.csv,
%   extracts all epoch labels from EEG.epoch(e).eventtype, and writes FOUR outputs:
%
%   A) Spreadsheet column 'epoch_types' (per-file unique labels; alphabetical; semicolon-joined)
%   B) Per-file CSV listing all epoch labels (duplicates kept; no header)
%      -> data/info/epoch_types/<stem>_epoch_types.csv
%   C) Global epoch label summary CSV (Type, TotalOccurrences, FilesContainingType)
%      -> data/info/epoch_types/epoch_type_summary.csv
%   D) Multi-event epoch reporting (non-optional), fully contained under:
%         data/info/epoch_types/multievent_epochs/
%        D1) Per-file detail (ONLY if file has ≥1 multi-event epoch):
%             <stem>_multievent_epochs.csv
%             Columns: EpochIndex, EventTypesJoined, CanonicalKey, NumEvents
%        D2) Dataset-level index (always written, with headers):
%             multievent_epoch_index.csv
%             Columns: DatasetStem, NumEpochs, NumMultiEventEpochs, UniqueComboKeys
%        D3) Global combo summary (always written, with headers):
%             multievent_epoch_combos_summary.csv
%             Columns: CanonicalKey, TotalOccurrences, FilesContainingCombo
%
% Inclusion rule:
%   - All rows in dataset_list.csv are treated as included.
%
% Policies & behaviors
%   - If processed .set file missing: WARN and continue (do not crash the batch).
%   - If a .set has no epochs: still write an EMPTY per-file epoch-types CSV, keep spreadsheet cell blank,
%     and index it with zero multi-event epochs.
%   - Labels are included EXACTLY as found (including 'boundary', dummy/prestim labels, etc).
%   - Per-file epoch-types CSV keeps duplicates (so counts remain meaningful).
%   - Spreadsheet 'epoch_types' is unique+sorted+semicolon-joined.
%   - CanonicalKey for multi-event grouping: within an epoch, dedupe labels -> sort -> join with ' + '.
%   - This script NEVER modifies EEG files; it ONLY reads .set and writes CSVs / spreadsheet updates.
%
% Dependencies
%   - EEGLAB on the path (pop_loadset).
%   - The spreadsheet data_lists/dataset_list.csv must contain:
%        path_processed, EEGfile_processed

log_command_window('start');
clear; clc;

%% 0) Paths and output folders
baseDir               = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
fileListPath          = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

outEpochTypesFolder   = fullfile(baseDir, 'data', 'info', 'epoch_types');
outMultiEventFolder   = fullfile(outEpochTypesFolder, 'multievent_epochs');

% Ensure output folders exist
if ~exist(outEpochTypesFolder, 'dir')
    ok = mkdir(outEpochTypesFolder);
    if ~ok, error('Failed to create output folder: %s', outEpochTypesFolder); end
end
if ~exist(outMultiEventFolder, 'dir')
    ok = mkdir(outMultiEventFolder);
    if ~ok, error('Failed to create output folder: %s', outMultiEventFolder); end
end

%% 1) Initialize EEGLAB and sanity-check dependencies
eeglab;
assert(exist('pop_loadset','file') == 2, 'EEGLAB ''pop_loadset'' not found on the MATLAB path.');

%% 2) Load spreadsheet & validate required columns
fprintf('Loading dataset list: %s\n', fileListPath);

opts = detectImportOptions(fileListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');

% Force ALL columns to import as string (prevents loss of leading zeros, digit-only IDs, etc.)
opts = setvartype(opts, opts.VariableNames, 'string');

T = readtable(fileListPath, opts);

reqCols = ["path_processed","EEGfile_processed"];
missingReq = setdiff(reqCols, string(T.Properties.VariableNames));
assert(isempty(missingReq), "Missing required columns in dataset_list.csv: %s", strjoin(missingReq, ", "));

% Normalize key columns to string & treat <missing> as empty
for c = reqCols
    T.(c) = string(T.(c));
    T.(c)(ismissing(T.(c))) = "";
end

% Ensure the output column exists (create if missing)
if ~any(strcmp(string(T.Properties.VariableNames), "epoch_types"))
    T.epoch_types = strings(height(T), 1);
else
    % Make sure it's a string array for consistent writing
    T.epoch_types = string(T.epoch_types);
    T.epoch_types(ismissing(T.epoch_types)) = "";
end

N = height(T);
rowsToDo  = (1:N).';
totalToDo = N;

%% 3) Global accumulators
% Label summaries
label_totalCount = containers.Map('KeyType','char','ValueType','double');  % counts duplicates across all files
label_filesCount = containers.Map('KeyType','char','ValueType','double');  % counts number of files where label appears at least once

% Multi-event combination summaries
combo_totalCount = containers.Map('KeyType','char','ValueType','double');  % counts multi-event epochs per canonical combo
combo_filesCount = containers.Map('KeyType','char','ValueType','double');  % counts number of files containing the combo

% Dataset-level index for multi-event summary
index_DatasetStem         = strings(0,1);
index_NumEpochs           = zeros(0,1);
index_NumMultiEventEpochs = zeros(0,1);
index_UniqueComboKeys     = strings(0,1);

% Counters
processed        = 0;   % rows with existing .set (even if 0 epochs)
skipped_missing  = 0;   % rows whose processed .set was missing

%% 4) Process each row
for k = 1:totalToDo
    r = rowsToDo(k);
    relPath = strtrim(string(T.path_processed(r)));
    setName = strtrim(string(T.EEGfile_processed(r)));

    if any(strlength([relPath, setName]) == 0)
        error('[%d/%d] Row %d missing path_processed or EEGfile_processed.', k, totalToDo, r);
    end

    absDir = fullfile(baseDir, relPath);
    absSet = fullfile(absDir, char(setName));
    [~, stem] = fileparts(char(setName));

    fprintf('[%d/%d] Epoch inventory %s\n', k, totalToDo, setName);

    if ~isfile(absSet)
        fprintf('   [warn] Processed .set not found, skipping row %d: %s\n', r, absSet);
        skipped_missing = skipped_missing + 1;
        continue
    end

    % -- Load dataset
    try
        EEG = pop_loadset(char(absSet));
    catch ME
        fprintf('   [warn] Failed to load .set (row %d): %s\n', r, ME.message);
        skipped_missing = skipped_missing + 1;
        continue
    end

    % -- Handle "no epochs" case
    if ~isfield(EEG,'epoch') || isempty(EEG.epoch)
        % Per-file epoch labels CSV: create an empty file explicitly
        perFileEpochTypesCSV = fullfile(outEpochTypesFolder, [stem '_epoch_types.csv']);
        fid = fopen(perFileEpochTypesCSV, 'w'); fclose(fid);

        % Spreadsheet column left blank
        T.epoch_types(r) = "";

        % Dataset-level index row (0 epochs, 0 multi-event)
        index_DatasetStem(end+1,1)         = string(stem);
        index_NumEpochs(end+1,1)           = 0;
        index_NumMultiEventEpochs(end+1,1) = 0;
        index_UniqueComboKeys(end+1,1)     = "";

        fprintf('   [info] No epochs found. Wrote empty epoch-types CSV.\n');
        processed = processed + 1;
        continue
    end

    % -- Epochs exist: extract labels
    numEpochs = numel(EEG.epoch);

    % Accumulators for this file
    typesAll   = strings(0,1);   % flat list of labels across epochs (duplicates kept)
    fileCombos = strings(0,1);   % set of distinct canonical keys observed in this file
    multiRows  = [];             % table of multi-event rows for this file
    numMulti   = 0;

    % Iterate epochs
    for e = 1:numEpochs
        % Read eventtype(s) for this epoch and normalize to a string vector (labelsObserved)
        labelsObserved = strings(0,1);
        if isfield(EEG.epoch(e), 'eventtype')
            et = EEG.epoch(e).eventtype;
            if iscell(et)
                tmp = strings(0,1);
                for ii = 1:numel(et)
                    s = strtrim(string(et{ii}));
                    if strlength(s) > 0
                        tmp(end+1,1) = s; %#ok<AGROW>
                    end
                end
                labelsObserved = tmp;
            else
                s = strtrim(string(et));
                if strlength(s) > 0
                    labelsObserved = s;
                end
            end
        end

        % Append to the flat label list (duplicates kept)
        if ~isempty(labelsObserved)
            typesAll = [typesAll; labelsObserved]; %#ok<AGROW>
        end

        % Multi-event detection and recording
        if numel(labelsObserved) > 1
            numEvents = numel(labelsObserved);                  % before any dedupe
            uniqSorted = sort(unique(labelsObserved));          % dedupe + sort (case-preserving)
            canonical  = strjoin(cellstr(uniqSorted), ' + ');   % canonical combo key

            % Track the combo key for per-file uniqueness
            if ~ismember(string(canonical), fileCombos)
                fileCombos(end+1,1) = string(canonical); %#ok<AGROW>
            end

            % Build a per-file detail row
            joinedObserved = strjoin(cellstr(labelsObserved), '; '); % as observed in the epoch
            row = table( ...
                e, {joinedObserved}, {canonical}, numEvents, ...
                'VariableNames', {'EpochIndex','EventTypesJoined','CanonicalKey','NumEvents'} );
            if isempty(multiRows)
                multiRows = row;
            else
                multiRows = [multiRows; row]; %#ok<AGROW>
            end
            numMulti = numMulti + 1;
        end
    end

    % -- Write per-file epoch labels CSV (duplicates kept; no header)
    perFileEpochTypesCSV = fullfile(outEpochTypesFolder, [stem '_epoch_types.csv']);
    if isempty(typesAll)
        % Explicit empty file
        fid = fopen(perFileEpochTypesCSV, 'w'); fclose(fid);
    else
        writecell(cellstr(typesAll), perFileEpochTypesCSV);
    end

    % -- Update spreadsheet column 'epoch_types' (unique + alphabetical + semicolon-joined)
    if isempty(typesAll)
        T.epoch_types(r) = "";
    else
        uniqSorted = sort(unique(typesAll));
        T.epoch_types(r) = strjoin(cellstr(uniqSorted), '; ');
    end

    % -- Update GLOBAL label counts
    % TotalOccurrences: add all duplicates
    for j = 1:numel(typesAll)
        key = char(typesAll(j));
        if isKey(label_totalCount, key)
            label_totalCount(key) = label_totalCount(key) + 1;
        else
            label_totalCount(key) = 1;
        end
    end
    % FilesContainingType: once per file (unique labels within this file)
    if ~isempty(typesAll)
        fileUniques = unique(typesAll);
        for j = 1:numel(fileUniques)
            key = char(fileUniques(j));
            if isKey(label_filesCount, key)
                label_filesCount(key) = label_filesCount(key) + 1;
            else
                label_filesCount(key) = 1;
            end
        end
    end

    % -- Write per-file MULTI-EVENT detail (only if any)
    if numMulti > 0
        perFileMultiCSV = fullfile(outMultiEventFolder, [stem '_multievent_epochs.csv']);
        writetable(multiRows, perFileMultiCSV);
    end

    % -- Update GLOBAL combo counts (multi-event only)
    if ~isempty(fileCombos)
        % FilesContainingCombo: count each combo once per file
        for j = 1:numel(fileCombos)
            key = char(fileCombos(j));
            if isKey(combo_filesCount, key)
                combo_filesCount(key) = combo_filesCount(key) + 1;
            else
                combo_filesCount(key) = 1;
            end
        end
    end
    if ~isempty(multiRows)
        % TotalOccurrences: add one per multi-event epoch row
        for j = 1:height(multiRows)
            key = char(multiRows.CanonicalKey{j});
            if isKey(combo_totalCount, key)
                combo_totalCount(key) = combo_totalCount(key) + 1;
            else
                combo_totalCount(key) = 1;
            end
        end
    end

    % -- Append dataset-level index row
    if isempty(fileCombos)
        uniqueKeysJoined = "";
    else
        uniqueKeysJoined = strjoin(cellstr(sort(fileCombos)), '; ');
    end
    index_DatasetStem(end+1,1)         = string(stem);
    index_NumEpochs(end+1,1)           = numEpochs;
    index_NumMultiEventEpochs(end+1,1) = numMulti;
    index_UniqueComboKeys(end+1,1)     = string(uniqueKeysJoined);

    fprintf('   [info] epochs: %d | multi-event epochs: %d | unique epoch types: %d\n', ...
        numEpochs, numMulti, numel(unique(typesAll)));

    processed = processed + 1;
end

%% 5) Save updated spreadsheet with the new/updated 'epoch_types' column
writetable(T, fileListPath);
fprintf('Updated dataset_list.csv with ''epoch_types''.\n');

%% 6) Write GLOBAL epoch label summary: epoch_type_summary.csv
allLabelKeys = unique([keys(label_totalCount), keys(label_filesCount)]);
if isempty(allLabelKeys)
    Type = strings(0,1); TotalOccurrences = zeros(0,1); FilesContainingType = zeros(0,1); %#ok<NASGU>
    summaryTbl = table(Type, TotalOccurrences, FilesContainingType);
else
    Type = string(allLabelKeys(:));
    TotalOccurrences = zeros(numel(allLabelKeys), 1);
    FilesContainingType = zeros(numel(allLabelKeys), 1);

    for j = 1:numel(allLabelKeys)
        key = allLabelKeys{j};
        if isKey(label_totalCount, key),   TotalOccurrences(j)   = label_totalCount(key);   end
        if isKey(label_filesCount, key),   FilesContainingType(j) = label_filesCount(key); end
    end

    % Sort alphabetically by Type
    [Type, sortIdx]       = sort(Type);
    TotalOccurrences      = TotalOccurrences(sortIdx);
    FilesContainingType   = FilesContainingType(sortIdx);

    summaryTbl = table(Type, TotalOccurrences, FilesContainingType);
end

summaryPath = fullfile(outEpochTypesFolder, 'epoch_type_summary.csv');

emptyCol = strings(height(summaryTbl), 1);
summaryTbl.early_NRF            = emptyCol;
summaryTbl.noxious_NRF          = emptyCol;
summaryTbl.noxious_preterm_NRF  = emptyCol;

writetable(summaryTbl, summaryPath);

%% 7) Write GLOBAL multi-event files (always with headers)

% Dataset-level index
indexTbl = table( ...
    index_DatasetStem, index_NumEpochs, index_NumMultiEventEpochs, index_UniqueComboKeys, ...
    'VariableNames', {'DatasetStem','NumEpochs','NumMultiEventEpochs','UniqueComboKeys'} );
% (Optional sort) indexTbl = sortrows(indexTbl, 'DatasetStem');
writetable(indexTbl, fullfile(outMultiEventFolder, 'multievent_epoch_index.csv'));

% Combo summary
allComboKeys = unique([keys(combo_totalCount), keys(combo_filesCount)]);
if isempty(allComboKeys)
    CanonicalKey = strings(0,1); TotalOccurrences = zeros(0,1); FilesContainingCombo = zeros(0,1); %#ok<NASGU>
    combosTbl = table(CanonicalKey, TotalOccurrences, FilesContainingCombo);
else
    CanonicalKey       = string(allComboKeys(:));
    TotalOccurrences   = zeros(numel(allComboKeys), 1);
    FilesContainingCombo = zeros(numel(allComboKeys), 1);

    for j = 1:numel(allComboKeys)
        key = allComboKeys{j};
        if isKey(combo_totalCount, key),     TotalOccurrences(j)    = combo_totalCount(key);   end
        if isKey(combo_filesCount, key),     FilesContainingCombo(j) = combo_filesCount(key); end
    end

    % Sort alphabetically by CanonicalKey
    [CanonicalKey, sortIdx]  = sort(CanonicalKey);
    TotalOccurrences         = TotalOccurrences(sortIdx);
    FilesContainingCombo     = FilesContainingCombo(sortIdx);

    combosTbl = table(CanonicalKey, TotalOccurrences, FilesContainingCombo);
end

writetable(combosTbl, fullfile(outMultiEventFolder, 'multievent_epoch_combos_summary.csv'));

%% 8) Wrap-up logs
numGlobalLabels = height(summaryTbl);
numGlobalCombos = height(combosTbl);
fprintf('Epoch inventory complete.\n');
fprintf('  Files processed                : %d / %d\n', processed, totalToDo);
fprintf('  Skipped missing processed .set : %d\n', skipped_missing);
fprintf('  Global unique epoch labels     : %d\n', numGlobalLabels);
fprintf('  Global multi-event combos      : %d\n', numGlobalCombos);

log_command_window('stop');
