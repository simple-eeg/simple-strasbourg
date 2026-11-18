function result = run_step2_sanitisation_tests(repoRoot)
%RUN_STEP2_SANITISATION_TESTS Focused synthetic Step 2.11 tests.

arguments
    repoRoot (1,:) char
end
originalPath = path;
pathCleanup = onCleanup(@() path(originalPath));
addpath(fullfile(repoRoot, 'tests', 'helpers'), '-begin');
functionsRoot = fullfile(repoRoot, 'functions');
addpath(functionsRoot, '-begin');
clear build_pseudonymised_dataset_registry inspect_identity_state ...
    inspect_pseudonymisation_inputs load_dataset_identity_registry ...
    run_sanitisation_transaction ...
    sanitise_eeglab_dataset validate_dataset_registry_paths ...
    verify_sanitised_eeglab_dataset
rehash path;
caseNames = [ ...
    "continuous_v6_success_and_noop"; ...
    "epoched_wrapper_auto_v73_and_exact_mirror"; ...
    "authorised_metadata_science_and_leading_zeros"; ...
    "privacy_classification_and_redacted_diagnostics"; ...
    "external_pointers_mirror_and_content_rejected"; ...
    "verifier_rejects_policy_and_scientific_drift"; ...
    "prerequisite_downstream_schema_and_storage_guards"; ...
    "caught_failure_restores_original_state"; ...
    "hard_interruption_recovers_then_stops"; ...
    "pre_mutation_workspace_recovery"; ...
    "foreign_or_malformed_workspace_is_preserved"; ...
    "changed_raw_orig_or_unknown_active_is_preserved"];

case_continuous_success(repoRoot);
case_epoched_v73(repoRoot);
case_metadata_policy();
case_privacy_policy(repoRoot);
case_unsupported_content();
case_verifier_drift(repoRoot);
skipped = case_preflight_guards(repoRoot);
case_caught_failure(repoRoot);
case_hard_interruption(repoRoot);
case_pre_mutation_recovery(repoRoot);
skipped = skipped + case_unknown_workspace(repoRoot);
case_changed_governed_files(repoRoot);

result = struct('schema', 'simple-step2-sanitisation-tests-v1', ...
    'case_names', caseNames, 'total', numel(caseNames), ...
    'skipped', skipped, 'passed', true);
fprintf('STEP 2 SANITISATION TEST GROUPS PASSED: %d; platform skips: %d\n', ...
    result.total, skipped);
end

function case_continuous_success(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
registryHash = sha256_file(fixture.registry);
activeMetadata = fullfile(fixture.root, 'data', 'raw', '.DS_Store');
write_text(activeMetadata, 'finder preflight metadata');
outcome = run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50, 'save_version', "v6"));
assert(strcmp(outcome.status, 'completed') && outcome.verified_count == 1);
assert(isequal(outcome.save_versions, "v6"));
assert(~isfolder(fixture.workspace));
assert(strcmp(sha256_file(fixture.registry), registryHash));
assert(strcmp(sha256_file(fixture.source), fixture.source_hash));
stored = load('-mat', fixture.active);
assert(strcmp(stored.subject, '001') && strcmp(stored.session, '01'));
assert(strcmp(stored.run, '01') && isempty(stored.filepath));
assert(~isfield(stored.event, 'bvtime') && ...
    ~isfield(stored.urevent, 'bvtime'));
assert(isfile(activeMetadata));
second = run_sanitisation_transaction(fixture.root);
assert(strcmp(second.status, 'no-op') && second.no_op);

midTransaction = create_mapped_fixture(repoRoot, false, ...
    'top-level-fields', 1);
midCleanup = onCleanup(@() cleanup_fixture(midTransaction));
activate_fixture_functions(midTransaction);
midMetadata = fullfile(midTransaction.root, 'data', 'raw', '.DS_Store');
midOutcome = run_sanitisation_transaction(midTransaction.root, struct( ...
    'available_bytes_override', 2^50, 'save_version', "v6", ...
    'after_promotion', @(row) add_finder_metadata(row, midMetadata)));
assert(strcmp(midOutcome.status, 'completed') && isfile(midMetadata));
midNoOp = run_sanitisation_transaction(midTransaction.root);
assert(strcmp(midNoOp.status, 'no-op') && midNoOp.no_op);

descriptionFixture = create_mapped_fixture(repoRoot, false, ...
    'top-level-fields', 1);
descriptionCleanup = onCleanup(@() cleanup_fixture(descriptionFixture));
activate_fixture_functions(descriptionFixture);
descriptionEEG = load('-mat', descriptionFixture.source);
descriptionEEG.eventdescription = {'legacy event-field description'};
save_fixture_set(descriptionFixture.source, descriptionEEG, ...
    'top-level-fields', '-v6');
assert(copyfile(descriptionFixture.source, descriptionFixture.active, 'f'));
descriptionOutcome = run_sanitisation_transaction(descriptionFixture.root, ...
    struct('available_bytes_override', 2^50, 'save_version', "v6"));
assert(strcmp(descriptionOutcome.status, 'completed'));
end

function case_epoched_v73(repoRoot)
fixture = create_mapped_fixture(repoRoot, true, 'scalar-EEG-wrapper', 1);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
loaded = load('-mat', fixture.source, 'EEG');
EEG = loaded.EEG;
EEG.group = "control";
save_fixture_set(fixture.source, EEG, 'scalar-EEG-wrapper', '-v7.3');
copyfile(fixture.source, fixture.active, 'f');
fixture.source_hash = sha256_file(fixture.source);
outcome = run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50));
assert(isequal(outcome.save_versions, "v7.3"));
stored = load('-mat', fixture.active, 'EEG');
assert(strcmp(stored.EEG.subject, '001'));
assert(strcmp(stored.EEG.session, '01') && strcmp(stored.EEG.run, '01'));
assert(~isfield(stored.EEG.event, 'bvtime'));
assert(~isfield(stored.EEG.urevent, 'bvtime'));
assert(~isfield(stored.EEG.epoch, 'eventbvtime'));
assert(isequal([stored.EEG.event.bvmknum], [1 2]));
assert(strcmp(sha256_file(fixture.source), fixture.source_hash));

fixture2 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
activate_fixture_functions(fixture2);
outcome = run_sanitisation_transaction(fixture2.root, struct( ...
    'available_bytes_override', 2^50, ...
    'v6_error_identifier', "MATLAB:save:sizeTooBigForMATFile"));
assert(isequal(outcome.save_versions, "v7.3"));
verify_sanitised_eeglab_dataset(fixture2.source, fixture2.active, ...
    expected_identity(), privacy_context());
end

function case_metadata_policy()
EEG = make_eeg(false);
EEG.urevent = rmfield(EEG.event, 'urevent');
eventFields = fieldnames(EEG.event);
eventBvtime = find(strcmp(eventFields, 'bvtime'));
expectedEventDescriptions = EEG.eventdescription;
expectedEventDescriptions(eventBvtime) = [];
EEG.icaweights = eye(2);
EEG.icasphere = eye(2);
EEG.etc.safeNumeric = [1 2 3];
[EEG.chanlocs.impedance] = deal(4.2, 5.3);
[clean, report] = sanitise_eeglab_dataset( ...
    EEG, expected_identity(), privacy_context());
assert(isequal(clean.data, EEG.data) && isequal(clean.icaweights, eye(2)));
assert(isequal(clean.etc.safeNumeric, [1 2 3]));
assert(isequal([clean.chanlocs.impedance], [4.2 5.3]));
assert(isequal(clean.eventdescription, expectedEventDescriptions));
assert(strcmp(clean.group, 'control') && strcmp(clean.condition, 'pain'));
assert(strcmp(clean.subject, '001') && strcmp(clean.session, '01'));
assert(strcmp(clean.run, '01') && isempty(clean.filepath));
assert(isempty(clean.comments) && isempty(clean.history));
assert(~isfield(clean.event, 'bvtime') && ~isfield(clean.urevent, 'bvtime'));
assert(report.event_bvtime_removed == 1, ...
    'Expected one event bvtime removal; got %d.', ...
    report.event_bvtime_removed);
assert(report.urevent_bvtime_removed == 1, ...
    'Expected one urevent bvtime removal; got %d.', ...
    report.urevent_bvtime_removed);
assert(~report.requires_v73, ...
    'Unexpected string or categorical scientific content.');
end

function case_privacy_policy(repoRoot)
base = make_eeg(false);
privacy = privacy_context();
tests = { ...
    @(EEG) set_field(EEG, 'participant_id', 17), 'RiskyField'; ...
    @(EEG) set_etc_field(EEG, 'MRN', 123456), 'RiskyField'; ...
    @(EEG) set_etc_field(EEG, 'MRNValue', 123456), 'RiskyField'; ...
    @(EEG) set_etc_field(EEG, 'recordNo', 123456), 'RiskyField'; ...
    @(EEG) set_etc_field(EEG, 'medicalRecordNo', true), 'RiskyField'; ...
    @(EEG) set_field(EEG, 'custom_note', 'ordinary note'), 'UnclassifiedText'; ...
    @(EEG) set_field(EEG, 'group', 'OrigA'), 'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'participantOrigArecord'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'person@example.org'), 'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', '/private/source/file'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', '../archive/file.set'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', './archive/file.set'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', '~/archive/file.set'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/file.set'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/file.set.'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/file.set:'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/file.set!'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/file.set?'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'archive/recording.001'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/my file.set'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/participant notes.txt'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'exports/archive/source signal.vhdr'), ...
        'ResidualIdentifier'; ...
    @(EEG) set_field(EEG, 'group', 'templates/MNI152.nii.gz'), ...
        'ResidualIdentifier'};
for index = 1:size(tests, 1)
    failure = capture_failure(@() sanitise_eeglab_dataset( ...
        tests{index, 1}(base), expected_identity(), privacy));
    assert(endsWith(string(failure.identifier), string(tests{index, 2})));
    details = string(getReport(failure, 'extended', 'hyperlinks', 'off'));
    assert(~contains(details, 'OrigA') && ...
        ~contains(details, 'participant_id') && ...
        ~contains(details, 'person@example.org'));
end
failure = capture_failure(@() sanitise_eeglab_dataset( ...
    tests{1, 1}(base), expected_identity(), privacy));
assert(contains(string(failure.message), '<redacted-field-1>'));

distinctive = privacy;
distinctive.original_run_id = 'stim2';
assert_rejected(@() sanitise_eeglab_dataset(set_field(base, 'group', ...
    'stim2pain'), expected_identity(), distinctive), ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier');
distinctive.original_run_id = '123';
assert_rejected(@() sanitise_eeglab_dataset(set_field(base, 'group', ...
    'phase123pain'), expected_identity(), distinctive), ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier');
generic = privacy;
generic.original_session_id = '01';
generic.original_run_id = '1';
clean = sanitise_eeglab_dataset(set_field(base, 'group', 'phase01'), ...
    expected_identity(), generic);
assert(strcmp(clean.group, 'phase01'));
numericSubject = privacy;
numericSubject.original_subject_id = '6';
assert_rejected(@() sanitise_eeglab_dataset(set_field(base, 'group', ...
    'phase6'), expected_identity(), numericSubject), ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier');
clean = sanitise_eeglab_dataset(set_etc_field(base, ...
    'metric6value', 1), expected_identity(), numericSubject);
assert(clean.etc.metric6value == 1);
assert_rejected(@() sanitise_eeglab_dataset(set_etc_field(base, ...
    'subject6value', 1), expected_identity(), numericSubject), ...
    'SIMPLE:Step2Sanitise:RiskyField');
numericVersionSafe = base;
numericVersionSafe.etc.eeglabvers = '2026.0';
clean = sanitise_eeglab_dataset(numericVersionSafe, ...
    expected_identity(), numericSubject);
assert(strcmp(clean.etc.eeglabvers, '2026.0'));
clean = sanitise_eeglab_dataset(set_field(base, 'group', '1.2/6.4'), ...
    expected_identity(), numericSubject);
assert(strcmp(clean.group, '1.2/6.4'));
generic.original_session_id = '6';
generic.original_run_id = '6';
clean = sanitise_eeglab_dataset(set_field(base, 'group', 'phase6'), ...
    expected_identity(), generic);
assert(strcmp(clean.group, 'phase6'));
safeLabels = ["left/right", "Cz/Fz", "mg/kg", "pain/control", ...
    "1.2/3.4", "source"];
for label = safeLabels
    clean = sanitise_eeglab_dataset(set_field(base, 'group', label), ...
        expected_identity(), generic);
    assert(string(clean.group) == label);
end

fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 2);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
append_excluded_subject(fixture.preliminary, 'ExcludedNumeric', ...
    "", "", "01", "1");
add_source_reference_columns(fixture.preliminary);
identity = load_dataset_identity_registry(fixture.registry);
original = original_view(identity);
snapshot = inspect_pseudonymisation_inputs(fixture.root, original, ...
    fullfile(fixture.root, 'data', 'raw_orig'));
[~, secondStem] = fileparts(char(original.EEGfile_raw(2)));
expectedTokens = [original.subjectID(2); original.sessionID(2); ...
    original.runID(2); original.path_raw(2); original.EEGfile_raw(2); ...
    string(secondStem); "LegacyPrivateB.cdt.dpa"; ...
    "LegacyPrivateB.cdt"; "LegacyPrivateB"; ...
    "/archive/LegacyPrivateContainerB"; "LegacyPrivateContainerB"; ...
    "ExcludedSourceOnly.001"; "ExcludedSourceOnly"; ...
    "/archive/ExcludedSourceContainer"; "ExcludedSourceContainer"; "7"; ...
    "CamelPrivateB.002"; "CamelPrivateB"; ...
    "/camel/01/CamelPathB"; "CamelPathB"; ...
    "~/external/LoosePrivateB"; "LoosePrivateB"; ...
    "/camel/8.001"; "8.001"; "8"];
assert(all(ismember(expectedTokens, snapshot.privacy_tokens)));
assert(~any(ismember(["01", "1"], snapshot.privacy_tokens)));
assert(~any(ismember(["01", "1"], snapshot.subject_privacy_tokens)));
scientificTokens = ["Cz/Fz", "Cz", "Fz", "mg/kg", "mg", "kg", ...
    "Stimulus/S  1", "Stimulus", "S  1", "alpha.beta", "alpha", ...
    "pain/control", "left/right", "none", "not applicable", ...
    "unknown", "2"];
assert(~any(ismember(scientificTokens, snapshot.privacy_tokens)));
globalPrivacy = privacy_context();
globalPrivacy.blocked_tokens = snapshot.privacy_tokens;
globalPrivacy.subject_tokens = snapshot.subject_privacy_tokens;
for label = ["Cz/Fz", "mg/kg", "Stimulus/S  1", "pain/control"]
    clean = sanitise_eeglab_dataset(set_field(base, 'group', label), ...
        expected_identity(), globalPrivacy);
    assert(string(clean.group) == label);
end
clean = sanitise_eeglab_dataset(set_field(base, 'group', 'phase6'), ...
    expected_identity(), globalPrivacy);
assert(strcmp(clean.group, 'phase6'));
versionSafe = base;
versionSafe.etc.eeglabvers = '2026.0';
clean = sanitise_eeglab_dataset(versionSafe, ...
    expected_identity(), globalPrivacy);
assert(strcmp(clean.etc.eeglabvers, '2026.0'));
assert_rejected(@() sanitise_eeglab_dataset( ...
    set_field(base, 'group', 'source-6.set'), ...
    expected_identity(), globalPrivacy), ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier');
fixture = set_fixture_group(fixture, 1, 'participantLegacyPrivateBrecord');
failure = capture_failure(@() run_sanitisation_transaction(fixture.root));
assert(strcmp(failure.identifier, ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier'));
assert(~contains(string(getReport(failure, 'extended', ...
    'hyperlinks', 'off')), 'LegacyPrivateB'));
assert_original_state(fixture);

fixture2 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
activate_fixture_functions(fixture2);
append_excluded_subject(fixture2.preliminary, 'ExcludedPrivate');
append_excluded_subject(fixture2.preliminary, '03');
identity2 = load_dataset_identity_registry(fixture2.registry);
snapshot2 = inspect_pseudonymisation_inputs(fixture2.root, ...
    original_view(identity2), fullfile(fixture2.root, 'data', 'raw_orig'));
assert(~ismember("03", snapshot2.privacy_tokens));
assert(ismember("03", snapshot2.subject_privacy_tokens));
fixture2 = set_fixture_group(fixture2, 1, ...
    'participantExcludedPrivaterecord');
failure = capture_failure(@() run_sanitisation_transaction(fixture2.root));
assert(strcmp(failure.identifier, ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier'));
assert(~contains(string(getReport(failure, 'extended', ...
    'hyperlinks', 'off')), 'ExcludedPrivate'));
assert_original_state(fixture2);
fixture2 = set_fixture_group(fixture2, 1, 'participant03record');
failure = capture_failure(@() run_sanitisation_transaction(fixture2.root));
assert(strcmp(failure.identifier, ...
    'SIMPLE:Step2Sanitise:ResidualIdentifier'));
assert_original_state(fixture2);
end

function case_unsupported_content()
privacy = privacy_context();
expected = expected_identity();
EEG = make_eeg(false);
EEG.datfile = 'external.fdt';
assert_rejected(@() sanitise_eeglab_dataset(EEG, expected, privacy), ...
    'SIMPLE:Step2Sanitise:ExternalPointer');
EEG = make_eeg(false);
EEG.dipfit.mrifile = '/private/anatomy.mat';
assert_rejected(@() sanitise_eeglab_dataset(EEG, expected, privacy), ...
    'SIMPLE:Step2Sanitise:RiskyField');
EEG = make_eeg(false);
EEG.data = 'external.fdt';
assert_rejected(@() sanitise_eeglab_dataset(EEG, expected, privacy), ...
    'SIMPLE:Step2Sanitise:ExternalData');
EEG = make_eeg(true);
EEG.epoch(1).eventbvtime = {'wrong-time'};
assert_rejected(@() sanitise_eeglab_dataset(EEG, expected, privacy), ...
    'SIMPLE:Step2Sanitise:EpochBvtimeNotMirror');
EEG = make_eeg(false);
EEG.etc.custom = table(1);
assert_rejected(@() sanitise_eeglab_dataset(EEG, expected, privacy), ...
    'SIMPLE:Step2Sanitise:UnsupportedContent');
end

function case_verifier_drift(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
original = load('-mat', fixture.source);
candidate = sanitise_eeglab_dataset( ...
    original, expected_identity(), privacy_context());
save_fixture_set(fixture.active, candidate, 'top-level-fields', '-v6');
verify_sanitised_eeglab_dataset(fixture.source, fixture.active, ...
    expected_identity(), privacy_context());
candidate.data(1) = candidate.data(1) + 1;
save_fixture_set(fixture.active, candidate, 'top-level-fields', '-v6');
assert_rejected(@() verify_sanitised_eeglab_dataset( ...
    fixture.source, fixture.active, expected_identity(), privacy_context()), ...
    'SIMPLE:Step2Sanitise:ScientificDifference');
candidate = sanitise_eeglab_dataset( ...
    original, expected_identity(), privacy_context());
candidate.filepath = '/private/leak';
save_fixture_set(fixture.active, candidate, 'top-level-fields', '-v6');
assert_rejected(@() verify_sanitised_eeglab_dataset( ...
    fixture.source, fixture.active, expected_identity(), privacy_context()), ...
    'SIMPLE:Step2Sanitise:StoredPolicyMismatch');
end

function skipped = case_preflight_guards(repoRoot)
skipped = 0;
fixture = create_original_fixture(repoRoot);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
assert_rejected(@() run_sanitisation_transaction(fixture.root), ...
    'SIMPLE:Step2Sanitise:InvalidStartingState');

fixture2 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
activate_fixture_functions(fixture2);
mkdir(fullfile(fixture2.root, 'data', 'results'));
write_text(fullfile(fixture2.root, 'data', 'results', 'later.txt'), 'later');
assert_rejected(@() run_sanitisation_transaction(fixture2.root), ...
    'SIMPLE:Step2Sanitise:DownstreamStateExists');

fixture3 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup3 = onCleanup(@() cleanup_fixture(fixture3));
activate_fixture_functions(fixture3);
assert_rejected(@() run_sanitisation_transaction(fixture3.root, ...
    struct('available_bytes_override', 0)), ...
    'SIMPLE:Step2Sanitise:InsufficientStorage');

fixture4 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup4 = onCleanup(@() cleanup_fixture(fixture4));
activate_fixture_functions(fixture4);
identity = load_dataset_identity_registry(fixture4.registry);
T = identity.table;
T.path_processed = T.path_raw;
writetable(T, fixture4.registry, 'QuoteStrings', true);
assert_rejected(@() run_sanitisation_transaction(fixture4.root), ...
    'SIMPLE:Step2Sanitise:MappedRegistryRequired');

fixture5 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup5 = onCleanup(@() cleanup_fixture(fixture5));
activate_fixture_functions(fixture5);
extraDirectory = fullfile(fixture5.root, 'data', 'raw', 'extra-empty');
mkdir(extraDirectory);
assert_rejected(@() run_sanitisation_transaction(fixture5.root), ...
    'SIMPLE:Step2Sanitise:UnexpectedActiveInventory');
assert(isfolder(extraDirectory));

nodeKinds = ["file", "symlink"];
if isunix
    nodeKinds(end + 1) = "fifo";
else
    fprintf('SKIP: two Unix FIFO downstream-state fixtures are unavailable.\n');
    skipped = skipped + 2;
end
for rootName = ["results", "logs"]
    for nodeKind = nodeKinds
        fixtureNode = create_mapped_fixture(repoRoot, false, ...
            'top-level-fields', 1);
        nodeCleanup = onCleanup(@() cleanup_fixture(fixtureNode));
        activate_fixture_functions(fixtureNode);
        slot = fullfile(fixtureNode.root, 'data', char(rootName));
        if ~create_filesystem_object(slot, nodeKind, fixtureNode.registry)
            skipped = skipped + 1;
            continue
        end
        assert_rejected(@() run_sanitisation_transaction(fixtureNode.root), ...
            'SIMPLE:Step2Sanitise:DownstreamStateExists');
        entries = dir(fullfile(fixtureNode.root, 'data'));
        assert(any(strcmp({entries.name}, char(rootName))));
    end
end
end

function case_caught_failure(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 2);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
assert_rejected(@() run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50, ...
    'after_promotion', @throw_caught_failure)), ...
    'SIMPLE:Test:CaughtFailure');
assert_original_state(fixture);

fixture2 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
activate_fixture_functions(fixture2);
assert_rejected(@() run_sanitisation_transaction(fixture2.root, struct( ...
    'available_bytes_override', 2^50, ...
    'v6_error_identifier', "SIMPLE:Test:OtherSaveFailure")), ...
    'SIMPLE:Step2Sanitise:CandidateSaveFailed');
assert_original_state(fixture2);
end

function case_hard_interruption(repoRoot)
fixture = interrupted_full_tree_fixture(repoRoot);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
assert(isfolder(fixture.workspace) && ~isfile(fixture.registry));
assert(isfile(fullfile(fixture.workspace, 'dataset_list.locked.csv')));
loaded = load('-mat', fullfile(fixture.workspace, 'manifest.mat'));
manifest = loaded.manifest;
assert(isequal(fieldnames(manifest), {'schema'; 'operation'; ...
    'registry_hash'; 'preliminary_hash'; 'raw_tree_hash'; ...
    'row_count'; 'source_hashes'}));
assert(strcmp(manifest.schema, 'simple-step2-sanitisation-v2'));
assert(strcmp(manifest.operation, 'step_2_raw_11'));
assert(manifest.row_count == numel(fixture.source_files));
hashes = [{manifest.registry_hash}; {manifest.preliminary_hash}; ...
    {manifest.raw_tree_hash}; manifest.source_hashes];
assert(all(~cellfun(@isempty, regexp(hashes, '^[0-9a-f]{64}$', 'once'))));
printed = string(evalc('disp(manifest)'));
privateValues = ["OrigA", "OrigB", "visit1", "visit2", "run1", ...
    "run2", "ExcludedTree", string(fixture.root), string(getenv('USER'))];
privateValues = privateValues(privateValues ~= "");
assert(~any(contains(printed, privateValues)));
outcome = run_sanitisation_transaction(fixture.root);
assert(strcmp(outcome.status, 'recovered') && outcome.recovered);
assert_original_state(fixture);
assert(isfile(fixture.ds_store) && isfile(fixture.excluded_source));
assert(isfolder(fixture.empty_source_dir));
outcome = run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50));
assert(strcmp(outcome.status, 'completed'));
end

function case_pre_mutation_recovery(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
mkdir(fixture.workspace);
manifest = fixture_manifest(fixture);
save(fullfile(fixture.workspace, 'manifest.pending.mat'), ...
    '-v6', '-mat', 'manifest');
outcome = run_sanitisation_transaction(fixture.root);
assert(strcmp(outcome.status, 'recovered'));
assert_original_state(fixture);
end

function skipped = case_unknown_workspace(repoRoot)
skipped = 0;
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup = onCleanup(@() cleanup_fixture(fixture));
activate_fixture_functions(fixture);
mkdir(fixture.workspace);
assert_rejected(@() run_sanitisation_transaction(fixture.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfolder(fixture.workspace));
assert_original_files(fixture);

fixture2 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
activate_fixture_functions(fixture2);
mkdir(fixture2.workspace);
junk = 1;
pendingPath = fullfile(fixture2.workspace, 'manifest.pending.mat');
save(pendingPath, 'junk', '-v6');
pendingHash = sha256_file(pendingPath);
assert_rejected(@() run_sanitisation_transaction(fixture2.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(strcmp(sha256_file(pendingPath), pendingHash));
assert_original_files(fixture2);
delete(pendingPath);
manifest = fixture_manifest(fixture2);
save(pendingPath, 'manifest', 'junk', '-v6');
pendingHash = sha256_file(pendingPath);
assert_rejected(@() run_sanitisation_transaction(fixture2.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfolder(fixture2.workspace));
assert(strcmp(sha256_file(pendingPath), pendingHash));
assert_original_files(fixture2);

fixture3 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup3 = onCleanup(@() cleanup_fixture(fixture3));
activate_fixture_functions(fixture3);
mkdir(fixture3.workspace);
write_text(fullfile(fixture3.workspace, 'foreign.txt'), 'foreign');
assert_rejected(@() run_sanitisation_transaction(fixture3.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfile(fullfile(fixture3.workspace, 'foreign.txt')));
assert_original_files(fixture3);

fixture4 = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
cleanup4 = onCleanup(@() cleanup_fixture(fixture4));
activate_fixture_functions(fixture4);
mkdir(fixture4.workspace);
manifestPath = fullfile(fixture4.workspace, 'manifest.mat');
save(manifestPath, 'junk', '-v6');
manifestHash = sha256_file(manifestPath);
assert_rejected(@() run_sanitisation_transaction(fixture4.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(strcmp(sha256_file(manifestPath), manifestHash));
assert_original_files(fixture4);

conflict = interrupted_fixture(repoRoot);
conflictCleanup = onCleanup(@() cleanup_fixture(conflict));
pseudonymisationWorkspace = fullfile(conflict.root, 'data', ...
    '.step_2_raw_10_transaction');
mkdir(pseudonymisationWorkspace);
sentinel = fullfile(pseudonymisationWorkspace, 'foreign.txt');
write_text(sentinel, 'foreign');
governed = [conflict.source_files(:); conflict.active_files(:); ...
    {fullfile(conflict.workspace, 'dataset_list.locked.csv'); ...
    fullfile(conflict.workspace, 'manifest.mat'); sentinel}];
governedHashes = cellfun(@sha256_file, governed, 'UniformOutput', false);
assert_rejected(@() run_sanitisation_transaction(conflict.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(~isfile(conflict.registry) && isfolder(conflict.workspace) && ...
    isfolder(pseudonymisationWorkspace));
assert(isequal(cellfun(@sha256_file, governed, 'UniformOutput', false), ...
    governedHashes));

preManifestConflict = create_mapped_fixture(repoRoot, false, ...
    'top-level-fields', 1);
preManifestCleanup = onCleanup(@() cleanup_fixture(preManifestConflict));
activate_fixture_functions(preManifestConflict);
pseudonymisationWorkspace = fullfile(preManifestConflict.root, 'data', ...
    '.step_2_raw_10_transaction');
governed = [{preManifestConflict.registry}; ...
    preManifestConflict.source_files(:); ...
    preManifestConflict.active_files(:)];
governedHashes = cellfun(@sha256_file, governed, 'UniformOutput', false);
assert_rejected(@() run_sanitisation_transaction( ...
    preManifestConflict.root, struct( ...
    'available_bytes_override', 2^50, ...
    'after_pending_manifest', ...
    @() create_pseudonymisation_conflict(pseudonymisationWorkspace))), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
pendingPath = fullfile(preManifestConflict.workspace, ...
    'manifest.pending.mat');
assert(isfile(pendingPath) && isfolder(pseudonymisationWorkspace));
assert(isfile(fullfile(pseudonymisationWorkspace, 'foreign.txt')));
assert(isequal(cellfun(@sha256_file, governed, 'UniformOutput', false), ...
    governedHashes));
pendingHash = sha256_file(pendingPath);
assert_rejected(@() run_sanitisation_transaction(preManifestConflict.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(strcmp(sha256_file(pendingPath), pendingHash));

for kind = ["pending", "manifest", "locked", "candidate", ...
        "source", "active"]
    if ~assert_hard_link_refused(repoRoot, kind)
        skipped = skipped + 1;
    end
end
end

function case_changed_governed_files(repoRoot)
fixture = interrupted_fixture(repoRoot);
cleanup = onCleanup(@() cleanup_fixture(fixture));
append_byte(fixture.source_files{2});
changedSourceHash = sha256_file(fixture.source_files{2});
assert_rejected(@() run_sanitisation_transaction(fixture.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfolder(fixture.workspace) && ~isfile(fixture.registry));
assert(strcmp(sha256_file(fixture.source_files{2}), changedSourceHash));

fixture2 = interrupted_fixture(repoRoot);
cleanup2 = onCleanup(@() cleanup_fixture(fixture2));
append_byte(fixture2.active_files{2});
changedActiveHash = sha256_file(fixture2.active_files{2});
assert_rejected(@() run_sanitisation_transaction(fixture2.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfolder(fixture2.workspace) && ~isfile(fixture2.registry));
assert(strcmp(sha256_file(fixture2.active_files{2}), changedActiveHash));

for kind = ["preliminary", "excluded", "empty_directory"]
    drift = interrupted_full_tree_fixture(repoRoot);
    driftCleanup = onCleanup(@() cleanup_fixture(drift));
    if kind == "preliminary"
        changedPath = drift.preliminary;
        append_byte(changedPath);
    elseif kind == "excluded"
        changedPath = drift.excluded_source;
        append_byte(changedPath);
    else
        changedPath = fullfile(drift.empty_source_dir, 'nested-empty');
        mkdir(changedPath);
    end
    if kind ~= "empty_directory"
        changedHash = sha256_file(changedPath);
    end
    assert_rejected(@() run_sanitisation_transaction(drift.root), ...
        'SIMPLE:Step2Sanitise:UnknownRecoveryState');
    assert(isfolder(drift.workspace) && ~isfile(drift.registry));
    if kind == "empty_directory"
        assert(isfolder(changedPath));
    else
        assert(strcmp(sha256_file(changedPath), changedHash));
    end
end


finderDrift = interrupted_full_tree_fixture(repoRoot);
finderCleanup = onCleanup(@() cleanup_fixture(finderDrift));
append_byte(finderDrift.ds_store);
nestedMetadata = fullfile(fileparts(finderDrift.source_files{1}), '.DS_Store');
write_text(nestedMetadata, 'finder metadata added after interruption');
dsStoreHash = sha256_file(finderDrift.ds_store);
nestedHash = sha256_file(nestedMetadata);
outcome = run_sanitisation_transaction(finderDrift.root);
assert(strcmp(outcome.status, 'recovered') && outcome.recovered);
assert_original_state(finderDrift);
assert(strcmp(sha256_file(finderDrift.ds_store), dsStoreHash));
assert(strcmp(sha256_file(nestedMetadata), nestedHash));

noOpDrift = create_mapped_fixture(repoRoot, false, 'top-level-fields', 1);
noOpCleanup = onCleanup(@() cleanup_fixture(noOpDrift));
activate_fixture_functions(noOpDrift);
outcome = run_sanitisation_transaction(noOpDrift.root, ...
    struct('available_bytes_override', 2^50));
assert(strcmp(outcome.status, 'completed'));
activeHash = sha256_file(noOpDrift.active);
registryHash = sha256_file(noOpDrift.registry);
opts = detectImportOptions(noOpDrift.preliminary, ...
    'FileType', 'spreadsheet');
opts = setvartype(opts, opts.VariableNames, 'string');
preliminary = readtable(noOpDrift.preliminary, opts);
preliminary.subjectID(1) = "ChangedPrivate";
writetable(preliminary, noOpDrift.preliminary, 'FileType', 'spreadsheet');
preliminaryHash = sha256_file(noOpDrift.preliminary);
assert_rejected(@() run_sanitisation_transaction(noOpDrift.root), ...
    'SIMPLE:Step2Sanitise:MixedOrDamagedState');
assert(strcmp(sha256_file(noOpDrift.preliminary), preliminaryHash));
assert(strcmp(sha256_file(noOpDrift.registry), registryHash));
assert(strcmp(sha256_file(noOpDrift.active), activeHash));
assert(strcmp(sha256_file(noOpDrift.source), noOpDrift.source_hash));
assert(~isfolder(noOpDrift.workspace));
end

function fixture = interrupted_fixture(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 2);
activate_fixture_functions(fixture);
assert_rejected(@() run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50, ...
    'after_promotion', @throw_interruption)), ...
    'SIMPLE:Step2Sanitise:SimulatedInterruption');
end

function fixture = interrupted_full_tree_fixture(repoRoot)
fixture = create_mapped_fixture(repoRoot, false, 'top-level-fields', 2);
rawOrig = fullfile(fixture.root, 'data', 'raw_orig');
fixture.ds_store = fullfile(rawOrig, '.DS_Store');
write_text(fixture.ds_store, 'finder metadata');
fixture.empty_source_dir = fullfile(rawOrig, 'empty-directory');
mkdir(fixture.empty_source_dir);
excludedPath = "data/raw/sub-ExcludedTree/ses-visitExcluded/eeg";
excludedFile = "sub-ExcludedTree_ses-visitExcluded_run-runExcluded_eeg.set";
append_excluded_subject(fixture.preliminary, 'ExcludedTree', ...
    excludedPath, excludedFile);
excludedOrigPath = replace(excludedPath, "data/raw/", "data/raw_orig/");
excludedDirectory = registry_directory(fixture.root, excludedOrigPath);
mkdir(excludedDirectory);
fixture.excluded_source = fullfile(excludedDirectory, char(excludedFile));
copyfile(fixture.source, fixture.excluded_source, 'f');
activate_fixture_functions(fixture);
assert_rejected(@() run_sanitisation_transaction(fixture.root, ...
    struct('available_bytes_override', 2^50, ...
    'after_promotion', @throw_interruption)), ...
    'SIMPLE:Step2Sanitise:SimulatedInterruption');
end

function manifest = fixture_manifest(fixture)
activate_fixture_functions(fixture);
identity = load_dataset_identity_registry(fixture.registry);
original = original_view(identity);
snapshot = inspect_pseudonymisation_inputs(fixture.root, original, ...
    fullfile(fixture.root, 'data', 'raw_orig'));
manifest = struct('schema', 'simple-step2-sanitisation-v2', ...
    'operation', 'step_2_raw_11', ...
    'registry_hash', sha256_file(fixture.registry), ...
    'preliminary_hash', char(snapshot.preliminary_hash), ...
    'raw_tree_hash', char(snapshot.raw_tree_hash), ...
    'row_count', identity.recording_count, ...
    'source_hashes', {cellstr(snapshot.source_hashes)});
end

function original = original_view(identity)
T = identity.table;
original = table(T.subjectID_orig, T.sessionID_orig, T.runID_orig, ...
    "data/raw/" + extractAfter(T.path_raw_orig, ...
    strlength("data/raw_orig/")), T.EEGfile_raw_orig, ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'});
end

function available = assert_hard_link_refused(repoRoot, kind)
if kind == "pending"
    fixture = create_mapped_fixture(repoRoot, false, ...
        'top-level-fields', 2);
    cleanup = onCleanup(@() cleanup_fixture(fixture));
    activate_fixture_functions(fixture);
    mkdir(fixture.workspace);
    manifest = fixture_manifest(fixture);
    slot = fullfile(fixture.workspace, 'manifest.pending.mat');
    save(slot, '-v6', '-mat', 'manifest');
else
    fixture = interrupted_fixture(repoRoot);
    cleanup = onCleanup(@() cleanup_fixture(fixture));
    if kind == "manifest"
        slot = fullfile(fixture.workspace, 'manifest.mat');
    elseif kind == "locked"
        slot = fullfile(fixture.workspace, 'dataset_list.locked.csv');
    elseif kind == "candidate"
        slot = fullfile(fixture.workspace, 'candidate.set');
        copyfile(fixture.source_files{2}, slot, 'f');
    elseif kind == "source"
        slot = fixture.source_files{2};
    else
        slot = fixture.active_files{2};
    end
end
alias = fullfile(fixture.root, char("outside-" + kind + ".bin"));
available = create_test_link(slot, alias, 'hard');
if ~available
    return
end
slotHash = sha256_file(slot);
aliasHash = sha256_file(alias);
assert(same_file(slot, alias));
assert_rejected(@() run_sanitisation_transaction(fixture.root), ...
    'SIMPLE:Step2Sanitise:UnknownRecoveryState');
assert(isfolder(fixture.workspace));
assert(strcmp(sha256_file(slot), slotHash));
assert(strcmp(sha256_file(alias), aliasHash));
assert(same_file(slot, alias));
if kind == "pending"
    assert(isfile(fixture.registry));
else
    assert(~isfile(fixture.registry));
end
end

function fixture = create_mapped_fixture(repoRoot, epoched, layout, rowCount)
fixture = create_skeleton(repoRoot);
original = original_registry(rowCount);
activate_fixture_functions(fixture);
mapped = build_pseudonymised_dataset_registry(original);
writetable(mapped, fixture.registry, 'QuoteStrings', true);
write_preliminary(fixture.preliminary, original);
fixture.source_files = cell(rowCount, 1);
fixture.active_files = cell(rowCount, 1);
fixture.source_hashes = cell(rowCount, 1);
for row = 1:rowCount
    sourceDir = registry_directory(fixture.root, mapped.path_raw_orig(row));
    activeDir = registry_directory(fixture.root, mapped.path_raw(row));
    if ~isfolder(sourceDir), mkdir(sourceDir); end
    if ~isfolder(activeDir), mkdir(activeDir); end
    fixture.source_files{row} = fullfile(sourceDir, ...
        char(mapped.EEGfile_raw_orig(row)));
    fixture.active_files{row} = fullfile(activeDir, ...
        char(mapped.EEGfile_raw(row)));
    EEG = make_eeg(epoched);
    EEG.filename = char(mapped.EEGfile_raw_orig(row));
    EEG.subject = char(original.subjectID(row));
    EEG.session = char(original.sessionID(row));
    EEG.run = char(original.runID(row));
    EEG.comments = sprintf('source note row %d', row);
    EEG.history = sprintf('source history row %d', row);
    save_fixture_set(fixture.source_files{row}, EEG, layout, '-v6');
    copyfile(fixture.source_files{row}, fixture.active_files{row});
    fixture.source_hashes{row} = sha256_file(fixture.source_files{row});
end
fixture.source = fixture.source_files{1};
fixture.active = fixture.active_files{1};
fixture.source_hash = fixture.source_hashes{1};
end

function fixture = create_original_fixture(repoRoot)
fixture = create_skeleton(repoRoot);
original = original_registry(1);
writetable(original, fixture.registry, 'QuoteStrings', true);
write_preliminary(fixture.preliminary, original);
directory = registry_directory(fixture.root, original.path_raw(1));
mkdir(directory);
fixture.active = fullfile(directory, char(original.EEGfile_raw(1)));
save_fixture_set(fixture.active, make_eeg(false), 'top-level-fields', '-v6');
fixture.source_files = {};
fixture.active_files = {fixture.active};
fixture.source_hashes = {};
end

function fixture = create_skeleton(repoRoot)
fixture.root = tempname;
mkdir(fixture.root);
mkdir(fullfile(fixture.root, 'functions'));
copyfile(fullfile(repoRoot, 'functions', 'private'), ...
    fullfile(fixture.root, 'functions', 'private'));
mkdir(fullfile(fixture.root, 'data'));
mkdir(fullfile(fixture.root, 'data', 'raw'));
mkdir(fullfile(fixture.root, 'data_lists'));
fixture.registry = fullfile(fixture.root, 'data_lists', 'dataset_list.csv');
fixture.preliminary = fullfile(fixture.root, 'data_lists', ...
    'dataset_list_prelim.xlsx');
fixture.workspace = fullfile(fixture.root, 'data', ...
    '.step_2_raw_11_transaction');
names = {'build_pseudonymised_dataset_registry.m', ...
    'inspect_identity_state.m', 'inspect_pseudonymisation_inputs.m', ...
    'load_dataset_identity_registry.m', ...
    'run_sanitisation_transaction.m', 'sanitise_eeglab_dataset.m', ...
    'validate_dataset_registry_paths.m', ...
    'verify_sanitised_eeglab_dataset.m'};
for index = 1:numel(names)
    copyfile(fullfile(repoRoot, 'functions', names{index}), ...
        fullfile(fixture.root, 'functions', names{index}));
end
end

function activate_fixture_functions(fixture)
addpath(fullfile(fixture.root, 'functions'), '-begin');
clear build_pseudonymised_dataset_registry inspect_identity_state ...
    inspect_pseudonymisation_inputs load_dataset_identity_registry ...
    run_sanitisation_transaction ...
    sanitise_eeglab_dataset validate_dataset_registry_paths ...
    verify_sanitised_eeglab_dataset
rehash path
end

function original = original_registry(rowCount)
subjectID = "Orig" + string(char(('A':'Z').'));
subjectID = subjectID(1:rowCount);
sessionID = "visit" + string((1:rowCount).');
runID = "run" + string((1:rowCount).');
pathRaw = "data/raw/sub-" + subjectID + "/ses-" + sessionID + "/eeg";
filename = "sub-" + subjectID + "_ses-" + sessionID + ...
    "_run-" + runID + "_eeg.set";
original = table(subjectID, sessionID, runID, pathRaw, filename, ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'});
end

function write_preliminary(pathValue, original)
rows = height(original);
T = table(original.subjectID, original.sessionID, original.runID, ...
    original.path_raw, original.EEGfile_raw, strings(rows, 1), ...
    strings(rows, 1), repmat("included", rows, 1), ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_reformatted', 'EEGfile_reformatted', 'excluded_datasets', ...
    'channel_exclusion', 'included_datasets'});
writetable(T, pathValue, 'FileType', 'spreadsheet');
end

function append_excluded_subject( ...
        pathValue, subjectID, pathRaw, filename, sessionID, runID)
if nargin < 3
    pathRaw = "";
    filename = "";
end
if nargin < 5
    sessionID = "visitExcluded";
    runID = "runExcluded";
end
opts = detectImportOptions(pathValue, 'FileType', 'spreadsheet');
opts = setvartype(opts, opts.VariableNames, 'string');
T = readtable(pathValue, opts);
excluded = table(string(subjectID), string(sessionID), string(runID), ...
    string(pathRaw), string(filename), "excluded", "", "", ...
    'VariableNames', T.Properties.VariableNames);
T = [T; excluded];
writetable(T, pathValue, 'FileType', 'spreadsheet');
end

function add_source_reference_columns(pathValue)
opts = detectImportOptions(pathValue, 'FileType', 'spreadsheet');
opts = setvartype(opts, opts.VariableNames, 'string');
T = readtable(pathValue, opts);
assert(height(T) == 3);
T.original_source_file = ["OrigAPrivate.dat"; ...
    "LegacyPrivateB.cdt.dpa"; "ExcludedSourceOnly.001"];
T.original_source_path = ["/archive/OrigAContainer"; ...
    "/archive/LegacyPrivateContainerB"; ...
    "/archive/ExcludedSourceContainer"];
T.scientific_annotation = ["Cz/Fz"; "mg/kg"; "Stimulus/S  1"];
T.scientific_code = ["alpha.beta"; "pain/control"; "left/right"];
T.numeric_source_filename = ["5.set"; "6.set"; "7.set"];
T.originalSourceFile = ["CamelPrivateA.001"; ...
    "CamelPrivateB.002"; "CamelPrivateExcluded.003"];
T.EEGSourcePath = ["/camel/CamelPathA"; ...
    "/camel/01/CamelPathB"; "/camel/8.001"];
T.source_reference = ["/external/LoosePrivateA"; ...
    "~/external/LoosePrivateB"; "../external/LoosePrivateC"];
T.source_file_placeholder = ["none"; "not applicable"; "unknown"];
T.root_mean_square = [1; 2; 3];
writetable(T, pathValue, 'FileType', 'spreadsheet');
end

function directory = registry_directory(root, relative)
parts = cellstr(split(relative, '/'));
directory = fullfile(root, parts{:});
end

function EEG = make_eeg(epoched)
EEG = eeg_emptyset;
EEG.setname = 'OrigA recording';
EEG.filename = 'sub-OrigA_ses-visitA_run-runA_eeg.set';
EEG.filepath = '/private/source/OrigA';
EEG.subject = 'OrigA';
EEG.session = 'visitA';
EEG.run = 'runA';
EEG.group = 'control';
EEG.condition = 'pain';
EEG.comments = 'OrigA source note';
EEG.history = 'loaded from /private/source/OrigA';
EEG.nbchan = 2;
EEG.pnts = 10;
EEG.srate = 100;
EEG.xmin = -0.02;
EEG.xmax = EEG.xmin + (EEG.pnts - 1) / EEG.srate;
EEG.times = linspace(EEG.xmin * 1000, EEG.xmax * 1000, EEG.pnts);
EEG.chanlocs = struct('labels', {'Cz', 'Fz'}, ...
    'type', {'EEG', 'EEG'}, 'X', {0, 1}, 'Y', {1, 0}, 'Z', {1, 1});
if epoched
    EEG.trials = 2;
    EEG.data = reshape(single(1:40), 2, 10, 2);
    EEG.event = struct('type', {'stim', 'stim'}, 'latency', {5, 15}, ...
        'duration', {0, 0}, 'epoch', {1, 2}, 'urevent', {1, 2}, ...
        'code', {'S 1', 'S 1'}, 'bvmknum', {1, 2});
else
    EEG.trials = 1;
    EEG.data = reshape(single(1:20), 2, 10);
    EEG.event = struct('type', 'stim', 'latency', 5, 'duration', 0, ...
        'urevent', 1, 'code', 'S 1', 'bvmknum', 1);
end
EEG = eeg_checkset(EEG, 'eventconsistency');
EEG = eeg_checkset(EEG);
for index = 1:numel(EEG.event)
    EEG.event(index).bvtime = sprintf('private-time-%d', index);
end
for index = 1:numel(EEG.urevent)
    EEG.urevent(index).bvtime = sprintf('private-time-%d', index);
end
eventFields = fieldnames(EEG.event);
eventFields(strcmp(eventFields, 'bvtime')) = [];
eventFields = [eventFields(1:3); {'bvtime'}; eventFields(4:end)];
EEG.event = orderfields(EEG.event, eventFields);
EEG.eventdescription = cellfun(@(name) ['description-' name], ...
    reshape(eventFields, 1, []), 'UniformOutput', false);
if epoched
    for index = 1:numel(EEG.epoch)
        EEG.epoch(index).eventbvtime = {sprintf('private-time-%d', index)};
    end
    epochFields = fieldnames(EEG.epoch);
    epochFields(strcmp(epochFields, 'eventbvtime')) = [];
    epochFields = [epochFields(1); {'eventbvtime'}; epochFields(2:end)];
    EEG.epoch = orderfields(EEG.epoch, epochFields);
    EEG.epochdescription = cellfun(@(name) ['description-' name], ...
        reshape(epochFields, 1, []), 'UniformOutput', false);
end
end

function save_fixture_set(pathValue, EEG, layout, versionFlag)
if strcmp(layout, 'top-level-fields')
    save(pathValue, versionFlag, '-mat', '-struct', 'EEG');
else
    save(pathValue, versionFlag, '-mat', 'EEG');
end
end

function expected = expected_identity()
expected = struct('subjectID', '001', 'sessionID', '01', 'runID', '01', ...
    'EEGfile_raw', 'sub-001_ses-01_run-01_eeg.set');
end

function privacy = privacy_context()
privacy = struct('row_number', 1, 'original_subject_id', 'OrigA', ...
    'original_session_id', 'visitA', 'original_run_id', 'runA', ...
    'original_filename', 'sub-OrigA_ses-visitA_run-runA_eeg.set', ...
    'original_path', 'data/raw_orig/sub-OrigA/ses-visitA/eeg', ...
    'blocked_tokens', strings(0, 1));
end

function EEG = set_field(EEG, name, value)
EEG.(name) = value;
end

function EEG = set_etc_field(EEG, name, value)
EEG.etc.(name) = value;
end

function fixture = set_fixture_group(fixture, row, value)
EEG = load('-mat', fixture.source_files{row});
EEG.group = value;
save_fixture_set(fixture.source_files{row}, EEG, ...
    'top-level-fields', '-v6');
copyfile(fixture.source_files{row}, fixture.active_files{row}, 'f');
fixture.source_hashes{row} = sha256_file(fixture.source_files{row});
if row == 1
    fixture.source_hash = fixture.source_hashes{row};
end
end

function throw_caught_failure(row)
if row == 1
    error('SIMPLE:Test:CaughtFailure', 'Synthetic caught failure.');
end
end

function throw_interruption(row)
if row == 1
    error('SIMPLE:Step2Sanitise:SimulatedInterruption', ...
        'Synthetic hard interruption.');
end
end

function add_finder_metadata(row, pathValue)
if row == 1
    write_text(pathValue, 'finder mid-transaction metadata');
end
end

function create_pseudonymisation_conflict(workspace)
assert(mkdir(workspace));
write_text(fullfile(workspace, 'foreign.txt'), 'foreign');
error('SIMPLE:Test:CaughtFailure', 'Synthetic pre-manifest failure.');
end

function assert_original_state(fixture)
assert(isfile(fixture.registry) && ~isfolder(fixture.workspace));
assert_original_files(fixture);
end

function assert_original_files(fixture)
for row = 1:numel(fixture.source_files)
    assert(strcmp(sha256_file(fixture.source_files{row}), ...
        fixture.source_hashes{row}));
    assert(strcmp(sha256_file(fixture.active_files{row}), ...
        fixture.source_hashes{row}));
end
end

function failure = capture_failure(action)
try
    action();
catch failure
    return
end
error('SIMPLE:Test:ExpectedFailure', 'Expected the action to fail.');
end

function assert_rejected(action, identifier)
failure = capture_failure(action);
assert(strcmp(failure.identifier, identifier), ...
    'Expected %s, received %s.', identifier, failure.identifier);
end

function write_text(pathValue, value)
fid = fopen(pathValue, 'wt');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '%s', value);
end

function available = create_filesystem_object(pathValue, kind, target)
available = true;
if kind == "file"
    write_text(pathValue, 'occupied');
elseif kind == "symlink"
    available = create_test_link(target, pathValue);
else
    assert(system(sprintf('/usr/bin/mkfifo %s', ...
        shell_quote(pathValue))) == 0);
end
end

function append_byte(pathValue)
fid = fopen(pathValue, 'ab');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
fwrite(fid, uint8(0), 'uint8');
end

function quoted = shell_quote(value)
quoted = ['"' strrep(char(value), '"', '\"') '"'];
end

function tf = same_file(first, second)
tf = java.nio.file.Files.isSameFile(java.io.File(first).toPath(), ...
    java.io.File(second).toPath());
end

function cleanup_fixture(fixture)
functionsRoot = fullfile(fixture.root, 'functions');
if contains(path, functionsRoot)
    rmpath(functionsRoot);
end
if isfolder(fixture.root)
    rmdir(fixture.root, 's');
end
end

function digest = sha256_file(pathValue)
engine = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(pathValue, 'rb');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
while true
    [bytes, count] = fread(fid, 1024 * 1024, '*uint8');
    if count > 0
        engine.update(reshape(typecast(bytes(:), 'int8'), 1, []));
    end
    if count < 1024 * 1024
        break
    end
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end
