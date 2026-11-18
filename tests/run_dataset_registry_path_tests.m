function [passed, skipped] = run_dataset_registry_path_tests(repoRoot)
%RUN_DATASET_REGISTRY_PATH_TESTS Exercise fail-closed registry target checks.

arguments
    repoRoot (1,:) char
end

functionsRoot = fullfile(repoRoot, 'functions');
addpath(functionsRoot, '-begin');
originalPath = path;
pathCleanup = onCleanup(@() path(originalPath)); %#ok<NASGU>
addpath(fullfile(repoRoot, 'tests', 'helpers'), '-begin');
clear validate_dataset_registry_paths
rehash path
skipped = 0;

temporaryRoot = tempname;
mkdir(temporaryRoot);
cleanup = onCleanup(@() rmdir_if_present(temporaryRoot)); %#ok<NASGU>
mkdir(fullfile(temporaryRoot, 'data', 'raw'));
mkdir(fullfile(temporaryRoot, 'data', 'processed'));
mkdir(fullfile(temporaryRoot, 'data', 'summary'));

T = valid_registry();
targets = validate_dataset_registry_paths(T, temporaryRoot, 'summary');
assert(isequal(size(targets.summary_files), [2 4]));
assert(endsWith(targets.raw_files(1), ...
    fullfile('data', 'raw', 'sub-001', 'recording.set')));
assert(endsWith(targets.processed_files(2), ...
    fullfile('data', 'processed', 'sub-002', 'recording.set')));
assert(endsWith(targets.summary_files(2, 4), ...
    fullfile('data', 'summary', 'sub-002', 'recording_epochs.mat')));
passed = 1;

rawOnly = removevars(T, {'path_processed', 'EEGfile_processed', ...
    'path_summary'});
validate_dataset_registry_paths(rawOnly, temporaryRoot, 'raw');
passed = passed + 1;

assert_rejected(set_value(T, 'path_raw', 2, 'data/rawish/sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_processed', 2, ...
    'data/processed-old/sub-002'), temporaryRoot, 'summary', ...
    'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_summary', 2, ...
    'data/summary2/sub-002'), temporaryRoot, 'summary', ...
    'SIMPLE:DatasetRegistry:UnsafePath');
passed = passed + 3;

assert_rejected(set_value(T, 'path_raw', 2, '/tmp/absolute'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, 'data/raw/../summary'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, 'data/raw/./sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, 'data/raw//sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, ' data/raw/sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, 'C:/data/raw/sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, '//server/share'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_raw', 2, 'data\\raw\\sub-002'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:UnsafePath');
assert_rejected(set_value(T, 'path_processed', 2, ''), ...
    temporaryRoot, 'processed', 'SIMPLE:DatasetRegistry:UnsafePath');
passed = passed + 9;

assert_rejected(set_value(T, 'EEGfile_raw', 2, 'nested/recording.set'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:InvalidFilename');
assert_rejected(set_value(T, 'EEGfile_processed', 2, 'recording.mat'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:InvalidFilename');
assert_rejected(set_value(T, 'EEGfile_processed', 2, 'recording.SET'), ...
    temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:InvalidFilename');
passed = passed + 3;

rawOutputEquality = T(1, :);
rawOutputEquality.path_processed = rawOutputEquality.path_raw;
assert_rejected(rawOutputEquality, temporaryRoot, 'processed', ...
    'SIMPLE:DatasetRegistry:UnsafePath');
passed = passed + 1;

duplicateProcessed = T;
duplicateProcessed.path_processed(2) = duplicateProcessed.path_processed(1);
assert_rejected(duplicateProcessed, temporaryRoot, 'summary', ...
    'SIMPLE:DatasetRegistry:DuplicateProcessedTarget');
passed = passed + 1;

duplicateSummary = T;
duplicateSummary.path_summary(:) = "data/summary/shared";
assert_rejected(duplicateSummary, temporaryRoot, 'summary', ...
    'SIMPLE:DatasetRegistry:DuplicateSummaryTarget');
passed = passed + 1;

sentinelPath = fullfile(temporaryRoot, 'dataset_list_sentinel.csv');
write_sentinel(sentinelPath, 'UNCHANGED_REGISTRY');
lateInvalid = T;
lateInvalid.path_summary(2) = "data/summary/../raw";
assert_rejected(lateInvalid, temporaryRoot, 'summary', ...
    'SIMPLE:DatasetRegistry:UnsafePath');
assert(strcmp(fileread(sentinelPath), 'UNCHANGED_REGISTRY'), ...
    'Invalid late row changed the registry sentinel.');
passed = passed + 1;

outsideRoot = fullfile(temporaryRoot, 'outside');
mkdir(outsideRoot);
escapeLink = fullfile(temporaryRoot, 'data', 'raw', 'escape');
if create_test_link(outsideRoot, escapeLink)
    assert_rejected(set_value(T, 'path_raw', 2, 'data/raw/escape'), ...
        temporaryRoot, 'summary', 'SIMPLE:DatasetRegistry:CanonicalEscape');
    passed = passed + 1;
else
    skipped = skipped + 1;
end

redirectedRoot = tempname;
mkdir(fullfile(redirectedRoot, 'data', 'raw'));
redirectedCleanup = onCleanup(@() rmdir_if_present(redirectedRoot)); %#ok<NASGU>
processedLink = fullfile(redirectedRoot, 'data', 'processed');
if create_test_link(fullfile(redirectedRoot, 'data', 'raw'), processedLink)
    sameTarget = T(1, :);
    sameTarget.path_processed = sameTarget.path_raw;
    sameTarget.path_processed = replace(sameTarget.path_processed, ...
        'data/raw', 'data/processed');
    assert_rejected(sameTarget, redirectedRoot, 'processed', ...
        'SIMPLE:DatasetRegistry:CanonicalEscape');
    passed = passed + 1;
else
    skipped = skipped + 1;
end

fprintf('DATASET REGISTRY PATH TESTS: %d passed, %d skipped\n', passed, skipped);
end

function T = valid_registry()
T = table( ...
    ["data/raw/sub-001"; "data/raw/sub-002"], ...
    ["recording.set"; "recording.set"], ...
    ["data/processed/sub-001"; "data/processed/sub-002"], ...
    ["recording.set"; "recording.set"], ...
    ["data/summary/sub-001"; "data/summary/sub-002"], ...
    'VariableNames', {'path_raw', 'EEGfile_raw', 'path_processed', ...
    'EEGfile_processed', 'path_summary'});
end

function T = set_value(T, variableName, row, value)
T.(variableName)(row) = string(value);
end

function assert_rejected(T, baseDir, stage, expectedIdentifier)
try
    validate_dataset_registry_paths(T, baseDir, stage);
catch ME
    assert(strcmp(ME.identifier, expectedIdentifier), ...
        'Expected %s, got %s: %s', expectedIdentifier, ME.identifier, ...
        ME.message);
    return
end
error('Expected registry validation to reject the fixture.');
end

function write_sentinel(filePath, value)
fid = fopen(filePath, 'wt');
assert(fid >= 0, 'Could not create registry sentinel.');
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
count = fwrite(fid, value, 'char');
assert(count == numel(value));
end

function rmdir_if_present(folder)
if isfolder(folder)
    rmdir(folder, 's');
end
end
