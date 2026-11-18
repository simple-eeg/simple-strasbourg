function state = inspect_identity_state(repositoryRoot)
%INSPECT_IDENTITY_STATE Classify the optional Step 2 identity state.
%
% This read-only guard deliberately stays high level. Transaction helpers
% perform exact manifest, inventory, and recovery verification.

repositoryRoot = validate_root(repositoryRoot);
paths = make_paths(repositoryRoot);
state = struct('name', "unknown", 'message', "State is not recognised.", ...
    'identity', [], 'paths', paths, ...
    'workspace_2_10_exists', path_object_exists(paths.workspace_2_10), ...
    'workspace_2_11_exists', path_object_exists(paths.workspace_2_11));

if state.workspace_2_10_exists || state.workspace_2_11_exists
    if state.workspace_2_10_exists && state.workspace_2_11_exists
        state.message = "Both Step 2 transaction workspaces exist.";
    elseif state.workspace_2_10_exists && ...
            recognised_workspace(paths.workspace_2_10, "step_2_10")
        state.name = "recoverable_step_2_10";
        state.message = "A Step 2.10 transaction workspace exists.";
    elseif state.workspace_2_11_exists && ...
            recognised_workspace(paths.workspace_2_11, "step_2_11")
        state.name = "recoverable_step_2_11";
        state.message = "A Step 2.11 transaction workspace exists.";
    else
        state.message = "A Step 2 transaction workspace is irregular.";
    end
    return
end

registryExists = path_object_exists(paths.registry);
rawExists = path_object_exists(paths.raw);
rawOrigExists = path_object_exists(paths.raw_orig);
if registryExists && ~single_regular_file(paths.registry)
    state.message = "The dataset-registry slot is irregular.";
    return
elseif ~registryExists
    if rawOrigExists
        state.name = "partial";
    elseif ~rawExists || ...
            (isfolder(paths.raw) && ~is_symbolic_link(paths.raw))
        state.name = "empty";
    end
    return
end

try
    identity = load_dataset_identity_registry(paths.registry);
catch
    return
end
state.identity = identity;
if identity.mode == "original"
    if isfolder(paths.raw) && ~is_symbolic_link(paths.raw) && ...
            ~rawOrigExists
        state.name = "original";
        state.message = "The original Step 2 registry is active.";
    else
        state.name = "partial";
    end
    return
end
if ~isfolder(paths.raw) || ~isfolder(paths.raw_orig) || ...
        is_symbolic_link(paths.raw) || is_symbolic_link(paths.raw_orig)
    state.name = "partial";
    return
end

same = true;
for row = 1:identity.recording_count
    source = registry_target(repositoryRoot, ...
        identity.table.path_raw_orig(row), ...
        identity.table.EEGfile_raw_orig(row));
    active = registry_target(repositoryRoot, identity.table.path_raw(row), ...
        identity.table.EEGfile_raw(row));
    if ~single_regular_file(source) || ~single_regular_file(active)
        state.name = "partial";
        return
    end
    same = same && strcmp(sha256_file(source), sha256_file(active));
end
if same
    state.name = "mapped_unsanitised";
    state.message = "Mapped SET files are byte-identical to raw_orig.";
else
    state.name = "mapped_modified";
    state.message = "Mapped SET bytes differ from raw_orig.";
end
end

function paths = make_paths(root)
paths = struct('repository', root, 'data', fullfile(root, 'data'), ...
    'registry', fullfile(root, 'data_lists', 'dataset_list.csv'), ...
    'preliminary', fullfile(root, 'data_lists', ...
    'dataset_list_prelim.xlsx'), ...
    'raw', fullfile(root, 'data', 'raw'), ...
    'raw_orig', fullfile(root, 'data', 'raw_orig'), ...
    'workspace_2_10', fullfile(root, 'data', ...
    '.step_2_raw_10_transaction'), ...
    'workspace_2_11', fullfile(root, 'data', ...
    '.step_2_raw_11_transaction'));
end

function tf = recognised_workspace(workspace, operation)
tf = false;
if ~isfolder(workspace) || is_symbolic_link(workspace)
    return
end
items = directory_entries(workspace);
if isempty(items)
    return
end
names = string({items.name});
if operation == "step_2_10"
    allowed = ["manifest.mat", "manifest.pending.mat", ...
        "dataset_list.locked.csv", "dataset_list.candidate.csv", ...
        "dataset_list.candidate.pending.csv", "raw_candidate", ...
        "copy.pending.set"];
    directorySlots = "raw_candidate";
else
    allowed = ["manifest.mat", "manifest.pending.mat", ...
        "dataset_list.locked.csv", "candidate.set"];
    directorySlots = strings(0, 1);
end
if any(~ismember(names, allowed))
    return
end
for index = 1:numel(items)
    pathValue = fullfile(workspace, items(index).name);
    expectsDirectory = ismember(string(items(index).name), directorySlots);
    if is_symbolic_link(pathValue) || ...
            (expectsDirectory && ~items(index).isdir) || ...
            (~expectsDirectory && ...
            (items(index).isdir || ~single_regular_file(pathValue)))
        return
    end
end
tf = true;
end

function root = validate_root(value)
if ~(ischar(value) || (isstring(value) && isscalar(value)))
    error('SIMPLE:Step2Identity:InvalidRepositoryRoot', ...
        'repositoryRoot must be scalar text.');
end
root = canonical_path(char(string(value)));
if ~isfolder(root) || is_symbolic_link(root)
    error('SIMPLE:Step2Identity:InvalidRepositoryRoot', ...
        'The repository root must be one real directory.');
end
end

function target = registry_target(root, relativePath, filename)
parts = cellstr(split(string(relativePath), '/'));
target = fullfile(root, parts{:}, char(filename));
end

function items = directory_entries(pathValue)
items = dir(pathValue);
items = items(~ismember({items.name}, {'.', '..'}));
end

function tf = single_regular_file(pathValue)
tf = path_object_exists(pathValue) && ~is_symbolic_link(pathValue) && ...
    java.io.File(pathValue).isFile() && hard_link_count(pathValue) == 1;
end

function count = hard_link_count(pathValue)
try
    count = file_hard_link_count(pathValue);
catch
    error('SIMPLE:Step2Identity:HardLinkInspectionFailed', ...
        'A governed file hard-link count could not be verified.');
end
end

function digest = sha256_file(pathValue)
engine = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(pathValue, 'rb');
if fid < 0
    error('SIMPLE:Step2Identity:FileReadFailed', ...
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
    error('SIMPLE:Step2Identity:FileReadFailed', ...
        'A governed file could not be read completely.');
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end

function tf = path_object_exists(pathValue)
tf = java.io.File(pathValue).exists() || is_symbolic_link(pathValue);
end

function tf = is_symbolic_link(pathValue)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(pathValue).toPath());
end

function value = canonical_path(value)
value = char(java.io.File(value).getCanonicalPath());
end
