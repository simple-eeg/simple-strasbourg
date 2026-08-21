function report = verify_sanitised_eeglab_dataset( ...
        originalSetPath, candidateSetPath, expected, privacy)
%VERIFY_SANITISED_EEGLAB_DATASET Verify one sanitised SET candidate.

if nargin < 4 || isempty(privacy)
    privacy = struct();
end
originalSetPath = require_set(originalSetPath, privacy, 'OriginalSetMissing');
candidateSetPath = require_set(candidateSetPath, privacy, 'CandidateSetMissing');
[originalEEG, originalLayout] = raw_load(originalSetPath, privacy);
[candidateEEG, candidateLayout] = raw_load(candidateSetPath, privacy);
if ~strcmp(originalLayout, candidateLayout)
    fail('LayoutChanged', privacy, ...
        'The candidate changed the source SET storage layout.');
end

[expectedEEG, policyReport] = sanitise_eeglab_dataset( ...
    originalEEG, expected, privacy);
resanitised = sanitise_eeglab_dataset(candidateEEG, expected, privacy);
if ~isequaln(candidateEEG, resanitised)
    fail('StoredPolicyMismatch', privacy, ...
        'The stored candidate does not satisfy the exact metadata policy.');
elseif ~isequaln(expectedEEG, candidateEEG)
    fail('ScientificDifference', privacy, ...
        'The candidate contains a change outside the metadata policy.');
end
assert_identity_text(candidateEEG, expected, privacy);

[folder, stem, extension] = fileparts(candidateSetPath);
try
    loadedEEG = pop_loadset('filename', [stem extension], ...
        'filepath', folder, 'loadmode', 'all', 'check', 'on', ...
        'verbose', 'off');
catch
    fail('EEGLABLoadFailed', privacy, ...
        'EEGLAB could not load the sanitised SET candidate.');
end
loadedEEG = normalise_runtime_fields(loadedEEG, candidateEEG);
if ~isequaln(candidateEEG, loadedEEG)
    fail('EEGLABLoadChangedContent', privacy, ...
        'Normal EEGLAB loading changed stored scientific content.');
end
try
    checkedEEG = eeg_checkset(loadedEEG, 'eventconsistency');
catch
    fail('EventConsistencyFailed', privacy, ...
        'EEGLAB event-consistency checking failed.');
end
checkedEEG = normalise_runtime_fields(checkedEEG, candidateEEG);
if ~isequaln(candidateEEG, checkedEEG)
    fail('EventConsistencyChangedContent', privacy, ...
        'EEGLAB event-consistency checking changed scientific content.');
end
rescanned = sanitise_eeglab_dataset(checkedEEG, expected, privacy);
if ~isequaln(checkedEEG, rescanned)
    fail('EventConsistencyReintroducedMetadata', privacy, ...
        'EEGLAB event checking reintroduced removed metadata.');
end

report = struct('schema', 'simple-step2-sanitisation-verification-v1', ...
    'layout', originalLayout, 'stored_filepath_empty', true, ...
    'textual_identifiers_exact', true, 'eeglab_loadable', true, ...
    'event_consistent', true, 'scientifically_equal', true, ...
    'authorised_changes', policyReport.authorised_changes, ...
    'fields_scanned', policyReport.fields_scanned);
end

function pathValue = require_set(pathValue, privacy, identifier)
if ~(ischar(pathValue) || (isstring(pathValue) && isscalar(pathValue)))
    fail(identifier, privacy, 'A required SET path was not scalar text.');
end
pathValue = char(string(pathValue));
if isempty(pathValue) || ~isfile(pathValue) || ...
        is_symbolic_link(pathValue) || ~java.io.File(pathValue).isFile()
    fail(identifier, privacy, 'A required SET file is unavailable.');
end
end

function [EEG, layout] = raw_load(pathValue, privacy)
try
    stored = load('-mat', pathValue);
catch
    fail('RawLoadFailed', privacy, 'The SET could not be raw-loaded.');
end
if isfield(stored, 'EEG') && isscalar(fieldnames(stored)) && ...
        isstruct(stored.EEG) && isscalar(stored.EEG)
    EEG = stored.EEG;
    layout = 'scalar-EEG-wrapper';
elseif isstruct(stored) && isscalar(stored) && isfield(stored, 'data')
    EEG = stored;
    layout = 'top-level-fields';
else
    fail('UnsupportedSetLayout', privacy, ...
        'The SET has an unsupported or ambiguous storage layout.');
end
end

function assert_identity_text(EEG, expected, privacy)
[~, stem] = fileparts(char(string(expected.EEGfile_raw)));
fields = {'filename', 'filepath', 'setname', 'subject', 'session', 'run', ...
    'comments', 'history'};
values = {expected.EEGfile_raw, '', stem, expected.subjectID, ...
    expected.sessionID, expected.runID, '', ''};
for index = 1:numel(fields)
    value = EEG.(fields{index});
    if ~ischar(value) || ~(isempty(value) || isrow(value)) || ...
            ~strcmp(value, char(string(values{index})))
        fail('StoredIdentityMismatch', privacy, ...
            'A stored identity or provenance field is not exact character text.');
    end
end
end

function EEG = normalise_runtime_fields(EEG, storedEEG)
EEG.filepath = storedEEG.filepath;
EEG.filename = storedEEG.filename;
if isfield(storedEEG, 'saved')
    EEG.saved = storedEEG.saved;
elseif isfield(EEG, 'saved')
    EEG = rmfield(EEG, 'saved');
end
if isfield(EEG, 'changes_not_saved') && ...
        ~isfield(storedEEG, 'changes_not_saved')
    EEG = rmfield(EEG, 'changes_not_saved');
end
for name = {'eventdescription', 'epochdescription'}
    if isfield(storedEEG, name{1})
        EEG.(name{1}) = storedEEG.(name{1});
    elseif isfield(EEG, name{1})
        EEG = rmfield(EEG, name{1});
    end
end
end

function fail(identifier, privacy, message)
prefix = '';
if isstruct(privacy) && isfield(privacy, 'row_number') && ...
        isnumeric(privacy.row_number) && isscalar(privacy.row_number) && ...
        isfinite(privacy.row_number)
    prefix = sprintf('Registry row %d: ', privacy.row_number);
end
error(['SIMPLE:Step2Sanitise:' identifier], '%s%s', prefix, message);
end

function tf = is_symbolic_link(pathValue)
tf = java.nio.file.Files.isSymbolicLink(java.io.File(pathValue).toPath());
end
