function [result, handles] = plot_guardrail_average_psd(ax, eventSeries, settings)
%PLOT_GUARDRAIL_AVERAGE_PSD Draw the active Step 7 multitaper-PSD route.
%   This helper creates no figure, title, log, or file. It implements only
%   the accepted post-stimulus, arithmetic-mean, linear-power route.

if ~isgraphics(ax, 'axes')
    error('plot_guardrail_average_psd:InvalidAxes', ...
        'ax must be a valid axes handle.');
end
validate_event_series(eventSeries);
requiredSettings = {'epoch_window','aggregator','aggregate_domain', ...
    'frequency_limits_hz','axis_font_size','line_width', ...
    'time_bandwidth_product','nfft'};
if ~isstruct(settings) || ~isscalar(settings) || ...
        ~all(isfield(settings, requiredSettings))
    error('plot_guardrail_average_psd:InvalidSettings', ...
        'settings is missing one or more required fields.');
end

epochWindow = lower(text_scalar(settings.epoch_window, ...
    'settings.epoch_window'));
aggregator = lower(text_scalar(settings.aggregator, 'settings.aggregator'));
aggregateDomain = lower(text_scalar(settings.aggregate_domain, ...
    'settings.aggregate_domain'));
if epochWindow ~= "post-stim" || aggregator ~= "mean" || ...
        aggregateDomain ~= "linear_power"
    error('plot_guardrail_average_psd:InactiveRoute', ...
        ['The guardrail figure supports only epoch_window="post-stim", ', ...
        'aggregator="mean", and aggregate_domain="linear_power".']);
end
frequencyLimits = numeric_pair(settings.frequency_limits_hz, ...
    'settings.frequency_limits_hz');
axisFontSize = positive_scalar(settings.axis_font_size, ...
    'settings.axis_font_size');
lineWidth = positive_scalar(settings.line_width, 'settings.line_width');
timeBandwidthProduct = positive_scalar(settings.time_bandwidth_product, ...
    'settings.time_bandwidth_product');
if timeBandwidthProduct < 1.25
    error('plot_guardrail_average_psd:InvalidBandwidth', ...
        'time_bandwidth_product must be at least 1.25.');
end
nfft = integer_scalar(settings.nfft, 'settings.nfft');
if nfft < 2
    error('plot_guardrail_average_psd:InvalidNFFT', ...
        'nfft must be an integer of at least 2.');
end
if exist('pmtm', 'file') ~= 2
    error('plot_guardrail_average_psd:MissingSignalToolbox', ...
        'The active PSD route requires pmtm.');
end

timeMs = double(eventSeries.times_ms(:));
windowMask = timeMs >= 0;
nWindowSamples = sum(windowMask);
if nWindowSamples == 0
    error('plot_guardrail_average_psd:EmptyWindow', ...
        'The fixed post-stimulus window times_ms >= 0 contains no samples.');
end
if timeBandwidthProduct >= nWindowSamples / 2
    error('plot_guardrail_average_psd:WindowTooShort', ...
        ['The time-bandwidth product %.12g must be less than half ', ...
        'the %d-sample post-stimulus window.'], ...
        timeBandwidthProduct, nWindowSamples);
end
windowedData = eventSeries.data(windowMask, :);
samplingRate = double(eventSeries.srate);
nSeries = size(windowedData, 2);

powerMatrix = [];
frequencyReference = [];
for seriesIdx = 1:nSeries
    [power, frequency] = pmtm(double(windowedData(:, seriesIdx)), ...
        timeBandwidthProduct, nfft, samplingRate, 'onesided');
    if ~isnumeric(power) || ~isreal(power) || any(~isfinite(power(:))) || ...
            any(power(:) < 0)
        error('plot_guardrail_average_psd:InvalidPower', ...
            'pmtm returned invalid PSD values for series %d.', seriesIdx);
    end
    frequency = double(frequency(:));
    if isempty(frequency) || any(~isfinite(frequency)) || any(frequency < 0) || ...
            any(frequency > samplingRate / 2 + max(eps(samplingRate), 1e-12)) || ...
            any(diff(frequency) <= 0) || numel(power) ~= numel(frequency)
        error('plot_guardrail_average_psd:InvalidFrequencyGrid', ...
            'pmtm returned an invalid one-sided frequency grid for series %d.', ...
            seriesIdx);
    end
    power = max(power, eps);
    if isempty(frequencyReference)
        frequencyReference = frequency;
        powerMatrix = zeros(numel(frequencyReference), nSeries);
    elseif numel(frequency) ~= numel(frequencyReference) || ...
            any(frequency ~= frequencyReference)
        error('plot_guardrail_average_psd:FrequencyGridMismatch', ...
            'pmtm frequency grids differ across admitted series.');
    end
    powerMatrix(:, seriesIdx) = double(power(:));
end
if isempty(powerMatrix) || ~isreal(powerMatrix) || ...
        any(~isfinite(powerMatrix(:)))
    error('plot_guardrail_average_psd:InvalidPowerMatrix', ...
        'Computed per-series PSD values are empty or nonfinite.');
end

averageLinearPower = mean(powerMatrix, 2, 'omitnan');
averageLinearPower = max(averageLinearPower, eps);
averageDb = 10 * log10(averageLinearPower);
if ~isreal(averageDb) || any(~isfinite(averageDb)) || ...
        numel(averageDb) ~= numel(frequencyReference)
    error('plot_guardrail_average_psd:InvalidAverage', ...
        'Aggregated PSD is nonfinite or has unexpected dimensions.');
end
psdAll = table(frequencyReference, averageDb, ...
    'VariableNames', {'freq_hz','PSD_avg_db'});

meta = struct();
meta.channelFilter = char(eventSeries.channel);
meta.eventtypeFilter = char(eventSeries.eventtype);
meta.useExclusionFlags = eventSeries.use_exclusion_flags;
meta.epochWindow = char(epochWindow);
meta.Fs_hz = samplingRate;
meta.n_window_samples = nWindowSamples;
meta.n_candidates_total = eventSeries.n_candidates;
meta.n_flagged_mat = eventSeries.n_flagged;
meta.n_excluded_by_flags = eventSeries.n_excluded;
meta.n_used = eventSeries.n_admitted;
meta.timeBandwidthProduct = timeBandwidthProduct;
meta.nfft = nfft;
meta.spectrum = 'one-sided';
meta.aggregator = char(aggregator);
meta.aggregateDomain = char(aggregateDomain);
meta.fmin_plot_hz = frequencyLimits(1);
meta.fmax_plot_hz = frequencyLimits(2);

result = struct('psd_all', psdAll, 'meta', meta);

cla(ax);
handles = struct();
handles.axes = ax;
handles.curve = plot(ax, psdAll.freq_hz, psdAll.PSD_avg_db, ...
    'LineWidth', lineWidth, 'Tag', 'guardrail-psd-curve');
set(handles.curve, 'HitTest', 'off', 'PickableParts', 'none');
grid(ax, 'on');
box(ax, 'on');
set(ax, 'FontSize', axisFontSize);
xlabel(ax, 'Frequency (Hz)', 'FontSize', axisFontSize);
ylabel(ax, 'PSD (dB/Hz)', 'FontSize', axisFontSize);
xlim(ax, frequencyLimits);
title(ax, '');
end

function validate_event_series(value)
required = {'eventtype','channel','data','times_ms','srate','identities', ...
    'n_candidates','n_flagged','n_excluded','n_admitted', ...
    'use_exclusion_flags'};
if ~isstruct(value) || ~isscalar(value) || ~all(isfield(value, required))
    error('plot_guardrail_average_psd:InvalidEventSeries', ...
        'eventSeries is missing one or more required fields.');
end
if ~isnumeric(value.data) || ~isreal(value.data) || ~ismatrix(value.data) || ...
        isempty(value.data) || any(~isfinite(value.data(:))) || ...
        size(value.data, 2) ~= value.n_admitted
    error('plot_guardrail_average_psd:InvalidEventSeries', ...
        'eventSeries.data must be a finite real matrix matching n_admitted.');
end
if ~isnumeric(value.times_ms) || ~isreal(value.times_ms) || ...
        ~isvector(value.times_ms) || numel(value.times_ms) ~= size(value.data,1) || ...
        any(~isfinite(value.times_ms)) || any(diff(value.times_ms(:)) <= 0)
    error('plot_guardrail_average_psd:InvalidEventSeries', ...
        'eventSeries.times_ms is invalid or does not match data.');
end
if ~isnumeric(value.srate) || ~isreal(value.srate) || ...
        ~isscalar(value.srate) || ~isfinite(value.srate) || value.srate <= 0 || ...
        ~istable(value.identities) || height(value.identities) ~= value.n_admitted || ...
        ~islogical(value.use_exclusion_flags) || ~isscalar(value.use_exclusion_flags)
    error('plot_guardrail_average_psd:InvalidEventSeries', ...
        'eventSeries metadata are invalid or internally inconsistent.');
end
text_scalar(value.channel, 'eventSeries.channel');
text_scalar(value.eventtype, 'eventSeries.eventtype');
end

function value = text_scalar(value, label)
value = string(value);
if ~isscalar(value) || ismissing(value) || strlength(strtrim(value)) == 0
    error('plot_guardrail_average_psd:InvalidText', ...
        '%s must be one nonblank text value.', label);
end
value = strtrim(value);
end

function value = positive_scalar(value, label)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
        ~isfinite(value) || value <= 0
    error('plot_guardrail_average_psd:InvalidNumeric', ...
        '%s must be one positive finite value.', label);
end
value = double(value);
end

function value = integer_scalar(value, label)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
        ~isfinite(value) || mod(value, 1) ~= 0
    error('plot_guardrail_average_psd:InvalidInteger', ...
        '%s must be one finite integer.', label);
end
value = double(value);
end

function value = numeric_pair(value, label)
if ~isnumeric(value) || ~isreal(value) || numel(value) ~= 2 || ...
        any(~isfinite(value)) || value(2) <= value(1)
    error('plot_guardrail_average_psd:InvalidPair', ...
        '%s must be an ordered finite numeric pair.', label);
end
value = reshape(double(value), 1, 2);
end
