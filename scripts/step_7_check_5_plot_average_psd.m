%% step_7_check_5_plot_average_psd.m
% Purpose
%   Visualise a group-level averaged EEG power spectral density (PSD) curve for a
%   single channel + eventtype, using screened pooled epochs with an Exclude mask.
%
% Behaviour (high level)
%   1) Load SCREENED pooled epochs (MAT) from data/summary/screening/.
%   2) Assemble a set of single-channel epoch time series across all matching epochs.
%   3) Optionally drop items flagged Exclude (MAT-driven) via useExclusionFlags.
%   4) Select an epoch window (full, post-stim, or baseline) based on times_ms.
%   5) Compute multitaper PSD (pmtm) for each retained epoch-series (NW=4, NFFT=1024, one-sided).
%   6) Aggregate PSDs across epochs using:
%        - aggregator: "mean" or "median"
%        - aggregateDomain: "linear_power" or "db_power"
%      and always plot the final average as PSD (dB/Hz).
%   7) Print concise, informative summary information to the Command Window.
%
% Inputs (screened; must already exist from Step 6.3 apply-decisions)
%   <baseDir>/data/summary/screening/pooled_screened_eeg_epochs.mat
%     - variable: epochs_pooled (struct array, one element per dataset)
%     - required field on each element: Exclude [nCh x nEp] logical
%
% Outputs (in workspace)
%   - psd_all : table with columns:
%                 freq_hz, PSD_avg_db
%   - Figure  : one figure showing PSD_avg_db vs freq_hz

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

assert(isfile(screened_mat_file), 'Missing screened epochs MAT: %s', screened_mat_file);

%% ────────────────────────── 2) User-config ──────────────────────────
% 2A. Filters: which channel / eventtype?

channelFilter   = "Cz";       % channel label (matched case-insensitively, after trimming whitespace)
eventtypeFilter = "cannula";    % case-sensitive eventtype

% 2B. Exclusion toggle (the only exclusion mechanism)
useExclusionFlags = true;     % if true: drop items flagged Exclude; if false: ignore Exclude entirely

% 2C. Epoch window for PSD
%   "post-stim" : samples at times_ms >= 0
%   "baseline"  : samples at times_ms < 0
%   "full"      : all samples
epochWindow = "post-stim";

% 2D. PSD aggregation options (across epochs)
% aggregator: "mean" or "median"
aggregator = "mean";

% aggregateDomain:
%   "linear_power" : aggregate on linear PSD, then convert the average to dB for plotting (recommended)
%   "db_power"     : convert each epoch PSD to dB first, then aggregate in dB (use for visual robustness only)
aggregateDomain = "linear_power";

% 2E. Frequency axis (plot limits)
fmin_hz = -1;
fmax_hz = 251;

% 2F. Plot configuration
figureTitleFontSize = 12;
axisFontSize        = 15;

% Fixed multitaper settings
timeBandwidthProduct = 4;
nfft                 = 1024;

%% ────────────────────────── 3) Validate user-config ──────────────────────────
channelFilter   = string(channelFilter);
eventtypeFilter = string(eventtypeFilter);
epochWindow     = string(epochWindow);
aggregator      = string(aggregator);
aggregateDomain = string(aggregateDomain);

if ~isscalar(channelFilter) || ismissing(channelFilter) || strlength(strtrim(channelFilter)) == 0
    error('Config error: channelFilter must be one nonblank text scalar.');
end
if ~isscalar(eventtypeFilter) || ismissing(eventtypeFilter) || strlength(strtrim(eventtypeFilter)) == 0
    error('Config error: eventtypeFilter must be one nonblank text scalar.');
end
if ~isscalar(epochWindow) || ismissing(epochWindow) || ...
        ~isscalar(aggregator) || ismissing(aggregator) || ...
        ~isscalar(aggregateDomain) || ismissing(aggregateDomain)
    error('Config error: epochWindow, aggregator, and aggregateDomain must each be one text scalar.');
end

channelFilter   = strtrim(channelFilter);
eventtypeFilter = strtrim(eventtypeFilter);
epochWindow     = lower(strtrim(epochWindow));
aggregator      = lower(strtrim(aggregator));
aggregateDomain = lower(strtrim(aggregateDomain));

validWindows = ["post-stim","baseline","full"];
if ~ismember(epochWindow, validWindows)
    error('Config error: epochWindow must be one of: %s', strjoin(cellstr(validWindows), ', '));
end

validAgg = ["mean","median"];
if ~ismember(aggregator, validAgg)
    error('Config error: aggregator must be "mean" or "median".');
end

validDomains = ["linear_power","db_power"];
if ~ismember(aggregateDomain, validDomains)
    error('Config error: aggregateDomain must be one of: %s', strjoin(cellstr(validDomains), ', '));
end

if ~isnumeric(fmin_hz) || ~isreal(fmin_hz) || ~isscalar(fmin_hz) || ...
        ~isnumeric(fmax_hz) || ~isreal(fmax_hz) || ~isscalar(fmax_hz) || ...
        ~isfinite(fmin_hz) || ~isfinite(fmax_hz) || fmax_hz <= fmin_hz
    error('Config error: fmin_hz and fmax_hz must be finite scalars with fmin_hz < fmax_hz.');
end

if ~islogical(useExclusionFlags) || ~isscalar(useExclusionFlags)
    error('Config error: useExclusionFlags must be a logical scalar.');
end

if ~isnumeric(timeBandwidthProduct) || ~isreal(timeBandwidthProduct) || ...
        ~isscalar(timeBandwidthProduct) || ~isfinite(timeBandwidthProduct) || timeBandwidthProduct < 1.25
    error(['Config error: timeBandwidthProduct must be one finite real value of at least 1.25 ', ...
        'for pmtm''s default dropped-last-taper route.']);
end
if ~isnumeric(nfft) || ~isreal(nfft) || ~isscalar(nfft) || ...
        ~isfinite(nfft) || nfft < 2 || mod(nfft, 1) ~= 0
    error('Config error: nfft must be an integer scalar of at least 2.');
end

if ~isnumeric(figureTitleFontSize) || ~isreal(figureTitleFontSize) || ...
        ~isscalar(figureTitleFontSize) || ~isfinite(figureTitleFontSize) || figureTitleFontSize <= 0 || ...
        ~isnumeric(axisFontSize) || ~isreal(axisFontSize) || ...
        ~isscalar(axisFontSize) || ~isfinite(axisFontSize) || axisFontSize <= 0
    error('Config error: figureTitleFontSize and axisFontSize must be positive finite numeric scalars.');
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
        'This indicates Step 6.3 (apply-decisions) has not been run, or the wrong file was used.']);
end

% Collect time series and metadata (one column per epoch-series)
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
    needFields = {'data','times_ms','channels','eventtype','epoch_index','srate','subjectID','sessionID','runID','Exclude'};
    for nf = 1:numel(needFields)
        if ~isfield(ep, needFields{nf})
            error('Dataset %d is missing required field: %s', i, needFields{nf});
        end
    end

    if ~isnumeric(ep.data) || ~isreal(ep.data) || isempty(ep.data) || ndims(ep.data) > 3
        error('Dataset %d: ep.data must be a non-empty real numeric [nCh x nPts x nEp] array.', i);
    end
    if any(~isfinite(ep.data(:)))
        error('Dataset %d: ep.data contains a nonfinite value.', i);
    end
    if ~islogical(ep.Exclude)
        error('Dataset %d: Exclude must be logical.', i);
    end
    nCh = size(ep.data, 1);
    nPts = size(ep.data, 2);
    nEp = size(ep.data, 3);
    if ~isequal(size(ep.Exclude), [nCh, nEp])
        error('Dataset %d: Exclude has wrong shape. Expected [%d x %d].', i, nCh, nEp);
    end

    subj = strtrim(string(ep.subjectID));
    sess = strtrim(string(ep.sessionID));
    run  = strtrim(string(ep.runID));
    if ~isscalar(subj) || ismissing(subj) || strlength(subj) == 0 || ...
            ~isscalar(sess) || ismissing(sess) || strlength(sess) == 0 || ...
            ~isscalar(run) || ismissing(run) || strlength(run) == 0
        error('Dataset %d: subjectID, sessionID, and runID must each be one nonblank text value.', i);
    end

    if ischar(ep.channels)
        chLabels = string(cellstr(ep.channels));
    elseif isstring(ep.channels) || iscellstr(ep.channels)
        chLabels = string(ep.channels(:));
    else
        error('Dataset %d: channels must be a text vector.', i);
    end
    if ischar(ep.eventtype)
        evtTypes = string(cellstr(ep.eventtype));
    elseif isstring(ep.eventtype) || iscellstr(ep.eventtype)
        evtTypes = string(ep.eventtype(:));
    else
        error('Dataset %d: eventtype must be a text vector.', i);
    end
    chLabels = strtrim(chLabels(:));
    evtTypes = strtrim(evtTypes(:));

    if numel(chLabels) ~= nCh || any(ismissing(chLabels)) || any(strlength(chLabels) == 0)
        error('Dataset %d: channels must contain one nonblank label for each of %d data channels.', i, nCh);
    end
    if numel(unique(lower(chLabels))) ~= nCh
        error('Dataset %d: channel labels must be unique after case-insensitive trimming.', i);
    end
    if numel(evtTypes) ~= nEp || any(ismissing(evtTypes)) || any(strlength(evtTypes) == 0)
        error('Dataset %d: eventtype must contain one nonblank label for each of %d epochs.', i, nEp);
    end

    if ~isnumeric(ep.epoch_index) || ~isreal(ep.epoch_index)
        error('Dataset %d: epoch_index must be a real numeric vector.', i);
    end
    epIndex = double(ep.epoch_index(:));
    if numel(epIndex) ~= nEp || any(~isfinite(epIndex)) || any(mod(epIndex, 1) ~= 0)
        error('Dataset %d: epoch_index must contain one finite integer for each of %d epochs.', i, nEp);
    end
    if numel(unique(epIndex)) ~= nEp
        error('Dataset %d: epoch_index values must be unique.', i);
    end

    if ~isnumeric(ep.times_ms) || ~isreal(ep.times_ms)
        error('Dataset %d: times_ms must be a real numeric vector.', i);
    end
    thisTimes = double(ep.times_ms(:));
    if numel(thisTimes) ~= nPts || any(~isfinite(thisTimes)) || any(diff(thisTimes) <= 0)
        error('Dataset %d: times_ms must have %d finite, strictly increasing samples.', i, nPts);
    end
    if ~isnumeric(ep.srate) || ~isreal(ep.srate) || ~isscalar(ep.srate) || ...
            ~isfinite(ep.srate) || ep.srate <= 0
        error('Dataset %d: srate must be one positive finite real value.', i);
    end
    expectedStepMs = 1000 / double(ep.srate);
    stepToleranceMs = max(1e-9, 1e-6 * expectedStepMs);
    if nPts < 2 || any(abs(diff(thisTimes) - expectedStepMs) > stepToleranceMs)
        error('Dataset %d: times_ms spacing is not coherent with srate=%.12g Hz.', i, double(ep.srate));
    end

    chMatches = find(lower(chLabels) == lower(channelFilter));
    if numel(chMatches) > 1
        error('Dataset %d: channelFilter="%s" matches more than one channel.', i, char(channelFilter));
    end
    chIdx = chMatches;
    if isempty(chIdx)
        continue;
    end

    keepEpochs = find(evtTypes == eventtypeFilter);
    if isempty(keepEpochs)
        continue;
    end

    % Enforce identical time base and sampling rate across all CONTRIBUTING datasets (PSD comparability)
    if isempty(times_ms)
        times_ms = thisTimes;
        srate    = double(ep.srate);
    else
        if numel(times_ms) ~= numel(thisTimes) || any(times_ms ~= thisTimes)
            error('Time vector mismatch: dataset %d differs from the first dataset (PSD requires consistent time base).', i);
        end
        if double(ep.srate) ~= srate
            error('Sampling rate mismatch: dataset %d has srate=%.6f but expected %.6f (PSD requires consistent Fs).', ...
                i, double(ep.srate), srate);
        end
    end

    for k = 1:numel(keepEpochs)
        eidx = keepEpochs(k);

        thisCol = reshape(ep.data(chIdx, :, eidx), [], 1);
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

if n_points ~= numel(times_ms)
    error('Internal assembly error: collected data length does not match times_ms length.');
end
seriesIdentity = [series_subj, series_sess, series_run, string(series_epix)];
if size(unique(seriesIdentity, 'rows'), 1) ~= n_series
    error('Selected items are not unique by subject, session, run, channel, eventtype, and epoch_index.');
end

n_candidates_total = n_series;
n_flagged_mat      = sum(series_mat_excl);

% Apply MAT Exclude flags if toggled on
if useExclusionFlags
    keepMask = ~series_mat_excl;
    ts               = ts(:, keepMask);
    series_subj      = series_subj(keepMask);
    series_sess      = series_sess(keepMask);
    series_run       = series_run(keepMask);
    series_epix      = series_epix(keepMask);
    series_chan      = series_chan(keepMask);
    series_evt       = series_evt(keepMask);
    series_mat_excl  = series_mat_excl(keepMask); %#ok<NASGU>
    n_excluded_by_flags = n_flagged_mat;
else
    n_excluded_by_flags = 0;
end

n_after_flags = size(ts, 2);

if n_after_flags == 0
    error('All candidate series were excluded by Exclude flags. Nothing left to compute PSD.');
end

%% ────────────────────────── 4B) Select epoch window samples ──────────────────────────
t = double(times_ms(:));
switch epochWindow
    case "full"
        winMask = true(size(t));
    case "post-stim"
        winMask = (t >= 0);
    case "baseline"
        winMask = (t < 0);
    otherwise
        error('Internal error: unexpected epochWindow: %s', epochWindow);
end

nWin = sum(winMask);
if nWin == 0
    error('epochWindow="%s" yields zero samples (times_ms has no samples in that region).', char(epochWindow));
end
if timeBandwidthProduct >= nWin / 2
    error(['epochWindow="%s" yields %d samples, but pmtm requires the time-bandwidth product ', ...
        '(%.12g) to be less than half the signal length.'], ...
        char(epochWindow), nWin, timeBandwidthProduct);
end

ts_win = ts(winMask, :);

%% ────────────────────────── 5) Compute per-epoch PSDs ──────────────────────────
Pmat = [];   % [nFreq x nSeries] linear PSD
Fref = [];   % [nFreq x 1]

for j = 1:size(ts_win, 2)
    y = double(ts_win(:, j));

    [Pxx, F] = pmtm(y, timeBandwidthProduct, nfft, srate, 'onesided');
    if ~isnumeric(Pxx) || ~isreal(Pxx) || any(~isfinite(Pxx(:))) || any(Pxx(:) < 0)
        error('pmtm returned invalid PSD values for series %d.', j);
    end
    if ~isnumeric(F) || ~isreal(F) || any(~isfinite(F(:))) || ...
            any(F(:) < 0) || any(F(:) > srate / 2 + max(eps(srate), 1e-12)) || ...
            any(diff(double(F(:))) <= 0)
        error('pmtm returned an invalid one-sided frequency grid for series %d.', j);
    end
    if numel(Pxx) ~= numel(F)
        error('pmtm returned mismatched PSD and frequency dimensions for series %d.', j);
    end
    Pxx = max(Pxx, eps);

    if isempty(Fref)
        Fref = double(F(:));
        Pmat = zeros(numel(Fref), size(ts_win, 2));
    else
        if numel(F) ~= numel(Fref) || any(double(F(:)) ~= Fref)
            error(['pmtm frequency grid mismatch across epochs. This should not happen with fixed ', ...
                'Fs=%.3f, time-bandwidth product=%g, and NFFT=%d.'], ...
                srate, timeBandwidthProduct, nfft);
        end
    end

    Pmat(:, j) = double(Pxx(:));
end

if isempty(Pmat) || ~isreal(Pmat) || any(~isfinite(Pmat(:)))
    error('Computed per-series PSD matrix is empty, complex, or nonfinite.');
end

%% ────────────────────────── 6) Aggregate PSDs and convert to dB for plotting ──────────────────────────
switch aggregateDomain
    case "linear_power"
        % Aggregate in linear units, then convert the average to dB
        switch aggregator
            case "mean"
                Pavg_lin = mean(Pmat, 2, 'omitnan');
            case "median"
                Pavg_lin = median(Pmat, 2, 'omitnan');
            otherwise
                error('Internal error: unexpected aggregator: %s', aggregator);
        end
        Pavg_lin = max(Pavg_lin, eps);
        PSD_avg_db = 10 * log10(Pavg_lin);

    case "db_power"
        % Convert each epoch PSD to dB, then aggregate in dB
        Pdb = 10 * log10(max(Pmat, eps));

        switch aggregator
            case "mean"
                PSD_avg_db = mean(Pdb, 2, 'omitnan');
            case "median"
                PSD_avg_db = median(Pdb, 2, 'omitnan');
            otherwise
                error('Internal error: unexpected aggregator: %s', aggregator);
        end

    otherwise
        error('Internal error: unexpected aggregateDomain: %s', aggregateDomain);
end

if ~isreal(PSD_avg_db) || any(~isfinite(PSD_avg_db(:))) || numel(PSD_avg_db) ~= numel(Fref)
    error('Aggregated PSD result is nonfinite or has unexpected dimensions.');
end

%% ────────────────────────── 6B) Assemble output table ──────────────────────────
psd_all = table(Fref, PSD_avg_db, 'VariableNames', {'freq_hz','PSD_avg_db'});

%% ────────────────────────── 6C) Concise Command Window reporting (always) ──────────────────────────
fprintf('\nSummary:\n');
fprintf('  channel=%s | eventtype=%s\n', char(channelFilter), char(eventtypeFilter));
fprintf('  epochWindow=%s | Fs=%.3f Hz | nWinSamples=%d\n', char(epochWindow), srate, nWin);
fprintf('  pmtm: timeBandwidthProduct=%g | nfft=%d | one-sided\n', timeBandwidthProduct, nfft);
fprintf('  aggregator=%s | aggregateDomain=%s\n', char(aggregator), char(aggregateDomain));

if useExclusionFlags
    fprintf('  useExclusionFlags=true | excluded_by_flags=%d | candidates=%d | used=%d\n', ...
        n_excluded_by_flags, n_candidates_total, n_after_flags);
else
    fprintf('  useExclusionFlags=false | candidates=%d | used=%d | (flags present but ignored; flagged_in_mat=%d)\n', ...
        n_candidates_total, n_after_flags, n_flagged_mat);
end

%% ────────────────────────── 7) Plot average PSD ──────────────────────────
figure('Color','w'); hold on;

h = plot(psd_all.freq_hz, psd_all.PSD_avg_db, 'LineWidth', 2);
set(h, 'HitTest', 'off', 'PickableParts', 'none');

grid on; box on;
set(gca, 'FontSize', axisFontSize);

xlabel('Frequency (Hz)', 'FontSize', axisFontSize);
ylabel('PSD (dB/Hz)', 'FontSize', axisFontSize);

xlim([fmin_hz, fmax_hz]);

title(sprintf('PSD | window=%s | agg=%s | domain=%s | n=%d | channel=%s | eventtype=%s', ...
    char(epochWindow), char(aggregator), char(aggregateDomain), n_after_flags, char(channelFilter), char(eventtypeFilter)), ...
    'FontSize', figureTitleFontSize, 'Interpreter', 'none');

hold off;

fprintf('\nDone. psd_all has %d rows and %d columns.\n', height(psd_all), width(psd_all));
fprintf('Columns: %s\n', strjoin(psd_all.Properties.VariableNames, ', '));

log_command_window('stop');
