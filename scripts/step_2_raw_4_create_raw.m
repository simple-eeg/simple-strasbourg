%% step_2_raw_4_create_raw.m
% Create EEGLAB .set files from Strasbourg BrainVision data.
%
% Purpose:
%   - Read dataset_list_prelim.xlsx to find all non-excluded datasets.
%   - For each non-excluded row:
%       * Load the BrainVision data (.vhdr/.vmrk/.dat) from data/source/...
%       * Back up original event types in EEG.event.urtype.
%       * Replace EEG.event.type using a mapping defined in
%         data/info_prelim/event_types_original/event_types_original_summary.csv:
%             - For each Type_original, use Type_new if provided.
%             - If Type_new is blank, use 'NA'.
%         All original event types in the data must appear in the mapping.
%       * Save a one-file EEGLAB .set into data/raw/... with BIDS-style name:
%             sub-<subjectID>_ses-<sessionID>_run-<runID>_eeg.set
%
% Assumptions:
%   - All datasets are BrainVision format.
%   - dataset_list_prelim.xlsx already contains:
%       subjectID, sessionID, runID,
%       excluded_datasets,
%       path_out, path_reformatted,
%       vhdr, vmrk, dat,
%       EEGfile_reformatted.
%   - event_types_original_summary.csv contains:
%       Type_original, Type_new (plus other columns we ignore here).
%     There are no duplicate Type_original values (after trimming).
%     Every original event type in the data appears in Type_original.

log_command_window('start');
clear; clc;

%% 0) Setup paths and EEGLAB

baseDir     = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
eegListPath = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');
mapPath     = fullfile(baseDir, 'data', 'info_prelim', ...
    'event_types_original', 'event_types_original_summary.csv');

% Check files exist
if ~isfile(eegListPath)
    error('CreateRaw:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', eegListPath);
end

if ~isfile(mapPath)
    error('CreateRaw:MappingMissing', ...
        'event_types_original_summary.csv not found at: %s', mapPath);
end

% Ensure EEGLAB is available
if exist('eeglab', 'file') ~= 2
    error('CreateRaw:EEGLABMissing', ...
        'EEGLAB not found on the MATLAB path.');
end
eeglab;

%% 1) Load event-type mapping (Type_original -> Type_new)

mapOpts = detectImportOptions(mapPath, ...
    'PreserveVariableNames', true, ...
    'TextType', 'string');

M = readtable(mapPath, mapOpts);

% Ensure required columns exist
requiredMapCols = {'Type_original','Type_new'};
missingMapCols = setdiff(requiredMapCols, M.Properties.VariableNames);
if ~isempty(missingMapCols)
    error('CreateRaw:MappingColsMissing', ...
        'Mapping file missing required column(s): %s', ...
        strjoin(missingMapCols, ', '));
end

% Normalise columns to trimmed strings
orig = string(M.Type_original);
new  = string(M.Type_new);

orig(ismissing(orig)) = "";
new(ismissing(new))   = "";

orig = strtrim(orig);
new  = strtrim(new);

% Enforce: at least one Type_new is non-empty
if all(strlength(new) == 0)
    error(['event_types_original_summary.csv: Type_new column is entirely empty after trimming. ', ...
        'Populate at least one Type_new and retry.']);
end

% Build a containers.Map from Type_original -> Type_new
% Assumes no duplicate Type_original values (after trimming);
% if duplicates are present, containers.Map will error, which is desired.
eventTypeMap = containers.Map( ...
    cellstr(orig), ...
    cellstr(new) ...
    );

%% 2) Load dataset_list_prelim.xlsx and select non-excluded rows

opts = detectImportOptions(eegListPath, 'PreserveVariableNames', true);

requiredCols = {'subjectID','sessionID','runID', ...
    'excluded_datasets', ...
    'path_out','path_reformatted', ...
    'vhdr','vmrk','dat', ...
    'EEGfile_reformatted'};

missingCols = setdiff(requiredCols, opts.VariableNames);
if ~isempty(missingCols)
    error('CreateRaw:ListColsMissing', ...
        'dataset_list_prelim.xlsx missing required column(s): %s', ...
        strjoin(missingCols, ', '));
end

% Force key columns to be read as string
forceStr = requiredCols;
for k = 1:numel(forceStr)
    colName = forceStr{k};
    if any(strcmpi(opts.VariableNames, colName))
        opts = setvaropts(opts, colName, 'Type', 'string');
    end
end

T = readtable(eegListPath, opts);
N = height(T);

% Normalise key columns to strings and turn <missing> into ""
for k = 1:numel(forceStr)
    colName = forceStr{k};
    col = string(T.(colName));
    col(ismissing(col)) = "";
    T.(colName) = col;
end

% Filter to non-excluded rows (excluded_datasets == "" or <missing>)
excl = strtrim(T.excluded_datasets);
keepMask = (excl == "" | ismissing(excl));
Tkeep = T(keepMask, :);
Nkeep = height(Tkeep);

if Nkeep == 0
    fprintf('No non-excluded rows to process. Nothing to do.\n');
    log_command_window('stop');
    return;
end

fprintf('Found %d non-excluded rows to process.\n', Nkeep);

%% 3) Loop through each non-excluded row and create .set files

processed = 0;

for r = 1:Nkeep
    subjID = Tkeep.subjectID(r);
    sessID = Tkeep.sessionID(r);
    runID  = Tkeep.runID(r);

    srcRel = Tkeep.path_out(r);         % e.g. "data/source/sub-.../ses-.../eeg"
    dstRel = Tkeep.path_reformatted(r); % e.g. "data/raw/sub-.../ses-.../eeg"

    vhdrName = Tkeep.vhdr(r);
    setName  = Tkeep.EEGfile_reformatted(r);

    % Basic sanity checks for required fields
    if strlength(srcRel) == 0
        error('Row %d: path_out is empty.', r);
    end
    if strlength(dstRel) == 0
        error('Row %d: path_reformatted is empty.', r);
    end
    if strlength(vhdrName) == 0
        error('Row %d: vhdr filename is empty.', r);
    end
    if strlength(setName) == 0
        error('Row %d: EEGfile_reformatted is empty.', r);
    end

    srcDir = fullfile(baseDir, char(srcRel));
    dstDir = fullfile(baseDir, char(dstRel));

    if ~isfolder(srcDir)
        error('Row %d: source folder not found: %s', r, srcDir);
    end

    vhdrPath = fullfile(srcDir, char(vhdrName));
    if ~isfile(vhdrPath)
        error('Row %d: VHDR file not found: %s', r, vhdrPath);
    end

    if ~isfolder(dstDir)
        ok = mkdir(dstDir);
        if ~ok
            error('Row %d: failed to create destination folder: %s', r, dstDir);
        end
    end

    fprintf('Row %d/%d | sub-%s ses-%s run-%s\n', ...
        r, Nkeep, subjID, sessID, runID);

    %% 3a) Load BrainVision file into EEGLAB

    [vhdrFolder, vhdrBase, vhdrExt] = fileparts(vhdrPath);
    EEG = pop_loadbv(vhdrFolder, [vhdrBase vhdrExt]);
    EEG = eeg_checkset(EEG);

    %% 3b) Backup original event types and apply mapping

    if isfield(EEG, 'event') && ~isempty(EEG.event)
        % Original types as trimmed strings
        origTypes = string({EEG.event.type});
        origTypes(ismissing(origTypes)) = "";
        origTypes = strtrim(origTypes);

        % Backup into .urtype
        for k = 1:numel(EEG.event)
            EEG.event(k).urtype = char(origTypes(k));
        end

        % Map to new types
        newTypes = strings(size(origTypes));

        for k = 1:numel(origTypes)
            o = origTypes(k);  % trimmed original type (may be "")

            % Every original event type must exist in the mapping
            if ~isKey(eventTypeMap, char(o))
                error(['Mapping missing for original event type "%s" ', ...
                    '(sub-%s ses-%s run-%s, row %d).'], ...
                    o, subjID, sessID, runID, r);
            end

            mapped = string(eventTypeMap(char(o)));
            % If Type_new is blank, use "NA"
            if strlength(mapped) == 0
                newTypes(k) = "NA";
            else
                newTypes(k) = mapped;
            end
        end

        % Write back new event types
        for k = 1:numel(EEG.event)
            EEG.event(k).type = char(newTypes(k));
        end

        EEG = eeg_checkset(EEG);
    else
        % No events present; nothing to map
        fprintf('  Warning: no events found in this EEG (sub-%s ses-%s run-%s).\n', ...
            subjID, sessID, runID);
    end

    %% 3c) Save .set in one-file mode

    pop_saveset(EEG, ...
        'filename', char(setName), ...
        'filepath', dstDir, ...
        'savemode', 'onefile');

    fprintf('  Saved: %s\n', fullfile(dstDir, char(setName)));
    processed = processed + 1;
end

%% 4) Summary

fprintf('Completed BrainVision → .set conversion.\n');
fprintf('  Non-excluded rows processed: %d\n', processed);
fprintf('  Destination root (raw): %s\n', fullfile(baseDir, 'data', 'raw'));

log_command_window('stop');