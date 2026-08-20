%% step_1_source_1_create_dataset_list_prelim.m
% Create an EEG file list for Strasbourg BrainVision data.
% - Scans the flat BrainVision export folder for .vhdr files.
% - Derives subjectID, sessionID, and runID from filenames.
% - Predicts the corresponding .vmrk and .dat filenames.
% - Writes dataset_list_prelim.xlsx into data_lists/.
%
% No files are copied, and no existence checks are made for .vmrk/.dat.
% That is handled by later scripts in the workflow.

log_command_window('start');
clear; clc;

%% 1. Define paths and constants

% Local project root and external source folder
local_base  = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
remote_base = '<EDIT_APPROVED_EXTERNAL_SOURCE_ROOT>';

data_lists_dir = fullfile(local_base, 'data_lists');
output_file    = fullfile(data_lists_dir, 'dataset_list_prelim.xlsx');

format_value = "BrainVision";

%% 2. Basic checks and setup

% Replace the placeholder locally with the approved source folder. Its private
% path is intentionally neither stored in this repository nor printed on failure.
if strcmp(remote_base, '<EDIT_APPROVED_EXTERNAL_SOURCE_ROOT>') || ~isfolder(remote_base)
    error('step_1_source_1_create_list:RemoteMissing', ...
        ['Set remote_base to the approved external source folder before running. ', ...
        'The configured source folder is unavailable; its path is not displayed.']);
end

% Ensure data_lists directory exists
if ~isfolder(data_lists_dir)
    ok = mkdir(data_lists_dir);
    if ~ok
        error('step_1_source_1_create_list:MakeDataListsFailed', ...
            'Failed to create data_lists directory: %s', data_lists_dir);
    end
end

% If dataset_list_prelim.xlsx already exists, warn and stop
if exist(output_file, 'file')
    fprintf(['[step_1_source_1_create_list] dataset_list_prelim.xlsx already exists:\n', ...
        '  %s\n', ...
        'Please delete or rename it, then rerun this script.\n'], output_file);
    error('step_1_source_1_create_list:OutputExists', ...
        'dataset_list_prelim.xlsx already exists; aborting to avoid overwrite.');
end

%% 3. Discover primary BrainVision files (.vhdr)

dir_listing = dir(remote_base);

% Keep only files, not directories
is_file = ~[dir_listing.isdir];
dir_listing = dir_listing(is_file);

% Keep only exact ".vhdr" (lowercase) files
all_names = {dir_listing.name};
is_vhdr = endsWith(all_names, '.vhdr');
vhdr_files = dir_listing(is_vhdr);

if isempty(vhdr_files)
    error('step_1_source_1_create_list:NoVHDR', ...
        'No lowercase .vhdr files were found in the configured source folder.');
end

%% 4. Prepare table for output

var_names = {'subjectID', 'sessionID', 'runID', 'format', ...
    'vhdr', 'vmrk', 'dat', 'path_in', 'path_out'};

var_types = repmat("string", 1, numel(var_names));

eeg_table = table('Size', [0, numel(var_names)], ...
    'VariableTypes', var_types, ...
    'VariableNames', var_names);

%% 5. Loop over .vhdr files and parse IDs

for k = 1:numel(vhdr_files)
    vhdr_name = vhdr_files(k).name;  % e.g. 'BB16Pnociprem36s_noci_Segmentation-stim1NoFilter.vhdr'

    % Strip extension to get basename
    if ~endsWith(vhdr_name, '.vhdr')
        % Defensive: should not happen given the filter above
        fprintf('[WARN] Skipping unexpected file (not .vhdr): %s\n', vhdr_name);
        continue;
    end
    basename = vhdr_name(1:end-5);  % remove ".vhdr"

    % -------- 5.1 Parse subjectID (first four characters, uppercased) --------
    if numel(basename) < 4
        fprintf(['[ERROR] Filename too short to contain subjectID (4 chars): %s\n'], vhdr_name);
        error('step_1_source_1_create_list:BadSubject', ...
            'Cannot derive subjectID from filename: %s', vhdr_name);
    end

    subject_raw = basename(1:4);
    subjectID   = upper(string(subject_raw));  % e.g. "BB16"

    % -------- 5.2 Parse runID (between last "-" and "NoFilter") --------
    dash_idx = find(basename == '-', 1, 'last');
    if isempty(dash_idx)
        fprintf(['[ERROR] No "-" found before runID in filename: %s\n'], vhdr_name);
        error('step_1_source_1_create_list:NoDash', ...
            'Cannot locate runID (missing "-") in basename: %s', basename);
    end

    if ~endsWith(basename, 'NoFilter')
        fprintf(['[ERROR] Basename does not end with "NoFilter": %s\n'], basename);
        error('step_1_source_1_create_list:NoNoFilter', ...
            'Expected suffix "-<run>NoFilter" in basename: %s', basename);
    end

    run_with_nf = basename(dash_idx+1:end);  % e.g. "stim1NoFilter"
    % Remove "NoFilter" tail
    run_core = extractBefore(run_with_nf, 'NoFilter');  % e.g. "stim1"
    if run_core == ""
        fprintf(['[ERROR] Could not extract runID between "-" and "NoFilter" in: %s\n'], basename);
        error('step_1_source_1_create_list:EmptyRun', ...
            'Empty runID between "-" and "NoFilter" in basename: %s', basename);
    end
    runID = lower(string(run_core));  % e.g. "stim1"

    % Full suffix to remove from the end of basename when deriving sessionID
    suffix_full = basename(dash_idx:end);  % e.g. "-stim1NoFilter"

    % -------- 5.3 Parse sessionID (middle chunk, cleaned and lowercased) -----
    % Characters for session core are between:
    %   subject_raw (first 4 chars) and suffix_full at the end
    start_idx = 5;
    end_idx   = length(basename) - length(suffix_full);

    if end_idx < start_idx
        fprintf(['[ERROR] Not enough characters to derive sessionID in basename: %s\n'], basename);
        error('step_1_source_1_create_list:BadSessionIndices', ...
            'Cannot derive sessionID (indices inverted) for basename: %s', basename);
    end

    session_core = basename(start_idx:end_idx);  % e.g. "Pnociprem36s_noci_Segmentation"

    % Remove literal substring "Segmentation"
    session_core = strrep(session_core, 'Segmentation', '');

    % Remove underscores and dashes
    session_core = strrep(session_core, '_', '');
    session_core = strrep(session_core, '-', '');

    % Lowercase result
    sessionID = lower(string(session_core));  % e.g. "pnociprem36snoci"

    if sessionID == ""
        fprintf(['[ERROR] Derived empty sessionID from basename: %s\n'], basename);
        error('step_1_source_1_create_list:EmptySession', ...
            'Empty sessionID after cleaning for basename: %s', basename);
    end

    % -------- 5.4 Predict filenames for all three BrainVision files --------
    vhdr = string(vhdr_name);                         % primary
    vmrk = string(basename + ".vmrk");
    dat  = string(basename + ".dat");

    % -------- 5.5 Construct path_in and path_out ----------------------------
    path_in  = string(remote_base);  % constant for this dataset
    path_out = "data/source/sub-" + subjectID + "/ses-" + sessionID + "/eeg";

    % -------- 5.6 Append row to table --------------------------------------
    new_row = {subjectID, sessionID, runID, format_value, ...
        vhdr, vmrk, dat, path_in, path_out};

    eeg_table = [eeg_table; new_row]; %#ok<AGROW>
end

%% 6. Sort rows by subjectID, sessionID, runID

if ~isempty(eeg_table)
    eeg_table = sortrows(eeg_table, {'subjectID', 'sessionID', 'runID'});
end

%% 7. Write spreadsheet

writetable(eeg_table, output_file);
fprintf('Wrote EEG file list to: %s\n', output_file);

log_command_window('stop');
