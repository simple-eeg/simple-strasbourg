function identity = load_dataset_identity_registry(datasetListPath)
%LOAD_DATASET_IDENTITY_REGISTRY Import and validate the identity registry.
%
% identity = load_dataset_identity_registry(datasetListPath)
%
% The registry schema alone determines original or mapped mode. Every
% identifier, path, and filename is imported as exact text before validation.

if ~(ischar(datasetListPath) || ...
        (isstring(datasetListPath) && isscalar(datasetListPath)))
    error('SIMPLE:Step2Identity:InvalidRegistryPath', ...
        'datasetListPath must be one character vector or string scalar.');
end
datasetListPath = char(string(datasetListPath));
if ~isfile(datasetListPath)
    error('SIMPLE:Step2Identity:MissingRegistry', ...
        'The dataset registry does not exist.');
end
if is_symbolic_link(datasetListPath)
    error('SIMPLE:Step2Identity:UnsafeRegistry', ...
        'The dataset registry must not be a symbolic link.');
end

registryCanonical = canonical_path(datasetListPath);
[dataListsDir, basename, extension] = fileparts(registryCanonical);
[activeRepositoryRoot, ~, ~] = fileparts(dataListsDir);
activeLocation = canonical_equal(dataListsDir, ...
    fullfile(activeRepositoryRoot, 'data_lists')) && ...
    strcmp([basename extension], 'dataset_list.csv');
repositoryRoot = activeRepositoryRoot;
lockedLocation = false;
if ~activeLocation && ...
        strcmp([basename extension], 'dataset_list.locked.csv')
    [dataDir, ~, ~] = fileparts(dataListsDir);
    [lockedRepositoryRoot, dataLeaf, dataExtension] = fileparts(dataDir);
    expected10 = fullfile(lockedRepositoryRoot, 'data', ...
        '.step_2_raw_10_transaction');
    expected11 = fullfile(lockedRepositoryRoot, 'data', ...
        '.step_2_raw_11_transaction');
    lockedLocation = strcmp([dataLeaf dataExtension], 'data') && ...
        (canonical_equal(dataListsDir, expected10) || ...
        canonical_equal(dataListsDir, expected11));
    repositoryRoot = lockedRepositoryRoot;
end
if ~(activeLocation || lockedLocation)
    error('SIMPLE:Step2Identity:InvalidRegistryLocation', ...
        ['The registry must be the active dataset_list.csv or an exact ' ...
         'transaction-owned locked registry.']);
end

builderPath = which('build_pseudonymised_dataset_registry');
expectedBuilder = fullfile(repositoryRoot, 'functions', ...
    'build_pseudonymised_dataset_registry.m');
if isempty(builderPath) || ~canonical_equal(builderPath, expectedBuilder)
    error('SIMPLE:Step2Identity:HelperResolution', ...
        'The repository-local pseudonymised-registry builder is not active.');
end

originalCore = {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'};
mappedCore = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'subjectID', 'sessionID', 'runID', 'path_raw_orig', 'path_raw', ...
    'EEGfile_raw_orig', 'EEGfile_raw'};
mappedOnly = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'path_raw_orig', 'EEGfile_raw_orig'};
allIdentityColumns = unique([mappedCore, originalCore], 'stable');

opts = detectImportOptions(registryCanonical, 'FileType', 'text', ...
    'Delimiter', ',');
names = opts.VariableNames;
mappedPresent = ismember(mappedOnly, names);
if any(mappedPresent) && ~all(mappedPresent)
    error('SIMPLE:Step2Identity:PartialMappedSchema', ...
        'The dataset registry contains only part of the mapped identity schema.');
elseif all(mappedPresent)
    mode = "mapped";
    requiredCore = mappedCore;
else
    mode = "original";
    requiredCore = originalCore;
end
if numel(names) < numel(requiredCore) || ...
        ~isequal(names(1:numel(requiredCore)), requiredCore)
    error('SIMPLE:Step2Identity:InvalidColumnOrder', ...
        'The dataset registry does not begin with the required identity columns.');
end
missing = setdiff(requiredCore, names, 'stable');
if ~isempty(missing)
    error('SIMPLE:Step2Identity:MissingColumns', ...
        'The dataset registry is missing required identity columns.');
end

presentText = intersect(allIdentityColumns, names, 'stable');
opts = force_import_strings(opts, presentText);
T = readtable(registryCanonical, opts);
T = validate_text_columns(T, presentText, mode);
if height(T) == 0
    error('SIMPLE:Step2Identity:EmptyRegistry', ...
        'The dataset registry contains no admitted recordings.');
end

if mode == "original"
    assert_unique_tuples(T, {'subjectID', 'sessionID', 'runID'}, ...
        'SIMPLE:Step2Identity:DuplicateOriginalTuple');
    originalSubjectIDs = unique(T.subjectID, 'stable');
    canonicalSubjectIDs = originalSubjectIDs;
    participantMap = table(originalSubjectIDs, canonicalSubjectIDs, ...
        'VariableNames', {'sourceSubjectID', 'subjectID'});
else
    assert_unique_tuples(T, ...
        {'subjectID_orig', 'sessionID_orig', 'runID_orig'}, ...
        'SIMPLE:Step2Identity:DuplicateOriginalTuple');
    assert_unique_tuples(T, {'subjectID', 'sessionID', 'runID'}, ...
        'SIMPLE:Step2Identity:DuplicateCanonicalTuple');

    originalView = table(T.subjectID_orig, T.sessionID_orig, T.runID_orig, ...
        replace_raw_orig_prefix(T.path_raw_orig), T.EEGfile_raw_orig, ...
        'VariableNames', originalCore);
    expected = build_pseudonymised_dataset_registry(originalView);
    for columnIndex = 1:numel(mappedCore)
        name = mappedCore{columnIndex};
        if ~isequal(T.(name), expected.(name))
            error('SIMPLE:Step2Identity:InvalidMapping', ...
                ['Mapped registry column %s is inconsistent with stable ' ...
                 'first-appearance numbering at one or more rows.'], name);
        end
    end

    originalSubjectIDs = unique(T.subjectID_orig, 'stable');
    canonicalSubjectIDs = strings(numel(originalSubjectIDs), 1);
    for subjectIndex = 1:numel(originalSubjectIDs)
        rows = T.subjectID_orig == originalSubjectIDs(subjectIndex);
        mappedValues = unique(T.subjectID(rows), 'stable');
        if numel(mappedValues) ~= 1
            error('SIMPLE:Step2Identity:ParticipantMappingConflict', ...
                'Mapped registry participant correspondence is not one-to-one.');
        end
        canonicalSubjectIDs(subjectIndex) = mappedValues;
    end
    if numel(unique(canonicalSubjectIDs, 'stable')) ~= ...
            numel(canonicalSubjectIDs)
        error('SIMPLE:Step2Identity:ParticipantMappingConflict', ...
            'Mapped registry participant correspondence is not bijective.');
    end
    if any(ismember(originalSubjectIDs, canonicalSubjectIDs))
        error('SIMPLE:Step2Identity:SubjectNamespaceOverlap', ...
            'Original and replacement subject namespaces must be disjoint.');
    end
    participantMap = table(originalSubjectIDs, canonicalSubjectIDs, ...
        'VariableNames', {'sourceSubjectID', 'subjectID'});
end

validatorPath = which('validate_dataset_registry_paths');
expectedValidator = fullfile(repositoryRoot, 'functions', ...
    'validate_dataset_registry_paths.m');
if isempty(validatorPath) || ...
        ~canonical_equal(validatorPath, expectedValidator)
    error('SIMPLE:Step2Identity:HelperResolution', ...
        'The repository-local dataset path validator is not active.');
end
targets = validate_dataset_registry_paths(T, repositoryRoot, 'raw');

identity = struct();
identity.mode = mode;
identity.table = T;
identity.recording_count = height(T);
identity.canonical_subject_ids = canonicalSubjectIDs(:);
identity.original_subject_ids = originalSubjectIDs(:);
identity.participant_map = participantMap;
identity.repository_root = repositoryRoot;
identity.targets = targets;
end

function opts = force_import_strings(opts, columns)
try
    opts = setvartype(opts, columns, 'string');
catch
    variableTypes = opts.VariableTypes;
    for columnIndex = 1:numel(columns)
        index = find(strcmp(opts.VariableNames, columns{columnIndex}), ...
            1, 'first');
        if ~isempty(index)
            variableTypes{index} = 'string';
        end
    end
    opts.VariableTypes = variableTypes;
end
end

function T = validate_text_columns(T, columns, mode)
for columnIndex = 1:numel(columns)
    name = columns{columnIndex};
    try
        values = string(T.(name));
    catch
        invalid_text(mode, name);
    end
    if ~iscolumn(values) || numel(values) ~= height(T)
        invalid_text(mode, name);
    end
    values = values(:);
    if any(ismissing(values) | strlength(values) == 0 | ...
            values ~= strtrim(values))
        invalid_text(mode, name);
    end
    T.(name) = values;
end
end

function invalid_text(mode, name)
if mode == "mapped" && endsWith(string(name), "_orig")
    error('SIMPLE:Step2Identity:InvalidTextValue', ...
        'A mapped original-side identity column is blank or unnormalised.');
end
error('SIMPLE:Step2Identity:InvalidTextValue', ...
    'Identity column %s is blank, missing, or unnormalised.', name);
end

function values = replace_raw_orig_prefix(values)
prefix = "data/raw_orig/";
if any(~startsWith(values, prefix))
    error('SIMPLE:Step2Identity:InvalidOriginalPath', ...
        'Mapped original-side paths must remain under data/raw_orig.');
end
values = "data/raw/" + extractAfter(values, strlength(prefix));
end

function assert_unique_tuples(T, columns, identifier)
for row = 2:height(T)
    prior = true(row - 1, 1);
    for columnIndex = 1:numel(columns)
        values = T.(columns{columnIndex});
        prior = prior & values(1:row - 1) == values(row);
    end
    if any(prior)
        error(identifier, ...
            'Recording tuples must be unique; duplicate encountered at row %d.', ...
            row);
    end
end
end

function tf = is_symbolic_link(pathValue)
file = java.io.File(pathValue);
tf = java.nio.file.Files.isSymbolicLink(file.toPath());
end

function value = canonical_path(value)
value = char(java.io.File(value).getCanonicalPath());
end

function tf = canonical_equal(first, second)
first = canonical_path(char(first));
second = canonical_path(char(second));
if ispc
    tf = strcmpi(first, second);
else
    tf = strcmp(first, second);
end
end
