%% step_3_proc_2_get_channels.m
% Purpose:
%   - Create data/info/channels/
%   - For each raw .set file listed in dataset_list.csv (ALL rows are included):
%       * Extract channel labels:
%           - Write per-file CSV with the full list of channel labels (not deduplicated, no header, case preserved)
%           - Add a semicolon-separated unique (alphabetical) channel list to dataset_list.csv ('channels' column)
%   - Build a global summary at data/info/channels/channel_summary.csv with columns:
%       Channel | TotalOccurrences | FilesContainingChannel
%
% Inclusion / exclusion:
%   - All rows in dataset_list.csv are treated as included recordings.
%
% Behaviour:
%   - Fail fast if any required column is missing
%   - Fail fast if any row has blank path_raw or EEGfile_raw (after trimming)
%   - Fail fast if a listed .set file is missing or unreadable
%   - Idempotent: safe to re-run (rewrites per-file CSVs, recomputes summary, rewrites 'channels' column)
%   - Requires EEGLAB on path

log_command_window('start');
clear; clc;

%% Project paths
baseDir         = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
dataListPath    = fullfile(baseDir, 'data_lists', 'dataset_list.csv');
processedRoot   = fullfile(baseDir, 'data', 'info');
channelsFolder  = fullfile(processedRoot, 'channels');

% Ensure output folders exist
if ~exist(processedRoot, 'dir'),  mkdir(processedRoot);  end
if ~exist(channelsFolder, 'dir'), mkdir(channelsFolder); end

%% Ensure EEGLAB is available
assert(exist('eeglab','file') == 2, 'EEGLAB not found on path.');
eeglab;
assert(exist('pop_loadset','file') == 2, 'pop_loadset not found after launching EEGLAB.');

%% Load dataset_list.csv
fprintf('Loading dataset list...\n');
if ~isfile(dataListPath)
    error('dataset_list.csv not found: %s', dataListPath);
end

opts = detectImportOptions(dataListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');

% Validate required columns
requiredCols = {'subjectID','sessionID','runID','path_raw','EEGfile_raw'};
missingCols  = setdiff(requiredCols, opts.VariableNames);
if ~isempty(missingCols)
    error('Missing required columns in dataset_list.csv: %s', strjoin(missingCols, ', '));
end

% Force ALL columns to import as string (prevents loss of leading zeros, digit-only IDs, etc.)
opts = setvartype(opts, opts.VariableNames, 'string');

T = readtable(dataListPath, opts);

% Normalise required columns: string, missing->"", trim whitespace
for k = 1:numel(requiredCols)
    v = requiredCols{k};
    s = string(T.(v));
    s(ismissing(s)) = "";
    s = strtrim(s);
    s(lower(s) == "nan") = "";
    T.(v) = s;
end

N = height(T);

% Validate non-blank path_raw and EEGfile_raw for ALL rows
blankPath = (T.path_raw == "");
blankFile = (T.EEGfile_raw == "");

if any(blankPath | blankFile)
    idx = find(blankPath | blankFile);
    exampleN = min(10, numel(idx));
    examples = strings(exampleN,1);
    for i = 1:exampleN
        r = idx(i);
        examples(i) = sprintf('Row %d: path_raw="%s" | EEGfile_raw="%s"', r, T.path_raw(r), T.EEGfile_raw(r));
    end
    msg = sprintf([ ...
        'Blank path_raw and/or EEGfile_raw detected in dataset_list.csv. These must be non-blank for all rows.\n' ...
        'First %d offending row(s):\n  - %s'], ...
        exampleN, strjoin(examples, '\n  - '));
    error('%s', msg);
end

%% Prepare per-row output accumulator for dataset_list.csv 'channels' column
channels_col = strings(N,1);

%% Prepare global accumulators for summary
% - totalCounts: Channel -> total occurrences across all files (counts duplicates within a file)
% - filesSeen:   Channel -> set of file stems that contained it at least once
totalCounts = containers.Map('KeyType','char','ValueType','double');
filesSeen   = containers.Map('KeyType','char','ValueType','any');  % values: containers.Map(fileStem->true)

%% Iterate rows (ALL rows are included)
checked = 0;

for r = 1:N

    relPathRaw = T.path_raw(r);      % e.g., data/raw/sub-.../ses-.../eeg
    setName    = T.EEGfile_raw(r);   % e.g., sub-..._eeg.set

    fullSet = fullfile(baseDir, relPathRaw, setName);
    if ~isfile(fullSet)
        error('Missing .set file at row %d: %s', r, fullSet);
    end

    % Load .set in metadata-only mode if available; otherwise full load
    [setFolderAbs, setFileAbs, setExtAbs] = fileparts(fullSet);
    try
        EEG = pop_loadset('filename', char(string(setFileAbs) + string(setExtAbs)), ...
            'filepath', char(setFolderAbs), ...
            'loadmode', 'info');  % metadata only
    catch
        EEG = pop_loadset('filename', char(string(setFileAbs) + string(setExtAbs)), ...
            'filepath', char(setFolderAbs));         % full load fallback
    end

    % Extract channel labels (trim whitespace; drop empties; preserve case)
    chFull = strings(0,1);
    if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs)
        try
            chFull = string({EEG.chanlocs.labels});
        catch
            tmp = strings(numel(EEG.chanlocs),1);
            for k = 1:numel(EEG.chanlocs)
                if isfield(EEG.chanlocs(k),'labels') && ~isempty(EEG.chanlocs(k).labels)
                    tmp(k) = string(EEG.chanlocs(k).labels);
                else
                    tmp(k) = "";
                end
            end
            chFull = tmp;
        end
    end
    chFull = string(chFull);        % ensure string
    chFull = chFull(:);             % force column
    chFull = strtrim(chFull);       % trim spaces
    chFull = chFull(strlength(chFull) > 0);  % drop empties

    % Per-file CSV (NOT deduplicated; no header)
    stem = erase(setName, '.set');
    perFileCSV = fullfile(channelsFolder, char(stem + "_channels.csv"));
    if isempty(chFull)
        fid = fopen(perFileCSV, 'w'); fclose(fid);
    else
        writecell(cellstr(chFull), perFileCSV);
    end

    % dataset_list.csv column: UNIQUE (alphabetical), semicolon-separated
    if isempty(chFull)
        channels_col(r) = "";
    else
        chUnique = unique(chFull);
        chUnique = sort(chUnique);               % alphabetical, case preserved
        channels_col(r) = strjoin(chUnique, '; ');
    end

    % Global accumulators
    for k = 1:numel(chFull)
        key = char(chFull(k));
        if isKey(totalCounts, key)
            totalCounts(key) = totalCounts(key) + 1;
        else
            totalCounts(key) = 1;
        end
    end

    presentUnique = unique(chFull);
    for k = 1:numel(presentUnique)
        key = char(presentUnique(k));
        if ~isKey(filesSeen, key)
            filesSeen(key) = containers.Map('KeyType','char','ValueType','logical');
        end
        fileMap = filesSeen(key);
        fileMap(char(stem)) = true;
        filesSeen(key) = fileMap;
    end

    checked = checked + 1;
    fprintf('[%d/%d] channels extracted: %s\n', checked, N, setName);
end

%% Build and write channel_summary.csv (NO Filter_* columns)
% Assemble summary table (alphabetical by Channel)
chKeys = totalCounts.keys;  % cell array of channel strings

if isempty(chKeys)
    % Empty summary with correct headers
    summaryTbl = table( ...
        string.empty(0,1), ...   % Channel
        zeros(0,1), ...          % TotalOccurrences
        zeros(0,1), ...          % FilesContainingChannel
        'VariableNames', {'Channel','TotalOccurrences','FilesContainingChannel'});
else
    chKeysStr = string(chKeys(:));
    totalArr  = zeros(numel(chKeysStr),1);
    filesArr  = zeros(numel(chKeysStr),1);

    for i = 1:numel(chKeysStr)
        key = char(chKeysStr(i));
        totalArr(i) = totalCounts(key);
        filesArr(i) = numel(keys(filesSeen(key)));
    end

    summaryTbl = table(chKeysStr, totalArr, filesArr, ...
        'VariableNames', {'Channel','TotalOccurrences','FilesContainingChannel'});

    summaryTbl = sortrows(summaryTbl, 'Channel');  % alphabetical
end

summaryOut = fullfile(channelsFolder, 'channel_summary.csv');
writetable(summaryTbl, summaryOut);

%% Update dataset_list.csv: add/overwrite 'channels' (at the END)
if ismember('channels', T.Properties.VariableNames)
    T = removevars(T, {'channels'});
end
T.channels = channels_col;

writetable(T, dataListPath);

fprintf('Done. Processed %d rows. Summary written to %s\n', checked, summaryOut);

log_command_window('stop');