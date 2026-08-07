%% step_5_sum_4_plot_epochs.m
% Purpose
%   Plot individual epoch–channel items from pooled outputs (Step 5.3), paging
%   through as many 3×3 subplot figures as needed. Figures are displayed only
%   (not saved).
%
% Inputs
%   <baseDir>/data/summary/pooled/pooled_eeg_epochs.mat
%     - variable: epochs_pooled (struct array; one element per dataset)
%
%   <baseDir>/data/summary/pooled/pooled_eeg_nrf_features.csv
%     - used only if overlayNRF == true (stored fit params, no refitting)
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
%   3) Sort items by: subjectID, sessionID, runID, epoch_index (numeric), channel
%   4) Clear everything except PLOT.
%   5) Set plot styling variables (user-editable) then plot (3×3 paging).
%
% Notes
%   - Channel matching is case-insensitive.
%   - eventtype / eventannotation matching is exact (case-sensitive).
%   - NRF overlays use stored shift_samples + fglsCoef + projectionTimes_ms.
%   - If an NRF overlay window is out of bounds, the script errors and stops.
%   - If duplicate NRF rows exist for a given item+NRFName, the script errors and stops.
%   - No legends.

log_command_window('start');
clear; clc;

%% 1) Paths and environment
baseDir  = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
pooledDir = fullfile(baseDir, 'data', 'summary', 'pooled');

epochsMatPath = fullfile(pooledDir, 'pooled_eeg_epochs.mat');
nrfCsvPath    = fullfile(pooledDir, 'pooled_eeg_nrf_features.csv');

functionsFolder = fullfile(baseDir, 'functions');
if exist(functionsFolder, 'dir')
    addpath(functionsFolder);
end

assert(isfile(epochsMatPath), 'Missing file: %s', epochsMatPath);

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


if ~overlayNRF
    nrfNamesRequested = {};
end
if overlayNRF
    assert(~isempty(nrfNamesRequested), 'overlayNRF is true, but nrfNamesRequested is empty.');
end

assert(filterMode == "eventtype" || filterMode == "eventannotation", ...
    'filterMode must be "eventtype" or "eventannotation".');

%% 3) Load pooled epochs
S = load(epochsMatPath);
assert(isfield(S, 'epochs_pooled'), 'Expected variable "epochs_pooled" in %s', epochsMatPath);
epochs_pooled = S.epochs_pooled;
assert(~isempty(epochs_pooled), 'epochs_pooled is empty in %s', epochsMatPath);

%% 4) Load pooled NRF CSV (only if overlayNRF)
% Read as strings for ID columns to preserve leading zeros (sessionID/runID).
if overlayNRF
    assert(isfile(nrfCsvPath), 'overlayNRF is true, but NRF CSV is missing: %s', nrfCsvPath);

    optsNRF = detectImportOptions(nrfCsvPath, 'PreserveVariableNames', true, 'TextType', 'string');
    idCols = {'subjectID','sessionID','runID','channel','eventtype','eventannotation','NRFName'};
    idCols = intersect(idCols, optsNRF.VariableNames, 'stable');
    if ~isempty(idCols)
        optsNRF = setvartype(optsNRF, idCols, 'string');
    end

    Tnrf_all = readtable(nrfCsvPath, optsNRF);

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
        Tnrf_all.(c) = double(Tnrf_all.(c));
    end

    % Keep only requested NRFName rows (exact match, case-sensitive)
    reqNames = string(nrfNamesRequested(:));
    keep = ismember(Tnrf_all.NRFName, reqNames);
    Tnrf = Tnrf_all(keep, :);

    % Optional early trim: keep only rows matching chosen filter (exact)
    if filterMode == "eventtype"
        Tnrf = Tnrf(Tnrf.eventtype == string(filterValue), :);
    else
        Tnrf = Tnrf(Tnrf.eventannotation == string(filterValue), :);
    end
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

        T = load(nrfFile);
        assert(isfield(T, 'NRF') && isfield(T, 'fs'), 'NRF file must contain variables NRF and fs: %s', nrfFile);

        nrfVec = T.NRF(:);
        fs = double(T.fs);

        assert(isnumeric(nrfVec) && numel(nrfVec) >= 2, 'Bad NRF vector in: %s', nrfFile);
        assert(isfinite(fs) && fs > 0, 'Bad fs in: %s', nrfFile);

        nrfTemplates(j).NRF = double(nrfVec);
        nrfTemplates(j).fs  = fs;
        nrfTemplates(j).L   = numel(nrfVec);
        nrfTemplates(j).meanNRF = mean(double(nrfVec));
    end
end

%% 6) Determine number of items to plot (first pass)
targetCh = upper(strtrim(string(channelRequested)));

n_items_total = 0;

for d = 1:numel(epochs_pooled)
    D = epochs_pooled(d);

    % Channels present?
    if ~isfield(D, 'channels') || isempty(D.channels)
        continue
    end
    chLabels = string(D.channels(:));
    chLabels(ismissing(chLabels)) = "";
    chUpper = upper(strtrim(chLabels));

    idxCh = find(chUpper == targetCh, 1, 'first');
    if isempty(idxCh)
        % Skip datasets missing the requested channel (silent policy)
        continue
    end

    % Epoch metadata present?
    if ~isfield(D, 'eventtype') || ~isfield(D, 'eventannotation') || ~isfield(D, 'epoch_index')
        continue
    end

    evType  = string(D.eventtype(:));
    evAnnot = string(D.eventannotation(:));
    evType(ismissing(evType)) = "";
    evAnnot(ismissing(evAnnot)) = "";

    if filterMode == "eventtype"
        mask = (evType == string(filterValue));
    else
        mask = (evAnnot == string(filterValue));
    end

    n_items_total = n_items_total + sum(mask);
end

assert(n_items_total > 0, ...
    'No items matched: filterMode=%s, filterValue=%s, channel=%s', ...
    filterMode, string(filterValue), string(channelRequested));

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

itemCounter = 0;
Y_allocated = false;

% We enforce a single X for all items. The first contributing dataset defines X.
for d = 1:numel(epochs_pooled)
    D = epochs_pooled(d);

    % Required fields (skip silently if missing)
    reqFields = {'data','times_ms','channels','epoch_index','eventtype','eventannotation','subjectID','sessionID','runID','srate'};
    ok = true;
    for k = 1:numel(reqFields)
        if ~isfield(D, reqFields{k})
            ok = false; break
        end
    end
    if ~ok
        continue
    end

    % Channel index (case-insensitive)
    chLabels = string(D.channels(:));
    chLabels(ismissing(chLabels)) = "";
    chUpper = upper(strtrim(chLabels));
    idxCh = find(chUpper == targetCh, 1, 'first');
    if isempty(idxCh)
        continue
    end
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
    evType  = string(D.eventtype(:));
    evAnnot = string(D.eventannotation(:));
    evType(ismissing(evType)) = "";
    evAnnot(ismissing(evAnnot)) = "";

    if filterMode == "eventtype"
        mask = (evType == string(filterValue));
    else
        mask = (evAnnot == string(filterValue));
    end

    % Indices of selected epochs, in existing order
    selIdx = find(mask);
    if isempty(selIdx)
        continue
    end

    % IDs for this dataset
    subj = strtrim(string(D.subjectID));
    sess = strtrim(string(D.sessionID));
    run  = strtrim(string(D.runID));

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
                if isempty(Tnrf)
                    % No rows at all after initial trimming -> keep NaN overlay
                    continue
                end

                keyMask = (Tnrf.subjectID == subj) & ...
                    (Tnrf.sessionID == sess) & ...
                    (Tnrf.runID == run) & ...
                    (Tnrf.epoch_index == epochIndexAll(e)) & ...
                    (upper(Tnrf.channel) == upper(channelLabelOriginal)) & ...
                    (Tnrf.NRFName == nrfName);

                hit = find(keyMask);

                if isempty(hit)
                    % No overlay for this NRF on this item (leave as NaNs)
                    continue
                end

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

% Up to three NRF colours, used in order for however many NRF series exist
nrfColors = [ ...
    [1 0 0]; ...
    [20 204 204] / 255; ...
    [0 0.5 0] ...
    ];

% Fixed y-axis limits (default ±150 µV)
yLim_uV = [-150 150];

% X-limits auto-fit to PLOT.X
xLim_ms = [min(PLOT.X) max(PLOT.X)];

% Optional: grid (default off)
useGrid = false;

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