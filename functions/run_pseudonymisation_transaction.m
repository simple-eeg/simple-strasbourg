function result = run_pseudonymisation_transaction(repositoryRoot, testOptions)
%RUN_PSEUDONYMISATION_TRANSACTION Execute or recover Step 2.10.
%
% The transaction builds and verifies a complete replacement-ID candidate,
% then publishes it with same-filesystem atomic renames or restores the
% original state conservatively after a recognised interruption.

if nargin < 2
    testOptions = struct();
end
initialState = inspect_identity_state(repositoryRoot);
root = initialState.paths.repository;
paths = transaction_paths(initialState.paths);
options = validate_options(testOptions);
assert_bindings(root);

if path_object_exists(paths.workspace_11)
    error('SIMPLE:Step2Identity:OtherTransactionActive', ...
        'A Step 2.11 transaction workspace exists.');
elseif path_object_exists(paths.workspace)
    snapshot = recover_transaction(paths);
    result = make_result("recovered_stop", "original", ...
        height(snapshot.original), snapshot.admitted_bytes);
    fprintf(['Recovered a recognised Step 2.10 transaction. ' ...
        'Run this script again separately to start new work.\n']);
    return
end

state = initialState;
if state.name == "mapped_unsanitised"
    snapshot = verify_mapped_complete(paths, state.identity);
    result = make_result("already_complete", state.name, ...
        height(snapshot.original), snapshot.admitted_bytes);
    fprintf('Step 2.10 is already complete and verified for %d recordings.\n', ...
        height(snapshot.original));
    return
elseif state.name == "mapped_modified"
    error('SIMPLE:Step2Identity:MappedFilesChanged', ...
        'Mapped active SET files differ from raw_orig.');
elseif state.name ~= "original"
    error('SIMPLE:Step2Identity:InvalidStartState', ...
        'Step 2.10 requires the exact immediate post-Step-2.9 state.');
end

require_immediate_registry(state.identity.table);
snapshot = inspect_pseudonymisation_inputs(root, ...
    state.identity.table, paths.raw);
snapshot.registry_hash = sha256_file(paths.registry);
assert_no_downstream(root);
assert_one_store(paths);
requiredBytes = snapshot.admitted_bytes + ...
    max(1024^3, ceil(0.01 * snapshot.admitted_bytes));
assert_space(paths.data, requiredBytes, options);
fprintf(['Step 2.10 preflight passed: admitted=%d, excluded-present=%d, ' ...
    'admitted-bytes=%0.0f.\n'], height(snapshot.original), ...
    snapshot.excluded_present_count, snapshot.admitted_bytes);

workspaceOwned = false;
try
    create_workspace(paths.workspace);
    workspaceOwned = true;
    manifest = make_manifest(snapshot);
    write_manifest(paths, manifest);
    stage_registry(paths, snapshot.mapped);
    stage_tree(paths, snapshot);
    verify_staged(paths, snapshot, manifest);

    atomic_move(paths.registry, paths.locked_registry);
    after_move(options, 1);
    atomic_move(paths.raw, paths.raw_orig);
    after_move(options, 2);
    atomic_move(paths.raw_candidate, paths.raw);
    after_move(options, 3);
    atomic_move(paths.candidate_registry, paths.registry);
    after_move(options, 4);

    verify_published(paths, snapshot, manifest);
    delete_regular(paths.locked_registry);
    delete_regular(paths.manifest);
    remove_empty_directory(paths.workspace);
catch ME
    if strcmp(ME.identifier, 'SIMPLE:Step2Identity:SimulatedInterruption')
        rethrow(ME)
    end
    originalFailure = ME;
    if path_object_exists(paths.workspace)
        try
            if isfile(paths.manifest)
                recover_transaction(paths);
            elseif workspaceOwned
                cleanup_owned_pre_manifest(paths);
            else
                unknown_recovery();
            end
        catch
            error('SIMPLE:Step2Identity:RollbackFailed', ...
                ['Step 2.10 failed and automatic rollback could not ' ...
                 'complete. The workspace was retained.']);
        end
    end
    throw(originalFailure)
end

result = make_result("completed", "mapped_unsanitised", ...
    height(snapshot.original), snapshot.admitted_bytes);
fprintf('Step 2.10 completed and verified for %d recordings.\n', height(snapshot.original));
end

function options = validate_options(value)
defaults = struct('usable_bytes', NaN, 'after_move', []);
if ~isstruct(value) || ~isscalar(value) || ...
        ~isempty(setdiff(fieldnames(value), fieldnames(defaults)))
    error('SIMPLE:Step2Identity:InvalidTestOptions', 'The test-only options are invalid.');
end
for name = fieldnames(defaults).'
    if ~isfield(value, name{1})
        value.(name{1}) = defaults.(name{1});
    end
end
validSpace = isnumeric(value.usable_bytes) && isreal(value.usable_bytes) && ...
    isscalar(value.usable_bytes) && (isnan(value.usable_bytes) || ...
    (isfinite(value.usable_bytes) && value.usable_bytes >= 0));
if ~validSpace || ~(isempty(value.after_move) || ...
        isa(value.after_move, 'function_handle'))
    error('SIMPLE:Step2Identity:InvalidTestOptions', ...
        'The test-only storage override or callback is invalid.');
end
options = value;
end

function after_move(options, moveNumber)
if ~isempty(options.after_move)
    options.after_move(moveNumber);
end
end

function paths = transaction_paths(paths)
paths.workspace = paths.workspace_2_10;
paths.workspace_11 = paths.workspace_2_11;
paths.manifest = fullfile(paths.workspace, 'manifest.mat');
paths.pending_manifest = fullfile(paths.workspace, 'manifest.pending.mat');
paths.locked_registry = fullfile(paths.workspace, 'dataset_list.locked.csv');
paths.candidate_registry = fullfile(paths.workspace, 'dataset_list.candidate.csv');
paths.pending_registry = fullfile(paths.workspace, 'dataset_list.candidate.pending.csv');
paths.raw_candidate = fullfile(paths.workspace, 'raw_candidate');
paths.copy_pending = fullfile(paths.workspace, 'copy.pending.set');
end

function manifest = make_manifest(snapshot)
manifest = struct('schema', 'simple-step2-pseudonymisation-v1', ...
    'operation', 'step_2_raw_10', ...
    'registry_hash', snapshot.registry_hash, ...
    'preliminary_hash', snapshot.preliminary_hash, ...
    'row_count', height(snapshot.original), ...
    'source_hashes', {cellstr(snapshot.source_hashes)});
end

function write_manifest(paths, manifest)
if path_object_exists(paths.pending_manifest) || path_object_exists(paths.manifest)
    unknown_recovery();
end
try
    save(paths.pending_manifest, '-v6', '-mat', 'manifest');
    loaded = load('-mat', paths.pending_manifest);
catch
    error('SIMPLE:Step2Identity:ManifestWriteFailed', ...
        'The transaction manifest could not be written safely.');
end
if ~isequal(fieldnames(loaded), {'manifest'}) || ~isequaln(loaded.manifest, manifest)
    error('SIMPLE:Step2Identity:ManifestWriteFailed', 'The transaction manifest did not verify.');
end
atomic_move(paths.pending_manifest, paths.manifest);
end

function manifest = load_manifest(pathValue)
try
    loaded = load('-mat', pathValue);
catch
    unknown_recovery();
end
if ~isequal(fieldnames(loaded), {'manifest'}) || ...
        ~isstruct(loaded.manifest) || ~isscalar(loaded.manifest)
    unknown_recovery();
end
manifest = loaded.manifest;
required = {'schema'; 'operation'; 'registry_hash'; ...
    'preliminary_hash'; 'row_count'; 'source_hashes'};
if ~isequal(fieldnames(manifest), required) || ...
        ~ischar(manifest.schema) || ...
        ~strcmp(manifest.schema, 'simple-step2-pseudonymisation-v1') || ...
        ~ischar(manifest.operation) || ...
        ~strcmp(manifest.operation, 'step_2_raw_10') || ...
        ~is_hash(manifest.registry_hash) || ...
        ~is_hash(manifest.preliminary_hash) || ...
        ~(isnumeric(manifest.row_count) && isscalar(manifest.row_count) && ...
        isfinite(manifest.row_count) && manifest.row_count >= 1 && ...
        manifest.row_count == fix(manifest.row_count)) || ...
        ~iscell(manifest.source_hashes) || ...
        ~isequal(size(manifest.source_hashes), [manifest.row_count, 1]) || ...
        ~all(cellfun(@is_hash, manifest.source_hashes))
    unknown_recovery();
end
end

function stage_registry(paths, mapped)
try
    writetable(mapped, paths.pending_registry, 'FileType', 'text', ...
        'WriteVariableNames', true, 'Delimiter', ',');
catch
    error('SIMPLE:Step2Identity:CandidateRegistryWriteFailed', ...
        'The candidate registry could not be written safely.');
end
if ~isequal(read_candidate_registry(paths.pending_registry, mapped), mapped)
    error('SIMPLE:Step2Identity:CandidateRegistryWriteFailed', ...
        'The candidate registry did not verify.');
end
atomic_move(paths.pending_registry, paths.candidate_registry);
end

function tableValue = read_candidate_registry(pathValue, expected)
if ~regular_file(pathValue)
    error('SIMPLE:Step2Identity:InvalidCandidateRegistry', ...
        'The candidate registry is not a regular file.');
end
names = expected.Properties.VariableNames;
try
    opts = detectImportOptions(pathValue, 'FileType', 'text', 'Delimiter', ',');
    if ~isequal(opts.VariableNames, names)
        error('schema');
    end
    opts = setvartype(opts, names, 'string');
    tableValue = readtable(pathValue, opts);
catch
    error('SIMPLE:Step2Identity:InvalidCandidateRegistry', ...
        'The candidate registry could not be verified.');
end
for index = 1:numel(names)
    tableValue.(names{index}) = string(tableValue.(names{index}));
end
end

function stage_tree(paths, snapshot)
safe_mkdir(paths.raw_candidate);
targets = mapped_targets(paths.raw_candidate, snapshot.mapped);
for row = 1:numel(targets)
    safe_mkdir(fileparts(targets(row)));
    try
        copied = copyfile(char(snapshot.admitted_files(row)), paths.copy_pending, 'f');
    catch
        copied = false;
    end
    if ~copied || ~strcmp(sha256_file(paths.copy_pending), snapshot.source_hashes(row))
        error('SIMPLE:Step2Identity:CopyFailed', ...
            'Could not create a verified copy for registry row %d.', row);
    end
    atomic_move(paths.copy_pending, targets(row));
end
end

function verify_staged(paths, snapshot, manifest)
if ~strcmp(sha256_file(paths.registry), manifest.registry_hash) || ...
        ~strcmp(sha256_file(paths.preliminary), ...
        manifest.preliminary_hash) || ...
        ~snapshot_matches(paths, snapshot.original, paths.raw, manifest) || ...
        ~isequal(read_candidate_registry(paths.candidate_registry, ...
        snapshot.mapped), snapshot.mapped) || ...
        mapped_tree_status(paths.raw_candidate, snapshot.mapped, ...
        strings(0, 1)) ~= "full" || ...
        path_object_exists(paths.copy_pending) || ...
        path_object_exists(paths.pending_registry)
    error('SIMPLE:Step2Identity:CandidateVerificationFailed', ...
        'The complete Step 2.10 candidate did not verify.');
end
assert_no_downstream(paths.repository);
end

function verify_published(paths, snapshot, manifest)
try
    active = load_dataset_identity_registry(paths.registry);
catch
    error('SIMPLE:Step2Identity:FinalVerificationFailed', ...
        'The published mapped registry could not be verified.');
end
if active.mode ~= "mapped" || ~isequal(active.table, snapshot.mapped) || ...
        ~strcmp(sha256_file(paths.locked_registry), ...
        manifest.registry_hash) || ...
        ~strcmp(sha256_file(paths.preliminary), ...
        manifest.preliminary_hash) || ...
        ~isfolder(paths.raw_orig) || is_symbolic_link(paths.raw_orig) || ...
        mapped_tree_status(paths.raw, snapshot.mapped, ...
        strings(0, 1)) ~= "full" || ...
        path_object_exists(paths.raw_candidate) || ...
        path_object_exists(paths.candidate_registry)
    error('SIMPLE:Step2Identity:FinalVerificationFailed', ...
        'The complete published Step 2.10 state did not verify.');
end
assert_no_downstream(paths.repository);
end

function snapshot = verify_mapped_complete(paths, identity)
required = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'subjectID', 'sessionID', 'runID', 'path_raw_orig', 'path_raw', ...
    'EEGfile_raw_orig', 'EEGfile_raw'};
if identity.mode ~= "mapped" || ~isequal(identity.table.Properties.VariableNames, required)
    error('SIMPLE:Step2Identity:MappedStateInvalid', ...
        'The mapped registry is not the immediate Step 2.10 schema.');
end
T = identity.table;
original = table(T.subjectID_orig, T.sessionID_orig, T.runID_orig, ...
    "data/raw/" + extractAfter(T.path_raw_orig, ...
    strlength("data/raw_orig/")), T.EEGfile_raw_orig, ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'});
    snapshot = inspect_pseudonymisation_inputs(paths.repository, ...
        original, paths.raw_orig);
snapshot.registry_hash = '';
if ~isequal(snapshot.mapped, T) || ...
        mapped_tree_status(paths.raw, T, ...
        snapshot.source_hashes) ~= "full"
    error('SIMPLE:Step2Identity:MappedFilesChanged', ...
        'The complete mapped raw tree does not match raw_orig.');
end
assert_no_downstream(paths.repository);
end

function snapshot = recover_transaction(paths)
validate_workspace_slots(paths);
if ~isfile(paths.manifest)
    unknown_recovery();
end
if path_object_exists(paths.pending_manifest)
    unknown_recovery();
end
manifest = load_manifest(paths.manifest);
activeOriginal = regular_file(paths.registry) && ...
    strcmp(sha256_file(paths.registry), manifest.registry_hash);
lockedOriginal = regular_file(paths.locked_registry) && ...
    strcmp(sha256_file(paths.locked_registry), manifest.registry_hash);
if (path_object_exists(paths.locked_registry) && ~lockedOriginal) || ...
        activeOriginal == lockedOriginal || ...
        ~regular_file(paths.preliminary) || ...
        ~strcmp(sha256_file(paths.preliminary), ...
        manifest.preliminary_hash)
    unknown_recovery();
end
originalRegistry = paths.registry;
if lockedOriginal
    originalRegistry = paths.locked_registry;
end
try
    originalIdentity = load_dataset_identity_registry(originalRegistry);
    require_immediate_registry(originalIdentity.table);
catch
    unknown_recovery();
end
if height(originalIdentity.table) ~= manifest.row_count
    unknown_recovery();
end

rawOriginal = snapshot_matches(paths, originalIdentity.table, paths.raw, manifest);
rawOrigOriginal = snapshot_matches(paths, originalIdentity.table, paths.raw_orig, manifest);
if rawOriginal == rawOrigOriginal
    unknown_recovery();
end
sourceRoot = paths.raw;
if rawOrigOriginal
    sourceRoot = paths.raw_orig;
end
try
    snapshot = inspect_pseudonymisation_inputs(paths.repository, ...
        originalIdentity.table, sourceRoot);
catch
    unknown_recovery();
end
if ~strcmp(snapshot.preliminary_hash, manifest.preliminary_hash) || ...
        ~isequal(cellstr(snapshot.source_hashes), manifest.source_hashes)
    unknown_recovery();
end

candidateRegistry = path_object_exists(paths.candidate_registry);
pendingRegistry = path_object_exists(paths.pending_registry);
if candidateRegistry && pendingRegistry
    unknown_recovery();
elseif candidateRegistry
    try
        candidate = read_candidate_registry(paths.candidate_registry, ...
            snapshot.mapped);
        if ~isequal(candidate, snapshot.mapped)
            unknown_recovery();
        end
    catch
        unknown_recovery();
    end
end
activeMapped = false;
if ~activeOriginal && regular_file(paths.registry)
    try
        active = load_dataset_identity_registry(paths.registry);
        activeMapped = active.mode == "mapped" && isequal(active.table, snapshot.mapped);
    catch
        activeMapped = false;
    end
    if ~activeMapped
        unknown_recovery();
    end
elseif ~activeOriginal && path_object_exists(paths.registry)
    unknown_recovery();
end
candidateStatus = mapped_tree_status(paths.raw_candidate, ...
    snapshot.mapped, snapshot.source_hashes);
rawMapped = ~rawOriginal && mapped_tree_status(paths.raw, ...
    snapshot.mapped, snapshot.source_hashes) == "full";

if rawOriginal
    if path_object_exists(paths.raw_orig) || activeMapped || ...
            candidateStatus == "unknown" || ...
            (lockedOriginal && activeOriginal)
        unknown_recovery();
    end
else
    invalidRaw = (rawMapped && candidateStatus ~= "absent") || ...
        (~rawMapped && (path_object_exists(paths.raw) || ...
        candidateStatus ~= "full"));
    invalidRegistry = (activeMapped && candidateRegistry) || ...
        (~activeMapped && ~candidateRegistry);
    if ~lockedOriginal || invalidRaw || invalidRegistry
        unknown_recovery();
    end
end

if activeMapped
    atomic_move(paths.registry, paths.candidate_registry);
    candidateRegistry = true;
end
if rawMapped
    atomic_move(paths.raw, paths.raw_candidate);
    candidateStatus = "full";
end
if rawOrigOriginal
    atomic_move(paths.raw_orig, paths.raw);
end
if lockedOriginal
    atomic_move(paths.locked_registry, paths.registry);
end
if path_object_exists(paths.copy_pending)
    delete_regular(paths.copy_pending);
end
if candidateStatus ~= "absent"
    remove_verified_tree(paths.raw_candidate);
end
if pendingRegistry
    delete_regular(paths.pending_registry);
end
if candidateRegistry
    delete_regular(paths.candidate_registry);
end
delete_regular(paths.manifest);
remove_empty_directory(paths.workspace);
end

function cleanup_owned_pre_manifest(paths)
validate_workspace_slots(paths);
names = sort(string({directory_entries(paths.workspace).name}));
if isempty(names)
    remove_empty_directory(paths.workspace);
elseif isequal(names, "manifest.pending.mat")
    delete_regular(paths.pending_manifest);
    remove_empty_directory(paths.workspace);
else
    unknown_recovery();
end
end

function validate_workspace_slots(paths)
if ~isfolder(paths.workspace) || is_symbolic_link(paths.workspace)
    unknown_recovery();
end
items = directory_entries(paths.workspace);
allowed = ["manifest.mat", "manifest.pending.mat", ...
    "dataset_list.locked.csv", "dataset_list.candidate.csv", ...
    "dataset_list.candidate.pending.csv", "raw_candidate", ...
    "copy.pending.set"];
if any(~ismember(string({items.name}), allowed))
    unknown_recovery();
end
for index = 1:numel(items)
    pathValue = fullfile(paths.workspace, items(index).name);
    isCandidateTree = strcmp(items(index).name, 'raw_candidate');
    if is_symbolic_link(pathValue) || ...
            (isCandidateTree && ~items(index).isdir) || ...
            (~isCandidateTree && ...
            (items(index).isdir || ~regular_file(pathValue)))
        unknown_recovery();
    end
end
end

function tf = snapshot_matches(paths, original, root, manifest)
tf = false;
if ~isfolder(root) || is_symbolic_link(root)
    return
end
try
    snapshot = inspect_pseudonymisation_inputs(paths.repository, ...
        original, root);
    tf = strcmp(snapshot.preliminary_hash, ...
        manifest.preliminary_hash) && ...
        isequal(cellstr(snapshot.source_hashes), ...
        manifest.source_hashes);
catch
    tf = false;
end
end

function status = mapped_tree_status(root, mapped, hashes)
if ~path_object_exists(root)
    status = "absent";
    return
elseif ~isfolder(root) || is_symbolic_link(root)
    status = "unknown";
    return
end
try
    nodes = walk_tree(root);
catch
    status = "unknown";
    return
end
types = string({nodes.type});
actualFiles = string({nodes(types == "file").absolute}).';
actualDirectories = string({nodes(types == "directory").absolute}).';
targets = mapped_targets(root, mapped);
directories = expected_directories(root, targets);
if any(~ismember(actualFiles, targets)) || ...
        any(~ismember(actualDirectories, directories))
    status = "unknown";
    return
end
checkHashes = ~isempty(hashes);
for row = 1:numel(targets)
    if checkHashes && any(actualFiles == targets(row)) && ...
            ~strcmp(sha256_file(targets(row)), hashes(row))
        status = "unknown";
        return
    end
end
if isequal(sort(actualFiles), sort(targets)) && ...
        isequal(sort(actualDirectories), sort(directories))
    status = "full";
else
    status = "partial";
end
end

function targets = mapped_targets(root, mapped)
targets = strings(height(mapped), 1);
prefix = "data/raw/";
for row = 1:height(mapped)
    relative = extractAfter(mapped.path_raw(row), strlength(prefix));
    parts = cellstr(split(relative, '/'));
    targets(row) = string(fullfile(root, parts{:}, char(mapped.EEGfile_raw(row))));
end
end

function directories = expected_directories(root, targets)
directories = strings(0, 1);
for index = 1:numel(targets)
    current = string(fileparts(targets(index)));
    while current ~= string(root)
        directories(end + 1, 1) = current; %#ok<AGROW>
        current = string(fileparts(current));
    end
end
directories = unique(directories, 'stable');
end

function nodes = walk_tree(root)
if ~isfolder(root) || is_symbolic_link(root)
    error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
        'A governed tree is unavailable or redirected.');
end
nodes = struct('absolute', {}, 'type', {});
nodes = walk_directory(root, nodes);
end

function nodes = walk_directory(folder, nodes)
items = directory_entries(folder);
for index = 1:numel(items)
    pathValue = fullfile(folder, items(index).name);
    if is_symbolic_link(pathValue)
        error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
            'A governed tree contains a symbolic link.');
    elseif items(index).isdir
        type = 'directory';
    elseif java.io.File(pathValue).isFile()
        if hard_link_count(pathValue) ~= 1
            error('SIMPLE:Step2Identity:UnsafeHardLink', ...
                'A governed tree contains a hard-linked file.');
        end
        type = 'file';
    else
        error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
            'A governed tree contains a special filesystem object.');
    end
    nodes(end + 1) = struct('absolute', pathValue, 'type', type); %#ok<AGROW>
    if items(index).isdir
        nodes = walk_directory(pathValue, nodes);
    end
end
end

function require_immediate_registry(T)
required = {'subjectID', 'sessionID', 'runID', 'path_raw', 'EEGfile_raw'};
if ~istable(T) || ~isequal(T.Properties.VariableNames, required) || height(T) < 1
    error('SIMPLE:Step2Identity:NotImmediatePostStep29', ...
        'Step 2.10 requires the exact five-column Step 2.9 registry.');
end
end

function assert_no_downstream(root)
for leaf = {'info', 'processed', 'summary', 'results', 'jasp'}
    folder = fullfile(root, 'data', leaf{1});
    if path_object_exists(folder) && ...
            (~isfolder(folder) || is_symbolic_link(folder) || ...
            folder_has_material(folder))
        error('SIMPLE:Step2Identity:DownstreamStateExists', ...
            'Material Step 3-or-later state exists.');
    end
end
logs = fullfile(root, 'data', 'logs');
if path_object_exists(logs) && ...
        (~isfolder(logs) || is_symbolic_link(logs))
    error('SIMPLE:Step2Identity:DownstreamStateExists', 'The workflow log folder is redirected.');
elseif isfolder(logs)
    entries = dir(logs);
    names = string({entries(~[entries.isdir]).name});
    if any(~cellfun(@isempty, regexp(cellstr(names), '^step_[3-9]_', 'once')))
        error('SIMPLE:Step2Identity:DownstreamStateExists', 'Step 3-or-later logs already exist.');
    end
end
end

function tf = folder_has_material(folder)
entries = directory_entries(folder);
entries = entries(~strcmp({entries.name}, '.DS_Store'));
tf = false;
for index = 1:numel(entries)
    pathValue = fullfile(folder, entries(index).name);
    if ~entries(index).isdir || is_symbolic_link(pathValue) || folder_has_material(pathValue)
        tf = true;
        return
    end
end
end

function assert_one_store(paths)
if is_symbolic_link(paths.data) || is_symbolic_link(fileparts(paths.registry))
    error('SIMPLE:Step2Identity:NonLocalVolume', 'Step 2.10 paths must not be redirected.');
end
reference = file_store(paths.data);
values = {paths.registry, paths.preliminary, paths.raw, ...
    paths.raw_orig, paths.workspace, paths.raw_candidate};
for index = 1:numel(values)
    if path_object_exists(values{index}) && ~file_store(values{index}).equals(reference)
        error('SIMPLE:Step2Identity:CrossVolumeTransaction', ...
            'Step 2.10 requires one local filesystem.');
    end
end
end

function store = file_store(pathValue)
try
    store = java.nio.file.Files.getFileStore(java.io.File(pathValue).toPath());
    type = lower(char(store.type()));
catch
    error('SIMPLE:Step2Identity:FileStoreCheckUnavailable', ...
        'The Step 2.10 filesystem could not be verified.');
end
if any(contains(type, {'nfs', 'smb', 'cifs', 'afp', 'webdav', 'sshfs', 'fuse', 'network'}))
    error('SIMPLE:Step2Identity:NonLocalVolume', 'Step 2.10 requires a local filesystem.');
end
end

function assert_space(root, required, options)
available = options.usable_bytes;
if isnan(available)
    available = double(java.io.File(root).getUsableSpace());
end
if available < required
    error('SIMPLE:Step2Identity:InsufficientSpace', ...
        'Step 2.10 does not have enough local working space.');
end
end

function create_workspace(pathValue)
if path_object_exists(pathValue)
    unknown_recovery();
end
safe_mkdir(pathValue);
if ~isempty(directory_entries(pathValue))
    unknown_recovery();
end
end

function safe_mkdir(pathValue)
if ~isfolder(pathValue)
    try
        made = mkdir(pathValue);
    catch
        made = false;
    end
    if ~made
        error('SIMPLE:Step2Identity:DirectoryCreateFailed', ...
            'A required candidate directory could not be created.');
    end
end
if is_symbolic_link(pathValue)
    unknown_recovery();
end
end

function atomic_move(source, destination)
if ~path_object_exists(source) || path_object_exists(destination)
    unknown_recovery();
end
options = javaArray('java.nio.file.CopyOption', 1);
options(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
try
    java.nio.file.Files.move(java.io.File(source).toPath(), ...
        java.io.File(destination).toPath(), options);
catch
    error('SIMPLE:Step2Identity:AtomicMoveFailed', 'A same-filesystem atomic rename failed.');
end
end

function delete_regular(pathValue)
if ~regular_file(pathValue)
    unknown_recovery();
end
delete(pathValue);
end

function remove_verified_tree(pathValue)
if ~isfolder(pathValue) || is_symbolic_link(pathValue)
    unknown_recovery();
end
try
    removed = rmdir(pathValue, 's');
catch
    removed = false;
end
if ~removed
    error('SIMPLE:Step2Identity:CandidateCleanupFailed', ...
        'A verified candidate tree could not be removed.');
end
end

function remove_empty_directory(pathValue)
if ~isfolder(pathValue) || is_symbolic_link(pathValue) || ~isempty(directory_entries(pathValue))
    unknown_recovery();
end
rmdir(pathValue);
end

function tf = regular_file(pathValue)
tf = path_object_exists(pathValue) && ~is_symbolic_link(pathValue) && ...
    java.io.File(pathValue).isFile() && hard_link_count(pathValue) == 1;
end

function count = hard_link_count(pathValue)
try
    options = javaArray('java.nio.file.LinkOption', 0);
    count = double(java.nio.file.Files.getAttribute( ...
        java.io.File(pathValue).toPath(), 'unix:nlink', options));
catch
    error('SIMPLE:Step2Identity:HardLinkInspectionFailed', ...
        'A governed file hard-link count could not be verified.');
end
end

function digest = sha256_file(pathValue)
fid = fopen(char(pathValue), 'rb');
if fid < 0
    error('SIMPLE:Step2Identity:FileReadFailed', 'A governed file could not be read.');
end
cleanup = onCleanup(@() fclose(fid));
engine = java.security.MessageDigest.getInstance('SHA-256');
remainingBytes = double(java.io.File(pathValue).length());
while remainingBytes > 0
    [bytes, count] = fread(fid, ...
        min(1024 * 1024, remainingBytes), '*uint8');
    if count > 0
        engine.update(reshape(typecast(bytes(:), 'int8'), 1, []));
    end
    remainingBytes = remainingBytes - count;
    if count == 0
        break
    end
end
if remainingBytes ~= 0 || ~isempty(ferror(fid))
    error('SIMPLE:Step2Identity:FileReadFailed', ...
        'A governed file could not be read completely.');
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', 1, []));
end

function tf = is_hash(value)
tf = ischar(value) && ~isempty(regexp(value, '^[0-9a-f]{64}$', 'once'));
end

function items = directory_entries(pathValue)
items = dir(pathValue);
items = items(~ismember({items.name}, {'.', '..'}));
end

function assert_bindings(root)
for name = {'inspect_identity_state', 'load_dataset_identity_registry', ...
        'build_pseudonymised_dataset_registry', ...
        'inspect_pseudonymisation_inputs'}
    active = which(name{1});
    expected = fullfile(root, 'functions', [name{1} '.m']);
    if isempty(active) || ~canonical_equal(active, expected)
        error('SIMPLE:Step2Identity:HelperResolution', ...
            'A required repository-local helper is not active.');
    end
end
end

function tf = canonical_equal(first, second)
first = char(java.io.File(first).getCanonicalPath());
second = char(java.io.File(second).getCanonicalPath());
if ispc
    tf = strcmpi(first, second);
else
    tf = strcmp(first, second);
end
end

function tf = path_object_exists(pathValue)
tf = java.io.File(pathValue).exists() || is_symbolic_link(pathValue);
end

function tf = is_symbolic_link(pathValue)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(pathValue).toPath());
end

function result = make_result(status, state, rows, bytes)
result = struct('status', string(status), 'state', string(state), ...
    'row_count', double(rows), 'admitted_bytes', double(bytes));
end

function unknown_recovery()
error('SIMPLE:Step2Identity:RecoveryRefused', ...
    ['The Step 2.10 transaction state is not recognised. It was left ' ...
     'untouched for manual review.']);
end
