%% step_8_jasp_1_data_prep_eeg.m
% Purpose
%   - Read the SCREENED pooled QC and NRF feature tables.
%   - Identify every cannula recording independently of screening decisions.
%   - Recover acquisition chronology from the BrainVision marker files.
%   - Select the earliest cannula recording per subject before applying Exclude.
%   - Create a parallel within-subject median export from complete retained
%     true/reference recording pairs.
%   - Retain one row per subject in both exports, using NaN when a method has
%     no available value for that subject.
%   - Write:
%       data/jasp/jasp_data_eeg.csv
%       data/jasp/jasp_data_eeg_median.csv
%       data/jasp/jasp_selection_manifest.csv
%
% Earliest-recording selection policy
%   - The selection universe is all cannula recordings represented by paired
%     cannula_prestim and cannula rows in the screened source tables.
%   - A recording is ranked within subject using the timestamp of its Stim 2
%     cannula event in the corresponding BrainVision .vmrk file.
%   - Rank 1 is selected. Selection occurs BEFORE Exclude is consulted.
%   - If the selected true cannula epoch is excluded, its output values remain
%     missing. A later recording is never substituted.
%   - Non-selected repeat recordings remain in the 39-row audit manifest and
%     are labelled AnalysisSelected = 0; they are not screening exclusions.
%
% Within-subject median aggregation policy
%   - A recording contributes only when its matched cannula_prestim and
%     cannula epochs are both screening-retained.
%   - The identical set of complete retained recording pairs supplies all four
%     analytical columns for a subject.
%   - Each analytical column is separately summarised by its ordinary median.
%   - A subject with no complete retained pair remains in the export with all
%     four analytical values missing.
%
% JASP output mapping
%   CA_BL_MeanAbsDiffNorm <- QC MeanAbsDiffNorm, cannula_prestim
%   CA_ER_MeanAbsDiffNorm <- QC MeanAbsDiffNorm, cannula
%   CA_BL_pnNRF_mag       <- NRF fglsCoef, cannula_prestim
%   CA_ER_pnNRF_mag       <- NRF fglsCoef, cannula
%
% Current baseline invariants
%   - 39 cannula recordings from 27 unique subjects.
%   - 12 later repeat recordings are not selected.
%   - Among the 27 selected recordings: 27 retained reference epochs,
%     25 retained true cannula epochs, and 25 complete pairs.
%   - For median aggregation: 37 complete retained recording pairs from
%     25 subjects contribute, leaving two subjects with all values missing.
%   - The expected channel is Cz, the cannula run is stim2, and the NRF is
%     noxious_preterm_NRF_500Hz.
%
% BrainVision timing assumptions
%   - The marker timestamp is an unzoned local acquisition timestamp with
%     format yyyyMMddHHmmssSSSSSS.
%   - The current source recordings were acquired at 2500 Hz. The script
%     validates New Segment at sample 1 and Stim 2 at sample 5001, giving a
%     two-second event offset using (5001 - 1) / 2500.
%
% Validation philosophy
%   - All joins use the full source epoch identity.
%   - QC and NRF candidate sets and Exclude values must agree.
%   - Missing/ambiguous chronology, duplicate keys, unexpected source files,
%     non-finite retained values, and changed baseline counts are hard errors.
%   - All three output tables are fully assembled and validated before any
%     destination file is replaced.

log_command_window('start');
clear; clc;

%% 0) User config: paths, constants, and fixed schemas
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';

qcCsv = fullfile(baseDir, 'data', 'summary', 'screening', ...
    'pooled_screened_eeg_qc_features.csv');
nrfCsv = fullfile(baseDir, 'data', 'summary', 'screening', ...
    'pooled_screened_eeg_nrf_features.csv');
sourceDir = fullfile(baseDir, 'data', 'source');

outDir = fullfile(baseDir, 'data', 'jasp');
outCsv = fullfile(outDir, 'jasp_data_eeg.csv');
outMedianCsv = fullfile(outDir, 'jasp_data_eeg_median.csv');
manifestCsv = fullfile(outDir, 'jasp_selection_manifest.csv');

expected_channel = "Cz";
expected_run = "stim2";
expected_nrfname = "noxious_preterm_NRF_500Hz";
expected_ref_event = "cannula_prestim";
expected_true_event = "cannula";
expected_ref_epoch = 1;
expected_true_epoch = 2;
expected_sampling_rate_hz = 2500;
expected_new_segment_sample = 1;
expected_stim2_sample = 5001;

selection_rule = "earliest_timestamped_cannula_event_per_subject";
median_aggregation_rule = ...
    "within_subject_median_of_complete_retained_matched_recording_pairs";

expected_recordings = 39;
expected_subjects = 27;
expected_nonselected = 12;
expected_single_recording_subjects = 17;
expected_double_recording_subjects = 8;
expected_triple_recording_subjects = 2;
expected_all_ref_included = 39;
expected_all_true_included = 37;
expected_selected_ref_included = 27;
expected_selected_true_included = 25;
expected_complete_pairs = 25;
expected_median_contributing_recordings = 37;
expected_median_contributing_subjects = 25;
expected_median_zero_contributor_subjects = 2;

OUT_COLS = { ...
    'subjectID', ...
    'CA_BL_MeanAbsDiffNorm', ...
    'CA_ER_MeanAbsDiffNorm', ...
    'CA_BL_pnNRF_mag', ...
    'CA_ER_pnNRF_mag' ...
    };

MANIFEST_COLS = { ...
    'subjectID', ...
    'sessionID', ...
    'runID', ...
    'cannula_event_datetime', ...
    'selection_rank', ...
    'AnalysisSelected', ...
    'SelectionRule', ...
    'source_vmrk_relative_path', ...
    'source_vmrk_sha256', ...
    'CA_BL_Exclude', ...
    'CA_ER_Exclude', ...
    'MedianAggregationIncluded', ...
    'MedianAggregationRule' ...
    };

%% 1) Validate fixed inputs and create output directory
if ~isfile(qcCsv)
    error('Input file not found: %s', qcCsv);
end
if ~isfile(nrfCsv)
    error('Input file not found: %s', nrfCsv);
end
if ~isfolder(sourceDir)
    error('BrainVision source directory not found: %s', sourceDir);
end

if ~exist(outDir, 'dir')
    ok = mkdir(outDir);
    if ~ok
        error('Failed to create output directory: %s', outDir);
    end
end

%% 2) Read source tables with strict, string-stable import
qcInputSha256 = string(sha256_file(qcCsv));
nrfInputSha256 = string(sha256_file(nrfCsv));

qcRequired = { ...
    'subjectID','sessionID','runID','epoch_index','channel','eventtype', ...
    'MeanAbsDiffNorm','Exclude' ...
    };
nrfRequired = { ...
    'subjectID','sessionID','runID','epoch_index','channel','eventtype', ...
    'NRFName','fglsCoef','Exclude' ...
    };

Tqc = read_required_csv(qcCsv, qcRequired, ...
    'pooled_screened_eeg_qc_features.csv');
Tnrf = read_required_csv(nrfCsv, nrfRequired, ...
    'pooled_screened_eeg_nrf_features.csv');

if string(sha256_file(qcCsv)) ~= qcInputSha256 || ...
        string(sha256_file(nrfCsv)) ~= nrfInputSha256
    error('A screened source CSV changed while it was being read.');
end

textKeysQc = {'subjectID','sessionID','runID','channel','eventtype'};
textKeysNrf = {'subjectID','sessionID','runID','channel','eventtype','NRFName'};

Tqc = normalise_required_text(Tqc, textKeysQc, 'QC');
Tnrf = normalise_required_text(Tnrf, textKeysNrf, 'NRF');

Tqc.epoch_index = parse_required_integer(Tqc.epoch_index, 'QC epoch_index');
Tnrf.epoch_index = parse_required_integer(Tnrf.epoch_index, 'NRF epoch_index');
Tqc.Exclude = parse_binary(Tqc.Exclude, 'QC Exclude');
Tnrf.Exclude = parse_binary(Tnrf.Exclude, 'NRF Exclude');

Tqc.MeanAbsDiffNorm = parse_optional_numeric( ...
    Tqc.MeanAbsDiffNorm, 'QC MeanAbsDiffNorm');
Tnrf.fglsCoef = parse_optional_numeric(Tnrf.fglsCoef, 'NRF fglsCoef');

%% 3) Validate source-table domains and full epoch-key uniqueness
allowed_eventtypes = ["touch_prestim","touch", ...
    expected_ref_event,expected_true_event];

assert_allowed_values(Tqc.eventtype, allowed_eventtypes, ...
    'QC eventtype');
assert_allowed_values(Tnrf.eventtype, allowed_eventtypes, ...
    'NRF eventtype');
assert_allowed_values(Tnrf.NRFName, expected_nrfname, 'NRFName');

if any(~strcmpi(Tqc.channel, expected_channel))
    error('QC table contains a channel other than expected channel "%s".', ...
        expected_channel);
end
if any(~strcmpi(Tnrf.channel, expected_channel))
    error('NRF table contains a channel other than expected channel "%s".', ...
        expected_channel);
end

qcKey = make_epoch_key(Tqc, false);
nrfKey = make_epoch_key(Tnrf, true);
assert_unique_keys(qcKey, 'QC full epoch');
assert_unique_keys(nrfKey, 'NRF full epoch');

%% 4) Derive the 39-recording cannula universe independently in QC and NRF
cannula_events = [expected_ref_event, expected_true_event];
qcCannulaMask = ismember(Tqc.eventtype, cannula_events);
nrfCannulaMask = ismember(Tnrf.eventtype, cannula_events);

if any(Tqc.runID(qcCannulaMask) ~= expected_run)
    error('QC cannula rows contain a runID other than expected run "%s".', ...
        expected_run);
end
if any(Tnrf.runID(nrfCannulaMask) ~= expected_run)
    error('NRF cannula rows contain a runID other than expected run "%s".', ...
        expected_run);
end

recordingVars = {'subjectID','sessionID','runID'};
qcCandidates = unique(Tqc(qcCannulaMask, recordingVars), 'rows');
nrfCandidates = unique(Tnrf(nrfCannulaMask, recordingVars), 'rows');

qcCandidates = sortrows(qcCandidates, recordingVars);
nrfCandidates = sortrows(nrfCandidates, recordingVars);

if height(qcCandidates) ~= height(nrfCandidates) || ...
        ~all(make_recording_key(qcCandidates) == ...
        make_recording_key(nrfCandidates))
    error('QC and NRF cannula recording sets do not match exactly.');
end

if height(qcCandidates) ~= expected_recordings
    error('Expected %d cannula recordings, found %d.', ...
        expected_recordings, height(qcCandidates));
end
if numel(unique(qcCandidates.subjectID)) ~= expected_subjects
    error('Expected %d unique cannula subjects, found %d.', ...
        expected_subjects, numel(unique(qcCandidates.subjectID)));
end

if sum(qcCannulaMask) ~= 2 * expected_recordings
    error('Expected exactly two QC cannula items per recording (%d rows), found %d.', ...
        2 * expected_recordings, sum(qcCannulaMask));
end
if sum(nrfCannulaMask) ~= 2 * expected_recordings
    error('Expected exactly two NRF cannula items per recording (%d rows), found %d.', ...
        2 * expected_recordings, sum(nrfCannulaMask));
end

%% 5) Discover and validate the 39 cannula BrainVision marker sources
allEntries = dir(fullfile(sourceDir, '**', '*'));
allEntries = allEntries(~[allEntries.isdir]);
allNames = string({allEntries.name})';

isMarker = endsWith(lower(allNames), ".vmrk");
markerEntries = allEntries(isMarker);
markerNames = string({markerEntries.name})';

if any(startsWith(markerNames, "._"))
    error('AppleDouble .vmrk file(s) found in data/source; source identity is ambiguous.');
end

markerPaths = strings(numel(markerEntries), 1);
for i = 1:numel(markerEntries)
    markerPaths(i) = string(fullfile(markerEntries(i).folder, markerEntries(i).name));
end
markerPaths = sort(markerPaths);

containsStim2 = false(numel(markerPaths), 1);
for i = 1:numel(markerPaths)
    markerText = fileread(char(markerPaths(i)));
    containsStim2(i) = ~isempty(regexpi(markerText, ...
        '(?m)^Mk\d+=Stimulus,Stim 2,', 'once'));
end

cannulaMarkerPaths = markerPaths(containsStim2);
expectedFilenameSuffix = "-" + lower(expected_run) + "nofilter.vmrk";

if any(~endsWith(lower(cannulaMarkerPaths), expectedFilenameSuffix))
    error(['A marker file contains Stimulus,Stim 2 but its filename does not ' ...
        'end in the expected "%s" token.'], expectedFilenameSuffix);
end
if numel(cannulaMarkerPaths) ~= expected_recordings
    error('Expected %d Stim 2 marker files, found %d.', ...
        expected_recordings, numel(cannulaMarkerPaths));
end

sourceSubject = strings(expected_recordings, 1);
sourceSession = strings(expected_recordings, 1);
sourceRun = repmat(expected_run, expected_recordings, 1);
eventDatetimeSortKey = strings(expected_recordings, 1);
eventDatetimeText = strings(expected_recordings, 1);
sourceRelativePath = strings(expected_recordings, 1);
sourceSha256 = strings(expected_recordings, 1);

for i = 1:expected_recordings
    markerPath = cannulaMarkerPaths(i);

    [sourceSubject(i), sourceSession(i), sourceRelativePath(i)] = ...
        canonical_ids_from_marker_path(markerPath, sourceDir, expected_run);

    hashBefore = string(sha256_file(char(markerPath)));
    [eventDatetimeText(i), eventDatetimeSortKey(i)] = ...
        parse_cannula_datetime( ...
        markerPath, expected_sampling_rate_hz, ...
        expected_new_segment_sample, expected_stim2_sample);
    hashAfter = string(sha256_file(char(markerPath)));

    if hashBefore ~= hashAfter
        error('Marker file changed while it was being read: %s', markerPath);
    end
    if strlength(hashBefore) ~= 64 || ...
            isempty(regexp(char(hashBefore), '^[0-9a-f]{64}$', 'once'))
        error('Invalid SHA-256 result for marker file: %s', markerPath);
    end

    sourceSha256(i) = hashBefore;
end

sourceCandidates = table( ...
    sourceSubject, sourceSession, sourceRun, eventDatetimeSortKey, ...
    eventDatetimeText, sourceRelativePath, sourceSha256, ...
    'VariableNames', { ...
    'subjectID','sessionID','runID','event_datetime_sort_key', ...
    'cannula_event_datetime','source_vmrk_relative_path', ...
    'source_vmrk_sha256' ...
    });

sourceCandidates = sortrows(sourceCandidates, recordingVars);
if height(sourceCandidates) ~= height(qcCandidates) || ...
        ~all(make_recording_key(sourceCandidates) == ...
        make_recording_key(qcCandidates))
    error(['BrainVision Stim 2 source keys do not match the screened QC/NRF ' ...
        'cannula recording keys exactly.']);
end

%% 6) Rank recordings chronologically and freeze selection before Exclude
candidates = sortrows(sourceCandidates, ...
    {'subjectID','event_datetime_sort_key','sessionID','runID'});

selection_rank = zeros(height(candidates), 1);
AnalysisSelected = zeros(height(candidates), 1);

subjects = unique(candidates.subjectID, 'stable');
for s = 1:numel(subjects)
    idx = find(candidates.subjectID == subjects(s));

    if numel(unique(candidates.event_datetime_sort_key(idx))) ~= numel(idx)
        error('Subject %s has tied cannula acquisition timestamps.', subjects(s));
    end

    selection_rank(idx) = (1:numel(idx))';
    AnalysisSelected(idx(1)) = 1;
end

if sum(AnalysisSelected) ~= expected_subjects
    error('Expected %d selected recordings, found %d.', ...
        expected_subjects, sum(AnalysisSelected));
end
if sum(AnalysisSelected == 0) ~= expected_nonselected
    error('Expected %d non-selected repeat recordings, found %d.', ...
        expected_nonselected, sum(AnalysisSelected == 0));
end
if any((AnalysisSelected == 1) ~= (selection_rank == 1))
    error('Internal selection error: AnalysisSelected does not equal rank 1.');
end

% This table is the frozen selection core. Screening decisions are joined only
% after the chronological rank and AnalysisSelected fields have been created.
candidates.selection_rank = selection_rank;
candidates.AnalysisSelected = AnalysisSelected;

%% 7) Join exact QC/NRF epochs and validate Exclude across all 39 recordings
nRecordings = height(candidates);

qcRefRow = zeros(nRecordings, 1);
qcTrueRow = zeros(nRecordings, 1);
nrfRefRow = zeros(nRecordings, 1);
nrfTrueRow = zeros(nRecordings, 1);
CA_BL_Exclude = zeros(nRecordings, 1);
CA_ER_Exclude = zeros(nRecordings, 1);

for i = 1:nRecordings
    sid = candidates.subjectID(i);
    sess = candidates.sessionID(i);
    runID = candidates.runID(i);

    qcRefRow(i) = find_one_qc_epoch(Tqc, sid, sess, runID, ...
        expected_ref_epoch, expected_channel, expected_ref_event);
    qcTrueRow(i) = find_one_qc_epoch(Tqc, sid, sess, runID, ...
        expected_true_epoch, expected_channel, expected_true_event);

    nrfRefRow(i) = find_one_nrf_epoch(Tnrf, sid, sess, runID, ...
        expected_ref_epoch, expected_channel, expected_ref_event, ...
        expected_nrfname);
    nrfTrueRow(i) = find_one_nrf_epoch(Tnrf, sid, sess, runID, ...
        expected_true_epoch, expected_channel, expected_true_event, ...
        expected_nrfname);

    if Tqc.Exclude(qcRefRow(i)) ~= Tnrf.Exclude(nrfRefRow(i))
        error('QC/NRF Exclude mismatch for a cannula reference epoch.');
    end
    if Tqc.Exclude(qcTrueRow(i)) ~= Tnrf.Exclude(nrfTrueRow(i))
        error('QC/NRF Exclude mismatch for a true cannula epoch.');
    end

    CA_BL_Exclude(i) = Tqc.Exclude(qcRefRow(i));
    CA_ER_Exclude(i) = Tqc.Exclude(qcTrueRow(i));
end

candidates.CA_BL_Exclude = CA_BL_Exclude;
candidates.CA_ER_Exclude = CA_ER_Exclude;
candidates.MedianAggregationIncluded = double( ...
    candidates.CA_BL_Exclude == 0 & candidates.CA_ER_Exclude == 0);

if sum(candidates.CA_BL_Exclude == 0) ~= expected_all_ref_included
    error('Expected %d included reference epochs across all recordings, found %d.', ...
        expected_all_ref_included, sum(candidates.CA_BL_Exclude == 0));
end
if sum(candidates.CA_ER_Exclude == 0) ~= expected_all_true_included
    error('Expected %d included true epochs across all recordings, found %d.', ...
        expected_all_true_included, sum(candidates.CA_ER_Exclude == 0));
end

nonselectedMask = candidates.AnalysisSelected == 0;
if any(candidates.CA_BL_Exclude(nonselectedMask) ~= 0) || ...
        any(candidates.CA_ER_Exclude(nonselectedMask) ~= 0)
    error(['All %d non-selected repeat recordings must remain retained by ' ...
        'screening under the current baseline.'], expected_nonselected);
end

if sum(candidates.MedianAggregationIncluded) ~= ...
        expected_median_contributing_recordings
    error('Expected %d complete recording pairs for median aggregation.', ...
        expected_median_contributing_recordings);
end

subjectRecordingCounts = zeros(numel(subjects), 1);
subjectMedianContributorCounts = zeros(numel(subjects), 1);
for s = 1:numel(subjects)
    subjectMask = candidates.subjectID == subjects(s);
    subjectRecordingCounts(s) = sum(subjectMask);
    subjectMedianContributorCounts(s) = ...
        sum(candidates.MedianAggregationIncluded(subjectMask));
end

if sum(subjectRecordingCounts == 1) ~= expected_single_recording_subjects || ...
        sum(subjectRecordingCounts == 2) ~= expected_double_recording_subjects || ...
        sum(subjectRecordingCounts == 3) ~= expected_triple_recording_subjects
    error('Subject-level recording multiplicities do not match the baseline.');
end
if any(subjectRecordingCounts > 1 & ...
        subjectMedianContributorCounts ~= subjectRecordingCounts)
    error(['Every repeated subject must contribute all complete retained ' ...
        'recording pairs under the current baseline.']);
end
if sum(subjectMedianContributorCounts > 0) ~= ...
        expected_median_contributing_subjects || ...
        sum(subjectMedianContributorCounts == 0) ~= ...
        expected_median_zero_contributor_subjects
    error('Median contributor counts by subject do not match the baseline.');
end

%% 8) Extract the 27 earliest-recording participant rows without aggregation
selectedIdx = find(candidates.AnalysisSelected == 1);
nSelected = numel(selectedIdx);

subjectID = candidates.subjectID(selectedIdx);
CA_BL_MeanAbsDiffNorm = nan(nSelected, 1);
CA_ER_MeanAbsDiffNorm = nan(nSelected, 1);
CA_BL_pnNRF_mag = nan(nSelected, 1);
CA_ER_pnNRF_mag = nan(nSelected, 1);

for s = 1:nSelected
    i = selectedIdx(s);

    if candidates.CA_BL_Exclude(i) == 0
        qcValue = Tqc.MeanAbsDiffNorm(qcRefRow(i));
        nrfValue = Tnrf.fglsCoef(nrfRefRow(i));
        assert_finite_retained(qcValue, 'CA_BL MeanAbsDiffNorm');
        assert_finite_retained(nrfValue, 'CA_BL pnNRF magnitude');
        CA_BL_MeanAbsDiffNorm(s) = qcValue;
        CA_BL_pnNRF_mag(s) = nrfValue;
    end

    if candidates.CA_ER_Exclude(i) == 0
        qcValue = Tqc.MeanAbsDiffNorm(qcTrueRow(i));
        nrfValue = Tnrf.fglsCoef(nrfTrueRow(i));
        assert_finite_retained(qcValue, 'CA_ER MeanAbsDiffNorm');
        assert_finite_retained(nrfValue, 'CA_ER pnNRF magnitude');
        CA_ER_MeanAbsDiffNorm(s) = qcValue;
        CA_ER_pnNRF_mag(s) = nrfValue;
    end
end

Tout = table( ...
    subjectID, ...
    CA_BL_MeanAbsDiffNorm, ...
    CA_ER_MeanAbsDiffNorm, ...
    CA_BL_pnNRF_mag, ...
    CA_ER_pnNRF_mag ...
    );
Tout.Properties.VariableNames = OUT_COLS;
Tout = sortrows(Tout, 'subjectID');

%% 9) Aggregate complete retained matched recordings within subject by median
medianSubjectID = Tout.subjectID;
CA_BL_MeanAbsDiffNorm = nan(expected_subjects, 1);
CA_ER_MeanAbsDiffNorm = nan(expected_subjects, 1);
CA_BL_pnNRF_mag = nan(expected_subjects, 1);
CA_ER_pnNRF_mag = nan(expected_subjects, 1);

for s = 1:expected_subjects
    contributorIdx = find( ...
        candidates.subjectID == medianSubjectID(s) & ...
        candidates.MedianAggregationIncluded == 1);

    if isempty(contributorIdx)
        continue
    end

    blQcValues = Tqc.MeanAbsDiffNorm(qcRefRow(contributorIdx));
    erQcValues = Tqc.MeanAbsDiffNorm(qcTrueRow(contributorIdx));
    blNrfValues = Tnrf.fglsCoef(nrfRefRow(contributorIdx));
    erNrfValues = Tnrf.fglsCoef(nrfTrueRow(contributorIdx));

    assert_finite_retained_vector( ...
        blQcValues, 'median CA_BL MeanAbsDiffNorm');
    assert_finite_retained_vector( ...
        erQcValues, 'median CA_ER MeanAbsDiffNorm');
    assert_finite_retained_vector( ...
        blNrfValues, 'median CA_BL pnNRF magnitude');
    assert_finite_retained_vector( ...
        erNrfValues, 'median CA_ER pnNRF magnitude');

    CA_BL_MeanAbsDiffNorm(s) = median(blQcValues);
    CA_ER_MeanAbsDiffNorm(s) = median(erQcValues);
    CA_BL_pnNRF_mag(s) = median(blNrfValues);
    CA_ER_pnNRF_mag(s) = median(erNrfValues);
end

ToutMedian = table( ...
    medianSubjectID, ...
    CA_BL_MeanAbsDiffNorm, ...
    CA_ER_MeanAbsDiffNorm, ...
    CA_BL_pnNRF_mag, ...
    CA_ER_pnNRF_mag ...
    );
ToutMedian.Properties.VariableNames = OUT_COLS;

%% 10) Assemble the 39-recording analysis audit manifest
SelectionRule = repmat(selection_rule, nRecordings, 1);
MedianAggregationRule = repmat(median_aggregation_rule, nRecordings, 1);

Tmanifest = table( ...
    candidates.subjectID, ...
    candidates.sessionID, ...
    candidates.runID, ...
    candidates.cannula_event_datetime, ...
    candidates.selection_rank, ...
    candidates.AnalysisSelected, ...
    SelectionRule, ...
    candidates.source_vmrk_relative_path, ...
    candidates.source_vmrk_sha256, ...
    candidates.CA_BL_Exclude, ...
    candidates.CA_ER_Exclude, ...
    candidates.MedianAggregationIncluded, ...
    MedianAggregationRule ...
    );
Tmanifest.Properties.VariableNames = MANIFEST_COLS;
Tmanifest = sortrows(Tmanifest, {'subjectID','selection_rank'});

%% 11) Validate schemas, counts, missingness, and analysis invariants
if ~isequal(Tout.Properties.VariableNames, OUT_COLS)
    error('Internal error: earliest JASP output schema does not match OUT_COLS.');
end
if ~isequal(ToutMedian.Properties.VariableNames, OUT_COLS)
    error('Internal error: median JASP output schema does not match OUT_COLS.');
end
if ~isequal(Tmanifest.Properties.VariableNames, MANIFEST_COLS)
    error('Internal error: manifest schema does not match MANIFEST_COLS.');
end
if height(Tout) ~= expected_subjects || ...
        numel(unique(Tout.subjectID)) ~= expected_subjects
    error('JASP output must contain one unique row for each of %d subjects.', ...
        expected_subjects);
end
if height(ToutMedian) ~= expected_subjects || ...
        numel(unique(ToutMedian.subjectID)) ~= expected_subjects
    error('Median JASP output must contain one unique row for each subject.');
end
if ~isequal(ToutMedian.subjectID, Tout.subjectID)
    error('Earliest and median JASP participant rows do not align exactly.');
end
if height(Tmanifest) ~= expected_recordings
    error('Selection manifest must contain %d recording rows.', ...
        expected_recordings);
end
if sum(Tmanifest.CA_BL_Exclude == 0) ~= expected_all_ref_included || ...
        sum(Tmanifest.CA_ER_Exclude == 0) ~= expected_all_true_included
    error('Selection-manifest screening counts do not match the baseline.');
end
if sum(Tmanifest.MedianAggregationIncluded) ~= ...
        expected_median_contributing_recordings || ...
        any(Tmanifest.MedianAggregationIncluded ~= ...
        double(Tmanifest.CA_BL_Exclude == 0 & ...
        Tmanifest.CA_ER_Exclude == 0))
    error('Manifest median-contributor flags do not match complete pairs.');
end
manifestNonselected = Tmanifest.AnalysisSelected == 0;
if any(Tmanifest.CA_BL_Exclude(manifestNonselected) ~= 0) || ...
        any(Tmanifest.CA_ER_Exclude(manifestNonselected) ~= 0)
    error('A non-selected repeat is incorrectly screening-excluded.');
end

selectedManifest = Tmanifest(Tmanifest.AnalysisSelected == 1, :);
if ~all(sort(selectedManifest.subjectID) == sort(Tout.subjectID))
    error('JASP and selected-manifest participant sets do not match.');
end

if sum(selectedManifest.CA_BL_Exclude == 0) ~= ...
        expected_selected_ref_included
    error('Expected %d selected included reference epochs, found %d.', ...
        expected_selected_ref_included, ...
        sum(selectedManifest.CA_BL_Exclude == 0));
end
if sum(selectedManifest.CA_ER_Exclude == 0) ~= ...
        expected_selected_true_included
    error('Expected %d selected included true epochs, found %d.', ...
        expected_selected_true_included, ...
        sum(selectedManifest.CA_ER_Exclude == 0));
end

if sum(isfinite(Tout.CA_BL_MeanAbsDiffNorm)) ~= ...
        expected_selected_ref_included || ...
        sum(isfinite(Tout.CA_BL_pnNRF_mag)) ~= ...
        expected_selected_ref_included
    error('Reference-event output missingness does not match Exclude.');
end
if sum(isfinite(Tout.CA_ER_MeanAbsDiffNorm)) ~= ...
        expected_selected_true_included || ...
        sum(isfinite(Tout.CA_ER_pnNRF_mag)) ~= ...
        expected_selected_true_included
    error('True-event output missingness does not match Exclude.');
end

refMissingnessAgrees = ...
    isfinite(Tout.CA_BL_MeanAbsDiffNorm) == isfinite(Tout.CA_BL_pnNRF_mag);
trueMissingnessAgrees = ...
    isfinite(Tout.CA_ER_MeanAbsDiffNorm) == isfinite(Tout.CA_ER_pnNRF_mag);
if ~all(refMissingnessAgrees) || ~all(trueMissingnessAgrees)
    error('QC and NRF output missingness do not agree within event.');
end

completeRows = isfinite(Tout.CA_BL_MeanAbsDiffNorm) & ...
    isfinite(Tout.CA_ER_MeanAbsDiffNorm) & ...
    isfinite(Tout.CA_BL_pnNRF_mag) & ...
    isfinite(Tout.CA_ER_pnNRF_mag);
if sum(completeRows) ~= expected_complete_pairs
    error('Expected %d complete participant pairs, found %d.', ...
        expected_complete_pairs, sum(completeRows));
end

medianFiniteCounts = [ ...
    sum(isfinite(ToutMedian.CA_BL_MeanAbsDiffNorm)), ...
    sum(isfinite(ToutMedian.CA_ER_MeanAbsDiffNorm)), ...
    sum(isfinite(ToutMedian.CA_BL_pnNRF_mag)), ...
    sum(isfinite(ToutMedian.CA_ER_pnNRF_mag)) ...
    ];
if any(medianFiniteCounts ~= expected_median_contributing_subjects)
    error('Median JASP output must have %d finite values in every feature.', ...
        expected_median_contributing_subjects);
end

medianCompleteRows = isfinite(ToutMedian.CA_BL_MeanAbsDiffNorm) & ...
    isfinite(ToutMedian.CA_ER_MeanAbsDiffNorm) & ...
    isfinite(ToutMedian.CA_BL_pnNRF_mag) & ...
    isfinite(ToutMedian.CA_ER_pnNRF_mag);
if sum(medianCompleteRows) ~= expected_complete_pairs
    error('Median JASP output must contain %d complete participant pairs.', ...
        expected_complete_pairs);
end
if sum(~medianCompleteRows) ~= expected_median_zero_contributor_subjects || ...
        any(any(isfinite(ToutMedian{~medianCompleteRows, 2:5})))
    error('Subjects without median contributors must have four missing values.');
end

for s = 1:expected_subjects
    sourceMask = candidates.subjectID == Tout.subjectID(s);
    if sum(sourceMask) == 1 && ...
            candidates.MedianAggregationIncluded(sourceMask) == 1 && ...
            ~isequaln(Tout{s, 2:5}, ToutMedian{s, 2:5})
        error(['A complete single-recording subject differs between the ' ...
            'earliest and median JASP outputs.']);
    end
end

if string(sha256_file(qcCsv)) ~= qcInputSha256 || ...
        string(sha256_file(nrfCsv)) ~= nrfInputSha256
    error('A screened source CSV changed during Step 8 execution.');
end

%% 12) Write validated outputs through temporary files, then read back
tmpOutCsv = [tempname(outDir), '.csv'];
tmpMedianCsv = [tempname(outDir), '.csv'];
tmpManifestCsv = [tempname(outDir), '.csv'];
tmpCleanup = onCleanup(@() delete_temporary_files( ...
    tmpOutCsv, tmpMedianCsv, tmpManifestCsv));

try
    writetable(Tout, tmpOutCsv);
    writetable(ToutMedian, tmpMedianCsv);
    writetable(Tmanifest, tmpManifestCsv);

    validate_written_table(tmpOutCsv, OUT_COLS, ...
        expected_subjects, 'earliest JASP output');
    validate_written_table(tmpMedianCsv, OUT_COLS, ...
        expected_subjects, 'median JASP output');
    validate_written_table(tmpManifestCsv, MANIFEST_COLS, ...
        expected_recordings, 'analysis manifest');

    replace_output_set( ...
        {tmpOutCsv, tmpMedianCsv, tmpManifestCsv}, ...
        {outCsv, outMedianCsv, manifestCsv});
catch ME
    delete_temporary_files(tmpOutCsv, tmpMedianCsv, tmpManifestCsv);
    clear tmpCleanup
    rethrow(ME);
end

%% 13) Report the exact run provenance
scriptPath = fullfile(baseDir, 'scripts', ...
    'step_8_jasp_1_data_prep_eeg.m');

fprintf('\nStrasbourg Step 8 completed successfully.\n');
fprintf('  Candidate recordings: %d\n', expected_recordings);
fprintf('  Unique subjects:      %d\n', expected_subjects);
fprintf('  Not selected:         %d\n', expected_nonselected);
fprintf('  Median contributors:  %d recording pairs from %d subjects\n', ...
    expected_median_contributing_recordings, ...
    expected_median_contributing_subjects);
fprintf('  Complete pairs:       %d subjects in each output\n', ...
    expected_complete_pairs);
fprintf('  QC input SHA-256:     %s\n', qcInputSha256);
fprintf('  NRF input SHA-256:    %s\n', nrfInputSha256);
fprintf('  Script SHA-256:       %s\n', sha256_file(scriptPath));
fprintf('  Earliest CSV SHA-256: %s\n', sha256_file(outCsv));
fprintf('  Median CSV SHA-256:   %s\n', sha256_file(outMedianCsv));
fprintf('  Manifest SHA-256:     %s\n', sha256_file(manifestCsv));
fprintf('  Earliest JASP CSV:    %s\n', outCsv);
fprintf('  Median JASP CSV:      %s\n', outMedianCsv);
fprintf('  Analysis manifest:    %s\n\n', manifestCsv);

clear tmpCleanup
log_command_window('stop');

%% Local helpers
function T = read_required_csv(filePath, requiredColumns, label)
% Import all required columns as strings so malformed numerics cannot be
% silently replaced under MATLAB's default import error handling.
opts = detectImportOptions(filePath, ...
    'PreserveVariableNames', true, 'TextType', 'string');

missingColumns = setdiff(requiredColumns, opts.VariableNames);
if ~isempty(missingColumns)
    error('%s is missing required column(s): %s', ...
        label, strjoin(missingColumns, ', '));
end

opts = setvartype(opts, requiredColumns, 'string');
T = readtable(filePath, opts);
end

function T = normalise_required_text(T, variableNames, label)
for i = 1:numel(variableNames)
    name = variableNames{i};
    values = strtrim(string(T.(name)));
    values(ismissing(values)) = "";
    if any(values == "")
        row = find(values == "", 1, 'first');
        error('%s contains a blank %s at row %d.', label, name, row);
    end
    T.(name) = values;
end
end

function values = parse_required_integer(rawValues, label)
textValues = strtrim(string(rawValues));
textValues(ismissing(textValues)) = "";
values = str2double(textValues);

bad = textValues == "" | ~isfinite(values) | values ~= fix(values);
if any(bad)
    row = find(bad, 1, 'first');
    error('%s contains a missing or invalid integer at row %d.', label, row);
end
end

function values = parse_binary(rawValues, label)
values = parse_required_integer(rawValues, label);
bad = ~ismember(values, [0 1]);
if any(bad)
    row = find(bad, 1, 'first');
    error('%s must contain only 0/1; invalid value at row %d.', label, row);
end
end

function values = parse_optional_numeric(rawValues, label)
textValues = strtrim(string(rawValues));
textValues(ismissing(textValues)) = "";
values = str2double(textValues);

isDeclaredMissing = textValues == "" | ...
    strcmpi(textValues, "nan") | strcmpi(textValues, "na");
bad = ~isfinite(values) & ~isDeclaredMissing;
if any(bad)
    row = find(bad, 1, 'first');
    error('%s contains an invalid numeric value at row %d.', label, row);
end
values(isDeclaredMissing) = NaN;
end

function assert_allowed_values(values, allowedValues, label)
unexpected = setdiff(unique(values), allowedValues);
if ~isempty(unexpected)
    error('%s contains unexpected value(s): %s', ...
        label, strjoin(cellstr(unexpected), ', '));
end
end

function key = make_epoch_key(T, includeNrfName)
parts = [ ...
    T.subjectID, T.sessionID, T.runID, string(T.epoch_index), ...
    upper(T.channel), T.eventtype ...
    ];
if includeNrfName
    parts = [parts, T.NRFName];
end
key = join(parts, char(31), 2);
end

function key = make_recording_key(T)
key = join([T.subjectID,T.sessionID,T.runID], char(31), 2);
end

function assert_unique_keys(keys, label)
if numel(unique(keys)) ~= numel(keys)
    error('%s keys are not unique.', label);
end
end

function [subjectID, sessionID, relativePath] = ...
        canonical_ids_from_marker_path(markerPath, sourceDir, expectedRun)
% Derive canonical IDs from sub-<subject>/ses-<session>/eeg, never from the
% free-form portion of the recording filename.
[eegDir, markerName, markerExt] = fileparts(char(markerPath));
[sessionDir, eegLeaf] = fileparts(eegDir);
[subjectDir, sessionLeaf] = fileparts(sessionDir);
[sourceParent, subjectLeaf] = fileparts(subjectDir);

if ~strcmp(eegLeaf, 'eeg') || ...
        ~startsWith(string(sessionLeaf), "ses-") || ...
        ~startsWith(string(subjectLeaf), "sub-") || ...
        ~strcmp(sourceParent, char(sourceDir))
    error('Unexpected BrainVision source path layout: %s', markerPath);
end

expectedSuffix = "-" + lower(expectedRun) + "nofilter.vmrk";
fullName = lower(string(markerName) + string(markerExt));
if ~endsWith(fullName, expectedSuffix)
    error('Unexpected cannula marker filename/run token: %s', markerPath);
end

subjectID = extractAfter(string(subjectLeaf), "sub-");
sessionID = extractAfter(string(sessionLeaf), "ses-");
if subjectID == "" || sessionID == ""
    error('Blank canonical ID derived from marker path: %s', markerPath);
end

rootPrefix = string(sourceDir) + filesep;
if ~startsWith(markerPath, rootPrefix)
    error('Marker path is not below data/source: %s', markerPath);
end
relativePath = extractAfter(markerPath, strlength(rootPrefix));
relativePath = strrep(relativePath, filesep, '/');
end

function [eventDatetimeText, chronologyKey] = parse_cannula_datetime( ...
        markerPath, samplingRateHz, expectedSegmentSample, expectedStimSample)
% Parse exactly one New Segment timestamp and one Stim 2 position.
markerText = fileread(char(markerPath));

newSegmentTokens = regexpi(markerText, ...
    '(?m)^Mk\d+=New Segment,,(\d+),(\d+),(\d+),(\d{20})\r?$', ...
    'tokens');
stim2Tokens = regexpi(markerText, ...
    '(?m)^Mk\d+=Stimulus,Stim 2,(\d+),(\d+),(\d+)(?:,[^\r\n]*)?\r?$', ...
    'tokens');

if numel(newSegmentTokens) ~= 1
    error('Expected exactly one New Segment marker in: %s', markerPath);
end
if numel(stim2Tokens) ~= 1
    error('Expected exactly one Stimulus,Stim 2 marker in: %s', markerPath);
end

newPosition = parse_digit_token(newSegmentTokens{1}{1}, ...
    'New Segment position', markerPath);
newSize = parse_digit_token(newSegmentTokens{1}{2}, ...
    'New Segment size', markerPath);
newChannel = parse_digit_token(newSegmentTokens{1}{3}, ...
    'New Segment channel', markerPath);
rawTimestamp = string(newSegmentTokens{1}{4});

stimPosition = parse_digit_token(stim2Tokens{1}{1}, ...
    'Stim 2 position', markerPath);
stimSize = parse_digit_token(stim2Tokens{1}{2}, ...
    'Stim 2 size', markerPath);
stimChannel = parse_digit_token(stim2Tokens{1}{3}, ...
    'Stim 2 channel', markerPath);

if newPosition ~= expectedSegmentSample || newSize ~= 1 || newChannel ~= 0
    error('Unexpected New Segment marker fields in: %s', markerPath);
end
if stimPosition ~= expectedStimSample || stimSize ~= 1 || stimChannel ~= 0
    error('Unexpected Stim 2 marker fields in: %s', markerPath);
end

stampChars = char(rawTimestamp);
baseText = stampChars(1:14);
microsecondText = stampChars(15:20);
microsecondValue = str2double(microsecondText);

if isempty(regexp(microsecondText, '^\d{6}$', 'once')) || ...
        ~isfinite(microsecondValue) || microsecondValue < 0 || ...
        microsecondValue > 999999
    error('Invalid BrainVision fractional-second timestamp in: %s', markerPath);
end

try
    segmentDatetime = datetime(baseText, ...
        'InputFormat', 'yyyyMMddHHmmss');
catch ME
    error('Invalid BrainVision date/time in %s: %s', markerPath, ME.message);
end
segmentDatetime.Format = 'yyyyMMddHHmmss';

if string(segmentDatetime) ~= string(baseText)
    error('BrainVision whole-second timestamp failed round-trip validation in: %s', ...
        markerPath);
end

eventOffsetSeconds = ...
    (stimPosition - newPosition) / samplingRateHz;
expectedOffsetSeconds = ...
    (expectedStimSample - expectedSegmentSample) / samplingRateHz;
if eventOffsetSeconds ~= expectedOffsetSeconds || ...
        expectedOffsetSeconds ~= 2
    error('Unexpected cannula event timing offset in: %s', markerPath);
end

eventWholeSecond = segmentDatetime + seconds(eventOffsetSeconds);
eventWholeSecond.Format = "yyyy-MM-dd'T'HH:mm:ss";
eventDatetimeText = string(eventWholeSecond) + "." + string(microsecondText);

% A fixed-width digit string preserves the source microseconds exactly and is
% lexicographically sortable. Every current recording has the same 2-second
% offset, so the raw segment timestamp is also an exact event-order key.
chronologyKey = rawTimestamp;
end

function value = parse_digit_token(token, label, markerPath)
if isempty(regexp(token, '^\d+$', 'once'))
    error('%s is not an unsigned integer in: %s', label, markerPath);
end
value = str2double(token);
if ~isfinite(value)
    error('%s is not finite in: %s', label, markerPath);
end
end

function rowIndex = find_one_qc_epoch( ...
        T, subjectID, sessionID, runID, epochIndex, channel, eventtype)
mask = T.subjectID == subjectID & ...
    T.sessionID == sessionID & ...
    T.runID == runID & ...
    T.epoch_index == epochIndex & ...
    strcmpi(T.channel, channel) & ...
    T.eventtype == eventtype;

if sum(mask) ~= 1
    error(['Expected exactly one QC row for selected full epoch identity; ' ...
        'found %d.'], sum(mask));
end
rowIndex = find(mask);
end

function rowIndex = find_one_nrf_epoch( ...
        T, subjectID, sessionID, runID, epochIndex, channel, eventtype, nrfName)
mask = T.subjectID == subjectID & ...
    T.sessionID == sessionID & ...
    T.runID == runID & ...
    T.epoch_index == epochIndex & ...
    strcmpi(T.channel, channel) & ...
    T.eventtype == eventtype & ...
    T.NRFName == nrfName;

if sum(mask) ~= 1
    error(['Expected exactly one NRF row for selected full epoch identity; ' ...
        'found %d.'], sum(mask));
end
rowIndex = find(mask);
end

function assert_finite_retained(value, label)
if ~isscalar(value) || ~isfinite(value)
    error('Retained %s must be one finite scalar value.', label);
end
end

function assert_finite_retained_vector(values, label)
if isempty(values) || ~isvector(values) || any(~isfinite(values))
    error('Every contributing %s value must be finite.', label);
end
end

function validate_written_table(filePath, expectedColumns, expectedRows, label)
opts = detectImportOptions(filePath, ...
    'PreserveVariableNames', true, 'TextType', 'string');
if ~isequal(opts.VariableNames, expectedColumns)
    error('Written %s schema failed read-back validation.', label);
end
T = readtable(filePath, opts);
if height(T) ~= expectedRows
    error('Written %s row count failed read-back validation.', label);
end
end

function replace_output_set(temporaryPaths, destinationPaths)
% Replace every destination as one rollback-oriented set. Existing files are
% backed up before the first move and all destinations are restored if any
% replacement fails.
if numel(temporaryPaths) ~= numel(destinationPaths) || isempty(temporaryPaths)
    error('Output replacement requires equally sized nonempty path sets.');
end

nFiles = numel(destinationPaths);
backupPaths = cell(1, nFiles);
hadOriginal = false(1, nFiles);

for i = 1:nFiles
    backupPaths{i} = [tempname(fileparts(destinationPaths{i})), '.bak'];
end
backupCleanup = onCleanup(@() delete_temporary_files(backupPaths{:}));

for i = 1:nFiles
    hadOriginal(i) = isfile(destinationPaths{i});
    if hadOriginal(i)
        [ok, msg] = copyfile(destinationPaths{i}, backupPaths{i});
        if ~ok
            error('Failed to back up output "%s": %s', ...
                destinationPaths{i}, msg);
        end
    end
end

for i = 1:nFiles
    [ok, msg] = movefile(temporaryPaths{i}, destinationPaths{i}, 'f');
    if ~ok
        for j = 1:nFiles
            restore_destination( ...
                destinationPaths{j}, backupPaths{j}, hadOriginal(j));
        end
        error(['Failed to replace output "%s"; all destinations were ' ...
            'restored to their pre-run state: %s'], ...
            destinationPaths{i}, msg);
    end
end

clear backupCleanup
end

function restore_destination(destination, backup, hadOriginal)
if hadOriginal
    [ok, msg] = copyfile(backup, destination, 'f');
    if ~ok
        error('Failed to restore output "%s": %s', destination, msg);
    end
elseif isfile(destination)
    delete(destination);
end
end

function delete_temporary_files(varargin)
for i = 1:nargin
    filePath = varargin{i};
    if isfile(filePath)
        try %#ok<TRYNC>
            delete(filePath);
        end
    end
end
end

function h = sha256_file(filePath)
% Compute SHA-256 over the file's exact raw bytes.
if ~isfile(filePath)
    error('sha256_file:FileNotFound', 'File not found: %s', filePath);
end

fileObject = java.io.File(filePath);
rawBytes = java.nio.file.Files.readAllBytes(fileObject.toPath());
md = java.security.MessageDigest.getInstance('SHA-256');
d = md.digest(rawBytes);
h = bytes2hex(d);
end

function h = bytes2hex(javaInt8Array)
u = typecast(javaInt8Array, 'uint8');
h = lower(reshape(dec2hex(u, 2).', 1, []));
end
