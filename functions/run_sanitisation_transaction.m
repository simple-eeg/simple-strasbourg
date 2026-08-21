function result = run_sanitisation_transaction(repositoryRoot, testOptions)
%RUN_SANITISATION_TRANSACTION Safely sanitise mapped raw SET files.
%
% The second argument is used only by the synthetic regression tests. The
% numbered workflow script calls this function with repositoryRoot alone.

if nargin < 2
    testOptions = struct();
end
repositoryRoot = require_repository_root(repositoryRoot);
options = normalise_test_options(testOptions);
paths = transaction_paths(repositoryRoot);

assert_no_pseudonymisation_workspace(paths);
if path_object_exists(paths.workspace)
    result = recover_transaction(paths);
    fprintf(['Recovered the interrupted Step 2.11 transaction. ' ...
        'Run the script again separately to sanitise.\n']);
    return
end

state = inspect_identity_state(repositoryRoot);
if state.name == "mapped_modified"
    identity = state.identity;
    require_immediate_mapped_registry(identity);
    if verify_complete_noop(identity, paths)
        result = result_struct('no-op', identity.recording_count, ...
            identity.recording_count, false, true, strings(0, 1));
        fprintf('Step 2.11 already complete: %d SET files verified.\n', ...
            identity.recording_count);
        return
    end
    error('SIMPLE:Step2Sanitise:MixedOrDamagedState', ...
        ['The active SET files differ from raw_orig but do not form a ' ...
         'complete verified Step 2.11 result. No files were changed.']);
elseif state.name ~= "mapped_unsanitised"
    error('SIMPLE:Step2Sanitise:InvalidStartingState', ...
        'Step 2.11 requires a complete mapped Step 2.10 state.');
end

identity = state.identity;
require_immediate_mapped_registry(identity);
[manifest, privacyTokens] = preflight(identity, paths, options);
fprintf('Step 2.11 preflight passed: %d admitted SET files.\n', ...
    identity.recording_count);
assert_no_pseudonymisation_workspace(paths);
if ~mkdir(paths.workspace)
    error('SIMPLE:Step2Sanitise:WorkspaceCreateFailed', ...
        'Could not create the Step 2.11 transaction folder.');
end
ownsUncommittedWorkspace = true;

saveVersions = strings(identity.recording_count, 1);
try
    write_manifest(paths, manifest, options);
    ownsUncommittedWorkspace = false;
    assert_no_downstream_state(paths);
    assert_unsanitised_active(identity, manifest);
    require_regular_file(paths.registry, 0);
    assert_bound_inputs(identity, paths, paths.registry, manifest);
    assert_no_pseudonymisation_workspace(paths);
    atomic_move(paths.registry, paths.locked_registry, false);
    for row = 1:identity.recording_count
        source = set_path(identity, row, true);
        active = set_path(identity, row, false);
        require_hash(source, manifest.source_hashes{row}, row);
        require_hash(active, manifest.source_hashes{row}, row);
        [sourceEEG, layout] = raw_load_set(source, row);
        [candidateEEG, sanitiseReport] = sanitise_eeglab_dataset(sourceEEG, ...
            expected_identity(identity, row), ...
            privacy_context(identity, row, privacyTokens));
        delete_candidate_if_present(paths);
        saveVersions(row) = controlled_save_set(candidateEEG, ...
            paths.candidate, layout, sanitiseReport.requires_v73, options);
        require_regular_file(paths.candidate, row);
        verify_sanitised_eeglab_dataset(source, ...
            paths.candidate, expected_identity(identity, row), ...
            privacy_context(identity, row, privacyTokens));
        require_hash(source, manifest.source_hashes{row}, row);
        require_hash(active, manifest.source_hashes{row}, row);
        assert_no_pseudonymisation_workspace(paths);
        atomic_move(paths.candidate, active, true);
        if ~isempty(options.after_promotion)
            options.after_promotion(row);
        end
    end
    assert_no_downstream_state(paths);
    if ~verify_all(identity, manifest, privacyTokens)
        error('SIMPLE:Step2Sanitise:FinalVerificationFailed', ...
            'The complete active SET tree did not pass final verification.');
    end
    assert_bound_inputs(identity, paths, paths.locked_registry, manifest);
    require_hash(paths.locked_registry, manifest.registry_hash, 0);
    assert_no_pseudonymisation_workspace(paths);
    atomic_move(paths.locked_registry, paths.registry, false);
    assert_no_downstream_state(paths);
    assert_exact_active_inventory(identity);
    assert_bound_inputs(identity, paths, paths.registry, manifest);
    remove_owned_workspace(paths, manifest);
catch ME
    if strcmp(ME.identifier, 'SIMPLE:Step2Sanitise:SimulatedInterruption')
        rethrow(ME);
    end
    originalFailure = ME;
    try
        if ownsUncommittedWorkspace && ~path_object_exists(paths.manifest)
            names = workspace_names(paths.workspace);
            if isequal(names, "manifest.pending.mat") && ...
                    recovery_regular_file(paths.pending_manifest)
                pendingManifest = load_manifest(paths.pending_manifest);
                expectedManifest = rmfield(manifest, 'required_bytes');
                if ~isequaln(pendingManifest, expectedManifest)
                    unknown_workspace();
                end
                assert_no_pseudonymisation_workspace(paths);
                delete(paths.pending_manifest);
            elseif ~isempty(names)
                unknown_workspace();
            end
            if ~isempty(workspace_names(paths.workspace))
                unknown_workspace();
            end
            assert_no_pseudonymisation_workspace(paths);
            rmdir(paths.workspace);
        else
            recover_transaction(paths);
        end
    catch rollbackFailure
        if strcmp(rollbackFailure.identifier, ...
                'SIMPLE:Step2Sanitise:UnknownRecoveryState')
            rethrow(rollbackFailure);
        end
        combined = MException('SIMPLE:Step2Sanitise:RollbackFailed', ...
            ['Step 2.11 failed and its automatic rollback could not ' ...
             'complete. The transaction folder was retained.']);
        throw(combined);
    end
    throw(originalFailure);
end

result = result_struct('completed', identity.recording_count, ...
    identity.recording_count, false, false, unique(saveVersions, 'stable'));
fprintf('Step 2.11 complete: %d SET files sanitised and verified.\n', ...
    identity.recording_count);
end

function options = normalise_test_options(options)
defaults = struct('available_bytes_override', NaN, 'save_version', "auto", ...
    'v6_error_identifier', "", 'after_promotion', [], ...
    'after_pending_manifest', []);
if ~isstruct(options) || ~isscalar(options) || ...
        ~isempty(setdiff(fieldnames(options), fieldnames(defaults)))
    error('SIMPLE:Step2Sanitise:InvalidTestOptions', ...
        'The test-only options must be one supported scalar structure.');
end
for name = fieldnames(defaults).'
    if ~isfield(options, name{1})
        options.(name{1}) = defaults.(name{1});
    end
end
options.save_version = string(options.save_version);
if ~isscalar(options.save_version) || ...
        ~any(options.save_version == ["auto", "v6", "v7.3"])
    error('SIMPLE:Step2Sanitise:InvalidTestOptions', ...
        'The test-only save options are invalid.');
end
options.v6_error_identifier = string(options.v6_error_identifier);
testErrors = ["", "MATLAB:save:sizeTooBigForMATFile", ...
    "SIMPLE:Test:OtherSaveFailure"];
if ~isscalar(options.v6_error_identifier) || ...
        ~any(options.v6_error_identifier == testErrors)
    error('SIMPLE:Step2Sanitise:InvalidTestOptions', ...
        'The test-only v6 failure injection is invalid.');
end
available = options.available_bytes_override;
if ~(isnumeric(available) && isreal(available) && isscalar(available) && ...
        (isnan(available) || (isfinite(available) && available >= 0))) || ...
        ~(isempty(options.after_promotion) || ...
        isa(options.after_promotion, 'function_handle')) || ...
        ~(isempty(options.after_pending_manifest) || ...
        isa(options.after_pending_manifest, 'function_handle'))
    error('SIMPLE:Step2Sanitise:InvalidTestOptions', ...
        'The test-only storage override or callback is invalid.');
end
end

function repositoryRoot = require_repository_root(repositoryRoot)
if ~(ischar(repositoryRoot) || ...
        (isstring(repositoryRoot) && isscalar(repositoryRoot)))
    error('SIMPLE:Step2Sanitise:InvalidRepositoryRoot', ...
        'repositoryRoot must be scalar text.');
end
repositoryRoot = char(string(repositoryRoot));
if ~isfolder(repositoryRoot) || is_symbolic_link(repositoryRoot)
    error('SIMPLE:Step2Sanitise:InvalidRepositoryRoot', ...
        'The repository root must be a real directory.');
end
repositoryRoot = canonical_path(repositoryRoot);
end

function paths = transaction_paths(repositoryRoot)
paths.data = fullfile(repositoryRoot, 'data');
paths.registry = fullfile(repositoryRoot, 'data_lists', 'dataset_list.csv');
paths.preliminary = fullfile(repositoryRoot, 'data_lists', ...
    'dataset_list_prelim.xlsx');
paths.raw = fullfile(paths.data, 'raw');
paths.raw_orig = fullfile(paths.data, 'raw_orig');
paths.pseudonymisation_workspace = fullfile(paths.data, ...
    '.step_2_raw_10_transaction');
paths.workspace = fullfile(paths.data, '.step_2_raw_11_transaction');
paths.manifest = fullfile(paths.workspace, 'manifest.mat');
paths.pending_manifest = fullfile(paths.workspace, 'manifest.pending.mat');
paths.locked_registry = fullfile(paths.workspace, ...
    'dataset_list.locked.csv');
paths.candidate = fullfile(paths.workspace, 'candidate.set');
end

function require_immediate_mapped_registry(identity)
required = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'subjectID', 'sessionID', 'runID', 'path_raw_orig', 'path_raw', ...
    'EEGfile_raw_orig', 'EEGfile_raw'};
if identity.mode ~= "mapped" || ...
        ~isequal(identity.table.Properties.VariableNames, required)
    error('SIMPLE:Step2Sanitise:MappedRegistryRequired', ...
        'Step 2.11 requires the immediate ten-column Step 2.10 registry.');
end
end

function tf = verify_complete_noop(identity, paths)
tf = false;
try
    assert_no_downstream_state(paths);
    snapshot = inspect_mapped_inputs(identity, paths);
    manifest = manifest_from_snapshot(identity, paths.registry, snapshot);
    assert_same_filesystem(identity, paths, paths.registry, snapshot);
    if verify_all(identity, manifest, privacy_token_sets(snapshot))
        assert_bound_inputs(identity, paths, paths.registry, manifest);
        tf = true;
    end
catch
end
end

function snapshot = inspect_mapped_inputs(identity, paths)
T = identity.table;
originalPaths = "data/raw/" + ...
    extractAfter(T.path_raw_orig, strlength("data/raw_orig/"));
original = table(T.subjectID_orig, T.sessionID_orig, T.runID_orig, ...
    originalPaths, T.EEGfile_raw_orig, ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'});
snapshot = inspect_pseudonymisation_inputs( ...
    identity.repository_root, original, paths.raw_orig);
if ~isequal(snapshot.mapped, T)
    error('SIMPLE:Step2Sanitise:MappedRegistryMismatch', ...
        'The mapped registry does not match the accepted original inputs.');
end
end

function manifest = manifest_from_snapshot(identity, registryPath, snapshot)
manifest = struct('schema', 'simple-step2-sanitisation-v2', ...
    'operation', 'step_2_raw_11', ...
    'registry_hash', sha256_file(registryPath), ...
    'preliminary_hash', char(snapshot.preliminary_hash), ...
    'raw_tree_hash', char(snapshot.raw_tree_hash), ...
    'row_count', identity.recording_count, ...
    'source_hashes', {cellstr(snapshot.source_hashes)});
end

function assert_manifest_snapshot(manifest, snapshot)
if ~strcmp(manifest.preliminary_hash, snapshot.preliminary_hash) || ...
        ~strcmp(manifest.raw_tree_hash, snapshot.raw_tree_hash) || ...
        ~isequal(manifest.source_hashes, cellstr(snapshot.source_hashes))
    error('SIMPLE:Step2Sanitise:BoundInputChanged', ...
        'A governed Step 2.11 input changed.');
end
end

function assert_bound_inputs(identity, paths, registryPath, manifest)
assert_no_pseudonymisation_workspace(paths);
require_hash(registryPath, manifest.registry_hash, 0);
snapshot = inspect_mapped_inputs(identity, paths);
assert_manifest_snapshot(manifest, snapshot);
end

function assert_no_pseudonymisation_workspace(paths)
if path_object_exists(paths.pseudonymisation_workspace)
    unknown_workspace();
end
end

function assert_same_filesystem(identity, paths, registryPath, snapshot)
reference = file_store(paths.data);
values = [string(registryPath); string(paths.preliminary); ...
    string(paths.raw); string(paths.raw_orig); snapshot.admitted_files; ...
    string(identity.targets.raw_files)];
if path_object_exists(paths.workspace)
    values(end + 1, 1) = string(paths.workspace);
end
for index = 1:numel(values)
    if ~file_store(char(values(index))).equals(reference)
        error('SIMPLE:Step2Sanitise:CrossVolumeTransaction', ...
            'Every governed input must be on the transaction filesystem.');
    end
end
end

function [manifest, privacyTokens] = preflight(identity, paths, options)
assert_no_downstream_state(paths);
require_regular_file(paths.registry, 0);
for pathValue = {paths.raw, paths.raw_orig}
    if ~isfolder(pathValue{1}) || is_symbolic_link(pathValue{1})
        error('SIMPLE:Step2Sanitise:IncompleteMappedState', ...
            'The mapped raw and raw_orig folders must be real directories.');
    end
end
snapshot = inspect_mapped_inputs(identity, paths);
privacyTokens = privacy_token_sets(snapshot);
referenceStore = file_store(paths.data);
if ~file_store(paths.registry).equals(referenceStore)
    error('SIMPLE:Step2Sanitise:CrossVolumeTransaction', ...
        'The registry and raw data must be on one local filesystem.');
end

manifest = manifest_from_snapshot(identity, paths.registry, snapshot);
totalBytes = 0;
largestBytes = 0;
for row = 1:identity.recording_count
    source = set_path(identity, row, true);
    active = set_path(identity, row, false);
    require_regular_file(source, row);
    require_regular_file(active, row);
    if ~file_store(source).equals(referenceStore) || ...
            ~file_store(active).equals(referenceStore)
        error('SIMPLE:Step2Sanitise:CrossVolumeTransaction', ...
            'Every admitted SET must be on the transaction filesystem.');
    end
    if ~strcmp(manifest.source_hashes{row}, sha256_file(active))
        error('SIMPLE:Step2Sanitise:ActiveBytesChanged', ...
            'Registry row %d is not byte-identical to raw_orig.', row);
    end
    details = dir(source);
    totalBytes = totalBytes + details.bytes;
    largestBytes = max(largestBytes, details.bytes);
    sourceEEG = raw_load_set(source, row);
    sanitise_eeglab_dataset(sourceEEG, expected_identity(identity, row), ...
        privacy_context(identity, row, privacyTokens));
end
assert_exact_active_inventory(identity);
manifest.required_bytes = 2 * largestBytes + ...
    max(1024^3, ceil(0.01 * totalBytes));
assert_available_storage(paths, manifest.required_bytes, options);
end

function write_manifest(paths, manifest, options)
manifest = rmfield(manifest, 'required_bytes');
save(paths.pending_manifest, '-v6', '-mat', 'manifest');
loaded = load('-mat', paths.pending_manifest);
if ~isequal(fieldnames(loaded), {'manifest'}) || ...
        ~isequaln(loaded.manifest, manifest)
    error('SIMPLE:Step2Sanitise:ManifestWriteFailed', ...
        'The Step 2.11 recovery manifest did not verify.');
end
require_regular_file(paths.pending_manifest, 0);
if ~isempty(options.after_pending_manifest)
    options.after_pending_manifest();
end
atomic_move(paths.pending_manifest, paths.manifest, false);
end

function result = recover_transaction(paths)
if ~isfolder(paths.workspace) || is_symbolic_link(paths.workspace)
    unknown_workspace();
end
names = workspace_names(paths.workspace);
pendingOnly = isequal(names, "manifest.pending.mat") && ...
    recovery_regular_file(paths.pending_manifest);
if isempty(names) || (any(names == "manifest.pending.mat") && ~pendingOnly)
    unknown_workspace();
end

allowed = ["candidate.set", "dataset_list.locked.csv", "manifest.mat"];
if ~pendingOnly && (~recovery_regular_file(paths.manifest) || ...
        any(~ismember(names, allowed)) || ...
        (path_object_exists(paths.candidate) && ...
        ~recovery_regular_file(paths.candidate)) || ...
        (path_object_exists(paths.locked_registry) && ...
        ~recovery_regular_file(paths.locked_registry)))
    unknown_workspace();
end
manifestPath = paths.manifest;
if pendingOnly
    manifestPath = paths.pending_manifest;
end
manifest = load_manifest(manifestPath);
activeExists = path_object_exists(paths.registry);
lockedExists = path_object_exists(paths.locked_registry);
activeRegistry = activeExists && recovery_regular_file(paths.registry);
lockedRegistry = lockedExists && recovery_regular_file(paths.locked_registry);
if (activeExists && ~activeRegistry) || (lockedExists && ~lockedRegistry)
    unknown_workspace();
end
if activeRegistry == lockedRegistry || (pendingOnly && ~activeRegistry)
    unknown_workspace();
end
registryPath = paths.registry;
if lockedRegistry
    registryPath = paths.locked_registry;
end
recovery_require_hash(registryPath, manifest.registry_hash);
try
    identity = load_dataset_identity_registry(registryPath);
    require_immediate_mapped_registry(identity);
    if identity.recording_count ~= manifest.row_count
        unknown_workspace();
    end
    snapshot = inspect_mapped_inputs(identity, paths);
    assert_manifest_snapshot(manifest, snapshot);
    assert_same_filesystem(identity, paths, registryPath, snapshot);
catch ME
    if strcmp(ME.identifier, 'SIMPLE:Step2Sanitise:UnknownRecoveryState')
        rethrow(ME);
    end
    unknown_workspace();
end
privacyTokens = privacy_token_sets(snapshot);

try
    assert_no_downstream_state(paths);
    assert_exact_active_inventory(identity);
    assert_recoverable_files(identity, manifest, privacyTokens);
    if pendingOnly
        assert_unsanitised_active(identity, manifest);
    end
    assert_bound_inputs(identity, paths, registryPath, manifest);
catch
    unknown_workspace();
end
if pendingOnly
    if ~recovery_regular_file(paths.pending_manifest)
        unknown_workspace();
    end
    assert_no_pseudonymisation_workspace(paths);
    delete(paths.pending_manifest);
    if ~isempty(workspace_names(paths.workspace))
        unknown_workspace();
    end
    rmdir(paths.workspace);
    result = result_struct('recovered', identity.recording_count, ...
        identity.recording_count, true, false, strings(0, 1));
    return
end

if activeRegistry
    recovery_require_hash(paths.registry, manifest.registry_hash);
    assert_no_pseudonymisation_workspace(paths);
    recovery_atomic_move(paths.registry, paths.locked_registry, false);
end
for row = 1:identity.recording_count
    restore_source_file(paths, identity, manifest, ...
        privacyTokens, row);
end
try
    assert_no_downstream_state(paths);
    assert_unsanitised_active(identity, manifest);
    assert_bound_inputs(identity, paths, paths.locked_registry, manifest);
catch
    unknown_workspace();
end
recovery_require_hash(paths.locked_registry, manifest.registry_hash);
assert_no_pseudonymisation_workspace(paths);
recovery_atomic_move(paths.locked_registry, paths.registry, false);
delete_candidate_if_present(paths);
try
    assert_no_downstream_state(paths);
    assert_unsanitised_active(identity, manifest);
    assert_bound_inputs(identity, paths, paths.registry, manifest);
catch
    unknown_workspace();
end
remove_owned_workspace(paths, manifest);
result = result_struct('recovered', identity.recording_count, ...
    identity.recording_count, true, false, strings(0, 1));
end

function manifest = load_manifest(pathValue)
try
    loaded = load('-mat', pathValue);
catch
    unknown_workspace();
end
if ~isequal(fieldnames(loaded), {'manifest'}) || ...
        ~isstruct(loaded.manifest) || ...
        ~isscalar(loaded.manifest)
    unknown_workspace();
end
manifest = loaded.manifest;
expected = {'schema'; 'operation'; 'registry_hash'; 'preliminary_hash'; ...
    'raw_tree_hash'; 'row_count'; 'source_hashes'};
if ~isequal(fieldnames(manifest), expected) || ...
        ~ischar(manifest.schema) || ...
        ~strcmp(manifest.schema, 'simple-step2-sanitisation-v2') || ...
        ~ischar(manifest.operation) || ...
        ~strcmp(manifest.operation, 'step_2_raw_11') || ...
        ~is_sha256(manifest.registry_hash) || ...
        ~is_sha256(manifest.preliminary_hash) || ...
        ~is_sha256(manifest.raw_tree_hash) || ...
        ~(isnumeric(manifest.row_count) && isscalar(manifest.row_count) && ...
        isfinite(manifest.row_count) && manifest.row_count >= 1 && ...
        manifest.row_count == fix(manifest.row_count)) || ...
        ~iscell(manifest.source_hashes) || ...
        ~isequal(size(manifest.source_hashes), [manifest.row_count, 1]) || ...
        ~all(cellfun(@is_sha256, manifest.source_hashes))
    unknown_workspace();
end
end

function assert_recoverable_files(identity, manifest, privacyTokens)
for row = 1:identity.recording_count
    assert_recoverable_file(identity, manifest, privacyTokens, row);
end
end

function assert_recoverable_file(identity, manifest, privacyTokens, row)
source = set_path(identity, row, true);
active = set_path(identity, row, false);
recovery_require_hash(source, manifest.source_hashes{row});
if ~recovery_regular_file(active)
    unknown_workspace();
end
try
    activeHash = sha256_file(active);
catch
    unknown_workspace();
end
if strcmp(activeHash, manifest.source_hashes{row})
    return
end
try
    verify_sanitised_eeglab_dataset(source, active, ...
        expected_identity(identity, row), ...
        privacy_context(identity, row, privacyTokens));
catch
    unknown_workspace();
end
end

function restore_source_file(paths, identity, manifest, privacyTokens, row)
delete_candidate_if_present(paths);
source = set_path(identity, row, true);
active = set_path(identity, row, false);
assert_recoverable_file(identity, manifest, privacyTokens, row);
recovery_require_hash(source, manifest.source_hashes{row});
try
    copied = copyfile(source, paths.candidate, 'f');
catch
    copied = false;
end
if ~copied
    error('SIMPLE:Step2Sanitise:RecoveryCopyFailed', ...
        'Could not create a verified rollback copy for registry row %d.', row);
end
recovery_require_hash(paths.candidate, manifest.source_hashes{row});
recovery_require_hash(source, manifest.source_hashes{row});
assert_recoverable_file(identity, manifest, privacyTokens, row);
assert_no_pseudonymisation_workspace(paths);
recovery_atomic_move(paths.candidate, active, true);
if ~recovery_regular_file(active) || ...
        ~strcmp(sha256_file(active), manifest.source_hashes{row})
    error('SIMPLE:Step2Sanitise:RecoveryCopyFailed', ...
        'Could not restore registry row %d from raw_orig.', row);
end
end

function tf = verify_all(identity, manifest, privacyTokens)
tf = false;
try
    assert_exact_active_inventory(identity);
    for row = 1:identity.recording_count
        require_hash(set_path(identity, row, true), ...
            manifest.source_hashes{row}, row);
        verify_sanitised_eeglab_dataset(set_path(identity, row, true), ...
            set_path(identity, row, false), expected_identity(identity, row), ...
            privacy_context(identity, row, privacyTokens));
    end
    tf = true;
catch
end
end

function [EEG, layout] = raw_load_set(pathValue, row)
try
    stored = load('-mat', pathValue);
catch
    error('SIMPLE:Step2Sanitise:RawLoadFailed', ...
        'Registry row %d could not be raw-loaded.', row);
end
if isfield(stored, 'EEG') && isscalar(fieldnames(stored)) && ...
        isstruct(stored.EEG) && isscalar(stored.EEG)
    EEG = stored.EEG;
    layout = 'scalar-EEG-wrapper';
elseif isstruct(stored) && isscalar(stored) && isfield(stored, 'data')
    EEG = stored;
    layout = 'top-level-fields';
else
    error('SIMPLE:Step2Sanitise:UnsupportedSetLayout', ...
        'Registry row %d has an unsupported SET layout.', row);
end
end

function versionUsed = controlled_save_set( ...
        EEG, outputPath, layout, requiresV73, options)
requested = options.save_version;
if requested == "v7.3" || (requested == "auto" && requiresV73)
    save_layout_safely(EEG, outputPath, layout, '-v7.3');
    versionUsed = "v7.3";
    return
elseif requested == "v6" && requiresV73
    error('SIMPLE:Step2Sanitise:V6UnsupportedClass', ...
        'The SET contains content that requires the tested v7.3 route.');
end
try
    previousWarning = warning('error', ...
        'MATLAB:save:sizeTooBigForMATFile');
    warningCleanup = onCleanup(@() warning(previousWarning));
    if strlength(options.v6_error_identifier) > 0
        error(char(options.v6_error_identifier), ...
            'Synthetic v6 save failure.');
    end
    save_layout(EEG, outputPath, layout, '-v6');
catch ME
    delete_candidate_if_present_path(outputPath);
    if requested == "auto" && ...
            strcmp(ME.identifier, 'MATLAB:save:sizeTooBigForMATFile')
        save_layout_safely(EEG, outputPath, layout, '-v7.3');
        versionUsed = "v7.3";
        return
    end
    error('SIMPLE:Step2Sanitise:CandidateSaveFailed', ...
        'The sanitised SET candidate could not be saved.');
end
versionUsed = "v6";
end

function save_layout_safely(EEG, outputPath, layout, versionFlag)
try
    save_layout(EEG, outputPath, layout, versionFlag);
catch
    delete_candidate_if_present_path(outputPath);
    error('SIMPLE:Step2Sanitise:CandidateSaveFailed', ...
        'The sanitised SET candidate could not be saved.');
end
end

function save_layout(EEG, outputPath, layout, versionFlag)
if strcmp(layout, 'top-level-fields')
    save(outputPath, versionFlag, '-mat', '-struct', 'EEG');
elseif strcmp(layout, 'scalar-EEG-wrapper')
    save(outputPath, versionFlag, '-mat', 'EEG');
else
    error('SIMPLE:Step2Sanitise:UnsupportedSetLayout', ...
        'The controlled SET storage layout is unsupported.');
end
end

function expected = expected_identity(identity, row)
T = identity.table;
expected = struct('subjectID', char(T.subjectID(row)), ...
    'sessionID', char(T.sessionID(row)), 'runID', char(T.runID(row)), ...
    'EEGfile_raw', char(T.EEGfile_raw(row)));
end

function tokenSets = privacy_token_sets(snapshot)
tokenSets = struct('blocked', snapshot.privacy_tokens, ...
    'subjects', snapshot.subject_privacy_tokens);
end

function privacy = privacy_context(identity, row, tokenSets)
T = identity.table;
privacy = struct('row_number', row, ...
    'original_subject_id', char(T.subjectID_orig(row)), ...
    'original_session_id', char(T.sessionID_orig(row)), ...
    'original_run_id', char(T.runID_orig(row)), ...
    'original_filename', char(T.EEGfile_raw_orig(row)), ...
    'original_path', char(T.path_raw_orig(row)), ...
    'blocked_tokens', tokenSets.blocked, ...
    'subject_tokens', tokenSets.subjects);
end

function pathValue = set_path(identity, row, original)
if original
    relative = identity.table.path_raw_orig(row);
    filename = identity.table.EEGfile_raw_orig(row);
else
    relative = identity.table.path_raw(row);
    filename = identity.table.EEGfile_raw(row);
end
parts = cellstr(split(relative, '/'));
pathValue = fullfile(identity.repository_root, parts{:}, char(filename));
end

function assert_no_downstream_state(paths)
for leaf = {'info', 'processed', 'summary', 'results', 'jasp'}
    folder = fullfile(paths.data, leaf{1});
    if path_object_exists(folder) && ...
            (~isfolder(folder) || is_symbolic_link(folder) || ...
            folder_has_material(folder))
        error('SIMPLE:Step2Sanitise:DownstreamStateExists', ...
            'Step 3-or-later output already exists.');
    end
end
logs = fullfile(paths.data, 'logs');
if path_object_exists(logs) && ...
        (~isfolder(logs) || is_symbolic_link(logs))
    error('SIMPLE:Step2Sanitise:DownstreamStateExists', ...
        'The workflow log folder is not one real directory.');
elseif isfolder(logs)
    entries = dir(logs);
    names = string({entries(~[entries.isdir]).name});
    if any(~cellfun(@isempty, regexp(cellstr(names), ...
            '^step_[3-9]_', 'once')))
        error('SIMPLE:Step2Sanitise:DownstreamStateExists', ...
            'Step 3-or-later logs already exist.');
    end
end
end

function tf = folder_has_material(folder)
entries = dir(folder);
entries = entries(~ismember({entries.name}, {'.', '..', '.DS_Store'}));
tf = false;
for index = 1:numel(entries)
    pathValue = fullfile(folder, entries(index).name);
    if ~entries(index).isdir || is_symbolic_link(pathValue) || ...
            folder_has_material(pathValue)
        tf = true;
        return
    end
end
end

function assert_exact_active_inventory(identity)
root = canonical_path(fullfile(identity.repository_root, 'data', 'raw'));
[files, directories] = walk_tree(root);
expectedFiles = sort(string(identity.targets.raw_files));
expectedDirectories = strings(0, 1);
for index = 1:numel(expectedFiles)
    parent = fileparts(char(expectedFiles(index)));
    while ~strcmp(canonical_path(parent), root)
        expectedDirectories(end + 1, 1) = ...
            string(canonical_path(parent)); %#ok<AGROW>
        parent = fileparts(parent);
    end
end
expectedDirectories = unique(expectedDirectories, 'sorted');
if ~isequal(sort(files), expectedFiles) || ...
        ~isequal(sort(directories), expectedDirectories)
    error('SIMPLE:Step2Sanitise:UnexpectedActiveInventory', ...
        'The active raw tree does not have the exact admitted topology.');
end
end

function assert_unsanitised_active(identity, manifest)
assert_exact_active_inventory(identity);
for row = 1:identity.recording_count
    require_hash(set_path(identity, row, false), ...
        manifest.source_hashes{row}, row);
end
end

function [files, directories] = walk_tree(root)
if ~isfolder(root) || is_symbolic_link(root)
    error('SIMPLE:Step2Sanitise:UnexpectedActiveInventory', ...
        'The active raw root is unavailable or redirected.');
end
files = strings(0, 1);
directories = strings(0, 1);
entries = dir(root);
entries = entries(~ismember({entries.name}, {'.', '..'}));
for index = 1:numel(entries)
    pathValue = fullfile(root, entries(index).name);
    if is_symbolic_link(pathValue)
        error('SIMPLE:Step2Sanitise:UnexpectedActiveInventory', ...
            'The active raw tree contains a symbolic link.');
    elseif entries(index).isdir
        directories(end + 1, 1) = ...
            string(canonical_path(pathValue)); %#ok<AGROW>
        [childFiles, childDirectories] = walk_tree(pathValue);
        files = [files; childFiles]; %#ok<AGROW>
        directories = [directories; childDirectories]; %#ok<AGROW>
    elseif java.io.File(pathValue).isFile()
        require_regular_file(pathValue, 0);
        if strcmp(entries(index).name, '.DS_Store')
            continue
        end
        files(end + 1, 1) = string(canonical_path(pathValue)); %#ok<AGROW>
    else
        error('SIMPLE:Step2Sanitise:UnexpectedActiveInventory', ...
            'The active raw tree contains a special filesystem object.');
    end
end
end

function require_regular_file(pathValue, row)
if ~isfile(pathValue) || is_symbolic_link(pathValue) || ...
        ~java.io.File(pathValue).isFile() || hard_link_count(pathValue) ~= 1
    error('SIMPLE:Step2Sanitise:UnsafeFile', ...
        'Registry row %d is not one regular, singly linked file.', row);
end
end

function tf = recovery_regular_file(pathValue)
try
    tf = isfile(pathValue) && ~is_symbolic_link(pathValue) && ...
        java.io.File(pathValue).isFile() && hard_link_count(pathValue) == 1;
catch
    tf = false;
end
end

function count = hard_link_count(pathValue)
try
    options = javaArray('java.nio.file.LinkOption', 0);
    count = double(java.nio.file.Files.getAttribute( ...
        java.io.File(pathValue).toPath(), 'unix:nlink', options));
catch
    error('SIMPLE:Step2Sanitise:HardLinkInspectionFailed', ...
        'A governed file hard-link count could not be verified.');
end
end

function require_hash(pathValue, expectedHash, row)
require_regular_file(pathValue, row);
if ~strcmp(sha256_file(pathValue), expectedHash)
    error('SIMPLE:Step2Sanitise:BoundInputChanged', ...
        'A governed Step 2.11 file changed.');
end
end

function recovery_require_hash(pathValue, expectedHash)
if ~recovery_regular_file(pathValue)
    unknown_workspace();
end
try
    matches = strcmp(sha256_file(pathValue), expectedHash);
catch
    unknown_workspace();
end
if ~matches
    unknown_workspace();
end
end

function store = file_store(pathValue)
try
    store = java.nio.file.Files.getFileStore(java.io.File(pathValue).toPath());
    type = lower(char(store.type()));
catch
    error('SIMPLE:Step2Sanitise:FileStoreCheckUnavailable', ...
        'Could not verify the Step 2.11 filesystem.');
end
if any(contains(type, {'nfs', 'smb', 'cifs', 'afp', 'webdav', ...
        'sshfs', 'fuse', 'network'}))
    error('SIMPLE:Step2Sanitise:NonLocalVolume', ...
        'Step 2.11 requires a local filesystem.');
end
end

function assert_available_storage(paths, requiredBytes, options)
available = options.available_bytes_override;
if isnan(available)
    available = double(java.io.File(paths.data).getUsableSpace());
end
if available < requiredBytes
    error('SIMPLE:Step2Sanitise:InsufficientStorage', ...
        'Step 2.11 does not have enough same-volume working space.');
end
end

function delete_candidate_if_present(paths)
assert_no_pseudonymisation_workspace(paths);
delete_candidate_if_present_path(paths.candidate);
end

function delete_candidate_if_present_path(pathValue)
if path_object_exists(pathValue)
    if ~recovery_regular_file(pathValue)
        unknown_workspace();
    end
    delete(pathValue);
end
end

function remove_owned_workspace(paths, manifest)
assert_no_pseudonymisation_workspace(paths);
names = workspace_names(paths.workspace);
if path_object_exists(paths.locked_registry) || ...
        path_object_exists(paths.candidate) || ...
        path_object_exists(paths.pending_manifest) || ...
        ~isequal(names, "manifest.mat")
    unknown_workspace();
end
if ~recovery_regular_file(paths.manifest)
    unknown_workspace();
end
expected = manifest;
if isfield(expected, 'required_bytes')
    expected = rmfield(expected, 'required_bytes');
end
if ~isequaln(load_manifest(paths.manifest), expected)
    unknown_workspace();
end
delete(paths.manifest);
if ~isempty(workspace_names(paths.workspace))
    unknown_workspace();
end
rmdir(paths.workspace);
end

function names = workspace_names(workspace)
entries = dir(workspace);
entries = entries(~ismember({entries.name}, {'.', '..'}));
names = sort(string({entries.name}));
end

function atomic_move(source, destination, replaceExisting)
require_regular_file(source, 0);
if path_object_exists(destination)
    require_regular_file(destination, 0);
end
moveOptions = javaArray('java.nio.file.CopyOption', 1 + replaceExisting);
moveOptions(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
if replaceExisting
    moveOptions(2) = java.nio.file.StandardCopyOption.REPLACE_EXISTING;
end
try
    java.nio.file.Files.move(java.io.File(source).toPath(), ...
        java.io.File(destination).toPath(), moveOptions);
catch
    error('SIMPLE:Step2Sanitise:AtomicMoveFailed', ...
        'A required same-filesystem atomic rename failed.');
end
end

function recovery_atomic_move(source, destination, replaceExisting)
if ~recovery_regular_file(source) || ...
        (path_object_exists(destination) && ...
        ~recovery_regular_file(destination))
    unknown_workspace();
end
try
    atomic_move(source, destination, replaceExisting);
catch ME
    if any(strcmp(ME.identifier, { ...
            'SIMPLE:Step2Sanitise:UnsafeFile', ...
            'SIMPLE:Step2Sanitise:HardLinkInspectionFailed'}))
        unknown_workspace();
    end
    rethrow(ME)
end
end

function digest = sha256_file(pathValue)
engine = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(pathValue, 'rb');
if fid < 0
    error('SIMPLE:Step2Sanitise:FileReadFailed', ...
        'A governed file could not be read.');
end
cleanup = onCleanup(@() fclose(fid));
remainingBytes = double(java.io.File(pathValue).length());
while remainingBytes > 0
    [bytes, count] = fread(fid, min(1024 * 1024, remainingBytes), '*uint8');
    if count > 0
        engine.update(reshape(typecast(bytes(:), 'int8'), 1, []));
    end
    remainingBytes = remainingBytes - count;
    if count == 0
        break
    end
end
if remainingBytes ~= 0 || ~isempty(ferror(fid))
    error('SIMPLE:Step2Sanitise:FileReadFailed', ...
        'A governed file could not be read completely.');
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end

function tf = is_sha256(value)
tf = ischar(value) && ~isempty(regexp(value, '^[0-9a-f]{64}$', 'once'));
end

function result = result_struct(status, recordingCount, verifiedCount, ...
        recovered, noOp, saveVersions)
result = struct('status', status, 'recording_count', recordingCount, ...
    'verified_count', verifiedCount, 'recovered', recovered, ...
    'no_op', noOp, 'save_versions', saveVersions);
end

function unknown_workspace()
error('SIMPLE:Step2Sanitise:UnknownRecoveryState', ...
    ['The Step 2.11 transaction state is not recognised. It was left ' ...
     'untouched for manual review.']);
end

function tf = path_object_exists(pathValue)
tf = java.io.File(pathValue).exists() || is_symbolic_link(pathValue);
end

function tf = is_symbolic_link(pathValue)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(pathValue).toPath());
end

function value = canonical_path(value)
value = char(java.io.File(char(value)).getCanonicalPath());
end
