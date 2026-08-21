function [EEG, report] = sanitise_eeglab_dataset(EEG, expected, privacy)
%SANITISE_EEGLAB_DATASET Apply the accepted SET metadata policy.

if nargin < 3 || isempty(privacy)
    privacy = struct();
end
privacy = prepare_privacy(privacy);
expected = validate_expected(expected, privacy);
if ~isstruct(EEG) || ~isscalar(EEG)
    fail('InvalidDataset', privacy, '', ...
        'The loaded SET must contain one scalar EEG structure.');
end
require_internal_data(EEG, privacy);

report.schema = 'simple-step2-sanitisation-report-v1';
report.event_bvtime_removed = field_count(EEG, 'event', 'bvtime');
report.urevent_bvtime_removed = field_count(EEG, 'urevent', 'bvtime');
report.epoch_eventbvtime_removed = field_count(EEG, 'epoch', 'eventbvtime');
report.event_description_removed = 0;
report.epoch_description_removed = 0;
if report.epoch_eventbvtime_removed > 0
    verify_epoch_bvtime_mirror(EEG, privacy);
end

[~, stem] = fileparts(expected.EEGfile_raw);
EEG.filename = expected.EEGfile_raw;
EEG.filepath = '';
EEG.setname = stem;
EEG.subject = expected.subjectID;
EEG.session = expected.sessionID;
EEG.run = expected.runID;
EEG.comments = '';
EEG.history = '';
removals = {'event', 'bvtime', 'eventdescription'; ...
    'urevent', 'bvtime', ''; ...
    'epoch', 'eventbvtime', 'epochdescription'};
for index = 1:size(removals, 1)
    parent = removals{index, 1};
    field = removals{index, 2};
    description = removals{index, 3};
    if isfield(EEG, parent) && isstruct(EEG.(parent)) && ...
            isfield(EEG.(parent), field)
        [EEG, descriptionRemoved] = remove_field_description( ...
            EEG, parent, field, description);
        if strcmp(description, 'eventdescription')
            report.event_description_removed = descriptionRemoved;
        elseif strcmp(description, 'epochdescription')
            report.epoch_description_removed = descriptionRemoved;
        end
        EEG.(parent) = rmfield(EEG.(parent), field);
    end
end

scan = scan_value(EEG, {'EEG'}, privacy);
report.fields_scanned = scan.fields;
report.text_values_scanned = scan.texts;
report.requires_v73 = scan.requires_v73;
report.authorised_changes = 8 + report.event_bvtime_removed + ...
    report.urevent_bvtime_removed + report.epoch_eventbvtime_removed + ...
    report.event_description_removed + report.epoch_description_removed;
end

function [EEG, removed] = remove_field_description( ...
        EEG, parent, field, description)
removed = 0;
if isempty(description) || ~isfield(EEG, description) || ...
        ~iscell(EEG.(description)) || ~isvector(EEG.(description))
    return
end
fields = fieldnames(EEG.(parent));
fieldIndex = find(strcmp(fields, field), 1);
descriptions = EEG.(description);
if numel(descriptions) == numel(fields)
    descriptions(fieldIndex) = [];
    EEG.(description) = descriptions;
    removed = 1;
end
end

function expected = validate_expected(expected, privacy)
required = {'subjectID', 'sessionID', 'runID', 'EEGfile_raw'};
if ~isstruct(expected) || ~isscalar(expected) || ...
        ~all(isfield(expected, required))
    fail('InvalidExpectedIdentity', privacy, '', ...
        'Expected identity must contain the four canonical fields.');
end
for index = 1:numel(required)
    name = required{index};
    value = expected.(name);
    if ~(ischar(value) || (isstring(value) && isscalar(value)))
        fail('InvalidExpectedIdentity', privacy, '', ...
            'Canonical identity fields must be scalar text.');
    end
    value = char(string(value));
    if isempty(value) || ~strcmp(value, strtrim(value))
        fail('InvalidExpectedIdentity', privacy, '', ...
            'Canonical identity fields must be nonblank normalised text.');
    end
    expected.(name) = value;
end
if isempty(regexp(expected.subjectID, '^\d{3,}$', 'once')) || ...
        isempty(regexp(expected.sessionID, '^\d{2,}$', 'once')) || ...
        isempty(regexp(expected.runID, '^\d{2,}$', 'once'))
    fail('InvalidExpectedIdentity', privacy, '', ...
        'Canonical identifiers do not satisfy the textual width contract.');
end
canonical = sprintf('sub-%s_ses-%s_run-%s_eeg.set', ...
    expected.subjectID, expected.sessionID, expected.runID);
if ~strcmp(expected.EEGfile_raw, canonical)
    fail('InvalidExpectedIdentity', privacy, '', ...
        'The canonical EEG filename does not match its identifier tuple.');
end
end

function privacy = prepare_privacy(privacy)
if ~isstruct(privacy) || ~isscalar(privacy)
    privacy = struct();
end
defaults = struct('row_number', NaN, 'original_subject_id', '', ...
    'original_session_id', '', 'original_run_id', '', ...
    'original_filename', '', 'original_path', '', ...
    'blocked_tokens', strings(0, 1), ...
    'subject_tokens', strings(0, 1));
for name = fieldnames(defaults).'
    if ~isfield(privacy, name{1})
        privacy.(name{1}) = defaults.(name{1});
    end
end

tokens = strings(0, 1);
for name = {'original_filename', 'original_path', 'blocked_tokens'}
    values = string(privacy.(name{1}));
    tokens = [tokens; values(:)]; %#ok<AGROW>
end
for name = {'original_session_id', 'original_run_id'}
    value = char(string(privacy.(name{1})));
    if ~isempty(value) && isempty(regexp(value, '^\d{1,2}$', 'once'))
        tokens(end + 1, 1) = string(value); %#ok<AGROW>
    end
end
[~, stem] = fileparts(char(string(privacy.original_filename)));
tokens(end + 1, 1) = string(stem);
components = regexp(strrep(char(string(privacy.original_path)), ...
    '\', '/'), '/', 'split');
generic = {'', 'data', 'raw', 'raw_orig', 'eeg'};
for index = 1:numel(components)
    component = regexprep(components{index}, '^(sub|ses)-', '');
    if numel(component) >= 4 && ~any(strcmpi(component, generic)) && ...
            isempty(regexp(component, '^\d+$', 'once'))
        tokens(end + 1, 1) = string(component); %#ok<AGROW>
    end
end
tokens = [tokens; string(getenv('USER')); string(getenv('USERNAME'))];
tokens = strtrim(tokens);
privacy.blocked_tokens = unique(tokens(~ismissing(tokens) & ...
    strlength(tokens) > 0), 'stable');
subjectTokens = string(privacy.subject_tokens);
subjectTokens = [subjectTokens(:); string(privacy.original_subject_id)];
subjectTokens = strtrim(subjectTokens);
privacy.subject_tokens = unique(subjectTokens(~ismissing(subjectTokens) & ...
    strlength(subjectTokens) > 0), 'stable');
end

function require_internal_data(EEG, privacy)
if ~isfield(EEG, 'data') || ~isnumeric(EEG.data) || isempty(EEG.data)
    fail('ExternalData', privacy, 'EEG.data', ...
        'Signal data must be nonempty numeric content stored in the SET.');
end
for name = {'datfile', 'splinefile', 'icasplinefile'}
    if isfield(EEG, name{1}) && ~effectively_empty(EEG.(name{1}))
        fail('ExternalPointer', privacy, ['EEG.' name{1}], ...
            'A populated external-pointer field is not supported.');
    end
end
end

function verify_epoch_bvtime_mirror(EEG, privacy)
location = 'EEG.epoch.eventbvtime';
if ~isfield(EEG, 'event') || ~isstruct(EEG.event) || ...
        ~isfield(EEG.event, 'bvtime') || ~isfield(EEG, 'epoch') || ...
        ~isstruct(EEG.epoch)
    fail('EpochBvtimeNotMirror', privacy, location, ...
        'The epoch timing field is not an event-linked mirror.');
end
for epochIndex = 1:numel(EEG.epoch)
    epoch = EEG.epoch(epochIndex);
    if ~isfield(epoch, 'event') || ~isfield(epoch, 'eventbvtime')
        fail('EpochBvtimeNotMirror', privacy, location, ...
            'The epoch timing mirror is incomplete.');
    end
    eventIndices = event_indices(epoch.event, privacy);
    values = epoch.eventbvtime;
    if any(eventIndices > numel(EEG.event)) || ~iscell(values) || ...
            ~isvector(values) || numel(values) ~= numel(eventIndices)
        fail('EpochBvtimeNotMirror', privacy, location, ...
            'The epoch timing mirror has invalid links or cardinality.');
    end
    values = reshape(values, 1, []);
    for link = 1:numel(eventIndices)
        event = EEG.event(eventIndices(link));
        if ~isequaln(values{link}, event.bvtime)
            fail('EpochBvtimeNotMirror', privacy, location, ...
                'The epoch timing value differs from its linked event.');
        end
        if isfield(event, 'urevent') && isfield(EEG, 'urevent') && ...
                isstruct(EEG.urevent) && isfield(EEG.urevent, 'bvtime')
            index = event.urevent;
            valid = isnumeric(index) && isreal(index) && isscalar(index) && ...
                isfinite(index) && index == fix(index) && index >= 1 && ...
                index <= numel(EEG.urevent);
            if ~valid || ~isequaln(event.bvtime, EEG.urevent(index).bvtime)
                fail('EpochBvtimeNotMirror', privacy, location, ...
                    'The linked urevent timing value differs.');
            end
        end
    end
end
end

function indices = event_indices(value, privacy)
if iscell(value) && isvector(value) && all(cellfun(@(item) ...
        isnumeric(item) && isreal(item) && isscalar(item), value))
    value = cell2mat(reshape(value, 1, []));
end
if ~(isnumeric(value) && isreal(value) && isvector(value) && ...
        ~isempty(value) && all(isfinite(value)) && ...
        all(value == fix(value)) && all(value >= 1))
    fail('EpochBvtimeNotMirror', privacy, 'EEG.epoch.eventbvtime', ...
        'The epoch event links are invalid.');
end
indices = reshape(double(value), 1, []);
end

function count = field_count(EEG, parent, field)
count = 0;
if isfield(EEG, parent) && isstruct(EEG.(parent)) && ...
        isfield(EEG.(parent), field)
    count = numel(EEG.(parent));
end
end

function report = scan_value(value, path, privacy)
report = struct('fields', 0, 'texts', 0, 'requires_v73', false);
if isstruct(value)
    names = fieldnames(value);
    for element = 1:numel(value)
        for index = 1:numel(names)
            name = names{index};
            childPath = [path, {name}];
            report.fields = report.fields + 1;
            if risky_field(name, childPath, privacy)
                fail('RiskyField', privacy, redacted_location(childPath), ...
                    'An identifier-bearing or path-bearing field is not allowed.');
            end
            child = scan_value(value(element).(name), childPath, privacy);
            report.fields = report.fields + child.fields;
            report.texts = report.texts + child.texts;
            report.requires_v73 = report.requires_v73 || child.requires_v73;
        end
    end
elseif iscell(value)
    for index = 1:numel(value)
        child = scan_value(value{index}, path, privacy);
        report.fields = report.fields + child.fields;
        report.texts = report.texts + child.texts;
        report.requires_v73 = report.requires_v73 || child.requires_v73;
    end
elseif ischar(value) || isstring(value) || iscategorical(value)
    texts = string(value);
    texts = texts(~ismissing(texts) & strlength(texts) > 0);
    if ~isempty(texts) && ~classified_text_path(path)
        fail('UnclassifiedText', privacy, strjoin(path, '.'), ...
            'Nonempty free text occurs outside the scientific allowlist.');
    end
    for index = 1:numel(texts)
        assert_safe_text(char(texts(index)), path, privacy);
    end
    report.texts = numel(texts);
    report.requires_v73 = isstring(value) || iscategorical(value);
elseif isa(value, 'function_handle') || isobject(value) || istable(value)
    fail('UnsupportedContent', privacy, strjoin(path, '.'), ...
        'A custom object or unsupported value occurs in the SET metadata.');
elseif ~(isnumeric(value) || islogical(value) || isempty(value))
    fail('UnsupportedContent', privacy, strjoin(path, '.'), ...
        'An unsupported value occurs in the SET metadata.');
end
end

function tf = risky_field(name, path, privacy)
location = strjoin(path, '.');
exceptions = {'eeg.subject', 'eeg.session', 'eeg.run', 'eeg.filename', ...
    'eeg.filepath', 'eeg.setname', 'eeg.datfile', 'eeg.splinefile', ...
    'eeg.icasplinefile', 'eeg.eventdescription', 'eeg.epochdescription'};
if any(strcmpi(location, exceptions))
    tf = false;
    return
end
lowerName = lower(name);
for index = 1:numel(privacy.subject_tokens)
    subjectToken = char(privacy.subject_tokens(index));
    if ~isempty(regexp(subjectToken, '^\d+$', 'once'))
        continue
    end
    if blocked_token_present(lowerName, subjectToken, true)
        tf = true;
        return
    end
end
for index = 1:numel(privacy.blocked_tokens)
    if blocked_token_present(lowerName, privacy.blocked_tokens(index))
        tf = true;
        return
    end
end
words = field_words(name);
compact = regexprep(lowerName, '[^a-z0-9]', '');
exact = {'subjectid', 'participantid', 'patientid', 'identifier', ...
    'birthdate', 'dateofbirth', 'acquisitiondate', 'acquisitiontime', ...
    'deviceserial', 'deviceserialnumber', 'hospitalnumber', ...
    'hospitalrecord', 'medicalrecord', 'medicalrecordnumber', ...
    'clinicalrecord', 'clinicalrecordnumber', 'nhsnumber', 'studyid', ...
    'studynumber', 'operatorname', 'experimentername', 'sourcefile', ...
    'sourcefilename', 'originalfile', 'originalfilename', 'sourcepath', ...
    'originalpath', 'filepath', 'mrifile', 'hdmfile', 'chanfile', 'meshfile', ...
    'mrn', 'recordno', 'medicalrecordno', 'clinicalrecordno', ...
    'hospitalrecordno', 'patientrecordno', 'nhsno'};
direct = {'subject', 'participant', 'identifier', 'id', 'patient', 'name', ...
    'medical', 'clinical', 'nhs', 'hospital', 'operator', 'experimenter', ...
    'dob', 'birth', 'serial', 'path', 'filepath', 'mrn'};
tf = any(strcmp(compact, exact)) || any(ismember(words, direct)) || ...
    (any(ismember(words, {'acquisition', 'acquired', 'device'})) && ...
    any(ismember(words, {'date', 'time', 'serial', 'id', 'number'}))) || ...
    (any(ismember(words, {'source', 'original', 'header'})) && ...
    any(ismember(words, {'file', 'filename', 'path', 'header', 'id'}))) || ...
    (any(ismember(words, {'record', 'study'})) && ...
    any(ismember(words, {'number', 'no', 'id', 'identifier'})));
end

function words = field_words(name)
name = regexprep(name, '([A-Z]+)([A-Z][a-z])', '$1_$2');
name = regexprep(name, '([a-z0-9])([A-Z])', '$1_$2');
words = regexp(lower(name), '[a-z]+|\d+', 'match');
end

function tf = classified_text_path(path)
location = lower(strjoin(path, '.'));
top = {'eeg.setname', 'eeg.filename', 'eeg.filepath', 'eeg.subject', ...
    'eeg.session', 'eeg.run', 'eeg.comments', 'eeg.history', 'eeg.group', ...
    'eeg.condition', 'eeg.ref', 'eeg.saved', 'eeg.datfile', ...
    'eeg.splinefile', 'eeg.icasplinefile', 'eeg.eventdescription', ...
    'eeg.epochdescription', 'eeg.chaninfo.nosedir', 'eeg.etc.eeglabvers', ...
    'eeg.dipfit.coordformat'};
if any(strcmp(location, top))
    tf = true;
    return
end
if numel(path) < 3
    tf = false;
    return
end
parent = lower(path{end - 1});
name = lower(path{end});
if any(strcmp(parent, {'chanlocs', 'urchanlocs'}))
    tf = any(strcmp(name, {'labels', 'type', 'ref'}));
elseif any(strcmp(parent, {'event', 'urevent'}))
    tf = any(strcmp(name, {'type', 'code', 'channel', 'annotation', 'urtype'}));
elseif strcmp(parent, 'epoch')
    tf = any(strcmp(name, {'eventtype', 'eventcode', 'eventchannel', ...
        'eventannotation', 'eventurtype'}));
elseif strcmp(parent, 'model') && contains(location, '.dipfit.')
    tf = strcmp(name, 'label');
else
    tf = strcmp(name, 'classes') && contains(location, '.ic_classification.');
end
end

function assert_safe_text(text, path, privacy)
lowerText = lower(text);
pathLike = contains(lowerText, 'raw_orig') || ...
    ~isempty(regexp(text, ...
    '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', 'once')) || ...
    ~isempty(regexp(text, '(^|[\s\(\[\{<"''=:;,])/[A-Za-z0-9._~\-]', ...
    'once')) || ~isempty(regexp(text, '[A-Za-z]:[\\/]', 'once')) || ...
    ~isempty(regexp(text, '\\\\[^\\\s]+\\[^\\\s]+', 'once')) || ...
    ~isempty(regexp(text, '//[^/\s]+/[^/\s]+', 'once')) || ...
    ~isempty(regexp(text, ...
    '(^|[\s\(\[\{<"''=:;,])~[\\/][^\s\)\]\}>"'';,]+', 'once')) || ...
    ~isempty(regexp(text, ...
    '(^|[\s\(\[\{<"''=:;,])\.\.?[\\/][^\s\)\]\}>"'';,]+', 'once')) || ...
    ~isempty(regexp(text, ...
    ['(^|[\s\(\[\{<"''=:;,])(?:[A-Za-z0-9._-]+[\\/])+' ...
     '(?=[A-Za-z0-9_.-]*[A-Za-z])[A-Za-z0-9_-]+' ...
     '(?:\.[A-Za-z0-9_-]{1,12})+' ...
     '($|[\.\!\?\s\)\]\}>"'';,:])'], ...
    'once')) || ~isempty(regexpi(text, ...
    ['(^|[\s\(\[\{<"''=:;,])(?:[A-Za-z0-9._ -]+[\\/])+' ...
     '[A-Za-z0-9._ -]+\.(?:set|fdt|mat|nii(?:\.gz)?|csv|tsv|xls|xlsx|' ...
     'txt|json|xml|vhdr|vmrk|dat|cdt(?:\.(?:dpa|ceo))?|dap|dpa|' ...
     'ceo|cef|rs3|xdf|edf|bdf|cnt|eeg)' ...
     '($|[\.\!\?\s\)\]\}>"'';,:])'], ...
    'once'));
if pathLike
    fail('ResidualIdentifier', privacy, strjoin(path, '.'), ...
        'Residual path-like or identifying text remains in the SET metadata.');
end
for index = 1:numel(privacy.subject_tokens)
    if blocked_token_present(lowerText, privacy.subject_tokens(index), true)
        fail('ResidualIdentifier', privacy, strjoin(path, '.'), ...
            'A blocked source token remains in the SET metadata.');
    end
end
for index = 1:numel(privacy.blocked_tokens)
    if blocked_token_present(lowerText, privacy.blocked_tokens(index))
        fail('ResidualIdentifier', privacy, strjoin(path, '.'), ...
            'A blocked source token remains in the SET metadata.');
    end
end
end

function tf = blocked_token_present(text, token, strict)
if nargin < 3
    strict = false;
end
text = lower(char(text));
token = lower(char(token));
shortNumeric = ~isempty(regexp(token, '^\d{1,2}$', 'once'));
if strict && shortNumeric
    pattern = ['(^|[^0-9\.])' regexptranslate('escape', token) ...
        '($|[^0-9\.])'];
    tf = ~isempty(regexp(text, pattern, 'once'));
elseif shortNumeric
    pattern = ['(^|[^a-z0-9])' regexptranslate('escape', token) ...
        '($|[^a-z0-9])'];
    tf = ~isempty(regexp(text, pattern, 'once'));
else
    tf = contains(text, token);
end
end

function location = redacted_location(path)
path{end} = '<redacted-field-1>';
location = strjoin(path, '.');
end

function tf = effectively_empty(value)
if isempty(value)
    tf = true;
elseif ischar(value)
    tf = isempty(strtrim(value));
elseif isstring(value)
    tf = all(ismissing(value) | strlength(strtrim(value)) == 0);
elseif iscell(value)
    tf = all(cellfun(@effectively_empty, value));
else
    tf = false;
end
end

function fail(identifier, privacy, location, message)
prefix = '';
if isnumeric(privacy.row_number) && isscalar(privacy.row_number) && ...
        isfinite(privacy.row_number)
    prefix = sprintf('Registry row %d: ', privacy.row_number);
end
if ~isempty(location)
    message = sprintf('%s Location: %s.', message, location);
end
error(['SIMPLE:Step2Sanitise:' identifier], '%s%s', prefix, message);
end
