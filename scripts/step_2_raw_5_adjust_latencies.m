%% step_2_raw_5_adjust_latencies.m
% Adjust event latencies in raw .set files based on original event types.
%
% Purpose:
%   - Read:
%       * data/info_prelim/event_types_original/event_types_original_summary.csv
%         (columns: Type_original, LatencyCorrect, ...)
%       * data_lists/dataset_list_prelim.xlsx
%         (columns: path_reformatted, EEGfile_reformatted, latency_correct, ...)
%   - For each .set file where latency_correct == "1":
%       * Load the dataset from data/raw/... (path_reformatted + EEGfile_reformatted).
%       * Identify events whose original type (EEG.event.urtype) is flagged for
%         latency correction (LatencyCorrect == "1" for the matching Type_original).
%       * Apply a global latency shift (CORRECTION_MS) to those events only:
%             Δsamples = round(CORRECTION_MS * srate / 1000).
%       * Maintain provenance:
%           - If EEG.event.urlatency exists, verify it matches current latencies
%             within tolerance TOL; otherwise skip file.
%           - If urlatency is absent, create it from current latencies before edits.
%           - Best-effort cross-check with EEG.urevent.latency where available.
%       * Run eeg_checkset(EEG, 'eventconsistency') and overwrite the .set file
%         only if at least one event was successfully adjusted.
%
% Matching:
%   - LatencyCorrect is interpreted against original types:
%       Type_original  <->  EEG.event.urtype
%   - Matching is exact, case-sensitive, after trimming leading/trailing spaces.
%
% Notes:
%   - Events whose original types are not flagged are left unchanged.
%   - Events whose new types are "NA" are irrelevant here; only urtype matters.
%   - Files or events failing provenance checks are skipped with a warning.

log_command_window('start');
clear; clc;

%% 0) User configuration

PROJECT_ROOT  = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
XLSX_PATH     = fullfile(PROJECT_ROOT, 'data_lists', 'dataset_list_prelim.xlsx');
MAP_CSV       = fullfile(PROJECT_ROOT, 'data', 'info_prelim', ...
    'event_types_original', 'event_types_original_summary.csv');

CORRECTION_MS = -40;    % ms; NEGATIVE = move earlier, POSITIVE = move later
TOL           = 1e-9;   % tolerance for latency equality checks

fprintf('== Latency adjust: CORRECTION_MS = %g ms  (- earlier, + later)\n', CORRECTION_MS);

% Check files exist
if ~isfile(XLSX_PATH)
    error('LatencyAdjust:FileListMissing', ...
        'dataset_list_prelim.xlsx not found at: %s', XLSX_PATH);
end

if ~isfile(MAP_CSV)
    error('LatencyAdjust:MappingMissing', ...
        'event_types_original_summary.csv not found at: %s', MAP_CSV);
end

% EEGLAB
if exist('eeglab','file') ~= 2
    error('LatencyAdjust:EEGLABMissing', ...
        'EEGLAB not found on the MATLAB path.');
end
eeglab;

%% 1) Load mapping CSV (Type_original -> LatencyCorrect flag)

mapOpts = detectImportOptions(MAP_CSV, ...
    'TextType', 'string', ...
    'VariableNamingRule', 'preserve');

mapTbl  = readtable(MAP_CSV, mapOpts);

% Ensure required columns exist
if ~ismember("Type_original", string(mapTbl.Properties.VariableNames))
    error('LatencyAdjust:MappingColsMissing', ...
        'Mapping file must contain column: Type_original');
end

if ~ismember("LatencyCorrect", string(mapTbl.Properties.VariableNames))
    % If missing, create a blank column
    mapTbl.LatencyCorrect = strings(height(mapTbl), 1);
end

% Normalise columns
typeCol = string(mapTbl.Type_original);
typeCol(ismissing(typeCol)) = "";
typeCol = strtrim(typeCol);

flagCol = string(mapTbl.LatencyCorrect);
flagCol(ismissing(flagCol)) = "";
flagCol = strtrim(flagCol);

% Determine which original types are flagged for latency correction
flaggedMask   = (flagCol == "1");
FLAGGED_TYPES = typeCol(flaggedMask & strlength(typeCol) > 0);

if isempty(FLAGGED_TYPES)
    fprintf('Info: No original event types flagged for latency correction (LatencyCorrect == "1"). Nothing to do.\n');
    log_command_window('stop');
    return;
end

fprintf('Original event types flagged for latency correction: %d\n', numel(FLAGGED_TYPES));

%% 2) Load file list and select .set files to process

listOpts = detectImportOptions(XLSX_PATH, ...
    'TextType', 'string', ...
    'VariableNamingRule', 'preserve');

T = readtable(XLSX_PATH, listOpts);

reqCols = ["path_reformatted","EEGfile_reformatted","latency_correct"];
missing = setdiff(reqCols, string(T.Properties.VariableNames));
if ~isempty(missing)
    error('LatencyAdjust:ListColsMissing', ...
        'dataset_list_prelim.xlsx missing required column(s): %s', strjoin(missing, ', '));
end

% Normalise required columns
pathCol = string(T.path_reformatted);
pathCol(ismissing(pathCol)) = "";
pathCol = strtrim(pathCol);

fileCol = string(T.EEGfile_reformatted);
fileCol(ismissing(fileCol)) = "";
fileCol = strtrim(fileCol);

lcorCol = string(T.latency_correct);
lcorCol(ismissing(lcorCol)) = "";
lcorCol = strtrim(lcorCol);

% Select rows to process: valid path, valid filename, and latency_correct == "1"
rowsToProcess = (strlength(pathCol) > 0) & ...
    (strlength(fileCol) > 0) & ...
    (lcorCol == "1");

if ~any(rowsToProcess)
    fprintf('Info: No files flagged in dataset_list_prelim.xlsx (latency_correct == "1"). Nothing to do.\n');
    log_command_window('stop');
    return;
end

procIdx = find(rowsToProcess);
N       = numel(procIdx);

fprintf('Files flagged for latency correction: %d\n', N);

%% 3) Iterate over selected .set files

nSaved   = 0;
nSkipped = 0;

for k = 1:N
    r       = procIdx(k);
    relDir  = pathCol(r);
    setName = fileCol(r);

    srcDir  = fullfile(PROJECT_ROOT, relDir);
    setPath = fullfile(srcDir, setName);

    fprintf('[%d/%d] %s/%s\n', k, N, relDir, setName);

    % Ensure file exists
    if ~isfile(setPath)
        error('LatencyAdjust:MissingSetFile', ...
            'Missing .set file: %s', setPath);
    end

    %% 3a) Load EEG and basic sanity checks

    EEG = pop_loadset('filepath', srcDir, 'filename', setName, 'loadmode', 'all');

    if ~isfield(EEG, 'event') || isempty(EEG.event)
        warning('  [WARN] No events present; skipping file.');
        nSkipped = nSkipped + 1;
        continue;
    end

    if ~isfield(EEG, 'srate') || isempty(EEG.srate) || EEG.srate <= 0 || ...
            ~isfield(EEG, 'pnts')  || EEG.pnts <= 0
        error('LatencyAdjust:BadSampling', ...
            'Invalid srate/pnts for: %s', setPath);
    end

    evCount = numel(EEG.event);
    L       = arrayfun(@(e) double(e.latency), EEG.event);

    %% 3b) Provenance / idempotence checks

    % Check urlatency consistency if present
    hasUrlField = all(isfield(EEG.event, 'urlatency'));
    if hasUrlField
        hasUrlValue = arrayfun(@(e) isfield(e, 'urlatency') && ...
            ~isempty(e.urlatency) && ...
            isnumeric(e.urlatency), EEG.event);
        if ~all(hasUrlValue)
            warning('  [WARN] urlatency field exists but contains missing/non-numeric values; skipping file.');
            nSkipped = nSkipped + 1;
            continue;
        end

        UL = arrayfun(@(e) double(e.urlatency), EEG.event);
        if numel(UL) ~= evCount
            warning('  [WARN] urlatency length mismatch (urlatency=%d, events=%d); skipping file.', numel(UL), evCount);
            nSkipped = nSkipped + 1;
            continue;
        end

        if any(abs(L - UL) > TOL)
            warning('  [WARN] Current latencies differ from urlatency (>%g); skipping file.', TOL);
            nSkipped = nSkipped + 1;
            continue;
        end
    end

    % Best-effort cross-check with urevent.latency
    if isfield(EEG, 'urevent') && ~isempty(EEG.urevent) && all(isfield(EEG.event, 'urevent'))
        mismatchFound = false;
        for e = 1:evCount
            uix = [];
            if isfield(EEG.event(e), 'urevent')
                try
                    uix = double(EEG.event(e).urevent);
                catch
                    uix = [];
                end
            end

            if ~isempty(uix) && isfinite(uix) && uix >= 1 && uix <= numel(EEG.urevent)
                if isfield(EEG.urevent, 'latency') && ~isempty(EEG.urevent(uix).latency)
                    U = double(EEG.urevent(uix).latency);
                    if abs(L(e) - U) > TOL
                        warning('  [WARN] urevent mismatch at event %d (|%g - %g| > %g); skipping file.', ...
                            e, L(e), U, TOL);
                        mismatchFound = true;
                        break;
                    end
                end
            end
        end

        if mismatchFound
            nSkipped = nSkipped + 1;
            continue;
        end
    end

    %% 3c) Backup original latencies if urlatency is absent

    if ~hasUrlField
        for e = 1:evCount
            EEG.event(e).urlatency = EEG.event(e).latency;
        end
        fprintf('  [INFO] Backed up original latencies to EEG.event.urlatency\n');
    end

    %% 3d) Determine which events to adjust (match on original type: urtype)

    if ~all(isfield(EEG.event, 'urtype'))
        warning('  [WARN] Event field "urtype" not found for all events; skipping file.');
        nSkipped = nSkipped + 1;
        continue;
    end

    matchedMask = false(1, evCount);

    for e = 1:evCount
        t = "";
        try
            t = string(EEG.event(e).urtype);
        catch
            t = "";
        end

        if ismissing(t)
            t = "";
        end
        t = strtrim(t);

        if strlength(t) > 0
            % exact, case-sensitive match against flagged Type_original values
            if any(t == FLAGGED_TYPES)
                matchedMask(e) = true;
            end
        else
            % original type is empty string; only match if FLAGGED_TYPES contains ""
            if any("" == FLAGGED_TYPES)
                matchedMask(e) = true;
            end
        end
    end

    nMatched = nnz(matchedMask);
    if nMatched == 0
        warning('  [WARN] No events with flagged original types in this file; skipping save.');
        nSkipped = nSkipped + 1;
        continue;
    end

    %% 3e) Compute and apply latency shifts

    deltaSamples = round(CORRECTION_MS * EEG.srate / 1000);
    applied      = 0;
    oobSkips     = 0;

    idxMatched = find(matchedMask);
    for e = idxMatched
        oldLat = EEG.event(e).latency;
        newLat = oldLat + deltaSamples;

        if newLat < 1 || newLat > EEG.pnts
            warning('  [WARN] Event %d out-of-bounds after shift (old=%.6g, new=%.6g; pnts=%d); event skipped.', ...
                e, oldLat, newLat, EEG.pnts);
            oobSkips = oobSkips + 1;
        else
            EEG.event(e).latency = newLat;
            applied = applied + 1;
        end
    end

    %% 3f) Integrity check and save / skip

    EEG = eeg_checkset(EEG, 'eventconsistency');

    if applied > 0
        pop_saveset(EEG, 'filename', setName, 'filepath', srcDir, 'savemode', 'onefile');
        fprintf('  [OK] matched=%d, adjusted=%d, OOB skipped=%d → saved\n', nMatched, applied, oobSkips);
        nSaved = nSaved + 1;
    else
        warning('  [WARN] matched=%d but adjusted=0 (OOB skipped=%d) → file left unchanged.', nMatched, oobSkips);
        nSkipped = nSkipped + 1;
    end
end

fprintf('== Done. Files flagged: %d | saved: %d | skipped: %d\n', N, nSaved, nSkipped);

log_command_window('stop');