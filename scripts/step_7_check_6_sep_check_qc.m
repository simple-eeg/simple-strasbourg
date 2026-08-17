%% step_7_check_6_sep_check_qc.m
% Purpose
%   Paired separation check for a user-selected QC metric between two event types,
%   using an estimation-style plot plus one within-pair difference estimate.
%
% Inputs
%   - Reads:  data/summary/screening/pooled_screened_eeg_qc_features.csv
%
% Pairing logic (comparison integrity gate)
%   - Define a recording-channel key by the 4-tuple:
%       (subjectID, sessionID, runID, channel)
%   - Within each key, form a paired comparison where:
%       reference = QC metric where eventtype == eventtype_reference
%       true      = QC metric where eventtype == eventtype_primary
%   - epoch_index is NOT used for pairing.
%   - eventtype matching is exact (after trimming leading/trailing whitespace).
%
% Channel filtering
%   - Data may contain multiple channels. This script filters early to a single
%     user-specified channel_of_interest (exact match after strtrim, case-insensitive).
%   - Rows from other channels are removed before defining the universe-of-interest
%     and before any counts/filters/stats/plots.
%
% Exclusions and missingness
%   - If useExclusionFlags == true, rows with Exclude==1 are dropped first.
%   - After filtering, incomplete groups (only reference or only true present) are dropped (counted).
%   - Pairs with NaNs in the reference or true value are dropped (counted).
%   - Ambiguous groups (multiple reference rows or multiple primary rows within a key)
%     hard-error and stop (post-filter), because pairing is not uniquely defined.
%
% Outputs
%   - Prints concise run info and one paired-difference estimate to the Command Window
%   - Displays an estimation-style paired plot (not saved)
%   - Prints one deterministic paired mean or median with a paired BCa interval
%   - Saves the ordered pairs, exact difference vector, estimate, settings, and source hashes
%   - Command Window is logged via log_command_window (start/stop)
%
% -------------------------------------------------------------------------
log_command_window('start');
clear; clc;

%% ───────────────────────────── User config ──────────────────────────────
baseDir = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
functionsDir = fullfile(baseDir, 'functions');
addpath(functionsDir, '-begin');
clear compute_paired_effect plot_paired_effect_result ...
    save_paired_separation_result;
rehash toolboxcache;

pairedHelperNames = {'compute_paired_effect', ...
    'plot_paired_effect_result', 'save_paired_separation_result'};
assert_local_helper_paths(functionsDir, pairedHelperNames);

inDir = fullfile(baseDir, 'data', 'summary', 'screening');
inCSV = fullfile(inDir, 'pooled_screened_eeg_qc_features.csv');
outMAT = fullfile(inDir, 'step_7_check_6_sep_check_qc_result.mat');

% Channel to analyse (exact match after strtrim; case-insensitive)
channel_of_interest = "Cz";

% Internal-reference event: exact match after strtrim
eventtype_reference = "cannula_prestim";
% True event: exact match after strtrim
eventtype_primary   = "cannula";

% qc_metric must match a column name exactly (case-sensitive) after strtrim
qc_metric = "MeanAbsDiffNorm";

% if useExclusionFlags is true: drop Exclude==1 rows first; if false: ignore Exclude entirely
useExclusionFlags = true;

% Supported paired-difference estimators (exact after trimming; case-insensitive):
%   "pairedmediandiff" — median(true - reference) across complete pairs
%   "pairedmeandiff"   — mean(true - reference) across complete pairs
% Both use the same paired BCa bootstrap settings below.
Estimator = "pairedmediandiff";

Alpha = 0.05;
bootstrap_resamples = 100000;
rng_seed = 1;
rng_algorithm = 'twister';

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
for v = ["eventtype","eventannotation"]
    if ismember(v, string(opts.VariableNames))
        opts = setvartype(opts, char(v), 'string');
    end
end

T = readtable(inCSV, opts);

% Trim only where specified/needed
if ismember("eventtype", string(T.Properties.VariableNames))
    T.eventtype = strtrim(T.eventtype);
end
qc_metric = strtrim(convertCharsToStrings(qc_metric));
channel_of_interest = strtrim(convertCharsToStrings(channel_of_interest));
eventtype_reference = strtrim(convertCharsToStrings(eventtype_reference));
eventtype_primary = strtrim(convertCharsToStrings(eventtype_primary));

named_settings = {channel_of_interest, "channel_of_interest"; ...
    eventtype_reference, "eventtype_reference"; ...
    eventtype_primary, "eventtype_primary"; ...
    qc_metric, "qc_metric"};
for setting_idx = 1:size(named_settings, 1)
    setting_value = named_settings{setting_idx, 1};
    if ~isscalar(setting_value) || ismissing(setting_value) || ...
            strlength(setting_value) == 0
        error("Configuration '%s' must be a nonblank string scalar.", ...
            named_settings{setting_idx, 2});
    end
end
if eventtype_reference == eventtype_primary
    error('eventtype_reference and eventtype_primary must be distinct.');
end
if ~(islogical(useExclusionFlags) && isscalar(useExclusionFlags)) && ...
        ~(isnumeric(useExclusionFlags) && isreal(useExclusionFlags) && ...
          isscalar(useExclusionFlags) && isfinite(useExclusionFlags) && ...
          ismember(useExclusionFlags, [0 1]))
    error('useExclusionFlags must be a logical scalar or numeric 0/1.');
end
useExclusionFlags = logical(useExclusionFlags);

%% ───────────────────────────── Validation ──────────────────────────────
reqAlways = ["subjectID","sessionID","runID","epoch_index","channel","eventtype"];
for v = reqAlways
    if ~ismember(v, string(T.Properties.VariableNames))
        error("Required column '%s' not found in %s.", v, inCSV);
    end
end

if useExclusionFlags && ~ismember("Exclude", string(T.Properties.VariableNames))
    error("useExclusionFlags==true but required column 'Exclude' was not found in %s.", inCSV);
end

if ~ismember(qc_metric, string(T.Properties.VariableNames))
    error("qc_metric '%s' was not found in the loaded spreadsheet.", qc_metric);
end

% No blank/missing IDs in the 5-tuple
for v = keyVars5
    if any(ismissing(T.(v)) | strlength(strtrim(T.(v)))==0)
        error("Found missing/blank values in ID column '%s'.", v);
    end
end

% ───────────── Channel filter (early; defines universe-of-interest) ──────
T.channel = strtrim(T.channel);

T = T(strcmpi(T.channel, channel_of_interest), :);
fprintf("Rows after channel filter ('%s'): %d\n", channel_of_interest, height(T));
nRowsAfterChannelFilter = height(T);

if height(T) == 0
    error("No rows remain after filtering to channel_of_interest='%s'.", channel_of_interest);
end

if useExclusionFlags
    if ~(isnumeric(T.Exclude) || islogical(T.Exclude)) || ~isreal(T.Exclude) || ...
            ~isvector(T.Exclude) || numel(T.Exclude) ~= height(T) || ...
            any(~isfinite(T.Exclude)) || any(~ismember(T.Exclude, [0 1]))
        error("Column 'Exclude' must contain one finite binary 0/1 value per selected-channel row.");
    end
end

% Enforce uniqueness of the full 5-tuple (row identity)
identityKeys5 = T(:, cellstr(keyVars5));
identityKeys5.channel = upper(identityKeys5.channel);
[G5, ~] = findgroups(identityKeys5);
counts5 = splitapply(@numel, G5, G5);
if any(counts5 > 1)
    error("Duplicate rows detected for the 5-tuple (subjectID, sessionID, runID, epoch_index, channel).");
end

%% ─────────────────────────── Run header print ──────────────────────────
fprintf("\n");
fprintf("Config: channel='%s' | ref='%s' | primary='%s' | qc_metric='%s' | Estimator='%s' | Alpha=%g | useExclusionFlags=%d\n", ...
    channel_of_interest, eventtype_reference, eventtype_primary, qc_metric, Estimator, Alpha, useExclusionFlags);

fprintf("Rows entering exclusion and pairing after channel filter: %d\n", height(T));

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

%% ───────────────────── Post-exclusion comparison rows ───────────────────
Tcmp = T( (T.eventtype == eventtype_reference) | (T.eventtype == eventtype_primary), : );

selected_metric_values = Tcmp.(qc_metric);
if ~isnumeric(selected_metric_values) || ~isreal(selected_metric_values) || ...
        ~isvector(selected_metric_values) || ...
        numel(selected_metric_values) ~= height(Tcmp) || ...
        any(isinf(selected_metric_values))
    error("Selected qc_metric '%s' must contain one real numeric value or NaN per comparison row.", qc_metric);
end

nRefRows = sum(Tcmp.eventtype == eventtype_reference);
nPriRows = sum(Tcmp.eventtype == eventtype_primary);

fprintf("Candidate rows (post-exclusion): ref=%d | primary=%d\n", nRefRows, nPriRows);

groupKeys4 = Tcmp(:, {'subjectID','sessionID','runID'});
groupKeys4.channel = upper(Tcmp.channel);
[G4, ~] = findgroups(groupKeys4);
nGroupsInScope = max(G4);
if isempty(G4)
    nGroupsInScope = 0;
end
fprintf("In-scope groups (subjectID, sessionID, runID, channel): %d\n", nGroupsInScope);

%% ───────────── Pairing: build true/reference values with dropping rules ─────────────
reference_values = [];
true_values = [];
reference_row_indices = [];
true_row_indices = [];

nDroppedIncomplete = 0;
nDroppedNaN = 0;

% Ambiguity (duplicates within group) is a hard error
if nGroupsInScope > 0
    for g = 1:nGroupsInScope
        idxG = (G4 == g);

        idxRef = idxG & (Tcmp.eventtype == eventtype_reference);
        idxPri = idxG & (Tcmp.eventtype == eventtype_primary);

        cRef = sum(idxRef);
        cPri = sum(idxPri);

        if (cRef > 1) || (cPri > 1)
            % Hard-error immediately (keep simple)
            exampleRow = find(idxG, 1, 'first');
            error("Ambiguous pairing: group has multiple reference and/or primary rows. Example key: subjectID='%s', sessionID='%s', runID='%s', channel='%s'.", ...
                string(Tcmp.subjectID(exampleRow)), string(Tcmp.sessionID(exampleRow)), ...
                string(Tcmp.runID(exampleRow)), string(Tcmp.channel(exampleRow)));
        end

        if (cRef == 0) || (cPri == 0)
            nDroppedIncomplete = nDroppedIncomplete + 1;
            continue
        end

        reference_value = Tcmp.(qc_metric)(idxRef);
        true_value = Tcmp.(qc_metric)(idxPri);

        if isnan(reference_value) || isnan(true_value)
            nDroppedNaN = nDroppedNaN + 1;
            continue
        end

        reference_values(end+1,1) = reference_value; %#ok<SAGROW>
        true_values(end+1,1) = true_value; %#ok<SAGROW>
        reference_row_indices(end+1,1) = find(idxRef); %#ok<SAGROW>
        true_row_indices(end+1,1) = find(idxPri); %#ok<SAGROW>
    end
end

nPairs = numel(reference_values);

fprintf("Dropped incomplete groups (missing ref or primary after filtering): %d\n", nDroppedIncomplete);
fprintf("Dropped pairs due to NaN in '%s': %d\n", qc_metric, nDroppedNaN);
fprintf("Pairs used for analysis: %d\n", nPairs);

if nPairs == 0
    error("No valid complete pairs remain after filtering (Exclude and/or NaN dropping).");
end

pairing_table = table( ...
    (1:nPairs).', ...
    string(Tcmp.subjectID(reference_row_indices)), ...
    string(Tcmp.sessionID(reference_row_indices)), ...
    string(Tcmp.runID(reference_row_indices)), ...
    string(Tcmp.channel(reference_row_indices)), ...
    string(Tcmp.epoch_index(reference_row_indices)), ...
    string(Tcmp.epoch_index(true_row_indices)), ...
    string(Tcmp.eventtype(reference_row_indices)), ...
    string(Tcmp.eventtype(true_row_indices)), ...
    reference_values, true_values, true_values - reference_values, ...
    'VariableNames', {'PairIndex','subjectID','sessionID','runID','channel', ...
    'reference_epoch_index','true_epoch_index','reference_eventtype','true_eventtype', ...
    'reference_value','true_value','true_minus_reference'});

%% ───────────────────── Within-pair difference vector ──────────────────
d = true_values - reference_values;
fprintf('Complete paired differences available: n=%d\n', nPairs);
fprintf('Difference definition: true event value - internal reference value within each matched pair.\n');
fprintf("\n");


%% ─────────────────────── Plot + paired estimate ────────────────────────

w = which('jackknife');
needsShield = contains(w, 'chronux', 'IgnoreCase', true) || contains(w, 'Cleanline', 'IgnoreCase', true);

if needsShield
    path_before = path;
    statsDir = fullfile(matlabroot, 'toolbox', 'stats', 'stats');
    addpath(statsDir, '-begin');
    addpath(functionsDir, '-begin');
    rehash toolboxcache;
end

try
    assert_local_helper_paths(functionsDir, pairedHelperNames);
    [estimate_result, rng_specification, effect_specification] = compute_paired_effect( ...
        true_values, reference_values, Estimator, Alpha, ...
        bootstrap_resamples, rng_seed, rng_algorithm);

    f = figure('Name', sprintf("QC sep check: %s | %s vs %s (n=%d)", qc_metric, eventtype_primary, eventtype_reference, nPairs), ...
        'NumberTitle', 'off');
    plot_handles = plot_paired_effect_result(gca, true_values, reference_values, estimate_result, ...
        eventtype_primary, eventtype_reference, effect_specification, Alpha);

    ci = estimate_result.ConfidenceIntervals(1, :);
    fprintf('Configured estimator: %s\n', effect_specification.estimand);
    fprintf('Paired result (%s): n=%d, estimate=%.17g; %g%% paired BCa CI [%.17g, %.17g]\n', ...
        effect_specification.direction, nPairs, estimate_result.Estimate(1), ...
        100*(1-Alpha), ci(1), ci(2));
    fprintf('Bootstrap: %d complete-pair resamples; seed=%d; generator=%s.\n', ...
        bootstrap_resamples, rng_seed, rng_algorithm);

    separation_result = struct();
    separation_result.schema = 'simple-paired-separation-result-v2';
    separation_result.role = 'descriptive, non-exclusionary guardrail';
    separation_result.pairing_table = pairing_table;
    separation_result.pair_differences = d;
    separation_result.estimate = estimate_result;
    separation_result.settings = struct( ...
        'direction', effect_specification.direction, ...
        'estimand', effect_specification.estimand, ...
        'effect_specification', effect_specification, ...
        'paired', true, ...
        'estimator', effect_specification.effect, ...
        'statistic', effect_specification.statistic, ...
        'difference_definition', 'true_value - reference_value within each complete pair', ...
        'bootstrap_resampling_unit', 'complete pair represented by one difference score', ...
        'confidence_interval', 'bias-corrected and accelerated (BCa)', ...
        'estimator_implementation', 'MATLAB bootci applied once to pair_differences', ...
        'alpha', Alpha, ...
        'rng', rng_specification, ...
        'channel', char(channel_of_interest), ...
        'true_event', char(eventtype_primary), ...
        'reference_event', char(eventtype_reference), ...
        'metric', char(qc_metric), ...
        'use_exclusion_flags', logical(useExclusionFlags), ...
        'pairing_key', 'subjectID, sessionID, runID, channel', ...
        'participant_aggregation', 'none');
    separation_result.counts = struct( ...
        'rows_after_channel_filter', nRowsAfterChannelFilter, ...
        'excluded_rows_all', nDroppedExcludeAll, ...
        'excluded_rows_selected_events', nDroppedExcludeCmp, ...
        'reference_rows_after_exclusion', nRefRows, ...
        'true_rows_after_exclusion', nPriRows, ...
        'groups_in_scope', nGroupsInScope, ...
        'incomplete_groups_dropped', nDroppedIncomplete, ...
        'nan_pairs_dropped', nDroppedNaN, ...
        'pairs_analysed', nPairs);
    separation_result.environment = struct( ...
        'matlab_version', version, ...
        'matlab_release', version('-release'), ...
        'computer', computer);

    script_file = [mfilename('fullpath'), '.m'];
    pairedHelperFiles = assert_local_helper_paths(functionsDir, pairedHelperNames);
    source_files = struct( ...
        'input_csv', inCSV, ...
        'script', script_file, ...
        'compute_helper', pairedHelperFiles{1}, ...
        'plot_helper', pairedHelperFiles{2}, ...
        'save_helper', pairedHelperFiles{3});
    separation_result = save_paired_separation_result(outMAT, separation_result, source_files);
    fprintf('Saved machine-readable separation result: %s\n', outMAT);
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

function helperFiles = assert_local_helper_paths(functionsDir, helperNames)
canonicalFunctionsDir = char(java.io.File(functionsDir).getCanonicalPath());
helperFiles = cell(size(helperNames));

for helperIdx = 1:numel(helperNames)
    helperName = helperNames{helperIdx};
    expectedFile = fullfile(canonicalFunctionsDir, [helperName, '.m']);
    if ~isfile(expectedFile)
        error('SIMPLE:LocalHelperMissing', ...
            'Required local helper is missing: %s', expectedFile);
    end

    resolvedFile = which(helperName);
    if isempty(resolvedFile)
        error('SIMPLE:LocalHelperUnresolved', ...
            'Required local helper did not resolve: %s', helperName);
    end
    resolvedFile = char(java.io.File(resolvedFile).getCanonicalPath());
    if ~strcmp(resolvedFile, expectedFile)
        error('SIMPLE:LocalHelperShadowed', ...
            ['Required helper ''%s'' resolved outside this repository. ' ...
             'Expected %s; resolved %s.'], ...
            helperName, expectedFile, resolvedFile);
    end
    helperFiles{helperIdx} = resolvedFile;
end
end
