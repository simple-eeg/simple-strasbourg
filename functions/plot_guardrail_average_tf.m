function [result, handles] = plot_guardrail_average_tf(ax, eventSeries, settings)
%PLOT_GUARDRAIL_AVERAGE_TF Draw the active Step 7 Morlet-TF route on one axes.
%   This helper creates no figure, title, log, or file. It implements only
%   the accepted mean-baseline, mean-across-epochs, linear-frequency route.

if ~isgraphics(ax, 'axes')
    error('plot_guardrail_average_tf:InvalidAxes', ...
        'ax must be a valid axes handle.');
end
validate_event_series(eventSeries);
requiredSettings = {'voices_per_octave','baseline_time_agg','epoch_agg', ...
    'y_axis_scale','time_limits_ms','frequency_limits_hz', ...
    'colour_limits_db','time_zero_colour','axis_font_size'};
if ~isstruct(settings) || ~isscalar(settings) || ...
        ~all(isfield(settings, requiredSettings))
    error('plot_guardrail_average_tf:InvalidSettings', ...
        'settings is missing one or more required fields.');
end

voicesPerOctave = integer_scalar(settings.voices_per_octave, ...
    'settings.voices_per_octave');
if voicesPerOctave < 1 || voicesPerOctave > 48
    error('plot_guardrail_average_tf:InvalidVoices', ...
        'voices_per_octave must be an integer from 1 through 48.');
end
baselineTimeAgg = lower(text_scalar(settings.baseline_time_agg, ...
    'settings.baseline_time_agg'));
epochAgg = lower(text_scalar(settings.epoch_agg, 'settings.epoch_agg'));
yAxisScale = lower(text_scalar(settings.y_axis_scale, ...
    'settings.y_axis_scale'));
if baselineTimeAgg ~= "mean" || epochAgg ~= "mean" || yAxisScale ~= "linear"
    error('plot_guardrail_average_tf:InactiveRoute', ...
        ['The guardrail figure supports only baseline_time_agg="mean", ', ...
        'epoch_agg="mean", and y_axis_scale="linear".']);
end
timeLimits = numeric_pair(settings.time_limits_ms, 'settings.time_limits_ms');
frequencyLimits = numeric_pair(settings.frequency_limits_hz, ...
    'settings.frequency_limits_hz');
colourLimits = numeric_pair(settings.colour_limits_db, ...
    'settings.colour_limits_db');
timeZeroColour = colour_triplet(settings.time_zero_colour, ...
    'settings.time_zero_colour');
axisFontSize = positive_scalar(settings.axis_font_size, ...
    'settings.axis_font_size');

if exist('cwtfilterbank', 'file') ~= 2 || exist('cwt', 'file') ~= 2
    error('plot_guardrail_average_tf:MissingWaveletToolbox', ...
        'The active TF route requires cwtfilterbank and cwt.');
end

timeMs = double(eventSeries.times_ms(:));
data = eventSeries.data;
[nPoints, nSeries] = size(data);
if nPoints < 4
    error('plot_guardrail_average_tf:InsufficientSamples', ...
        'TF computation requires at least four time samples.');
end
baselineMask = timeMs < 0;
nBaseline = sum(baselineMask);
if nBaseline == 0
    error('plot_guardrail_average_tf:MissingBaseline', ...
        'The fixed baseline times_ms < 0 contains no samples.');
end
samplingRate = double(eventSeries.srate);
if samplingRate <= 2
    error('plot_guardrail_average_tf:InvalidSrate', ...
        'The TF route requires a sampling rate greater than 2 Hz.');
end
minimumComputeHz = 1;
maximumComputeHz = samplingRate / 2;

filterBank = cwtfilterbank( ...
    'SignalLength', nPoints, ...
    'SamplingFrequency', samplingRate, ...
    'Wavelet', 'amor', ...
    'VoicesPerOctave', voicesPerOctave, ...
    'FrequencyLimits', [minimumComputeHz, maximumComputeHz], ...
    'Boundary', 'reflection');

frequencyCompute = [];
runningSum = [];
for seriesIdx = 1:nSeries
    y = double(data(:, seriesIdx));
    [coefficients, frequency] = cwt(y, 'FilterBank', filterBank);
    frequency = double(frequency(:));
    if isempty(frequency) || any(~isfinite(frequency)) || any(frequency <= 0) || ...
            ~(all(diff(frequency) > 0) || all(diff(frequency) < 0))
        error('plot_guardrail_average_tf:InvalidFrequencyGrid', ...
            'CWT returned an invalid frequency grid for series %d.', seriesIdx);
    end
    if size(coefficients, 1) ~= numel(frequency) || ...
            size(coefficients, 2) ~= nPoints || ...
            any(~isfinite(real(coefficients(:)))) || ...
            any(~isfinite(imag(coefficients(:))))
        error('plot_guardrail_average_tf:InvalidCWT', ...
            'CWT returned invalid coefficients for series %d.', seriesIdx);
    end
    if isempty(frequencyCompute)
        frequencyCompute = frequency;
        runningSum = zeros(numel(frequencyCompute), nPoints, 'double');
    elseif numel(frequency) ~= numel(frequencyCompute) || ...
            any(abs(frequency - frequencyCompute) > ...
            1e-12 * max(1, max(abs(frequencyCompute))))
        error('plot_guardrail_average_tf:FrequencyGridMismatch', ...
            'CWT frequency grids differ across admitted series.');
    end

    power = abs(coefficients).^2;
    baselinePower = mean(power(:, baselineMask), 2, 'omitnan');
    baselinePower = max(double(baselinePower), eps);
    ratio = max(double(power) ./ baselinePower, eps);
    tfDb = 10 * log10(ratio);
    runningSum = runningSum + tfDb;
end
tfAverageCompute = runningSum ./ nSeries;
if ~isreal(tfAverageCompute) || any(~isfinite(tfAverageCompute(:))) || ...
        ~isequal(size(tfAverageCompute), [numel(frequencyCompute), nPoints])
    error('plot_guardrail_average_tf:InvalidAverage', ...
        'Computed TF average is nonfinite or has unexpected dimensions.');
end

frequencyDisplay = (ceil(minimumComputeHz):floor(maximumComputeHz)).';
if isempty(frequencyDisplay)
    error('plot_guardrail_average_tf:EmptyDisplayGrid', ...
        'The fixed 1-Hz display grid is empty.');
end
tfAverageDisplay = interp1(frequencyCompute, tfAverageCompute, ...
    frequencyDisplay, 'pchip', NaN);
if ~isreal(tfAverageDisplay) || any(isinf(tfAverageDisplay(:))) || ...
        ~isequal(size(tfAverageDisplay), [numel(frequencyDisplay), nPoints])
    error('plot_guardrail_average_tf:InvalidDisplay', ...
        'Interpolated TF display data are invalid.');
end
withinSupport = frequencyDisplay >= min(frequencyCompute) & ...
    frequencyDisplay <= max(frequencyCompute);
if ~any(withinSupport) || any(~isfinite(tfAverageDisplay(withinSupport, :)), 'all')
    error('plot_guardrail_average_tf:InvalidDisplay', ...
        'Interpolated TF data are nonfinite within computed support.');
end

meta = struct();
meta.channelFilter = char(eventSeries.channel);
meta.eventtypeFilter = char(eventSeries.eventtype);
meta.useExclusionFlags = eventSeries.use_exclusion_flags;
meta.Fs_hz = samplingRate;
meta.n_time_samples = nPoints;
meta.n_baseline_samples = nBaseline;
meta.n_candidates_total = eventSeries.n_candidates;
meta.n_flagged_mat = eventSeries.n_flagged;
meta.n_excluded_by_flags = eventSeries.n_excluded;
meta.n_used = eventSeries.n_admitted;
meta.baseline_definition = 'times_ms < 0';
meta.baselineTimeAgg = char(baselineTimeAgg);
meta.epochAgg = char(epochAgg);
meta.wavelet = 'amor (analytic Morlet)';
meta.voicesPerOctave = voicesPerOctave;
meta.fmin_compute_hz = minimumComputeHz;
meta.fmax_compute_hz = maximumComputeHz;
meta.boundary = char(filterBank.Boundary);
meta.coneOfInfluenceMaskApplied = false;
meta.yAxisScale = char(yAxisScale);
meta.displayFrequencyCoordinates = ...
    'interpolated 1-Hz linear frequency coordinates';
meta.tmin_plot_ms = timeLimits(1);
meta.tmax_plot_ms = timeLimits(2);
meta.fmin_plot_hz = frequencyLimits(1);
meta.fmax_plot_hz = frequencyLimits(2);
meta.clim_db = colourLimits;

result = struct();
result.time_ms = timeMs;
result.freq_hz_compute = frequencyCompute;
result.TF_avg_db_compute = tfAverageCompute;
result.freq_hz_display = frequencyDisplay;
result.TF_avg_db_display = tfAverageDisplay;
result.meta = meta;

cla(ax);
handles = struct();
handles.axes = ax;
handles.heatmap = imagesc(ax, result.time_ms, result.freq_hz_display, ...
    result.TF_avg_db_display);
handles.heatmap.Tag = 'guardrail-tf-heatmap';
set(ax, 'YDir', 'normal', 'YScale', 'linear', 'FontSize', axisFontSize);
grid(ax, 'on');
box(ax, 'on');
xlabel(ax, 'Time (ms)', 'FontSize', axisFontSize);
ylabel(ax, 'Frequency (Hz)', 'FontSize', axisFontSize);
xlim(ax, timeLimits);
ylim(ax, frequencyLimits);
clim(ax, colourLimits);
colormap(ax, parula(256));
handles.colorbar = colorbar(ax);
handles.colorbar.Tag = 'guardrail-tf-colorbar';
ylabel(handles.colorbar, 'dB (vs baseline)', 'FontSize', axisFontSize);
hold(ax, 'on');
handles.time_zero = xline(ax, 0, '--', 'Color', timeZeroColour, ...
    'LineWidth', 1, 'HandleVisibility', 'off', ...
    'Tag', 'guardrail-tf-time-zero');
hold(ax, 'off');
title(ax, '');
end

function validate_event_series(value)
required = {'eventtype','channel','data','times_ms','srate','identities', ...
    'n_candidates','n_flagged','n_excluded','n_admitted', ...
    'use_exclusion_flags'};
if ~isstruct(value) || ~isscalar(value) || ~all(isfield(value, required))
    error('plot_guardrail_average_tf:InvalidEventSeries', ...
        'eventSeries is missing one or more required fields.');
end
if ~isnumeric(value.data) || ~isreal(value.data) || ~ismatrix(value.data) || ...
        isempty(value.data) || any(~isfinite(value.data(:))) || ...
        size(value.data, 2) ~= value.n_admitted
    error('plot_guardrail_average_tf:InvalidEventSeries', ...
        'eventSeries.data must be a finite real matrix matching n_admitted.');
end
if ~isnumeric(value.times_ms) || ~isreal(value.times_ms) || ...
        ~isvector(value.times_ms) || numel(value.times_ms) ~= size(value.data,1) || ...
        any(~isfinite(value.times_ms)) || any(diff(value.times_ms(:)) <= 0)
    error('plot_guardrail_average_tf:InvalidEventSeries', ...
        'eventSeries.times_ms is invalid or does not match data.');
end
if ~isnumeric(value.srate) || ~isreal(value.srate) || ...
        ~isscalar(value.srate) || ~isfinite(value.srate) || value.srate <= 0 || ...
        ~istable(value.identities) || height(value.identities) ~= value.n_admitted || ...
        ~islogical(value.use_exclusion_flags) || ~isscalar(value.use_exclusion_flags)
    error('plot_guardrail_average_tf:InvalidEventSeries', ...
        'eventSeries metadata are invalid or internally inconsistent.');
end
text_scalar(value.channel, 'eventSeries.channel');
text_scalar(value.eventtype, 'eventSeries.eventtype');
end

function value = text_scalar(value, label)
value = string(value);
if ~isscalar(value) || ismissing(value) || strlength(strtrim(value)) == 0
    error('plot_guardrail_average_tf:InvalidText', ...
        '%s must be one nonblank text value.', label);
end
value = strtrim(value);
end

function value = integer_scalar(value, label)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
        ~isfinite(value) || mod(value, 1) ~= 0
    error('plot_guardrail_average_tf:InvalidInteger', ...
        '%s must be one finite integer.', label);
end
value = double(value);
end

function value = positive_scalar(value, label)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
        ~isfinite(value) || value <= 0
    error('plot_guardrail_average_tf:InvalidNumeric', ...
        '%s must be one positive finite value.', label);
end
value = double(value);
end

function value = numeric_pair(value, label)
if ~isnumeric(value) || ~isreal(value) || numel(value) ~= 2 || ...
        any(~isfinite(value)) || value(2) <= value(1)
    error('plot_guardrail_average_tf:InvalidPair', ...
        '%s must be an ordered finite numeric pair.', label);
end
value = reshape(double(value), 1, 2);
end

function value = colour_triplet(value, label)
if ~isnumeric(value) || ~isreal(value) || numel(value) ~= 3 || ...
        any(~isfinite(value)) || any(value < 0) || any(value > 1)
    error('plot_guardrail_average_tf:InvalidColour', ...
        '%s must be an RGB triplet in [0,1].', label);
end
value = reshape(double(value), 1, 3);
end
