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
%                'allow_oob'           → create them anyway; downstream epoching may drop them.
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
%     If applied to epoched data, the computed bounds use total points = EEG.pnts * EEG.trials.
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

% Validate sampling rate and offset.
if ~isfield(EEG_in,'srate') || ~isscalar(EEG_in.srate) || ~(EEG_in.srate > 0)
    error('add_offset_events:InvalidSRate', 'EEG.srate must be a positive scalar.');
end
if ~isscalar(offset_ms) || ~isfinite(offset_ms)
    error('add_offset_events:InvalidOffset', 'offset_ms must be a finite scalar.');
end

% Normalize src_types and new_types to flat cellstr; enforce length equality.
src_types = i_norm_type_list(src_types);
new_types = i_norm_type_list(new_types);
if numel(src_types) ~= numel(new_types) || isempty(src_types)
    error('add_offset_events:TypeListMismatch', ...
        'src_types and new_types must be non-empty cell arrays of the same length.');
end

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
offset_samp = round((offset_ms / 1000) * EEG_in.srate);

% Determine the valid latency bounds (inclusive) across the dataset.
% For continuous data: [1, EEG_in.pnts]; for epoched: [1, EEG_in.pnts * EEG_in.trials].
total_points = EEG_in.pnts * max(1, EEG_in.trials);
lower_bound  = 1;
upper_bound  = total_points;

% Prepare per-type tallies (for report).
per_type_added = struct();
for i = 1:numel(new_types)
    per_type_added.(i_safe_fieldname(new_types{i})) = 0;
end

% Track which source labels had zero matches (for report).
missing_sources = src_types(:)';  % start with all; remove as we find matches

% Iterate over events; when TYPE matches a src label, create a new event with mapped new TYPE.
added = 0;
skipped_oob = 0;

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
    if lat_new < lower_bound || lat_new > upper_bound
        if strcmpi(policy, 'skip_oob')
            skipped_oob = skipped_oob + 1;
            continue
        elseif ~strcmpi(policy, 'allow_oob')
            error('add_offset_events:BadPolicy', 'Unknown policy "%s". Use "skip_oob" or "allow_oob".', policy);
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

    % Tally by new TYPE.
    key = i_safe_fieldname(new_ev.type);
    per_type_added.(key) = per_type_added.(key) + 1;
    added = added + 1;
end

% Rebuild event consistency (sort by latency, recompute bookkeeping).
if added > 0
    EEG_out = eeg_checkset(EEG_out, 'eventconsistency');
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

% Deduplicate while preserving first occurrence order.
if ~isempty(out)
    [~, idx] = unique(out, 'stable');
    out = out(sort(idx));
end
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
end
end