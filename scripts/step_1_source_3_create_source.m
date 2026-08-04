%% step_1_source_3_create_source.m
% Create BIDS-style "source" tree and copy Strasbourg BrainVision data.
% - Reads dataset_list_prelim.xlsx from data_lists/.
% - Uses *_missing flags to decide which rows to copy.
% - For each row with all three files present:
%       - Creates data/source/sub-<subjectID>/ses-<sessionID>/eeg
%       - Copies vhdr, vmrk, dat into that folder, preserving filenames.
% - Prints progress per row and a summary at the end.
%
% No filenames are changed; BrainVision header/marker links remain valid.

log_command_window('start');
clear; clc;

%% 1. Define paths

baseDir      = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
dataListsDir = fullfile(baseDir, 'data_lists');
eegFile      = fullfile(dataListsDir, 'dataset_list_prelim.xlsx');
sourceRoot   = fullfile(baseDir, 'data', 'source');

%% 2. Check source folder does not already exist

if isfolder(sourceRoot)
    fprintf('Source folder already exists at %s\n', sourceRoot);
    error('CreateSource:SourceExists', ...
        'Source folder already exists; aborting to avoid overwriting.');
end

%% 3. Check dataset_list_prelim.xlsx exists and read it

if ~isfolder(dataListsDir)
    error('CreateSource:DataListsMissing', ...
        'Data lists directory does not exist: %s', dataListsDir);
end

if ~isfile(eegFile)
    error('CreateSource:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', eegFile);
end

eegTable = readtable(eegFile, ...
    'PreserveVariableNames', true, ...
    'TextType', 'string');

% Force *_missing columns to be strings (handles case where Excel stored them as numeric)
missingCols = ["vhdr_missing","vmrk_missing","dat_missing"];
for c = 1:numel(missingCols)
    colName = missingCols(c);

    if ~ismember(colName, eegTable.Properties.VariableNames)
        error('CreateSource:MissingColumns', ...
            'Required column %s is missing from dataset_list_prelim.xlsx.', colName);
    end

    colData = eegTable.(colName);

    % If the column came in as numeric (e.g., all NaN), treat it as "all empty"
    if isnumeric(colData)
        eegTable.(colName) = strings(height(eegTable), 1);
    else
        eegTable.(colName) = string(colData);
    end
end

requiredCols = ["subjectID","sessionID","runID","format", ...
    "vhdr","vmrk","dat","path_in","path_out", ...
    "vhdr_missing","vmrk_missing","dat_missing"];

missingRequired = requiredCols(~ismember(requiredCols, eegTable.Properties.VariableNames));
if ~isempty(missingRequired)
    error('CreateSource:MissingColumns', ...
        'The following required column(s) are missing from dataset_list_prelim.xlsx: %s', ...
        strjoin(cellstr(missingRequired), ', '));
end

%% 4. Determine which rows should be copied

nRows = height(eegTable);

toCopy = (eegTable.vhdr_missing ~= "missing") & ...
    (eegTable.vmrk_missing ~= "missing") & ...
    (eegTable.dat_missing  ~= "missing");

nToCopy = sum(toCopy);
nCopied = 0;

%% 5. Loop over rows

for i = 1:nRows
    subj = eegTable.subjectID(i);
    sess = eegTable.sessionID(i);
    run  = eegTable.runID(i);

    if ~toCopy(i)
        fprintf('Skipping sub-%s, ses-%s, run %s (missing files)\n', ...
            subj, sess, run);
        continue;
    end

    fprintf('Copying sub-%s, ses-%s, run-%s...\n', subj, sess, run);

    % Build destination directory from relative path_out
    relPathOut = eegTable.path_out(i);          % e.g. "data/source/sub-BB16/ses-.../eeg"
    destDir    = fullfile(baseDir, relPathOut);

    if ~isfolder(destDir)
        ok = mkdir(destDir);
        if ~ok
            error('CreateSource:MakeDestFailed', ...
                'Failed to create destination directory: %s', destDir);
        end
    end

    % Build full source paths
    srcDir  = eegTable.path_in(i);
    vhdrSrc = fullfile(srcDir, eegTable.vhdr(i));
    vmrkSrc = fullfile(srcDir, eegTable.vmrk(i));
    datSrc  = fullfile(srcDir, eegTable.dat(i));

    % Build full destination paths (preserve filenames)
    vhdrDst = fullfile(destDir, eegTable.vhdr(i));
    vmrkDst = fullfile(destDir, eegTable.vmrk(i));
    datDst  = fullfile(destDir, eegTable.dat(i));

    % Copy files; error immediately if any copy fails
    [ok1, msg1] = copyfile(vhdrSrc, vhdrDst);
    if ~ok1
        error('CreateSource:CopyFailed', ...
            'Failed to copy file from "%s" to "%s": %s', vhdrSrc, vhdrDst, msg1);
    end

    [ok2, msg2] = copyfile(vmrkSrc, vmrkDst);
    if ~ok2
        error('CreateSource:CopyFailed', ...
            'Failed to copy file from "%s" to "%s": %s', vmrkSrc, vmrkDst, msg2);
    end

    [ok3, msg3] = copyfile(datSrc, datDst);
    if ~ok3
        error('CreateSource:CopyFailed', ...
            'Failed to copy file from "%s" to "%s": %s', datSrc, datDst, msg3);
    end

    nCopied = nCopied + 1;
end

%% 6. Final summary

fprintf('Copied %d row(s) out of %d row(s) scheduled for copying.\n', ...
    nCopied, nToCopy);

log_command_window('stop');