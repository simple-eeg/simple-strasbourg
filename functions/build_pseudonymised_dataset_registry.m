function mapped = build_pseudonymised_dataset_registry(original)
%BUILD_PSEUDONYMISED_DATASET_REGISTRY Build the canonical ten-column map.
%
% mapped = build_pseudonymised_dataset_registry(original)
%
% The transformation is pure: it reads no files and changes no filesystem
% state. Replacement identifiers follow stable first appearance and remain
% text, including their leading zeroes.

if ~istable(original)
    error('SIMPLE:Step2Identity:InvalidRegistry', ...
        'The original dataset registry must be a table.');
end

originalCore = {'subjectID', 'sessionID', 'runID', ...
    'path_raw', 'EEGfile_raw'};
mappedOnly = {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'path_raw_orig', 'EEGfile_raw_orig'};
names = original.Properties.VariableNames;
if numel(names) < numel(originalCore) || ...
        ~isequal(names(1:numel(originalCore)), originalCore)
    error('SIMPLE:Step2Identity:InvalidOriginalSchema', ...
        'The first five registry columns must be the canonical original identity columns.');
end
if any(ismember(mappedOnly, names))
    error('SIMPLE:Step2Identity:PartialMappedSchema', ...
        'The registry already contains one or more mapped-only columns.');
end

original = force_and_validate_text(original, originalCore);
assert_unique_tuples(original, originalCore(1:3), ...
    'SIMPLE:Step2Identity:DuplicateOriginalTuple', ...
    'Original recording tuples must be unique.');
validate_raw_targets(original.path_raw, original.EEGfile_raw, 'data/raw');

rowCount = height(original);
replacementSubject = strings(rowCount, 1);
replacementSession = strings(rowCount, 1);
replacementRun = strings(rowCount, 1);

seenSubjects = strings(0, 1);
seenSessions = cell(0, 1);
seenRuns = cell(0, 1);

for row = 1:rowCount
    sourceSubject = original.subjectID(row);
    subjectIndex = find(seenSubjects == sourceSubject, 1, 'first');
    if isempty(subjectIndex)
        seenSubjects(end + 1, 1) = sourceSubject; %#ok<AGROW>
        seenSessions{end + 1, 1} = strings(0, 1); %#ok<AGROW>
        seenRuns{end + 1, 1} = cell(0, 1); %#ok<AGROW>
        subjectIndex = numel(seenSubjects);
    end

    subjectSessions = seenSessions{subjectIndex};
    sourceSession = original.sessionID(row);
    sessionIndex = find(subjectSessions == sourceSession, 1, 'first');
    if isempty(sessionIndex)
        subjectSessions(end + 1, 1) = sourceSession; %#ok<AGROW>
        seenSessions{subjectIndex} = subjectSessions;
        subjectRuns = seenRuns{subjectIndex};
        subjectRuns{end + 1, 1} = strings(0, 1); %#ok<AGROW>
        seenRuns{subjectIndex} = subjectRuns;
        sessionIndex = numel(subjectSessions);
    end

    subjectRuns = seenRuns{subjectIndex};
    sessionRuns = subjectRuns{sessionIndex};
    sourceRun = original.runID(row);
    runIndex = find(sessionRuns == sourceRun, 1, 'first');
    if isempty(runIndex)
        sessionRuns(end + 1, 1) = sourceRun; %#ok<AGROW>
        subjectRuns{sessionIndex} = sessionRuns;
        seenRuns{subjectIndex} = subjectRuns;
        runIndex = numel(sessionRuns);
    end

    replacementSubject(row) = padded_identifier(subjectIndex, 3);
    replacementSession(row) = padded_identifier(sessionIndex, 2);
    replacementRun(row) = padded_identifier(runIndex, 2);
end

if any(ismember(unique(original.subjectID, 'stable'), ...
        unique(replacementSubject, 'stable')))
    error('SIMPLE:Step2Identity:SubjectNamespaceOverlap', ...
        ['The replacement subject namespace overlaps an admitted original ' ...
         'subject identifier. Select a separately agreed namespace before proceeding.']);
end

suffix = extractAfter(original.path_raw, strlength("data/raw/"));
originalPath = "data/raw_orig/" + suffix;
canonicalPath = "data/raw/sub-" + replacementSubject + ...
    "/ses-" + replacementSession + "/eeg";
canonicalFile = "sub-" + replacementSubject + ...
    "_ses-" + replacementSession + "_run-" + replacementRun + "_eeg.set";

mappedCore = table( ...
    original.subjectID, original.sessionID, original.runID, ...
    replacementSubject, replacementSession, replacementRun, ...
    originalPath, canonicalPath, original.EEGfile_raw, canonicalFile, ...
    'VariableNames', {'subjectID_orig', 'sessionID_orig', 'runID_orig', ...
    'subjectID', 'sessionID', 'runID', 'path_raw_orig', 'path_raw', ...
    'EEGfile_raw_orig', 'EEGfile_raw'});

extraNames = names(numel(originalCore) + 1:end);
if isempty(extraNames)
    mapped = mappedCore;
else
    mapped = [mappedCore, original(:, extraNames)];
end

assert_unique_tuples(mapped, {'subjectID', 'sessionID', 'runID'}, ...
    'SIMPLE:Step2Identity:DuplicateCanonicalTuple', ...
    'Canonical recording tuples must be unique.');
validate_raw_targets(mapped.path_raw_orig, mapped.EEGfile_raw_orig, ...
    'data/raw_orig');
validate_raw_targets(mapped.path_raw, mapped.EEGfile_raw, 'data/raw');
end

function T = force_and_validate_text(T, columns)
for columnIndex = 1:numel(columns)
    name = columns{columnIndex};
    source = T.(name);
    if ~(ischar(source) || isstring(source) || iscellstr(source) || ...
            iscategorical(source))
        error('SIMPLE:Step2Identity:InvalidTextColumn', ...
            ['Column %s must already contain text. Numeric or logical ' ...
             'conversion could discard meaningful leading zeroes.'], name);
    end
    try
        values = string(source);
    catch
        error('SIMPLE:Step2Identity:InvalidTextColumn', ...
            'Column %s cannot be represented as scalar text.', name);
    end
    if ~iscolumn(values) || numel(values) ~= height(T)
        error('SIMPLE:Step2Identity:InvalidTextColumn', ...
            'Column %s must contain one scalar text value per row.', name);
    end
    values = values(:);
    if any(ismissing(values) | strlength(values) == 0 | ...
            values ~= strtrim(values))
        error('SIMPLE:Step2Identity:InvalidTextValue', ...
            'Column %s contains a blank, missing, or unnormalised value.', name);
    end
    T.(name) = values;
end
end

function value = padded_identifier(index, minimumWidth)
width = max(minimumWidth, numel(sprintf('%d', index)));
value = string(sprintf(['%0' num2str(width) 'd'], index));
end

function assert_unique_tuples(T, columns, identifier, message)
for row = 2:height(T)
    prior = true(row - 1, 1);
    for columnIndex = 1:numel(columns)
        values = T.(columns{columnIndex});
        prior = prior & values(1:row - 1) == values(row);
    end
    if any(prior)
        error(identifier, '%s Duplicate encountered at row %d.', message, row);
    end
end
end

function validate_raw_targets(paths, files, requiredRoot)
requiredPrefix = string(requiredRoot) + "/";
targets = strings(numel(paths), 1);
for row = 1:numel(paths)
    pathValue = paths(row);
    fileValue = files(row);
    if ~startsWith(pathValue, requiredPrefix) || ...
            contains(pathValue, "\") || contains(pathValue, "//") || ...
            contains(pathValue, ":") || contains(pathValue, "~") || ...
            any(split(pathValue, '/') == "..") || ...
            any(split(pathValue, '/') == ".") || ...
            contains_control_character(pathValue)
        error('SIMPLE:Step2Identity:UnsafePath', ...
            'Registry row %d has an unsafe %s path.', row, requiredRoot);
    end
    [folder, stem, extension] = fileparts(char(fileValue));
    if ~isempty(folder) || isempty(stem) || ~strcmp(extension, '.set') || ...
            contains(fileValue, "\") || contains(fileValue, "/") || ...
            contains(fileValue, ":") || contains(fileValue, "~") || ...
            contains_control_character(fileValue)
        error('SIMPLE:Step2Identity:InvalidFilename', ...
            'Registry row %d has an invalid SET filename.', row);
    end
    targets(row) = pathValue + "/" + fileValue;
end
if numel(unique(targets, 'stable')) ~= numel(targets)
    error('SIMPLE:Step2Identity:DuplicateTarget', ...
        'Registry SET targets must be unique.');
end
end

function tf = contains_control_character(value)
codes = double(char(value));
tf = any(codes < 32) || any(codes == 127);
end
