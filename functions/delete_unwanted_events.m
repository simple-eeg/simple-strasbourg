function [EEG_out, report] = delete_unwanted_events(EEG_in, match_labels)
% DELETE_UNWANTED_EVENTS  Remove events whose TYPE matches specified labels, then rebuild consistency.
%
% Purpose
%   This helper removes events that are known to be irrelevant for analysis (e.g., those
%   previously marked as 'NA'). It performs exact, case-insensitive matching on event TYPE,
%   deletes matching events, and then calls EEGLAB's event consistency routine to restore
%   ordering and indices. Data samples are not modified.
%
% Usage
%   [EEG_out, report] = delete_unwanted_events(EEG_in)
%   [EEG_out, report] = delete_unwanted_events(EEG_in, {'NA','bad','skip'})
%
% Inputs
%   EEG_in        : EEGLAB EEG struct. Event fields and associated consistency
%                   bookkeeping may change; data samples are unchanged.
%   match_labels  : Labels to remove. Accepts char, string, string array, or cellstr.
%                   Comparison is case-insensitive and exact (no substring matching).
%                   Default = {'NA'}.
%
% Outputs
%   EEG_out       : EEG struct with matching events removed. Event consistency is rebuilt.
%   report        : Struct with transparent provenance of the operation:
%                     .total_before     : number of events before deletion
%                     .removed_count    : number of events removed
%                     .total_after      : number of events after deletion
%                     .removed_by_label : struct mapping label -> count removed (lower-cased keys)
%                     .labels_requested : cellstr of normalized labels that were matched against
%                     .notes            : cellstr of informational notes/warnings
%
% Notes
%   - Only exact label matches are removed (after lower-casing and trimming).
%   - Event TYPE values are normalized to char for comparison (string/numeric are coerced).
%   - If there are no events, the function returns immediately with zero counts.
%   - This function does not print to console; callers should handle user-facing logging.
%
% Dependencies
%   - EEGLAB's eeg_checkset.m (used with 'eventconsistency')
%
% See also: eeg_checkset

% -------- Defaults and defensive copies --------
if nargin < 2 || isempty(match_labels)
    match_labels = {'NA'};
end
EEG_out = EEG_in;

% Initialize 'report' as a SCALAR struct (avoid struct(...) with {} which yields 0x0 struct)
% Build field-by-field so empty cells (e.g., {}) do not collapse the struct to 0x0.
report = struct();
report.total_before     = 0;
report.removed_count    = 0;
report.total_after      = 0;
report.removed_by_label = struct();   % container for dynamic tallies
report.labels_requested = {};         % OK to assign {} AFTER struct exists
report.notes            = {};         % OK to assign {} AFTER struct exists

assert(isstruct(report) && isscalar(report), 'Internal: report must be scalar after init.');

% -------- Early exit when no events to process --------
if ~isfield(EEG_in, 'event') || isempty(EEG_in.event)
    report.total_before     = 0;
    report.total_after      = 0;
    report.labels_requested = i_norm_label_list(match_labels);
    report.notes            = {'No events present; nothing to delete.'};
    return
end

% -------- Normalize requested labels (lower-case, trimmed) --------
labels_lc = i_norm_label_list(match_labels);

% Belt-and-braces: ensure 'report' is still a scalar struct before any dot-assignments
if ~isstruct(report) || isempty(report) || ~isscalar(report)
    report = struct();
    report.total_before     = 0;
    report.removed_count    = 0;
    report.total_after      = 0;
    report.removed_by_label = struct();
    report.labels_requested = {};
    report.notes            = {};
end

report.labels_requested = labels_lc;
if isempty(labels_lc)
    report.total_before = numel(EEG_in.event);
    report.total_after  = report.total_before;
    report.notes        = {'Empty match label list; nothing to delete.'};
    return
end

% -------- Snapshot total count before deletion --------
total_before        = numel(EEG_in.event);
report.total_before = total_before;

% -------- Normalize event TYPE values to comparable char --------
% We coerce each event.type to a trimmed char. Strings and numerics are converted.
% Empty/missing values become '' (and will not match any non-empty label).
types_char = cell(1, total_before);
for k = 1:total_before
    t = [];
    if isfield(EEG_in.event, 'type')
        t = EEG_in.event(k).type;
    end
    if iscell(t)
        if ~isempty(t)
            t = t{1};
        else
            t = '';
        end
    end
    if isstring(t)
        t = char(t);
    elseif isnumeric(t)
        t = num2str(t);
    end
    if ischar(t)
        t = strtrim(t);
    else
        t = '';
    end
    types_char{k} = t;
end
types_lc = lower(types_char);

% -------- Build deletion mask: exact, case-insensitive matches --------
delMask = ismember(types_lc, labels_lc);
nDel    = sum(delMask);

% -------- Apply deletion and rebuild event consistency (if needed) --------
if nDel > 0
    EEG_out.event(delMask) = [];
    EEG_out = eeg_checkset(EEG_out, 'eventconsistency');
end

% -------- Compose removal tallies per label (lower-cased keys) --------
% Guarantee scalar struct for dynamic fieldnames.
removed_by_label = struct();
assert(isscalar(removed_by_label), 'Internal: removed_by_label must be scalar.');
report_keys = i_unique_report_keys(labels_lc);
if nDel > 0
    removed_types_lc = types_lc(delMask);
    for i = 1:numel(labels_lc)
        removed_by_label.(report_keys{i}) = ...
            sum(strcmp(removed_types_lc, labels_lc{i}));
    end
else
    for i = 1:numel(labels_lc)
        removed_by_label.(report_keys{i}) = 0;
    end
end

% -------- Finalize report --------
report.removed_count    = nDel;
report.total_after      = numel(EEG_out.event);
report.removed_by_label = removed_by_label;
if nDel == 0
    report.notes = {'No matching events found; no deletions performed.'};
else
    report.notes = {sprintf('Deleted %d event(s) matching requested label(s).', nDel)};
end

end

% =========================================================================
% Helpers (local)
% =========================================================================

function labels_lc = i_norm_label_list(match_labels)
% Normalize a heterogeneous label list into a flat, lower-cased, trimmed cellstr.
% Drops empty entries.

labels_lc = {};
if isstring(match_labels)
    match_labels = cellstr(match_labels);
elseif ischar(match_labels)
    match_labels = {match_labels};
elseif iscell(match_labels)
    % keep as is
else
    match_labels = {};
end

for j = 1:numel(match_labels)
    v = match_labels{j};
    if isstring(v),  v = char(v); end
    if isnumeric(v), v = num2str(v); end
    if ischar(v)
        s = strtrim(v);
        if ~isempty(s)
            labels_lc{end+1} = lower(s); %#ok<AGROW>
        end
    end
end

% Deduplicate while preserving order of first occurrence
if ~isempty(labels_lc)
    [~, firstIdx] = unique(labels_lc, 'stable');
    labels_lc = labels_lc(sort(firstIdx));
end
end

function f = i_safe_fieldname(key)
% Make a safe struct fieldname from an arbitrary label by replacing non-word chars.
% Lower-case is assumed; this is used only for reporting.
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
