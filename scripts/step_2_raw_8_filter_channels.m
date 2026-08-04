%% step_2_raw_8_filter_channels.m
% Purpose:
%   - Read dataset_list_prelim.xlsx
%   - Evaluate each row's channel list against logical filters defined in
%     data/info_prelim/channels/channel_summary.csv (Filter_AND / Filter_OR / Filter_NOT)
%   - Append a new column 'channel_exclusion' to dataset_list_prelim.xlsx:
%       ""          -> row passes filters (keep)
%       "excluded"  -> row fails filters (exclude downstream)
%
% Notes:
%   - Exact, case-sensitive matching of channel names
%   - Rows already excluded upstream (excluded_datasets == "excluded", case-insensitive) are skipped and left blank
%   - Empty filter columns are ignored (i.e., no constraint)
%   - If Filter_OR marks exactly one channel, the script errors (users should use AND for single requirements)

log_command_window('start');
clear; clc;

%% Paths
baseDir       = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
fileListPath  = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');
summaryPath   = fullfile(baseDir, 'data', 'info_prelim', 'channels', 'channel_summary.csv');

%% Load dataset_list_prelim.xlsx
fprintf('Loading: %s\n', fileListPath);
optsList = detectImportOptions(fileListPath, 'PreserveVariableNames', true, 'TextType', 'string');

% Force critical columns to string (if present)
forceStrCols = {'excluded_datasets','channels','channel_exclusion'};
for k = 1:numel(forceStrCols)
    if any(strcmpi(optsList.VariableNames, forceStrCols{k}))
        optsList = setvaropts(optsList, forceStrCols{k}, 'Type', 'string');
    end
end

T = readtable(fileListPath, optsList);

% Ensure required columns exist
requiredCols = {'excluded_datasets','channels'};
missingCols = setdiff(requiredCols, T.Properties.VariableNames);
if ~isempty(missingCols)
    error('Missing required columns in dataset_list_prelim.xlsx: %s', strjoin(missingCols, ', '));
end

% Create/initialize the output column (overwrite if it already exists)
T.channel_exclusion = strings(height(T), 1);

%% Load channel_summary.csv
fprintf('Loading: %s\n', summaryPath);
optsSum = detectImportOptions(summaryPath, 'PreserveVariableNames', true, 'TextType', 'string');

% Ensure expected columns exist and read as string
expectedSumCols = {'Channel','Filter_AND','Filter_OR','Filter_NOT'};
for k = 1:numel(expectedSumCols)
    if ~any(strcmpi(optsSum.VariableNames, expectedSumCols{k}))
        error('Missing required column in channel_summary.csv: %s', expectedSumCols{k});
    end
    optsSum = setvaropts(optsSum, expectedSumCols{k}, 'Type', 'string');
end

M = readtable(summaryPath, optsSum);

% Trim whitespace (defensive)
M.Channel     = strtrim(M.Channel);
M.Filter_AND  = strtrim(M.Filter_AND);
M.Filter_OR   = strtrim(M.Filter_OR);
M.Filter_NOT  = strtrim(M.Filter_NOT);

% Normalize filter flags to logicals: exact "1" means true; anything else false
toBool  = @(x) (x == "1");

AND_set = M.Channel(toBool(M.Filter_AND));
OR_set  = M.Channel(toBool(M.Filter_OR));
NOT_set = M.Channel(toBool(M.Filter_NOT));

fprintf('Active filters: AND=%d, OR=%d, NOT=%d\n', numel(AND_set), numel(OR_set), numel(NOT_set));
if isempty(AND_set) && isempty(OR_set) && isempty(NOT_set)
    fprintf('Note: No active filters (AND/OR/NOT all empty). All eligible rows will pass.\n');
end

%% Evaluate each row
N = height(T);
checked = 0;
flagged = 0;

for i = 1:N
    % Skip rows already excluded upstream (leave channel_exclusion blank)
    exclUpstream = "";
    if ~ismissing(T.excluded_datasets(i)) && ~isempty(T.excluded_datasets(i))
        exclUpstream = lower(string(T.excluded_datasets(i)));
    end
    if contains(exclUpstream, "excluded")
        continue;
    end

    % Parse this row's channels (semicolon-separated, already unique from step 3.1)
    chanStr = T.channels(i);
    if ismissing(chanStr) || chanStr == ""
        thisSet = string([]);   % no channels listed for this row
    else
        toks = string(strtrim(split(string(chanStr), ';')));
        toks = toks(~ismissing(toks) & toks ~= "");
        thisSet = unique(toks); % dedupe to a set
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
        % Guard: OR_set must have at least two entries
        if isscalar(OR_set)
            error(['Invalid Filter_OR: only one channel ("%s") is marked. ', ...
                'Mark at least two channels for an OR rule, or leave OR blank.'], OR_set);
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
        T.channel_exclusion(i) = "excluded";
        flagged = flagged + 1;
    else
        T.channel_exclusion(i) = "";
    end
end

%% Save table (overwrite)
writetable(T, fileListPath);
fprintf('Done. Checked %d rows; flagged %d rows as channel_exclusion.\n', checked, flagged);

log_command_window('stop');
