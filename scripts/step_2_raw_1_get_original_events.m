%% step_2_raw_1_get_original_events.m
% Extract original event types from Strasbourg BrainVision data.
%
% For each usable recording listed in dataset_list_prelim.xlsx, this script:
%   - Loads the BrainVision file from data/source/ via pop_loadbv.
%   - Extracts ALL EEG.event.type entries (no filtering at all).
%   - Writes a per-recording CSV with one event type per row (no header).
%   - Builds a per-recording summary of unique event types and writes it
%     into dataset_list_prelim.xlsx as 'event_types_original'.
%   - Constructs a global summary CSV listing each unique event type,
%     total occurrences, and number of files containing it, plus blank
%     user-editable columns for Type_new / filters / latency flags.
%
% Outputs:
%   - Per-file CSVs:
%       baseDir/data/info_prelim/event_types_original/ ...
%           sub-<subjectID>_ses-<sessionID>_run-<runID>_eeg_event_types_original.csv
%     Each CSV has a single column, no header, one event type per row
%     (duplicates kept; empty types appear as blank lines).
%
%   - Updated dataset_list_prelim.xlsx:
%       Adds/overwrites:
%           event_types_original : semicolon-separated unique event types per row
%           latency_correct      : blank string column (created if missing)
%
%   - Global summary CSV:
%       baseDir/data/info_prelim/event_types_original/event_types_original_summary.csv
%       Columns (with header):
%           Type_original, TotalOccurrences, FilesContainingEvent,
%           Type_new, Filter_AND, Filter_OR, Filter_NOT, LatencyCorrect

log_command_window('start');
clear; clc;

eeglab;

%% 1. Define paths

baseDir       = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
dataListsPath = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');

eventsRoot    = fullfile(baseDir, 'data', 'info_prelim', 'event_types_original');
if ~isfolder(eventsRoot)
    ok = mkdir(eventsRoot);
    if ~ok
        error('GetOriginalEvents:MakeEventsRootFailed', ...
            'Failed to create directory: %s', eventsRoot);
    end
end

%% 2. Load dataset_list_prelim.xlsx and check required columns

if ~isfile(dataListsPath)
    error('GetOriginalEvents:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', dataListsPath);
end

tbl = readtable(dataListsPath, ...
    'PreserveVariableNames', true, ...
    'TextType', 'string');

requiredCols = ["subjectID","sessionID","runID", ...
    "vhdr","path_out", ...
    "vhdr_missing","vmrk_missing","dat_missing"];

missingRequired = requiredCols(~ismember(requiredCols, tbl.Properties.VariableNames));
if ~isempty(missingRequired)
    error('GetOriginalEvents:MissingColumns', ...
        'The following required column(s) are missing from dataset_list_prelim.xlsx: %s', ...
        strjoin(cellstr(missingRequired), ', '));
end

nRows = height(tbl);

% Ensure *_missing columns are strings (handle all-empty-as-NaN case)
missingCols = ["vhdr_missing","vmrk_missing","dat_missing"];
for c = 1:numel(missingCols)
    colName = missingCols(c);
    colData = tbl.(colName);
    if isnumeric(colData)
        tbl.(colName) = strings(nRows, 1);
    else
        tbl.(colName) = string(colData);
    end
end

%% 3. Determine which rows to process

toUse = (tbl.vhdr_missing ~= "missing") & ...
    (tbl.vmrk_missing ~= "missing") & ...
    (tbl.dat_missing  ~= "missing");

eventTypesCol = strings(nRows, 1);  % per-row semicolon-joined unique types
allTypes      = strings(0, 1);      % all event instances across all files

%% 4. Loop over rows and extract event types

for i = 1:nRows
    subjID = tbl.subjectID(i);
    sessID = tbl.sessionID(i);
    runID  = tbl.runID(i);

    if ~toUse(i)
        fprintf('Skipping sub-%s, ses-%s, run %s (missing BrainVision files)\n', ...
            subjID, sessID, runID);
        continue;
    end

    relOut = tbl.path_out(i);   % string, e.g. "data/source/sub-XX/ses-YY/eeg"
    vhdr   = tbl.vhdr(i);       % string, e.g. "BB16...vhdr"

    % Convert to char for compatibility with EEGLAB/file I/O
    relOutChar = char(relOut);
    vhdrChar   = char(vhdr);

    vhdrDir  = fullfile(baseDir, relOutChar);
    vhdrFile = fullfile(vhdrDir, vhdrChar);

    if ~isfile(vhdrFile)
        error('GetOriginalEvents:VHDRMissing', ...
            'VHDR file not found for sub-%s, ses-%s, run %s: %s', ...
            subjID, sessID, runID, vhdrFile);
    end

    fprintf('Reading events: sub-%s, ses-%s, run %s\n', subjID, sessID, runID);

    [vhdrFolder, vhdrName, vhdrExt] = fileparts(vhdrFile);  % chars
    EEG = pop_loadbv(vhdrFolder, [vhdrName vhdrExt]);
    EEG = eeg_checkset(EEG);

    % Extract event types, trimming leading/trailing whitespace only
    if isfield(EEG, 'event') && ~isempty(EEG.event)
        types = string({EEG.event.type}).';
        types = strtrim(types);
    else
        types = strings(0, 1);
    end

    % Write per-file CSV: single column, no header, one type per row
    nameStem = "sub-" + subjID + "_ses-" + sessID + "_run-" + runID;
    outFile  = fullfile(eventsRoot, nameStem + "_eeg_event_types_original.csv");
    writecell(cellstr(types), outFile);

    % Per-row unique type summary for dataset_list_prelim.xlsx
    if isempty(types)
        eventTypesCol(i) = "";
    else
        uniqueTypes = unique(types);  % includes empty string if present
        eventTypesCol(i) = strjoin(uniqueTypes, '; ');
    end

    % Append all event instances to global list
    allTypes = [allTypes; types]; %#ok<AGROW>
end

%% 5. Update dataset_list_prelim.xlsx

tbl.event_types_original = eventTypesCol;

if ~ismember("latency_correct", tbl.Properties.VariableNames)
    tbl.latency_correct = strings(nRows, 1);
else
    % Ensure latency_correct is string
    colData = tbl.latency_correct;
    if isnumeric(colData)
        tbl.latency_correct = strings(nRows, 1);
    else
        tbl.latency_correct = string(colData);
    end
end

writetable(tbl, dataListsPath);
fprintf('Updated dataset_list_prelim.xlsx with event_types_original column.\n');

%% 6. Build global summary and write event_types_original_summary.csv

summaryPath = fullfile(eventsRoot, 'event_types_original_summary.csv');

if isempty(allTypes)
    % Create an empty summary table with the correct columns
    summaryTbl = table;
    summaryTbl.Type_original        = strings(0, 1);
    summaryTbl.TotalOccurrences     = zeros(0, 1);
    summaryTbl.FilesContainingEvent = zeros(0, 1);
    summaryTbl.Type_new             = strings(0, 1);
    summaryTbl.Filter_AND           = strings(0, 1);
    summaryTbl.Filter_OR            = strings(0, 1);
    summaryTbl.Filter_NOT           = strings(0, 1);
    summaryTbl.LatencyCorrect       = strings(0, 1);

    writetable(summaryTbl, summaryPath);
    fprintf('No events found in any file. Wrote empty summary to: %s\n', summaryPath);
    log_command_window('stop');
    return;
end

% Unique types and total occurrences
[uniqTypes, ~, idx] = unique(allTypes);
counts = accumarray(idx, 1);

% FilesContainingEvent: for each unique type, count how many rows contain it at least once
filesContaining = zeros(numel(uniqTypes), 1);

for j = 1:numel(uniqTypes)
    currentType = uniqTypes(j);
    matches = false(nRows, 1);

    for i = 1:nRows
        if strlength(eventTypesCol(i)) == 0
            continue;
        end

        typesInRow = strtrim(split(eventTypesCol(i), ';'));
        if any(typesInRow == currentType)
            matches(i) = true;
        end
    end

    filesContaining(j) = sum(matches);
end

% Build summary table
summaryTbl = table;
summaryTbl.Type_original        = uniqTypes;
summaryTbl.TotalOccurrences     = counts;
summaryTbl.FilesContainingEvent = filesContaining;
summaryTbl.Type_new             = repmat("", numel(uniqTypes), 1);
summaryTbl.Filter_AND           = repmat("", numel(uniqTypes), 1);
summaryTbl.Filter_OR            = repmat("", numel(uniqTypes), 1);
summaryTbl.Filter_NOT           = repmat("", numel(uniqTypes), 1);
summaryTbl.LatencyCorrect       = repmat("", numel(uniqTypes), 1);

writetable(summaryTbl, summaryPath);
fprintf('Wrote event type summary to: %s\n', summaryPath);

log_command_window('stop');