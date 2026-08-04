%% step_7_check_3_plot_average_ts.m
% Purpose
%   Visualise group-level averaged EEG epochs for a single channel + eventtype,
%   with optional NRF-shifted averaging and optional NRF template overlays.
%
% Behaviour (high level)
%   1) Load SCREENED pooled epochs (MAT) from data/summary/screening/.
%   2) Assemble a 2D matrix of single-channel time series across all matching epochs.
%   3) Optionally drop items flagged Exclude (MAT-driven) via useExclusionFlags (ALL averaging approaches).
%   4) Compute a group-average EEG time series using one of:
%        - "simple"     : straight average/median across series.
%        - "NRFshifted" : use pre-computed NRF shifts to align each series (requires screened NRF CSV).
%        - "woody"      : iterative latency correction within a given ROI.
%   5) Optionally compute one or more NRF overlay time series (via ts_nrf_overlay),
%      each aligned, scaled, and NaN-padded to the same time base.
%   6) Store the result in table `ts_all` (time, EEG_avg, NRF overlays),
%      and optionally plot EEG + NRF overlays in a single figure.
%
% Inputs (screened; must already exist from Step 5.3 apply-decisions)
%   <baseDir>/data/summary/screening/pooled_screened_eeg_epochs.mat
%     - variable: epochs_pooled (struct array, one element per dataset)
%     - required field on each element: Exclude [nCh x nEp] logical
%
%   <baseDir>/data/summary/screening/pooled_screened_eeg_nrf_features.csv
%     - required ONLY if averagingApproach == "NRFshifted"
%     - must contain Exclude column with values 0/1 (or logical)
%
% Dependencies (on path, e.g., via functionsDir)
%   - ts_average_simple.m
%   - ts_average_NRFshifted.m
%   - ts_average_woody.m
%   - ts_nrf_overlay.m
%
% Outputs (in workspace)
%   - ts_all       : table with columns:
%                      time_ms, EEG_avg, <one column per NRF overlay>
%   - overlayFits  : struct of fit structs per NRF (if getNRFOverlays == true)
%   - Figure       : one figure showing EEG_avg ± NRF overlays (if plotNRFOverlays == true)

log_command_window('start');
clear; clc;

%% ────────────────────────── 1) Project paths and setup ──────────────────────────
baseDir      = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
functionsDir = fullfile(baseDir, 'functions');

if exist(functionsDir, 'dir')
    addpath(functionsDir);
end

screeningDir      = fullfile(baseDir, 'data', 'summary', 'screening');
screened_mat_file = fullfile(screeningDir, 'pooled_screened_eeg_epochs.mat');
screened_nrf_csv  = fullfile(screeningDir, 'pooled_screened_eeg_nrf_features.csv');

assert(isfile(screened_mat_file), 'Missing screened epochs MAT: %s', screened_mat_file);

%% ────────────────────────── 2) User-config ──────────────────────────
% 2A. Filters: which channel / eventtype?

channelFilter   = "Cz";       % channel label (matched case-insensitively, after trimming whitespace)
eventtypeFilter = "cannula";    % case-sensitive eventtype

% 2B. Exclusion toggle (the only exclusion mechanism)
useExclusionFlags = true;     % if true: drop items flagged Exclude; if false: ignore Exclude entirely

% 2C. Group-averaging options

% averagingApproach: "simple", "NRFshifted", or "woody" (case-insensitive)
averagingApproach = "simple";

% aggregator for the group trace: "mean" or "median" (case-insensitive)
aggregator = "mean";

% Smoothing window (ms) for the group trace (0 = no smoothing)
smoothingMs = 0;

% NRF-shifted averaging: which NRF's shift_samples to use
% (only relevant if averagingApproach == "NRFshifted")
shiftNRFName = "noxious_preterm_NRF_500Hz";

% Woody-options (used ONLY if averagingApproach == "woody")
woodyROI        = [0 1000];   % ms; search ROI for latency shifts
woodyMaxShiftMs = 50;         % ms; max |shift| allowed
woodyIterations = 10;         % fixed number of alignment iterations

% 2D. NRF overlay options

% Whether to compute NRF overlay time series (via ts_nrf_overlay)
getNRFOverlays  = true;

% Whether to plot NRF overlays on top of the EEG average
plotNRFOverlays = true;

% Which NRFs to compute overlay time series for (0–N entries allowed)
overlayNRFNames_to_compute = [ ...
    "early_NRF_500Hz"; ...
    "noxious_NRF_500Hz"; ...
    "noxious_preterm_NRF_500Hz" ...
    ];

% Which NRF overlays to plot (must be a subset of overlayNRFNames_to_compute)
overlayNRFNames_to_plot = [ ...
    "noxious_preterm_NRF_500Hz" ...
    ];

% 2E. NRF-specific fit window configuration (ms)
fit_time_map = struct( ...
    'early_NRF_500Hz',            100, ...
    'noxious_NRF_500Hz',          400, ...
    'noxious_preterm_NRF_500Hz',    0  ...
    );

jitter_map = struct( ...
    'early_NRF_500Hz',            100, ...
    'noxious_NRF_500Hz',          100, ...
    'noxious_preterm_NRF_500Hz',  100  ...
    );

% 2F. Plot configuration
xlim_window_ms = [-100 1150];   % ms
ylim_window_uV = [-20 20];      % microvolts

colour_time_zero = [0.6 0.6 0.6];

overlayColours = struct();
overlayColours.early_NRF_500Hz           = [20 204 204] / 255;  % cyan-ish
overlayColours.noxious_NRF_500Hz         = [0 0.5 0];           % red
overlayColours.noxious_preterm_NRF_500Hz = [1 0 0];             % dark green

%% ────────────────────────── 3) Validate user-config ──────────────────────────
averagingApproach          = lower(string(averagingApproach));
aggregator                 = lower(string(aggregator));
shiftNRFName               = string(shiftNRFName);
overlayNRFNames_to_compute = string(overlayNRFNames_to_compute(:));
overlayNRFNames_to_plot    = string(overlayNRFNames_to_plot(:));

validApproaches = ["simple","nrfshifted","woody"];
if ~ismember(averagingApproach, validApproaches)
    error('Config error: averagingApproach must be one of: %s', strjoin(cellstr(validApproaches), ', '));
end

validAgg = ["mean","median"];
if ~ismember(aggregator, validAgg)
    error('Config error: aggregator must be "mean" or "median".');
end

if ~getNRFOverlays && plotNRFOverlays
    error('Config error: plotNRFOverlays=true but getNRFOverlays=false. Set getNRFOverlays=true or plotNRFOverlays=false.');
end

if getNRFOverlays
    overlayNRFNames_to_compute = unique(overlayNRFNames_to_compute, 'stable');

    if ~isempty(overlayNRFNames_to_plot)
        bad = overlayNRFNames_to_plot(~ismember(overlayNRFNames_to_plot, overlayNRFNames_to_compute));
        if ~isempty(bad)
            error('Config error: overlayNRFNames_to_plot contains names not in overlayNRFNames_to_compute: %s', ...
                strjoin(cellstr(bad), ', '));
        end
    end
else
    overlayNRFNames_to_compute = strings(0,1);
    overlayNRFNames_to_plot    = strings(0,1);
end

if averagingApproach == "nrfshifted" && strlength(shiftNRFName) == 0
    error('Config error: averagingApproach="NRFshifted" requires shiftNRFName to be set.');
end

%% ────────────────────────── 4) Load screened epochs and assemble series ──────────────────────────
S = load(screened_mat_file);   % expects variable 'epochs_pooled'
if ~isfield(S, 'epochs_pooled')
    error('Expected variable "epochs_pooled" in %s', screened_mat_file);
end
epochs_pooled = S.epochs_pooled;

if ~isstruct(epochs_pooled) || isempty(epochs_pooled)
    error('epochs_pooled must be a non-empty struct array in %s', screened_mat_file);
end

% Hard requirement: Exclude must be present (even if ignoring it)
if ~isfield(epochs_pooled, 'Exclude')
    error(['Expected field "Exclude" on epochs_pooled (screened MAT). ', ...
        'This indicates Step 5.3 (apply-decisions) has not been run, or the wrong file was used.']);
end

ts               = [];            % [n_points x n_series]
times_ms         = [];            % [n_points x 1]
srate            = NaN;           % scalar
series_subj      = strings(0,1);
series_sess      = strings(0,1);
series_run       = strings(0,1);
series_epix      = [];
series_chan      = strings(0,1);
series_evt       = strings(0,1);
series_mat_excl  = false(0,1);    % per-series Exclude flag from MAT

for i = 1:numel(epochs_pooled)
    ep = epochs_pooled(i);

    % Basic required fields
    if ~isfield(ep,'data') || ~isfield(ep,'times_ms') || ~isfield(ep,'channels') || ~isfield(ep,'eventtype') || ~isfield(ep,'epoch_index') || ~isfield(ep,'srate')
        error('Dataset %d is missing required fields (data/times_ms/channels/eventtype/epoch_index/srate).', i);
    end

    % Validate Exclude for this dataset
    if ~isfield(ep, 'Exclude')
        error('Dataset %d: missing Exclude field (screened MAT expected).', i);
    end
    if ~islogical(ep.Exclude)
        error('Dataset %d: Exclude must be logical.', i);
    end
    if ndims(ep.data) ~= 3
        error('Dataset %d: expected ep.data as [nCh x nPts x nEp].', i);
    end
    nCh = size(ep.data,1);
    nEp = size(ep.data,3);
    if ~isequal(size(ep.Exclude), [nCh, nEp])
        error('Dataset %d: Exclude has wrong shape. Expected [%d x %d].', i, nCh, nEp);
    end

    subj = string(strtrim(ep.subjectID));
    sess = string(strtrim(ep.sessionID));
    run  = string(strtrim(ep.runID));

    chLabels = string(ep.channels(:));
    evtTypes = string(ep.eventtype(:));
    epIndex  = double(ep.epoch_index(:));

    chIdx = find(lower(strtrim(chLabels)) == lower(strtrim(channelFilter)), 1, 'first');
    if isempty(chIdx)
        continue;
    end

    keepEpochs = find(evtTypes == eventtypeFilter);
    if isempty(keepEpochs)
        continue;
    end

    if isempty(times_ms)
        times_ms = ep.times_ms(:);
        srate    = double(ep.srate);
    else
        if numel(times_ms) ~= numel(ep.times_ms) || any(times_ms ~= ep.times_ms(:))
            warning('Time vector in dataset %d differs from the first accepted dataset. Proceeding anyway.', i);
        end
    end

    for k = 1:numel(keepEpochs)
        eidx = keepEpochs(k);

        thisCol = squeeze(ep.data(chIdx, :, eidx)).';
        if ~isa(thisCol, 'single') && ~isa(thisCol, 'double')
            thisCol = single(thisCol);
        end

        if isempty(ts)
            ts = thisCol;
        else
            ts = [ts, thisCol]; %#ok<AGROW>
        end

        series_subj(end+1,1)     = subj;              %#ok<SAGROW>
        series_sess(end+1,1)     = sess;              %#ok<SAGROW>
        series_run(end+1,1)      = run;               %#ok<SAGROW>
        series_epix(end+1,1)     = epIndex(eidx);     %#ok<SAGROW>
        series_chan(end+1,1)     = chLabels(chIdx);     %#ok<SAGROW>
        series_evt(end+1,1)      = eventtypeFilter;   %#ok<SAGROW>
        series_mat_excl(end+1,1) = logical(ep.Exclude(chIdx, eidx)); %#ok<SAGROW>
    end
end

if isempty(ts)
    error('No time series collected. Check channelFilter="%s" and eventtypeFilter="%s".', ...
        char(channelFilter), char(eventtypeFilter));
end

[n_points, n_series] = size(ts);

% Preserve a stable pre-MAT-exclusion candidate list (needed for NRFshifted warning)
ts_raw              = ts;
series_subj_raw     = series_subj;
series_sess_raw     = series_sess;
series_run_raw      = series_run;
series_epix_raw     = series_epix;
series_chan_raw     = series_chan;
series_evt_raw      = series_evt;
series_mat_excl_raw = series_mat_excl;

n_candidates_total = n_series;
n_flagged_mat      = sum(series_mat_excl_raw);

% Apply MAT Exclude flags to ALL averaging approaches if toggled on
if useExclusionFlags
    keepMask = ~series_mat_excl;
    ts              = ts(:, keepMask);
    series_subj     = series_subj(keepMask);
    series_sess     = series_sess(keepMask);
    series_run      = series_run(keepMask);
    series_epix     = series_epix(keepMask);
    series_chan     = series_chan(keepMask);
    series_evt      = series_evt(keepMask);
    series_mat_excl = series_mat_excl(keepMask); %#ok<NASGU> % now all false, but keep for consistency
    n_excluded_by_flags = n_flagged_mat;
else
    keepMask = true(n_series, 1); %#ok<NASGU>
    n_excluded_by_flags = 0;
end

n_after_flags = size(ts, 2);

fprintf('Assembled data: %d points x %d candidates (channel=%s, eventtype=%s)\n', ...
    n_points, n_candidates_total, channelFilter, eventtypeFilter);
fprintf('times_ms: %d x 1; srate: %.3f Hz\n', numel(times_ms), srate);

%% ────────────────────────── 5) If needed: load NRF shifts for NRFshifted averaging ──────────────────────────
ts_for_NRFshifted        = [];
shifts_for_NRFshifted    = [];
n_series_used_for_average = NaN;

n_dropped_missing_shift = 0;  % only relevant for NRFshifted

if averagingApproach == "nrfshifted"
    assert(isfile(screened_nrf_csv), 'NRFshifted requested, but screened NRF CSV not found: %s', screened_nrf_csv);

    opts = detectImportOptions(screened_nrf_csv, 'PreserveVariableNames', true, 'TextType', 'string');

    % Force key columns to string (if present)
    idCols = intersect({'subjectID','sessionID','runID','eventtype','channel','NRFName'}, opts.VariableNames, 'stable');
    if ~isempty(idCols)
        opts = setvartype(opts, idCols, 'string');
    end

    % Ensure epoch_index & shift_samples are numeric if present
    numCols = intersect({'epoch_index','shift_samples','Exclude'}, opts.VariableNames, 'stable');
    for nc = 1:numel(numCols)
        opts = setvartype(opts, numCols{nc}, 'double');
    end

    Tnrf = readtable(screened_nrf_csv, opts);

    neededCols = {'subjectID','sessionID','runID','epoch_index','channel','eventtype','NRFName','shift_samples','Exclude'};
    if ~all(ismember(neededCols, Tnrf.Properties.VariableNames))
        error('Screened NRF CSV missing required columns for NRFshifted averaging (expected: %s).', strjoin(neededCols, ', '));
    end

    % Trim whitespace on string columns
    for c = 1:numel(idCols)
        col = idCols{c};
        Tnrf.(col) = strtrim(Tnrf.(col));
    end

    % Validate Exclude values: must be 0/1 only (or logical-equivalent)
    exv = double(Tnrf.Exclude);
    if any(~isfinite(exv))
        error('Screened NRF CSV contains non-finite Exclude values. Expected 0/1 only.');
    end
    if any(~ismember(exv, [0 1]))
        error('Screened NRF CSV contains Exclude values other than 0/1. Expected 0/1 only.');
    end
    Tnrf.Exclude = logical(exv);

    % Ensure numeric columns are double
    Tnrf.epoch_index   = double(Tnrf.epoch_index);
    Tnrf.shift_samples = double(Tnrf.shift_samples);

    % Filter NRF table to the specific channel/eventtype and the selected NRFName
    Tnrf = Tnrf(lower(strtrim(Tnrf.channel)) == lower(strtrim(channelFilter)) & Tnrf.eventtype == eventtypeFilter & Tnrf.NRFName == shiftNRFName, :);
    if isempty(Tnrf)
        error('No NRF rows found in screened NRF CSV for channel=%s, eventtype=%s, NRFName=%s.', ...
            char(channelFilter), char(eventtypeFilter), char(shiftNRFName));
    end

    % ── Consistency warning: MAT vs CSV Exclude (NRFshifted + useExclusionFlags==true only)
    if useExclusionFlags
        % Candidate series table BEFORE MAT exclusion (stable list)
        cand = table( ...
            series_subj_raw, series_sess_raw, series_run_raw, double(series_epix_raw), series_chan_raw, series_evt_raw, ...
            double(series_mat_excl_raw), ...
            'VariableNames', {'subjectID','sessionID','runID','epoch_index','channel','eventtype','mat_exclude'} ...
            );
        cand.channel_key = lower(strtrim(cand.channel));

        % CSV mapping for join (do NOT apply Exclude filter here; we are comparing)
        map = Tnrf(:, {'subjectID','sessionID','runID','epoch_index','channel','eventtype','Exclude'});
        map.csv_exclude = double(map.Exclude); % 0/1; outerjoin will yield NaN for non-matches
        map.Exclude = []; % drop to avoid confusion
        map.channel_key = lower(strtrim(map.channel));
        map.channel = [];

        joined_chk = outerjoin(cand, map, ...
            'Keys', {'subjectID','sessionID','runID','epoch_index','channel_key','eventtype'}, ...
            'MergeKeys', true, ...
            'Type', 'left');

        hit = ~isnan(joined_chk.csv_exclude); % "joinable" candidates (as per your requirement)

        if any(hit)
            mism = hit & (logical(joined_chk.mat_exclude) ~= (joined_chk.csv_exclude == 1));
            nMismatch = sum(mism);

            if nMismatch > 0
                exRows = find(mism);
                nShow = min(5, numel(exRows));

                keys = joined_chk.subjectID(exRows) + "|" + joined_chk.sessionID(exRows) + "|" + joined_chk.runID(exRows) + "|" + ...
                    string(joined_chk.epoch_index(exRows)) + "|" + joined_chk.channel(exRows) + "|" + joined_chk.eventtype(exRows);

                sampleKeys = keys(1:nShow);
                sampleTxt = "  " + strjoin(sampleKeys, newline + "  ");

                warning('Screening:PlotAverageTS:ExcludeMismatch', ...
                    'MAT vs CSV Exclude mismatch for %d joinable candidate series (showing up to %d):\n%s', ...
                    nMismatch, nShow, char(sampleTxt));
            end
        end
    end

    % ── Belt-and-braces: when using exclusion flags, filter NRF rows to Exclude==0 before joining
    if useExclusionFlags
        Tshift = Tnrf(~Tnrf.Exclude, :);
    else
        Tshift = Tnrf; % ignore Exclude completely
    end

    % Reduce to join keys + shift_samples (channel/eventtype included as safety guard)
    Tshift = Tshift(:, {'subjectID','sessionID','runID','epoch_index','channel','eventtype','shift_samples'});
    Tshift.channel_key = lower(strtrim(Tshift.channel));

    % Build post-flag series table for joining (in the same column order as ts)
    n_series_post_flags = size(ts, 2);
    series_id = (1:n_series_post_flags).';

    seriesTable = table( ...
        series_id, series_subj, series_sess, series_run, double(series_epix), series_chan, series_evt, ...
        'VariableNames', {'series_id','subjectID','sessionID','runID','epoch_index','channel','eventtype'} ...
        );
    seriesTable.channel_key = lower(strtrim(seriesTable.channel));

    joined = outerjoin(seriesTable, Tshift, ...
        'Keys', {'subjectID','sessionID','runID','epoch_index','channel_key','eventtype'}, ...
        'MergeKeys', true, ...
        'Type', 'left');

    % Ensure alignment to original series order
    joined = sortrows(joined, 'series_id');
    shifts_all = reshape(joined.shift_samples, 1, []);

    % Drop series with NaN shifts (distinct from Exclude-based dropping)
    mask_valid = ~isnan(shifts_all);
    n_dropped_missing_shift = sum(~mask_valid);
    n_remaining             = sum(mask_valid);

    if n_dropped_missing_shift > 0
        fprintf('Dropped %d series due to missing NRF shifts for %s (remaining: %d).\n', ...
            n_dropped_missing_shift, char(shiftNRFName), n_remaining);
    end
    if n_remaining == 0
        error('All series have missing NRF shifts for %s; cannot compute NRF-shifted average.', char(shiftNRFName));
    end

    ts_for_NRFshifted     = ts(:, mask_valid);
    shifts_for_NRFshifted = shifts_all(mask_valid);

    if any(~isfinite(shifts_for_NRFshifted)) || any(mod(shifts_for_NRFshifted, 1) ~= 0)
        error('Selected shifts for %s contain non-integer or non-finite values.', char(shiftNRFName));
    end
end

%% ────────────────────────── 6) Compute group-average EEG time series ──────────────────────────
switch averagingApproach
    case "simple"
        ts_avg = ts_average_simple(ts, ...
            'Aggregator',        aggregator, ...
            'SmoothingWindowMs', smoothingMs, ...
            'SRate',             srate);
        n_series_used_for_average = size(ts, 2);
        title_approach = 'simple';

    case "nrfshifted"
        ts_avg = ts_average_NRFshifted(ts_for_NRFshifted, shifts_for_NRFshifted, ...
            'Aggregator',        aggregator, ...
            'SmoothingWindowMs', smoothingMs, ...
            'SRate',             srate);
        n_series_used_for_average = size(ts_for_NRFshifted, 2);
        title_approach = sprintf('NRF-shifted [%s]', char(shiftNRFName));

    case "woody"
        [ts_avg, woody_shifts_samples] = ts_average_woody(ts, ...
            'TimesMs',           times_ms, ...
            'SRate',             srate, ...
            'ROI',               woodyROI, ...
            'MaxShiftMs',        woodyMaxShiftMs, ...
            'Iterations',        woodyIterations, ...
            'Aggregator',        aggregator, ...
            'SmoothingWindowMs', smoothingMs);
        %#ok<NASGU>
        n_series_used_for_average = size(ts, 2);
        title_approach = sprintf('woody (ROI %g–%g ms, ±%g ms, K=%d)', ...
            woodyROI(1), woodyROI(2), woodyMaxShiftMs, woodyIterations);

    otherwise
        error('Unknown averagingApproach: %s. Allowed: "simple", "NRFshifted", or "woody".', averagingApproach);
end

%% ────────────────────────── 6B) Concise Command Window reporting (always) ──────────────────────────
fprintf('\nSummary:\n');
fprintf('  channel=%s | eventtype=%s\n', char(channelFilter), char(eventtypeFilter));
fprintf('  approach=%s | aggregator=%s | smoothing=%gms\n', char(title_approach), char(aggregator), smoothingMs);

if useExclusionFlags
    fprintf('  useExclusionFlags=true | excluded_by_flags=%d | candidates=%d | after_flags=%d\n', ...
        n_excluded_by_flags, n_candidates_total, n_after_flags);
else
    fprintf('  useExclusionFlags=false | candidates=%d | used=%d | (flags present but ignored; flagged_in_mat=%d)\n', ...
        n_candidates_total, n_after_flags, n_flagged_mat);
end

if averagingApproach == "nrfshifted"
    fprintf('  shiftNRFName=%s | dropped_missing_shift=%d | used_for_average=%d\n', ...
        char(shiftNRFName), n_dropped_missing_shift, n_series_used_for_average);
else
    fprintf('  used_for_average=%d\n', n_series_used_for_average);
end

%% ────────────────────────── 7) Compute NRF overlay time series (optional) ──────────────────────────
overlayTS   = struct();
overlayFits = struct();

if getNRFOverlays && ~isempty(overlayNRFNames_to_compute)
    for i = 1:numel(overlayNRFNames_to_compute)
        thisNRF  = overlayNRFNames_to_compute(i);
        nameChar = char(thisNRF);

        if ~isfield(fit_time_map, nameChar)
            error('No fit_time_ms configured for NRF "%s" in fit_time_map.', nameChar);
        end
        if ~isfield(jitter_map, nameChar)
            error('No jitter_ms configured for NRF "%s" in jitter_map.', nameChar);
        end

        fit_time_ms = fit_time_map.(nameChar);
        jitter_ms   = jitter_map.(nameChar);

        [overlay_ts, fitStruct] = ts_nrf_overlay(ts_avg, thisNRF, times_ms, fit_time_ms, jitter_ms);

        overlayTS.(nameChar)   = overlay_ts;
        overlayFits.(nameChar) = fitStruct;
    end
end

%% ────────────────────────── 8) Assemble ts_all table ──────────────────────────
varNames = {'time_ms','EEG_avg'};
vars     = {times_ms(:), ts_avg(:)};

if getNRFOverlays && ~isempty(overlayNRFNames_to_compute)
    for i = 1:numel(overlayNRFNames_to_compute)
        thisNRF  = overlayNRFNames_to_compute(i);
        nameChar = char(thisNRF);

        if ~isfield(overlayTS, nameChar)
            error('Internal error: overlay time series missing for NRF "%s".', nameChar);
        end

        varNames{end+1} = nameChar;                %#ok<SAGROW>
        vars{end+1}     = overlayTS.(nameChar)(:); %#ok<SAGROW>
    end
end

ts_all = table(vars{:}, 'VariableNames', varNames);

%% ────────────────────────── 9) Plot EEG average ± NRF overlays ──────────────────────────
if plotNRFOverlays
    figure('Color','w'); hold on;

    h_eeg = plot(ts_all.time_ms, ts_all.EEG_avg, 'LineWidth', 2);

    xline(0, '--', 'Color', colour_time_zero, 'LineWidth', 1, 'HandleVisibility', 'off');

    h_overlays = gobjects(0);
    legend_labels = {'EEG data'};

    if getNRFOverlays && ~isempty(overlayNRFNames_to_plot)
        for i = 1:numel(overlayNRFNames_to_plot)
            thisNRF  = overlayNRFNames_to_plot(i);
            nameChar = char(thisNRF);

            if ~ismember(nameChar, ts_all.Properties.VariableNames)
                error('Config error: requested overlay "%s" to plot, but no overlay time series was computed.', nameChar);
            end
            if ~isfield(overlayColours, nameChar)
                error('Config error: no colour configured for overlay "%s" in overlayColours.', nameChar);
            end

            this_ts  = ts_all.(nameChar);
            this_col = overlayColours.(nameChar);

            h = plot(ts_all.time_ms, this_ts, 'LineWidth', 2, 'Color', this_col);
            h_overlays(end+1)    = h;        %#ok<SAGROW>
            legend_labels{end+1} = nameChar; %#ok<SAGROW>
        end
    end

    set(gca, 'YDir', 'reverse', 'FontSize', 15);
    grid on; box on;
    xlabel('Time (ms)', 'FontSize', 15);
    ylabel('Amplitude (\muV)', 'FontSize', 15);

    title(sprintf('TS | approach=%s | aggregator=%s | smoothing=%gms | n=%d | channel=%s | eventtype=%s', ...
        char(title_approach), char(aggregator), smoothingMs, n_series_used_for_average, char(channelFilter), char(eventtypeFilter)), ...
        'FontSize', 12, 'Interpreter', 'none');

    if isempty(h_overlays)
        legend(h_eeg, legend_labels, ...
            'Location', 'northeast', ...
            'Box', 'off', ...
            'FontSize', 15, ...
            'Interpreter', 'none');
    else
        legend([h_eeg; h_overlays(:)], legend_labels, ...
            'Location', 'northeast', ...
            'Box', 'off', ...
            'FontSize', 15, ...
            'Interpreter', 'none');
    end

    tmin = min(ts_all.time_ms);
    tmax = max(ts_all.time_ms);
    xwin = [max(xlim_window_ms(1), tmin), min(xlim_window_ms(2), tmax)];
    xlim(xwin);

    ylim(ylim_window_uV);

    hold off;
end

fprintf('\nDone. ts_all has %d rows and %d columns.\n', height(ts_all), width(ts_all));
fprintf('Columns: %s\n', strjoin(ts_all.Properties.VariableNames, ', '));

log_command_window('stop');