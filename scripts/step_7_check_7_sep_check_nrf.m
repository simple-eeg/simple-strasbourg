%% step_7_check_7_sep_check_nrf.m
% Purpose
%   Paired separation check for a user-selected NRF metric between two event types,
%   using an estimation-style plot plus paired effect-size output.
%
% Inputs
%   - Reads:  data/summary/screening/pooled_screened_eeg_nrf_features.csv
%
% Notes on NRF rows
%   - Unlike QC features (one row per epoch), NRF features can have multiple rows per
%     epoch because multiple NRF templates may be fit to the same epoch.
%   - This script filters to a user-selected NRFName first, then performs the paired
%     separation check within that NRF template only.
%
% Pairing logic (comparison integrity gate)
%   - Define a recording-channel key by the 4-tuple:
%       (subjectID, sessionID, runID, channel)
%   - Within each key, form a paired comparison where:
%       x = NRF metric from the row with eventtype == eventtype_reference
%       y = NRF metric from the row with eventtype == eventtype_primary
%   - epoch_index is NOT used for pairing.
%   - eventtype and NRFName matching are exact (after trimming leading/trailing whitespace).
%
% Channel filtering
%   - Data may contain multiple channels. This script filters early to a single
%     user-specified channel_of_interest (exact match after strtrim, case-insensitive).
%   - Rows from other channels are removed before defining the universe-of-interest
%     and before any counts/filters/stats/plots.
%
% Row identity / uniqueness
%   - Each NRF row is uniquely identified by the 6-tuple:
%       (subjectID, sessionID, runID, epoch_index, channel, NRFName)
%
% Exclusions and missingness
%   - If useExclusionFlags == true, rows with Exclude==1 are dropped first.
%   - Then rows are filtered to NRFName_of_interest.
%   - After filtering, incomplete groups (only x or only y present) are dropped (counted).
%   - Pairs with NaNs in x or y are dropped (counted).
%   - Ambiguous groups (multiple reference rows or multiple primary rows within a key)
%     hard-error and stop (post-filter), because pairing is not uniquely defined.
%
% Outputs
%   - Prints concise run info + descriptive stats to the Command Window
%   - Displays a Gardner–Altman plot (not saved)
%   - Prints paired effect-size summary via meanEffectSize (not saved)
%   - Command Window is logged via log_command_window (start/stop)
%
% -------------------------------------------------------------------------
log_command_window('start');
clear; clc;

%% ───────────────────────────── User config ──────────────────────────────
baseDir = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';

inDir = fullfile(baseDir, 'data', 'summary', 'screening');
inCSV = fullfile(inDir, 'pooled_screened_eeg_nrf_features.csv');

% Channel to analyse (exact match after strtrim; case-insensitive)
channel_of_interest = "Cz";

% x: exact match after strtrim
eventtype_reference = "cannula_prestim";
% y: exact match after strtrim
eventtype_primary   = "cannula";

% NRFName to analyse (exact match after strtrim; case-sensitive)
NRFName_of_interest = "noxious_preterm_NRF_500Hz";

% nrf_metric must match a column name exactly (case-sensitive) after strtrim
nrf_metric = "fglsCoef";

% if useExclusionFlags is true: drop Exclude==1 rows first; if false: ignore Exclude entirely
useExclusionFlags = true;

% Effect examples (not exhaustive):
%   "mediandiff"  — robust paired shift in typical value
%   "meandiff"    — standard paired mean shift
%   "cohen"       — standardised (scale-free) mean difference
%   "robustcohen" — standardised effect, more robust to outliers/heavy tails
%   "cliff"       — non-parametric, probability-of-superiority style
Effect = "mediandiff";

Alpha = 0.05;

% numeric formatting for concise console output (significant figures)
fmt_num = '%.3g';

%% ───────────────────────────── Load data ───────────────────────────────
opts = detectImportOptions(inCSV, 'TextType', 'string');

% Preserve leading zeros / exact IDs by forcing key-like columns to string
keyVars5 = ["subjectID","sessionID","runID","epoch_index","channel"];
for v = keyVars5
    if ismember(v, string(opts.VariableNames))
        opts = setvartype(opts, char(v), 'string');
    end
end

% Ensure event text fields are string
for v = ["eventtype","eventannotation","NRFName"]
    if ismember(v, string(opts.VariableNames))
        opts = setvartype(opts, char(v), 'string');
    end
end

T = readtable(inCSV, opts);

% Trim only where specified/needed
if ismember("eventtype", string(T.Properties.VariableNames))
    T.eventtype = strtrim(T.eventtype);
end
if ismember("NRFName", string(T.Properties.VariableNames))
    T.NRFName = strtrim(T.NRFName);
end

nrf_metric = strtrim(string(nrf_metric));
NRFName_of_interest = strtrim(string(NRFName_of_interest));

%% ───────────────────────────── Validation ──────────────────────────────
reqAlways = ["subjectID","sessionID","runID","epoch_index","channel","eventtype","NRFName"];
for v = reqAlways
    if ~ismember(v, string(T.Properties.VariableNames))
        error("Required column '%s' not found in %s.", v, inCSV);
    end
end

if useExclusionFlags && ~ismember("Exclude", string(T.Properties.VariableNames))
    error("useExclusionFlags==true but required column 'Exclude' was not found in %s.", inCSV);
end

if ~ismember(nrf_metric, string(T.Properties.VariableNames))
    error("nrf_metric '%s' was not found in the loaded spreadsheet.", nrf_metric);
end

% No blank/missing IDs in the 6-tuple
keyVars6 = ["subjectID","sessionID","runID","epoch_index","channel","NRFName"];
for v = keyVars6
    if any(ismissing(T.(v)) | strlength(T.(v))==0)
        error("Found missing/blank values in ID column '%s'.", v);
    end
end

% ───────────── Channel filter (early; defines universe-of-interest) ──────
T.channel = strtrim(T.channel);
channel_of_interest = strtrim(string(channel_of_interest));

T = T(strcmpi(T.channel, channel_of_interest), :);
fprintf("Rows after channel filter ('%s'): %d\n", channel_of_interest, height(T));

if height(T) == 0
    error("No rows remain after filtering to channel_of_interest='%s'.", channel_of_interest);
end

% Enforce uniqueness of the full 6-tuple (row identity for NRF rows)
[G6, ~] = findgroups(T(:, cellstr(keyVars6)));
counts6 = splitapply(@numel, G6, G6);
if any(counts6 > 1)
    error("Duplicate rows detected for the 6-tuple (subjectID, sessionID, runID, epoch_index, channel, NRFName).");
end

%% ─────────────────────────── Run header print ──────────────────────────
fprintf("\n");
fprintf("Config: channel='%s' | ref='%s' | primary='%s' | NRFName='%s' | nrf_metric='%s' | Effect='%s' | Alpha=%g | useExclusionFlags=%d\n", ...
    channel_of_interest, eventtype_reference, eventtype_primary, NRFName_of_interest, nrf_metric, Effect, Alpha, useExclusionFlags);

fprintf("Rows loaded: %d\n", height(T));

%% ─────────────────────── Exclusions (exclude-first) ─────────────────────
nDroppedExcludeAll = 0;
nDroppedExcludeCmp = 0;

if useExclusionFlags
    nDroppedExcludeAll = sum(T.Exclude == 1);

    isCmpType = (T.eventtype == eventtype_reference) | (T.eventtype == eventtype_primary);
    if any(isCmpType)
        nDroppedExcludeCmp = sum(isCmpType & (T.Exclude == 1));
    end

    T = T(T.Exclude ~= 1, :);

    fprintf("Dropped rows with Exclude==1: %d (overall)\n", nDroppedExcludeAll);
    if any(isCmpType)
        fprintf("Dropped rows with Exclude==1: %d (within selected eventtypes)\n", nDroppedExcludeCmp);
    end
else
    fprintf("Exclusion flags ignored.\n");
end

%% ──────────────────── Filter to selected NRFName (post-exclude) ─────────
T = T(T.NRFName == NRFName_of_interest, :);
fprintf("Rows after NRFName filter ('%s'): %d\n", NRFName_of_interest, height(T));

if height(T) == 0
    error("No rows remain after filtering to NRFName_of_interest='%s'.", NRFName_of_interest);
end

%% ─────────────────────── Post-filter comparison rows ────────────────────
Tcmp = T( (T.eventtype == eventtype_reference) | (T.eventtype == eventtype_primary), : );

nRefRows = sum(Tcmp.eventtype == eventtype_reference);
nPriRows = sum(Tcmp.eventtype == eventtype_primary);

fprintf("Candidate rows (post-filter): ref=%d | primary=%d\n", nRefRows, nPriRows);

keyVars4 = ["subjectID","sessionID","runID","channel"];
[G4, ~] = findgroups(Tcmp(:, cellstr(keyVars4)));
nGroupsInScope = max(G4);
if isempty(G4)
    nGroupsInScope = 0;
end
fprintf("In-scope groups (subjectID, sessionID, runID, channel): %d\n", nGroupsInScope);

%% ───────────────── Pairing: build x/y with dropping rules ───────────────
x = [];
y = [];

nDroppedIncomplete = 0;
nDroppedNaN = 0;

% Ambiguity (duplicates within group) is a hard error
nAmbiguous = 0;

if nGroupsInScope > 0
    for g = 1:nGroupsInScope
        idxG = (G4 == g);

        idxRef = idxG & (Tcmp.eventtype == eventtype_reference);
        idxPri = idxG & (Tcmp.eventtype == eventtype_primary);

        cRef = sum(idxRef);
        cPri = sum(idxPri);

        if (cRef > 1) || (cPri > 1)
            nAmbiguous = nAmbiguous + 1;
            % Hard-error immediately (keep simple)
            thisKey = Tcmp(idxG, cellstr(keyVars4));
            error("Ambiguous pairing: group has multiple reference and/or primary rows. Example key: subjectID='%s', sessionID='%s', runID='%s', channel='%s'.", ...
                string(thisKey.subjectID(1)), string(thisKey.sessionID(1)), string(thisKey.runID(1)), string(thisKey.channel(1)));
        end

        if (cRef == 0) || (cPri == 0)
            nDroppedIncomplete = nDroppedIncomplete + 1;
            continue
        end

        xVal = Tcmp.(nrf_metric)(idxRef);
        yVal = Tcmp.(nrf_metric)(idxPri);

        if isnan(xVal) || isnan(yVal)
            nDroppedNaN = nDroppedNaN + 1;
            continue
        end

        x(end+1,1) = xVal; %#ok<SAGROW>
        y(end+1,1) = yVal; %#ok<SAGROW>
    end
end

nPairs = numel(x);

fprintf("Dropped incomplete groups (missing ref or primary after filtering): %d\n", nDroppedIncomplete);
fprintf("Dropped pairs due to NaN in '%s': %d\n", nrf_metric, nDroppedNaN);
fprintf("Pairs used for analysis: %d\n", nPairs);

if nPairs == 0
    error("No valid complete pairs remain after filtering (Exclude and/or NaN dropping).");
end

%% ───────────────────── Descriptive stats (x, y, Δ) ─────────────────────
d = y - x;

% x
qx = prctile(x, [25 50 75]);
mx = mean(x);
sx = std(x);
fprintf("x (reference): n=%d, median [Q1,Q3]=%s [%s,%s], mean±SD=%s±%s\n", ...
    nPairs, ...
    sprintf(fmt_num, qx(2)), sprintf(fmt_num, qx(1)), sprintf(fmt_num, qx(3)), ...
    sprintf(fmt_num, mx), sprintf(fmt_num, sx));

% y
qy = prctile(y, [25 50 75]);
my = mean(y);
sy = std(y);
fprintf("y (primary):   n=%d, median [Q1,Q3]=%s [%s,%s], mean±SD=%s±%s\n", ...
    nPairs, ...
    sprintf(fmt_num, qy(2)), sprintf(fmt_num, qy(1)), sprintf(fmt_num, qy(3)), ...
    sprintf(fmt_num, my), sprintf(fmt_num, sy));

% Δ
qd = prctile(d, [25 50 75]);
md = mean(d);
sd = std(d);
fprintf("Δ (y−x):       n=%d, median [Q1,Q3]=%s [%s,%s], mean±SD=%s±%s\n", ...
    nPairs, ...
    sprintf(fmt_num, qd(2)), sprintf(fmt_num, qd(1)), sprintf(fmt_num, qd(3)), ...
    sprintf(fmt_num, md), sprintf(fmt_num, sd));
fprintf("\n");

%% ─────────────────────────── Plot + effect size ────────────────────────

w = which('jackknife');
needsShield = contains(w, 'chronux', 'IgnoreCase', true) || contains(w, 'Cleanline', 'IgnoreCase', true);

if needsShield
    path_before = path;
    statsDir = fullfile(matlabroot, 'toolbox', 'stats', 'stats');
    addpath(statsDir, '-begin');
    rehash toolboxcache;
end

try
    f = figure('Name', sprintf("NRF sep check: %s | %s | %s vs %s (n=%d)", ...
        nrf_metric, NRFName_of_interest, eventtype_reference, eventtype_primary, nPairs), ...
        'NumberTitle', 'off');

    gardnerAltmanPlot(x, y, Paired=true, Effect=Effect, Alpha=Alpha);

    effect = meanEffectSize(x, y, Paired=true, Effect=Effect, Alpha=Alpha);
    disp(effect);

catch ME
    if needsShield
        path(path_before);
        rehash toolboxcache;
    end
    rethrow(ME);
end

if needsShield
    path(path_before);
    rehash toolboxcache;
end

%% ───────────────────────────── Logging stop ────────────────────────────
log_command_window('stop');