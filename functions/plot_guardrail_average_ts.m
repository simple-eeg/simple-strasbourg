function [result, handles] = plot_guardrail_average_ts(ax, eventSeries, settings)
%PLOT_GUARDRAIL_AVERAGE_TS Draw the active Step 7 mean-TS route on one axes.
%   The caller supplies an axes, one collected event-series struct, and a
%   settings struct. This helper creates no figure, title, log, or file.
%
%   settings.overlays is a variable-length struct array with fields:
%     name, template_file, fit_time_ms, jitter_ms, colour, display_label.

if ~isgraphics(ax, 'axes')
    error('plot_guardrail_average_ts:InvalidAxes', ...
        'ax must be a valid axes handle.');
end
validate_event_series(eventSeries);
requiredSettings = {'aggregator','smoothing_ms','overlays','x_limits_ms', ...
    'y_limits_uV','time_zero_colour','axis_font_size','line_width', ...
    'legend_location'};
validate_settings_struct(settings, requiredSettings);

aggregator = lower(text_scalar(settings.aggregator, 'settings.aggregator'));
if aggregator ~= "mean"
    error('plot_guardrail_average_ts:InactiveRoute', ...
        'The guardrail figure supports only the active arithmetic-mean route.');
end
if ~isnumeric(settings.smoothing_ms) || ~isreal(settings.smoothing_ms) || ...
        ~isscalar(settings.smoothing_ms) || ~isfinite(settings.smoothing_ms) || ...
        settings.smoothing_ms ~= 0
    error('plot_guardrail_average_ts:InactiveRoute', ...
        'The guardrail figure supports only the active zero-smoothing route.');
end
xLimits = numeric_pair(settings.x_limits_ms, 'settings.x_limits_ms');
yLimits = numeric_pair(settings.y_limits_uV, 'settings.y_limits_uV');
timeZeroColour = colour_triplet(settings.time_zero_colour, ...
    'settings.time_zero_colour');
axisFontSize = positive_scalar(settings.axis_font_size, ...
    'settings.axis_font_size');
lineWidth = positive_scalar(settings.line_width, 'settings.line_width');
legendLocation = text_scalar(settings.legend_location, ...
    'settings.legend_location');

overlays = settings.overlays;
requiredOverlayFields = {'name','template_file','fit_time_ms','jitter_ms', ...
    'colour','display_label'};
if isempty(overlays)
    overlays = struct('name', {}, 'template_file', {}, 'fit_time_ms', {}, ...
        'jitter_ms', {}, 'colour', {}, 'display_label', {});
elseif ~isstruct(overlays) || ~all(isfield(overlays, requiredOverlayFields))
    error('plot_guardrail_average_ts:InvalidOverlays', ...
        'settings.overlays is missing one or more required fields.');
end

nOverlays = numel(overlays);
overlayNames = strings(nOverlays, 1);
templateFiles = strings(nOverlays, 1);
overlayLabels = strings(nOverlays, 1);
overlayColours = zeros(nOverlays, 3);
fitTimes = zeros(nOverlays, 1);
jitterValues = zeros(nOverlays, 1);
for overlayIdx = 1:nOverlays
    overlayNames(overlayIdx) = text_scalar(overlays(overlayIdx).name, ...
        sprintf('settings.overlays(%d).name', overlayIdx));
    if ~isvarname(char(overlayNames(overlayIdx)))
        error('plot_guardrail_average_ts:InvalidOverlayName', ...
            'Overlay name %s is not a valid MATLAB variable name.', ...
            overlayNames(overlayIdx));
    end
    templateFiles(overlayIdx) = text_scalar(overlays(overlayIdx).template_file, ...
        sprintf('settings.overlays(%d).template_file', overlayIdx));
    if ~isfile(templateFiles(overlayIdx))
        error('plot_guardrail_average_ts:MissingTemplate', ...
            'Overlay template is missing: %s', templateFiles(overlayIdx));
    end
    overlayLabels(overlayIdx) = text_scalar(overlays(overlayIdx).display_label, ...
        sprintf('settings.overlays(%d).display_label', overlayIdx));
    overlayColours(overlayIdx, :) = colour_triplet(overlays(overlayIdx).colour, ...
        sprintf('settings.overlays(%d).colour', overlayIdx));
    fitTimes(overlayIdx) = finite_scalar(overlays(overlayIdx).fit_time_ms, ...
        sprintf('settings.overlays(%d).fit_time_ms', overlayIdx));
    jitterValues(overlayIdx) = finite_scalar(overlays(overlayIdx).jitter_ms, ...
        sprintf('settings.overlays(%d).jitter_ms', overlayIdx));
    if jitterValues(overlayIdx) < 0
        error('plot_guardrail_average_ts:InvalidJitter', ...
            'Overlay jitter must be nonnegative.');
    end
end
if numel(unique(overlayNames, 'stable')) ~= nOverlays
    error('plot_guardrail_average_ts:DuplicateOverlays', ...
        'Overlay names must be unique.');
end

[meanTrace, averageInfo] = ts_average_simple(eventSeries.data, ...
    'Aggregator', aggregator, ...
    'SmoothingWindowMs', settings.smoothing_ms, ...
    'SRate', eventSeries.srate);
averageInfo.approach = 'simple';
averageInfo.channel = char(eventSeries.channel);
averageInfo.eventtype = char(eventSeries.eventtype);
averageInfo.use_exclusion_flags = eventSeries.use_exclusion_flags;
averageInfo.n_candidates = eventSeries.n_candidates;
averageInfo.n_excluded_by_flags = eventSeries.n_excluded;
averageInfo.n_admitted_series = eventSeries.n_admitted;
averageInfo.series_keys_used = eventSeries.identities;

overlayTracePrototype = struct('name', "", 'trace', []);
overlayFitPrototype = struct('name', "", 'fit', struct());
overlayTraces = repmat(overlayTracePrototype, nOverlays, 1);
overlayFits = repmat(overlayFitPrototype, nOverlays, 1);
for overlayIdx = 1:nOverlays
    [trace, fit] = ts_nrf_overlay(meanTrace, templateFiles(overlayIdx), ...
        eventSeries.times_ms, fitTimes(overlayIdx), jitterValues(overlayIdx));
    if string(fit.nrfName) ~= overlayNames(overlayIdx) || ...
            ~canonical_equal(fit.nrfFile, templateFiles(overlayIdx))
        error('plot_guardrail_average_ts:TemplateProvenanceMismatch', ...
            'Overlay provenance does not match configured template %s.', ...
            overlayNames(overlayIdx));
    end
    overlayTraces(overlayIdx).name = overlayNames(overlayIdx);
    overlayTraces(overlayIdx).trace = trace(:);
    overlayFits(overlayIdx).name = overlayNames(overlayIdx);
    overlayFits(overlayIdx).fit = fit;
end

variableNames = {'time_ms','EEG_avg'};
tableVariables = {eventSeries.times_ms(:), meanTrace(:)};
for overlayIdx = 1:nOverlays
    variableNames{end+1} = char(overlayNames(overlayIdx)); %#ok<AGROW>
    tableVariables{end+1} = overlayTraces(overlayIdx).trace; %#ok<AGROW>
end
tsAll = table(tableVariables{:}, 'VariableNames', variableNames);

cla(ax);
hold(ax, 'on');
handles = struct();
handles.axes = ax;
handles.eeg = plot(ax, tsAll.time_ms, tsAll.EEG_avg, ...
    'LineWidth', lineWidth, 'DisplayName', 'EEG data', ...
    'Tag', 'guardrail-ts-eeg');
handles.time_zero = xline(ax, 0, '--', 'Color', timeZeroColour, ...
    'LineWidth', 1, 'HandleVisibility', 'off', ...
    'Tag', 'guardrail-ts-time-zero');
handles.overlays = gobjects(nOverlays, 1);
for overlayIdx = 1:nOverlays
    handles.overlays(overlayIdx) = plot(ax, tsAll.time_ms, ...
        overlayTraces(overlayIdx).trace, 'LineWidth', lineWidth, ...
        'Color', overlayColours(overlayIdx, :), ...
        'DisplayName', char(overlayLabels(overlayIdx)), ...
        'Tag', ['guardrail-ts-overlay-', char(overlayNames(overlayIdx))]);
end

set(ax, 'YDir', 'reverse', 'FontSize', axisFontSize);
grid(ax, 'on');
box(ax, 'on');
xlabel(ax, 'Time (ms)', 'FontSize', axisFontSize);
ylabel(ax, 'Amplitude (\muV)', 'FontSize', axisFontSize);
availableLimits = [min(tsAll.time_ms), max(tsAll.time_ms)];
displayLimits = [max(xLimits(1), availableLimits(1)), ...
    min(xLimits(2), availableLimits(2))];
if displayLimits(2) <= displayLimits(1)
    error('plot_guardrail_average_ts:NoDisplaySupport', ...
        'Requested time limits do not overlap the event time base.');
end
xlim(ax, displayLimits);
ylim(ax, yLimits);
legendHandles = [handles.eeg; handles.overlays(:)];
handles.legend = legend(ax, legendHandles, ...
    ["EEG data"; overlayLabels], 'Location', char(legendLocation), ...
    'Box', 'off', 'FontSize', axisFontSize, 'Interpreter', 'none');
title(ax, '');
hold(ax, 'off');

result = struct();
result.ts_all = tsAll;
result.average_info = averageInfo;
result.overlay_traces = overlayTraces;
result.overlay_fits = overlayFits;
result.meta = struct( ...
    'channel', char(eventSeries.channel), ...
    'eventtype', char(eventSeries.eventtype), ...
    'aggregator', char(aggregator), ...
    'smoothing_ms', double(settings.smoothing_ms), ...
    'x_limits_ms', xLimits, ...
    'y_limits_uV', yLimits, ...
    'n_candidates', eventSeries.n_candidates, ...
    'n_excluded', eventSeries.n_excluded, ...
    'n_admitted', eventSeries.n_admitted);
end

function validate_event_series(value)
required = {'eventtype','channel','data','times_ms','srate','identities', ...
    'n_candidates','n_excluded','n_admitted','use_exclusion_flags'};
if ~isstruct(value) || ~isscalar(value) || ~all(isfield(value, required))
    error('plot_guardrail_average_ts:InvalidEventSeries', ...
        'eventSeries is missing one or more required fields.');
end
if ~isnumeric(value.data) || ~isreal(value.data) || ~ismatrix(value.data) || ...
        isempty(value.data) || any(~isfinite(value.data(:))) || ...
        size(value.data, 2) ~= value.n_admitted
    error('plot_guardrail_average_ts:InvalidEventSeries', ...
        'eventSeries.data must be a finite real matrix matching n_admitted.');
end
if ~isnumeric(value.times_ms) || ~isreal(value.times_ms) || ...
        ~isvector(value.times_ms) || numel(value.times_ms) ~= size(value.data,1) || ...
        any(~isfinite(value.times_ms)) || any(diff(value.times_ms(:)) <= 0)
    error('plot_guardrail_average_ts:InvalidEventSeries', ...
        'eventSeries.times_ms is invalid or does not match data.');
end
if ~isnumeric(value.srate) || ~isreal(value.srate) || ...
        ~isscalar(value.srate) || ~isfinite(value.srate) || value.srate <= 0 || ...
        ~istable(value.identities) || height(value.identities) ~= value.n_admitted || ...
        ~islogical(value.use_exclusion_flags) || ~isscalar(value.use_exclusion_flags)
    error('plot_guardrail_average_ts:InvalidEventSeries', ...
        'eventSeries metadata are invalid or internally inconsistent.');
end
text_scalar(value.channel, 'eventSeries.channel');
text_scalar(value.eventtype, 'eventSeries.eventtype');
end

function validate_settings_struct(value, required)
if ~isstruct(value) || ~isscalar(value) || ~all(isfield(value, required))
    error('plot_guardrail_average_ts:InvalidSettings', ...
        'settings is missing one or more required fields.');
end
end

function value = text_scalar(value, label)
value = string(value);
if ~isscalar(value) || ismissing(value) || strlength(strtrim(value)) == 0
    error('plot_guardrail_average_ts:InvalidText', ...
        '%s must be one nonblank text value.', label);
end
value = strtrim(value);
end

function value = finite_scalar(value, label)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value)
    error('plot_guardrail_average_ts:InvalidNumeric', ...
        '%s must be one finite real numeric value.', label);
end
value = double(value);
end

function value = positive_scalar(value, label)
value = finite_scalar(value, label);
if value <= 0
    error('plot_guardrail_average_ts:InvalidNumeric', ...
        '%s must be positive.', label);
end
end

function value = numeric_pair(value, label)
if ~isnumeric(value) || ~isreal(value) || numel(value) ~= 2 || ...
        any(~isfinite(value)) || value(2) <= value(1)
    error('plot_guardrail_average_ts:InvalidPair', ...
        '%s must be an ordered finite numeric pair.', label);
end
value = reshape(double(value), 1, 2);
end

function value = colour_triplet(value, label)
if ~isnumeric(value) || ~isreal(value) || numel(value) ~= 3 || ...
        any(~isfinite(value)) || any(value < 0) || any(value > 1)
    error('plot_guardrail_average_ts:InvalidColour', ...
        '%s must be an RGB triplet in [0,1].', label);
end
value = reshape(double(value), 1, 3);
end

function tf = canonical_equal(firstPath, secondPath)
firstPath = char(java.io.File(char(string(firstPath))).getCanonicalPath());
secondPath = char(java.io.File(char(string(secondPath))).getCanonicalPath());
tf = strcmp(firstPath, secondPath);
end
