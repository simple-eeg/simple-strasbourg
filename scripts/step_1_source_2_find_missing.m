%% step_1_source_2_find_missing.m
% Update EEG file list with missing-file flags for Strasbourg BrainVision data.
% - Reads dataset_list_prelim.xlsx from data_lists/.
% - For each row, checks whether vhdr, vmrk, and dat exist at path_in.
% - Adds/updates vhdr_missing, vmrk_missing, dat_missing columns:
%       ""        → file present
%       "missing" → file not found
% - Overwrites dataset_list_prelim.xlsx with the updated table.
%
% No files are copied here. This script only annotates the file list.

log_command_window('start');
clear; clc;

%% 1. Define paths

local_base     = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
data_lists_dir = fullfile(local_base, 'data_lists');
eeg_file       = fullfile(data_lists_dir, 'dataset_list_prelim.xlsx');

%% 2. Basic checks

% Check data_lists directory exists
if ~isfolder(data_lists_dir)
    error('FindMissing:DataListsMissing', ...
        'Data lists directory does not exist: %s', data_lists_dir);
end

% Check dataset_list_prelim.xlsx exists
if ~isfile(eeg_file)
    error('FindMissing:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', eeg_file);
end

%% 3. Read existing table

eeg_table = readtable(eeg_file, ...
    'PreserveVariableNames', true, ...
    'TextType', 'string');

% Expect these columns (created by step_1_source_1_create_list.m)
required_cols = ["subjectID", "sessionID", "runID", "format", ...
    "vhdr", "vmrk", "dat", "path_in", "path_out"];

missing_required = required_cols(~ismember(required_cols, eeg_table.Properties.VariableNames));
if ~isempty(missing_required)
    error('FindMissing:MissingColumns', ...
        'The following required column(s) are missing from dataset_list_prelim.xlsx: %s', ...
        strjoin(cellstr(missing_required), ', '));
end

%% 4. Ensure *_missing columns exist (or reset them)

n_rows = height(eeg_table);

missing_cols = ["vhdr_missing", "vmrk_missing", "dat_missing"];

for c = 1:numel(missing_cols)
    col = missing_cols(c);
    if ~ismember(col, eeg_table.Properties.VariableNames)
        % Add as empty string column
        eeg_table.(col) = strings(n_rows, 1);
    else
        % Reset all entries to empty; will be recomputed below
        eeg_table.(col)(:) = "";
    end
end

%% 5. Loop over rows and check file existence

for i = 1:n_rows
    path_in  = eeg_table.path_in(i);   % string
    vhdrName = eeg_table.vhdr(i);      % string
    vmrkName = eeg_table.vmrk(i);      % string
    datName  = eeg_table.dat(i);       % string

    % Build full paths
    full_vhdr = fullfile(path_in, vhdrName);
    full_vmrk = fullfile(path_in, vmrkName);
    full_dat  = fullfile(path_in, datName);

    % Check existence; exist() accepts string paths in recent MATLAB
    if exist(full_vhdr, 'file') == 2
        eeg_table.vhdr_missing(i) = "";
    else
        eeg_table.vhdr_missing(i) = "missing";
    end

    if exist(full_vmrk, 'file') == 2
        eeg_table.vmrk_missing(i) = "";
    else
        eeg_table.vmrk_missing(i) = "missing";
    end

    if exist(full_dat, 'file') == 2
        eeg_table.dat_missing(i) = "";
    else
        eeg_table.dat_missing(i) = "missing";
    end
end

%% 6. Compute summary stats

has_missing = (eeg_table.vhdr_missing == "missing") | ...
    (eeg_table.vmrk_missing == "missing") | ...
    (eeg_table.dat_missing  == "missing");

n_rows_with_missing = sum(has_missing);

%% 7. Write updated table

writetable(eeg_table, eeg_file);

fprintf('Updated EEG file list: %d row(s) with missing data files out of %d total.\n', ...
    n_rows_with_missing, n_rows);

log_command_window('stop');