function targets = validate_dataset_registry_paths(T, baseDir, stage)
%VALIDATE_DATASET_REGISTRY_PATHS Validate all registry paths before writes.
%
% targets = validate_dataset_registry_paths(T, baseDir, stage)
%
% stage is 'raw', 'processed', or 'summary'. Each stage includes every
% preceding contract. The function rejects unsafe input; it never rewrites,
% normalises, or repairs registry values.

if ~istable(T)
    error('SIMPLE:DatasetRegistry:InvalidTable', ...
        'The dataset registry must be a table.');
end
if ~(ischar(baseDir) || (isstring(baseDir) && isscalar(baseDir)))
    error('SIMPLE:DatasetRegistry:InvalidBaseDirectory', ...
        'baseDir must be one character vector or string scalar.');
end
baseDir = char(string(baseDir));
if ~isfolder(baseDir)
    error('SIMPLE:DatasetRegistry:InvalidBaseDirectory', ...
        'Repository root does not exist: %s', baseDir);
end
if ~(ischar(stage) || (isstring(stage) && isscalar(stage)))
    error('SIMPLE:DatasetRegistry:InvalidStage', ...
        'Validation stage must be raw, processed, or summary.');
end
stage = char(string(stage));
stages = {'raw', 'processed', 'summary'};
stageIndex = find(strcmp(stage, stages), 1);
if isempty(stageIndex)
    error('SIMPLE:DatasetRegistry:InvalidStage', ...
        'Validation stage must be raw, processed, or summary.');
end

required = {'path_raw', 'EEGfile_raw'};
if stageIndex >= 2
    required = [required, {'path_processed', 'EEGfile_processed'}]; %#ok<AGROW>
end
if stageIndex >= 3
    required = [required, {'path_summary'}]; %#ok<AGROW>
end
missing = setdiff(required, T.Properties.VariableNames, 'stable');
if ~isempty(missing)
    error('SIMPLE:DatasetRegistry:MissingColumns', ...
        'Missing required dataset-registry columns: %s', ...
        strjoin(missing, ', '));
end

baseCanonical = canonical_path(baseDir);
rawRoot = validated_root(baseDir, baseCanonical, 'raw');
rawPaths = registry_strings(T.path_raw, 'path_raw');
rawNames = registry_strings(T.EEGfile_raw, 'EEGfile_raw');
targets = struct();
targets.raw_files = validate_file_targets(rawPaths, rawNames, baseDir, ...
    baseCanonical, rawRoot, 'raw');
targets.processed_files = strings(0, 1);
targets.summary_files = strings(0, 4);

if stageIndex >= 2
    processedRoot = validated_root(baseDir, baseCanonical, 'processed');
    processedPaths = registry_strings(T.path_processed, 'path_processed');
    processedNames = registry_strings(T.EEGfile_processed, ...
        'EEGfile_processed');
    targets.processed_files = validate_file_targets(processedPaths, ...
        processedNames, baseDir, baseCanonical, processedRoot, 'processed');

    rawKeys = lower(targets.raw_files);
    processedKeys = lower(targets.processed_files);
    collisionRows = find(rawKeys == processedKeys);
    if ~isempty(collisionRows)
        error('SIMPLE:DatasetRegistry:RawOutputCollision', ...
            'Raw and processed targets are identical at row(s): %s', ...
            join(string(collisionRows(:).'), ', '));
    end
    assert_unique_targets(processedKeys, ...
        'SIMPLE:DatasetRegistry:DuplicateProcessedTarget', ...
        'Processed dataset');
end

if stageIndex >= 3
    summaryRoot = validated_root(baseDir, baseCanonical, 'summary');
    summaryPaths = registry_strings(T.path_summary, 'path_summary');
    validate_relative_directories(summaryPaths, baseDir, baseCanonical, ...
        summaryRoot, 'summary');

    suffixes = ["_qc_features.csv", "_nrf_features.csv", ...
        "_epochs_index.csv", "_epochs.mat"];
    targets.summary_files = strings(height(T), numel(suffixes));
    for row = 1:height(T)
        [~, stem] = fileparts(char(processedNames(row)));
        summaryDirectory = join_relative(baseDir, summaryPaths(row));
        for outputIndex = 1:numel(suffixes)
            outputName = string(stem) + suffixes(outputIndex);
            outputCanonical = canonical_path(fullfile(summaryDirectory, ...
                char(outputName)));
            assert_canonical_within(outputCanonical, summaryRoot, ...
                'summary output', row);
            targets.summary_files(row, outputIndex) = outputCanonical;
        end
    end
    assert_unique_targets(lower(targets.summary_files(:)), ...
        'SIMPLE:DatasetRegistry:DuplicateSummaryTarget', ...
        'Summary output');
end
end

function values = registry_strings(column, columnName)
try
    values = string(column);
catch ME
    error('SIMPLE:DatasetRegistry:InvalidValue', ...
        'Column %s cannot be represented as scalar strings: %s', ...
        columnName, ME.message);
end
if ~iscolumn(values) || numel(values) ~= size(column, 1)
    error('SIMPLE:DatasetRegistry:InvalidValue', ...
        'Column %s must contain one scalar value per row.', columnName);
end
values = values(:);
end

function rootCanonical = validated_root(baseDir, baseCanonical, rootName)
rootCanonical = canonical_path(fullfile(baseDir, 'data', rootName));
expectedRoot = string(fullfile(char(baseCanonical), 'data', rootName));
if ~canonical_equal(rootCanonical, expectedRoot)
    error('SIMPLE:DatasetRegistry:CanonicalEscape', ...
        'data/%s must be a real repository directory, not a redirected path.', ...
        rootName);
end
assert_canonical_within(rootCanonical, baseCanonical, ...
    ['data/' rootName ' root'], 0);
end

function targets = validate_file_targets(paths, names, baseDir, ...
        baseCanonical, rootCanonical, rootName)
if numel(paths) ~= numel(names)
    error('SIMPLE:DatasetRegistry:InvalidValue', ...
        'Path and filename columns must have the same number of rows.');
end
validate_relative_directories(paths, baseDir, baseCanonical, ...
    rootCanonical, rootName);
targets = strings(numel(paths), 1);
for row = 1:numel(paths)
    validate_set_filename(names(row), row);
    directory = join_relative(baseDir, paths(row));
    targetCanonical = canonical_path(fullfile(directory, char(names(row))));
    assert_canonical_within(targetCanonical, rootCanonical, ...
        [rootName ' dataset'], row);
    targets(row) = targetCanonical;
end
end

function validate_relative_directories(paths, baseDir, baseCanonical, ...
        rootCanonical, rootName)
expected = ["data", string(rootName)];
for row = 1:numel(paths)
    value = paths(row);
    if ismissing(value) || strlength(value) == 0 || value ~= strtrim(value)
        unsafe_path(rootName, row, value);
    end
    if contains(value, "\") || contains(value, "//") || ...
            contains(value, ":") || contains(value, "~") || ...
            contains_control_character(value)
        unsafe_path(rootName, row, value);
    end
    components = split(value, '/');
    if numel(components) < 2 || any(components == "") || ...
            any(components == ".") || any(components == "..") || ...
            ~isequal(components(1:2).', expected)
        unsafe_path(rootName, row, value);
    end
    directoryCanonical = canonical_path(join_relative(baseDir, value));
    assert_canonical_within(directoryCanonical, rootCanonical, ...
        [rootName ' directory'], row);
    assert_canonical_within(directoryCanonical, baseCanonical, ...
        [rootName ' directory'], row);
end
end

function validate_set_filename(value, row)
if ismissing(value) || strlength(value) == 0 || value ~= strtrim(value) || ...
        contains(value, "/") || contains(value, "\") || ...
        contains(value, ":") || contains(value, "~") || ...
        contains_control_character(value)
    invalid_filename(row, value);
end
[folder, stem, extension] = fileparts(char(value));
if ~isempty(folder) || isempty(stem) || ~strcmp(extension, '.set') || ...
        any(strcmp(stem, {'.', '..'}))
    invalid_filename(row, value);
end
end

function directory = join_relative(baseDir, relativePath)
components = cellstr(split(relativePath, '/'));
directory = fullfile(baseDir, components{:});
end

function value = canonical_path(value)
value = string(char(java.io.File(char(value)).getCanonicalPath()));
end

function tf = canonical_equal(first, second)
if ispc
    tf = strcmpi(char(first), char(second));
else
    tf = strcmp(char(first), char(second));
end
end

function tf = contains_control_character(value)
codes = double(char(value));
tf = any(codes < 32) || any(codes == 127);
end

function assert_canonical_within(candidate, root, label, row)
candidate = char(candidate);
root = char(root);
if ispc
    equalRoot = strcmpi(candidate, root);
    insideRoot = startsWith(candidate, [root filesep], 'IgnoreCase', true);
else
    equalRoot = strcmp(candidate, root);
    insideRoot = startsWith(candidate, [root filesep]);
end
if ~(equalRoot || insideRoot)
    if row > 0
        error('SIMPLE:DatasetRegistry:CanonicalEscape', ...
            'Row %d %s escapes its required repository root.', row, label);
    else
        error('SIMPLE:DatasetRegistry:CanonicalEscape', ...
            '%s escapes the repository root.', label);
    end
end
end

function assert_unique_targets(keys, identifier, label)
if numel(unique(keys, 'stable')) ~= numel(keys)
    error(identifier, '%s destinations must be unique.', label);
end
end

function unsafe_path(rootName, row, value)
error('SIMPLE:DatasetRegistry:UnsafePath', ...
    'Row %d has an unsafe %s path: %s', row, rootName, printable(value));
end

function invalid_filename(row, value)
error('SIMPLE:DatasetRegistry:InvalidFilename', ...
    'Row %d has an invalid .set filename: %s', row, printable(value));
end

function value = printable(value)
if ismissing(value)
    value = '<missing>';
else
    value = char(value);
end
end
