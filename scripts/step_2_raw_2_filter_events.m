%% step_2_raw_2_filter_events.m
% Filter Strasbourg recordings based on original event types.
%
% Purpose:
%   - Read dataset_list_prelim.xlsx
%   - Evaluate each row's event type list against logical filters defined in
%     data/info_prelim/event_types_original/event_types_original_summary.csv
%     (Filter_AND / Filter_OR / Filter_NOT)
%   - Append/overwrite a column 'event_missing' in dataset_list_prelim.xlsx:
%       ""        -> row passes filters (keep for downstream analysis)
%       "missing" -> row fails filters (exclude downstream)
%
% Notes:
%   - Exact, case-sensitive matching of event type names (after trimming).
%   - Rows with missing EEG files (vhdr/vmrk/dat) are skipped and left as "".
%   - Empty filter columns are ignored (i.e., no constraint).
%   - For Filter_OR:
%       * If used, at least two event types must be marked with "1";
%         if exactly one is marked, the script errors.

log_command_window('start');
clear; clc;

%% 1. Paths

baseDir      = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
fileListPath = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');
mappingPath  = fullfile(baseDir, 'data', 'info_prelim', ...
    'event_types_original', 'event_types_original_summary.csv');

if ~isfile(fileListPath)
    error('FilterEvents:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', fileListPath);
end

if ~isfile(mappingPath)
    error('FilterEvents:MappingMissing', ...
        'event_types_original_summary.csv not found at: %s', mappingPath);
end

%% 2. Load dataset_list_prelim.xlsx

fprintf('Loading: %s\n', fileListPath);

optsList = detectImportOptions(fileListPath, 'PreserveVariableNames', true);

% Ensure relevant columns are read as strings
forceStrCols = {'event_types_original','vhdr_missing','vmrk_missing','dat_missing'};
for k = 1:numel(forceStrCols)
    colName = forceStrCols{k};
    if any(strcmpi(optsList.VariableNames, colName))
        optsList = setvaropts(optsList, colName, 'Type', 'string');
    end
end

T = readtable(fileListPath, optsList);

requiredCols = {'event_types_original','vhdr_missing','vmrk_missing','dat_missing'};
missingCols = setdiff(requiredCols, T.Properties.VariableNames);
if ~isempty(missingCols)
    error('FilterEvents:MissingColumns', ...
        'Missing required column(s) in dataset_list_prelim.xlsx: %s', ...
        strjoin(missingCols, ', '));
end

% Normalise the *_missing columns as strings in case detectImportOptions mis-guesses
nRows = height(T);
for colName = ["vhdr_missing","vmrk_missing","dat_missing"]
    colData = T.(colName);
    if isnumeric(colData)
        T.(colName) = strings(nRows, 1);
    else
        T.(colName) = string(colData);
    end
end

% Create/initialise the output column (overwrite if it already exists)
T.event_missing = strings(nRows, 1);

%% 3. Load event_types_original_summary.csv

fprintf('Loading: %s\n', mappingPath);

optsMap = detectImportOptions(mappingPath, ...
    'PreserveVariableNames', true, ...
    'TextType', 'string');

expectedMapCols = {'Type_original','Filter_AND','Filter_OR','Filter_NOT'};
for k = 1:numel(expectedMapCols)
    colName = expectedMapCols{k};
    if ~any(strcmpi(optsMap.VariableNames, colName))
        error('FilterEvents:MappingMissingColumns', ...
            'Missing required column in mapping file: %s', colName);
    end
    optsMap = setvaropts(optsMap, colName, 'Type', 'string');
end

M = readtable(mappingPath, optsMap);

% Normalise whitespace
M.Type_original = strtrim(M.Type_original);
M.Filter_AND    = strtrim(M.Filter_AND);
M.Filter_OR     = strtrim(M.Filter_OR);
M.Filter_NOT    = strtrim(M.Filter_NOT);

% Helper: treat exact "1" as true, everything else as false
toBool = @(x) (x == "1");

andMask = toBool(M.Filter_AND);
orMask  = toBool(M.Filter_OR);
notMask = toBool(M.Filter_NOT);

AND_set = M.Type_original(andMask);
OR_set  = M.Type_original(orMask);
NOT_set = M.Type_original(notMask);

fprintf('Active filters: AND=%d, OR=%d, NOT=%d\n', numel(AND_set), numel(OR_set), numel(NOT_set));
if isempty(AND_set) && isempty(OR_set) && isempty(NOT_set)
    fprintf('Note: No active filters (AND/OR/NOT all empty). All eligible rows will pass.\n');
end

%% 4. Evaluate each row

N       = height(T);
checked = 0;
flagged = 0;

for i = 1:N
    % Skip rows with missing EEG files (this script does not judge these)
    if T.vhdr_missing(i) == "missing" || ...
            T.vmrk_missing(i) == "missing" || ...
            T.dat_missing(i)  == "missing"
        % Leave event_missing(i) as "" and continue
        continue;
    end

    % Parse this row's event types (semicolon-separated)
    typeStr = T.event_types_original(i);

    if ismissing(typeStr) || typeStr == ""
        thisSet = string([]);   % no event types in this row
    else
        tmp = split(string(typeStr), ';');
        tmp = strtrim(tmp);
        thisSet = unique(string(tmp));
        % Drop empty tokens and <missing>
        thisSet = thisSet(thisSet ~= "" & ~ismissing(thisSet));
    end

    % Evaluate filters
    pass = true;

    % AND: all must be present (if AND_set non-empty)
    if ~isempty(AND_set)
        if ~all(ismember(AND_set, thisSet))
            pass = false;
        end
    end

    % OR: at least one must be present (if OR_set non-empty)
    if pass && ~isempty(OR_set)

        % Enforce rule: OR_set must have at least 2 entries
        if isscalar(OR_set)
            error(['FilterEvents:InvalidFilterOR - Invalid Filter_OR: only one event type ("%s") is marked. ', ...
                'You must mark at least two event types for an OR rule, or leave all Filter_OR cells blank.'], OR_set);
        end

        if ~any(ismember(OR_set, thisSet))
            pass = false;
        end
    end

    % NOT: none may be present (if NOT_set non-empty)
    if pass && ~isempty(NOT_set)
        if any(ismember(NOT_set, thisSet))
            pass = false;
        end
    end

    % Write result
    checked = checked + 1;
    if ~pass
        T.event_missing(i) = "missing";
        flagged = flagged + 1;
    else
        T.event_missing(i) = "";  % explicitly blank
    end
end

%% 5. Save updated dataset_list_prelim.xlsx

writetable(T, fileListPath);
fprintf('Done. Checked %d rows; flagged %d rows as event_missing.\n', checked, flagged);

log_command_window('stop');