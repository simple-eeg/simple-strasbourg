%% step_7_check_4_plot_average_tf.m
% Purpose
%   Visualise a group-level averaged time–frequency (TF) heatmap for a single
%   channel + eventtype, using screened pooled epochs with an Exclude mask.
%
% Behaviour (high level)
%   1) Load SCREENED pooled epochs (MAT) from data/summary/screening/.
%   2) Assemble a set of single-channel epoch time series across all matching epochs.
%   3) Optionally drop items flagged Exclude (MAT-driven) via useExclusionFlags.
%   4) Enforce strict alignment across contributing datasets:
%        - ERROR if times_ms differ
%        - ERROR if srate differs
%   5) Compute wavelet TF (CWT) for each retained epoch-series:
%        - MATLAB Wavelet Toolbox
%        - Analytic Morlet ("amor")
%        - VoicesPerOctave = user-configurable (default 12)
%        - Compute f in [1, Fs/2] Hz
%        - Quantity: power = |W|^2 (ERSP-style)
%   6) Baseline-relative change (fixed baseline definition: all times_ms < 0):
%        - Per epoch: P(t,f) = |W(t,f)|^2
%        - Per epoch: Pbase(f) = baselineTimeAgg over baseline time points
%        - Per epoch: ratio R(t,f) = P(t,f) ./ max(Pbase(f), eps)
%        - Per epoch: TF_db(t,f) = 10*log10(max(R(t,f), eps))
%   7) Aggregate TF_db across epochs using epochAgg ("mean" or "median").
%   8) Plot a single TF heatmap (time on x, frequency on y), with:
%        - Fixed symmetric colour limits clim_db (default [-4 4])
%        - Vertical reference line at t=0
%        - User-configurable plot limits (NOT clamped; blank space allowed)
%        - Default yAxisScale="linear" uses interpolation to 1 Hz display grid
%
% Inputs (screened; must already exist from Step 6.3 apply-decisions)
%   <baseDir>/data/summary/screening/pooled_screened_eeg_epochs.mat
%     - variable: epochs_pooled (struct array, one element per dataset)
%     - required field on each element: Exclude [nCh x nEp] logical
%
% Outputs (in workspace)
%   - tf_all : struct with fields:
%       tf_all.time_ms
%       tf_all.freq_hz_compute
%       tf_all.TF_avg_db_compute
%       tf_all.freq_hz_display
%       tf_all.TF_avg_db_display
%       tf_all.meta
%   - Figure: one figure showing TF_avg_db_display vs time and frequency

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

% Wavelet Toolbox check (early, friendly)
assert(exist('cwtfilterbank', 'file') == 2, ...
    'Wavelet Toolbox appears unavailable (missing cwtfilterbank).');

%% ────────────────────────── 2) User-config ──────────────────────────
% 2A. Filters: which channel / eventtype?
channelFilter   = "Cz";       % channel label (matched case-insensitively, after trimming whitespace)
eventtypeFilter = "cannula";    % case-sensitive eventtype

% 2B. Exclusion toggle (the only exclusion mechanism)
useExclusionFlags = true;     % if true: drop items flagged Exclude; if false: ignore Exclude entirely

% 2C. Wavelet settings (v1: minimal, with only VoicesPerOctave exposed)
voicesPerOctave = 12;         % common default; higher => denser frequency sampling (more compute)

% 2D. Baseline-relative change settings
baselineTimeAgg = "mean";     % within-epoch baseline statistic over t<0: "mean" or "median"
epochAgg        = "mean";     % across-epoch aggregation of TF_db: "mean" or "median"

% 2E. Display settings
% yAxisScale:
%   "linear" : interpolate TF onto 1 Hz grid for display (visually correct in Hz)
%   "log"    : display computed wavelet frequencies on a logarithmic Hz axis
yAxisScale = "linear";

% Plot limits (NOT clamped; blank space allowed)
tmin_plot_ms = -100;
tmax_plot_ms = 1150;

fmin_plot_hz = 3;
fmax_plot_hz = 30;

% Colour limits (fixed symmetric by default; recommended for comparability)
clim_db = [-4, 4];

% Plot styling
figureTitleFontSize = 12;
axisFontSize        = 15;

%% ────────────────────────── 3) Validate user-config ──────────────────────────
channelFilter   = string(channelFilter);
eventtypeFilter = string(eventtypeFilter);
baselineTimeAgg = string(baselineTimeAgg);
epochAgg        = string(epochAgg);
yAxisScale      = string(yAxisScale);

if ~isscalar(channelFilter) || ismissing(channelFilter) || strlength(strtrim(channelFilter)) == 0
    error('Config error: channelFilter must be one nonblank text scalar.');
end
if ~isscalar(eventtypeFilter) || ismissing(eventtypeFilter) || strlength(strtrim(eventtypeFilter)) == 0
    error('Config error: eventtypeFilter must be one nonblank text scalar.');
end
if ~isscalar(baselineTimeAgg) || ismissing(baselineTimeAgg) || ...
        ~isscalar(epochAgg) || ismissing(epochAgg) || ...
        ~isscalar(yAxisScale) || ismissing(yAxisScale)
    error('Config error: baselineTimeAgg, epochAgg, and yAxisScale must each be one text scalar.');
end

channelFilter   = strtrim(channelFilter);
eventtypeFilter = strtrim(eventtypeFilter);
baselineTimeAgg = lower(strtrim(baselineTimeAgg));
epochAgg        = lower(strtrim(epochAgg));
yAxisScale      = lower(strtrim(yAxisScale));

validAgg = ["mean","median"];
if ~ismember(baselineTimeAgg, validAgg)
    error('Config error: baselineTimeAgg must be "mean" or "median".');
end
if ~ismember(epochAgg, validAgg)
    error('Config error: epochAgg must be "mean" or "median".');
end

validAxis = ["linear","log"];
if ~ismember(yAxisScale, validAxis)
    error('Config error: yAxisScale must be "linear" or "log".');
end

if ~isnumeric(voicesPerOctave) || ~isreal(voicesPerOctave) || ~isscalar(voicesPerOctave) || ...
        ~isfinite(voicesPerOctave) || voicesPerOctave < 1 || voicesPerOctave > 48 || mod(voicesPerOctave,1) ~= 0
    error('Config error: voicesPerOctave must be an integer scalar from 1 through 48.');
end

if ~isnumeric(clim_db) || ~isreal(clim_db) || numel(clim_db) ~= 2 || any(~isfinite(clim_db)) || clim_db(2) <= clim_db(1)
    error('Config error: clim_db must be [min max] with finite values and max>min.');
end

if ~isnumeric(tmin_plot_ms) || ~isreal(tmin_plot_ms) || ~isscalar(tmin_plot_ms) || ...
        ~isnumeric(tmax_plot_ms) || ~isreal(tmax_plot_ms) || ~isscalar(tmax_plot_ms) || ...
        ~isfinite(tmin_plot_ms) || ~isfinite(tmax_plot_ms) || tmax_plot_ms <= tmin_plot_ms
    error('Config error: tmin_plot_ms and tmax_plot_ms must be finite scalars with tmin<tmax.');
end

if ~isnumeric(fmin_plot_hz) || ~isreal(fmin_plot_hz) || ~isscalar(fmin_plot_hz) || ...
        ~isnumeric(fmax_plot_hz) || ~isreal(fmax_plot_hz) || ~isscalar(fmax_plot_hz) || ...
        ~isfinite(fmin_plot_hz) || ~isfinite(fmax_plot_hz) || fmax_plot_hz <= fmin_plot_hz
    error('Config error: fmin_plot_hz and fmax_plot_hz must be finite scalars with fmin<fmax.');
end

if yAxisScale == "log" && fmin_plot_hz <= 0
    error('Config error: fmin_plot_hz must be positive when yAxisScale="log".');
end

if ~islogical(useExclusionFlags) || ~isscalar(useExclusionFlags)
    error('Config error: useExclusionFlags must be a logical scalar.');
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
ts              = [];            % [n_points x n_series]
times_ms        = [];            % [n_points x 1]
srate           = NaN;           % scalar
series_mat_excl = false(0,1);    % per-series Exclude flag from MAT

% Metadata for reporting only
series_subj = strings(0,1);
series_sess = strings(0,1);
series_run  = strings(0,1);
series_epix = [];

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
            ~isfinite(ep.srate) || ep.srate <= 2
        error('Dataset %d: srate must be one finite real value greater than 2 Hz.', i);
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

    % Enforce identical time base and sampling rate across all CONTRIBUTING datasets
    if isempty(times_ms)
        times_ms = thisTimes;
        srate    = double(ep.srate);
    else
        if numel(times_ms) ~= numel(thisTimes) || any(times_ms ~= thisTimes)
            error('Time vector mismatch: dataset %d differs from the first dataset (TF requires consistent time base).', i);
        end
        if double(ep.srate) ~= srate
            error('Sampling rate mismatch: dataset %d has srate=%.6f but expected %.6f (TF requires consistent Fs).', ...
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

        series_mat_excl(end+1,1) = logical(ep.Exclude(chIdx, eidx)); %#ok<SAGROW>

        series_subj(end+1,1) = subj;              %#ok<SAGROW>
        series_sess(end+1,1) = sess;              %#ok<SAGROW>
        series_run(end+1,1)  = run;               %#ok<SAGROW>
        series_epix(end+1,1) = epIndex(eidx);     %#ok<SAGROW>
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
if n_points < 4
    error('TF computation requires at least four time samples per selected series.');
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
    ts              = ts(:, keepMask);
    series_mat_excl = series_mat_excl(keepMask); %#ok<NASGU>
    series_subj     = series_subj(keepMask);
    series_sess     = series_sess(keepMask);
    series_run      = series_run(keepMask);
    series_epix     = series_epix(keepMask);
    n_excluded_by_flags = n_flagged_mat;
else
    n_excluded_by_flags = 0;
end

n_after_flags = size(ts, 2);

if n_after_flags == 0
    error('All candidate series were excluded by Exclude flags. Nothing left to compute TF.');
end

%% ────────────────────────── 5) Define baseline and TF compute bounds ──────────────────────────
t_ms = double(times_ms(:));
baselineMask = (t_ms < 0);

nBaseline = sum(baselineMask);
if nBaseline == 0
    error('Baseline definition times_ms < 0 yields zero samples. Cannot compute baseline-relative TF.');
end

Fs = double(srate);
fmin_compute_hz = 1;
fmax_compute_hz = Fs / 2;

%% ────────────────────────── 6) Create Morlet CWT filter bank ──────────────────────────
fb = cwtfilterbank( ...
    'SignalLength',      n_points, ...
    'SamplingFrequency', Fs, ...
    'Wavelet',           'amor', ...
    'VoicesPerOctave',   voicesPerOctave, ...
    'FrequencyLimits',   [fmin_compute_hz, fmax_compute_hz], ...
    'Boundary',          'reflection');

%% ────────────────────────── 7) Compute per-epoch TF (power), baseline-relative dB, then aggregate ──────────────────────────
TF_avg_db_compute = [];
freq_hz_compute   = [];

switch epochAgg
    case "mean"
        runningSum = [];
        for j = 1:n_after_flags
            y = double(ts(:, j));

            [wt, f] = cwt(y, 'FilterBank', fb);  % wt: [nF x nTime], f: [nF x 1]
            if ~isnumeric(f) || ~isreal(f) || any(~isfinite(f(:))) || any(f(:) <= 0) || ...
                    ~(all(diff(double(f(:))) > 0) || all(diff(double(f(:))) < 0))
                error('CWT returned an invalid frequency grid. Expected finite, positive, strictly monotonic Hz values.');
            end
            if size(wt, 1) ~= numel(f) || size(wt, 2) ~= n_points || ...
                    any(~isfinite(real(wt(:)))) || any(~isfinite(imag(wt(:))))
                error('CWT returned invalid coefficients or dimensions for series %d.', j);
            end
            if isempty(freq_hz_compute)
                freq_hz_compute = double(f(:));
                runningSum = zeros(numel(freq_hz_compute), n_points, 'double');
            else
                if numel(f) ~= numel(freq_hz_compute) || any(abs(double(f(:)) - freq_hz_compute) > 1e-12 * max(1, max(abs(freq_hz_compute))))
                    error('CWT frequency grid mismatch across epochs. This should not happen with a fixed filter bank.');
                end
            end

            P = abs(wt).^2;  % power

            % Baseline power per frequency
            switch baselineTimeAgg
                case "mean"
                    Pbase = mean(P(:, baselineMask), 2, 'omitnan');
                case "median"
                    Pbase = median(P(:, baselineMask), 2, 'omitnan');
                otherwise
                    error('Internal error: unexpected baselineTimeAgg: %s', baselineTimeAgg);
            end
            Pbase = max(double(Pbase), eps);

            % Ratio and dB
            R = double(P) ./ Pbase;        % implicit expansion across time
            R = max(R, eps);
            TF_db = 10 * log10(R);

            runningSum = runningSum + TF_db;
        end

        TF_avg_db_compute = runningSum ./ max(1, n_after_flags);

    case "median"
        TF_stack = [];
        for j = 1:n_after_flags
            y = double(ts(:, j));

            [wt, f] = cwt(y, 'FilterBank', fb);
            if ~isnumeric(f) || ~isreal(f) || any(~isfinite(f(:))) || any(f(:) <= 0) || ...
                    ~(all(diff(double(f(:))) > 0) || all(diff(double(f(:))) < 0))
                error('CWT returned an invalid frequency grid. Expected finite, positive, strictly monotonic Hz values.');
            end
            if size(wt, 1) ~= numel(f) || size(wt, 2) ~= n_points || ...
                    any(~isfinite(real(wt(:)))) || any(~isfinite(imag(wt(:))))
                error('CWT returned invalid coefficients or dimensions for series %d.', j);
            end
            if isempty(freq_hz_compute)
                freq_hz_compute = double(f(:));
                TF_stack = zeros(numel(freq_hz_compute), n_points, n_after_flags, 'single');
            else
                if numel(f) ~= numel(freq_hz_compute) || any(abs(double(f(:)) - freq_hz_compute) > 1e-12 * max(1, max(abs(freq_hz_compute))))
                    error('CWT frequency grid mismatch across epochs. This should not happen with a fixed filter bank.');
                end
            end

            P = abs(wt).^2;

            switch baselineTimeAgg
                case "mean"
                    Pbase = mean(P(:, baselineMask), 2, 'omitnan');
                case "median"
                    Pbase = median(P(:, baselineMask), 2, 'omitnan');
                otherwise
                    error('Internal error: unexpected baselineTimeAgg: %s', baselineTimeAgg);
            end
            Pbase = max(double(Pbase), eps);

            R = double(P) ./ Pbase;
            R = max(R, eps);
            TF_db = 10 * log10(R);

            TF_stack(:, :, j) = single(TF_db);
        end

        TF_avg_db_compute = median(TF_stack, 3, 'omitnan');  % single is fine for display
        TF_avg_db_compute = double(TF_avg_db_compute);

    otherwise
        error('Internal error: unexpected epochAgg: %s', epochAgg);
end

if ~isreal(TF_avg_db_compute) || any(~isfinite(TF_avg_db_compute(:))) || ...
        ~isequal(size(TF_avg_db_compute), [numel(freq_hz_compute), n_points])
    error('Computed TF result is nonfinite or has unexpected dimensions.');
end

%% ────────────────────────── 8) Build display matrix (optional interpolation for linear y) ──────────────────────────
time_ms = t_ms;

switch yAxisScale
    case "log"
        freq_hz_display   = freq_hz_compute;
        TF_avg_db_display = TF_avg_db_compute;

    case "linear"
        f_display = (ceil(fmin_compute_hz):1:floor(fmax_compute_hz)).';  % 1 Hz grid for display
        if isempty(f_display)
            error('Internal error: empty 1 Hz display grid. Check Fs and compute bounds.');
        end

        % Interpolate along frequency for each time sample (matrix-form interpolation)
        TF_avg_db_display = interp1(freq_hz_compute, TF_avg_db_compute, f_display, 'pchip', NaN);
        freq_hz_display   = f_display;

    otherwise
        error('Internal error: unexpected yAxisScale: %s', yAxisScale);
end


if ~isreal(TF_avg_db_display) || any(isinf(TF_avg_db_display(:))) || ...
        ~isequal(size(TF_avg_db_display), [numel(freq_hz_display), n_points])
    error('Display TF result has infinite values or unexpected dimensions.');
end
displayRowsWithinComputeSupport = freq_hz_display >= min(freq_hz_compute) & ...
    freq_hz_display <= max(freq_hz_compute);
if ~any(displayRowsWithinComputeSupport) || ...
        any(~isfinite(TF_avg_db_display(displayRowsWithinComputeSupport, :)), 'all')
    error('Display TF result is nonfinite within the computed frequency support.');
end

%% ────────────────────────── 9) Assemble tf_all output struct ──────────────────────────
tf_all = struct();
tf_all.time_ms           = time_ms(:);
tf_all.freq_hz_compute   = freq_hz_compute(:);
tf_all.TF_avg_db_compute = TF_avg_db_compute;

tf_all.freq_hz_display   = freq_hz_display(:);
tf_all.TF_avg_db_display = TF_avg_db_display;

meta = struct();
meta.channelFilter      = char(channelFilter);
meta.eventtypeFilter    = char(eventtypeFilter);
meta.useExclusionFlags  = logical(useExclusionFlags);

meta.Fs_hz              = Fs;
meta.n_time_samples     = n_points;
meta.n_baseline_samples = nBaseline;

meta.n_candidates_total  = n_candidates_total;
meta.n_flagged_mat       = n_flagged_mat;
meta.n_excluded_by_flags = n_excluded_by_flags;
meta.n_used              = n_after_flags;

meta.baseline_definition = 'times_ms < 0';
meta.baselineTimeAgg     = char(baselineTimeAgg);
meta.epochAgg            = char(epochAgg);

meta.wavelet             = 'amor (analytic Morlet)';
meta.voicesPerOctave     = voicesPerOctave;
meta.fmin_compute_hz     = fmin_compute_hz;
meta.fmax_compute_hz     = fmax_compute_hz;
meta.boundary             = char(fb.Boundary);
meta.coneOfInfluenceMaskApplied = false;

meta.yAxisScale          = char(yAxisScale);
if yAxisScale == "linear"
    meta.displayFrequencyCoordinates = 'interpolated 1-Hz linear frequency coordinates';
else
    meta.displayFrequencyCoordinates = 'native CWT frequency coordinates on logarithmic Hz axis';
end

meta.tmin_plot_ms        = tmin_plot_ms;
meta.tmax_plot_ms        = tmax_plot_ms;
meta.fmin_plot_hz        = fmin_plot_hz;
meta.fmax_plot_hz        = fmax_plot_hz;
meta.clim_db             = clim_db;

tf_all.meta = meta;

%% ────────────────────────── 10) Concise Command Window reporting (always) ──────────────────────────
fprintf('\nSummary:\n');
fprintf('  channel=%s | eventtype=%s\n', tf_all.meta.channelFilter, tf_all.meta.eventtypeFilter);
fprintf('  Fs=%.3f Hz | nTime=%d | baseline=t<0 (nBaseline=%d)\n', Fs, n_points, nBaseline);
fprintf('  wavelet=%s | voicesPerOctave=%d | fCompute=[%.3f, %.3f] Hz | nF_compute=%d\n', ...
    tf_all.meta.wavelet, voicesPerOctave, fmin_compute_hz, fmax_compute_hz, numel(freq_hz_compute));
fprintf('  boundary=%s | coneOfInfluenceMaskApplied=%s\n', ...
    tf_all.meta.boundary, mat2str(tf_all.meta.coneOfInfluenceMaskApplied));
fprintf('  baselineTimeAgg=%s | epochAgg=%s\n', tf_all.meta.baselineTimeAgg, tf_all.meta.epochAgg);
fprintf('  yAxisScale=%s | displayFrequencyCoordinates=%s | nF_display=%d\n', ...
    tf_all.meta.yAxisScale, tf_all.meta.displayFrequencyCoordinates, numel(freq_hz_display));
fprintf('  plotLimits: t=[%g %g] ms | f=[%g %g] Hz | clim_db=[%g %g]\n', ...
    tmin_plot_ms, tmax_plot_ms, fmin_plot_hz, fmax_plot_hz, clim_db(1), clim_db(2));

if useExclusionFlags
    fprintf('  useExclusionFlags=true | excluded_by_flags=%d | candidates=%d | used=%d\n', ...
        n_excluded_by_flags, n_candidates_total, n_after_flags);
else
    fprintf('  useExclusionFlags=false | candidates=%d | used=%d | (flags present but ignored; flagged_in_mat=%d)\n', ...
        n_candidates_total, n_after_flags, n_flagged_mat);
end

%% ────────────────────────── 11) Plot average TF heatmap ──────────────────────────
figure('Color','w');

% Heatmap: rows = frequency, columns = time
switch yAxisScale
    case "linear"
        imagesc(tf_all.time_ms, tf_all.freq_hz_display, tf_all.TF_avg_db_display);
        set(gca, 'YDir', 'normal', 'YScale', 'linear', 'FontSize', axisFontSize);
    case "log"
        surface(tf_all.time_ms(:).', tf_all.freq_hz_display, ...
            zeros(size(tf_all.TF_avg_db_display)), tf_all.TF_avg_db_display, ...
            'EdgeColor', 'none', 'FaceColor', 'texturemap');
        view(2);
        set(gca, 'YDir', 'normal', 'YScale', 'log', 'FontSize', axisFontSize);
    otherwise
        error('Internal error: unexpected yAxisScale: %s', yAxisScale);
end

grid on; box on;

xlabel('Time (ms)', 'FontSize', axisFontSize);
ylabel('Frequency (Hz)', 'FontSize', axisFontSize);

% Honour requested plot limits (no clamping; blank space is acceptable)
xlim([tmin_plot_ms, tmax_plot_ms]);
ylim([fmin_plot_hz, fmax_plot_hz]);

% Fixed symmetric colour limits
caxis(clim_db);

cb = colorbar;
ylabel(cb, 'dB (vs baseline)', 'FontSize', axisFontSize);

% Colormap choice (easy to find/change)
% colormap(parula);   % uncomment to force a consistent default
% colormap(turbo);    % example alternative (MATLAB built-in, newer releases)

% Reference line at t=0 (draw after axis limits to keep it visible)
hold on;
xline(0, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1, 'HandleVisibility', 'off');
hold off;

title(sprintf('TF (Morlet) | baseline t<0 | baseAgg=%s | epochAgg=%s | n=%d | channel=%s | eventtype=%s', ...
    char(baselineTimeAgg), char(epochAgg), n_after_flags, char(channelFilter), char(eventtypeFilter)), ...
    'FontSize', figureTitleFontSize, 'Interpreter', 'none');

fprintf('\nDone. tf_all contains compute and display TF matrices plus metadata.\n');

log_command_window('stop');
