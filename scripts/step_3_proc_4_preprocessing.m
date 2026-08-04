%% step_3_proc_4_preprocessing.m
% Batch preprocessing orchestrator for SIMPLE/EEGLAB datasets.
%
% Purpose
%   This script processes a list of EEG .set files in a clear four-block flow:
%     A) Continuous-data cleaning (re-reference, resample, band-pass, line-noise)
%     B) Delete unwanted events (e.g., events labeled 'NA')
%     C) Add per-source dummy/offset events (e.g., *_prestim at -2000 ms)
%     D) Epoch and baseline
%
%   The script prints concise progress and outcomes to the Command Window and embeds
%   a provenance record into each saved dataset under EEG.etc.simple.preproc.
%
% Key behaviors
%   • If epoching is ON and no epochs are produced, the dataset is not saved and the row
%     is counted as “skipped (no epochs)”.
%   • If epoching is OFF, the processed continuous dataset is always saved.
%   • Output is printed to the Command Window (captured via log_command_window).
%
% Requirements
%   • EEGLAB with SIMPLE installed; 'pop_preproc' must be on the path.
%   • The helper functions 'delete_unwanted_events.m' and 'add_offset_events.m'
%     must be on the MATLAB path (e.g., in <baseDir>/functions).
%   • A CSV at <baseDir>/data_lists/dataset_list.csv with required columns:
%       path_raw, EEGfile_raw,
%       path_processed, EEGfile_processed
%
% Notes
%   • Epoch window alignment is snapped to the sample grid at epoching time. The post
%     window is expanded by +1 sample when calling pop_epoch to enforce an inclusive
%     upper bound (confirm once on your EEGLAB version).
%   • This script defines user-editable options in a single configuration block below.

log_command_window('start');
clear; clc;

%% Project paths and environment setup
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
functionsDir = fullfile(baseDir, 'functions');
if exist(functionsDir, 'dir')
    addpath(functionsDir);
end

dataListPath = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

eeglab;
assert(exist('pop_preproc','file') > 0, 'pop_preproc.m not found on path. Check SIMPLE installation and MATLAB path.');

%% User-editable preprocessing options
PreprocOptions = struct();

% Block A — Continuous-data cleaning
PreprocOptions.reref      = false;
PreprocOptions.refchan    = {'Fz'};                      % case-sensitive channel labels
PreprocOptions.resample   = true;
PreprocOptions.srate      = 500;                         % Hz
PreprocOptions.filter     = true;
PreprocOptions.highpass   = 1;                           % Hz; use [] to disable HP
PreprocOptions.lowpass    = 30;                          % Hz; use [] to disable LP
PreprocOptions.linefilter = true;
PreprocOptions.linefreq   = [50 100 150 200];            % line frequency (Hz) and optional harmonics to notch; entries above Nyquist (with ±2 Hz half-width) are skipped
PreprocOptions.cleanline  = false;                       % use CleanLine if available and true

% Block B — Delete unwanted events
PreprocOptions.deleteNAevents = true;                    % remove events with TYPE exactly 'NA' (case-insensitive)
PreprocOptions.delete_labels  = {'NA'};                  % additional labels can be added here (exact match, case-insensitive)

% Block C — Add dummy/offset events
PreprocOptions.offsetevents = true;
PreprocOptions.src_types    = {'touch', 'cannula'};
PreprocOptions.offset_ms    = -1500;                     % negative for prestim
PreprocOptions.new_types    = {'touch_prestim', 'cannula_prestim'};
PreprocOptions.annotation_for_dummies = {'manually_added_dummy'}; % stored as 1x1 cell to match dataset convention
PreprocOptions.offset_policy = 'skip_oob';               % 'skip_oob' or 'allow_oob'

% Block D — Epoching and baseline
PreprocOptions.epoching        = true;
PreprocOptions.epochevents_true  = {'touch', 'cannula'};
PreprocOptions.epochevents_dummy = {'touch_prestim', 'cannula_prestim'};
PreprocOptions.epochlimpre_ms  = 200;                    % milliseconds before event
PreprocOptions.epochlimpost_ms = 1200;                   % milliseconds after event
PreprocOptions.baseadjust      = true;                   % baseline after epoching

%% Load dataset list and validate schema
fprintf('Loading file list: %s\n', dataListPath);

opts = detectImportOptions(dataListPath, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');
forceStr = {'subjectID','sessionID','runID','EEGfile_raw','path_raw','EEGfile_processed','path_processed'};
forceStr = intersect(forceStr, opts.VariableNames, 'stable');
opts = setvartype(opts, forceStr, 'string');
T = readtable(dataListPath, opts);

need = {'path_raw','EEGfile_raw','path_processed','EEGfile_processed'};
miss = setdiff(need, T.Properties.VariableNames);
if ~isempty(miss)
    error('Missing required columns in dataset_list.csv: %s', strjoin(miss, ', '));
end

N = height(T);
rowsToDo  = (1:N).';
totalToDo = N;

processed          = 0;
skippedNoEpochs    = 0;
skippedMissingSrc  = 0;
failed             = 0;

fprintf('Datasets to process: %d\n', totalToDo);

%% Main loop over rows
for idx = 1:totalToDo
    r = rowsToDo(idx);

    try
        % Resolve relative paths and filenames from the table.
        relIn  = strtrim(string(T.path_raw(r)));
        inName = strtrim(string(T.EEGfile_raw(r)));
        relOut = strtrim(string(T.path_processed(r)));
        outName= strtrim(string(T.EEGfile_processed(r)));

        % Validate required fields are present and non-empty.
        fields = [relIn, inName, relOut, outName];
        if any(ismissing(fields)) || any(strlength(fields) == 0)
            error('[%d/%d] Row %d missing required in/out fields.', idx, totalToDo, r);
        end

        % Build absolute input file path and output directory.
        inFile = fullfile(baseDir, relIn, inName);
        outDir = fullfile(baseDir, relOut);

        fprintf('[%d/%d] PREPROC %s  ->  %s\n', idx, totalToDo, char(inName), fullfile(char(relOut), char(outName)));

        if ~isfile(inFile)
            fprintf('   [warn] Raw .set not found, skipping row %d: %s\n', r, inFile);
            skippedMissingSrc = skippedMissingSrc + 1;
            continue
        end

        if ~exist(outDir, 'dir')
            mkdir(outDir);
        end

        % Load the source dataset into memory.
        [srcFolder, srcStem, srcExt] = fileparts(inFile);
        EEG = pop_loadset('filename', char(srcStem + srcExt), 'filepath', char(srcFolder));

        % Initialize event provenance counters.
        if isfield(EEG,'event') && ~isempty(EEG.event)
            ev_total_before = numel(EEG.event);
        else
            ev_total_before = 0;
        end
        ev_total_after     = ev_total_before;
        na_removed_count   = 0;
        dummy_added_count  = 0;
        per_dummy_added    = struct();
        skipped_oob_count  = 0;

        % --------------- Block A — Continuous cleaning (re-ref, resample, band-pass, line-noise) ---------------
        % Build effective options for Block A (continuous cleaning only).
        optsA = struct();
        optsA.reref       = logical(PreprocOptions.reref);
        optsA.refchan     = PreprocOptions.refchan;
        optsA.resample    = logical(PreprocOptions.resample);
        optsA.srate       = PreprocOptions.srate;
        optsA.filter      = logical(PreprocOptions.filter);
        optsA.highpass    = PreprocOptions.highpass;
        optsA.lowpass     = PreprocOptions.lowpass;
        optsA.linefilter  = logical(PreprocOptions.linefilter);
        optsA.linefreq    = PreprocOptions.linefreq;
        optsA.cleanline   = logical(PreprocOptions.cleanline);
        optsA.offsetevents= false;
        optsA.epoching    = false;
        optsA.baseadjust  = false;

        % Idempotence: only resample if current rate differs from target.
        targetHz = PreprocOptions.srate;
        sameRate = abs(double(EEG.srate) - double(targetHz)) < 1e-6;
        optsA.resample = optsA.resample && ~sameRate;

        % Defensive check: if requested ref channels are absent, skip reref and warn.
        if optsA.reref
            % Ensure channel labels exist before trying to match
            if ~isfield(EEG,'chanlocs') || isempty(EEG.chanlocs) || ~isfield(EEG.chanlocs, 'labels')
                fprintf('   [warn] No channel labels available; skipping re-reference.\n');
                optsA.reref = false;
            else
                refNames = PreprocOptions.refchan;
                have = ismember(refNames, {EEG.chanlocs.labels});
                if ~any(have)
                    fprintf('   [warn] Requested reference channel(s) not found: %s. Skipping re-reference.\n', ...
                        strjoin(refNames, ', '));
                    optsA.reref = false;
                elseif ~all(have)
                    missing = refNames(~have);
                    present = refNames(have);
                    fprintf('   [warn] Some reference channels missing: %s. Using available: %s.\n', ...
                        strjoin(missing, ', '), strjoin(present, ', '));
                    if isempty(present)
                        % Edge case: all requested refs were missing after all
                        optsA.reref = false;
                    else
                        optsA.refchan = present;
                    end
                end
                % If all requested refs exist, nothing to change.
            end
        end

        EEG_clean = pop_preproc(EEG, optsA);
        % -------------------------------------------------------------------------------------------------------


        % --------------- Block B — Delete unwanted events (e.g., TYPE == 'NA') ---------------------------------
        % Block B — Delete unwanted events (e.g., TYPE == 'NA').
        if PreprocOptions.deleteNAevents
            [EEG_clean, repDel] = delete_unwanted_events(EEG_clean, PreprocOptions.delete_labels);
            na_removed_count = repDel.removed_count;
            ev_total_after   = repDel.total_after;
            if na_removed_count > 0
                fprintf('   [info] Deleted %d event(s) matching %s.\n', na_removed_count, strjoin(PreprocOptions.delete_labels, ', '));
            else
                fprintf('   [info] No events matched %s; no deletions performed.\n', strjoin(PreprocOptions.delete_labels, ', '));
            end
        end
        % -------------------------------------------------------------------------------------------------------


        % --------------- Block C — Add per-source dummy/offset events (e.g., *_prestim at -2000 ms) ------------
        if PreprocOptions.offsetevents
            [EEG_clean, repAdd] = add_offset_events( ...
                EEG_clean, ...
                PreprocOptions.src_types, ...
                PreprocOptions.offset_ms, ...
                PreprocOptions.new_types, ...
                PreprocOptions.annotation_for_dummies, ...
                PreprocOptions.offset_policy );
            dummy_added_count  = repAdd.added_count;
            per_dummy_added    = repAdd.per_type_added;
            skipped_oob_count  = repAdd.skipped_oob_count;
            ev_total_after     = repAdd.total_after;

            if dummy_added_count > 0
                fprintf('   [info] Added %d dummy event(s) at %g ms. Skipped OOB: %d.\n', dummy_added_count, PreprocOptions.offset_ms, skipped_oob_count);
            else
                fprintf('   [info] No dummy events added. %s\n', strjoin(repAdd.notes, ' '));
            end
        end
        % -------------------------------------------------------------------------------------------------------


        % --------------- Block D — Epoch and baseline ----------------------------------------------------------
        if PreprocOptions.epoching
            % Build the epochevent list as unique union of true and dummy labels.
            epList = {};
            if ~isempty(PreprocOptions.epochevents_true)
                if isstring(PreprocOptions.epochevents_true)
                    epList = [epList, cellstr(PreprocOptions.epochevents_true)];
                elseif ischar(PreprocOptions.epochevents_true)
                    epList = [epList, {PreprocOptions.epochevents_true}];
                else
                    epList = [epList, PreprocOptions.epochevents_true];
                end
            end
            if ~isempty(PreprocOptions.epochevents_dummy)
                if isstring(PreprocOptions.epochevents_dummy)
                    epList = [epList, cellstr(PreprocOptions.epochevents_dummy)];
                elseif ischar(PreprocOptions.epochevents_dummy)
                    epList = [epList, {PreprocOptions.epochevents_dummy}];
                else
                    epList = [epList, PreprocOptions.epochevents_dummy];
                end
            end
            % Normalize to trimmed char and deduplicate while preserving order.
            epNorm = {};
            for ii = 1:numel(epList)
                v = epList{ii};
                if isstring(v),  v = char(v); end
                if iscell(v) && ~isempty(v), v = v{1}; end
                if ischar(v)
                    s = strtrim(v);
                    if ~isempty(s)
                        epNorm{end+1} = s; %#ok<AGROW>
                    end
                end
            end
            if ~isempty(epNorm)
                [~, firstIdx] = unique(epNorm, 'stable');
                epNorm = epNorm(sort(firstIdx));
            end

            % Align epoch window to sample grid at the rate used during epoching.
            finalHz = EEG_clean.srate;
            Npre  = round(finalHz * (PreprocOptions.epochlimpre_ms  / 1000));
            Npost = round(finalHz * (PreprocOptions.epochlimpost_ms / 1000));
            eff_pre_ms  = (Npre  * 1000) / finalHz;
            eff_post_ms = ((Npost + 1) * 1000) / finalHz;  % +1 sample to enforce inclusive post edge

            % Build effective options for epoching only.
            optsD = struct();
            optsD.reref        = false;
            optsD.refchan      = false;
            optsD.resample     = false;
            optsD.srate        = EEG_clean.srate;
            optsD.filter       = false;
            optsD.highpass     = [];
            optsD.lowpass      = [];
            optsD.linefilter   = false;
            optsD.linefreq     = [];
            optsD.cleanline    = false;
            optsD.offsetevents = false;
            optsD.epoching     = true;
            optsD.epochevents  = epNorm;
            optsD.baseadjust   = logical(PreprocOptions.baseadjust);
            optsD.epochlimpre  = eff_pre_ms;
            optsD.epochlimpost = eff_post_ms;

            EEG_pre = pop_preproc(EEG_clean, optsD);

            % If epoching produced zero epochs, skip saving and move on.
            if ~isfield(EEG_pre,'epoch') || isempty(EEG_pre.epoch)
                fprintf('   [warn] No requested epochevents found. Required any of: %s\n', strjoin(epNorm, ', '));
                fprintf('         Skipping without saving.\n');
                skippedNoEpochs = skippedNoEpochs + 1;
                continue
            end

            % Optional runtime check on epoch length.
            expectedPts = Npre + Npost + 1;
            if EEG_pre.pnts ~= expectedPts
                fprintf('   [warn] Epoch length mismatch: got %d pts, expected %d at Fs=%g\n', EEG_pre.pnts, expectedPts, EEG_pre.srate);
                fprintf('         Window intent:    pre=%g ms, post=%g ms\n', PreprocOptions.epochlimpre_ms, PreprocOptions.epochlimpost_ms);
                fprintf('         Window effective: pre=%g ms, post=%g ms\n', eff_pre_ms, eff_post_ms);
            end
        else
            EEG_pre = EEG_clean;
            epNorm = {};
            eff_pre_ms  = NaN;
            eff_post_ms = NaN;
            Npre = NaN; Npost = NaN; %#ok<NASGU>
        end
        % -------------------------------------------------------------------------------------------------------


        % -------------------- Block E — Compose provenance and embed into EEG ----------------------------------
        % Timestamp and container existence
        dtISO = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
        if ~isfield(EEG_pre,'etc') || isempty(EEG_pre.etc), EEG_pre.etc = struct; end
        if ~isfield(EEG_pre.etc,'simple') || isempty(EEG_pre.etc.simple), EEG_pre.etc.simple = struct; end

        % Outcomes and flags
        epoching_applied = PreprocOptions.epoching && isfield(EEG_pre,'epoch') && ~isempty(EEG_pre.epoch);
        baseline_applied = epoching_applied && PreprocOptions.baseadjust;

        bandpass_used  = PreprocOptions.filter && (~isempty(PreprocOptions.highpass) || ~isempty(PreprocOptions.lowpass));
        line_used      = PreprocOptions.linefilter;
        filter_applied = bandpass_used || line_used;

        if epoching_applied && isfield(EEG_pre,'data') && ndims(EEG_pre.data) >= 2
            final_epoch_pts = size(EEG_pre.data, 2);
            final_epoch_ms  = [eff_pre_ms, eff_post_ms];
        else
            final_epoch_pts = NaN;
            final_epoch_ms  = [NaN, NaN];
        end

        % Build a scalar provenance struct via dot-assignments (robust to non-scalars)
        preproc = struct();
        preproc.applied           = true;
        preproc.timestamp         = dtISO;
        preproc.options_requested = PreprocOptions;

        eff = struct();
        % Block A (continuous cleaning)
        eff.reref              = logical(PreprocOptions.reref);
        eff.refchan            = PreprocOptions.refchan;
        eff.resample           = logical(PreprocOptions.resample);
        eff.srate              = PreprocOptions.srate;
        eff.final_srate        = EEG_pre.srate;
        eff.filter             = logical(PreprocOptions.filter);
        eff.highpass           = PreprocOptions.highpass;
        eff.lowpass            = PreprocOptions.lowpass;
        eff.linefilter         = logical(PreprocOptions.linefilter);
        eff.cleanline          = logical(PreprocOptions.cleanline);
        eff.linefreq           = PreprocOptions.linefreq;

        % Event cleanup / counts
        eff.deleteNAevents     = logical(PreprocOptions.deleteNAevents);
        eff.events_total_before = ev_total_before;
        eff.events_total_after  = ev_total_after;
        eff.na_events_removed   = na_removed_count;

        % Block C (offset/dummy events)
        eff.offsetevents        = logical(PreprocOptions.offsetevents);
        eff.offsetfrom          = PreprocOptions.src_types;
        eff.offset_eventtype    = PreprocOptions.new_types;
        eff.offset_annot        = PreprocOptions.annotation_for_dummies;
        eff.offset              = PreprocOptions.offset_ms;
        eff.offset_policy       = PreprocOptions.offset_policy;
        eff.dummy_events_added  = dummy_added_count;
        eff.per_dummy_added     = per_dummy_added;
        eff.skipped_oob_count   = skipped_oob_count;

        % Block D (epoching/baseline)
        eff.epoching            = logical(PreprocOptions.epoching);
        eff.epochevents         = epNorm;
        eff.baseadjust          = logical(PreprocOptions.baseadjust);
        eff.epochlimpre         = eff_pre_ms;
        eff.epochlimpost        = eff_post_ms;
        eff.epoching_applied    = logical(epoching_applied);
        eff.baseline_applied    = logical(baseline_applied);

        % Derived summary
        eff.filter_applied      = logical(filter_applied);
        eff.final_epoch_pts     = final_epoch_pts;
        eff.final_epoch_ms      = final_epoch_ms;

        % Attach effective options into provenance and store on EEG
        preproc.options_effective = eff;
        EEG_pre.etc.simple.preproc = preproc;
        % -------------------------------------------------------------------------------------------------------

        % Save the processed dataset.
        outDirC  = char(outDir);
        outNameC = char(outName);
        EEG_pre.filepath = outDirC;
        EEG_pre.filename = outNameC;

        pop_saveset(EEG_pre, 'filename', outNameC, 'filepath', outDirC, 'savemode', 'onefile');
        fprintf('   -> saved OK (%s)  [trials=%d, srate=%g]\n', fullfile(char(relOut), char(outName)), EEG_pre.trials, EEG_pre.srate);
        processed = processed + 1;

    catch ME
        fprintf('   [error] Row %d failed: %s\n', r, ME.message);
        failed = failed + 1;
        continue
    end
end

%%  Summary

fprintf('\nPreprocessing complete.\n');
fprintf('  Files saved:           %d / %d\n', processed, totalToDo);
fprintf('  Skipped (no epochs):   %d\n', skippedNoEpochs);
fprintf('  Skipped (missing raw): %d\n', skippedMissingSrc);
fprintf('  Failed (errors):       %d\n', failed);

log_command_window('stop');
