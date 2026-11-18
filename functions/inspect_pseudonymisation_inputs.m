function snapshot = inspect_pseudonymisation_inputs( ...
        repositoryRoot, original, sourceRoot)
%INSPECT_PSEUDONYMISATION_INPUTS Verify original identifier-route inputs.
%
% This read-only helper reconciles the two registries, classifies the
% complete original raw inventory, and confirms that admitted SET files are
% self-contained. It returns only the snapshot required by the transaction.

preliminaryPath = fullfile(repositoryRoot, 'data_lists', ...
    'dataset_list_prelim.xlsx');
require_regular_file(preliminaryPath);
if ~isfolder(sourceRoot) || is_symbolic_link(sourceRoot)
    error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
        'The original raw tree must be one real directory.');
end

preliminary = read_preliminary(preliminaryPath);
if ~isequal(original, preliminary.expected_original)
    error('SIMPLE:Step2Identity:PreliminaryMismatch', ...
        'The final and preliminary registries do not agree.');
end
try
    validate_dataset_registry_paths(preliminary.excluded, ...
        repositoryRoot, 'raw');
catch ME
    if startsWith(string(ME.identifier), "SIMPLE:DatasetRegistry:")
        error('SIMPLE:Step2Identity:InvalidExcludedTarget', ...
            'A declared excluded raw target is invalid.');
    end
    rethrow(ME)
end
mapped = build_pseudonymised_dataset_registry(original);
allSubjects = unique(preliminary.all_subjects( ...
    preliminary.all_subjects ~= ""), 'stable');
if any(ismember(allSubjects, unique(mapped.subjectID, 'stable')))
    error('SIMPLE:Step2Identity:SubjectNamespaceOverlap', ...
        'The original and replacement subject namespaces overlap.');
end

[admitted, excludedPresent, nodes] = inspect_inventory(sourceRoot, original, ...
    preliminary.excluded);
hashes = strings(height(original), 1);
sizes = zeros(height(original), 1);
fileNodes = nodes(string({nodes.type}) == "file");
filePaths = string({fileNodes.absolute}).';
for row = 1:height(original)
    hashes(row) = string(fileNodes(filePaths == admitted(row)).hash);
    details = dir(admitted(row));
    sizes(row) = details.bytes;
end
verify_embedded_sets(admitted);
snapshot = struct('original', original, 'mapped', mapped, ...
    'admitted_files', admitted, 'source_hashes', hashes, ...
    'admitted_bytes', sum(sizes), ...
    'excluded_present_count', excludedPresent, ...
    'registry_hash', '', ...
    'preliminary_hash', sha256_file(preliminaryPath), ...
    'raw_tree_hash', hash_tree(sourceRoot, nodes), ...
    'privacy_tokens', preliminary.privacy_tokens, ...
    'subject_privacy_tokens', preliminary.subject_privacy_tokens);
end

function preliminary = read_preliminary(pathValue)
required = {'subjectID', 'sessionID', 'runID', 'excluded_datasets', ...
    'channel_exclusion', 'EEGfile_reformatted', 'path_reformatted', ...
    'included_datasets'};
try
    opts = detectImportOptions(pathValue, 'FileType', 'spreadsheet');
    if ~all(ismember(required, opts.VariableNames))
        error('missing');
    end
    require_text_source_types(opts, {'subjectID', 'sessionID', 'runID'});
    opts = setvartype(opts, required, 'string');
    T = readtable(pathValue, opts);
catch ME
    if strcmp(ME.identifier, ...
            'SIMPLE:Step2Identity:IdentityColumnsMustBeText')
        rethrow(ME)
    end
    error('SIMPLE:Step2Identity:InvalidPreliminaryRegistry', ...
        'The preliminary registry could not be read safely.');
end
for index = 1:numel(required)
    values = string(T.(required{index}));
    values(ismissing(values)) = "";
    T.(required{index}) = strtrim(values(:));
end
excluded = lower(T.excluded_datasets);
channel = lower(T.channel_exclusion);
included = excluded == "" & channel == "";
expectedFlags = strings(height(T), 1);
expectedFlags(included) = "included";
if any(~ismember(excluded, ["", "excluded"])) || ...
        any(~ismember(channel, ["", "excluded"])) || ...
        ~isequal(T.included_datasets, expectedFlags)
    error('SIMPLE:Step2Identity:InvalidPreliminaryRegistry', ...
        'The preliminary inclusion coding is inconsistent.');
end
preliminary.expected_original = table(T.subjectID(included), ...
    T.sessionID(included), T.runID(included), ...
    T.path_reformatted(included), T.EEGfile_reformatted(included), ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'});
preliminary.expected_original = sortrows(preliminary.expected_original, ...
    {'subjectID', 'sessionID', 'runID'});
preliminary.all_subjects = T.subjectID;
[preliminary.privacy_tokens, preliminary.subject_privacy_tokens] = ...
    collect_privacy_tokens(T);
partial = ~included & xor(T.path_reformatted ~= "", ...
    T.EEGfile_reformatted ~= "");
if any(partial)
    error('SIMPLE:Step2Identity:InvalidExcludedTarget', ...
        'A declared excluded raw target is incomplete.');
end
declared = ~included & T.path_reformatted ~= "" & ...
    T.EEGfile_reformatted ~= "";
excludedPaths = T.path_reformatted(declared);
excludedNames = T.EEGfile_reformatted(declared);
preliminary.excluded = table(excludedPaths(:), excludedNames(:), ...
    'VariableNames', {'path_raw', 'EEGfile_raw'});
end

function require_text_source_types(opts, names)
allowed = ["char", "string", "categorical"];
for index = 1:numel(names)
    column = find(strcmp(opts.VariableNames, names{index}), 1, 'first');
    if isempty(column) || ...
            ~ismember(lower(string(opts.VariableTypes{column})), allowed)
        error('SIMPLE:Step2Identity:IdentityColumnsMustBeText', ...
            'Subject, session, and run identifiers must be stored as text.');
    end
end
end

function [admitted, excludedPresent, nodes] = inspect_inventory( ...
        root, original, excludedTable)
nodes = walk_tree(root);
types = string({nodes.type});
files = nodes(types == "file");
admitted = strings(height(original), 1);
for row = 1:height(original)
    admitted(row) = target_in_root(root, original.path_raw(row), ...
        original.EEGfile_raw(row));
end
excluded = strings(height(excludedTable), 1);
for index = 1:height(excludedTable)
    excluded(index) = target_in_root(root, excludedTable.path_raw(index), ...
        excludedTable.EEGfile_raw(index));
end
declared = [admitted; excluded];
if numel(unique(lower(declared), 'stable')) ~= numel(declared)
    error('SIMPLE:Step2Identity:FilesystemTargetCollision', ...
        'Declared raw targets collide on a case-insensitive filesystem.');
end
actual = string({files.absolute}).';
if any(arrayfun(@(row) nnz(actual == admitted(row)) ~= 1, ...
        1:numel(admitted)))
    error('SIMPLE:Step2Identity:MissingAdmittedSet', ...
        'An admitted SET is missing from the original raw tree.');
end
for index = 1:numel(actual)
    [~, name, extension] = fileparts(actual(index));
    basename = string(name) + string(extension);
    if basename ~= ".DS_Store" && ~any(actual(index) == declared)
        if strcmpi(extension, '.set')
            error('SIMPLE:Step2Identity:UnknownRawSet', ...
                'The original raw tree contains an undeclared SET file.');
        end
        error('SIMPLE:Step2Identity:UnknownRawFile', ...
            'The original raw tree contains an undeclared file.');
    end
end
excludedPresent = nnz(ismember(excluded, actual));
end

function [tokens, subjectTokens] = collect_privacy_tokens(T)
subjectTokens = strtrim(T.subjectID);
subjectTokens = unique(subjectTokens(~ismissing(subjectTokens) & ...
    subjectTokens ~= ""), 'stable');
tokens = strings(0, 1);
for name = {'sessionID', 'runID'}
    values = T.(name{1});
    generic = ~cellfun(@isempty, regexp(cellstr(values), '^\d{1,2}$', 'once'));
    tokens = [tokens; values(~generic)]; %#ok<AGROW>
end
tokens = collect_reference_tokens(tokens, T);
tokens = strtrim(tokens);
tokens = unique(tokens(~ismissing(tokens) & tokens ~= ""), 'stable');
end

function tokens = collect_reference_tokens(tokens, T)
for variableIndex = 1:width(T)
    variableName = T.Properties.VariableNames{variableIndex};
    try
        values = string(T.(variableName));
    catch
        continue
    end
    if numel(values) ~= height(T)
        continue
    end
    values = reshape(values, [], 1);
    nonblank = ~ismissing(values) & strlength(strtrim(values)) > 0;
    if ~any(nonblank)
        continue
    end
    [pathColumn, fileColumn] = reference_header(variableName);
    placeholders = false(size(values));
    placeholders(nonblank) = arrayfun(@missing_marker, values(nonblank));
    referenceValues = nonblank & ~placeholders;
    inferredFileColumn = any(referenceValues) && ...
        all(arrayfun(@credible_filename, values(referenceValues)));
    for rawReference = reshape(values, 1, [])
        if ismissing(rawReference) || strlength(strtrim(rawReference)) == 0
            continue
        end
        value = strtrim(rawReference);
        if missing_marker(value)
            continue
        end
        normalised = replace(value, '\', '/');
        explicitReference = explicit_path(normalised);
        if ~(pathColumn || fileColumn || inferredFileColumn || ...
                explicitReference)
            continue
        end
        tokens(end + 1, 1) = value; %#ok<AGROW>
        [~, stem, extension] = fileparts(char(normalised));
        filenameReference = fileColumn || inferredFileColumn || ...
            ((pathColumn || explicitReference) && ~isempty(extension)) || ...
            credible_filename(string(stem) + string(extension));
        tokens = add_distinctive_component( ...
            tokens, string(stem), filenameReference);
        basename = string(stem) + string(extension);
        firstDot = regexp(char(basename), '\.', 'once');
        if ~isempty(firstDot) && firstDot > 1
            tokens = add_distinctive_component(tokens, ...
                extractBefore(basename, firstDot), filenameReference);
        end
        for component = reshape(split(normalised, '/'), 1, [])
            tokens = add_distinctive_component(tokens, component, false);
        end
    end
end
end

function [pathColumn, fileColumn] = reference_header(name)
splitName = regexprep(name, '([A-Z]+)([A-Z][a-z])', '$1_$2');
splitName = regexprep(splitName, '([a-z0-9])([A-Z])', '$1_$2');
words = regexp(lower(splitName), '[a-z0-9]+', 'match');
pathNames = {'path', 'filepath', 'folder', 'directory'};
fileNames = {'file', 'filename'};
compact = regexprep(lower(name), '[^a-z0-9]', '');
prefixes = ['(eeg|source|original|raw|input|output|data|header|event|' ...
    'events|urevent|urevents|recording|dataset|project|repository|' ...
    'remote|local|server|study)*'];
pathColumn = any(ismember(words, pathNames)) || ...
    any(strcmp(compact, {'root', 'dir'})) || ~isempty(regexp(compact, ...
    ['^' prefixes '(path|filepath|folder|directory|dir|root)' ...
    '(reformatted|in|out)?$'], 'once'));
fileColumn = any(ismember(words, fileNames)) || ~isempty(regexp(compact, ...
    ['^' prefixes '(file|filename)(reformatted|in|out)?$'], 'once'));
end

function tf = explicit_path(value)
text = char(value);
tf = any(startsWith(value, ["/", "~/", "./", "../", "//"])) || ...
    ~isempty(regexp(text, '^[A-Za-z]:[\\/]', 'once')) || ...
    ~isempty(regexp(text, '^[A-Za-z][A-Za-z0-9+.-]*://', 'once'));
end

function tf = missing_marker(value)
markers = ["none", "n/a", "na", "not applicable", "not available", ...
    "unknown", "missing", "not recorded", "<missing>", "-"];
tf = ismissing(value) || ismember(lower(strtrim(string(value))), markers);
end

function tf = credible_filename(value)
normalised = replace(strtrim(string(value)), '\', '/');
if ismissing(normalised) || contains(normalised, '/')
    tf = false;
    return
end
[~, stem, extension] = fileparts(char(normalised));
extensions = {'.set', '.fdt', '.mat', '.vhdr', '.vmrk', '.dat', '.cdt', ...
    '.dpa', '.ceo', '.cef', '.dap', '.rs3', '.xdf', '.csv', '.tsv', ...
    '.xls', '.xlsx', '.txt', '.json', '.edf', '.bdf', '.cnt', '.eeg', ...
    '.nii', '.gz', '.xml'};
tf = ~isempty(stem) && any(strcmpi(extension, extensions));
end

function tokens = add_distinctive_component(tokens, value, allowShortNumeric)
rawValue = strtrim(value);
genericSessionRun = ~allowShortNumeric && ~isempty(regexp(char(rawValue), ...
    '^(ses|run)-\d{1,2}$', 'once', 'ignorecase'));
if allowShortNumeric
    value = rawValue;
else
    value = regexprep(rawValue, '^(sub|ses|run)-', '', 'ignorecase');
end
genericShortNumeric = ~allowShortNumeric && ...
    ~isempty(regexp(char(value), '^\d{1,2}$', 'once'));
generic = ["", "data", "raw", "raw_orig", "source", "eeg", ...
    "users", "home", "volumes", "mnt", "media", "archive", ...
    "archives", "documents", "downloads", "desktop", "private", ...
    "external", "tmp", "var", "~", ".", ".."];
if ~isempty(regexp(char(value), '^[A-Za-z]:$', 'once'))
    value = "";
end
if ~genericSessionRun && ~genericShortNumeric && ...
        ~ismember(lower(value), generic)
    tokens(end + 1, 1) = value;
end
end

function target = target_in_root(root, pathValue, filename)
relative = extractAfter(string(pathValue), strlength("data/raw/"));
parts = cellstr(split(relative, '/'));
target = string(fullfile(root, parts{:}, char(filename)));
end

function verify_embedded_sets(files)
for row = 1:numel(files)
    try
        stored = load('-mat', char(files(row)));
    catch
        error('SIMPLE:Step2Identity:UnreadableSet', ...
            'SET row %d is unreadable.', row);
    end
    if isfield(stored, 'EEG') && isscalar(fieldnames(stored)) && ...
            isstruct(stored.EEG) && isscalar(stored.EEG)
        EEG = stored.EEG;
    elseif isfield(stored, 'data') && ~isfield(stored, 'EEG')
        EEG = stored;
    else
        error('SIMPLE:Step2Identity:UnsupportedSetLayout', ...
            'SET row %d has an unsupported layout.', row);
    end
    if isfield(EEG, 'datfile') && ~empty_text(EEG.datfile)
        error('SIMPLE:Step2Identity:ExternalDataDependency', ...
            'SET row %d uses external data.', row);
    end
    if ~isfield(EEG, 'data') || ~isnumeric(EEG.data) || isempty(EEG.data)
        if isfield(EEG, 'data') && ...
                (ischar(EEG.data) || isstring(EEG.data)) && ...
                ~empty_text(EEG.data)
            error('SIMPLE:Step2Identity:ExternalDataDependency', ...
                'SET row %d uses external data.', row);
        end
        error('SIMPLE:Step2Identity:MissingEmbeddedData', ...
            'SET row %d lacks embedded numeric data.', row);
    end
end
end

function tf = empty_text(value)
tf = isempty(value) || ((ischar(value) || isstring(value)) && ...
    all(strlength(string(value)) == 0));
end

function nodes = walk_tree(root)
nodes = struct('absolute', {}, 'type', {}, 'hash', {});
nodes = walk_directory(root, nodes);
end

function nodes = walk_directory(folder, nodes)
items = dir(folder);
items = items(~ismember({items.name}, {'.', '..'}));
for index = 1:numel(items)
    pathValue = fullfile(folder, items(index).name);
    if is_symbolic_link(pathValue)
        error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
            'The original raw tree contains a symbolic link.');
    elseif items(index).isdir
        type = 'directory';
        hash = '';
    elseif java.io.File(pathValue).isFile()
        if hard_link_count(pathValue) ~= 1
            error('SIMPLE:Step2Identity:UnsafeHardLink', ...
                'The original raw tree contains a hard-linked file.');
        end
        type = 'file';
        if strcmp(items(index).name, '.DS_Store')
            hash = '';
        else
            hash = sha256_file(pathValue);
        end
    else
        error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
            'The original raw tree contains a special filesystem object.');
    end
    nodes(end + 1) = struct( ...
        'absolute', pathValue, 'type', type, 'hash', hash); %#ok<AGROW>
    if items(index).isdir
        nodes = walk_directory(pathValue, nodes);
    end
end
end

function digest = hash_tree(root, nodes)
root = [canonical_path(root) filesep];
relative = strings(numel(nodes), 1);
for index = 1:numel(nodes)
    absolute = string(canonical_path(nodes(index).absolute));
    if ~startsWith(absolute, string(root))
        error('SIMPLE:Step2Identity:UnsafeRawInventory', ...
            'The original raw tree contains an escaped object.');
    end
    relative(index) = replace(extractAfter(absolute, strlength(root)), ...
        filesep, '/');
end
finderMetadata = false(numel(nodes), 1);
for index = 1:numel(nodes)
    [~, name, extension] = fileparts(nodes(index).absolute);
    finderMetadata(index) = strcmp(nodes(index).type, 'file') && ...
        strcmp([name extension], '.DS_Store');
end
relative = relative(~finderMetadata);
nodes = nodes(~finderMetadata);
[relative, order] = sort(relative);
nodes = nodes(order);
engine = java.security.MessageDigest.getInstance('SHA-256');
update_digest(engine, unicode2native('simple-raw-tree-v1', 'UTF-8'));
for index = 1:numel(nodes)
    pathBytes = unicode2native(char(relative(index)), 'UTF-8');
    header = sprintf('%s:%d:', nodes(index).type, numel(pathBytes));
    update_digest(engine, unicode2native(header, 'UTF-8'));
    update_digest(engine, pathBytes);
    update_digest(engine, uint8(0));
    update_digest(engine, unicode2native(nodes(index).hash, 'UTF-8'));
    update_digest(engine, uint8(0));
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end

function update_digest(engine, bytes)
if isempty(bytes)
    return
end
engine.update(reshape(typecast(uint8(bytes(:)), 'int8'), 1, []));
end

function require_regular_file(pathValue)
if ~isfile(pathValue) || is_symbolic_link(pathValue) || ...
        hard_link_count(pathValue) ~= 1
    error('SIMPLE:Step2Identity:UnsafeFile', ...
        'The preliminary registry must be one regular, singly linked file.');
end
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
fid = fopen(char(pathValue), 'rb');
if fid < 0
    error('SIMPLE:Step2Identity:FileReadFailed', ...
        'A governed file could not be read.');
end
cleanup = onCleanup(@() fclose(fid));
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
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end

function tf = is_symbolic_link(pathValue)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(pathValue).toPath());
end

function value = canonical_path(value)
value = char(java.io.File(char(value)).getCanonicalPath());
end
