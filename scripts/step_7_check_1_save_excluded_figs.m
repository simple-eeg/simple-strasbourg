%% step_7_check_1_save_excluded_figs.m
% Create per-item PNG plots for all excluded epoch–channel items.
%
% Inputs
%   <baseDir>/data/summary/screening/pooled_screened_eeg_epochs.mat
%     expects variable: epochs_pooled (struct array)
%     and each element must contain field: Exclude of size [nCh x nEp] logical
%
% Output
%   <baseDir>/data/summary/screening/excluded_epochs/
%     One PNG per excluded item:
%       sub-<subjectID>_ses-<sessionID>_run-<runID>_epoch-<epoch_index>_chan-<channel>_<eventtype>.png
%     (eventtype may be empty => filename ends with "_<empty>.png" i.e. trailing underscore)
%
% Plot layout (1x3), matching step_6_screen_2_viewer_rate_epochs.m:
%   1) Time-domain (fixed y)
%   2) Time-domain (auto y)
%   3) PSD (log power, pmtm)
%
% Behaviour
%   - Deterministic generation order: subjectID, sessionID, runID, epoch_index, channel
%   - Builds and verifies a complete local staging directory before replacing
%     any existing complete excluded_epochs directory.
%   - Uses exportgraphics only (no fallbacks).
%   - Figures are created invisibly and closed after export.
%   - If no excluded items, a validated empty output directory is promoted.
%   - Prints a progress counter to the Command Window.
%
% Logging
%   - Writes Command Window log via log_command_window('start'/'stop').

log_command_window('start');
clear; clc;

%% ───────────────────────────── USER CONFIG ─────────────────────────────
baseDir = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';

screeningDir = fullfile(baseDir, 'data', 'summary', 'screening');
inMat        = fullfile(screeningDir, 'pooled_screened_eeg_epochs.mat');

outDir       = fullfile(screeningDir, 'excluded_epochs');

% Match viewer defaults (user-adjustable)
fixed_ylim_units = [-100, 100];   % same units as stored in epochs_pooled.data
time_xlim_ms     = [-200, 1200];  % applied to both time-domain plots
psd_fmin_hz      = -1;
psd_fmax_hz      = 251;

% PNG export settings (user-adjustable)
export_dpi        = 200;                  % sensible default: good clarity without huge files
figure_size_px    = [1800, 450];          % [width, height] pixels; suits 1x3 layout

% Line/axis styling (match viewer)
line_width = 1.5;

% Progress reporting
progress_every = 1;  % print every N saved (set to 1 for every file)

%% ───────────────────────────── PRE-FLIGHT ─────────────────────────────
fprintf('Plotting excluded epoch–channel items.\n');

assert(isfolder(screeningDir), 'screeningDir does not exist (expected): %s', screeningDir);
assert(isfile(inMat), 'Missing screened epochs MAT: %s', inMat);
assert(is_local_child(baseDir, screeningDir) && is_local_child(baseDir, inMat) && ...
    is_local_child(baseDir, outDir), ...
    'Every read/write target must remain beneath the local Strasbourg repository.');

validateattributes(fixed_ylim_units, {'numeric'}, ...
    {'real','finite','vector','numel',2,'increasing'}, mfilename, 'fixed_ylim_units');
validateattributes(time_xlim_ms, {'numeric'}, ...
    {'real','finite','vector','numel',2,'increasing'}, mfilename, 'time_xlim_ms');
validateattributes(psd_fmin_hz, {'numeric'}, {'real','finite','scalar'}, mfilename, 'psd_fmin_hz');
validateattributes(psd_fmax_hz, {'numeric'}, {'real','finite','scalar','>',psd_fmin_hz}, mfilename, 'psd_fmax_hz');
validateattributes(export_dpi, {'numeric'}, {'real','finite','scalar','integer','positive'}, mfilename, 'export_dpi');
validateattributes(figure_size_px, {'numeric'}, ...
    {'real','finite','vector','numel',2,'integer','positive'}, mfilename, 'figure_size_px');
validateattributes(line_width, {'numeric'}, {'real','finite','scalar','positive'}, mfilename, 'line_width');
validateattributes(progress_every, {'numeric'}, ...
    {'real','finite','scalar','integer','nonnegative'}, mfilename, 'progress_every');

stagingDir = [outDir, '.partial'];
backupDir = [outDir, '.previous'];
assert(is_local_child(baseDir, stagingDir) && is_local_child(baseDir, backupDir), ...
    'Temporary and backup directories must remain beneath the local Strasbourg repository.');
recover_interrupted_promotion(outDir, stagingDir, backupDir);

%% ───────────────────────────── LOAD MAT ───────────────────────────────
fprintf('Loading: %s\n', inMat);
S = load(inMat);

assert(isfield(S, 'epochs_pooled'), 'Expected variable "epochs_pooled" in: %s', inMat);
epochs_pooled = S.epochs_pooled;
assert(isstruct(epochs_pooled) && ~isempty(epochs_pooled), 'epochs_pooled must be a non-empty struct array.');

% Required dataset fields (minimum needed here)
req = {'data','times_ms','channels','epoch_index','eventtype','srate','subjectID','sessionID','runID','Exclude'};
for f = 1:numel(req)
    assert(isfield(epochs_pooled, req{f}), 'epochs_pooled is missing required field: %s', req{f});
end

%% ───────────────────── BUILD FLAT LIST OF EXCLUDED ITEMS ─────────────────────
rows = []; % will become a table at the end

for d = 1:numel(epochs_pooled)
    E = epochs_pooled(d);

    % Basic shape checks
    assert(isnumeric(E.data) && isreal(E.data) && ndims(E.data) <= 3, ...
        'Dataset %d: data must be a real numeric [nCh x nPts x nEp] array.', d);
    assert(all(isfinite(E.data(:))), 'Dataset %d: data contain NaN or Inf.', d);
    nCh = size(E.data, 1);
    nPts = size(E.data, 2);
    nEp = size(E.data, 3);
    assert(nCh >= 1 && nPts >= 2 && nEp >= 1, ...
        'Dataset %d: data dimensions must all be non-empty and include at least two time samples.', d);

    % Validate channels/eventtype/epoch_index lengths
    assert(iscell(E.channels) && numel(E.channels) == nCh, 'Dataset %d: channels length mismatch.', d);
    assert(iscell(E.eventtype) && numel(E.eventtype) == nEp, 'Dataset %d: eventtype length mismatch.', d);
    assert(isnumeric(E.epoch_index) && isreal(E.epoch_index) && numel(E.epoch_index) == nEp && ...
        all(isfinite(E.epoch_index(:))) && all(E.epoch_index(:) == fix(E.epoch_index(:))) && ...
        numel(unique(double(E.epoch_index(:)))) == nEp, ...
        'Dataset %d: epoch_index must contain one unique finite integer per epoch.', d);

    channels_here = strings(nCh, 1);
    for c = 1:nCh
        channels_here(c) = string(E.channels{c});
        assert(isscalar(channels_here(c)) && ~ismissing(channels_here(c)) && ...
            strlength(strtrim(channels_here(c))) > 0, ...
            'Dataset %d: every channel label must be a nonblank scalar.', d);
    end
    assert(numel(unique(lower(strtrim(channels_here)))) == nCh, ...
        'Dataset %d: channel labels must be unique after trimming, case-insensitively.', d);

    times_here = double(E.times_ms(:));
    assert(isnumeric(E.times_ms) && isreal(E.times_ms) && numel(times_here) == nPts && ...
        all(isfinite(times_here)) && all(diff(times_here) > 0), ...
        'Dataset %d: times_ms must be a finite strictly increasing vector matching data.', d);
    assert(isnumeric(E.srate) && isreal(E.srate) && isscalar(E.srate) && ...
        isfinite(E.srate) && E.srate > 0, ...
        'Dataset %d: srate must be a positive finite numeric scalar.', d);
    expected_dt_ms = 1000 / double(E.srate);
    dt_tolerance = max(1e-9, abs(expected_dt_ms) * 1e-6);
    assert(all(abs(diff(times_here) - expected_dt_ms) <= dt_tolerance), ...
        'Dataset %d: times_ms spacing is inconsistent with srate.', d);

    % Validate Exclude exists + shape exactly [nCh x nEp]
    assert(islogical(E.Exclude), 'Dataset %d: Exclude must be logical.', d);
    szEx = size(E.Exclude);
    assert(isequal(szEx, [nCh, nEp]), ...
        'Dataset %d: Exclude has wrong shape. Expected [%d x %d], found [%d x %d].', ...
        d, nCh, nEp, szEx(1), szEx(2));

    % Dataset identifiers as stored (keep exact, no padding changes)
    subj = string(E.subjectID);
    sess = string(E.sessionID);
    run  = string(E.runID);
    identifiers = {subj, 'subjectID'; sess, 'sessionID'; run, 'runID'};
    for identifier_idx = 1:size(identifiers, 1)
        identifier_value = identifiers{identifier_idx, 1};
        assert(isscalar(identifier_value) && ~ismissing(identifier_value) && ...
            strlength(strtrim(identifier_value)) > 0 && ...
            strlength(sanitize_alnum(identifier_value)) > 0, ...
            'Dataset %d: %s must contain at least one alphanumeric character.', ...
            d, identifiers{identifier_idx, 2});
    end

    % Collect excluded positions
    [c_pos, e_pos] = find(E.Exclude); % returns channel positions, epoch positions

    if isempty(c_pos)
        continue
    end

    % Expand into rows
    n_here = numel(c_pos);
    dset_idx     = repmat(d, n_here, 1);
    channel_pos  = c_pos(:);
    epoch_pos    = e_pos(:);

    channel       = strings(n_here, 1);
    epoch_index   = zeros(n_here, 1);
    eventtype     = strings(n_here, 1);

    for k = 1:n_here
        channel(k)     = string(E.channels{channel_pos(k)});
        epoch_index(k) = double(E.epoch_index(epoch_pos(k)));
        et = E.eventtype{epoch_pos(k)};
        if isempty(et)
            eventtype(k) = "";
        else
            eventtype(k) = string(et);
            assert(isscalar(eventtype(k)) && ~ismissing(eventtype(k)), ...
                'Dataset %d: every non-empty eventtype must be a nonmissing scalar.', d);
        end
    end

    t_here = table( ...
        dset_idx, channel_pos, epoch_pos, ...
        repmat(subj, n_here, 1), repmat(sess, n_here, 1), repmat(run, n_here, 1), ...
        channel, epoch_index, eventtype, ...
        'VariableNames', {'dataset_idx','channel_pos','epoch_pos','subjectID','sessionID','runID','channel','epoch_index','eventtype'} ...
        );

    if isempty(rows)
        rows = t_here;
    else
        rows = [rows; t_here]; %#ok<AGROW>
    end
end

prepare_staging_directory(stagingDir);
staging_cleanup = onCleanup(@() delete_directory_if_present(stagingDir)); %#ok<NASGU>

if isempty(rows)
    promote_complete_directory(stagingDir, outDir, backupDir);
    fprintf('Excluded items found: 0\n');
    fprintf('Validated empty output folder: %s\n', outDir);
    log_command_window('stop');
    return
end

% Deterministic sort: subjectID, sessionID, runID, epoch_index, channel
rows = sortrows(rows, {'subjectID','sessionID','runID','epoch_index','channel'});

fprintf('Excluded items found: %d\n', height(rows));
fprintf('Saving PNGs to: %s\n', outDir);

%% ─────────────────────── PLAN NAMES BEFORE EXPORT ─────────────────────
usedNames = containers.Map('KeyType','char', 'ValueType','logical');
nTotal = height(rows);
planned_file_names = strings(nTotal, 1);
planned_titles = strings(nTotal, 1);

for i = 1:nTotal
    r = rows(i,:);

    subj_value = sanitize_alnum(string(r.subjectID));
    sess_value = sanitize_alnum(string(r.sessionID));
    run_value = sanitize_alnum(string(r.runID));
    chan_value = sanitize_alnum(string(r.channel));
    epoch_value = sanitize_alnum(string(r.epoch_index));
    assert(all(strlength([subj_value, sess_value, run_value, chan_value, epoch_value]) > 0), ...
        'An excluded item has an identifier/channel/epoch value that sanitises to blank.');

    subj = "sub-" + subj_value;
    sess = "ses-" + sess_value;
    run = "run-" + run_value;
    chan = "chan-" + chan_value;
    epc = "epoch-" + epoch_value;
    ev = sanitize_alnum(string(r.eventtype));
    baseName = subj + "_" + sess + "_" + run + "_" + epc + "_" + chan + "_" + ev;

    candidateName = baseName;
    duplicateNumber = 1;
    candidateKey = lower(char(candidateName + ".png"));
    while isKey(usedNames, candidateKey)
        duplicateNumber = duplicateNumber + 1;
        candidateName = baseName + "_dup" + string(duplicateNumber);
        candidateKey = lower(char(candidateName + ".png"));
    end
    usedNames(candidateKey) = true;

    planned_file_names(i) = candidateName + ".png";
    planned_titles(i) = strrep(candidateName, '_', ' | ');
end
assert(numel(unique(lower(planned_file_names))) == nTotal, ...
    'Planned PNG filenames are not unique after deterministic collision handling.');

%% ───────────────────────────── PLOT + EXPORT ──────────────────────────

nSaved = 0;

for i = 1:nTotal
    r = rows(i,:);

    d  = double(r.dataset_idx);
    cp = double(r.channel_pos);
    ep = double(r.epoch_pos);

    E = epochs_pooled(d);

    x_ms = double(E.times_ms(:));
    y    = squeeze(E.data(cp, :, ep));
    y    = double(y(:));
    Fs   = double(E.srate);

    fileName = planned_file_names(i);
    outPath  = fullfile(stagingDir, char(fileName));
    titleStr = char(planned_titles(i));

    % Create invisible figure sized in pixels
    fig = figure( ...
        'Visible', 'off', ...
        'Color', 'w', ...
        'Units', 'pixels', ...
        'Position', [100, 100, figure_size_px(1), figure_size_px(2)]);
    figure_cleanup = onCleanup(@() close_figure_if_present(fig)); %#ok<NASGU>

    tlo = tiledlayout(1, 3, 'Padding','compact', 'TileSpacing','compact');
    title(tlo, titleStr, 'Interpreter','none');

    % --- (1) Time (fixed y) ---
    ax1 = nexttile(tlo, 1);
    h_line = plot(ax1, x_ms, y, 'LineWidth', line_width);
    set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
    grid(ax1, 'on');
    xlabel(ax1, 'Time (ms)');
    ylabel(ax1, 'Amplitude'); % changed
    h0 = xline(ax1, 0, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
    set(h0, 'HitTest', 'off', 'PickableParts', 'none');
    xlim(ax1, time_xlim_ms);
    ylim(ax1, fixed_ylim_units);
    set(ax1, 'YDir', 'reverse');

    % --- (2) Time (auto y) ---
    ax2 = nexttile(tlo, 2);
    h_line = plot(ax2, x_ms, y, 'LineWidth', line_width);
    set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
    grid(ax2, 'on');
    xlabel(ax2, 'Time (ms)');
    ylabel(ax2, 'Amplitude'); % changed
    h0 = xline(ax2, 0, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
    set(h0, 'HitTest', 'off', 'PickableParts', 'none');
    xlim(ax2, time_xlim_ms);
    set(ax2, 'YDir', 'reverse');

    % --- (3) PSD (log power), full epoch ---
    ax3 = nexttile(tlo, 3);
    [Pxx, F] = pmtm(double(y), 4, 1024, Fs, 'onesided');
    Pxx = max(Pxx, eps);
    Pdb = 10*log10(Pxx);
    h_line = plot(ax3, F, Pdb, 'LineWidth', line_width);
    set(h_line, 'HitTest', 'off', 'PickableParts', 'none');
    grid(ax3, 'on');
    xlabel(ax3, 'Frequency (Hz)');
    ylabel(ax3, 'PSD (dB/Hz)');
    xlim(ax3, [psd_fmin_hz, psd_fmax_hz]);

    % Export and close
    exportgraphics(fig, outPath, 'Resolution', export_dpi);
    close(fig);
    clear figure_cleanup

    nSaved = nSaved + 1;

    % Progress (print occasionally, and always at the end)
    if progress_every >= 1
        if mod(nSaved, progress_every) == 0 || nSaved == nTotal
            fprintf('  Saved %d / %d\n', nSaved, nTotal);
        end
    end
end

staged_entries = dir(stagingDir);
staged_entries = staged_entries(~ismember({staged_entries.name}, {'.','..'}));
assert(numel(staged_entries) == nTotal && all(~[staged_entries.isdir]), ...
    'The staging directory does not contain exactly the planned file batch.');
assert(isequal(sort(string({staged_entries.name}).'), sort(planned_file_names)), ...
    'The staged PNG identities do not match the complete planned batch.');
assert(all([staged_entries.bytes] > 0), 'One or more staged PNGs are empty.');

promote_complete_directory(stagingDir, outDir, backupDir);

%% ───────────────────────────── SUMMARY ────────────────────────────────
fprintf('Saved PNGs: %d\n', nSaved);
fprintf('Done.\n');

log_command_window('stop');

%% ───────────────────────────── Helpers ────────────────────────────────
function tf = is_local_child(basePath, targetPath)
% Resolve existing parent symlinks and require targetPath beneath basePath.
baseCanonical = string(char(java.io.File(basePath).getCanonicalPath()));
targetCanonical = string(char(java.io.File(targetPath).getCanonicalPath()));
tf = startsWith(targetCanonical, baseCanonical + string(filesep));
end

function recover_interrupted_promotion(finalDir, stagingDir, backupDir)
% Restore a displaced prior final directory, then remove deterministic staging.
assert(~isfile(finalDir), 'The final output path is a file, not a directory: %s', finalDir);
assert(~isfile(stagingDir), 'The staging path is a file, not a directory: %s', stagingDir);
assert(~isfile(backupDir), 'The backup path is a file, not a directory: %s', backupDir);

if isfolder(backupDir)
    if isfolder(finalDir)
        delete_directory_if_present(backupDir);
    else
        [ok, msg] = movefile(backupDir, finalDir, 'f');
        assert(ok, 'Could not restore the prior complete output directory: %s', msg);
    end
end
delete_directory_if_present(stagingDir);
end

function prepare_staging_directory(stagingDir)
assert(~isfile(stagingDir) && ~isfolder(stagingDir), ...
    'The staging path must be absent before creation: %s', stagingDir);
[ok, msg] = mkdir(stagingDir);
assert(ok, 'Could not create the staging directory: %s', msg);
end

function delete_directory_if_present(folderPath)
assert(~isfile(folderPath), 'Refusing to delete a file at a directory-only path: %s', folderPath);
if isfolder(folderPath)
    [ok, msg] = rmdir(folderPath, 's');
    assert(ok, 'Could not remove deterministic local directory %s: %s', folderPath, msg);
end
end

function promote_complete_directory(stagingDir, finalDir, backupDir)
% Replace finalDir only after stagingDir has been built and verified completely.
assert(isfolder(stagingDir), 'Complete staging directory is absent: %s', stagingDir);
assert(~isfile(finalDir), 'The final output path is a file, not a directory: %s', finalDir);
assert(~isfile(backupDir) && ~isfolder(backupDir), ...
    'The deterministic backup path must be absent before promotion: %s', backupDir);

hadPriorFinal = isfolder(finalDir);
if hadPriorFinal
    [ok, msg] = movefile(finalDir, backupDir, 'f');
    assert(ok, 'Could not preserve the prior complete output directory: %s', msg);
end

try
    [ok, msg] = movefile(stagingDir, finalDir, 'f');
    assert(ok, 'Could not promote the complete staged output directory: %s', msg);
catch ME
    if hadPriorFinal && ~isfolder(finalDir) && isfolder(backupDir)
        [restored, restoreMsg] = movefile(backupDir, finalDir, 'f');
        if ~restored
            error('step_7_check_1:PromotionAndRestoreFailed', ...
                'Promotion failed (%s), and the prior output could not be restored (%s).', ...
                ME.message, restoreMsg);
        end
    end
    rethrow(ME)
end

if hadPriorFinal
    delete_directory_if_present(backupDir);
end
end

function close_figure_if_present(fig)
if isgraphics(fig)
    close(fig);
end
end

function out = sanitize_alnum(s)
% Remove everything except letters and digits 0-9. Preserve case.
s = string(s);
if ismissing(s) || strlength(s) == 0
    out = "";
    return
end
out = regexprep(s, '[^A-Za-z0-9]', '');
end
