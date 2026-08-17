%% step_2_raw_6_get_standardised_events.m
% Purpose:
%   - Read data_lists/dataset_list_prelim.xlsx.
%   - For each INCLUDED dataset (excluded_datasets == ""), load the .set file
%     in data/raw/... (using path_reformatted and EEGfile_reformatted).
%   - Extract all current event types from EEG.event.type (after standardisation).
%   - Write three outputs:
%
%     1) Append/overwrite a column 'event_types_standardised' in dataset_list_prelim.xlsx:
%          - Unique event types in that file
%          - Alphabetically sorted
%          - Joined into a single string with '; ' as separator.
%
%     2) For each .set, write a CSV:
%          data/info_prelim/event_types_standardised/<stem>_event_types_standardised.csv
%        containing one event type per row (duplicates kept, no header).
%
%     3) Write a global summary CSV:
%          data/info_prelim/event_types_standardised/event_types_standardised_summary.csv
%        with columns:
%          - Type
%          - TotalOccurrences        (across all files, counting duplicates)
%          - FilesContainingType     (number of files where the type appears at least once)
%
% Decisions:
%   - Include ALL event types exactly as found in EEG.event.type
%     (e.g., 'boundary', 'NA', any other labels).
%   - If a .set is missing or unreadable, error and stop (do not silently skip).
%   - If a .set has zero events, the per-file CSV is empty and the spreadsheet
%     cell is left blank.
%
% Dependencies:
%   - EEGLAB on path (pop_loadset, eeg_checkset).
%
% Inclusion rule:
%   - Only process rows where excluded_datasets == "" (treat <missing> as empty).

log_command_window('start');
clear; clc;

%% 0) Setup paths

root         = "/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg";
fileListPath = fullfile(root, 'data_lists', 'dataset_list_prelim.xlsx');
eventsFolder = fullfile(root, 'data', 'info_prelim', 'event_types_standardised');

% Ensure dataset_list_prelim.xlsx exists
if ~isfile(fileListPath)
    error('StdEvents:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', fileListPath);
end

% Ensure output folder exists
if ~exist(eventsFolder, 'dir')
    ok = mkdir(eventsFolder);
    if ~ok
        error('StdEvents:MakeDirFailed', ...
            'Failed to create events output folder: %s', eventsFolder);
    end
end

% Ensure EEGLAB / pop_loadset is available
if ~(exist('pop_loadset','file') == 2 || exist('eeglab','file') == 2)
    error('StdEvents:EEGLABMissing', ...
        'Neither pop_loadset nor eeglab found on the MATLAB path.');
end
if exist('eeglab','file') == 2
    eeglab;
end

%% 1) Load spreadsheet and validate columns

fprintf("Loading EEG file list: %s\n", fileListPath);
opts = detectImportOptions(fileListPath, ...
    'TextType', 'string', ...
    'VariableNamingRule', 'preserve');
T    = readtable(fileListPath, opts);

reqCols = ["excluded_datasets","path_reformatted","EEGfile_reformatted"];
missingReq = setdiff(reqCols, string(T.Properties.VariableNames));
if ~isempty(missingReq)
    error('StdEvents:ListColsMissing', ...
        'Missing required columns in dataset_list_prelim.xlsx: %s', strjoin(missingReq, ', '));
end

% Normalise key columns to string and treat <missing> as empty
for c = reqCols
    T.(c) = string(T.(c));
    T.(c)(ismissing(T.(c))) = "";
end

% Prepare/overwrite the output column
N = height(T);
T.event_types_standardised = strings(N, 1);

%% 2) Select rows to process (INCLUDED rows only)

excl = string(T.excluded_datasets);
excl(ismissing(excl)) = "";
includedMask = (strlength(strtrim(excl)) == 0);

idxIncluded = find(includedMask);
if isempty(idxIncluded)
    fprintf("No included rows found (excluded_datasets != \"\"). Nothing to do.\n");
    % Still save the table so that 'event_types_standardised' exists
    writetable(T, fileListPath);
    log_command_window('stop');
    return;
end

%% 3) Global accumulators for the summary CSV

% totalCount: total occurrences across all files (duplicates counted)
% filesCount: number of files containing at least one of the type
totalCount = containers.Map('KeyType','char','ValueType','double');
filesCount = containers.Map('KeyType','char','ValueType','double');

processed        = 0;
globalEventTotal = 0;

%% 4) Process each included row

for k = 1:numel(idxIncluded)
    i = idxIncluded(k);

    relDir  = T.path_reformatted(i);
    setName = T.EEGfile_reformatted(i);

    % Validate presence of values
    if strlength(relDir) == 0
        error("StdEvents:EmptyPath", ...
            "Row %d: path_reformatted is empty for an included dataset.", i);
    end
    if strlength(setName) == 0
        error("StdEvents:EmptyFilename", ...
            "Row %d: EEGfile_reformatted is empty for an included dataset.", i);
    end

    % Build absolute paths
    absDir = fullfile(char(root), char(relDir));
    absSet = fullfile(absDir, char(setName));

    if ~isfile(absSet)
        error("StdEvents:MissingSet", ...
            "Row %d: Missing .set file: %s", i, absSet);
    end

    % Load dataset
    try
        EEG = pop_loadset('filename', char(setName), 'filepath', absDir);
        EEG = eeg_checkset(EEG);
    catch ME
        error("StdEvents:LoadFailed", ...
            "Row %d: Failed to load .set file (%s). Error: %s", i, absSet, ME.message);
    end

    % Extract event types from EEG.event.type
    types = strings(0, 1);
    if isfield(EEG, 'event') && ~isempty(EEG.event)
        nEv = numel(EEG.event);
        raw = cell(nEv, 1);
        for e = 1:nEv
            raw{e} = EEG.event(e).type;
        end

        types = strings(nEv, 1);
        for e = 1:nEv
            % string(...) handles numeric/char/mixed; then trim whitespace
            types(e) = strtrim(string(raw{e}));
        end

    end

    % ---- 4a) Write per-file CSV with duplicates kept (no header) ----
    [~, stem, ~] = fileparts(char(setName));
    outCsv = fullfile(eventsFolder, [stem '_event_types_standardised.csv']);

    if isempty(types)
        % Create an empty file explicitly
        fid = fopen(outCsv, 'w');
        if fid ~= -1
            fclose(fid);
        else
            error('StdEvents:PerFileCreateFailed', ...
                'Failed to create per-file CSV: %s', outCsv);
        end
    else
        % One type per line
        writecell(cellstr(types), outCsv);
    end

    % ---- 4b) Update spreadsheet column with unique, alphabetically sorted list ----
    if ~isempty(types)
        uniqTypes = unique(types);
        uniqTypes = sort(uniqTypes);  % alphabetical
        T.event_types_standardised(i) = strjoin(uniqTypes, '; ');
    else
        T.event_types_standardised(i) = "";
    end

    % ---- 4c) Update global accumulators ----
    % TotalOccurrences: count duplicates
    for e = 1:numel(types)
        key = char(types(e));
        if isKey(totalCount, key)
            totalCount(key) = totalCount(key) + 1;
        else
            totalCount(key) = 1;
        end
    end

    % FilesContainingType: count once per file
    if ~isempty(types)
        fileUniques = unique(types);
        for e = 1:numel(fileUniques)
            key = char(fileUniques(e));
            if isKey(filesCount, key)
                filesCount(key) = filesCount(key) + 1;
            else
                filesCount(key) = 1;
            end
        end
    end

    processed        = processed + 1;
    globalEventTotal = globalEventTotal + numel(types);

    fprintf("Processed %d/%d | %s  (events: %d)\n", ...
        processed, numel(idxIncluded), stem, numel(types));
end

%% 5) Save updated spreadsheet with the new 'event_types_standardised' column

writetable(T, fileListPath);
fprintf("Updated dataset_list_prelim.xlsx with 'event_types_standardised'.\n");

%% 6) Build and save global summary CSV: event_types_standardised_summary.csv

allKeys = [keys(totalCount), keys(filesCount)];

if isempty(allKeys)
    % No events found anywhere → write an empty summary with headers
    Type               = strings(0, 1);
    TotalOccurrences   = zeros(0, 1);
    FilesContainingType = zeros(0, 1);
    summaryTbl = table(Type, TotalOccurrences, FilesContainingType);
else
    allKeys = unique(allKeys);        % cellstr of unique type names
    Type = string(allKeys(:));        % column vector of types (as strings)
    TotalOccurrences    = zeros(numel(allKeys), 1);
    FilesContainingType = zeros(numel(allKeys), 1);

    for j = 1:numel(allKeys)
        key = allKeys{j};
        if isKey(totalCount, key)
            TotalOccurrences(j) = totalCount(key);
        else
            TotalOccurrences(j) = 0;
        end
        if isKey(filesCount, key)
            FilesContainingType(j) = filesCount(key);
        else
            FilesContainingType(j) = 0;
        end
    end

    % Sort summary alphabetically by Type
    [Type, sortIdx] = sort(Type);
    TotalOccurrences    = TotalOccurrences(sortIdx);
    FilesContainingType = FilesContainingType(sortIdx);

    summaryTbl = table(Type, TotalOccurrences, FilesContainingType);
end

summaryPath = fullfile(eventsFolder, "event_types_standardised_summary.csv");
writetable(summaryTbl, summaryPath);

%% 7) Wrap-up logs

fprintf("Done.\n");
fprintf("  Files processed          : %d\n", processed);
fprintf("  Total events (all files) : %d\n", globalEventTotal);
if exist(summaryPath, 'file')
    fprintf("  Summary written to       : %s\n", summaryPath);
end

log_command_window('stop');
