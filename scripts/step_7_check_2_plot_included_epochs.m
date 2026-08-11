%% step_7_check_2_plot_included_epochs.m
% Purpose
%   Plot individual epoch–channel items from screened pooled outputs (Step 6.3),
%   paging through as many 3×3 subplot figures as needed. Figures are displayed only
%   (not saved). Excluded epoch–channel items are omitted.
%
% Inputs
%   <baseDir>/data/summary/screening/pooled_screened_eeg_epochs.mat
%     - variable: epochs_pooled (struct array; one element per dataset)
%     - each dataset includes: Exclude [n_channels x n_epochs] logical
%
%   <baseDir>/data/summary/screening/pooled_screened_eeg_nrf_features.csv
%     - used only if overlayNRF == true (stored fit params, no refitting)
%     - includes: Exclude (0/1); included rows are Exclude == 0
%
% High-level behaviour
%   1) User selects:
%        - filter mode: eventtype OR eventannotation (exact match)
%        - filter value
%        - channel (case-insensitive match)
%        - optional NRF overlay: on/off + list of NRFName(s)
%   2) Build one struct "PLOT" containing all time series + metadata required
%      for plotting:
%        PLOT.X          : [n_points x 1] time (ms)
%        PLOT.Y          : [n_points x n_series x n_items] (EEG + optional NRF overlays)
%        PLOT.seriesNames: [1 x n_series] (EEG + NRFName list)
%        PLOT.epochMeta  : table (one row per item)
%        PLOT.plotTitle  : [n_items x 1] subplot titles
%        PLOT.selection  : requested route and missing-channel identities
%   3) Sort items by: subjectID, sessionID, runID, epoch_index (numeric), channel
%   4) Clear everything except PLOT.
%   5) Set plot styling variables (user-editable) then plot (3×3 paging).
%
% Notes
%   - Channel matching is case-insensitive.
%   - eventtype / eventannotation matching is exact (case-sensitive).
%   - Exclusion is enforced per epoch–channel item:
%       • MAT: excluded if epochs_pooled(d).Exclude(ch,e) == true
%       • NRF CSV: included rows are Exclude == 0
%     The MAT and every requested NRF row must agree exactly before plotting.
%   - NRF overlays use stored shift_samples + fglsCoef + projectionTimes_ms.
%   - Every requested overlay must be present exactly once; missing rows error.
%   - If an NRF overlay window is out of bounds, the script errors and stops.
%   - If duplicate NRF rows exist for a given item+NRFName, the script errors and stops.
%   - No legends.

log_command_window('start');
clear; clc;

%% 1) Paths and environment
baseDir  = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
pooledDir = fullfile(baseDir, 'data', 'summary', 'screening');

epochsMatPath = fullfile(pooledDir, 'pooled_screened_eeg_epochs.mat');
nrfCsvPath    = fullfile(pooledDir, 'pooled_screened_eeg_nrf_features.csv');

functionsFolder = fullfile(baseDir, 'functions');
if exist(functionsFolder, 'dir')
    addpath(functionsFolder);
end

assert(isfile(epochsMatPath), 'Missing file: %s', epochsMatPath);
developerRoot = fileparts(baseDir);
assert(is_local_child(baseDir, pooledDir) && ...
    is_local_child(baseDir, epochsMatPath) && ...
    is_local_child(baseDir, nrfCsvPath) && ...
    is_local_child(baseDir, functionsFolder), ...
    'Strasbourg inputs, functions, and prospective log/output paths must remain local.');

% Launch EEGLAB interactively to ensure SIMPLE plugin paths (incl. NRFs) are on the MATLAB path.
% Do NOT use eeglab nogui here.
eeglab;

%% 2) User-configurable parameters (selection only; plot styling comes later)
% Filter mode (choose exactly one)
%   filterMode = "eventtype"
%   filterMode = "eventannotation"
filterMode  = "eventtype";
filterValue = "cannula";   % exact match (case-sensitive)

% Channel to plot (case-insensitive match)
channelRequested = "Cz";

% NRF overlays
overlayNRF = true;  % true/false
nrfNamesRequested = { ...
    'noxious_preterm_NRF_500Hz' ...
    };

assert(isstring(filterMode) && isscalar(filterMode) && ...
    (filterMode == "eventtype" || filterMode == "eventannotation"), ...
    'filterMode must be "eventtype" or "eventannotation".');
filterValue = string(filterValue);
channelRequested = string(channelRequested);
assert(isscalar(filterValue) && ~ismissing(filterValue) && strlength(filterValue) > 0, ...
    'filterValue must be a nonblank string scalar.');
assert(isscalar(channelRequested) && ~ismissing(channelRequested) && ...
    strlength(strtrim(channelRequested)) > 0, ...
    'channelRequested must be a nonblank string scalar.');
assert(islogical(overlayNRF) && isscalar(overlayNRF), ...
    'overlayNRF must be a logical scalar.');

if overlayNRF
    requestedNames = string(nrfNamesRequested(:));
    assert(~isempty(requestedNames) && numel(requestedNames) <= 3 && ...
        all(~ismissing(requestedNames)) && all(strlength(strtrim(requestedNames)) > 0), ...
        'nrfNamesRequested must contain one to three nonblank names when overlayNRF is true.');
    requestedNames = strtrim(requestedNames);
    assert(numel(unique(requestedNames)) == numel(requestedNames), ...
        'nrfNamesRequested must not contain duplicate names.');
    nrfNamesRequested = cellstr(requestedNames);
else
    requestedNames = strings(0, 1);
    nrfNamesRequested = {};
end

targetCh = upper(strtrim(channelRequested));

%% 3) Load screened pooled epochs
S = load(epochsMatPath);
assert(isfield(S, 'epochs_pooled'), 'Expected variable "epochs_pooled" in %s', epochsMatPath);
epochs_pooled = S.epochs_pooled;
assert(isstruct(epochs_pooled) && ~isempty(epochs_pooled), ...
    'epochs_pooled must be a non-empty struct array in %s', epochsMatPath);

candidateRows = table('Size', [0 11], ...
    'VariableTypes', {'double','double','double','string','string','string','double','string','string','string','logical'}, ...
    'VariableNames', {'dataset_idx','channel_pos','epoch_pos','subjectID','sessionID','runID', ...
    'epoch_index','channel','eventtype','eventannotation','mat_exclude'});
missingRequestedChannel = strings(0, 1);

% Fail-fast: validate every pooled dataset before constructing any plot.
for d = 1:numel(epochs_pooled)
    D = epochs_pooled(d);

    requiredFields = {'data','times_ms','channels','epoch_index','eventtype','eventannotation', ...
        'subjectID','sessionID','runID','srate','Exclude'};
    for fieldIndex = 1:numel(requiredFields)
        assert(isfield(D, requiredFields{fieldIndex}), ...
            'Dataset %d is missing required field: %s', d, requiredFields{fieldIndex});
    end

    assert(isnumeric(D.data) && isreal(D.data) && ndims(D.data) <= 3, ...
        'Dataset %d: data must be a real numeric [nCh x nPoints x nEpochs] array.', d);
    assert(all(isfinite(D.data(:))), 'Dataset %d: data contain NaN or Inf.', d);
    nCh = size(D.data, 1);
    nPoints = size(D.data, 2);
    nEp = size(D.data, 3);
    assert(nCh >= 1 && nPoints >= 2 && nEp >= 1, ...
        'Dataset %d: data dimensions are not usable.', d);

    channelLabels = normalise_text_vector(D.channels, nCh, 'channels', d, false);
    assert(numel(unique(upper(channelLabels))) == nCh, ...
        'Dataset %d: channel labels must be unique case-insensitively.', d);
    eventTypes = normalise_text_vector(D.eventtype, nEp, 'eventtype', d, true);
    eventAnnotations = normalise_text_vector(D.eventannotation, nEp, 'eventannotation', d, true);

    assert(isnumeric(D.epoch_index) && isreal(D.epoch_index) && numel(D.epoch_index) == nEp && ...
        all(isfinite(D.epoch_index(:))) && all(D.epoch_index(:) == fix(D.epoch_index(:))) && ...
        numel(unique(double(D.epoch_index(:)))) == nEp, ...
        'Dataset %d: epoch_index must contain one unique finite integer per epoch.', d);
    epochIndices = double(D.epoch_index(:));

    timesHere = double(D.times_ms(:));
    assert(isnumeric(D.times_ms) && isreal(D.times_ms) && numel(timesHere) == nPoints && ...
        all(isfinite(timesHere)) && all(diff(timesHere) > 0), ...
        'Dataset %d: times_ms must be finite, strictly increasing, and match data.', d);
    assert(isnumeric(D.srate) && isreal(D.srate) && isscalar(D.srate) && ...
        isfinite(D.srate) && D.srate > 0, ...
        'Dataset %d: srate must be a positive finite numeric scalar.', d);
    expectedDt = 1000 / double(D.srate);
    dtTolerance = max(1e-9, abs(expectedDt) * 1e-6);
    assert(all(abs(diff(timesHere) - expectedDt) <= dtTolerance), ...
        'Dataset %d: times_ms spacing is inconsistent with srate.', d);

    assert(islogical(D.Exclude) && isequal(size(D.Exclude), [nCh, nEp]), ...
        'Dataset %d: Exclude must be logical with exact size [%d x %d].', d, nCh, nEp);

    subjectID = normalise_text_scalar(D.subjectID, 'subjectID', d);
    sessionID = normalise_text_scalar(D.sessionID, 'sessionID', d);
    runID = normalise_text_scalar(D.runID, 'runID', d);

    channelMatches = find(upper(channelLabels) == targetCh);
    if isempty(channelMatches)
        missingRequestedChannel(end + 1, 1) = subjectID + "|" + sessionID + "|" + runID; %#ok<SAGROW>
        continue
    end
    assert(numel(channelMatches) == 1, ...
        'Dataset %d: requested channel has more than one case-insensitive match.', d);
    channelPosition = channelMatches(1);

    if filterMode == "eventtype"
        eventMask = eventTypes == filterValue;
    else
        eventMask = eventAnnotations == filterValue;
    end
    selectedEpochs = find(eventMask);
    if isempty(selectedEpochs)
        continue
    end

    nSelected = numel(selectedEpochs);
    selectedRows = table( ...
        repmat(d, nSelected, 1), repmat(channelPosition, nSelected, 1), selectedEpochs(:), ...
        repmat(subjectID, nSelected, 1), repmat(sessionID, nSelected, 1), repmat(runID, nSelected, 1), ...
        epochIndices(selectedEpochs), repmat(channelLabels(channelPosition), nSelected, 1), ...
        eventTypes(selectedEpochs), eventAnnotations(selectedEpochs), ...
        reshape(D.Exclude(channelPosition, selectedEpochs), [], 1), ...
        'VariableNames', candidateRows.Properties.VariableNames);
    candidateRows = [candidateRows; selectedRows]; %#ok<AGROW>
end

assert(~isempty(candidateRows), ...
    'No items matched: filterMode=%s, filterValue=%s, channel=%s', ...
    filterMode, filterValue, channelRequested);
candidateKeys = candidateRows(:, {'subjectID','sessionID','runID','epoch_index','channel'});
candidateKeys.channel = upper(candidateKeys.channel);
assert(height(unique(candidateKeys, 'rows')) == height(candidateKeys), ...
    'The selected MAT items do not have unique subject/session/run/epoch/channel keys.');

fprintf('Datasets without requested channel %s: %d\n', channelRequested, numel(missingRequestedChannel));

%% 4) Load screened pooled NRF CSV (only if overlayNRF)
% Read as strings for ID columns to preserve leading zeros (sessionID/runID).
if overlayNRF
    assert(isfile(nrfCsvPath), 'overlayNRF is true, but NRF CSV is missing: %s', nrfCsvPath);

    optsNRF = detectImportOptions(nrfCsvPath, 'PreserveVariableNames', true, 'TextType', 'string');
    idCols = {'subjectID','sessionID','runID','channel','eventtype','eventannotation','NRFName'};
    assert(all(ismember(idCols, optsNRF.VariableNames)), ...
        'NRF CSV is missing one or more required identity/event columns.');
    optsNRF = setvartype(optsNRF, idCols, 'string');

    Tnrf_all = readtable(nrfCsvPath, optsNRF);
    assert(~isempty(Tnrf_all), 'NRF CSV is empty: %s', nrfCsvPath);

    % Normalise key string fields (trim; missing -> "")
    for k = 1:numel(idCols)
        c = idCols{k};
        Tnrf_all.(c) = strtrim(string(Tnrf_all.(c)));
        Tnrf_all.(c)(ismissing(Tnrf_all.(c))) = "";
    end

    % Coerce numeric columns we will use
    needNum = {'epoch_index','projectionTimes_ms','shift_samples','fglsCoef'};
    for k = 1:numel(needNum)
        c = needNum{k};
        assert(any(strcmp(Tnrf_all.Properties.VariableNames, c)), ...
            'NRF CSV is missing required numeric column: %s', c);
        assert((isnumeric(Tnrf_all.(c)) || islogical(Tnrf_all.(c))) && ...
            isreal(Tnrf_all.(c)) && isvector(Tnrf_all.(c)) && ...
            numel(Tnrf_all.(c)) == height(Tnrf_all), ...
            'NRF CSV column %s must be a real numeric vector.', c);
        Tnrf_all.(c) = double(Tnrf_all.(c));
    end

    % Require a finite binary Exclude flag before checking MAT/CSV agreement.
    assert(any(strcmp(Tnrf_all.Properties.VariableNames, 'Exclude')), ...
        'Screened NRF CSV is missing required column: Exclude');
    assert((isnumeric(Tnrf_all.Exclude) || islogical(Tnrf_all.Exclude)) && ...
        isreal(Tnrf_all.Exclude) && isvector(Tnrf_all.Exclude) && ...
        numel(Tnrf_all.Exclude) == height(Tnrf_all), ...
        'NRF CSV Exclude column must be a real numeric/logical vector.');
    Tnrf_all.Exclude = double(Tnrf_all.Exclude);
    assert(all(isfinite(Tnrf_all.Exclude)), 'NRF CSV Exclude column contains non-finite values.');
    assert(all(ismember(unique(Tnrf_all.Exclude), [0 1])), 'NRF CSV Exclude column must be 0/1 only.');

    % Keep only rows relevant to the exact requested route.
    keep = ismember(Tnrf_all.NRFName, requestedNames) & ...
        upper(Tnrf_all.channel) == targetCh;
    if filterMode == "eventtype"
        keep = keep & Tnrf_all.eventtype == filterValue;
    else
        keep = keep & Tnrf_all.eventannotation == filterValue;
    end
    Tnrf = Tnrf_all(keep, :);
    assert(~isempty(Tnrf), 'No requested NRF rows remain after route filtering.');

    requiredNonblank = {'subjectID','sessionID','runID','channel','NRFName'};
    for k = 1:numel(requiredNonblank)
        c = requiredNonblank{k};
        assert(all(strlength(Tnrf.(c)) > 0), ...
            'Selected NRF column %s contains a blank key.', c);
    end
    assert(all(isfinite(Tnrf.epoch_index)) && ...
        all(Tnrf.epoch_index == fix(Tnrf.epoch_index)), ...
        'Selected NRF epoch_index values must be finite integers.');
    assert(all(isfinite(Tnrf.projectionTimes_ms)) && all(isfinite(Tnrf.shift_samples)) && ...
        all(isfinite(Tnrf.fglsCoef)) && all(Tnrf.shift_samples == round(Tnrf.shift_samples)), ...
        'Selected NRF fit parameters must be finite, with integer shift_samples.');

    % Require one exact requested fit per MAT item/template and identical flags.
    matchedNRFRows = false(height(Tnrf), 1);
    for itemIndex = 1:height(candidateRows)
        item = candidateRows(itemIndex, :);
        for nameIndex = 1:numel(requestedNames)
            hit = find( ...
                Tnrf.subjectID == item.subjectID & ...
                Tnrf.sessionID == item.sessionID & ...
                Tnrf.runID == item.runID & ...
                Tnrf.epoch_index == item.epoch_index & ...
                upper(Tnrf.channel) == upper(item.channel) & ...
                Tnrf.eventtype == item.eventtype & ...
                Tnrf.eventannotation == item.eventannotation & ...
                Tnrf.NRFName == requestedNames(nameIndex));
            assert(numel(hit) == 1, ...
                ['Expected exactly one requested NRF row for %s|%s|%s|epoch=%g|%s|%s; ' ...
                 'found %d.'], ...
                item.subjectID, item.sessionID, item.runID, item.epoch_index, ...
                item.channel, requestedNames(nameIndex), numel(hit));
            assert(logical(Tnrf.Exclude(hit)) == item.mat_exclude, ...
                ['MAT/CSV Exclude mismatch for %s|%s|%s|epoch=%g|%s|%s. ' ...
                 'Rerun or repair the screened outputs before plotting.'], ...
                item.subjectID, item.sessionID, item.runID, item.epoch_index, ...
                item.channel, requestedNames(nameIndex));
            matchedNRFRows(hit) = true;
        end
    end
    assert(all(matchedNRFRows), ...
        'Selected NRF rows contain keys that are not present in the requested MAT item set.');

    % Only included rows reach the plotting join after exact agreement is proven.
    Tnrf = Tnrf(Tnrf.Exclude == 0, :);
else
    Tnrf = table();
end

%% 5) Load NRF templates once (only if overlayNRF)
% Each template file must contain NRF (vector) and fs (Hz).
if overlayNRF
    nReq = numel(nrfNamesRequested);
    nrfTemplates = struct('name', cell(nReq,1), 'NRF', [], 'fs', NaN, 'L', NaN, 'meanNRF', NaN);

    for j = 1:nReq
        nm = string(nrfNamesRequested{j});
        nrfTemplates(j).name = nm;

        nrfFile = which(char(nm + ".mat"));
        assert(~isempty(nrfFile), 'NRF template not found on path: %s.mat', nm);
        assert(is_local_child(developerRoot, nrfFile), ...
            'Resolved NRF template must remain beneath the local simple-eeg development root: %s', nrfFile);

        T = load(nrfFile);
        assert(isfield(T, 'NRF') && isfield(T, 'fs'), 'NRF file must contain variables NRF and fs: %s', nrfFile);

        nrfVec = T.NRF(:);
        fs = double(T.fs);

        assert(isnumeric(nrfVec) && isreal(nrfVec) && numel(nrfVec) >= 2 && ...
            all(isfinite(nrfVec)), 'NRF must be a finite real numeric vector in: %s', nrfFile);
        assert(isnumeric(T.fs) && isreal(T.fs) && isscalar(T.fs) && ...
            isfinite(fs) && fs > 0, 'Bad fs in: %s', nrfFile);

        nrfTemplates(j).NRF = double(nrfVec);
        nrfTemplates(j).fs  = fs;
        nrfTemplates(j).L   = numel(nrfVec);
        nrfTemplates(j).meanNRF = mean(double(nrfVec));
    end
end

%% 6) Determine number of items to plot (first pass)
n_items_total = sum(~candidateRows.mat_exclude);

assert(n_items_total > 0, ...
    'No items matched: filterMode=%s, filterValue=%s, channel=%s', ...
    filterMode, filterValue, channelRequested);

%% 7) Build the single plotting struct PLOT (second pass)
seriesNames = ["EEG"];
if overlayNRF
    seriesNames = [seriesNames, string(nrfNamesRequested(:))'];
end
n_series = numel(seriesNames);

% Preallocate metadata arrays (one entry per plotted item)
meta_subjectID      = strings(n_items_total, 1);
meta_sessionID      = strings(n_items_total, 1);
meta_runID          = strings(n_items_total, 1);
meta_epoch_index    = nan(n_items_total, 1);
meta_channel        = strings(n_items_total, 1);
meta_eventtype      = strings(n_items_total, 1);
meta_eventannotation= strings(n_items_total, 1);
plotTitle           = strings(n_items_total, 1);

PLOT = struct();
PLOT.X = [];
PLOT.Y = [];  % allocated when we learn n_points from the first contributing dataset
PLOT.seriesNames = seriesNames;
PLOT.epochMeta = table();
PLOT.plotTitle = [];
PLOT.selection = struct( ...
    'filterMode', filterMode, ...
    'filterValue', filterValue, ...
    'channelRequested', channelRequested, ...
    'overlayNRF', overlayNRF, ...
    'nrfNamesRequested', requestedNames, ...
    'missingOverlayPolicy', "error", ...
    'datasetsMissingRequestedChannel', missingRequestedChannel);

itemCounter = 0;
Y_allocated = false;

% We enforce a single X for all items. The first contributing dataset defines X.
for d = 1:numel(epochs_pooled)
    D = epochs_pooled(d);

    % Channel index (case-insensitive)
    chLabels = normalise_text_vector(D.channels, size(D.data, 1), 'channels', d, false);
    chUpper = upper(chLabels);
    idxCh = find(chUpper == targetCh);
    if isempty(idxCh)
        continue
    end
    assert(numel(idxCh) == 1, 'Dataset %d: requested channel match became ambiguous.', d);
    channelLabelOriginal = strtrim(chLabels(idxCh));

    % Time axis for this dataset
    timesHere = double(D.times_ms(:));
    assert(isvector(timesHere) && all(isfinite(timesHere)), 'times_ms must be a finite vector.');
    n_points_here = numel(timesHere);

    if isempty(PLOT.X)
        PLOT.X = timesHere;
    else
        % Enforce identical X across all contributing datasets
        assert(numel(PLOT.X) == n_points_here, 'times_ms length mismatch across datasets.');
        assert(all(PLOT.X == timesHere), 'times_ms values differ across datasets. Cannot build a single PLOT.X.');
    end

    % Allocate PLOT.Y once we know n_points
    if ~Y_allocated
        PLOT.Y = nan(n_points_here, n_series, n_items_total);
        Y_allocated = true;

        % If overlayNRF, enforce template sampling rate matches effective sample rate from X
        if overlayNRF
            dt_ms = median(diff(PLOT.X));
            assert(isfinite(dt_ms) && dt_ms > 0, 'Invalid time axis: times_ms must be strictly increasing.');
            srate_eff = 1000 / dt_ms;

            for j = 1:numel(nrfTemplates)
                fs = nrfTemplates(j).fs;
                tol_fs = max(1e-9, 1e-6 * fs);
                assert(abs(fs - srate_eff) <= tol_fs, ...
                    'Sampling rate mismatch: template %s fs=%.9g Hz, epoch rate=%.9g Hz', ...
                    nrfTemplates(j).name, fs, srate_eff);
            end
        end
    end

    % Epoch selection mask
    evType = normalise_text_vector(D.eventtype, size(D.data, 3), 'eventtype', d, true);
    evAnnot = normalise_text_vector(D.eventannotation, size(D.data, 3), 'eventannotation', d, true);

    if filterMode == "eventtype"
        mask_event = (evType == string(filterValue));
    else
        mask_event = (evAnnot == string(filterValue));
    end

    % Exclusion mask for requested channel (included == ~Exclude)
    exCh = D.Exclude(idxCh, :);
    mask_included = ~exCh(:);

    mask_final = mask_event(:) & mask_included;

    % Indices of selected epochs, in existing order
    selIdx = find(mask_final);
    if isempty(selIdx)
        continue
    end

    % IDs for this dataset
    subj = normalise_text_scalar(D.subjectID, 'subjectID', d);
    sess = normalise_text_scalar(D.sessionID, 'sessionID', d);
    run  = normalise_text_scalar(D.runID, 'runID', d);

    epochIndexAll = double(D.epoch_index(:));

    % Loop selected epochs
    for ii = 1:numel(selIdx)
        e = selIdx(ii);

        itemCounter = itemCounter + 1;

        % EEG trace for this epoch–channel
        y_eeg = squeeze(D.data(idxCh, :, e));
        y_eeg = double(y_eeg(:));

        assert(numel(y_eeg) == numel(PLOT.X), 'EEG trace length does not match PLOT.X.');

        % Store EEG as series 1
        PLOT.Y(:, 1, itemCounter) = y_eeg;

        % Store metadata
        meta_subjectID(itemCounter)       = subj;
        meta_sessionID(itemCounter)       = sess;
        meta_runID(itemCounter)           = run;
        meta_epoch_index(itemCounter)     = epochIndexAll(e);
        meta_channel(itemCounter)         = channelLabelOriginal;
        meta_eventtype(itemCounter)       = evType(e);
        meta_eventannotation(itemCounter) = evAnnot(e);

        % Build subplot title exactly:
        % subjectID | sessionID | runID | epoch_index | eventtype | eventannotation
        plotTitle(itemCounter) = subj + " | " + sess + " | " + run + " | " + ...
            string(epochIndexAll(e)) + " | " + evType(e) + " | " + evAnnot(e);

        % NRF overlays (if enabled)
        if overlayNRF
            for j = 1:numel(nrfNamesRequested)
                nrfName = string(nrfNamesRequested{j});
                seriesCol = 1 + j;

                % Find matching NRF row(s) for this item + NRFName
                % Keys: subjectID, sessionID, runID, epoch_index, channel (case-insensitive), NRFName
                assert(~isempty(Tnrf), ...
                    'Requested NRF table is unexpectedly empty while overlays are enabled.');

                keyMask = (Tnrf.subjectID == subj) & ...
                    (Tnrf.sessionID == sess) & ...
                    (Tnrf.runID == run) & ...
                    (Tnrf.epoch_index == epochIndexAll(e)) & ...
                    (upper(Tnrf.channel) == upper(channelLabelOriginal)) & ...
                    (Tnrf.NRFName == nrfName);

                hit = find(keyMask);

                assert(~isempty(hit), ...
                    ['Requested NRF overlay is missing for %s | %s | %s | ' ...
                     'epoch_index=%g | channel=%s | NRFName=%s'], ...
                    subj, sess, run, epochIndexAll(e), channelLabelOriginal, nrfName);

                if numel(hit) > 1
                    error('Duplicate NRF rows found for %s | %s | %s | epoch_index=%g | channel=%s | NRFName=%s', ...
                        subj, sess, run, epochIndexAll(e), channelLabelOriginal, nrfName);
                end

                row = Tnrf(hit, :);

                % Extract stored fit parameters
                proj_ms = double(row.projectionTimes_ms);
                shift_s = double(row.shift_samples);
                scale   = double(row.fglsCoef);

                assert(isfinite(proj_ms) && isfinite(shift_s) && isfinite(scale), ...
                    'Non-finite NRF fit parameters for NRFName=%s', nrfName);

                % shift_samples must be an integer (index shift)
                shift_round = round(shift_s);
                assert(abs(shift_s - shift_round) < 1e-6, ...
                    'shift_samples is not an integer (NRFName=%s): %g', nrfName, shift_s);
                shift_s = shift_round;

                % Locate template for this nrfName (already loaded)
                idxTpl = find(string({nrfTemplates.name}) == nrfName, 1, 'first');
                assert(~isempty(idxTpl), 'Internal error: template not loaded for NRFName=%s', nrfName);

                NRF = nrfTemplates(idxTpl).NRF;
                L   = nrfTemplates(idxTpl).L;
                meanNRF = nrfTemplates(idxTpl).meanNRF;

                % Anchor index i0 is the nearest time sample to projectionTimes_ms
                [~, i0] = min(abs(PLOT.X - proj_ms));

                % Template start index s_best
                s_best = i0 + shift_s;

                % Bounds check (error and stop)
                assert(s_best >= 1, 'NRF window out of bounds (start < 1) for NRFName=%s', nrfName);
                assert((s_best + L - 1) <= numel(PLOT.X), ...
                    'NRF window out of bounds (end > n_points) for NRFName=%s', nrfName);

                % Compute offset so the scaled template overlays the EEG segment mean
                y_seg = y_eeg(s_best : s_best + L - 1);
                assert(all(isfinite(y_seg)), ...
                    'Non-finite EEG samples under NRF window for NRFName=%s (cannot compute offset)', nrfName);

                offset = mean(y_seg) - scale * meanNRF;

                % Build NaN-padded overlay vector
                overlay_ts = nan(numel(PLOT.X), 1);
                overlay_ts(s_best : s_best + L - 1) = offset + scale * NRF;

                % Store in PLOT
                PLOT.Y(:, seriesCol, itemCounter) = overlay_ts;
            end
        end
    end
end

assert(itemCounter == n_items_total, 'Internal error: itemCounter mismatch (%d vs %d).', itemCounter, n_items_total);
assert(~isempty(PLOT.X) && ~isempty(PLOT.Y), 'Internal error: PLOT was not populated.');
assert(isreal(PLOT.Y) && ~any(isinf(PLOT.Y(:))), ...
    'PLOT.Y must contain only real finite values or intentional NaN overlay padding.');

% Build epochMeta table and attach
PLOT.epochMeta = table( ...
    meta_subjectID, meta_sessionID, meta_runID, meta_epoch_index, meta_channel, meta_eventtype, meta_eventannotation, ...
    'VariableNames', {'subjectID','sessionID','runID','epoch_index','channel','eventtype','eventannotation'} ...
    );

PLOT.plotTitle = plotTitle;

%% 8) Sort items by: subjectID, sessionID, runID, epoch_index (numeric), channel
% (This reorders epochMeta, plotTitle, and Y together.)
sortKey = PLOT.epochMeta(:, {'subjectID','sessionID','runID','epoch_index','channel'});
[~, idxSort] = sortrows(sortKey, {'subjectID','sessionID','runID','epoch_index','channel'});

PLOT.epochMeta = PLOT.epochMeta(idxSort, :);
PLOT.plotTitle = PLOT.plotTitle(idxSort);
PLOT.Y         = PLOT.Y(:, :, idxSort);

%% 9) Clear everything except the plotting struct
clearvars -except PLOT

%% 10) Plot appearance settings (user-editable)
% Fonts
axisFontSize  = 10;
titleFontSize = 9;

% Line widths
eegLineWidth  = 1.0;
nrfLineWidth  = 1.0;
zeroLineWidth = 1.0;

% Colours
eegColor      = [0 0.4470 0.7410];  % explicit MATLAB default blue
zeroLineColor = [0.8 0.8 0.8];      % light grey

% Up to three NRF colours, used in order for however many NRF series exist.
% The active Strasbourg preterm overlay is first and remains red.
nrfColors = [ ...
    [1 0 0]; ...             % red: noxious_preterm_NRF_500Hz
    [20 204 204] / 255; ...  % cyan spare
    [0 0.5 0] ...            % dark-green spare
    ];

% Fixed y-axis limits (default ±150 µV)
yLim_uV = [-150 150];

% X-limits auto-fit to PLOT.X
xLim_ms = [min(PLOT.X) max(PLOT.X)];

% Optional: grid (default off)
useGrid = false;

validateattributes(axisFontSize, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'axisFontSize');
validateattributes(titleFontSize, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'titleFontSize');
validateattributes(eegLineWidth, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'eegLineWidth');
validateattributes(nrfLineWidth, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'nrfLineWidth');
validateattributes(zeroLineWidth, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'zeroLineWidth');
validateattributes(yLim_uV, {'numeric'}, {'real','finite','vector','numel',2,'increasing'}, mfilename, 'yLim_uV');
assert(isnumeric(eegColor) && isreal(eegColor) && isequal(size(eegColor), [1 3]) && ...
    all(isfinite(eegColor)) && all(eegColor >= 0 & eegColor <= 1), ...
    'eegColor must be a finite RGB triplet in [0,1].');
assert(isnumeric(zeroLineColor) && isreal(zeroLineColor) && isequal(size(zeroLineColor), [1 3]) && ...
    all(isfinite(zeroLineColor)) && all(zeroLineColor >= 0 & zeroLineColor <= 1), ...
    'zeroLineColor must be a finite RGB triplet in [0,1].');
assert(isnumeric(nrfColors) && isreal(nrfColors) && size(nrfColors, 2) == 3 && ...
    all(isfinite(nrfColors(:))) && all(nrfColors(:) >= 0 & nrfColors(:) <= 1), ...
    'nrfColors must contain finite RGB rows in [0,1].');
assert(islogical(useGrid) && isscalar(useGrid), 'useGrid must be a logical scalar.');

%% 11) Plot: 3×3 subplots per figure, as many figures as needed (no saving)
n_items = size(PLOT.Y, 3);
n_per_fig = 9;
n_figs = ceil(n_items / n_per_fig);

% Determine number of NRF series in PLOT (series 1 is EEG)
n_nrf = numel(PLOT.seriesNames) - 1;
assert(n_nrf <= size(nrfColors, 1), ...
    'More NRF series (%d) than available colours (%d). Add more colours or reduce NRF list.', ...
    n_nrf, size(nrfColors, 1));

for f = 1:n_figs
    startIdx = (f - 1) * n_per_fig + 1;
    endIdx   = min(f * n_per_fig, n_items);

    figure('Name', sprintf('Epoch plots %d/%d', f, n_figs), 'NumberTitle', 'off');

    localCount = 0;
    for itemIdx = startIdx:endIdx
        localCount = localCount + 1;

        subplot(3, 3, localCount);
        hold on;

        % EEG
        plot(PLOT.X, PLOT.Y(:, 1, itemIdx), 'LineWidth', eegLineWidth, 'Color', eegColor);

        % NRF overlays (if any)
        for j = 1:n_nrf
            seriesCol = 1 + j;
            plot(PLOT.X, PLOT.Y(:, seriesCol, itemIdx), 'LineWidth', nrfLineWidth, 'Color', nrfColors(j, :));
        end

        % Vertical dashed line at t = 0
        xline(0, '--', 'Color', zeroLineColor, 'LineWidth', zeroLineWidth);

        % Axes
        xlim(xLim_ms);
        ylim(yLim_uV);
        set(gca, 'FontSize', axisFontSize);
        set(gca, 'YDir', 'reverse');

        if useGrid
            grid on;
        else
            grid off;
        end

        % Title (Interpreter off to avoid surprises with underscores)
        title(PLOT.plotTitle(itemIdx), 'FontSize', titleFontSize, 'Interpreter', 'none');

        hold off;
    end
end

log_command_window('stop');

function values = normalise_text_vector(rawValues, expectedCount, fieldName, datasetIndex, allowBlank)
assert(iscell(rawValues) || isstring(rawValues) || ischar(rawValues) || iscategorical(rawValues), ...
    'Dataset %d: %s must contain text values.', datasetIndex, fieldName);
if ischar(rawValues)
    values = string(cellstr(rawValues));
    values = values(:);
else
    values = string(rawValues(:));
end
assert(numel(values) == expectedCount, ...
    'Dataset %d: %s must contain exactly %d values.', datasetIndex, fieldName, expectedCount);
values = strtrim(values);
values(ismissing(values)) = "";
if ~allowBlank
    assert(all(strlength(values) > 0), ...
        'Dataset %d: %s contains a blank value.', datasetIndex, fieldName);
end
end

function value = normalise_text_scalar(rawValue, fieldName, datasetIndex)
value = string(rawValue);
assert(isscalar(value) && ~ismissing(value), ...
    'Dataset %d: %s must be a nonmissing text scalar.', datasetIndex, fieldName);
value = strtrim(value);
assert(strlength(value) > 0, ...
    'Dataset %d: %s must be nonblank.', datasetIndex, fieldName);
end

function tf = is_local_child(basePath, targetPath)
baseCanonical = string(char(java.io.File(basePath).getCanonicalPath()));
targetCanonical = string(char(java.io.File(targetPath).getCanonicalPath()));
tf = startsWith(targetCanonical, baseCanonical + string(filesep));
end
