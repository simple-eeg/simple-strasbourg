function [EEG_out, report] = add_offset_events(EEG_in, src_types, offset_ms, new_types, annotation, policy)
% ADD_OFFSET_EVENTS  Create per-source dummy events at a fixed time offset.
%
% Purpose
%   For each occurrence of a source event type, add a new "dummy" event at a fixed time
%   offset (e.g., -2000 ms for a prestim marker). Each source type maps to its own new
%   type label (e.g., 'heellance' -> 'heellance_prestim'), allowing per-condition analysis
%   of dummy epochs alongside true epochs.
%
% Usage
%   [EEG_out, report] = add_offset_events(EEG_in, ...
%       {'heellance','controlheellance'}, -2000, ...
%       {'heellance_prestim','controlheellance_prestim'});
%
%   [EEG_out, report] = add_offset_events(EEG_in, src_types, offset_ms, new_types, {'manually_added_dummy'}, 'skip_oob');
%
% Inputs
%   EEG_in     : EEGLAB EEG struct. Expected to be continuous in typical usage.
%                The function only mutates .event and associated consistency bookkeeping.
%
%   src_types  : Cellstr (or string array / char) of source event TYPEs to anchor from.
%                Matching is case-sensitive and exact (no substring matching).
%
%   offset_ms  : Scalar time offset in milliseconds. Negative for prestim, positive allowed.
%                The offset is converted to an integer number of samples using EEG.srate.
%
%   new_types  : Cellstr (or string array / char) of new TYPE names, same length/order as src_types.
%                Each src_types{i} maps to new_types{i}. Types are stored exactly as provided.
%
%   annotation : Optional. If present in the dataset, the new events' ANNOTATION field will be set
%                to this value. To match your dataset convention, this parameter is normalized to a
%                1x1 cell of char (e.g., {'manually_added_dummy'}). If the existing events do not
%                have an 'annotation' field, this assignment is skipped. Default = {'manually_added_dummy'}.
%
%   policy     : Optional out-of-bounds policy for computed latencies:
%                'skip_oob' (default)  → do not create events whose new latency is < 1 or > data end;
%                'allow_oob'           → on continuous data, create them anyway so downstream
%                                        epoching may drop them. Rejected for already epoched data.
%
% Outputs
%   EEG_out    : EEG struct with new events appended and event consistency rebuilt.
%
%   report     : Struct summarizing outcomes for transparent provenance:
%                  .total_before      : number of events before additions
%                  .added_count       : number of new events added
%                  .skipped_oob_count : number of candidate additions skipped by policy
%                  .total_after       : number of events after additions
%                  .per_type_added    : struct mapping new_type -> count added (safe fieldnames)
%                  .missing_sources   : cellstr of src_types with no matches in the data
%                  .notes             : cellstr of informational notes/warnings
%
% Field-handling policy
%   - Required fields (always set): TYPE, LATENCY.
%   - ANNOTATION: only set if the dataset already has an 'annotation' field; stored as 1x1 cell of char.
%   - URTYPE / URLATENCY: if present in the dataset, set to 'NA' and NaN respectively for new events.
%   - DURATION: if present, set to [] (neutral). If copying the anchor duration is preferred later,
%     this line can be trivially adjusted.
%
% Important notes
%   - This function is designed for pre-epoching, continuous datasets (EEG.trials == 1).
%     With skip_oob, epoched-data bounds use total points = EEG.pnts * EEG.trials.
%   - Event matching is case-sensitive to avoid surprising collisions. If you want case-insensitive
%     behavior, normalize src_types and existing TYPEs to a common case before calling.
%   - The function does not print to the console; callers should handle user-facing logging.
%
% Dependencies
%   - EEGLAB's eeg_checkset.m (used with 'eventconsistency')
%
% See also: delete_unwanted_events, eeg_checkset

% -------- Defaults, normalization, and defensive copies --------
if nargin < 5 || isempty(annotation)
    annotation = {'manually_added_dummy'}; % dataset convention: 1x1 cell
end
if nargin < 6 || isempty(policy)
    policy = 'skip_oob';
end

if isstring(policy)
    if ~isscalar(policy) || ismissing(policy)
        error('add_offset_events:BadPolicy', ...
            'Unknown policy. Use "skip_oob" or "allow_oob".');
    end
    policy = char(policy);
end
if ~ischar(policy) || size(policy, 1) ~= 1
    error('add_offset_events:BadPolicy', ...
        'Unknown policy. Use "skip_oob" or "allow_oob".');
end
policy = lower(strtrim(policy));
if ~ismember(policy, {'skip_oob', 'allow_oob'})
    error('add_offset_events:BadPolicy', ...
        'Unknown policy "%s". Use "skip_oob" or "allow_oob".', policy);
end
if strcmp(policy, 'allow_oob') && isfield(EEG_in, 'trials') && ...
        isnumeric(EEG_in.trials) && isscalar(EEG_in.trials) && ...
        EEG_in.trials > 1
    error('add_offset_events:AllowOobRequiresContinuous', ...
        ['allow_oob is supported only for continuous data because an event ' ...
        'outside all epochs cannot have consistent EEG.epoch bookkeeping.']);
end

% Validate numerical inputs even when there are no matching events. This
% prevents malformed settings from being silently accepted on a no-op route.
if ~isfield(EEG_in,'srate') || ~isnumeric(EEG_in.srate) || ...
        ~isreal(EEG_in.srate) || ~isscalar(EEG_in.srate) || ...
        ~isfinite(EEG_in.srate) || ~(EEG_in.srate > 0)
    error('add_offset_events:InvalidSRate', ...
        'EEG.srate must be a finite positive real numeric scalar.');
end
if ~isnumeric(offset_ms) || ~isreal(offset_ms) || ...
        ~isscalar(offset_ms) || ~isfinite(offset_ms)
    error('add_offset_events:InvalidOffset', ...
        'offset_ms must be a finite real numeric scalar.');
end
sampling_rate = double(EEG_in.srate);
offset_ms_numeric = double(offset_ms);

EEG_out = EEG_in;

report = struct( ...
    'total_before',      0, ...
    'added_count',       0, ...
    'skipped_oob_count', 0, ...
    'total_after',       0, ...
    'per_type_added',    struct(), ...
    'missing_sources',   {{}}, ...
    'notes',             {{}});

% Early exit: no events present → nothing to add.
if ~isfield(EEG_in,'event') || isempty(EEG_in.event)
    report.total_before = 0;
    report.total_after  = 0;
    report.notes = {'No events present; no offset events added.'};
    return
end

% Normalize src_types and new_types to flat cellstr; enforce length equality.
src_types = i_norm_type_list(src_types);
new_types = i_norm_type_list(new_types);
if numel(src_types) ~= numel(new_types) || isempty(src_types)
    error('add_offset_events:TypeListMismatch', ...
        'src_types and new_types must be non-empty cell arrays of the same length.');
end
[src_types, new_types] = i_validate_and_deduplicate_pairs( ...
    src_types, new_types);

% Normalize annotation parameter to a 1x1 cell of char (dataset convention).
annotation_cell = i_norm_annotation_cell(annotation);

% Identify optional fields present in the dataset.
has_annotation = isfield(EEG_in.event, 'annotation');
has_urtype     = isfield(EEG_in.event, 'urtype');
has_urlatency  = isfield(EEG_in.event, 'urlatency');
has_duration   = isfield(EEG_in.event, 'duration');

% Snapshot counts before modifications.
total_before = numel(EEG_in.event);
report.total_before = total_before;

% Build mapping src -> new for quick lookup.
% We preserve user-provided casing for new_types.
map_new_by_src = containers.Map();
for i = 1:numel(src_types)
    map_new_by_src(src_types{i}) = new_types{i};
end

% Normalize existing TYPE values to trimmed char for exact matching.
types_char = cell(1, total_before);
for k = 1:total_before
    t = EEG_in.event(k).type;
    if iscell(t), t = i_first_or_empty(t); end
    if isstring(t), t = char(t); end
    if isnumeric(t), t = num2str(t); end
    if ischar(t), t = strtrim(t); else, t = ''; end
    types_char{k} = t;
end

% Convert offset from milliseconds to an *integer* number of samples on the current grid.
offset_samp = round((offset_ms_numeric / 1000) * sampling_rate);

% Determine the valid latency bounds (inclusive) across the dataset.
% For continuous data: [1, EEG_in.pnts]; for epoched: [1, EEG_in.pnts * EEG_in.trials].
total_points = EEG_in.pnts * max(1, EEG_in.trials);
lower_bound  = 1;
upper_bound  = total_points;

% Prepare per-type tallies (for report).
per_type_added = struct();
report_types = i_unique_strings_stable(new_types);
report_keys = i_unique_report_keys(report_types);
report_key_by_new_type = containers.Map(report_types, report_keys);
for i = 1:numel(report_types)
    per_type_added.(report_keys{i}) = 0;
end

% Track which source labels had zero matches (for report).
missing_sources = src_types(:)';  % start with all; remove as we find matches

% Iterate over events; when TYPE matches a src label, create a new event with mapped new TYPE.
added = 0;
skipped_oob = 0;
protected_oob_indices = [];
protected_oob_latencies = [];

for k = 1:total_before
    t_src = types_char{k};
    if isempty(t_src), continue; end
    if ~map_new_by_src.isKey(t_src)
        continue
    end

    % Found at least one match for this source label; remove it from missing list.
    missing_sources(strcmp(missing_sources, t_src)) = [];

    % Compute new latency (integer samples).
    lat_anchor = EEG_in.event(k).latency;
    if iscell(lat_anchor), lat_anchor = i_first_or_empty(lat_anchor); end
    lat_anchor = double(lat_anchor);
    if ~isfinite(lat_anchor), continue; end % defensive

    lat_new = round(lat_anchor + offset_samp);

    % Apply out-of-bounds policy.
    is_out_of_bounds = lat_new < lower_bound || lat_new > upper_bound;
    if is_out_of_bounds
        if strcmp(policy, 'skip_oob')
            skipped_oob = skipped_oob + 1;
            continue
        end
    end

    % Create the new event by cloning the anchor to preserve field parity, then overwrite keys.
    new_ev = EEG_in.event(k);

    % TYPE (required).
    new_ev.type = map_new_by_src(t_src);

    % LATENCY (required).
    new_ev.latency = lat_new;

    % ANNOTATION (only if field exists in dataset).
    if has_annotation
        new_ev.annotation = annotation_cell; % 1x1 cell of char by convention
    end

    % URTYPE/URLATENCY (only if fields exist).
    if has_urtype
        new_ev.urtype = 'NA';
    end
    if has_urlatency
        new_ev.urlatency = NaN;
    end

    % DURATION (neutralize if present).
    if has_duration
        new_ev.duration = [];
    end

    % Append the new event.
    EEG_out.event(end+1) = new_ev; %#ok<AGROW>
    if is_out_of_bounds
        protected_oob_indices(end+1) = numel(EEG_out.event); %#ok<AGROW>
        protected_oob_latencies(end+1) = lat_new; %#ok<AGROW>
    end

    % Tally by new TYPE.
    key = report_key_by_new_type(new_ev.type);
    per_type_added.(key) = per_type_added.(key) + 1;
    added = added + 1;
end

% Rebuild event consistency (sort by latency, recompute bookkeeping).
if added > 0
    EEG_out = i_eventconsistency_preserve_oob(EEG_out, ...
        protected_oob_indices, protected_oob_latencies, ...
        lower_bound, upper_bound);
end

% Compose report.
report.added_count       = added;
report.skipped_oob_count = skipped_oob;
report.total_after       = numel(EEG_out.event);
report.per_type_added    = per_type_added;
report.missing_sources   = missing_sources;
if added == 0
    if isempty(missing_sources)
        report.notes = {'No new events added (all candidates were out-of-bounds or duplicate conditions not met).'};
    else
        report.notes = {sprintf('No new events added; no matches for source types: %s', strjoin(missing_sources, ', '))};
    end
else
    msg = sprintf('Added %d new event(s) at %g ms offset.', added, offset_ms);
    if skipped_oob > 0
        msg = sprintf('%s Skipped %d out-of-bounds candidate(s) by policy.', msg, skipped_oob);
    end
    report.notes = {msg};
end
end

% =========================================================================
% Helpers (local)
% =========================================================================

function EEG_out = i_eventconsistency_preserve_oob(EEG_out, ...
    protected_indices, protected_latencies, lower_bound, upper_bound)
% Run EEGLAB consistency without letting its bounds check erase events that
% the caller explicitly requested through the allow_oob policy.

if isempty(protected_indices)
    EEG_out = eeg_checkset(EEG_out, 'eventconsistency');
    return
end

marker_field = 'simple_offset_event_internal_id';
while isfield(EEG_out.event, marker_field) || ...
        (isfield(EEG_out, 'epoch') && ~isempty(EEG_out.epoch) && ...
        isfield(EEG_out.epoch, ['event', marker_field]))
    marker_field = [marker_field, '_']; %#ok<AGROW>
end
[EEG_out.event.(marker_field)] = deal(0);

for idx = 1:numel(protected_indices)
    event_index = protected_indices(idx);
    EEG_out.event(event_index).(marker_field) = idx;
    EEG_out.event(event_index).latency = min(max( ...
        protected_latencies(idx), lower_bound), upper_bound);
end

EEG_out = eeg_checkset(EEG_out, 'eventconsistency');
markers = [EEG_out.event.(marker_field)];
for idx = 1:numel(protected_latencies)
    event_index = find(markers == idx);
    if numel(event_index) ~= 1
        error('add_offset_events:ConsistencyFailure', ...
            ['EEGLAB event consistency did not preserve one protected ' ...
            'allow_oob event.']);
    end
    EEG_out.event(event_index).latency = protected_latencies(idx);
end

% For epoched inputs, eventconsistency copies every temporary event field
% into EEG.epoch. Remove that private copy as well as its optional event
% description entry before returning the public structure.
epoch_marker_field = ['event', marker_field];
if isfield(EEG_out, 'epoch') && ~isempty(EEG_out.epoch) && ...
        isfield(EEG_out.epoch, epoch_marker_field)
    EEG_out.epoch = rmfield(EEG_out.epoch, epoch_marker_field);
end
event_fields = fieldnames(EEG_out.event);
marker_description_index = find(strcmp(event_fields, marker_field), 1);
if isfield(EEG_out, 'eventdescription') && ...
        numel(EEG_out.eventdescription) >= marker_description_index
    EEG_out.eventdescription(marker_description_index) = [];
end
EEG_out.event = rmfield(EEG_out.event, marker_field);

% eeg_checkset sorted using the temporary in-bounds latencies. Re-sort after
% restoring the intentional out-of-bounds values without running its bounds
% deletion a second time.
[~, order] = sort([EEG_out.event.latency], 'ascend');
EEG_out.event = EEG_out.event(order);
end

function out = i_norm_type_list(x)
% Normalize a heterogeneous type list to a flat cellstr of trimmed char.
% Accepts char, string, string array, or cellstr; drops empties.

if nargin == 0 || isempty(x)
    out = {};
    return
end

if isstring(x)
    x = cellstr(x);
elseif ischar(x)
    x = {x};
elseif iscell(x)
    % keep
else
    out = {};
    return
end

out = {};
for i = 1:numel(x)
    v = x{i};
    if iscell(v), v = i_first_or_empty(v); end
    if isstring(v),  v = char(v); end
    if isnumeric(v), v = num2str(v); end
    if ischar(v)
        s = strtrim(v);
        if ~isempty(s)
            out{end+1} = s; %#ok<AGROW>
        end
    end
end

end

function [sources, targets] = i_validate_and_deduplicate_pairs(sources, targets)
% Preserve row-wise mappings. Repeated identical mappings are harmless, but
% one source cannot be assigned two different target labels.
unique_sources = {};
unique_targets = {};
for idx = 1:numel(sources)
    prior = find(strcmp(unique_sources, sources{idx}), 1);
    if isempty(prior)
        unique_sources{end+1} = sources{idx}; %#ok<AGROW>
        unique_targets{end+1} = targets{idx}; %#ok<AGROW>
    elseif ~strcmp(unique_targets{prior}, targets{idx})
        error('add_offset_events:TypeMappingConflict', ...
            'Source type "%s" maps to more than one target type.', ...
            sources{idx});
    end
end
sources = unique_sources;
targets = unique_targets;
end

function values = i_unique_strings_stable(values)
% Deduplicate a cellstr while preserving first occurrence order.
unique_values = {};
for idx = 1:numel(values)
    if ~any(strcmp(unique_values, values{idx}))
        unique_values{end+1} = values{idx}; %#ok<AGROW>
    end
end
values = unique_values;
end

function c = i_norm_annotation_cell(a)
% Normalize an annotation parameter to a 1x1 cell of char.
% If a is already a cell, take its first non-empty, else default to 'manually_added_dummy'.

default = 'manually_added_dummy';

if nargin == 0 || isempty(a)
    c = {default};
    return
end

if iscell(a)
    if isempty(a)
        c = {default};
        return
    end
    v = i_first_or_empty(a);
else
    v = a;
end

if isstring(v),  v = char(v); end
if isnumeric(v), v = num2str(v); end
if ~ischar(v) || isempty(strtrim(v))
    v = default;
end
c = {strtrim(v)};
end

function v = i_first_or_empty(c)
% Return the first element of a cell array if present; otherwise ''.
if isempty(c)
    v = '';
else
    v = c{1};
end
end

function f = i_safe_fieldname(key)
% Make a safe struct fieldname from an arbitrary label by replacing non-word chars.
f = regexprep(key, '[^a-zA-Z0-9_]', '_');
if isempty(f)
    f = 'x';
elseif ~isletter(f(1))
    f = ['x', f];
end
f = f(1:min(numel(f), namelengthmax));
if ~isvarname(f)
    f = ['x_', f];
    f = f(1:min(numel(f), namelengthmax));
end
end

function keys = i_unique_report_keys(labels)
% Make deterministic, valid and collision-free report fields while retaining
% the readable key whenever its sanitised form is already unique.
keys = cell(size(labels));
used = {};
for idx = 1:numel(labels)
    base = i_safe_fieldname(labels{idx});
    candidate = base;
    suffix_number = 2;
    while any(strcmp(used, candidate))
        suffix = sprintf('_%d', suffix_number);
        keep = namelengthmax - numel(suffix);
        candidate = [base(1:min(numel(base), keep)), suffix];
        suffix_number = suffix_number + 1;
    end
    keys{idx} = candidate;
    used{end+1} = candidate; %#ok<AGROW>
end
end
