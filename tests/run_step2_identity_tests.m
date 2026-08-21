function result = run_step2_identity_tests(repoRoot)
%RUN_STEP2_IDENTITY_TESTS Exercise the compact Step 2.10 route.

arguments
    repoRoot (1,:) char
end

sourceRoot = fullfile(repoRoot, 'functions');
required = {'run_pseudonymisation_transaction.m', ...
    'inspect_pseudonymisation_inputs.m', ...
    'build_pseudonymised_dataset_registry.m'};
for index = 1:numel(required)
    assert(isfile(fullfile(sourceRoot, required{index})), ...
        'Missing Step 2.10 test source: %s', required{index});
end

originalPath = path;
pathCleanup = onCleanup(@() path(originalPath));
suiteRoot = tempname;
mkdir(suiteRoot);
suiteCleanup = onCleanup(@() remove_tree(suiteRoot));

caseNames = [ ...
    "mapping_hierarchy_width_and_numeric_rejection"; ...
    "loader_modes_partial_and_leading_zeros"; ...
    "inspector_core_states"; ...
    "inspector_workspace_states"; ...
    "transaction_success_inventory_exclusions_and_noop"; ...
    "transaction_immediate_input_and_namespace_guards"; ...
    "transaction_inventory_guards"; ...
    "transaction_link_special_and_external_guards"; ...
    "transaction_downstream_and_storage_guards"; ...
    "transaction_privacy_safe_diagnostics"; ...
    "transaction_caught_failure_rolls_back"; ...
    "transaction_four_move_interruptions_recover_then_stop"; ...
    "transaction_empty_and_pending_workspace_preserved"; ...
    "transaction_foreign_and_malformed_workspace_preserved"; ...
    "transaction_governed_drift_preserved"; ...
    "step29_empty_and_original_execution"; ...
    "step29_mapped_and_recoverable_no_overwrite"; ...
    "step29_numeric_xlsx_no_overwrite"];

test_mapping(suiteRoot, repoRoot, sourceRoot);
test_loader(suiteRoot, repoRoot, sourceRoot);
test_inspector_core(suiteRoot, repoRoot, sourceRoot);
test_inspector_workspaces(suiteRoot, repoRoot, sourceRoot);
test_success_and_noop(suiteRoot, repoRoot, sourceRoot);
test_input_guards(suiteRoot, repoRoot, sourceRoot);
test_inventory_guards(suiteRoot, repoRoot, sourceRoot);
test_filesystem_and_set_guards(suiteRoot, repoRoot, sourceRoot);
test_downstream_and_space(suiteRoot, repoRoot, sourceRoot);
test_private_diagnostics(suiteRoot, repoRoot, sourceRoot);
test_caught_rollback(suiteRoot, repoRoot, sourceRoot);
test_move_interruptions(suiteRoot, repoRoot, sourceRoot);
test_pre_manifest_workspaces(suiteRoot, repoRoot, sourceRoot);
test_unknown_workspaces(suiteRoot, repoRoot, sourceRoot);
test_governed_drift(suiteRoot, repoRoot, sourceRoot);
test_step29_empty_original(suiteRoot, repoRoot, sourceRoot);
test_step29_guards(suiteRoot, repoRoot, sourceRoot);
test_step29_numeric(suiteRoot, repoRoot, sourceRoot);

result = struct('schema', 'simple-step2-identity-tests-v2', ...
    'case_names', caseNames, 'total', numel(caseNames), 'passed', true);
fprintf('STEP 2 IDENTITY TESTS PASSED: %d\n', result.total);
end

function test_mapping(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "mapping", repoRoot, sourceRoot);
T = table(["A"; "B"; "A"; "A"; "B"], ...
    ["x"; "z"; "y"; "x"; "z"], ["r"; "q"; "r"; "s"; "p"], ...
    "data/raw/row-" + string((1:5).'), ...
    "row-" + string((1:5).') + ".set", string((11:15).'), ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw', 'later_column'});
mapped = build_pseudonymised_dataset_registry(T);
assert(isequal(mapped.subjectID, ["001"; "002"; "001"; "001"; "002"]));
assert(isequal(mapped.sessionID, ["01"; "01"; "02"; "01"; "01"]));
assert(isequal(mapped.runID, ["01"; "01"; "01"; "02"; "02"]));
assert(isequal(mapped.later_column, T.later_column));
assert(isequal(mapped.Properties.VariableNames(1:10), mapped_core()));

count = 1000;
wide = table("source-" + string((1:count).'), repmat("s", count, 1), ...
    repmat("r", count, 1), "data/raw/p-" + string((1:count).'), ...
    "p-" + string((1:count).') + ".set", 'VariableNames', original_core());
wideMapped = build_pseudonymised_dataset_registry(wide);
assert(isequal(wideMapped.subjectID([1 10 100 1000]), ...
    ["001"; "010"; "100"; "1000"]));
wide = wide(1:100, :);
wide.subjectID(:) = "one";
wide.sessionID = "s-" + string((1:100).');
wide.runID(:) = "run";
wideMapped = build_pseudonymised_dataset_registry(wide);
assert(wideMapped.sessionID(1) == "01" && wideMapped.sessionID(100) == "100");
wide.sessionID(:) = "session";
wide.runID = "r-" + string((1:100).');
wideMapped = build_pseudonymised_dataset_registry(wide);
assert(wideMapped.runID(1) == "01" && wideMapped.runID(100) == "100");

invalid = T(:, original_core());
invalid.subjectID = (1:height(invalid)).';
assert_rejected(@() build_pseudonymised_dataset_registry(invalid), ...
    'SIMPLE:Step2Identity:InvalidTextColumn');
invalid = T([1 1], original_core());
assert_rejected(@() build_pseudonymised_dataset_registry(invalid), ...
    'SIMPLE:Step2Identity:DuplicateOriginalTuple');
assert_sentinels(fixture);
end

function test_loader(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "loader", repoRoot, sourceRoot);
identity = load_dataset_identity_registry(fixture.registry);
assert(identity.mode == "original" && identity.recording_count == 2);
assert(isequal(identity.table.sessionID, ["01"; "02"]));
assert(isequal(identity.table.runID, ["01"; "01"]));
assert(isequal(identity.canonical_subject_ids, ["OxA"; "OxB"]));
assert(isequal(identity.participant_map.Properties.VariableNames, ...
    {'sourceSubjectID', 'subjectID'}));
mapped = build_pseudonymised_dataset_registry(identity.table);
writetable(mapped, fixture.registry);
identity = load_dataset_identity_registry(fixture.registry);
assert(identity.mode == "mapped" && isequal(identity.table.subjectID, ...
    ["001"; "002"]));
assert(isequal(identity.original_subject_ids, ["OxA"; "OxB"]));
assert(isequal(identity.participant_map.subjectID, ["001"; "002"]));
assert(isequal(size(identity.targets.raw_files), [2 1]));

tampered = identity.table;
tampered.subjectID(1) = "1";
writetable(tampered, fixture.registry);
assert_rejected(@() load_dataset_identity_registry(fixture.registry), ...
    'SIMPLE:Step2Identity:InvalidMapping');
fixture = make_fixture(suiteRoot, "loader_partial", repoRoot, sourceRoot);
mapped = build_pseudonymised_dataset_registry( ...
    load_dataset_identity_registry(fixture.registry).table);
writetable(removevars(mapped, 'path_raw_orig'), fixture.registry);
assert_rejected(@() load_dataset_identity_registry(fixture.registry), ...
    'SIMPLE:Step2Identity:PartialMappedSchema');
end

function test_inspector_core(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "state_empty", repoRoot, sourceRoot);
delete(fixture.registry);
assert(inspect_identity_state(fixture.root).name == "empty");
fixture = make_fixture(suiteRoot, "state_original", repoRoot, sourceRoot);
assert(inspect_identity_state(fixture.root).name == "original");
rmdir(fixture.raw, 's');
assert(inspect_identity_state(fixture.root).name == "partial");

fixture = make_mapped_fixture(suiteRoot, "state_mapped", repoRoot, sourceRoot);
assert(inspect_identity_state(fixture.root).name == "mapped_unsanitised");
identity = load_dataset_identity_registry(fixture.registry);
active = identity.targets.raw_files(1);
write_bytes(active, [read_bytes(active); uint8(7)]);
assert(inspect_identity_state(fixture.root).name == "mapped_modified");
end

function test_inspector_workspaces(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "state_workspace10", repoRoot, sourceRoot);
mkdir(fixture.workspace10);
write_bytes(fullfile(fixture.workspace10, 'manifest.pending.mat'), uint8('pending'));
assert(inspect_identity_state(fixture.root).name == "recoverable_step_2_10");
write_bytes(fullfile(fixture.workspace10, 'foreign.bin'), uint8('foreign'));
assert(inspect_identity_state(fixture.root).name == "unknown");

fixture = make_fixture(suiteRoot, "state_workspace11", repoRoot, sourceRoot);
mkdir(fixture.workspace11);
write_bytes(fullfile(fixture.workspace11, 'manifest.mat'), uint8('manifest'));
assert(inspect_identity_state(fixture.root).name == "recoverable_step_2_11");
end

function test_success_and_noop(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "success", repoRoot, sourceRoot);
sourceBytes = cellfun(@read_bytes, cellstr(fixture.all_files), ...
    'UniformOutput', false);
result = run_transaction(fixture, large_space());
assert(result.status == "completed" && result.state == "mapped_unsanitised");
assert(result.row_count == 2 && result.admitted_bytes > 0);
identity = load_dataset_identity_registry(fixture.registry);
assert(identity.mode == "mapped" && ...
    isequal(identity.table.Properties.VariableNames, mapped_core()));
assert(isfolder(fixture.raw_orig) && ~isfolder(fixture.workspace10));
for row = 1:identity.recording_count
    active = identity.targets.raw_files(row);
    source = target(fixture.root, identity.table.path_raw_orig(row), ...
        identity.table.EEGfile_raw_orig(row));
    assert(isequal(read_bytes(active), sourceBytes{row}));
    assert(isequal(read_bytes(source), sourceBytes{row}));
end
assert(isequal(read_bytes(target(fixture.root, ...
    "data/raw_orig/sub-Excluded/ses-01/eeg", ...
    "sub-Excluded_ses-01_run-01_eeg.set")), sourceBytes{3}));
assert(isfile(fullfile(fixture.raw_orig, '.DS_Store')));
assert(isfolder(fullfile(fixture.raw_orig, 'empty-directory')));
assert(isequal(sort(tree_files(fixture.raw)), sort(identity.targets.raw_files)));
assert_sentinels(fixture);
activeMetadata = fullfile(fixture.raw, '.DS_Store');
nestedMetadata = fullfile(fileparts(char(identity.targets.raw_files(1))), ...
    '.DS_Store');
write_bytes(activeMetadata, uint8('finder root metadata'));
write_bytes(nestedMetadata, uint8('finder nested metadata'));
noOp = run_transaction(fixture, large_space());
assert(noOp.status == "already_complete" && noOp.row_count == 2);
assert(isfile(activeMetadata) && isfile(nestedMetadata));

publishedFixture = make_fixture(suiteRoot, "finder_after_publish", ...
    repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) add_finder_metadata( ...
    move, 3, publishedFixture.raw);
published = run_transaction(publishedFixture, options);
assert(published.status == "completed");
assert(isfile(fullfile(publishedFixture.raw, '.DS_Store')));

foreignDirectory = fullfile(fixture.raw, 'foreign-empty-directory');
mkdir(foreignDirectory);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:MappedFilesChanged');
assert(isfolder(foreignDirectory));
end

function test_input_guards(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "later_column", repoRoot, sourceRoot);
T = load_dataset_identity_registry(fixture.registry).table;
T.path_processed = "data/processed/row-" + string((1:height(T)).');
writetable(T, fixture.registry);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:NotImmediatePostStep29');

fixture = make_fixture(suiteRoot, "preliminary_mismatch", repoRoot, sourceRoot);
T = load_dataset_identity_registry(fixture.registry).table;
T.subjectID(1) = "Changed";
writetable(T, fixture.registry);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:PreliminaryMismatch');

fixture = make_fixture(suiteRoot, "namespace", repoRoot, sourceRoot, ...
    'ExcludedSubject', "001");
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:SubjectNamespaceOverlap');

fixture = make_fixture(suiteRoot, "unsorted_preliminary", ...
    repoRoot, sourceRoot, 'UnsortedPreliminary', true);
result = run_transaction(fixture, large_space());
identity = load_dataset_identity_registry(fixture.registry);
assert(result.status == "completed" && ...
    isequal(identity.table.subjectID_orig, ["OxA"; "OxB"]));

fixture = make_fixture(suiteRoot, "other_workspace", repoRoot, sourceRoot);
mkdir(fixture.workspace11);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:OtherTransactionActive');
end

function test_inventory_guards(suiteRoot, repoRoot, sourceRoot)
kinds = ["missing_admitted", "unknown_set", "unknown_file"];
identifiers = ["SIMPLE:Step2Identity:MissingAdmittedSet", ...
    "SIMPLE:Step2Identity:UnknownRawSet", ...
    "SIMPLE:Step2Identity:UnknownRawFile"];
for index = 1:numel(kinds)
    fixture = make_fixture(suiteRoot, "inventory_" + kinds(index), ...
        repoRoot, sourceRoot);
    switch kinds(index)
        case "missing_admitted"
            delete(fixture.all_files(1));
        case "unknown_set"
            copyfile(fixture.all_files(1), fullfile(fixture.raw, 'unknown.set'));
        case "unknown_file"
            write_bytes(fullfile(fixture.raw, 'unknown.bin'), uint8('foreign'));
    end
    assert_rejected(@() run_transaction(fixture, large_space()), ...
        char(identifiers(index)));
    assert(~isfolder(fixture.workspace10));
end

fixture = make_fixture(suiteRoot, "absent_excluded", repoRoot, sourceRoot);
delete(fixture.all_files(3));
result = run_transaction(fixture, large_space());
assert(result.status == "completed");
identity = load_dataset_identity_registry(fixture.registry);
excluded = target(fixture.root, "data/raw_orig/sub-Excluded/ses-01/eeg", ...
    "sub-Excluded_ses-01_run-01_eeg.set");
assert(~isfile(excluded) && numel(tree_files(fixture.raw)) == ...
    identity.recording_count);

fixture = make_fixture(suiteRoot, "case_collision", repoRoot, sourceRoot);
original = load_dataset_identity_registry(fixture.registry).table;
original.path_raw(2) = lower(original.path_raw(1));
original.EEGfile_raw(2) = lower(original.EEGfile_raw(1));
opts = detectImportOptions(fixture.preliminary, 'FileType', 'spreadsheet');
opts = setvartype(opts, opts.VariableNames, 'string');
P = readtable(fixture.preliminary, opts);
P.path_reformatted(2) = original.path_raw(2);
P.EEGfile_reformatted(2) = original.EEGfile_raw(2);
writetable(P, fixture.preliminary, 'FileType', 'spreadsheet');
assert_rejected(@() inspect_pseudonymisation_inputs( ...
    fixture.root, original, fixture.raw), ...
    'SIMPLE:Step2Identity:FilesystemTargetCollision');

invalidPaths = ["archive/sub-Excluded/ses-01/eeg"; ...
    "data/raw/sub-Excluded/../eeg"; ...
    "data\raw\sub-Excluded\ses-01\eeg"; ...
    "data/raw/sub-Excluded/ses-01/eeg"; ...
    "data/raw/sub-Excluded/ses-01/eeg"; ...
    ""; ...
    "data/raw/sub-Excluded/ses-01/eeg"];
invalidFiles = ["sub-Excluded_ses-01_run-01_eeg.set"; ...
    "sub-Excluded_ses-01_run-01_eeg.set"; ...
    "sub-Excluded_ses-01_run-01_eeg.set"; ...
    "nested/unsafe.set"; ...
    "sub-Excluded_ses-01_run-01_eeg.mat"; ...
    "sub-Excluded_ses-01_run-01_eeg.set"; ...
    ""];
for index = 1:numel(invalidPaths)
    fixture = make_fixture(suiteRoot, "invalid_excluded_" + index, ...
        repoRoot, sourceRoot);
    opts = detectImportOptions(fixture.preliminary, ...
        'FileType', 'spreadsheet');
    opts = setvartype(opts, opts.VariableNames, 'string');
    P = readtable(fixture.preliminary, opts);
    P.path_reformatted(3) = invalidPaths(index);
    P.EEGfile_reformatted(3) = invalidFiles(index);
    writetable(P, fixture.preliminary, 'FileType', 'spreadsheet');
    assert_rejected(@() run_transaction(fixture, large_space()), ...
        'SIMPLE:Step2Identity:InvalidExcludedTarget');
    assert(~isfolder(fixture.workspace10));
end

fixture = make_fixture(suiteRoot, "excluded_collision", ...
    repoRoot, sourceRoot);
opts = detectImportOptions(fixture.preliminary, 'FileType', 'spreadsheet');
opts = setvartype(opts, opts.VariableNames, 'string');
P = readtable(fixture.preliminary, opts);
P.path_reformatted(3) = P.path_reformatted(1);
P.EEGfile_reformatted(3) = P.EEGfile_reformatted(1);
writetable(P, fixture.preliminary, 'FileType', 'spreadsheet');
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:FilesystemTargetCollision');
assert(~isfolder(fixture.workspace10));
end

function test_filesystem_and_set_guards(suiteRoot, repoRoot, sourceRoot)
kinds = ["symlink", "hardlink", "special", "external", "missing_data"];
identifiers = ["SIMPLE:Step2Identity:UnsafeRawInventory", ...
    "SIMPLE:Step2Identity:UnsafeHardLink", ...
    "SIMPLE:Step2Identity:UnsafeRawInventory", ...
    "SIMPLE:Step2Identity:ExternalDataDependency", ...
    "SIMPLE:Step2Identity:MissingEmbeddedData"];
for index = 1:numel(kinds)
    fixture = make_fixture(suiteRoot, "unsafe_" + kinds(index), ...
        repoRoot, sourceRoot);
    switch kinds(index)
        case "symlink"
            link = fullfile(fixture.raw, 'linked.set');
            assert(system(sprintf('/bin/ln -s %s %s', ...
                shell_quote(fixture.all_files(1)), shell_quote(link))) == 0);
        case "hardlink"
            link = fullfile(fixture.root, 'outside-hardlink.set');
            assert(system(sprintf('/bin/ln %s %s', ...
                shell_quote(fixture.all_files(1)), shell_quote(link))) == 0);
        case "special"
            fifo = fullfile(fixture.raw, 'unexpected.fifo');
            assert(system(sprintf('/usr/bin/mkfifo %s', shell_quote(fifo))) == 0);
        case "external"
            EEG = struct('data', 'recording.fdt', ...
                'datfile', 'recording.fdt');
            save(char(fixture.all_files(1)), 'EEG', '-mat');
        case "missing_data"
            EEG = struct('data', [], 'datfile', '');
            save(char(fixture.all_files(1)), 'EEG', '-mat');
    end
    assert_rejected(@() run_transaction(fixture, large_space()), ...
        char(identifiers(index)));
end
end

function test_downstream_and_space(suiteRoot, repoRoot, sourceRoot)
roots = ["info", "processed", "summary", "results", "jasp"];
for index = 1:numel(roots)
    fixture = make_fixture(suiteRoot, "downstream_" + roots(index), ...
        repoRoot, sourceRoot);
    folder = fullfile(fixture.root, 'data', char(roots(index)));
    mkdir(folder);
    write_bytes(fullfile(folder, 'material.bin'), uint8('later'));
    assert_rejected(@() run_transaction(fixture, large_space()), ...
        'SIMPLE:Step2Identity:DownstreamStateExists');
end
fixture = make_fixture(suiteRoot, "downstream_log", repoRoot, sourceRoot);
mkdir(fullfile(fixture.root, 'data', 'logs'));
write_bytes(fullfile(fixture.root, 'data', 'logs', 'step_3_test.log'), ...
    uint8('later'));
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:DownstreamStateExists');
fixture = make_fixture(suiteRoot, "downstream_file_slot", repoRoot, sourceRoot);
write_bytes(fullfile(fixture.root, 'data', 'results'), uint8('later'));
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:DownstreamStateExists');
fixture = make_fixture(suiteRoot, "storage", repoRoot, sourceRoot);
assert_rejected(@() run_transaction(fixture, struct('usable_bytes', 0)), ...
    'SIMPLE:Step2Identity:InsufficientSpace');
assert(~isfolder(fixture.workspace10));
end

function test_private_diagnostics(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "private_diagnostic", repoRoot, sourceRoot);
write_bytes(fullfile(fixture.raw, 'OxA-private-original-name.txt'), ...
    uint8('private'));
[identifier, diagnostic] = capture_rejection(@() ...
    run_transaction(fixture, large_space()));
assert(identifier == "SIMPLE:Step2Identity:UnknownRawFile");
blocked = ["OxA", "Excluded", string(fixture.root), string(getenv('USER'))];
blocked = blocked(blocked ~= "");
assert(~any(contains(diagnostic, blocked)));
end

function test_caught_rollback(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "caught_rollback", repoRoot, sourceRoot);
registryBytes = read_bytes(fixture.registry);
setBytes = cellfun(@read_bytes, cellstr(fixture.all_files), ...
    'UniformOutput', false);
options = large_space();
options.after_move = @(move) throw_on_move(move, 2, ...
    'SIMPLE:Step2Identity:InjectedFailure');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:InjectedFailure');
assert_original(fixture, registryBytes, setBytes);
end

function test_move_interruptions(suiteRoot, repoRoot, sourceRoot)
for move = 1:4
    fixture = make_fixture(suiteRoot, "interruption_" + move, ...
        repoRoot, sourceRoot);
    registryBytes = read_bytes(fixture.registry);
    setBytes = cellfun(@read_bytes, cellstr(fixture.all_files), ...
        'UniformOutput', false);
    options = large_space();
    options.after_move = @(actual) throw_on_move(actual, move, ...
        'SIMPLE:Step2Identity:SimulatedInterruption');
    assert_rejected(@() run_transaction(fixture, options), ...
        'SIMPLE:Step2Identity:SimulatedInterruption');
    if move >= 3
        write_bytes(fullfile(fixture.raw, '.DS_Store'), ...
            uint8('finder recovery metadata'));
    end
    assert(inspect_identity_state(fixture.root).name == ...
        "recoverable_step_2_10");
    if move == 1
        loaded = load('-mat', fullfile(fixture.workspace10, 'manifest.mat'));
        assert(isequal(fieldnames(loaded.manifest), {'schema'; 'operation'; ...
            'registry_hash'; 'preliminary_hash'; 'row_count'; 'source_hashes'}));
        printed = string(evalc('disp(loaded.manifest)'));
        assert(~contains(printed, "OxA") && ~contains(printed, fixture.root));
    end
    recovered = run_transaction(fixture, large_space());
    assert(recovered.status == "recovered_stop");
    assert_original(fixture, registryBytes, setBytes);
end
end

function test_pre_manifest_workspaces(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "empty_workspace", repoRoot, sourceRoot);
mkdir(fixture.workspace10);
assert(inspect_identity_state(fixture.root).name == "unknown");
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isfolder(fixture.workspace10) && ...
    isempty(directory_entries(fixture.workspace10)));

fixture = make_fixture(suiteRoot, "pending_workspace", repoRoot, sourceRoot);
mkdir(fixture.workspace10);
pending = fullfile(fixture.workspace10, 'manifest.pending.mat');
bytes = uint8('incomplete manifest');
write_bytes(pending, bytes);
assert(inspect_identity_state(fixture.root).name == "recoverable_step_2_10");
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isequal(read_bytes(pending), bytes(:)));
end

function test_unknown_workspaces(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "foreign_workspace", repoRoot, sourceRoot);
mkdir(fixture.workspace10);
foreign = fullfile(fixture.workspace10, 'foreign.bin');
write_bytes(foreign, uint8('foreign'));
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isfile(foreign));

fixture = make_fixture(suiteRoot, "malformed_manifest", repoRoot, sourceRoot);
mkdir(fixture.workspace10);
manifest = fullfile(fixture.workspace10, 'manifest.mat');
write_bytes(manifest, uint8('not a MAT file'));
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isfile(manifest));

fixture = make_fixture(suiteRoot, "foreign_candidate_dir", repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) throw_on_move(move, 1, ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
foreignDir = fullfile(fixture.workspace10, 'raw_candidate', 'foreign-empty');
mkdir(foreignDir);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isfolder(foreignDir));

fixture = make_fixture(suiteRoot, "finder_candidate_file", ...
    repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) throw_on_move(move, 1, ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
finderFile = fullfile(fixture.workspace10, 'raw_candidate', '.DS_Store');
write_bytes(finderFile, uint8('foreign candidate metadata'));
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isfile(finderFile));

fixture = make_fixture(suiteRoot, "wrong_locked_registry", ...
    repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) throw_on_move(move, 1, ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
locked = fullfile(fixture.workspace10, 'dataset_list.locked.csv');
assert(copyfile(locked, fixture.registry));
write_bytes(locked, [read_bytes(locked); uint8(91)]);
manifest = fullfile(fixture.workspace10, 'manifest.mat');
candidateRegistry = fullfile(fixture.workspace10, ...
    'dataset_list.candidate.csv');
candidateTree = fullfile(fixture.workspace10, 'raw_candidate');
governedPaths = [string(fixture.registry); string(locked); ...
    string(manifest); string(candidateRegistry); tree_files(candidateTree)];
governedBytes = cellfun(@read_bytes, cellstr(governedPaths), ...
    'UniformOutput', false);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
for index = 1:numel(governedPaths)
    assert(isequal(read_bytes(governedPaths(index)), governedBytes{index}));
end
end

function test_governed_drift(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "governed_drift", repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) throw_on_move(move, 2, ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
source = fixture.all_files(1);
source = replace(source, string(filesep) + "raw" + string(filesep), ...
    string(filesep) + "raw_orig" + string(filesep));
write_bytes(source, [read_bytes(source); uint8(19)]);
changed = read_bytes(source);
assert_rejected(@() run_transaction(fixture, large_space()), ...
    'SIMPLE:Step2Identity:RecoveryRefused');
assert(isequal(read_bytes(source), changed) && isfolder(fixture.workspace10));
end

function test_step29_empty_original(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "step29_empty", repoRoot, sourceRoot);
delete(fixture.registry);
run_step29(fixture, repoRoot);
assert(load_dataset_identity_registry(fixture.registry).mode == "original");
assert_log_calls(fixture, ["start"; "stop"]);

fixture = make_fixture(suiteRoot, "step29_original", repoRoot, sourceRoot);
run_step29(fixture, repoRoot);
identity = load_dataset_identity_registry(fixture.registry);
assert(identity.mode == "original" && isequal(identity.table.sessionID, ...
    ["01"; "02"]));
assert_log_calls(fixture, ["start"; "stop"]);
end

function test_step29_guards(suiteRoot, repoRoot, sourceRoot)
fixture = make_mapped_fixture(suiteRoot, "step29_mapped", repoRoot, sourceRoot);
registryBytes = read_bytes(fixture.registry);
preliminaryBytes = read_bytes(fixture.preliminary);
assert_rejected(@() run_step29(fixture, repoRoot), ...
    'SIMPLE:Step2Identity:Step29MappedState');
assert(isequal(read_bytes(fixture.registry), registryBytes));
assert(isequal(read_bytes(fixture.preliminary), preliminaryBytes));
assert_log_calls(fixture, "start");

fixture = make_fixture(suiteRoot, "step29_recoverable", repoRoot, sourceRoot);
options = large_space();
options.after_move = @(move) throw_on_move(move, 1, ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
assert_rejected(@() run_transaction(fixture, options), ...
    'SIMPLE:Step2Identity:SimulatedInterruption');
locked = fullfile(fixture.workspace10, 'dataset_list.locked.csv');
lockedBytes = read_bytes(locked);
preliminaryBytes = read_bytes(fixture.preliminary);
assert_rejected(@() run_step29(fixture, repoRoot), ...
    'SIMPLE:Step2Identity:Step29TransactionActive');
assert(~isfile(fixture.registry) && isequal(read_bytes(locked), lockedBytes));
assert(isequal(read_bytes(fixture.preliminary), preliminaryBytes));
assert_log_calls(fixture, "start");
end

function test_step29_numeric(suiteRoot, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, "step29_numeric", repoRoot, sourceRoot, ...
    'NumericPreliminary', true);
preliminaryBytes = read_bytes(fixture.preliminary);
registryBytes = read_bytes(fixture.registry);
assert_rejected(@() run_step29(fixture, repoRoot), ...
    'SIMPLE:Step2Identity:IdentityColumnsMustBeText');
assert(isequal(read_bytes(fixture.registry), registryBytes));
assert(isequal(read_bytes(fixture.preliminary), preliminaryBytes));
assert_log_calls(fixture, "start");
end

function fixture = make_mapped_fixture(suiteRoot, name, repoRoot, sourceRoot)
fixture = make_fixture(suiteRoot, name, repoRoot, sourceRoot);
result = run_transaction(fixture, large_space());
assert(result.status == "completed");
end

function fixture = make_fixture(suiteRoot, name, repoRoot, sourceRoot, options)
arguments
    suiteRoot (1,:) char
    name
    repoRoot (1,:) char
    sourceRoot (1,:) char
    options.ExcludedSubject = "Excluded"
    options.NumericPreliminary (1,1) logical = false
    options.UnsortedPreliminary (1,1) logical = false
end
root = fullfile(suiteRoot, char(name));
mkdir(root);
functionsRoot = fullfile(root, 'functions');
mkdir(functionsRoot);
mkdir(fullfile(root, 'data_lists'));
raw = fullfile(root, 'data', 'raw');
mkdir(raw);
copyfile(fullfile(sourceRoot, ...
    'run_pseudonymisation_transaction.m'), functionsRoot);
copyfile(fullfile(sourceRoot, 'inspect_pseudonymisation_inputs.m'), ...
    functionsRoot);
copyfile(fullfile(sourceRoot, 'build_pseudonymised_dataset_registry.m'), ...
    functionsRoot);
for file = {'load_dataset_identity_registry.m', 'inspect_identity_state.m', ...
        'validate_dataset_registry_paths.m'}
    copyfile(fullfile(repoRoot, 'functions', file{1}), functionsRoot);
end
activate_functions(functionsRoot);

subjectText = ["OxA"; "OxB"; string(options.ExcludedSubject)];
sessionText = ["01"; "02"; "01"];
runText = ["01"; "01"; "01"];
paths = "data/raw/sub-" + subjectText + "/ses-" + sessionText + "/eeg";
files = "sub-" + subjectText + "_ses-" + sessionText + ...
    "_run-" + runText + "_eeg.set";
excluded = [""; ""; "excluded"];
channel = [""; ""; ""];
included = ["included"; "included"; ""];
if options.NumericPreliminary
    subject = [1; 2; 3];
    session = [1; 2; 1];
    run = [1; 1; 1];
else
    subject = subjectText;
    session = sessionText;
    run = runText;
end
preliminary = table(subject, session, run, excluded, channel, files, paths, ...
    included, 'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'excluded_datasets', 'channel_exclusion', 'EEGfile_reformatted', ...
    'path_reformatted', 'included_datasets'});
if options.UnsortedPreliminary
    preliminary = preliminary([2 1 3], :);
end
preliminaryPath = fullfile(root, 'data_lists', 'dataset_list_prelim.xlsx');
writetable(preliminary, preliminaryPath, 'FileType', 'spreadsheet');
original = table(subjectText(1:2), sessionText(1:2), runText(1:2), ...
    paths(1:2), files(1:2), 'VariableNames', original_core());
registry = fullfile(root, 'data_lists', 'dataset_list.csv');
writetable(original, registry);

allFiles = strings(3, 1);
for row = 1:3
    filePath = target(root, paths(row), files(row));
    mkdir(fileparts(filePath));
    EEG = struct('data', single([row row + 0.5]), 'datfile', '', ...
        'subject', char(subjectText(row)));
    save(char(filePath), 'EEG', '-mat');
    allFiles(row) = string(filePath);
end
write_bytes(fullfile(raw, '.DS_Store'), uint8([1 2 3]));
mkdir(fullfile(raw, 'empty-directory'));
mkdir(fullfile(root, 'data', 'source'));
mkdir(fullfile(root, 'data', 'info_prelim'));
sentinels = [string(fullfile(root, 'outside-sentinel.bin')); ...
    string(fullfile(root, 'data', 'source', 'sentinel.bin')); ...
    string(fullfile(root, 'data', 'info_prelim', 'sentinel.bin'))];
for index = 1:numel(sentinels)
    write_bytes(sentinels(index), uint8([70 + index 80 + index]));
end
fixture = struct('root', root, 'functions', functionsRoot, ...
    'registry', registry, 'preliminary', preliminaryPath, 'raw', raw, ...
    'raw_orig', fullfile(root, 'data', 'raw_orig'), ...
    'workspace10', fullfile(root, 'data', '.step_2_raw_10_transaction'), ...
    'workspace11', fullfile(root, 'data', '.step_2_raw_11_transaction'), ...
    'all_files', allFiles, 'sentinels', sentinels, ...
    'sentinel_bytes', {cellfun(@read_bytes, cellstr(sentinels), ...
    'UniformOutput', false)});
end

function result = run_transaction(fixture, options)
activate_functions(fixture.functions);
result = run_pseudonymisation_transaction(fixture.root, options);
end

function activate_functions(functionsRoot)
addpath(functionsRoot, '-begin');
clear build_pseudonymised_dataset_registry inspect_identity_state ...
    inspect_pseudonymisation_inputs load_dataset_identity_registry ...
    run_pseudonymisation_transaction validate_dataset_registry_paths
rehash path
assert(canonical_equal(which('run_pseudonymisation_transaction'), ...
    fullfile(functionsRoot, 'run_pseudonymisation_transaction.m')));
end

function assert_original(fixture, registryBytes, setBytes)
assert(~isfolder(fixture.raw_orig) && ~isfolder(fixture.workspace10));
assert(isequal(read_bytes(fixture.registry), registryBytes));
assert(inspect_identity_state(fixture.root).name == "original");
for row = 1:numel(fixture.all_files)
    assert(isequal(read_bytes(fixture.all_files(row)), setBytes{row}));
end
assert_sentinels(fixture);
end

function assert_sentinels(fixture)
for index = 1:numel(fixture.sentinels)
    assert(isequal(read_bytes(fixture.sentinels(index)), ...
        fixture.sentinel_bytes{index}));
end
end

function options = large_space()
options = struct('usable_bytes', 2^50);
end

function throw_on_move(actual, targetMove, identifier)
if actual == targetMove
    error(identifier, 'Synthetic interruption after atomic move %d.', actual);
end
end

function add_finder_metadata(actual, targetMove, rawRoot)
if actual == targetMove
    write_bytes(fullfile(rawRoot, '.DS_Store'), ...
        uint8('finder publication metadata'));
end
end

function [identifier, diagnostic] = capture_rejection(operation)
try
    operation();
catch ME
    identifier = string(ME.identifier);
    diagnostic = string(getReport(ME, 'extended', 'hyperlinks', 'off'));
    return
end
error('Expected the operation to be rejected.');
end

function assert_rejected(operation, expectedIdentifier)
try
    operation();
catch ME
    assert(strcmp(ME.identifier, expectedIdentifier), ...
        'Expected %s, got %s: %s', expectedIdentifier, ME.identifier, ME.message);
    return
end
error('Expected rejection with %s.', expectedIdentifier);
end

function run_step29(fixture, repoRoot)
scriptsRoot = fullfile(fixture.root, 'scripts');
if ~isfolder(scriptsRoot)
    mkdir(scriptsRoot);
end
source = fileread(fullfile(repoRoot, 'scripts', ...
    'step_2_raw_9_create_dataset_list.m'));
sourceLine = ['baseDir = ''' repoRoot ''';'];
matches = strfind(source, sourceLine);
assert(isscalar(matches));
fixtureLine = ['baseDir = ''' strrep(fixture.root, '''', '''''') ''';'];
source = strrep(source, sourceLine, fixtureLine);
runner = sprintf('function run_step29_fixture\n%s\nend\n', source);
write_bytes(fullfile(scriptsRoot, 'run_step29_fixture.m'), ...
    unicode2native(runner, 'UTF-8'));
logPath = fullfile(fixture.root, 'step29-log-calls.txt');
logger = sprintf(['function log_command_window(action)\n' ...
    'fid=fopen(''%s'',''a''); assert(fid>=0);\n' ...
    'cleanup=onCleanup(@() fclose(fid)); %%#ok<NASGU>\n' ...
    'fprintf(fid,''%%s\\n'',char(string(action)));\nend\n'], ...
    strrep(logPath, '''', ''''''));
write_bytes(fullfile(scriptsRoot, 'log_command_window.m'), ...
    unicode2native(logger, 'UTF-8'));
priorPath = path;
priorFolder = pwd;
cleanup = onCleanup(@() restore_environment(priorPath, priorFolder));
addpath(scriptsRoot, '-begin');
addpath(fixture.functions, '-begin');
clear run_step29_fixture log_command_window inspect_identity_state ...
    load_dataset_identity_registry build_pseudonymised_dataset_registry ...
    validate_dataset_registry_paths
rehash path
cd(scriptsRoot);
run_step29_fixture();
end

function restore_environment(priorPath, priorFolder)
cd(priorFolder);
path(priorPath);
clear run_step29_fixture log_command_window
rehash path
end

function assert_log_calls(fixture, expected)
logPath = fullfile(fixture.root, 'step29-log-calls.txt');
assert(isfile(logPath));
actual = splitlines(strtrim(string(fileread(logPath))));
assert(isequal(actual(:), string(expected(:))));
end

function names = original_core()
names = {'subjectID', 'sessionID', 'runID', 'path_raw', 'EEGfile_raw'};
end

function names = mapped_core()
names = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'subjectID', 'sessionID', 'runID', 'path_raw_orig', 'path_raw', ...
    'EEGfile_raw_orig', 'EEGfile_raw'};
end

function filePath = target(root, relativePath, filename)
parts = cellstr(split(string(relativePath), '/'));
filePath = string(fullfile(root, parts{:}, char(filename)));
end

function files = tree_files(root)
files = strings(0, 1);
items = directory_entries(root);
for index = 1:numel(items)
    pathValue = fullfile(root, items(index).name);
    if items(index).isdir
        files = [files; tree_files(pathValue)]; %#ok<AGROW>
    else
        files(end + 1, 1) = string(pathValue); %#ok<AGROW>
    end
end
end

function items = directory_entries(pathValue)
items = dir(pathValue);
items = items(~ismember({items.name}, {'.', '..'}));
end

function bytes = read_bytes(pathValue)
fid = fopen(char(pathValue), 'rb');
assert(fid >= 0, 'Could not read fixture file.');
cleanup = onCleanup(@() fclose(fid));
bytes = fread(fid, Inf, '*uint8');
end

function write_bytes(pathValue, bytes)
fid = fopen(char(pathValue), 'wb');
assert(fid >= 0, 'Could not write fixture file.');
cleanup = onCleanup(@() fclose(fid));
count = fwrite(fid, bytes, 'uint8');
assert(count == numel(bytes));
end

function quoted = shell_quote(value)
quoted = ['"' strrep(char(value), '"', '\"') '"'];
end

function tf = canonical_equal(first, second)
first = char(java.io.File(first).getCanonicalPath());
second = char(java.io.File(second).getCanonicalPath());
tf = strcmp(first, second);
end

function remove_tree(pathValue)
if isfolder(pathValue)
    rmdir(pathValue, 's');
end
end
