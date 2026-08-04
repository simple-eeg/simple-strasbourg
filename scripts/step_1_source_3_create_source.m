%% step_1_source_3_create_source.m
% Create BIDS-style "source" tree and copy Strasbourg BrainVision data.
% - Reads dataset_list_prelim.xlsx from data_lists/.
% - Uses *_missing flags to decide which rows to copy.
% - For each row not flagged as missing any of the three expected files:
%       - Creates data/source/sub-<subjectID>/ses-<sessionID>/eeg
%       - Copies vhdr, vmrk, dat into that folder, preserving filenames.
% - Retains completed final files and restarts interrupted .partial copies.
% - Prints progress per row and a summary at the end.
%
% No filenames are changed, preserving existing same-directory BrainVision file references.

log_command_window('start');
clear; clc;

%% 1. Define paths

baseDir      = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
dataListsDir = fullfile(baseDir, 'data_lists');
eegFile      = fullfile(dataListsDir, 'dataset_list_prelim.xlsx');
sourceRoot   = fullfile(baseDir, 'data', 'source');

%% 2. Report existing source folder for resumable copying

if isfolder(sourceRoot)
    fprintf(['Source folder already exists at %s\n', ...
        'Existing final files will be retained and missing files will be copied.\n'], ...
        sourceRoot);
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
nFilesCopied = 0;
nFilesAlreadyPresent = 0;

%% 5. Loop over rows

for i = 1:nRows
    subj = eegTable.subjectID(i);
    sess = eegTable.sessionID(i);
    run  = eegTable.runID(i);

    if ~toCopy(i)
        fprintf('Skipping sub-%s, ses-%s, run %s (at least one expected file was flagged missing)\n', ...
            subj, sess, run);
        continue;
    end

    fprintf('Preparing sub-%s, ses-%s, run-%s...\n', subj, sess, run);

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

    sourceFiles = [vhdrSrc, vmrkSrc, datSrc];
    destinationFiles = [vhdrDst, vmrkDst, datDst];

    % Copy each absent file to a local .partial sibling before renaming it.
    for f = 1:numel(sourceFiles)
        sourceFile = sourceFiles(f);
        destinationFile = destinationFiles(f);

        if isfile(destinationFile)
            fprintf('  Already present: %s\n', destinationFile);
            nFilesAlreadyPresent = nFilesAlreadyPresent + 1;
            continue;
        end

        partialFile = destinationFile + ".partial";
        if isfile(partialFile)
            delete(partialFile);
        end

        [copyOk, copyMessage] = copyfile(sourceFile, partialFile);
        if ~copyOk
            if isfile(partialFile)
                try
                    delete(partialFile);
                catch cleanupError
                    warning('CreateSource:PartialCleanupFailed', ...
                        'Could not remove incomplete local file "%s": %s', ...
                        partialFile, cleanupError.message);
                end
            end
            error('CreateSource:CopyFailed', ...
                'Failed to copy file from "%s" to "%s": %s', ...
                sourceFile, partialFile, copyMessage);
        end

        [moveOk, moveMessage] = movefile(partialFile, destinationFile);
        if ~moveOk
            error('CreateSource:RenameFailed', ...
                'Failed to rename local file from "%s" to "%s": %s', ...
                partialFile, destinationFile, moveMessage);
        end

        fprintf('  Copied: %s\n', destinationFile);
        nFilesCopied = nFilesCopied + 1;
    end
end

%% 6. Final summary

fprintf(['Completed all %d scheduled BrainVision triplet(s): ', ...
    '%d file(s) copied in this run and %d already-present final file(s) retained.\n'], ...
    nToCopy, nFilesCopied, nFilesAlreadyPresent);

log_command_window('stop');