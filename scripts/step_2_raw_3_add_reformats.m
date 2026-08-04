%% step_2_raw_3_add_reformats.m
% Prepare reformatted (EEGLAB .set) filenames and paths for Strasbourg data.
%
% Purpose:
%   - Read dataset_list_prelim.xlsx.
%   - Add three columns (overwriting if present), in this order:
%       1) excluded_datasets
%            -> "excluded" if row should be excluded, "" otherwise.
%       2) EEGfile_reformatted
%            -> BIDS-style .set filename:
%               sub-<subjectID>_ses-<sessionID>_run-<runID>_eeg.set
%            -> only filled for non-excluded rows.
%       3) path_reformatted
%            -> same as path_out, but with "data/source/" replaced by
%               "data/raw/" at the start.
%            -> only filled for non-excluded rows where path_out has the
%               expected "data/source/" prefix.
%
% Exclusion rule:
%   - A row is marked "excluded" if ANY of the following cells equals "missing":
%       vhdr_missing, vmrk_missing, dat_missing, event_missing
%
% Conventions:
%   - True blanks from Excel are normalised to "" (not <missing>).
%   - BIDS-style .set file naming uses subjectID, sessionID, runID exactly
%     as stored in dataset_list_prelim.xlsx (no extra case changes).
%   - path_reformatted is derived by transforming path_out; if path_out
%     does not start with "data/source/", a warning is issued and
%     path_reformatted is left blank for that row.
%
% Output:
%   - Overwrites dataset_list_prelim.xlsx in-place with the three new columns
%     appended.

log_command_window('start');
clear; clc;

%% 1. Paths

baseDir      = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
fileListPath = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');

if ~isfile(fileListPath)
    error('AddReformats:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', fileListPath);
end

%% 2. Load dataset_list_prelim.xlsx with appropriate typing

fprintf('Loading: %s\n', fileListPath);

opts = detectImportOptions(fileListPath, 'PreserveVariableNames', true);

% Required columns for this step
requiredCols = {'subjectID','sessionID','runID', ...
    'path_out', ...
    'vhdr_missing','vmrk_missing','dat_missing','event_missing'};

missingCols = setdiff(requiredCols, opts.VariableNames);
if ~isempty(missingCols)
    error('AddReformats:MissingColumns', ...
        'Missing required column(s) in dataset_list_prelim.xlsx: %s', ...
        strjoin(missingCols, ', '));
end

% Force key columns to be read as string
forceStrCols = {'subjectID','sessionID','runID', ...
    'path_out', ...
    'vhdr_missing','vmrk_missing','dat_missing','event_missing'};

for k = 1:numel(forceStrCols)
    colName = forceStrCols{k};
    if any(strcmpi(opts.VariableNames, colName))
        opts = setvaropts(opts, colName, 'Type', 'string');
    end
end

T = readtable(fileListPath, opts);
N = height(T);

% Normalise *_missing columns as strings and turn <missing> into ""
for colName = ["vhdr_missing","vmrk_missing","dat_missing","event_missing"]
    if ~ismember(colName, T.Properties.VariableNames)
        error('AddReformats:MissingColumns', ...
            'Required column %s is missing after readtable.', colName);
    end

    colData = T.(colName);
    if isnumeric(colData)
        colStr = strings(N, 1);          % all blank
    else
        colStr = string(colData);        % may contain <missing>
    end

    % Convert true blanks (<missing>) to empty strings ""
    colStr(ismissing(colStr)) = "";

    T.(colName) = colStr;
end

% Ensure path_out is string as well
if isnumeric(T.path_out)
    T.path_out = strings(N, 1);
else
    T.path_out = string(T.path_out);
end

% Ensure IDs are strings
T.subjectID = string(T.subjectID);
T.sessionID = string(T.sessionID);
T.runID     = string(T.runID);

%% 3. Create/overwrite the three output columns

T.excluded_datasets   = strings(N, 1);
T.EEGfile_reformatted = strings(N, 1);
T.path_reformatted    = strings(N, 1);

%% 4. Pass 1: mark exclusions based on missing flags

fprintf('Marking exclusions based on *_missing columns...\n');

nExcluded = 0;
nKept     = 0;

for i = 1:N
    vhdrFlag = T.vhdr_missing(i);
    vmrkFlag = T.vmrk_missing(i);
    datFlag  = T.dat_missing(i);
    evtFlag  = T.event_missing(i);

    hasVHDRMissing = (vhdrFlag == "missing");
    hasVMRKMissing = (vmrkFlag == "missing");
    hasDATMissing  = (datFlag  == "missing");
    hasEvtMissing  = (evtFlag  == "missing");

    if hasVHDRMissing || hasVMRKMissing || hasDATMissing || hasEvtMissing
        T.excluded_datasets(i) = "excluded";
        nExcluded = nExcluded + 1;
    else
        T.excluded_datasets(i) = "";
        nKept = nKept + 1;
    end
end

%% 5. Pass 2: fill reformatted filename and path for non-excluded rows

fprintf('Setting reformatted filenames and paths for non-excluded rows...\n');

nUpdated = 0;

for i = 1:N
    if T.excluded_datasets(i) ~= ""
        % Excluded: leave EEGfile_reformatted and path_reformatted blank
        continue;
    end

    % ---- EEGfile_reformatted (BIDS-style .set filename) ----
    subjID = T.subjectID(i);
    sessID = T.sessionID(i);
    runID  = T.runID(i);

    EEGname = "sub-" + subjID + "_ses-" + sessID + "_run-" + runID + "_eeg.set";
    T.EEGfile_reformatted(i) = EEGname;

    % ---- path_reformatted (data/source/... -> data/raw/...) ----
    srcPath = T.path_out(i);  % e.g. "data/source/sub-XX/ses-YY/eeg"

    if startsWith(srcPath, "data/source/")
        T.path_reformatted(i) = "data/raw/" + extractAfter(srcPath, "data/source/");
    else
        warning('Row %d: path_out does not start with "data/source/": %s. Leaving path_reformatted blank.', ...
            i, srcPath);
        T.path_reformatted(i) = "";
    end

    if T.path_reformatted(i) ~= ""
        nUpdated = nUpdated + 1;
    end
end

%% 6. Save updated dataset_list_prelim.xlsx and summarise

writetable(T, fileListPath);

fprintf('Updated table saved to: %s\n', fileListPath);
fprintf('Summary:\n');
fprintf('  Non-excluded rows (kept)          : %d\n', nKept);
fprintf('  Excluded rows                     : %d\n', nExcluded);
fprintf('  Rows with reformatted info filled : %d\n', nUpdated);
fprintf('  Total rows                        : %d\n', N);

log_command_window('stop');