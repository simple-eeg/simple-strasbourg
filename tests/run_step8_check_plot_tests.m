function result = run_step8_check_plot_tests(repoRoot)
%RUN_STEP8_CHECK_PLOT_TESTS Exercise the Step 8.1 descriptive-check figure.
%   Every fixture is temporary and synthetic. No numbered production script
%   is run against repository data and no repository data, result or log is
%   read or changed.

arguments
    repoRoot (1,:) char
end

originalFolder = pwd;
originalPath = path;
originalWarnings = warning;
originalRng = rng;
figuresBefore = findall(groot, 'Type', 'figure');
cleanup = onCleanup(@() restore_test_state( ...
    originalFolder, originalPath, originalWarnings, originalRng, figuresBefore)); %#ok<NASGU>

functionsRoot = fullfile(repoRoot, 'functions');
requiredHelpers = { ...
    'collect_guardrail_event_series', ...
    'plot_guardrail_average_ts', ...
    'plot_guardrail_average_tf', ...
    'plot_guardrail_average_psd', ...
    'load_guardrail_separation_result'};
addpath(functionsRoot, '-begin');
for helperIndex = 1:numel(requiredHelpers)
    clear(requiredHelpers{helperIndex});
end
rehash path;
for helperIndex = 1:numel(requiredHelpers)
    assert_path(which(requiredHelpers{helperIndex}), ...
        fullfile(functionsRoot, [requiredHelpers{helperIndex} '.m']));
end

result = struct();
result.collection_positive = run_collection_positive();
result.collection_failures = run_collection_failures();
result.panel_parity = run_panel_parity(repoRoot);
result.separation_positive = run_separation_positive(repoRoot);
result.separation_failures = run_separation_failures(repoRoot);
result.script_positive = run_script_positive(repoRoot);
result.script_failures = run_script_failures(repoRoot);
result.transaction_rollback = run_transaction_rollback(repoRoot);
result.total = result.collection_positive + result.collection_failures + ...
    result.panel_parity + result.separation_positive + ...
    result.separation_failures + result.script_positive + ...
    result.script_failures + result.transaction_rollback;
fprintf(['STEP 8.1 CHECK-PLOT TESTS PASSED: collection_positive=%d, ' ...
    'collection_failures=%d, panel_parity=%d, separation_positive=%d, ' ...
    'separation_failures=%d, script_positive=%d, script_failures=%d, ' ...
    'transaction_rollback=%d\n'], ...
    result.collection_positive, result.collection_failures, ...
    result.panel_parity, result.separation_positive, ...
    result.separation_failures, result.script_positive, ...
    result.script_failures, result.transaction_rollback);
end

function passed = run_collection_positive()
epochs = make_epoch_fixture();
figuresBefore = findall(groot, 'Type', 'figure');
series = collect_guardrail_event_series(epochs, 'cz', ...
    ["cannula_prestim", "cannula"], true);

assert(numel(series) == 2);
assert(isequal(string({series.eventtype}), ...
    ["cannula_prestim", "cannula"]));
assert(isequal([series.n_candidates], [4 4]));
assert(isequal([series.n_flagged], [0 1]));
assert(isequal([series.n_excluded], [0 1]));
assert(isequal([series.n_admitted], [4 3]));
assert(isequal(size(series(1).data), [701 4]));
assert(isequal(size(series(2).data), [701 3]));
assert(all(strcmpi(string({series.channel}), 'cz')));
assert(isequal(series(1).times_ms, (-200:2:1200).'));
assert(all([series.srate] == 500));
assert(isequal(string(series(2).identities.subjectID), ...
    ["S01"; "S02"; "S03"]));
assert(isequal(find(series(2).candidate_exclude), 4));
assert(same_figure_inventory(figuresBefore, ...
    findall(groot, 'Type', 'figure')), ...
    'The collection helper created or closed a figure.');

withoutExclusions = collect_guardrail_event_series(epochs, 'CZ', ...
    ["cannula_prestim", "cannula"], false);
assert(isequal([withoutExclusions.n_admitted], [4 4]));
assert(isequal([withoutExclusions.n_excluded], [0 0]));
assert(isequal([withoutExclusions.n_flagged], [0 1]));
passed = 1;
end

function passed = run_collection_failures()
baseline = make_epoch_fixture();

missing = rmfield(baseline, 'times_ms');
assert_error_id(@() collect_guardrail_event_series(missing, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:MissingField');

numericExclude = baseline;
numericExclude(1).Exclude = double(numericExclude(1).Exclude);
assert_error_id(@() collect_guardrail_event_series(numericExclude, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:InvalidExclude');

wrongShape = baseline;
wrongShape(1).Exclude = false(2, 2);
assert_error_id(@() collect_guardrail_event_series(wrongShape, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:InvalidExclude');

nonfinite = baseline;
nonfinite(2).data(1, 10, 1) = NaN;
assert_error_id(@() collect_guardrail_event_series(nonfinite, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:NonfiniteData');

timeMismatch = baseline;
timeMismatch(3).times_ms = timeMismatch(3).times_ms + 2;
assert_error_id(@() collect_guardrail_event_series(timeMismatch, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:TimeMismatch');

rateMismatch = baseline;
rateMismatch(2).srate = 250;
assert_error_id(@() collect_guardrail_event_series(rateMismatch, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:IncoherentTimes');

tinyRateMismatch = baseline;
tinyRateMismatch(2).srate = 500 + 1e-10;
assert_error_id(@() collect_guardrail_event_series(tinyRateMismatch, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:SrateMismatch');

duplicate = baseline;
duplicate(2).subjectID = duplicate(1).subjectID;
assert_error_id(@() collect_guardrail_event_series(duplicate, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:DuplicateIdentity');

allExcluded = baseline;
for datasetIndex = 1:numel(allExcluded)
    allExcluded(datasetIndex).Exclude(1, 2) = true;
end
assert_error_id(@() collect_guardrail_event_series(allExcluded, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:NoAdmittedSeries');

missingEvent = baseline;
for datasetIndex = 1:numel(missingEvent)
    missingEvent(datasetIndex).eventtype(2) = "other";
end
assert_error_id(@() collect_guardrail_event_series(missingEvent, 'CZ', ...
    ["cannula_prestim", "cannula"], true), ...
    'collect_guardrail_event_series:NoCandidates');
passed = 1;
end

function passed = run_panel_parity(repoRoot)
epochs = make_epoch_fixture();
series = collect_guardrail_event_series(epochs, 'Cz', ...
    ["cannula_prestim", "cannula"], true);
settings = panel_settings(repoRoot);
[parityRoot, parityCleanup] = make_step7_parity_root(repoRoot, epochs); %#ok<ASGLU>
figuresBefore = findall(groot, 'Type', 'figure');
figureHandle = figure('Visible', 'off');
figureCleanup = onCleanup(@() close_if_graphics(figureHandle)); %#ok<NASGU>
layout = tiledlayout(figureHandle, 3, 2);

for eventIndex = 1:2
    step7 = run_step7_parity_routes(parityRoot, series(eventIndex).eventtype);
    tsAxes = nexttile(layout, eventIndex);
    tfAxes = nexttile(layout, 2 + eventIndex);
    psdAxes = nexttile(layout, 4 + eventIndex);
    [tsResult, tsHandles] = plot_guardrail_average_ts( ...
        tsAxes, series(eventIndex), settings.ts);
    [tfResult, tfHandles] = plot_guardrail_average_tf( ...
        tfAxes, series(eventIndex), settings.tf);
    [psdResult, psdHandles] = plot_guardrail_average_psd( ...
        psdAxes, series(eventIndex), settings.psd);

    [expectedMean, expectedInfo] = ts_average_simple( ...
        series(eventIndex).data, 'Aggregator', 'mean', ...
        'SmoothingWindowMs', 0, 'SRate', series(eventIndex).srate);
    assert(isequaln(tsResult.ts_all.EEG_avg, expectedMean(:)));
    assert(isequaln(tsResult.ts_all, step7.ts_all));
    averageFields = {'aggregator','smoothing_requested_ms', ...
        'smoothing_window_samples','smoothing_window_effective_ms', ...
        'n_contributors_by_time_pre_smoothing', ...
        'common_support_mask_pre_smoothing','approach','channel', ...
        'eventtype','use_exclusion_flags','n_candidates', ...
        'n_excluded_by_flags','n_admitted_series','series_keys_used'};
    for fieldIndex = 1:numel(averageFields)
        fieldName = averageFields{fieldIndex};
        assert(isequaln(tsResult.average_info.(fieldName), ...
            step7.average_info.(fieldName)), ...
            'Step 7 time-series metadata parity failed for %s.', fieldName);
    end
    for overlayIndex = 1:numel(tsResult.overlay_fits)
        overlayName = char(tsResult.overlay_fits(overlayIndex).name);
        assert_overlay_fit_parity(tsResult.overlay_fits(overlayIndex).fit, ...
            step7.overlay_fits.(overlayName), overlayName);
    end
    assert(isequal(tsResult.average_info.aggregator, expectedInfo.aggregator));
    for overlayIndex = 1:numel(settings.ts.overlays)
        overlay = settings.ts.overlays(overlayIndex);
        [expectedTrace, expectedFit] = ts_nrf_overlay(expectedMean, ...
            overlay.template_file, series(eventIndex).times_ms, ...
            overlay.fit_time_ms, overlay.jitter_ms);
        assert(isequaln(tsResult.overlay_traces(overlayIndex).trace, ...
            expectedTrace(:)));
        assert(isequaln(tsResult.overlay_fits(overlayIndex).fit, expectedFit));
    end
    assert(numel(tsHandles.overlays) == 1 && ...
        strcmp(tsAxes.YDir, 'reverse') && isempty(tsAxes.Title.String));
    assert(isequaln(tsHandles.eeg.YData(:), tsResult.ts_all.EEG_avg));
    for overlayIndex = 1:numel(tsHandles.overlays)
        assert(isequaln(tsHandles.overlays(overlayIndex).YData(:), ...
            tsResult.overlay_traces(overlayIndex).trace));
    end
    assert(isequal(xlim(tsAxes), step7.ts_xlim));
    assert(isequal(ylim(tsAxes), step7.ts_ylim));
    assert(strcmp(tsAxes.YDir, step7.ts_ydir));

    expectedTf = direct_tf_oracle(series(eventIndex), settings.tf);
    assert_numeric_close(tfResult.freq_hz_compute, ...
        expectedTf.freq_hz_compute, 1e-12, 'TF compute frequencies');
    assert_numeric_close(tfResult.TF_avg_db_compute, ...
        expectedTf.TF_avg_db_compute, 1e-10, 'TF compute matrix');
    assert_numeric_close(tfResult.TF_avg_db_display, ...
        expectedTf.TF_avg_db_display, 1e-10, 'TF display matrix');
    assert_numeric_close(tfResult.freq_hz_compute, ...
        step7.tf_all.freq_hz_compute, 1e-12, 'Step 7 TF frequencies');
    assert_numeric_close(tfResult.TF_avg_db_compute, ...
        step7.tf_all.TF_avg_db_compute, 1e-10, 'Step 7 TF compute matrix');
    assert_numeric_close(tfResult.TF_avg_db_display, ...
        step7.tf_all.TF_avg_db_display, 1e-10, 'Step 7 TF display matrix');
    assert(isequaln(tfResult.meta, step7.tf_all.meta));
    assert(isequal(clim(tfAxes), [-4 4]));
    assert(isgraphics(tfHandles.colorbar, 'colorbar'));
    assert_numeric_close(tfHandles.heatmap.CData, ...
        tfResult.TF_avg_db_display, 0, 'TF plotted heatmap');
    assert(isequal(colormap(tfAxes), parula(256)));
    assert(isempty(tfAxes.Title.String));
    assert(isequal(xlim(tfAxes), step7.tf_xlim));
    assert(isequal(ylim(tfAxes), step7.tf_ylim));
    assert(isequal(clim(tfAxes), step7.tf_clim));

    expectedPsd = direct_psd_oracle(series(eventIndex), settings.psd);
    assert_numeric_close(psdResult.psd_all.freq_hz, ...
        expectedPsd.freq_hz, 0, 'PSD frequencies');
    assert_numeric_close(psdResult.psd_all.PSD_avg_db, ...
        expectedPsd.PSD_avg_db, 1e-12, 'PSD average');
    assert_numeric_close(psdResult.psd_all.freq_hz, ...
        step7.psd_all.freq_hz, 0, 'Step 7 PSD frequencies');
    assert_numeric_close(psdResult.psd_all.PSD_avg_db, ...
        step7.psd_all.PSD_avg_db, 1e-12, 'Step 7 PSD average');
    assert(isequaln(psdResult.meta, step7.psd_meta));
    assert(isequal(xlim(psdAxes), [-1 251]));
    assert(isgraphics(psdHandles.curve, 'line'));
    assert_numeric_close(psdHandles.curve.YData(:), ...
        psdResult.psd_all.PSD_avg_db, 0, 'PSD plotted curve');
    assert(isempty(psdAxes.Title.String));
    assert(isequal(xlim(psdAxes), step7.psd_xlim));
end

close(figureHandle);
assert(same_figure_inventory(figuresBefore, ...
    findall(groot, 'Type', 'figure')), ...
    'Panel helper fixture did not restore its figure inventory.');
passed = 1;
end

function settings = panel_settings(repoRoot)
[noxiousName, noxiousFile] = NRFUtils.resolveTemplateFile( ...
    'noxious_preterm_NRF_500Hz', repoRoot);
settings.ts = struct();
settings.ts.aggregator = 'mean';
settings.ts.smoothing_ms = 0;
settings.ts.overlays = struct( ...
    'name', noxiousName, 'template_file', noxiousFile, ...
    'fit_time_ms', 0, 'jitter_ms', 100, ...
    'colour', [1 0 0], 'display_label', 'Preterm noxious NRF');
settings.ts.x_limits_ms = [-100 1150];
settings.ts.y_limits_uV = [-20 20];
settings.ts.time_zero_colour = [0.6 0.6 0.6];
settings.ts.axis_font_size = 8;
settings.ts.line_width = 2;
settings.ts.legend_location = 'northeast';

settings.tf = struct( ...
    'voices_per_octave', 12, ...
    'baseline_time_agg', 'mean', ...
    'epoch_agg', 'mean', ...
    'y_axis_scale', 'linear', ...
    'time_limits_ms', [-100 1150], ...
    'frequency_limits_hz', [3 30], ...
    'colour_limits_db', [-4 4], ...
    'time_zero_colour', [0.6 0.6 0.6], ...
    'axis_font_size', 8);
settings.psd = struct( ...
    'epoch_window', 'post-stim', ...
    'aggregator', 'mean', ...
    'aggregate_domain', 'linear_power', ...
    'frequency_limits_hz', [-1 251], ...
    'axis_font_size', 8, ...
    'line_width', 2, ...
    'time_bandwidth_product', 4, ...
    'nfft', 1024);
end

function result = direct_tf_oracle(eventSeries, settings)
timeMs = double(eventSeries.times_ms(:));
baselineMask = timeMs < 0;
filterBank = cwtfilterbank( ...
    'SignalLength', numel(timeMs), ...
    'SamplingFrequency', eventSeries.srate, ...
    'Wavelet', 'amor', ...
    'VoicesPerOctave', settings.voices_per_octave, ...
    'FrequencyLimits', [1 eventSeries.srate / 2], ...
    'Boundary', 'reflection');
runningSum = [];
frequency = [];
for seriesIndex = 1:size(eventSeries.data, 2)
    [coefficients, thisFrequency] = cwt( ...
        double(eventSeries.data(:, seriesIndex)), 'FilterBank', filterBank);
    thisFrequency = double(thisFrequency(:));
    power = abs(coefficients).^2;
    baselinePower = max(mean(power(:, baselineMask), 2, 'omitnan'), eps);
    tfDb = 10 * log10(max(double(power) ./ baselinePower, eps));
    if isempty(runningSum)
        frequency = thisFrequency;
        runningSum = zeros(size(tfDb));
    end
    runningSum = runningSum + tfDb;
end

result.freq_hz_compute = frequency;
result.TF_avg_db_compute = runningSum / size(eventSeries.data, 2);
result.freq_hz_display = (1:floor(eventSeries.srate / 2)).';
result.TF_avg_db_display = interp1(result.freq_hz_compute, ...
    result.TF_avg_db_compute, result.freq_hz_display, 'pchip', NaN);
end

function assert_overlay_fit_parity(actual, expected, label)
assert(strcmp(actual.nrfName, expected.nrfName));
assert(local_file_sha256(actual.nrfFile) == ...
    local_file_sha256(expected.nrfFile), ...
    'Step 7 overlay template bytes differ for %s.', label);
actual = rmfield(actual, 'nrfFile');
expected = rmfield(expected, 'nrfFile');
assert(isequaln(actual, expected), ...
    'Step 7 overlay-fit metadata parity failed for %s.', label);
end

function result = direct_psd_oracle(eventSeries, settings)
mask = eventSeries.times_ms >= 0;
powerMatrix = [];
for seriesIndex = 1:size(eventSeries.data, 2)
    [power, frequency] = pmtm(double(eventSeries.data(mask, seriesIndex)), ...
        settings.time_bandwidth_product, settings.nfft, ...
        eventSeries.srate, 'onesided');
    if isempty(powerMatrix)
        powerMatrix = zeros(numel(power), size(eventSeries.data, 2));
    end
    powerMatrix(:, seriesIndex) = max(double(power(:)), eps);
end
result = table(double(frequency(:)), ...
    10 * log10(max(mean(powerMatrix, 2, 'omitnan'), eps)), ...
    'VariableNames', {'freq_hz','PSD_avg_db'});
end

function epochs = make_epoch_fixture()
times = (-200:2:1200).';
nPoints = numel(times);
prototype = struct( ...
    'data', zeros(1, nPoints, 2), ...
    'times_ms', times, ...
    'channels', "Cz", ...
    'eventtype', ["cannula_prestim"; "cannula"], ...
    'epoch_index', [1; 2], ...
    'srate', 500, ...
    'subjectID', "", ...
    'sessionID', "01", ...
    'runID', "01", ...
    'Exclude', false(1, 2));
epochs = repmat(prototype, 4, 1);
for datasetIndex = 1:4
    tSeconds = times / 1000;
    reference = 2 * sin(2*pi*(5 + datasetIndex/5)*tSeconds) + ...
        0.2 * cos(2*pi*13*tSeconds) + datasetIndex / 10;
    primary = reference + 1.5 * exp(-((times - 420) / 55).^2) - ...
        0.4 * exp(-((times - 110) / 25).^2);
    epochs(datasetIndex).data(1,:,1) = reference;
    epochs(datasetIndex).data(1,:,2) = primary;
    epochs(datasetIndex).subjectID = sprintf('S%02d', datasetIndex);
end
epochs(4).Exclude(1,2) = true;
end

function [root, cleanup] = make_step7_parity_root(repoRoot, epochs)
originalPath = path;
root = tempname;
mkdir(root);
cleanup = onCleanup(@() cleanup_temporary_root(root, originalPath));
mkdir(fullfile(root, 'scripts'));
mkdir(fullfile(root, 'data', 'summary', 'screening'));
copyfile(fullfile(repoRoot, 'functions'), fullfile(root, 'functions'));
copyfile(fullfile(repoRoot, 'NRFs'), fullfile(root, 'NRFs'));
copyfile(fullfile(repoRoot, 'scripts', 'log_command_window.m'), ...
    fullfile(root, 'scripts', 'log_command_window.m'));
scriptNames = { ...
    'step_7_check_3_plot_average_ts.m', ...
    'step_7_check_4_plot_average_tf.m', ...
    'step_7_check_5_plot_average_psd.m'};
for scriptIndex = 1:numel(scriptNames)
    copy_step7_fixture_script( ...
        fullfile(repoRoot, 'scripts', scriptNames{scriptIndex}), ...
        fullfile(root, 'scripts', scriptNames{scriptIndex}), root, 'cannula');
end
epochs_pooled = epochs; %#ok<NASGU>
save(fullfile(root, 'data', 'summary', 'screening', ...
    'pooled_screened_eeg_epochs.mat'), 'epochs_pooled');
addpath(fullfile(root, 'scripts'), '-begin');
addpath(fullfile(root, 'functions'), '-begin');
clear log_command_window NRFUtils ts_average_simple ts_nrf_overlay
rehash path;
end

function result = run_step7_parity_routes(root, eventtype)
scriptNames = { ...
    'step_7_check_3_plot_average_ts.m', ...
    'step_7_check_4_plot_average_tf.m', ...
    'step_7_check_5_plot_average_psd.m'};
for scriptIndex = 1:numel(scriptNames)
    destination = fullfile(root, 'scripts', scriptNames{scriptIndex});
    source = fileread(destination);
    source = regexprep(source, ...
        '(?m)^eventtypeFilter\s*=\s*"[^"]+";', ...
        sprintf('eventtypeFilter = "%s";', char(eventtype)), 'once');
    write_text(destination, source);
end

result = struct();
for scriptIndex = 1:numel(scriptNames)
    scriptPath = fullfile(root, 'scripts', scriptNames{scriptIndex});
    figuresBefore = findall(groot, 'Type', 'figure');
    run_script_in_base(scriptPath);
    figuresAfter = findall(groot, 'Type', 'figure');
    newFigures = figuresAfter(~ismember(figuresAfter, figuresBefore));
    assert(numel(newFigures) == 1, ...
        'A copied Step 7 parity route did not create exactly one figure.');
    figureHandle = newFigures(1);
    figureCleanup = onCleanup(@() close_if_graphics(figureHandle)); %#ok<NASGU>
    axesHandle = findobj(figureHandle, 'Type', 'axes');
    assert(numel(axesHandle) == 1, ...
        'A copied Step 7 parity route has an unexpected axes inventory.');
    switch scriptIndex
        case 1
            result.ts_all = evalin('base', 'ts_all');
            result.average_info = evalin('base', 'averageInfo');
            result.overlay_fits = evalin('base', 'overlayFits');
            result.ts_xlim = xlim(axesHandle);
            result.ts_ylim = ylim(axesHandle);
            result.ts_ydir = axesHandle.YDir;
        case 2
            result.tf_all = evalin('base', 'tf_all');
            result.tf_xlim = xlim(axesHandle);
            result.tf_ylim = ylim(axesHandle);
            result.tf_clim = clim(axesHandle);
        case 3
            result.psd_all = evalin('base', 'psd_all');
            result.psd_xlim = xlim(axesHandle);
            result.psd_meta = struct( ...
                'channelFilter', char(evalin('base', 'channelFilter')), ...
                'eventtypeFilter', char(evalin('base', 'eventtypeFilter')), ...
                'useExclusionFlags', evalin('base', 'useExclusionFlags'), ...
                'epochWindow', char(evalin('base', 'epochWindow')), ...
                'Fs_hz', evalin('base', 'srate'), ...
                'n_window_samples', evalin('base', 'nWin'), ...
                'n_candidates_total', evalin('base', 'n_candidates_total'), ...
                'n_flagged_mat', evalin('base', 'n_flagged_mat'), ...
                'n_excluded_by_flags', evalin('base', 'n_excluded_by_flags'), ...
                'n_used', evalin('base', 'n_after_flags'), ...
                'timeBandwidthProduct', evalin('base', 'timeBandwidthProduct'), ...
                'nfft', evalin('base', 'nfft'), ...
                'spectrum', 'one-sided', ...
                'aggregator', char(evalin('base', 'aggregator')), ...
                'aggregateDomain', char(evalin('base', 'aggregateDomain')), ...
                'fmin_plot_hz', evalin('base', 'fmin_hz'), ...
                'fmax_plot_hz', evalin('base', 'fmax_hz'));
    end
    close(figureHandle);
end
evalin('base', 'clear;');
end

function copy_step7_fixture_script(sourcePath, destinationPath, root, eventtype)
source = fileread(sourcePath);
basePattern = 'baseDir\s*=\s*''[^'']+'';';
assert(numel(regexp(source, basePattern, 'match')) == 1, ...
    'Copied Step 7 route lacks one fixed baseDir assignment.');
source = regexprep(source, basePattern, ...
    sprintf('baseDir = ''%s'';', strrep(root, '''', '''''')), 'once');
source = regexprep(source, ...
    '(?m)^eventtypeFilter\s*=\s*"[^"]+";', ...
    sprintf('eventtypeFilter = "%s";', char(eventtype)), 'once');
write_text(destinationPath, source);
end

function passed = run_separation_positive(repoRoot)
[fixtureRoot, cleanup] = make_separation_fixture_root(repoRoot); %#ok<ASGLU>
sourcePaths = separation_source_paths(fixtureRoot);
[qcPath, qcExpected, qcResult] = write_separation_fixture( ...
    fixtureRoot, 'qc', sourcePaths);
[nrfPath, nrfExpected, nrfResult] = write_separation_fixture( ...
    fixtureRoot, 'nrf', sourcePaths);

bootciStubRoot = fullfile(fixtureRoot, 'bootci_stub');
mkdir(bootciStubRoot);
write_text(fullfile(bootciStubRoot, 'bootci.m'), sprintf([ ...
    'function varargout = bootci(varargin)\n' ...
    'error(''SimpleStrasbourg:Test:BootciCalled'', ''bootci must not run.'');\n' ...
    'end\n']));
addpath(bootciStubRoot, '-begin');
stubCleanup = onCleanup(@() remove_path_if_present(bootciStubRoot)); %#ok<NASGU>
clear bootci
rehash path;
assert_path(which('bootci'), fullfile(bootciStubRoot, 'bootci.m'));

rngBefore = rng;
filesBefore = snapshot_regular_files(fixtureRoot);
figuresBefore = findall(groot, 'Type', 'figure');
loadedQc = load_guardrail_separation_result(qcPath, qcExpected);
loadedNrf = load_guardrail_separation_result(nrfPath, nrfExpected);
assert(isequaln(loadedQc, qcResult));
assert(isequaln(loadedNrf, nrfResult));
assert(isequal(rngBefore, rng), ...
    'The saved-result consumer changed caller RNG state.');
assert(isequal(filesBefore, snapshot_regular_files(fixtureRoot)), ...
    'The saved-result consumer wrote or changed a file.');
assert(same_figure_inventory(figuresBefore, ...
    findall(groot, 'Type', 'figure')), ...
    'The saved-result consumer created or closed a figure.');

figureHandle = figure('Visible', 'off');
figureCleanup = onCleanup(@() close_if_graphics(figureHandle)); %#ok<NASGU>
ax = axes(figureHandle);
plot_paired_effect_result(ax, loadedQc.pairing_table.true_value, ...
    loadedQc.pairing_table.reference_value, loadedQc.estimate, ...
    loadedQc.settings.true_event, loadedQc.settings.reference_event, ...
    loadedQc.settings.effect_specification, loadedQc.settings.alpha);
title(ax, '');
assert(isempty(ax.Title.String));
assert(numel(findobj(ax, 'Tag', 'paired-separation-effect')) == 1);
close(figureHandle);
clear bootci
passed = 1;
end

function passed = run_separation_failures(repoRoot)
[fixtureRoot, cleanup] = make_separation_fixture_root(repoRoot); %#ok<ASGLU>
sourcePaths = separation_source_paths(fixtureRoot);
[baselinePath, expected, baseline] = write_separation_fixture( ...
    fixtureRoot, 'qc', sourcePaths);

badPath = fullfile(fixtureRoot, 'bad.mat');
extra = 1; %#ok<NASGU>
separation_result = baseline; %#ok<NASGU>
save(badPath, 'separation_result', 'extra');
assert_any_error(@() load_guardrail_separation_result(badPath, expected), ...
    'Extra top-level MAT content was accepted.');
save(badPath, 'extra');
assert_any_error(@() load_guardrail_separation_result(badPath, expected), ...
    'Missing top-level separation_result was accepted.');

mutations = cell(16, 1);
mutations{1} = baseline;
mutations{1}.schema = 'unknown-schema';
mutations{2} = baseline;
mutations{2}.pairing_table.PairIndex = [1; 3; 2];
mutations{3} = baseline;
mutations{3}.pairing_table.subjectID(2) = ...
    mutations{3}.pairing_table.subjectID(1);
mutations{4} = baseline;
mutations{4}.pairing_table.true_minus_reference(1) = 99;
mutations{5} = baseline;
mutations{5}.estimate.Estimate(1) = ...
    mutations{5}.estimate.Estimate(1) + 1;
mutations{6} = baseline;
mutations{6}.settings.pairing_key = 'subjectID';
mutations{7} = baseline;
mutations{7}.settings.rng.bootstrap_resamples = 99999;
mutations{8} = baseline;
mutations{8}.counts.pairs_analysed = 2;
mutations{9} = baseline;
mutations{9}.pairing_table.subjectID(1) = "";
mutations{10} = baseline;
mutations{10}.pairing_table.reference_eventtype(1) = "wrong_event";
mutations{11} = baseline;
mutations{11}.pairing_table.channel(1) = "Pz";
mutations{12} = baseline;
mutations{12}.estimate.ConfidenceIntervals(1, :) = [1 -1];
mutations{13} = baseline;
mutations{13}.settings.alpha = 0.01;
mutations{14} = baseline;
mutations{14}.settings.participant_aggregation = 'median';
mutations{15} = baseline;
mutations{15}.settings.estimator = 'meandiff';
mutations{16} = baseline;
mutations{16}.settings.use_exclusion_flags = false;
	for mutationIndex = 1:numel(mutations)
	    separation_result = mutations{mutationIndex}; %#ok<NASGU>
	    save(badPath, 'separation_result');
	    assert_any_error(@() load_guardrail_separation_result(badPath, expected), ...
	        sprintf('Malformed separation fixture %d was accepted.', mutationIndex));
	end

	% Exercise the remaining explicit rejection surfaces in the accepted
	% Step 8.1 plan. These cases use exact identifiers so that an unrelated
	% earlier guard cannot accidentally satisfy the intended contract.
	explicitMutations = cell(14, 1);
	explicitIdentifiers = strings(14, 1);
	explicitLabels = strings(14, 1);
	explicitMutations{1} = baseline;
	explicitMutations{1}.pairing_table = removevars( ...
	    explicitMutations{1}.pairing_table, 'sessionID');
	explicitIdentifiers(1) = "load_guardrail_separation_result:InvalidPairingTable";
	explicitLabels(1) = "missing pairing identity column";
	explicitMutations{2} = baseline;
	explicitMutations{2}.pairing_table.true_value(1) = NaN;
	explicitIdentifiers(2) = "load_guardrail_separation_result:InvalidPairValues";
	explicitLabels(2) = "nonfinite pairing value";
	explicitMutations{3} = baseline;
	explicitMutations{3}.pairing_table = ...
	    explicitMutations{3}.pairing_table([2 1 3], :);
	explicitIdentifiers(3) = "load_guardrail_separation_result:InvalidPairIndex";
	explicitLabels(3) = "reordered pairing identities";
	explicitMutations{4} = baseline;
	explicitMutations{4}.pairing_table.true_eventtype(1) = "wrong_event";
	explicitIdentifiers(4) = "load_guardrail_separation_result:PairRouteMismatch";
	explicitLabels(4) = "wrong true pairing event";
	explicitMutations{5} = baseline;
	explicitMutations{5}.settings.true_event = 'wrong_event';
	explicitIdentifiers(5) = "load_guardrail_separation_result:RouteSettingsMismatch";
	explicitLabels(5) = "wrong settings event";
	explicitMutations{6} = baseline;
	explicitMutations{6}.settings.channel = 'Pz';
	explicitIdentifiers(6) = "load_guardrail_separation_result:RouteSettingsMismatch";
	explicitLabels(6) = "wrong settings channel";
	explicitMutations{7} = baseline;
	explicitMutations{7}.settings.metric = 'wrong_metric';
	explicitIdentifiers(7) = "load_guardrail_separation_result:RouteSettingsMismatch";
	explicitLabels(7) = "wrong settings metric";
	explicitMutations{8} = baseline;
	explicitMutations{8}.settings.paired = false;
	explicitIdentifiers(8) = "load_guardrail_separation_result:AnalysisSettingsMismatch";
	explicitLabels(8) = "unpaired settings";
	explicitMutations{9} = baseline;
	explicitMutations{9}.settings.direction = 'wrong direction';
	explicitIdentifiers(9) = "load_guardrail_separation_result:EstimatorSettingsMismatch";
	explicitLabels(9) = "wrong estimator direction";
	explicitMutations{10} = baseline;
	explicitMutations{10}.settings.effect_specification.direction = 'wrong direction';
	explicitIdentifiers(10) = "load_guardrail_separation_result:EffectSpecificationMismatch";
	explicitLabels(10) = "wrong effect direction";
	explicitMutations{11} = baseline;
	explicitMutations{11}.settings.rng.seed = 2;
	explicitIdentifiers(11) = "load_guardrail_separation_result:RNGSettingsMismatch";
	explicitLabels(11) = "wrong RNG seed";
	explicitMutations{12} = baseline;
	explicitMutations{12}.settings.rng.generator = 'philox';
	explicitIdentifiers(12) = "load_guardrail_separation_result:RNGSettingsMismatch";
	explicitLabels(12) = "wrong RNG generator";
	explicitMutations{13} = baseline;
	explicitMutations{13}.estimate.Estimate(1) = NaN;
	explicitIdentifiers(13) = "load_guardrail_separation_result:InvalidEstimate";
	explicitLabels(13) = "nonfinite estimate";
	explicitMutations{14} = baseline;
	explicitMutations{14}.role = 'exclusionary analysis';
	explicitIdentifiers(14) = "load_guardrail_separation_result:InvalidRole";
	explicitLabels(14) = "wrong result role";
	for mutationIndex = 1:numel(explicitMutations)
	    separation_result = explicitMutations{mutationIndex}; %#ok<NASGU>
	    save(badPath, 'separation_result');
	    assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	        explicitIdentifiers(mutationIndex), explicitLabels(mutationIndex));
	end

	identityColumns = {'subjectID','sessionID','runID','channel', ...
	    'reference_epoch_index','true_epoch_index', ...
	    'reference_eventtype','true_eventtype'};
	for columnIndex = 1:numel(identityColumns)
	    separation_result = baseline; %#ok<NASGU>
	    separation_result.pairing_table.(identityColumns{columnIndex})(1) = "";
	    save(badPath, 'separation_result');
	    assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	        'load_guardrail_separation_result:InvalidPairIdentity', ...
	        sprintf('blank pairing identity %s', identityColumns{columnIndex}));
	end

	separation_result = rmfield(baseline, 'role'); %#ok<NASGU>
	save(badPath, 'separation_result');
	assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	    'load_guardrail_separation_result:MissingResultField', ...
	    'missing required saved-result field');

	separation_result = baseline; %#ok<NASGU>
	separation_result.provenance(1, :) = [];
	save(badPath, 'separation_result');
	assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	    'load_guardrail_separation_result:InvalidProvenance', ...
	    'missing provenance row');

	provenanceMutations = cell(4, 1);
	provenanceIdentifiers = strings(4, 1);
	provenanceLabels = strings(4, 1);
	provenanceMutations{1} = baseline;
	provenanceMutations{1}.provenance.name(1) = "";
	provenanceIdentifiers(1) = "load_guardrail_separation_result:InvalidProvenance";
	provenanceLabels(1) = "blank provenance name";
	provenanceMutations{2} = baseline;
	provenanceMutations{2}.provenance.name(2) = ...
	    provenanceMutations{2}.provenance.name(1);
	provenanceIdentifiers(2) = "load_guardrail_separation_result:InvalidProvenance";
	provenanceLabels(2) = "duplicate provenance name";
	provenanceMutations{3} = baseline;
	provenanceMutations{3}.provenance.path(1) = ...
	    provenanceMutations{3}.provenance.path(2);
	provenanceIdentifiers(3) = "load_guardrail_separation_result:SourcePathMismatch";
	provenanceLabels(3) = "wrong provenance path";
	provenanceMutations{4} = baseline;
	provenanceMutations{4}.provenance.bytes(1) = ...
	    provenanceMutations{4}.provenance.bytes(1) + 1;
	provenanceIdentifiers(4) = "load_guardrail_separation_result:SourceBytesMismatch";
	provenanceLabels(4) = "wrong provenance byte count";
	for mutationIndex = 1:numel(provenanceMutations)
	    separation_result = provenanceMutations{mutationIndex}; %#ok<NASGU>
	    save(badPath, 'separation_result');
	    assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	        provenanceIdentifiers(mutationIndex), provenanceLabels(mutationIndex));
	end

[nrfPath, nrfExpected, nrfBaseline] = write_separation_fixture( ...
    fixtureRoot, 'nrf', sourcePaths); %#ok<ASGLU>
	separation_result = nrfBaseline; %#ok<NASGU>
	separation_result.pairing_table.NRFName(1) = "wrong_template";
	save(badPath, 'separation_result');
	assert_error_id(@() load_guardrail_separation_result(badPath, nrfExpected), ...
	    'load_guardrail_separation_result:PairNRFMismatch', ...
	    'wrong pairing NRFName');
	separation_result = nrfBaseline; %#ok<NASGU>
	separation_result.settings.NRFName = 'wrong_template';
	save(badPath, 'separation_result');
	assert_error_id(@() load_guardrail_separation_result(badPath, nrfExpected), ...
	    'load_guardrail_separation_result:RouteSettingsMismatch', ...
	    'wrong settings NRFName');

	separation_result = baseline; %#ok<NASGU>
	separation_result.provenance.sha256(1) = string(repmat('0', 1, 64));
	save(badPath, 'separation_result');
	assert_error_id(@() load_guardrail_separation_result(badPath, expected), ...
	    'load_guardrail_separation_result:SourceHashMismatch', ...
	    'wrong stored provenance digest');

	originalSourceText = fileread(sourcePaths.input_csv);
	changedSourceText = originalSourceText;
	if changedSourceText(1) == 'X'
	    changedSourceText(1) = 'Y';
	else
	    changedSourceText(1) = 'X';
	end
	originalSourceBytes = dir(sourcePaths.input_csv).bytes;
	write_text(sourcePaths.input_csv, changedSourceText);
	assert(dir(sourcePaths.input_csv).bytes == originalSourceBytes, ...
	    'The same-byte provenance fixture unexpectedly changed file length.');
	assert_error_id(@() load_guardrail_separation_result(baselinePath, expected), ...
	    'load_guardrail_separation_result:SourceHashMismatch', ...
	    'same-byte current-source SHA-256 mismatch');
	write_text(sourcePaths.input_csv, originalSourceText);

	delete(sourcePaths.input_csv);
	assert_error_id(@() load_guardrail_separation_result(baselinePath, expected), ...
	    'load_guardrail_separation_result:MissingSource', ...
	    'missing current provenance source');
passed = 1;
end

function [root, cleanup] = make_separation_fixture_root(repoRoot)
originalPath = path;
root = tempname;
mkdir(root);
cleanup = onCleanup(@() cleanup_temporary_root(root, originalPath));
functionsRoot = fullfile(root, 'functions');
scriptsRoot = fullfile(root, 'scripts');
screeningRoot = fullfile(root, 'data', 'summary', 'screening');
mkdir(functionsRoot);
mkdir(scriptsRoot);
mkdir(screeningRoot);
copyfile(fullfile(repoRoot, 'functions', 'compute_paired_effect.m'), ...
    fullfile(functionsRoot, 'compute_paired_effect.m'));
copyfile(fullfile(repoRoot, 'functions', 'plot_paired_effect_result.m'), ...
    fullfile(functionsRoot, 'plot_paired_effect_result.m'));
copyfile(fullfile(repoRoot, 'functions', 'save_paired_separation_result.m'), ...
    fullfile(functionsRoot, 'save_paired_separation_result.m'));
copyfile(fullfile(repoRoot, 'scripts', 'step_7_check_6_sep_check_qc.m'), ...
    fullfile(scriptsRoot, 'step_7_check_6_sep_check_qc.m'));
copyfile(fullfile(repoRoot, 'scripts', 'step_7_check_7_sep_check_nrf.m'), ...
    fullfile(scriptsRoot, 'step_7_check_7_sep_check_nrf.m'));
write_text(fullfile(screeningRoot, 'pooled_screened_eeg_qc_features.csv'), ...
    "synthetic QC provenance fixture" + newline);
write_text(fullfile(screeningRoot, 'pooled_screened_eeg_nrf_features.csv'), ...
    "synthetic NRF provenance fixture" + newline);
end

function sourcePaths = separation_source_paths(root)
sourcePaths = struct( ...
    'input_csv', fullfile(root, 'data', 'summary', 'screening', ...
        'pooled_screened_eeg_qc_features.csv'), ...
    'script', fullfile(root, 'scripts', 'step_7_check_6_sep_check_qc.m'), ...
    'compute_helper', fullfile(root, 'functions', 'compute_paired_effect.m'), ...
    'plot_helper', fullfile(root, 'functions', 'plot_paired_effect_result.m'), ...
    'save_helper', fullfile(root, 'functions', 'save_paired_separation_result.m'));
end

function [resultPath, expected, separationResult] = write_separation_fixture( ...
        root, kind, sourcePaths)
screeningRoot = fullfile(root, 'data', 'summary', 'screening');
kind = string(kind);
if kind == "qc"
    resultPath = fullfile(screeningRoot, ...
        'step_7_check_6_sep_check_qc_result.mat');
    expected = struct( ...
        'channel', 'Cz', ...
        'reference_event', 'cannula_prestim', ...
        'true_event', 'cannula', ...
        'metric', 'MeanAbsDiffNorm', ...
        'nrf_name', '', ...
        'use_exclusion_flags', true, ...
        'source_paths', sourcePaths);
else
    resultPath = fullfile(screeningRoot, ...
        'step_7_check_7_sep_check_nrf_result.mat');
    sourcePaths.input_csv = fullfile(screeningRoot, ...
        'pooled_screened_eeg_nrf_features.csv');
    sourcePaths.script = fullfile(root, 'scripts', ...
        'step_7_check_7_sep_check_nrf.m');
    expected = struct( ...
        'channel', 'Cz', ...
        'reference_event', 'cannula_prestim', ...
        'true_event', 'cannula', ...
        'metric', 'fglsCoef', ...
        'nrf_name', 'noxious_preterm_NRF_500Hz', ...
        'use_exclusion_flags', true, ...
        'source_paths', sourcePaths);
end
separationResult = build_separation_result(kind, expected, sourcePaths);
separation_result = separationResult; %#ok<NASGU>
save(resultPath, 'separation_result');
end

function result = build_separation_result(kind, expected, sourcePaths)
pairIndex = (1:3).';
subjectID = ["S01"; "S02"; "S03"];
sessionID = repmat("01", 3, 1);
runID = repmat("01", 3, 1);
channel = repmat("Cz", 3, 1);
referenceEpochIndex = repmat("1", 3, 1);
trueEpochIndex = repmat("2", 3, 1);
referenceEvent = repmat("cannula_prestim", 3, 1);
trueEvent = repmat("cannula", 3, 1);
if kind == "qc"
    referenceValue = [0.8; 1.1; 1.4];
    trueValue = [0.5; 1.3; 1.6];
    pairingTable = table(pairIndex, subjectID, sessionID, runID, channel, ...
        referenceEpochIndex, trueEpochIndex, referenceEvent, trueEvent, ...
        referenceValue, trueValue, trueValue - referenceValue, ...
        'VariableNames', {'PairIndex','subjectID','sessionID','runID', ...
        'channel','reference_epoch_index','true_epoch_index', ...
        'reference_eventtype','true_eventtype','reference_value', ...
        'true_value','true_minus_reference'});
    counts = struct( ...
        'rows_after_channel_filter', 6, ...
        'excluded_rows_all', 0, ...
        'excluded_rows_selected_events', 0, ...
        'reference_rows_after_exclusion', 3, ...
        'true_rows_after_exclusion', 3, ...
        'groups_in_scope', 3, ...
        'incomplete_groups_dropped', 0, ...
        'nan_pairs_dropped', 0, ...
        'pairs_analysed', 3);
else
    referenceValue = [0.1; 0.4; 0.2];
    trueValue = [0.7; 0.9; 0.6];
    NRFName = repmat("noxious_preterm_NRF_500Hz", 3, 1);
    pairingTable = table(pairIndex, subjectID, sessionID, runID, channel, ...
        referenceEpochIndex, trueEpochIndex, referenceEvent, trueEvent, ...
        NRFName, referenceValue, trueValue, trueValue - referenceValue, ...
        'VariableNames', {'PairIndex','subjectID','sessionID','runID', ...
        'channel','reference_epoch_index','true_epoch_index', ...
        'reference_eventtype','true_eventtype','NRFName', ...
        'reference_value','true_value','true_minus_reference'});
    counts = struct( ...
        'rows_after_channel_filter', 6, ...
        'rows_after_template_filter', 6, ...
        'excluded_rows_all_templates', 0, ...
        'excluded_rows_selected_events_all_templates', 0, ...
        'excluded_rows_selected_template', 0, ...
        'excluded_rows_selected_events_and_template', 0, ...
        'reference_rows_after_filters', 3, ...
        'true_rows_after_filters', 3, ...
        'groups_in_scope', 3, ...
        'incomplete_groups_dropped', 0, ...
        'nan_pairs_dropped', 0, ...
        'pairs_analysed', 3);
end
differences = trueValue - referenceValue;
effectSpecification = struct( ...
    'effect', 'pairedmediandiff', ...
    'estimand', 'Median of within-pair differences', ...
    'statistic', 'median', ...
    'table_row_name', 'PairedMedianDifference', ...
    'direction', 'true event minus internal reference within each complete pair', ...
    'axis_label', 'Median paired difference (true - reference)', ...
    'contrast_tick_label', 'Median paired difference', ...
    'positive_value_interpretation', ...
        ['Positive values indicate a positive median within-pair ', ...
        'true-minus-reference difference.'], ...
    'scale', 'original metric units');
estimate = table(median(differences), [-0.5 0.8], ...
    'VariableNames', {'Estimate','ConfidenceIntervals'}, ...
    'RowNames', {'PairedMedianDifference'});
rngStateBefore = rng;
rngCleanup = onCleanup(@() rng(rngStateBefore)); %#ok<NASGU>
rng(1, 'twister');
generatingRng = rng;
rngSpecification = struct( ...
    'seed', 1, ...
    'generator', 'twister', ...
    'generating_state', generatingRng.State, ...
    'bootstrap_resamples', 100000, ...
    'bootstrap_interval', 'bias-corrected and accelerated (BCa)', ...
    'bootstrap_function', 'MATLAB bootci', ...
    'resampling_unit', ...
        'complete pair represented by one true-minus-reference difference score', ...
    'difference_definition', ...
        'true_values - reference_values in matched input order', ...
    'statistic', 'median');
settings = struct( ...
    'direction', effectSpecification.direction, ...
    'estimand', effectSpecification.estimand, ...
    'effect_specification', effectSpecification, ...
    'paired', true, ...
    'estimator', 'pairedmediandiff', ...
    'statistic', 'median', ...
    'difference_definition', ...
        'true_value - reference_value within each complete pair', ...
    'bootstrap_resampling_unit', ...
        'complete pair represented by one difference score', ...
    'confidence_interval', 'bias-corrected and accelerated (BCa)', ...
    'estimator_implementation', ...
        'MATLAB bootci applied once to pair_differences', ...
    'alpha', 0.05, ...
    'rng', rngSpecification, ...
    'channel', 'Cz', ...
    'true_event', 'cannula', ...
    'reference_event', 'cannula_prestim', ...
    'metric', expected.metric, ...
    'use_exclusion_flags', true, ...
    'pairing_key', 'subjectID, sessionID, runID, channel', ...
    'participant_aggregation', 'none');
if kind == "nrf"
    settings.NRFName = 'noxious_preterm_NRF_500Hz';
end

sourceNames = string(fieldnames(sourcePaths));
sourcePathValues = strings(numel(sourceNames), 1);
sourceBytes = zeros(numel(sourceNames), 1);
sourceSha256 = strings(numel(sourceNames), 1);
for sourceIndex = 1:numel(sourceNames)
    sourcePathValues(sourceIndex) = sourcePaths.(sourceNames(sourceIndex));
    info = dir(sourcePathValues(sourceIndex));
    sourceBytes(sourceIndex) = info.bytes;
    sourceSha256(sourceIndex) = local_file_sha256(sourcePathValues(sourceIndex));
end
provenance = table(sourceNames, sourcePathValues, sourceBytes, sourceSha256, ...
    'VariableNames', {'name','path','bytes','sha256'});

result = struct( ...
    'schema', 'simple-paired-separation-result-v2', ...
    'role', 'descriptive, non-exclusionary guardrail', ...
    'pairing_table', pairingTable, ...
    'pair_differences', differences, ...
    'estimate', estimate, ...
    'settings', settings, ...
    'counts', counts, ...
    'environment', struct('matlab_version', version, ...
        'matlab_release', version('-release'), 'computer', computer), ...
    'provenance', provenance);
end

function passed = run_script_positive(repoRoot)
[fixture, fixtureCleanup] = make_script_fixture(repoRoot, ""); %#ok<ASGLU>
mkdir(fixture.results);
sentinelNames = { ...
    'jasp_data_eeg.csv', 'jasp_data_eeg_median.csv', ...
    'jasp_selection_manifest.csv'};
sentinelHashes = strings(numel(sentinelNames), 1);
for sentinelIndex = 1:numel(sentinelNames)
    sentinelPath = fullfile(fixture.results, sentinelNames{sentinelIndex});
    write_text(sentinelPath, sprintf('unchanged sentinel %d\n', sentinelIndex));
    sentinelHashes(sentinelIndex) = local_file_sha256(sentinelPath);
end

bootciRoot = fullfile(fixture.root, 'bootci_stub');
mkdir(bootciRoot);
write_text(fullfile(bootciRoot, 'bootci.m'), sprintf([ ...
    'function varargout = bootci(varargin)\n' ...
    'error(''SimpleStrasbourg:Test:BootciCalled'', ''bootci must not run.'');\n' ...
    'end\n']));
addpath(bootciRoot, '-begin');
clear bootci
rehash path;
assert_path(which('bootci'), fullfile(bootciRoot, 'bootci.m'));

rngBefore = rng;
inputPaths = {fixture.epochs_mat, fixture.qc_mat, fixture.nrf_mat, ...
    fixture.qc_source, fixture.nrf_source};
inputHashes = strings(numel(inputPaths), 1);
for inputIndex = 1:numel(inputPaths)
    inputHashes(inputIndex) = local_file_sha256(inputPaths{inputIndex});
end
figuresBefore = findall(groot, 'Type', 'figure');
run_script_in_base(fixture.script);
assert(isequal(rngBefore, rng), ...
    'The complete Step 8.1 script changed caller RNG state.');
assert(getappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript'), ...
    'The complete Step 8.1 script did not close its own diary.');
for inputIndex = 1:numel(inputPaths)
    assert(local_file_sha256(inputPaths{inputIndex}) == inputHashes(inputIndex), ...
        'Step 8.1 changed a direct fixture input.');
end
assert(all(isgraphics(figuresBefore, 'figure')), ...
    'Step 8.1 closed an unrelated pre-existing figure.');
assert_script_success(fixture, sentinelNames, sentinelHashes);

firstPanelData = evalin('base', 'figure6PanelData');
write_text(fixture.final_pdf, "obsolete PDF sentinel\n");
write_text(fixture.log, "obsolete log sentinel\n");
run_script_in_base(fixture.script);
assert_script_success(fixture, sentinelNames, sentinelHashes);
assert(local_file_sha256(fixture.final_pdf) ~= ...
    local_file_sha256_text("obsolete PDF sentinel\n"), ...
    'A successful rerun did not replace its final PDF.');
secondPanelData = evalin('base', 'figure6PanelData');
assert(isequaln(firstPanelData, secondPanelData), ...
    'A successful rerun did not reproduce identical numerical panel data.');
logText = string(fileread(fixture.log));
assert(~contains(logText, 'obsolete log sentinel'));
assert(count(logText, ['Completed Step 8.1 post-screening ', ...
    'descriptive-check figure preparation; committing PDF:']) == 1);
clear bootci
remove_path_if_present(bootciRoot);
passed = 1;
end

function assert_script_success(fixture, sentinelNames, sentinelHashes)
assert(isfile(fixture.final_pdf), 'Step 8.1 did not create its final PDF.');
assert(isfile(fixture.log), 'Step 8.1 did not create its exact log.');
assert(~isfile(fixture.partial_pdf) && ~isfile(fixture.rollback_pdf), ...
    'A successful Step 8.1 run left a transactional PDF behind.');
assert_pdf_header(fixture.final_pdf);
assert(dir(fixture.final_pdf).bytes > 100, ...
    'Step 8.1 PDF is unexpectedly small.');
for sentinelIndex = 1:numel(sentinelNames)
    sentinelPath = fullfile(fixture.results, sentinelNames{sentinelIndex});
    assert(local_file_sha256(sentinelPath) == sentinelHashes(sentinelIndex), ...
        'Step 8.1 changed an unrelated Step 8/9 sentinel: %s', ...
        sentinelNames{sentinelIndex});
end

resultNames = sorted_file_names(fixture.results);
expectedNames = sort([sentinelNames, {fixture.pdf_name}]);
assert(isequal(resultNames, expectedNames), ...
    'The successful fixture created an unexpected result artefact.');
assert(isequal(sorted_file_names(fixture.logs), ...
    {'step_8_gen_1_check_plots.log'}), ...
    'The successful fixture created an unexpected log.');

requiredWorkspace = {'figure6Config','figure6PanelData', ...
    'figure6PanelHandles','figure6Figure'};
for variableIndex = 1:numel(requiredWorkspace)
    assert(evalin('base', sprintf('exist(''%s'', ''var'') == 1', ...
        requiredWorkspace{variableIndex})), ...
        'Step 8.1 did not retain %s.', requiredWorkspace{variableIndex});
end
config = evalin('base', 'figure6Config');
panelData = evalin('base', 'figure6PanelData');
panelHandles = evalin('base', 'figure6PanelHandles');
figureHandle = evalin('base', 'figure6Figure');
assert(isgraphics(figureHandle, 'figure'));
assert(strcmp(figureHandle.Units, 'centimeters'));
assert(strcmp(figureHandle.Visible, 'on'), ...
    'The completed Step 8.1 figure was not left visible for inspection.');
assert_numeric_close(figureHandle.Position(3:4), [18 24], 1e-12, ...
    'fixed figure dimensions');
assert(isequal(string({panelData.event_series.eventtype}), ...
    ["cannula_prestim", "cannula"]));
assert(isequal([panelData.event_series.n_admitted], [4 3]));

expectedAxesTags = [ ...
    "figure6-ts-reference"; "figure6-ts-true"; ...
    "figure6-tf-reference"; "figure6-tf-true"; ...
    "figure6-psd-reference"; "figure6-psd-true"; ...
    "figure6-qc-separation"; "figure6-nrf-separation"];
axesHandles = panelHandles.data_axes;
assert(numel(axesHandles) == 8 && all(isgraphics(axesHandles, 'axes')));
assert(isequal(string(get(axesHandles, 'Tag')), expectedAxesTags));
for axesIndex = 1:8
    assert(isempty(axesHandles(axesIndex).Title.String), ...
        'A Step 8.1 data axes retained a subplot title.');
end
labelHandles = panelHandles.labels;
actualLabelTags = [string(labelHandles.part_a.Tag); ...
    string(labelHandles.reference.Tag); string(labelHandles.true.Tag); ...
    string(labelHandles.part_b.Tag); string(labelHandles.qc.Tag); ...
    string(labelHandles.nrf.Tag)];
expectedLabelTags = ["figure6-label-part-a"; "figure6-label-reference"; ...
    "figure6-label-true"; "figure6-label-part-b"; ...
    "figure6-label-qc"; "figure6-label-nrf"];
assert(isequal(actualLabelTags, expectedLabelTags));
actualLabelStrings = [string(labelHandles.part_a.String); ...
    string(labelHandles.reference.String); string(labelHandles.true.String); ...
    string(labelHandles.part_b.String); string(labelHandles.qc.String); ...
    string(labelHandles.nrf.String)];
expectedLabelStrings = ["Time and frequency domain checks"; ...
    "Internal reference"; "True event"; ...
    "Feature separation checks"; "QC feature"; ...
    "Preterm noxious NRF magnitude"];
assert(isequal(actualLabelStrings, expectedLabelStrings));
assert(strcmp(labelHandles.part_a.HorizontalAlignment, 'center'));
assert(strcmp(labelHandles.part_b.HorizontalAlignment, 'center'));

assert(numel(panelHandles.time_series_reference.overlays) == 1);
assert(numel(panelHandles.time_series_true.overlays) == 1);
assert(isgraphics(panelHandles.time_frequency_reference.colorbar, 'colorbar'));
assert(isgraphics(panelHandles.time_frequency_true.colorbar, 'colorbar'));
assert(panelHandles.time_frequency_reference.colorbar ~= ...
    panelHandles.time_frequency_true.colorbar);
assert(isequal(clim(axesHandles(3)), [-4 4]));
assert(isequal(clim(axesHandles(4)), [-4 4]));
assert(isequal(xlim(axesHandles(5)), [-1 251]));
assert(isequal(xlim(axesHandles(6)), [-1 251]));
assert(isequaln(panelData.qc_separation, fixture.qc_result));
assert(isequaln(panelData.nrf_separation, fixture.nrf_result));
assert(isequal(config.paths.final_pdf, fixture.final_pdf));
assert(isstruct(panelHandles.qc_separation) && ...
    isgraphics(panelHandles.qc_separation.effect));
assert(isstruct(panelHandles.nrf_separation) && ...
    isgraphics(panelHandles.nrf_separation.effect));
assert_numeric_close(panelHandles.qc_separation.true.YData(:), ...
    fixture.qc_result.pairing_table.true_value, 0, 'QC plotted true values');
assert_numeric_close(panelHandles.qc_separation.reference.YData(:), ...
    fixture.qc_result.pairing_table.reference_value, 0, ...
    'QC plotted reference values');
assert_numeric_close(panelHandles.qc_separation.effect.YData, ...
    fixture.qc_result.estimate.Estimate(1), 0, 'QC plotted estimate');
assert_numeric_close(panelHandles.qc_separation.interval.YData(:), ...
    fixture.qc_result.estimate.ConfidenceIntervals(1, :).', 0, ...
    'QC plotted confidence interval');
assert_numeric_close(panelHandles.nrf_separation.true.YData(:), ...
    fixture.nrf_result.pairing_table.true_value, 0, 'NRF plotted true values');
assert_numeric_close(panelHandles.nrf_separation.reference.YData(:), ...
    fixture.nrf_result.pairing_table.reference_value, 0, ...
    'NRF plotted reference values');
assert_numeric_close(panelHandles.nrf_separation.effect.YData, ...
    fixture.nrf_result.estimate.Estimate(1), 0, 'NRF plotted estimate');
assert_numeric_close(panelHandles.nrf_separation.interval.YData(:), ...
    fixture.nrf_result.estimate.ConfidenceIntervals(1, :).', 0, ...
    'NRF plotted confidence interval');

logText = string(fileread(fixture.log));
assert(contains(logText, ['Completed Step 8.1 post-screening ', ...
    'descriptive-check figure preparation; committing PDF:']));
assert(~contains(lower(logText), 'step 8.1 failed'));
end

function passed = run_script_failures(repoRoot)
caseNames = ["missing_epochs", "missing_qc", "missing_nrf", ...
    "malformed_epochs", "no_admitted_true", "wrong_schema", ...
    "stale_provenance"];
for caseIndex = 1:numel(caseNames)
    [fixture, fixtureCleanup] = make_script_fixture(repoRoot, ""); %#ok<ASGLU>
    unrelatedPath = fullfile(fixture.root, 'unrelated_sentinel.txt');
    write_text(unrelatedPath, "must remain unchanged\n");
    unrelatedHash = local_file_sha256(unrelatedPath);
    switch caseNames(caseIndex)
        case "missing_epochs"
            delete(fixture.epochs_mat);
        case "missing_qc"
            delete(fixture.qc_mat);
        case "missing_nrf"
            delete(fixture.nrf_mat);
        case "malformed_epochs"
            epochs_pooled = make_epoch_fixture(); %#ok<NASGU>
            epochs_pooled(1).data(1, 1, 1) = NaN;
            save(fixture.epochs_mat, 'epochs_pooled');
        case "no_admitted_true"
            epochs_pooled = make_epoch_fixture(); %#ok<NASGU>
            for datasetIndex = 1:numel(epochs_pooled)
                epochs_pooled(datasetIndex).Exclude(1, 2) = true;
            end
            save(fixture.epochs_mat, 'epochs_pooled');
        case "wrong_schema"
            loaded = load(fixture.qc_mat, 'separation_result');
            separation_result = loaded.separation_result; %#ok<NASGU>
            separation_result.schema = 'wrong-schema';
            save(fixture.qc_mat, 'separation_result');
        case "stale_provenance"
            write_text(fixture.qc_source, "changed after result save\n");
    end
    assert_any_error(@() run_script_in_base(fixture.script), ...
        sprintf('Step 8.1 failure case %s was accepted.', caseNames(caseIndex)));
    assert_rejected_script_cleanup(fixture);
    assert(local_file_sha256(unrelatedPath) == unrelatedHash, ...
        'Rejected Step 8.1 changed an unrelated file.');
    clear fixtureCleanup fixture
end
passed = 1;
end

function assert_rejected_script_cleanup(fixture)
assert(isfile(fixture.log), 'Rejected Step 8.1 did not retain its exact log.');
logText = lower(string(fileread(fixture.log)));
assert(contains(logText, 'step 8.1 failed'), ...
    'Rejected Step 8.1 log lacks its failure diagnostic.');
assert(getappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript'), ...
    'Rejected Step 8.1 did not close its own diary before test cleanup.');
assert(~isfile(fixture.final_pdf) && ~isfile(fixture.partial_pdf) && ...
    ~isfile(fixture.rollback_pdf), ...
    'Rejected Step 8.1 left a final or transactional PDF.');
assert(~isfolder(fixture.results), ...
    'Rejected pre-render fixture left its newly created empty results folder.');
if evalin('base', 'exist(''figure6Figure'', ''var'') == 1')
    candidate = evalin('base', 'figure6Figure');
    assert(isempty(candidate) || ~isgraphics(candidate), ...
        'Rejected Step 8.1 left its incomplete candidate figure open.');
end
assert(isequal(sorted_file_names(fixture.logs), ...
    {'step_8_gen_1_check_plots.log'}));
end

function passed = run_transaction_rollback(repoRoot)
failpointsWithPrior = ["after-rollback", "after-promotion", "after-log-stop"];
for failpointIndex = 1:numel(failpointsWithPrior)
    failpoint = failpointsWithPrior(failpointIndex);
    [fixture, fixtureCleanup] = make_script_fixture(repoRoot, failpoint); %#ok<ASGLU>
    mkdir(fixture.results);
    priorBytes = uint8(sprintf('prior final sentinel: %s\n', failpoint));
    write_binary(fixture.final_pdf, priorBytes);
    priorHash = local_file_sha256(fixture.final_pdf);
    unrelatedPath = fullfile(fixture.results, 'unrelated_result.csv');
    write_text(unrelatedPath, "unchanged unrelated result\n");
    unrelatedHash = local_file_sha256(unrelatedPath);
    figuresBefore = findall(groot, 'Type', 'figure');
    assert_error_id(@() run_script_in_base(fixture.script), ...
        'SimpleStrasbourg:Step81:InjectedFailure');
    assert(isfile(fixture.final_pdf));
    assert(local_file_sha256(fixture.final_pdf) == priorHash, ...
        'Injected Step 8.1 failure did not restore the prior final PDF.');
    assert(local_file_sha256(unrelatedPath) == unrelatedHash);
    assert(~isfile(fixture.partial_pdf) && ~isfile(fixture.rollback_pdf));
    assert(isfile(fixture.log) && contains(lower(string(fileread(fixture.log))), ...
        'step 8.1 failed'));
    assert(getappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript'), ...
        'Injected Step 8.1 failure did not close its own diary.');
    assert(same_figure_inventory(figuresBefore, ...
        findall(groot, 'Type', 'figure')), ...
        'Injected Step 8.1 failure did not close only its candidate figure.');
    clear fixtureCleanup fixture
end

	for failpoint = ["after-promotion", "after-log-stop"]
	    [fixture, fixtureCleanup] = make_script_fixture(repoRoot, failpoint); %#ok<ASGLU>
	    figuresBefore = findall(groot, 'Type', 'figure');
	    assert_error_id(@() run_script_in_base(fixture.script), ...
	        'SimpleStrasbourg:Step81:InjectedFailure');
	    assert(~isfile(fixture.final_pdf) && ~isfile(fixture.partial_pdf) && ...
	        ~isfile(fixture.rollback_pdf), ...
	        ['Injected ', char(failpoint), ' failure without a prior final ', ...
	        'left a PDF behind.']);
	    assert(~isfolder(fixture.results), ...
	        ['Injected ', char(failpoint), ' failure without a prior final ', ...
	        'left an empty results folder.']);
	    assert(isfile(fixture.log) && contains(lower(string(fileread(fixture.log))), ...
	        'step 8.1 failed'));
	    assert(getappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript'), ...
	        ['Injected ', char(failpoint), ' failure without a prior PDF ', ...
	        'did not close its diary.']);
	    assert(same_figure_inventory(figuresBefore, ...
	        findall(groot, 'Type', 'figure')));
	    clear fixtureCleanup fixture
	end

	for hadPriorFinal = [true false]
	    [fixture, fixtureCleanup] = make_script_fixture(repoRoot, ""); %#ok<ASGLU>
	    install_throwing_stop_logger(fixture);
	    figuresBefore = findall(groot, 'Type', 'figure');
	    if hadPriorFinal
	        mkdir(fixture.results);
	        priorBytes = uint8('prior final before logger-stop failure');
	        write_binary(fixture.final_pdf, priorBytes);
	        priorHash = local_file_sha256(fixture.final_pdf);
	        unrelatedPath = fullfile(fixture.results, 'unrelated_result.csv');
	        write_text(unrelatedPath, "unchanged unrelated result\n");
	        unrelatedHash = local_file_sha256(unrelatedPath);
	    end
	    assert_error_id(@() run_script_in_base(fixture.script), ...
	        'SimpleStrasbourg:Test:LoggerStopFailure');
	    assert(log_command_window('query_stop_count') == 1, ...
	        'The guarded finaliser attempted to stop its logger more than once.');
	    logText = lower(string(fileread(fixture.log)));
	    assert(contains(logText, ['single logger-stop attempt failed; direct ', ...
	        'diary-off fallback was required.']), ...
	        'The logger-stop failure log lacks the direct-fallback diagnostic.');
	    assert(getappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript'), ...
	        'The logger-stop failure did not leave the diary closed.');
	    assert(~isfile(fixture.partial_pdf) && ~isfile(fixture.rollback_pdf), ...
	        'The logger-stop failure left a transactional PDF behind.');
	    assert(same_figure_inventory(figuresBefore, ...
	        findall(groot, 'Type', 'figure')), ...
	        'The logger-stop failure did not close only its candidate figure.');
	    if hadPriorFinal
	        assert(isfile(fixture.final_pdf) && ...
	            local_file_sha256(fixture.final_pdf) == priorHash, ...
	            'Logger-stop failure did not restore the prior final PDF.');
	        assert(local_file_sha256(unrelatedPath) == unrelatedHash, ...
	            'Logger-stop failure changed an unrelated result.');
	    else
	        assert(~isfile(fixture.final_pdf), ...
	            'Logger-stop failure without a prior PDF left a final behind.');
	        assert(~isfolder(fixture.results), ...
	            'Logger-stop failure without a prior PDF left an empty results folder.');
	    end
	    clear fixtureCleanup fixture log_command_window
	end
	passed = 1;
	end

	function install_throwing_stop_logger(fixture)
	loggerSource = sprintf([ ...
	    'function varargout = log_command_window(action)\n' ...
	    'persistent stopCount\n' ...
	    'if isempty(stopCount), stopCount = 0; end\n' ...
	    'act = lower(string(action));\n' ...
	    'if act == "query_stop_count"\n' ...
	    '    varargout{1} = stopCount;\n' ...
	    '    return;\n' ...
	    'end\n' ...
	    'if act == "start"\n' ...
	    '    stopCount = 0;\n' ...
	    '    stack = dbstack(''-completenames'');\n' ...
	    '    [~, callerBase] = fileparts(stack(2).file);\n' ...
	    '    helperDir = fileparts(mfilename(''fullpath''));\n' ...
	    '    projectRoot = fileparts(helperDir);\n' ...
	    '    logsDir = fullfile(projectRoot, ''data'', ''logs'');\n' ...
	    '    if ~isfolder(logsDir), mkdir(logsDir); end\n' ...
	    '    logFile = fullfile(logsDir, [callerBase ''.log'']);\n' ...
	    '    if isfile(logFile), delete(logFile); end\n' ...
	    '    diary off; diary(logFile); diary on;\n' ...
	    '    return;\n' ...
	    'end\n' ...
	    'if act == "stop"\n' ...
	    '    stopCount = stopCount + 1;\n' ...
	    '    error(''SimpleStrasbourg:Test:LoggerStopFailure'', ...\n' ...
	    '        ''Injected exact-path logger stop failure.'');\n' ...
	    'end\n' ...
	    'error(''SimpleStrasbourg:Test:LoggerAction'', ''Unexpected logger action.'');\n' ...
	    'end\n']);
	loggerPath = fullfile(fixture.scripts, 'log_command_window.m');
	write_text(loggerPath, loggerSource);
	clear log_command_window
	rehash path;
	assert_path(which('log_command_window'), loggerPath);
	end

function [fixture, cleanup] = make_script_fixture(repoRoot, failpoint)
originalPath = path;
root = tempname;
mkdir(root);
cleanup = onCleanup(@() cleanup_temporary_root(root, originalPath));
fixture = struct();
fixture.root = root;
fixture.scripts = fullfile(root, 'scripts');
fixture.functions = fullfile(root, 'functions');
fixture.screening = fullfile(root, 'data', 'summary', 'screening');
fixture.results = fullfile(root, 'data', 'results');
fixture.logs = fullfile(root, 'data', 'logs');
mkdir(fixture.scripts);
mkdir(fixture.screening);
mkdir(fixture.results);
mkdir(fixture.logs);
copyfile(fullfile(repoRoot, 'functions'), fixture.functions);
copyfile(fullfile(repoRoot, 'NRFs'), fullfile(root, 'NRFs'));
copyfile(fullfile(repoRoot, 'scripts', 'log_command_window.m'), ...
    fullfile(fixture.scripts, 'log_command_window.m'));
sourceScripts = { ...
    'step_7_check_6_sep_check_qc.m', ...
    'step_7_check_7_sep_check_nrf.m'};
for scriptIndex = 1:numel(sourceScripts)
    copyfile(fullfile(repoRoot, 'scripts', sourceScripts{scriptIndex}), ...
        fullfile(fixture.scripts, sourceScripts{scriptIndex}));
end

fixture.script = fullfile(fixture.scripts, 'step_8_gen_1_check_plots.m');
copy_step8_fixture_script( ...
    fullfile(repoRoot, 'scripts', 'step_8_gen_1_check_plots.m'), ...
    fixture.script, root, failpoint);
fixture.epochs_mat = fullfile(fixture.screening, ...
    'pooled_screened_eeg_epochs.mat');
epochs_pooled = make_epoch_fixture(); %#ok<NASGU>
save(fixture.epochs_mat, 'epochs_pooled');
fixture.qc_source = fullfile(fixture.screening, ...
    'pooled_screened_eeg_qc_features.csv');
fixture.nrf_source = fullfile(fixture.screening, ...
    'pooled_screened_eeg_nrf_features.csv');
write_text(fixture.qc_source, "synthetic QC source\n");
write_text(fixture.nrf_source, "synthetic NRF source\n");
sourcePaths = separation_source_paths(root);
[fixture.qc_mat, fixture.qc_expected, fixture.qc_result] = ...
    write_separation_fixture(root, 'qc', sourcePaths);
[fixture.nrf_mat, fixture.nrf_expected, fixture.nrf_result] = ...
    write_separation_fixture(root, 'nrf', sourcePaths);
fixture.pdf_name = 'figure_3b_post_screening_descriptive_checks_noci_prem.pdf';
fixture.final_pdf = fullfile(fixture.results, fixture.pdf_name);
fixture.partial_pdf = fullfile(fixture.results, ...
    'figure_3b_post_screening_descriptive_checks_noci_prem.partial.pdf');
fixture.rollback_pdf = fullfile(fixture.results, ...
    'figure_3b_post_screening_descriptive_checks_noci_prem.rollback.pdf');
fixture.log = fullfile(fixture.logs, 'step_8_gen_1_check_plots.log');

% Most cases need to prove that Step 8.1 creates and, on rejection, removes
% its own results directory. The caller can preseed it when replacement or
% unrelated-artifact preservation is under test.
rmdir(fixture.results);
addpath(fixture.scripts, '-begin');
addpath(fixture.functions, '-begin');
clear log_command_window NRFUtils collect_guardrail_event_series ...
    plot_guardrail_average_ts plot_guardrail_average_tf ...
    plot_guardrail_average_psd load_guardrail_separation_result
rehash path;
assert_path(which('log_command_window'), ...
    fullfile(fixture.scripts, 'log_command_window.m'));
end

function copy_step8_fixture_script(sourcePath, destinationPath, root, failpoint)
source = fileread(sourcePath);
basePattern = 'baseDir\s*=\s*''[^'']+'';';
assert(numel(regexp(source, basePattern, 'match')) == 1);
source = regexprep(source, basePattern, ...
    sprintf('baseDir = ''%s'';', strrep(root, '''', '''''')), 'once');
failpointPattern = 'figure6InternalFailpoint\s*=\s*"";';
assert(numel(regexp(source, failpointPattern, 'match')) == 1);
source = regexprep(source, failpointPattern, ...
    sprintf('figure6InternalFailpoint = "%s";', char(failpoint)), 'once');
write_text(destinationPath, source);
end

function run_script_in_base(scriptPath)
scriptFolder = fileparts(scriptPath);
cd(scriptFolder);
evalin('base', 'clear;');
setappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript', false);
command = sprintf('run(''%s'');', strrep(scriptPath, '''', ''''''));
try
    evalin('base', command);
catch ME
    scriptClosedDiary = probe_and_stop_diary(scriptPath);
    setappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript', ...
        scriptClosedDiary);
    rethrow(ME);
end
scriptClosedDiary = probe_and_stop_diary(scriptPath);
setappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript', scriptClosedDiary);
if ~scriptClosedDiary
    error('SimpleStrasbourg:Test:DiaryLeftOn', ...
        'Step 8.1 returned successfully with its diary still active.');
end
end

function scriptClosedDiary = probe_and_stop_diary(scriptPath)
[~, probeToken] = fileparts(tempname);
probeText = ['SIMPLE_STRASBOURG_DIARY_STATE_PROBE_', probeToken];
fprintf(1, '%s\n', probeText);
diary off;

scriptRoot = fileparts(fileparts(scriptPath));
logsDir = fullfile(scriptRoot, 'data', 'logs');
scriptClosedDiary = true;
if isfolder(logsDir)
    logFiles = dir(fullfile(logsDir, '*.log'));
    for logIndex = 1:numel(logFiles)
        logText = fileread(fullfile(logFiles(logIndex).folder, ...
            logFiles(logIndex).name));
        if contains(logText, probeText)
            scriptClosedDiary = false;
            break;
        end
    end
end
end

function assert_path(actualPath, expectedPath)
actualPath = char(java.io.File(actualPath).getCanonicalPath());
expectedPath = char(java.io.File(expectedPath).getCanonicalPath());
assert(strcmp(actualPath, expectedPath), ...
    'Expected path %s, but resolved %s.', expectedPath, actualPath);
end

	function assert_error_id(callback, expectedIdentifier, label)
	if nargin < 3
	    label = expectedIdentifier;
	end
	didThrow = false;
	try
	    callback();
	catch ME
	    didThrow = true;
	    assert(strcmp(ME.identifier, expectedIdentifier), ...
	        '%s: expected error %s, but received %s: %s', ...
	        label, expectedIdentifier, ME.identifier, ME.message);
	end
	assert(didThrow, '%s: expected error %s was not thrown.', ...
	    label, expectedIdentifier);
	end

function assert_any_error(callback, failureMessage)
didThrow = false;
try
    callback();
catch
    didThrow = true;
end
assert(didThrow, '%s', failureMessage);
end

function assert_numeric_close(actual, expected, tolerance, label)
assert(isequal(size(actual), size(expected)), '%s size differs.', label);
assert(isequal(isnan(actual), isnan(expected)), '%s NaN mask differs.', label);
delta = abs(double(actual) - double(expected));
delta(isnan(actual) & isnan(expected)) = 0;
maximum = max(delta(:), [], 'omitnan');
if isempty(maximum)
    maximum = 0;
end
assert(maximum <= tolerance, ...
    '%s differs by %.17g (tolerance %.17g).', label, maximum, tolerance);
end

function snapshot = snapshot_regular_files(root)
items = dir(fullfile(root, '**', '*'));
items = items(~[items.isdir]);
paths = strings(numel(items), 1);
hashes = strings(numel(items), 1);
for itemIndex = 1:numel(items)
    paths(itemIndex) = string(erase( ...
        fullfile(items(itemIndex).folder, items(itemIndex).name), ...
        [root filesep]));
    hashes(itemIndex) = local_file_sha256( ...
        fullfile(items(itemIndex).folder, items(itemIndex).name));
end
[paths, order] = sort(paths);
snapshot = table(paths, hashes(order));
end

function digest = local_file_sha256(filePath)
fid = fopen(filePath, 'rb');
assert(fid >= 0, 'Could not read fixture file: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
md = java.security.MessageDigest.getInstance('SHA-256');
chunkSize = 1024 * 1024;
while true
    [chunk, count] = fread(fid, chunkSize, '*uint8');
    if count > 0
        signedChunk = reshape(typecast(chunk(:), 'int8'), 1, []);
        md.update(signedChunk);
    end
    if count < chunkSize
        break;
    end
end
[readMessage, readErrno] = ferror(fid);
normalEof = readErrno == -4 && feof(fid);
assert(readErrno == 0 || normalEof, ...
    'Failed while hashing fixture file %s: %s', filePath, readMessage);
digest = string(lower(reshape( ...
    dec2hex(typecast(md.digest(), 'uint8'), 2).', 1, [])));
end

function digest = local_file_sha256_text(textValue)
temporary = [tempname '.txt'];
cleanup = onCleanup(@() delete_if_file(temporary)); %#ok<NASGU>
write_text(temporary, textValue);
digest = local_file_sha256(temporary);
end

function assert_pdf_header(filePath)
fid = fopen(filePath, 'rb');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
header = fread(fid, 5, '*uint8');
assert(isequal(header(:), uint8([37; 80; 68; 70; 45])), ...
    'Fixture output lacks the PDF header.');
end

function write_text(filePath, value)
fid = fopen(filePath, 'wt');
assert(fid >= 0, 'Could not create fixture file: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
value = char(value);
count = fwrite(fid, value, 'char');
assert(count == numel(value));
end

function write_binary(filePath, bytes)
fid = fopen(filePath, 'wb');
assert(fid >= 0, 'Could not create fixture file: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
count = fwrite(fid, uint8(bytes), 'uint8');
assert(count == numel(bytes));
end

function names = sorted_file_names(folder)
if ~isfolder(folder)
    names = {};
    return;
end
listing = dir(folder);
listing = listing(~[listing.isdir]);
names = sort({listing.name});
end

function close_if_graphics(handle)
if isgraphics(handle)
    close(handle);
end
end

function remove_path_if_present(folder)
if contains([path pathsep], [folder pathsep])
    rmpath(folder);
end
end

function delete_if_file(filePath)
if isfile(filePath)
    delete(filePath);
end
end

function cleanup_temporary_root(root, originalPath)
diary off;
evalin('base', 'clear;');
path(originalPath);
clear log_command_window NRFUtils collect_guardrail_event_series ...
    plot_guardrail_average_ts plot_guardrail_average_tf ...
    plot_guardrail_average_psd load_guardrail_separation_result
if isfolder(root)
    rmdir(root, 's');
end
rehash path;
end

function restore_test_state(originalFolder, originalPath, originalWarnings, ...
        originalRng, figuresBefore)
diary off;
evalin('base', 'clear;');
path(originalPath);
warning(originalWarnings);
rng(originalRng);
figuresAfter = findall(groot, 'Type', 'figure');
createdFigures = figuresAfter(~ismember(figuresAfter, figuresBefore));
for figureIndex = 1:numel(createdFigures)
    close_if_graphics(createdFigures(figureIndex));
end
if isfolder(originalFolder)
    cd(originalFolder);
end
clear log_command_window NRFUtils collect_guardrail_event_series ...
    plot_guardrail_average_ts plot_guardrail_average_tf ...
    plot_guardrail_average_psd load_guardrail_separation_result bootci
if isappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript')
    rmappdata(groot, 'SimpleStrasbourgStep81DiaryClosedByScript');
end
rehash path;
end

function tf = same_figure_inventory(leftFigures, rightFigures)
tf = numel(leftFigures) == numel(rightFigures) && ...
    all(ismember(leftFigures, rightFigures)) && ...
    all(ismember(rightFigures, leftFigures));
end
