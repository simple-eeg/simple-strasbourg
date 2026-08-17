%% step_5_sum_1_add_summaries.m
% Purpose:
%   - Read dataset_list.csv
%   - Create/overwrite a new column 'path_summary' by transforming
%       path_processed: '^data/processed' -> 'data/summary'
%   - Remove any existing 'path_summary' column first, then append it at the end
%
% Notes:
%   - Idempotent: column is rebuilt from path_processed on every run
%   - No folder creation here
%   - Validates every input and derived output before rewriting the table

log_command_window('start');
clear; clc;

%% Paths
baseDir      = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
fileListPath = fullfile(baseDir, 'data_lists', 'dataset_list.csv');
functionsDir = fullfile(baseDir, 'functions');

addpath(functionsDir, '-begin');
clear validate_dataset_registry_paths;
rehash;
expectedValidator = fullfile(functionsDir, 'validate_dataset_registry_paths.m');
resolvedValidator = which('validate_dataset_registry_paths');
assert(~isempty(resolvedValidator) && ...
    strcmp(char(java.io.File(resolvedValidator).getCanonicalPath()), ...
           char(java.io.File(expectedValidator).getCanonicalPath())), ...
    'Repository-local dataset-registry validator did not resolve canonically.');

fprintf('Loading: %s\n', fileListPath);

%% Load spreadsheet with string-preserving options (force ALL columns to string)
opts = detectImportOptions(fileListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');

% Force every column to import as string (prevents loss of leading zeros, digit-only IDs, etc.)
opts = setvartype(opts, opts.VariableNames, 'string');

T = readtable(fileListPath, opts);

%% Validate required input column
if ~any(strcmp(T.Properties.VariableNames, 'path_processed'))
    error('Missing required column in dataset_list.csv: path_processed');
end

%% Normalize input
T.path_processed = string(T.path_processed);
T.path_processed(ismissing(T.path_processed)) = "";

validate_dataset_registry_paths(T, baseDir, 'processed');

%% Prepare output
N = height(T);
path_summary   = strings(N,1);
updated        = 0;

%% Build path_summary from path_processed
for r = 1:N
    p = strtrim(T.path_processed(r));

    path_summary(r) = regexprep(p, '^data/processed', 'data/summary');
    updated = updated + 1;
end

%% Append/overwrite column at the END (keep stable order)
if any(strcmp(T.Properties.VariableNames, 'path_summary'))
    T = removevars(T, 'path_summary');
end
T.path_summary = path_summary;

validate_dataset_registry_paths(T, baseDir, 'summary');

%% Save
writetable(T, fileListPath);

%% Summary
fprintf('Done. path_summary updated/appended.\n');
fprintf('  Updated (from data/processed): %d\n', updated);
fprintf('  Total rows: %d\n', N);

log_command_window('stop');
