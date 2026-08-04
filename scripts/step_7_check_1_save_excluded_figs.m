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
% Plot layout (1x3), matching step_5_screen_2_viewer_rate_epochs.m:
%   1) Time-domain (fixed y)
%   2) Time-domain (auto y)
%   3) PSD (log power, pmtm)
%
% Behaviour
%   - Deterministic generation order: subjectID, sessionID, runID, epoch_index, channel
%   - If excluded_epochs exists, deletes ALL contents inside it (files + subfolders), but keeps the folder.
%   - Uses exportgraphics only (no fallbacks).
%   - Figures are created invisibly and closed after export.
%   - If no excluded items, folder is cleared/created and script prints 0 saved.
%   - Prints a progress counter to the Command Window.
%
% Logging
%   - Writes Command Window log via log_command_window('start'/'stop').

log_command_window('start');
clear; clc;

%% ───────────────────────────── USER CONFIG ─────────────────────────────
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';

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

% Ensure output folder exists; do NOT create screeningDir
if ~exist(outDir, 'dir')
    ok = mkdir(outDir);
    assert(ok, 'Failed to create output folder: %s', outDir);
end

% Clear output folder contents (delete everything inside, keep folder)
clear_folder_contents(outDir);

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
    assert(ndims(E.data) == 3, 'Dataset %d: expected data as [nCh x nPts x nEp].', d);
    nCh = size(E.data, 1);
    nEp = size(E.data, 3);

    % Validate channels/eventtype/epoch_index lengths
    assert(iscell(E.channels) && numel(E.channels) == nCh, 'Dataset %d: channels length mismatch.', d);
    assert(iscell(E.eventtype) && numel(E.eventtype) == nEp, 'Dataset %d: eventtype length mismatch.', d);
    assert(isnumeric(E.epoch_index) && numel(E.epoch_index) == nEp, 'Dataset %d: epoch_index length mismatch.', d);

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

if isempty(rows)
    fprintf('Excluded items found: 0\n');
    fprintf('Output folder cleared/ready: %s\n', outDir);
    log_command_window('stop');
    return
end

% Deterministic sort: subjectID, sessionID, runID, epoch_index, channel
rows = sortrows(rows, {'subjectID','sessionID','runID','epoch_index','channel'});

fprintf('Excluded items found: %d\n', height(rows));
fprintf('Saving PNGs to: %s\n', outDir);

%% ───────────────────────────── PLOT + EXPORT ──────────────────────────
% Track filenames to handle collisions after sanitisation
nameCounts = containers.Map('KeyType','char', 'ValueType','double');

nSaved = 0;
nTotal = height(rows);

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

    % Build filename components (use exact stored values, sanitised)
    subj_raw = "sub-" + string(r.subjectID);
    sess_raw = "ses-" + string(r.sessionID);
    run_raw  = "run-" + string(r.runID);
    chan_raw = "chan-" + string(r.channel);
    ep_raw   = "epoch-" + string(r.epoch_index);

    ev_raw   = string(r.eventtype); % may be empty

    % Sanitise each component: remove non-alphanumeric from the variable part, keep prefix + hyphen.
    subj = "sub-"   + sanitize_alnum(strip_prefix_value(subj_raw, "sub-"));
    sess = "ses-"   + sanitize_alnum(strip_prefix_value(sess_raw, "ses-"));
    run  = "run-"   + sanitize_alnum(strip_prefix_value(run_raw,  "run-"));
    chan = "chan-"  + sanitize_alnum(strip_prefix_value(chan_raw, "chan-"));
    epc  = "epoch-" + sanitize_alnum(strip_prefix_value(ep_raw,   "epoch-"));
    ev   = sanitize_alnum(ev_raw);

    % Assemble base filename (underscore-separated components; final slot is eventtype, may be empty)
    baseName = subj + "_" + sess + "_" + run + "_" + epc + "_" + chan + "_" + ev;

    % Collision handling: append _dupN (starting at 2) if needed
    key = char(baseName);
    if isKey(nameCounts, key)
        nameCounts(key) = nameCounts(key) + 1;
        baseName = baseName + "_dup" + string(nameCounts(key));
    else
        nameCounts(key) = 1;
    end

    fileName = baseName + ".png";
    outPath  = fullfile(outDir, char(fileName));

    % Figure title uses vertical bars, aligned to filename components (no per-subplot titles)
    titleStr = strrep(char(baseName), '_', ' | ');

    % Create invisible figure sized in pixels
    figure( ...
        'Visible', 'off', ...
        'Color', 'w', ...
        'Units', 'pixels', ...
        'Position', [100, 100, figure_size_px(1), figure_size_px(2)]);

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
    exportgraphics(gcf, outPath, 'Resolution', export_dpi);
    close(gcf);

    nSaved = nSaved + 1;

    % Progress (print occasionally, and always at the end)
    if progress_every >= 1
        if mod(nSaved, progress_every) == 0 || nSaved == nTotal
            fprintf('  Saved %d / %d\n', nSaved, nTotal);
        end
    end
end

%% ───────────────────────────── SUMMARY ────────────────────────────────
fprintf('Saved PNGs: %d\n', nSaved);
fprintf('Done.\n');

log_command_window('stop');

%% ───────────────────────────── Helpers ────────────────────────────────
function clear_folder_contents(folderPath)
% Delete everything inside folderPath (files and subfolders), but not the folder itself.
d = dir(folderPath);
for i = 1:numel(d)
    name = d(i).name;
    if strcmp(name, '.') || strcmp(name, '..')
        continue
    end
    fullp = fullfile(folderPath, name);
    if d(i).isdir
        rmdir(fullp, 's');
    else
        delete(fullp);
    end
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

function val = strip_prefix_value(s, prefix)
% Given s like "ses-01", return the part after prefix ("01").
% If prefix missing, return s unchanged (best-effort).
s = string(s);
prefix = string(prefix);
if startsWith(s, prefix)
    val = extractAfter(s, strlength(prefix));
else
    val = s;
end
end