%% step_6_screen_2_viewer_rate_epochs.m
% Purpose
%   - Load screening_package.mat (workflow-fixed) from data/summary/screening/
%   - Create/load screening_decisions.mat (mutable)
%   - Provide a mouse-only viewer to rate (exclude/un-exclude) each epoch–channel item
%   - Autosave decisions atomically on each decision change
%   - Save the complete current viewer (plots and Navigator) to PDF on request
%
% Notes (current behaviour)
%   - Screening unit is the epoch–channel pair ("item").
%   - Start at the first included item at launch (or first excluded if none included).
%   - Prev/Next steps within the currently selected view (Included or Excluded).
%   - QC swarm plots are computed using INCLUDED-AT-LAUNCH items only, with channel conditioning
%     set by QC_REF_CHANNEL_MODE; in 'current_channel' mode, channel matching is case-insensitive (after trimming).
%   - Missing QC for the current item: leave that QC subplot blank, title shows "missing".
%   - If a view has no items, plots are cleared and a "No items in this view" message is shown; controls are disabled.
%   - Colours:
%       • Swarm points: blue
%       • Current marker/line: red
%       • If browsing Excluded view and the item was excluded-at-launch: grey marker/line

log_command_window('start');
clear; clc;

%% User-editable paths
baseDir      = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
screeningDir = fullfile(baseDir, 'data', 'summary', 'screening');

packagePath  = fullfile(screeningDir, 'screening_package.mat');
decPath      = fullfile(screeningDir, 'screening_decisions.mat');
hashSchema   = 'screening-package-source-sha256-v2';

%% User-editable plotting defaults
fixed_ylim_units  = [-100, 100];    % same units as stored in epochs_pooled.data
time_xlim_ms      = [-200, 1200];   % applied to both time-domain plots
psd_fmin_hz        = -1;
psd_fmax_hz        = 251;

%% User-editable global title display
% If true, show the global tiledlayout title (metadata about the current item).
% If false, do not show any global title.
SHOW_GLOBAL_TITLE = true;

%% User-defined QC reference distribution channel mode
% Controls which items contribute to the QC swarm "reference distribution".
% - 'current_channel': use only items from the same channel as the current item
%                      (intended to be case-insensitive, e.g., 'Cz' == 'CZ')
% - 'all_channels'   : use items from all channels (still restricted to included-at-launch)
QC_REF_CHANNEL_MODE = 'current_channel';  % 'current_channel' or 'all_channels'

%% User-defined QC feature list (required; 1–9 entries; case-sensitive)
% - Use a cell array of character vectors (consistent with the rest of the pipeline).
% - Leading/trailing whitespace is ignored for matching (strtrim applied).
% - Duplicates are allowed and will produce duplicated subplots with identical titles.
QC_FEATURE_LIST = { ...
    'maxAbsEpoch', ...
    'sdEpoch', ...
    'invSdEpoch', ...
    'MeanAbsDiffNorm', ...
    'MaxAbsDiffNorm', ...
    'RobustSlopeNorm', ...
    'AutoCorrLag1Pos', ...
    'AutoCorrLag1Neg', ...
    'KatzFDNorm' ...
    };

%% User-defined QC box overlay (one-sided: upper whisker only)
% Draw a box summary over the QC swarm:
%   - Box spans q1..q3, median at q2
%   - Upper whisker starts at q3 and extends in the positive direction only
%   - No outlier markers
QC_BOXPLOT_WHISKER = 6;              % multiplier w in q3 + w*IQR
QC_BOXPLOT_WHISKER_MODE = "threshold"; % "threshold" or "adjacent"

%% Validate/normalise SHOW_GLOBAL_TITLE (accept true/false or 1/0)
assert(isscalar(SHOW_GLOBAL_TITLE), 'SHOW_GLOBAL_TITLE must be a scalar logical/numeric value.');
SHOW_GLOBAL_TITLE = logical(SHOW_GLOBAL_TITLE);

%% Validate/normalise QC_REF_CHANNEL_MODE (accept char or string; normalise case/whitespace)
QC_REF_CHANNEL_MODE = lower(strtrim(string(QC_REF_CHANNEL_MODE)));
validModes = ["current_channel", "all_channels"];
assert(any(QC_REF_CHANNEL_MODE == validModes), ...
    'QC_REF_CHANNEL_MODE must be ''current_channel'' or ''all_channels'' (got: "%s").', QC_REF_CHANNEL_MODE);

% Keep as char for consistency with the rest of the script
QC_REF_CHANNEL_MODE = char(QC_REF_CHANNEL_MODE);

%% Validate/normalise QC box overlay settings
assert(isnumeric(QC_BOXPLOT_WHISKER) && isscalar(QC_BOXPLOT_WHISKER) && isfinite(QC_BOXPLOT_WHISKER) && QC_BOXPLOT_WHISKER > 0, ...
    'QC_BOXPLOT_WHISKER must be a positive numeric scalar.');

QC_BOXPLOT_WHISKER_MODE = lower(strtrim(string(QC_BOXPLOT_WHISKER_MODE)));
validWhModes = ["threshold", "adjacent"];
assert(any(QC_BOXPLOT_WHISKER_MODE == validWhModes), ...
    'QC_BOXPLOT_WHISKER_MODE must be "threshold" or "adjacent" (got: "%s").', QC_BOXPLOT_WHISKER_MODE);

%% Validate QC feature list (strict, minimal assumptions)
assert(iscell(QC_FEATURE_LIST), 'QC_FEATURE_LIST must be a cell array of character vectors (use {''maxAbsEpoch'',''KatzFDNorm'',...}).');
assert(~isempty(QC_FEATURE_LIST), 'QC_FEATURE_LIST must contain at least 1 QC feature.');
assert(numel(QC_FEATURE_LIST) <= 9, 'QC_FEATURE_LIST has too many entries (max 9 for 3x4 layout). Found: %d.', numel(QC_FEATURE_LIST));

% Accept char vectors or string scalars only (avoid char(123) style surprises)
assert(all(cellfun(@(x) ischar(x) || (isstring(x) && isscalar(x)), QC_FEATURE_LIST)), ...
    'QC_FEATURE_LIST must contain only character vectors or string scalars.');

% Normalise to char vectors (consistent with rest of pipeline)
QC_FEATURE_LIST = cellfun(@char, QC_FEATURE_LIST, 'UniformOutput', false);

% Trim (no other normalisation; matching remains case-sensitive)
QC_FEATURE_LIST = cellfun(@strtrim, QC_FEATURE_LIST, 'UniformOutput', false);

% Guard against entries that become empty after trimming
assert(all(~cellfun(@isempty, QC_FEATURE_LIST)), 'QC_FEATURE_LIST contains an empty entry after trimming.');

%% Load package
assert(isfile(packagePath), 'Missing screening_package.mat: %s', packagePath);
P = load(packagePath);
assert(isfield(P, 'package'), 'screening_package.mat must contain variable "package".');
package = P.package;

if ~isfield(package, 'hash_schema')
    error('Screening:Viewer:MissingHashSchemaPackage', ...
        ['screening_package.mat has no hash_schema and cannot be used. ', ...
        'Create a package with the required hash schema separately; do not edit this file in place.']);
end
if isstring(package.hash_schema) && isscalar(package.hash_schema)
    package.hash_schema = char(package.hash_schema);
end
assert(ischar(package.hash_schema), 'package.hash_schema must be char or a string scalar convertible to char.');
if ~strcmp(package.hash_schema, hashSchema)
    error('Screening:Viewer:UnknownHashSchema', ...
        'Unsupported package hash schema "%s" (expected "%s").', package.hash_schema, hashSchema);
end

% Validate expected package fields (tight but readable)
needPkg = {'package_hash','source_hashes','items','epochs_pooled','qc_feature_names','qc_values'};
for k = 1:numel(needPkg)
    assert(isfield(package, needPkg{k}), 'package.%s missing from screening_package.mat', needPkg{k});
end
assert(istable(package.items), 'package.items must be a table.');
assert(isstruct(package.source_hashes) && isscalar(package.source_hashes), ...
    'package.source_hashes must be a scalar struct.');
needSourceHashes = {'epochs_sha256','qc_sha256','feature_list_sha256'};
for k = 1:numel(needSourceHashes)
    assert(isfield(package.source_hashes, needSourceHashes{k}), ...
        'package.source_hashes.%s missing from screening_package.mat', needSourceHashes{k});
end

package.package_hash = normalise_sha256(package.package_hash, 'package.package_hash');
package.source_hashes.epochs_sha256 = normalise_sha256( ...
    package.source_hashes.epochs_sha256, 'package.source_hashes.epochs_sha256');
package.source_hashes.qc_sha256 = normalise_sha256( ...
    package.source_hashes.qc_sha256, 'package.source_hashes.qc_sha256');
package.source_hashes.feature_list_sha256 = normalise_sha256( ...
    package.source_hashes.feature_list_sha256, 'package.source_hashes.feature_list_sha256');

qc_features_all = package.qc_feature_names;
qc_values_all   = package.qc_values;

% Accept cell array or string array; normalise once to cell array of char vectors
if isstring(qc_features_all)
    assert(~any(ismissing(qc_features_all(:))), 'package.qc_feature_names contains missing string entries.');
    qc_features_all = cellstr(qc_features_all);
end
assert(iscell(qc_features_all), 'package.qc_feature_names must be a cell array or string array.');
assert(all(cellfun(@(x) ischar(x) || (isstring(x) && isscalar(x)), qc_features_all)), ...
    'package.qc_feature_names must contain only character vectors or string scalars.');
qc_features_all = cellfun(@char, qc_features_all, 'UniformOutput', false);
assert(all(cellfun(@ischar, qc_features_all)), 'package.qc_feature_names must contain text entries convertible to char.');
assert(numel(qc_features_all) == size(qc_values_all,2), 'QC feature count must match qc_values columns.');

hash_feats = sha256_string(strjoin(string(qc_features_all), ','));
assert(strcmp(hash_feats, package.source_hashes.feature_list_sha256), ...
    'Package QC feature list does not match package.source_hashes.feature_list_sha256.');
package_hash_from_components = sha256_string( ...
    string(hashSchema) + "|" + string(package.source_hashes.epochs_sha256) + "|" + ...
    string(package.source_hashes.qc_sha256) + "|" + string(package.source_hashes.feature_list_sha256));
assert(strcmp(package_hash_from_components, package.package_hash), ...
    'Package hash is inconsistent with its version-2 schema and stored component hashes.');

n_items = height(package.items);
assert(size(qc_values_all,1) == n_items, 'QC values must have one row per item (expected %d).', n_items);

% Build selected QC feature indices (trim both sides, case-sensitive match)
pkg_names_trim = cellfun(@strtrim, qc_features_all, 'UniformOutput', false);
qc_sel_idx = nan(numel(QC_FEATURE_LIST), 1);

for i = 1:numel(QC_FEATURE_LIST)
    req = QC_FEATURE_LIST{i};
    idx = find(strcmp(pkg_names_trim, req), 1, 'first'); % case-sensitive
    assert(~isempty(idx), 'Requested QC feature not found in screening_package.mat: "%s"', req);
    qc_sel_idx(i) = idx;
end

% Subset for plotting (duplicates allowed: qc_sel_idx can repeat)
qc_features = qc_features_all(qc_sel_idx);
qc_values   = qc_values_all(:, qc_sel_idx);
assert(numel(qc_features) == size(qc_values,2), 'Internal: selected QC feature count mismatch.');

% Required item columns
needCols = {'item_id','subjectID','sessionID','runID','epoch_index','channel','eventtype','dataset_idx','epoch_pos','channel_pos'};
missCols = setdiff(needCols, string(package.items.Properties.VariableNames));
assert(isempty(missCols), 'package.items missing required columns: %s', strjoin(cellstr(missCols), ', '));

% Normalise key columns to string (defensive)
package.items.subjectID  = string(package.items.subjectID);
package.items.sessionID  = string(package.items.sessionID);
package.items.runID      = string(package.items.runID);
package.items.channel    = string(package.items.channel);
package.items.eventtype  = string(package.items.eventtype);

% Defensive: coerce numeric index columns and keep them as 1-based indices
package.items.item_id     = double(package.items.item_id);
package.items.dataset_idx = double(package.items.dataset_idx);
package.items.epoch_pos   = double(package.items.epoch_pos);
package.items.channel_pos = double(package.items.channel_pos);
package.items.epoch_index = double(package.items.epoch_index);

assert(all(package.items.item_id(:) == (1:n_items)'), ...
    'package.items.item_id must be 1..N in order, matching table row order.');

%% Load or create decisions
decisions = struct();
if isfile(decPath)
    D = load(decPath);
    assert(isfield(D,'decisions'), 'screening_decisions.mat must contain variable "decisions".');
    decisions = D.decisions;

    if ~isfield(decisions, 'hash_schema')
        error('Screening:Viewer:MissingHashSchemaDecisions', ...
            ['screening_decisions.mat has no hash_schema and cannot be used. ', ...
            'Create decisions for a package with the required hash schema; do not edit this file in place.']);
    end
    if isstring(decisions.hash_schema) && isscalar(decisions.hash_schema)
        decisions.hash_schema = char(decisions.hash_schema);
    end
    assert(ischar(decisions.hash_schema), ...
        'decisions.hash_schema must be char or a string scalar convertible to char.');
    if ~strcmp(decisions.hash_schema, hashSchema) || ~strcmp(decisions.hash_schema, package.hash_schema)
        error('Screening:Viewer:HashSchemaMismatch', ...
            'Decision/package hash schema mismatch (decision="%s", package="%s", expected="%s").', ...
            decisions.hash_schema, package.hash_schema, hashSchema);
    end

    assert(isfield(decisions,'exclude_mask') && islogical(decisions.exclude_mask), ...
        'decisions.exclude_mask missing or not logical.');
    assert(numel(decisions.exclude_mask) == n_items, ...
        'decisions.exclude_mask length mismatch (expected %d).', n_items);

    assert(isfield(decisions,'package_hash'), 'decisions.package_hash missing.');

    decisions.package_hash = normalise_sha256(decisions.package_hash, 'decisions.package_hash');

    if ~strcmp(decisions.package_hash, package.package_hash)
        error(['Decisions file does not match this package (package_hash mismatch). ', ...
            'Regenerate decisions for this screening_package.mat.']);
    end

    % Normalise last_saved_utc (tolerate string scalar)
    if isfield(decisions, 'last_saved_utc') && isstring(decisions.last_saved_utc) && isscalar(decisions.last_saved_utc)
        decisions.last_saved_utc = char(decisions.last_saved_utc);
    end
    if ~isfield(decisions,'last_saved_utc') || ~ischar(decisions.last_saved_utc)
        decisions.last_saved_utc = '';
    end
else
    decisions.exclude_mask   = false(n_items,1);
    decisions.hash_schema    = package.hash_schema;
    decisions.package_hash   = package.package_hash;
    decisions.last_saved_utc = '';
end

excluded_at_launch = decisions.exclude_mask;  % frozen snapshot for this run

%% Build initial view state (start at first included item)
included_ids = find(~decisions.exclude_mask);
excluded_ids = find(decisions.exclude_mask);

if ~isempty(included_ids)
    current_item_id = included_ids(1);
    current_view = "included";
elseif ~isempty(excluded_ids)
    current_item_id = excluded_ids(1);
    current_view = "excluded";
else
    error('No items found in package (n_items = %d).', n_items);
end

%% Create UI (classic figure + uicontrols, mouse-only)
fig = figure( ...
    'Name', 'SIMPLE Epoch Screening', ...
    'NumberTitle', 'off', ...
    'MenuBar', 'none', ...
    'ToolBar', 'none', ...
    'Color', 'w', ...
    'Units', 'normalized', ...
    'Position', [0.05, 0.06, 0.90, 0.88], ...
    'CloseRequestFcn', @on_close);

% Single-purpose export menu; keep MATLAB's default menus and toolbar hidden.
fileMenu = uimenu(fig, 'Text', 'File');
uimenu(fileMenu, 'Text', 'Save PDF...', ...
    'MenuSelectedFcn', @(src,evt) on_save_pdf(src,evt));

% Panels
plotPanel = uipanel(fig, 'Units','normalized', 'Position',[0.02 0.04 0.76 0.92], 'BorderType','none');
ctlPanel  = uipanel(fig, 'Units','normalized', 'Position',[0.80 0.04 0.18 0.92], 'Title','Navigator');

% Plot layout (fixed 3x4)
tlo = tiledlayout(plotPanel, 3, 4, 'Padding','compact', 'TileSpacing','compact');

ax_time_fixed = nexttile(tlo, 1);
ax_time_auto  = nexttile(tlo, 5);
ax_psd        = nexttile(tlo, 9);

% QC axes (up to 9)
ax_qc = gobjects(9,1);
tile_slots = [2,6,10,3,7,11,4,8,12]; % fill QC cols left->right, each top->bottom
for i = 1:9
    ax_qc(i) = nexttile(tlo, tile_slots(i));
end

% Controls
bg = uibuttongroup(ctlPanel, 'Units','normalized', 'Position',[0.06 0.88 0.88 0.10], ...
    'SelectionChangedFcn', @(src,evt) on_view_change(src,evt,fig));
rb_incl = uicontrol(bg, 'Style','radiobutton', 'String','Included', 'Units','normalized', 'Position',[0.05 0.55 0.90 0.35]);
rb_excl = uicontrol(bg, 'Style','radiobutton', 'String','Excluded', 'Units','normalized', 'Position',[0.05 0.10 0.90 0.35]);

listbox = uicontrol(ctlPanel, 'Style','listbox', 'Units','normalized', ...
    'Position',[0.06 0.43 0.88 0.44], 'Callback', @(src,evt) on_list_select(src,evt,fig), 'FontName','Monospaced');

btn_prev = uicontrol(ctlPanel, 'Style','pushbutton', 'String','Prev', 'Units','normalized', ...
    'Position',[0.06 0.36 0.42 0.06], 'Callback', @(src,evt) on_prev(src,evt,fig));
btn_next = uicontrol(ctlPanel, 'Style','pushbutton', 'String','Next', 'Units','normalized', ...
    'Position',[0.52 0.36 0.42 0.06], 'Callback', @(src,evt) on_next(src,evt,fig));

chk_excl = uicontrol(ctlPanel, 'Style','checkbox', 'String','Exclude this item', 'Units','normalized', ...
    'Position',[0.06 0.28 0.88 0.06], 'Callback', @(src,evt) on_exclude_toggle(src,evt,fig));

txt_status = uicontrol(ctlPanel, 'Style','text', 'Units','normalized', ...
    'Position',[0.06 0.20 0.88 0.07], 'HorizontalAlignment','left', 'BackgroundColor','w', 'String','');

btn_finish = uicontrol(ctlPanel, 'Style','pushbutton', 'String','Finish', 'Units','normalized', ...
    'Position',[0.06 0.13 0.88 0.06], 'Callback', @(src,evt) on_finish(src,evt));

txt_help = uicontrol(ctlPanel, 'Style','text', 'Units','normalized', ...
    'Position',[0.06 0.01 0.88 0.11], 'HorizontalAlignment','left', 'BackgroundColor','w', ...
    'String', sprintf(['Mouse-only controls:\n', ...
    '• Click a QC dot to show item_id\n', ...
    '• Click an item ID\n', ...
    '• Use Prev/Next\n', ...
    '• Tick/untick Exclude\n', ...
    '• Switch Included/Excluded\n', ...
    '• Click Finish to close']));

% Enforce consistent right-panel UI font (avoid root default changes e.g., EEGLAB)
apply_uicontrol_font(ctlPanel, 8);
apply_uicontrol_font(bg, 8);
apply_uicontrol_font([rb_incl; rb_excl; listbox; btn_prev; btn_next; chk_excl; txt_status; btn_finish; txt_help], 8);

% Store app state
S = struct();
S.baseDir = baseDir;
S.screeningDir = screeningDir;
S.packagePath = packagePath;
S.decPath = decPath;

S.package = package;
S.decisions = decisions;
S.excluded_at_launch = excluded_at_launch;

S.current_item_id = current_item_id;
S.current_view = current_view;

S.qc_features = qc_features;
S.qc_values   = qc_values;

S.opts.fixed_ylim_units = fixed_ylim_units;
S.opts.time_xlim_ms = time_xlim_ms;
S.opts.psd_fmin_hz = psd_fmin_hz;
S.opts.psd_fmax_hz = psd_fmax_hz;

S.opts.show_global_title = SHOW_GLOBAL_TITLE;
S.opts.qc_ref_channel_mode = QC_REF_CHANNEL_MODE;
S.opts.qc_box_whisker = double(QC_BOXPLOT_WHISKER);
S.opts.qc_box_whisker_mode = char(QC_BOXPLOT_WHISKER_MODE);

S.ui.fig = fig;
S.ui.bg = bg;
S.ui.rb_incl = rb_incl;
S.ui.rb_excl = rb_excl;
S.ui.listbox = listbox;
S.ui.btn_prev = btn_prev;
S.ui.btn_next = btn_next;
S.ui.chk_excl = chk_excl;
S.ui.txt_status = txt_status;
S.ui.btn_finish = btn_finish;

S.ax.tlo         = tlo;
S.ax.time_fixed  = ax_time_fixed;
S.ax.time_auto   = ax_time_auto;
S.ax.psd         = ax_psd;
S.ax.qc          = ax_qc;

% Closing guard (prevents re-entrancy issues)
S.is_closing = false;

% Empty-view state
S.state.empty_view = false;

guidata(fig, S);

% Enable data cursor mode programmatically (toolbars/menu are off)
dcm = datacursormode(fig);
set(dcm, 'Enable', 'on', ...
    'DisplayStyle', 'datatip', ...
    'SnapToDataVertex', 'on', ...
    'UpdateFcn', @qc_datatip_updatefcn);

% If available, ask MATLAB to keep only the most recent tip; we also enforce this deterministically.
try
    set(dcm, 'NewDataCursorOnClick', 'off');
catch
    % If property not available, accept MATLAB default behaviour (we still enforce in UpdateFcn when possible).
end

% Initialise view and draw
set_initial_view_selection(fig);
refresh_listbox(fig, true);

% If the initial view is empty for any reason, show empty state; otherwise draw the current item.
ids0 = get_view_item_ids(fig);
if isempty(ids0)
    set_empty_view(fig);
else
    set_current_item(fig, S.current_item_id, true);
end

log_command_window('stop');

%% ───────────────────────────── Callbacks ──────────────────────────────
function on_finish(src, ~)
fig = ancestor(src, 'figure');
if isempty(fig) || ~ishandle(fig), return; end
on_close(fig, []);
end

function on_save_pdf(src, ~)
fig = ancestor(src, 'figure');
if isempty(fig) || ~ishandle(fig), return; end

S = guidata(fig);
if S.decisions.exclude_mask(S.current_item_id)
    itemStatus = 'excluded';
else
    itemStatus = 'included';
end
defaultName = sprintf('simple_screening_item-%06d_%s.pdf', ...
    S.current_item_id, itemStatus);

[fileName, fileDir] = uiputfile( ...
    {'*.pdf', 'PDF file (*.pdf)'}, ...
    'Save current viewer as PDF', defaultName);
if isequal(fileName, 0) || isequal(fileDir, 0)
    return
end

[~, ~, fileExt] = fileparts(fileName);
if ~strcmpi(fileExt, '.pdf')
    warning('SIMPLE:Screening:ExportExtension', ...
        'Choose a filename ending in .pdf. No file was saved.');
    return
end

outputPath = fullfile(fileDir, fileName);
try
    drawnow limitrate nocallbacks
    exportapp(fig, outputPath);
    fprintf('Saved viewer PDF: %s\n', outputPath);
catch ME
    warning('SIMPLE:Screening:ExportFailed', ...
        'Could not save the viewer PDF: %s', ME.message);
end
end

function on_close(src, ~)
% Robust close: never leave the figure stuck due to an error inside CloseRequestFcn.
if isempty(src) || ~ishandle(src)
    return
end

try
    S = guidata(src);
catch
    S = [];
end

try
    if isstruct(S) && isfield(S,'is_closing') && S.is_closing
        % Already closing; force delete.
        set(src, 'CloseRequestFcn', '');
        delete(src);
        return
    end
catch
    % ignore
end

try
    if isstruct(S)
        S.is_closing = true;
        guidata(src, S);
    end
catch
    % ignore
end

% Best-effort save on close (so decisions exist even if user never toggled anything)
try
    if isstruct(S) && isfield(S,'decisions') && isfield(S,'screeningDir') && isfield(S,'decPath')
        S = save_decisions_atomic(S);
        guidata(src, S);
    end
catch ME
    warning('SIMPLE:Screening:CloseSaveFailed', ...
        'Viewer closing, but saving decisions failed: %s', ME.message);
end

try
    % Prevent recursion
    set(src, 'CloseRequestFcn', '');
catch
    % ignore
end

try
    delete(src);
catch ME
    warning('SIMPLE:Screening:CloseFailed', 'Close failed: %s. Forcing delete.', ME.message);
    try
        delete(src);
    catch
        % give up quietly
    end
end
end

function on_view_change(~, event, fig)
S = guidata(fig);
newLabel = string(event.NewValue.String);
if newLabel == "Included"
    S.current_view = "included";
else
    S.current_view = "excluded";
end
guidata(fig, S);

% Refresh list and either show first item or show empty-view state.
ids = get_view_item_ids(fig);
refresh_listbox(fig, false);

if isempty(ids)
    set_empty_view(fig);
    return
end

exit_empty_view_if_needed(fig);
set_current_item(fig, ids(1), true);
end

function on_list_select(~, ~, fig)
S = guidata(fig);
ids = get_view_item_ids(fig);
if isempty(ids), return; end

idx = S.ui.listbox.Value;
idx = max(1, min(idx, numel(ids)));
set_current_item(fig, ids(idx), true);
end

function on_prev(~, ~, fig)
step_current(fig, -1);
end

function on_next(~, ~, fig)
step_current(fig, +1);
end

function on_exclude_toggle(~, ~, fig)
S = guidata(fig);

% If view is empty (controls disabled), do nothing.
ids_before = get_view_item_ids(fig);
if isempty(ids_before) || ~isfinite(S.current_item_id)
    return
end

cur_item = S.current_item_id;
cur_pos = find(ids_before == cur_item, 1, 'first');
if isempty(cur_pos), cur_pos = 1; end

newExcluded = logical(S.ui.chk_excl.Value);

% Apply
S.decisions.exclude_mask(cur_item) = newExcluded;

% Autosave atomically
S = save_decisions_atomic(S);

% Keep the current view (do not switch views automatically)
guidata(fig, S);

% Refresh list for the current view
ids_after = get_view_item_ids(fig);
refresh_listbox(fig, false);

if isempty(ids_after)
    set_empty_view(fig);
    return
end

exit_empty_view_if_needed(fig);

% Advance to next item in this view if possible; otherwise go to previous.
% Using "same position" semantics: after removal, the next item falls into cur_pos.
target_pos = cur_pos;
if target_pos > numel(ids_after)
    target_pos = numel(ids_after);
end
target_item = ids_after(target_pos);

set_current_item(fig, target_item, true);
end

%% ───────────────────────────── Core UI ────────────────────────────────
function set_initial_view_selection(fig)
S = guidata(fig);
if S.current_view == "included"
    set(S.ui.bg, 'SelectedObject', S.ui.rb_incl);
else
    set(S.ui.bg, 'SelectedObject', S.ui.rb_excl);
end
guidata(fig, S);
end

function apply_uicontrol_font(h, fontSizePt)
%APPLY_UICONTROL_FONT Set FontUnits/FontSize on a set of UI handles (best-effort).
if nargin < 2 || isempty(fontSizePt)
    fontSizePt = 8;
end

for i = 1:numel(h)
    hi = h(i);
    if isempty(hi) || ~isgraphics(hi)
        continue
    end
    try
        set(hi, 'FontUnits', 'points', 'FontSize', fontSizePt);
    catch
        % Some graphics objects may not support Font* props; ignore.
    end
end
end

function refresh_listbox(fig, try_keep_current)
S = guidata(fig);
ids = get_view_item_ids(fig);

if isempty(ids)
    S.ui.listbox.String = {};
    S.ui.listbox.Value  = 1;
    S.ui.listbox.Enable = 'off';

    S.ui.chk_excl.Value  = 0;
    S.ui.chk_excl.Enable = 'off';

    refresh_status_text(fig);
    guidata(fig, S);
    return
end

% Enable controls for non-empty views
S.ui.listbox.Enable = 'on';
S.ui.chk_excl.Enable = 'on';

% Item_id only
S.ui.listbox.String = cellstr(string(ids));
if try_keep_current
    pos = find(ids == S.current_item_id, 1, 'first');
    if isempty(pos), pos = 1; end
    S.ui.listbox.Value = pos;
else
    S.ui.listbox.Value = 1;
end

refresh_status_text(fig);
guidata(fig, S);
end

function refresh_status_text(fig)
S = guidata(fig);
incN = sum(~S.decisions.exclude_mask);
excN = sum(S.decisions.exclude_mask);

totN = incN + excN;
if totN == 0
    pctExcluded = 0;
else
    pctExcluded = 100 * (excN / totN);
end

ids = get_view_item_ids(fig);
if isempty(ids)
    S.ui.txt_status.String = sprintf(['Included: %d\nExcluded: %d\n%% excluded: %.1f%%\n', ...
        '(no items in this view)'], ...
        incN, excN, pctExcluded);
else
    S.ui.txt_status.String = sprintf('Included: %d\nExcluded: %d\n%% excluded: %.1f%%\nThis view: %d', ...
        incN, excN, pctExcluded, numel(ids));
end
guidata(fig, S);
end

function ids = get_view_item_ids(fig)
S = guidata(fig);
if S.current_view == "included"
    ids = find(~S.decisions.exclude_mask);
else
    ids = find(S.decisions.exclude_mask);
end
end

function step_current(fig, delta)
S = guidata(fig);
ids = get_view_item_ids(fig);
if isempty(ids), return; end

curPos = find(ids == S.current_item_id, 1, 'first');
if isempty(curPos), curPos = 1; end
newPos = curPos + delta;
newPos = max(1, min(newPos, numel(ids)));

S.ui.listbox.Value = newPos;
guidata(fig, S);
set_current_item(fig, ids(newPos), true);
end

function set_current_item(fig, item_id, update_listbox_selection)
S = guidata(fig);

% Leaving empty-view state, if applicable
exit_empty_view_if_needed(fig);
S = guidata(fig);

% Bounds check
if item_id < 1 || item_id > height(S.package.items)
    error('Internal: item_id out of range: %d (1..%d).', item_id, height(S.package.items));
end

% Update current
S.current_item_id = item_id;

% Sync exclude checkbox
S.ui.chk_excl.Enable = 'on';
S.ui.chk_excl.Value  = S.decisions.exclude_mask(item_id);

% If requested, keep listbox selection aligned
if update_listbox_selection
    ids = get_view_item_ids(fig);
    pos = find(ids == item_id, 1, 'first');
    if ~isempty(pos)
        S.ui.listbox.Value = pos;
    end
end

guidata(fig, S);

% Redraw plots
redraw_all(fig);
end

function set_empty_view(fig)
S = guidata(fig);
S.state.empty_view = true;

% Disable controls
S.ui.listbox.String = {};
S.ui.listbox.Value  = 1;
S.ui.listbox.Enable = 'off';

S.ui.chk_excl.Value  = 0;
S.ui.chk_excl.Enable = 'off';

guidata(fig, S);

% Clear plots and show message
redraw_empty(fig);
end

function exit_empty_view_if_needed(fig)
S = guidata(fig);
if isfield(S,'state') && isfield(S.state,'empty_view') && S.state.empty_view
    S.state.empty_view = false;

    % Re-enable controls (listbox is populated by refresh_listbox; checkbox is synced by set_current_item)
    S.ui.listbox.Enable = 'on';

    guidata(fig, S);
end
end

function redraw_empty(fig)
S = guidata(fig);

% Clear global title explicitly
title(S.ax.tlo, '');

% Clear and hide all axes
allAx = [S.ax.time_fixed; S.ax.time_auto; S.ax.psd; S.ax.qc(:)];
for i = 1:numel(allAx)
    ax = allAx(i);
    cla(ax);
    axis(ax, 'off');
end

% Show message in top-left panel
if S.current_view == "included"
    viewLabel = 'Included';
else
    viewLabel = 'Excluded';
end

ax = S.ax.time_fixed;
axis(ax, 'off');
text(ax, 0.5, 0.5, sprintf('No items in %s view', viewLabel), ...
    'Units','normalized', 'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
    'FontWeight','bold');

end

function redraw_all(fig)
S = guidata(fig);
it = S.package.items(S.current_item_id, :);

% Extract trace indices
dset_idx = double(it.dataset_idx);
ep_pos   = double(it.epoch_pos);
ch_pos   = double(it.channel_pos);

% Validate indices
assert(dset_idx >= 1 && dset_idx <= numel(S.package.epochs_pooled), 'dataset_idx out of range.');
E = S.package.epochs_pooled(dset_idx);
assert(ep_pos >= 1 && ep_pos <= size(E.data,3), 'epoch_pos out of range for this dataset.');
assert(ch_pos >= 1 && ch_pos <= size(E.data,1), 'channel_pos out of range for this dataset.');

x_ms = double(E.times_ms(:));
y = squeeze(E.data(ch_pos, :, ep_pos));
y = double(y(:));
Fs = double(E.srate);

% Figure title (no eventannotation)
subj = char(it.subjectID);
sess = char(it.sessionID);
run  = char(it.runID);
epoch_index = double(it.epoch_index);
channel = char(it.channel);
eventtype = char(it.eventtype);

isExcludedNow = S.decisions.exclude_mask(S.current_item_id);
statusStr = "Included";
if isExcludedNow, statusStr = "Excluded"; end

atLaunchStr = "";
if S.excluded_at_launch(S.current_item_id)
    atLaunchStr = " (excluded at launch)";
end

if logical(S.opts.show_global_title)
    title(S.ax.tlo, sprintf('Item %d | %s | %s | %s | epoch %d | %s | %s | %s%s', ...
        S.current_item_id, subj, sess, run, epoch_index, channel, eventtype, statusStr, atLaunchStr), ...
        'Interpreter','none');
else
    title(S.ax.tlo, '');
end

% --- Time (fixed y) ---
ax = S.ax.time_fixed;
cla(ax);
axis(ax, 'on');
h_line = plot(ax, x_ms, y, 'LineWidth', 1.5);
set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
grid(ax, 'on');
xlabel(ax, 'Time (ms)');
ylabel(ax, 'Amplitude');
h0 = xline(ax, 0, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
set(h0, 'HitTest', 'off', 'PickableParts', 'none');
xlim(ax, S.opts.time_xlim_ms);
ylim(ax, S.opts.fixed_ylim_units);
set(ax, 'YDir', 'reverse');

% --- Time (auto y) ---
ax = S.ax.time_auto;
cla(ax);
axis(ax, 'on');
h_line = plot(ax, x_ms, y, 'LineWidth', 1.5);
set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
grid(ax, 'on');
xlabel(ax, 'Time (ms)');
ylabel(ax, 'Amplitude');
h0 = xline(ax, 0, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
set(h0, 'HitTest', 'off', 'PickableParts', 'none');
xlim(ax, S.opts.time_xlim_ms);
set(ax, 'YDir', 'reverse');

% --- PSD (log power), full epoch ---
ax = S.ax.psd;
cla(ax);
axis(ax, 'on');
[Pxx, F] = pmtm(double(y), 4, 1024, Fs, 'onesided');
Pxx = max(Pxx, eps);
Pdb = 10*log10(Pxx);
h_line = plot(ax, F, Pdb, 'LineWidth', 1.5);
set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
grid(ax, 'on');
xlabel(ax, 'Frequency (Hz)');
ylabel(ax, 'PSD (dB/Hz)');
xlim(ax, [S.opts.psd_fmin_hz, S.opts.psd_fmax_hz]);

% --- QC panels ---
for fi = 1:numel(S.qc_features)
    ax = S.ax.qc(fi);
    cla(ax);

    feat = S.qc_features{fi};
    val  = S.qc_values(S.current_item_id, fi);

    if ~isfinite(val)
        axis(ax, 'off');
        title(ax, sprintf('%s: missing', feat), 'Interpreter','none');
        continue
    end

    % Build swarm from INCLUDED-AT-LAUNCH only, with optional channel conditioning
    mode = string(S.opts.qc_ref_channel_mode);

    % Base mask: INCLUDED-AT-LAUNCH only (always applied)
    baseMask = ~S.excluded_at_launch;

    % Channel mask depends on mode
    if mode == "all_channels"
        chMask = true(size(baseMask)); % no channel restriction
    else
        % Default: "current_channel" (case-insensitive, trimmed)
        curCh = lower(strtrim(string(it.channel)));
        allCh = lower(strtrim(string(S.package.items.channel)));
        chMask = (allCh == curCh);
    end

    includeLaunchMask = baseMask & chMask;

    % Keep mapping to item_id for datatips
    item_ids_all = find(includeLaunchMask);
    vals_all     = S.qc_values(includeLaunchMask, fi);
    finite_mask  = isfinite(vals_all);

    dist          = vals_all(finite_mask);
    item_ids_dist = item_ids_all(finite_mask);

    if isempty(dist)
        axis(ax, 'off');
        title(ax, sprintf('%s: no data', feat), 'Interpreter','none');
        continue
    end

    axis(ax, 'on');

    % Horizontal swarm: x=values, y is a single group; jitter in Y for visibility
    y0 = ones(size(dist));  % single group
    h = swarmchart(ax, dist, y0, 'filled', 'YJitter', 'density');
    set(h, 'MarkerFaceColor', [0 0.4470 0.7410], 'MarkerEdgeColor', 'none'); % blue

    % Store mapping for datatips (robust: map via DataIndex into these stored arrays)
    h.UserData = struct( ...
        'item_ids', item_ids_dist, ...
        'values',   dist, ...
        'feature',  feat);

    ax.YTick = [];
    ax.YColor = 'none';
    grid(ax, 'on');
    xlabel(ax, feat, 'Interpreter','none');

    % Title includes numeric value (disambiguates off-scale vs missing)
    title(ax, sprintf('%s: %.4g', feat, val), 'Interpreter','none');

    % One-sided box overlay (q1..q3, median, upper whisker only)
    q1 = prctile(dist, 25);
    q2 = prctile(dist, 50);
    q3 = prctile(dist, 75);
    iqr_val = q3 - q1;

    w = double(S.opts.qc_box_whisker);
    thr = q3 + w * iqr_val;

    modeWh = lower(strtrim(string(S.opts.qc_box_whisker_mode)));
    if modeWh == "adjacent"
        d_ok = dist(dist <= thr);
        if isempty(d_ok)
            wh_end = q3;
        else
            wh_end = max(d_ok);
        end
    else
        % "threshold"
        wh_end = thr;
    end

    % Draw overlay at y=1 (match swarm group centre)
    y_c = 1;
    box_h = 0.28;   % fixed in data coords (swarm is centred at y=1)
    cap_h = 0.18;

    yb0 = y_c - box_h/2;
    yb1 = y_c + box_h/2;

    hold(ax, 'on');

    % Box (q1..q3)
    if isfinite(q1) && isfinite(q3) && q3 >= q1
        hr = rectangle(ax, 'Position', [q1, yb0, (q3 - q1), box_h], ...
            'FaceColor', 'none', 'LineWidth', 1);
        set(hr, 'HitTest', 'off', 'PickableParts', 'none');
    end

    % Median line at q2
    if isfinite(q2)
        hm = line(ax, [q2 q2], [yb0 yb1], 'LineWidth', 1);
        set(hm, 'HitTest', 'off', 'PickableParts', 'none');
    end

    % Upper whisker from q3 to wh_end (if meaningful)
    if isfinite(q3) && isfinite(wh_end) && wh_end >= q3
        hw = line(ax, [q3 wh_end], [y_c y_c], 'LineWidth', 1);
        set(hw, 'HitTest', 'off', 'PickableParts', 'none');

        % Whisker cap at wh_end
        hc = line(ax, [wh_end wh_end], [y_c - cap_h/2, y_c + cap_h/2], 'LineWidth', 1);
        set(hc, 'HitTest', 'off', 'PickableParts', 'none');
    end

    % Decide marker colour for current item
    useGrey = (S.current_view == "excluded") && S.excluded_at_launch(S.current_item_id);
    col = [1 0 0]; % red
    if useGrey, col = [0.5 0.5 0.5]; end

    % Current marker: do NOT expand x-limits (only draw if within current xlim)
    xl = ax.XLim;
    if val >= xl(1) && val <= xl(2)
        hx = xline(ax, val, '--', 'Color', col, 'LineWidth', 1);
        set(hx, 'HitTest', 'off', 'PickableParts', 'none');

        hp = plot(ax, val, 1, 'o', 'MarkerFaceColor', col, 'MarkerEdgeColor', col, 'MarkerSize', 6);
        set(hp, 'HitTest', 'off', 'PickableParts', 'none');
    end

    hold(ax, 'off');
end

% Hide unused QC axes (keep layout stable)
for fi = (numel(S.qc_features)+1):9
    ax = S.ax.qc(fi);
    cla(ax);
    axis(ax, 'off');
end
end

%% ───────────────────────────── Data tips (QC swarm only) ─────────────────────────────
function txt = qc_datatip_updatefcn(~, event_obj)
% Custom data tip for QC swarmchart points only.
% Shows:
%   item_id: <n>
%   <FEATURE>: <value>
%
% Clicking anywhere except QC swarm dots should do nothing and should not leave an empty datatip.

% Try to capture the datatip handle (so we can delete it when we want "do nothing")
hdt = [];
try
    hdt = event_obj.DataTipHandle;
catch
    % Continue without a removable handle if DataTipHandle is unavailable.
end

% Get target
try
    tgt = event_obj.Target;
catch
    if ~isempty(hdt) && isvalid(hdt), delete(hdt); end
    txt = {};
    return
end

% Only accept swarmcharts that carry our expected metadata
if isempty(tgt) || ~isprop(tgt, 'UserData') || ~isstruct(tgt.UserData)
    if ~isempty(hdt) && isvalid(hdt), delete(hdt); end
    txt = {};
    return
end

ud = tgt.UserData;
need = {'item_ids','values','feature'};
if ~all(isfield(ud, need))
    if ~isempty(hdt) && isvalid(hdt), delete(hdt); end
    txt = {};
    return
end

% Resolve clicked index
try
    di = event_obj.DataIndex;
catch
    if ~isempty(hdt) && isvalid(hdt), delete(hdt); end
    txt = {};
    return
end

if isempty(di) || di < 1 || di > numel(ud.item_ids)
    if ~isempty(hdt) && isvalid(hdt), delete(hdt); end
    txt = {};
    return
end

% Deterministic: keep only the most recent datatip, within this figure only
% Only do this if we can identify the current datatip handle reliably.
if ~isempty(hdt) && isvalid(hdt)
    try
        f = ancestor(tgt, 'figure');
        if ~isempty(f) && isgraphics(f)
            tips = findall(f, '-isa', 'matlab.graphics.datatip.DataTip');
            if ~isempty(tips)
                tips = tips(~arrayfun(@(x) isequal(x, hdt), tips));
                tips = tips(isvalid(tips));
                if ~isempty(tips)
                    delete(tips);
                end
            end
        end
    catch
        % If anything here fails, fall back to MATLAB defaults without breaking datatips.
    end
end

% Build text
item_id = ud.item_ids(di);
val     = ud.values(di);

feat = ud.feature;
feat = strrep(feat, '_', '\_'); % ensure underscores render literally in datatip

txt = { ...
    sprintf('item\\_id: %d', item_id), ...
    sprintf('%s: %.4g', feat, val) ...
    };
end

%% ───────────────────────────── Persistence ────────────────────────────
function S = save_decisions_atomic(S)
assert(isfield(S.decisions, 'hash_schema') && strcmp(S.decisions.hash_schema, S.package.hash_schema), ...
    'Refusing to save decisions with a missing or mismatched hash schema.');

% Update last_saved_utc
dtISO = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
S.decisions.last_saved_utc = dtISO;

% Ensure dir exists
if ~exist(S.screeningDir, 'dir')
    mkdir(S.screeningDir);
end

% Write to temp in same directory, then move over target.
% movefile within the same filesystem is atomic on macOS/Linux.
tmpPath = fullfile(S.screeningDir, sprintf('screening_decisions_%s.tmp.mat', char(java.util.UUID.randomUUID)));
decisions = S.decisions; %#ok<NASGU>
save(tmpPath, 'decisions', '-v7');

[ok, msg] = movefile(tmpPath, S.decPath, 'f');
if ~ok
    warning('SIMPLE:Screening:SaveFailed', 'Failed to save decisions file: %s', msg);
end
end

function h = sha256_string(s)
md = java.security.MessageDigest.getInstance('SHA-256');
bytes = unicode2native(char(s), 'UTF-8');
md.update(reshape(typecast(bytes(:), 'int8'), 1, []));
d = md.digest();
h = bytes2hex(d);
end

function h = bytes2hex(javaInt8Array)
u = typecast(javaInt8Array, 'uint8');
h = lower(reshape(dec2hex(u, 2).', 1, []));
end

function h = normalise_sha256(value, label)
if isstring(value) && isscalar(value)
    value = char(value);
end
if ~ischar(value) || size(value, 1) ~= 1
    error('%s must be a character vector or string scalar.', label);
end
h = lower(strtrim(value));
if isempty(regexp(h, '^[0-9a-f]{64}$', 'once'))
    error('%s must contain exactly 64 hexadecimal SHA-256 characters.', label);
end
end
