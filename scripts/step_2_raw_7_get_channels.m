%% step_2_raw_7_get_channels.m
% Purpose:
%   - Create data/info_prelim/channels/
%   - For each included raw .set file, extract channel labels:
%       * Write per-file CSV with the full list of channel labels (not deduplicated, no header, case preserved)
%       * Add a semicolon-separated unique (alphabetical) channel list to dataset_list_prelim.xlsx ('channels' column)
%   - Build a global summary at data/info_prelim/channels/channel_summary.csv with columns:
%       Channel | TotalOccurrences | FilesContainingChannel | Filter_AND | Filter_OR | Filter_NOT
%       * Filter_* columns are created empty as user-editable placeholders
%
% Inclusion / exclusion:
%   - A spreadsheet row is included if 'excluded_datasets' is blank/absent (case-insensitive check)
%   - Excluded rows are skipped and their 'channels' cell is left blank
%
% Behavior:
%   - Fail fast if an included .set file is missing or unreadable
%   - Idempotent: safe to re-run (rewrites per-file CSVs, recomputes summary, rewrites 'channels' column)
%   - Requires EEGLAB on path; launches headless (nogui)

log_command_window('start');
clear; clc;

%% Project paths
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
dataListPath    = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');
processedRoot   = fullfile(baseDir, 'data', 'info_prelim');
channelsFolder  = fullfile(processedRoot, 'channels');

% Ensure output folders exist
if ~exist(processedRoot, 'dir'),  mkdir(processedRoot);  end
if ~exist(channelsFolder, 'dir'), mkdir(channelsFolder); end

%% Ensure EEGLAB is available
assert(exist('eeglab','file') == 2, 'EEGLAB not found on path.');
eeglab;
assert(exist('pop_loadset','file') == 2, 'pop_loadset not found after launching EEGLAB.');

%% Load dataset_list_prelim.xlsx
fprintf('Loading EEG file list...\n');
opts = detectImportOptions(dataListPath, 'PreserveVariableNames', true, 'TextType', 'string');

% Ensure critical columns read as string
mustBeString = {'excluded_datasets','EEGfile_reformatted','path_reformatted'};
for k = 1:numel(mustBeString)
    if any(strcmpi(opts.VariableNames, mustBeString{k}))
        opts = setvaropts(opts, mustBeString{k}, 'Type', 'string');
    end
end

T = readtable(dataListPath, opts);

% Validate required columns
requiredCols = {'excluded_datasets','EEGfile_reformatted','path_reformatted'};
missingCols  = setdiff(requiredCols, T.Properties.VariableNames);
if ~isempty(missingCols)
    error('Missing required columns in dataset_list_prelim.xlsx: %s', strjoin(missingCols, ', '));
end

N = height(T);

%% Prepare per-row output accumulator for spreadsheet 'channels' column
channels_col = strings(N,1);

%% Prepare global accumulators for summary
% - totalCounts: Channel -> total occurrences across all included files (counts duplicates within a file)
% - filesSeen:   Channel -> set of file stems that contained it at least once
totalCounts = containers.Map('KeyType','char','ValueType','double');
filesSeen   = containers.Map('KeyType','char','ValueType','any');  % values: containers.Map(fileStem->true)

%% Iterate rows
checked = 0;

for r = 1:N

    % Skip rows marked as excluded (case-insensitive check)
    exclVal = "";
    if ~ismissing(T.excluded_datasets(r)) && ~isempty(T.excluded_datasets(r))
        exclVal = lower(string(T.excluded_datasets(r)));
    end
    if contains(exclVal, "excluded")
        channels_col(r) = "";  % leave blank for excluded rows
        continue;
    end

    relPathRaw = strtrim(string(T.path_reformatted(r)));    % e.g., data/raw/sub-.../ses-.../eeg
    setName    = strtrim(string(T.EEGfile_reformatted(r))); % e.g., sub-..._eeg.set

    if strlength(relPathRaw) == 0 || strlength(setName) == 0
        error('Row %d is included but has empty path_reformatted or EEGfile_reformatted.', r);
    end

    fullSet = fullfile(baseDir, relPathRaw, setName);
    if ~isfile(fullSet)
        error('Missing .set file at row %d: %s', r, fullSet);
    end

    % Load .set in metadata-only mode if available; otherwise full load
    [setFolderAbs, setFileAbs, setExtAbs] = fileparts(fullSet);
    try
        EEG = pop_loadset('filename', char(setFileAbs + setExtAbs), ...
            'filepath', char(setFolderAbs), ...
            'loadmode', 'info');  % metadata only
    catch
        EEG = pop_loadset('filename', char(setFileAbs + setExtAbs), ...
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

    % Spreadsheet column: UNIQUE (alphabetical), semicolon-separated
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

%% Build and write channel_summary.csv
% Assemble summary table (alphabetical by Channel)
chKeys = totalCounts.keys;  % cell array of channel strings

if isempty(chKeys)
    % Empty summary with correct headers
    summaryTbl = table( ...
        string.empty(0,1), ...   % Channel
        zeros(0,1), ...          % TotalOccurrences
        zeros(0,1), ...          % FilesContainingChannel
        string.empty(0,1), ...   % Filter_AND
        string.empty(0,1), ...   % Filter_OR
        string.empty(0,1), ...   % Filter_NOT
        'VariableNames', {'Channel','TotalOccurrences','FilesContainingChannel','Filter_AND','Filter_OR','Filter_NOT'});
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
        repmat("", numel(chKeysStr), 1), ...  % Filter_AND (empty)
        repmat("", numel(chKeysStr), 1), ...  % Filter_OR  (empty)
        repmat("", numel(chKeysStr), 1), ...  % Filter_NOT (empty)
        'VariableNames', {'Channel','TotalOccurrences','FilesContainingChannel','Filter_AND','Filter_OR','Filter_NOT'});

    summaryTbl = sortrows(summaryTbl, 'Channel');  % alphabetical
end

summaryOut = fullfile(channelsFolder, 'channel_summary.csv');
writetable(summaryTbl, summaryOut);

%% Update spreadsheet: add/overwrite 'channels' (at the END)
toRemove = intersect({'channels'}, T.Properties.VariableNames);
if ~isempty(toRemove)
    T = removevars(T, toRemove);
end
T.channels = channels_col;

writetable(T, dataListPath);

fprintf('Done. Processed %d included rows. Summary written to %s\n', checked, summaryOut);

log_command_window('stop');
