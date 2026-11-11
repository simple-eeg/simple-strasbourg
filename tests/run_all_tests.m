function results = run_all_tests(repoRoot, eeglabRoot)
%RUN_ALL_TESTS Run the self-contained synthetic SIMPLE regression suite.

arguments
    repoRoot (1,:) char
    eeglabRoot (1,:) char
end

testsRoot = fileparts(mfilename('fullpath'));
functionsRoot = fullfile(repoRoot, 'functions');
templatesRoot = fullfile(repoRoot, 'NRFs');
fixturePath = fullfile(testsRoot, 'fixtures', ...
    'simple_scientific_oracle_v1.mat');
assert(isfile(fixturePath));
loaded = load(fixturePath, 'oracle');
oracle = loaded.oracle;
assert(strcmp(oracle.schema, 'simple-scientific-oracle-v1'));
assert(oracle.passed);

originalPath = path;
pathCleanup = onCleanup(@() path(originalPath)); %#ok<NASGU>
figuresBefore = findall(groot, 'Type', 'figure');
warningState = warning;
warningCleanup = onCleanup(@() warning(warningState)); %#ok<NASGU>

restoredefaultpath;
addpath(eeglabRoot, '-begin');
eeglab nogui;
eeglab_options;
assert(strcmp(version('-release'), '2026a'));
assert(contains(version, 'Update 4'));
assert(strcmp(eeg_getversion, '2026.0.0'));
assert(~option_storedisk && ~option_parallel);

% EEGLAB may load plug-ins after its own startup. Repository functions must
% therefore be added last at path precedence and resolved canonically.
addpath(testsRoot, '-begin');
addpath(functionsRoot, '-begin');
clear preproc estimate_response jittercorrect quality_control_features ...
    validate_dataset_registry_paths run_dataset_registry_path_tests ...
    load_dataset_identity_registry build_pseudonymised_dataset_registry ...
    inspect_identity_state inspect_pseudonymisation_inputs ...
    run_pseudonymisation_transaction ...
    run_sanitisation_transaction sanitise_eeglab_dataset ...
    verify_sanitised_eeglab_dataset run_step2_identity_tests ...
    run_step2_sanitisation_tests run_step2_downstream_identity_tests ...
    run_processing_state_tests run_step8_check_plot_tests
rehash path;
assert_path(which('preproc'), fullfile(functionsRoot, 'preproc.m'));
assert_path(which('estimate_response'), ...
    fullfile(functionsRoot, 'estimate_response.m'));
assert_path(which('jittercorrect'), fullfile(functionsRoot, 'jittercorrect.m'));
assert_path(which('quality_control_features'), ...
    fullfile(functionsRoot, 'quality_control_features.m'));
assert_path(which('validate_dataset_registry_paths'), ...
    fullfile(functionsRoot, 'validate_dataset_registry_paths.m'));
assert_path(which('run_dataset_registry_path_tests'), ...
    fullfile(testsRoot, 'run_dataset_registry_path_tests.m'));
assert_path(which('load_dataset_identity_registry'), ...
    fullfile(functionsRoot, 'load_dataset_identity_registry.m'));
assert_path(which('build_pseudonymised_dataset_registry'), ...
    fullfile(functionsRoot, 'build_pseudonymised_dataset_registry.m'));
assert_path(which('inspect_identity_state'), ...
    fullfile(functionsRoot, 'inspect_identity_state.m'));
assert_path(which('inspect_pseudonymisation_inputs'), ...
    fullfile(functionsRoot, 'inspect_pseudonymisation_inputs.m'));
assert_path(which('run_pseudonymisation_transaction'), ...
    fullfile(functionsRoot, 'run_pseudonymisation_transaction.m'));
assert_path(which('run_sanitisation_transaction'), ...
    fullfile(functionsRoot, 'run_sanitisation_transaction.m'));
assert_path(which('sanitise_eeglab_dataset'), ...
    fullfile(functionsRoot, 'sanitise_eeglab_dataset.m'));
assert_path(which('verify_sanitised_eeglab_dataset'), ...
    fullfile(functionsRoot, 'verify_sanitised_eeglab_dataset.m'));
assert_path(which('run_step2_identity_tests'), ...
    fullfile(testsRoot, 'run_step2_identity_tests.m'));
assert_path(which('run_step2_sanitisation_tests'), ...
    fullfile(testsRoot, 'run_step2_sanitisation_tests.m'));
assert_path(which('run_step2_downstream_identity_tests'), ...
    fullfile(testsRoot, 'run_step2_downstream_identity_tests.m'));
assert_path(which('run_processing_state_tests'), ...
    fullfile(testsRoot, 'run_processing_state_tests.m'));
assert_path(which('run_step8_check_plot_tests'), ...
    fullfile(testsRoot, 'run_step8_check_plot_tests.m'));

assert_template_inventory(oracle.templates, templatesRoot);
basePath = path;
results = struct();
results.schema = 'simple-strasbourg-tests-v1';
results.preproc = run_preproc_oracles(oracle.preproc, testsRoot, ...
    functionsRoot, basePath);
path(basePath);
results.response = run_response_oracles(oracle.response, functionsRoot);
results.jitter = run_jitter_oracles(oracle.jitter, functionsRoot);
results.qc = run_qc_oracles(oracle.qc, functionsRoot);
results.clean_contract = run_clean_contract_tests(repoRoot, oracle);
results.registry = run_dataset_registry_path_tests(repoRoot);
results.step2_identity = run_step2_identity_tests(repoRoot);
results.step2_sanitisation = run_step2_sanitisation_tests(repoRoot);
results.step2_downstream_identity = ...
    run_step2_downstream_identity_tests(repoRoot);
results.processing_state = run_processing_state_tests(repoRoot);
results.step8_check_plot = run_step8_check_plot_tests(repoRoot);
path(basePath);
results.extended = run_extended_contract_tests(repoRoot, eeglabRoot, ...
    testsRoot, functionsRoot, templatesRoot, basePath, oracle);
results.figures_unchanged = isequal(figuresBefore, ...
    findall(groot, 'Type', 'figure'));
assert(results.figures_unchanged, 'Synthetic tests changed the figure set.');
results.passed = true;
fprintf(['SIMPLE STRASBOURG SYNTHETIC TESTS PASSED: preproc=%d, response=%d, ' ...
    'jitter=%d, qc=%d, registry=%d, step2_identity=%d, ' ...
    'step2_sanitisation=%d, step2_downstream_identity=%d, ' ...
    'processing_state=%d, ' ...
    'step8_check_plot=%d, extended=%d\n'], ...
    results.preproc, results.response, results.jitter, results.qc, ...
    results.registry, results.step2_identity.total, ...
    results.step2_sanitisation.total, ...
    results.step2_downstream_identity.total, ...
    results.processing_state.total, ...
    results.step8_check_plot.total, results.extended.total);
end

function passed = run_preproc_oracles(cases, testsRoot, functionsRoot, basePath)
passed = 0;
for idx = 1:numel(cases)
    testCase = cases(idx);
    path(basePath);
    clear preproc pop_cleanline pop_epoch pop_eegfiltnew pop_rmbase
    rehash path;
    switch testCase.name
        case 'filter_empty_command'
            addpath(fullfile(testsRoot, 'stubs', ...
                'filter_empty_command'), '-begin');
            clear pop_eegfiltnew
            rehash path;
        case 'cleanline_empty_command'
            addpath(fullfile(testsRoot, 'stubs', 'cleanline_empty'), '-begin');
            clear pop_cleanline
            rehash path;
        case 'cleanline_undefined_fallback'
            cleanlinePaths = which_all('pop_cleanline');
            for pathIdx = 1:numel(cleanlinePaths)
                remove_canonical_path(fileparts(cleanlinePaths{pathIdx}));
            end
            clear pop_cleanline
            rehash path;
            assert(isempty(which('pop_cleanline')));
        case 'cleanline_other_error'
            addpath(fullfile(testsRoot, 'stubs', 'cleanline_error'), '-begin');
            clear pop_cleanline
            rehash path;
        case 'epoch_other_error'
            addpath(fullfile(testsRoot, 'stubs', 'epoch_error'), '-begin');
            clear pop_epoch
            rehash path;
        case 'epoch_empty_command'
            addpath(fullfile(testsRoot, 'stubs', ...
                'epoch_empty_command'), '-begin');
            clear pop_epoch
            rehash path;
        case 'baseline_other_error'
            addpath(fullfile(testsRoot, 'stubs', 'baseline_error'), '-begin');
            clear pop_rmbase
            rehash path;
    end
    assert_path(which('preproc'), fullfile(functionsRoot, 'preproc.m'));
    warningConfiguration = warning;
    [output, failure, console, warningMessage, warningIdentifier] = ...
        invoke_preproc(testCase);
    assert(isequal(warningConfiguration, warning), ...
        'Preproc warning configuration was not restored for %s.', ...
        testCase.name);
    assert(strcmp(failure.identifier, testCase.error_identifier), ...
        'Preproc error identifier differs for %s.', testCase.name);
    assert(strcmp(failure.message, testCase.error_message), ...
        'Preproc error message differs for %s.', testCase.name);
    assert(strcmp(warningMessage, testCase.warning_message), ...
        'Preproc warning message differs for %s.', testCase.name);
    assert(strcmp(warningIdentifier, testCase.warning_identifier), ...
        'Preproc warning identifier differs for %s.', testCase.name);
    for tokenIdx = 1:numel(testCase.console)
        assert(contains(console, testCase.console{tokenIdx}, ...
            'IgnoreCase', true), 'Missing warning text for %s: %s', ...
            testCase.name, testCase.console{tokenIdx});
    end
    if isempty(testCase.error_identifier) && isempty(testCase.error_message)
        assert(isequaln(output, testCase.output), ...
            'Preproc output differs for %s.', testCase.name);
    else
        assert(isempty(output), 'Failing preproc case returned output: %s', ...
            testCase.name);
    end
    passed = passed + 1;
end
path(basePath);
end

function [output, failure, console, warningMessage, warningIdentifier] = ...
    invoke_preproc(testCase)
lastwarn('', '');
output = [];
failure = struct('identifier', '', 'message', '');
try
    if strcmp(testCase.name, 'no_arguments')
        console = evalc('preproc();');
    elseif strcmp(testCase.name, 'options_required')
        console = evalc('output = preproc(testCase.input);');
    else
        console = evalc('output = preproc(testCase.input, testCase.options);');
    end
catch ME
    failure.identifier = ME.identifier;
    failure.message = ME.message;
    console = ME.message;
end
[warningMessage, warningIdentifier] = lastwarn;
end

function passed = run_response_oracles(response, functionsRoot)
passed = 0;
for idx = 1:numel(response.cases)
    testCase = response.cases(idx);
    clear estimate_response jittercorrect
    rehash path;
    assert_path(which('estimate_response'), ...
        fullfile(functionsRoot, 'estimate_response.m'));
    failure = struct('identifier', '', 'message', '');
    output = [];
    try
        if strcmp(testCase.name, 'options_required')
            output = estimate_response(testCase.input);
        else
            output = estimate_response(testCase.input, testCase.options);
        end
    catch ME
        failure.identifier = ME.identifier;
        failure.message = ME.message;
    end
    assert(strcmp(failure.identifier, testCase.error_identifier), ...
        'Response error identifier differs for %s.', testCase.name);
    assert(strcmp(failure.message, testCase.error_message), ...
        'Response error message differs for %s.', testCase.name);
    if isempty(testCase.error_identifier) && isempty(testCase.error_message)
        assert(isequaln(output, testCase.output), ...
            'Response output differs for %s.', testCase.name);
        if ~isempty(fieldnames(testCase.numeric_input))
            assert_numeric_mapping(output, testCase.options.NRFName, ...
                testCase.numeric_output);
        end
    else
        assert(isempty(output), 'Failing response case returned output: %s', ...
            testCase.name);
    end
    passed = passed + 1;
end
end

function assert_numeric_mapping(EEG, templateName, numericOutput)
fit = EEG.epoch(1).(templateName);
actual = {fit.pearsonR, fit.shifted_data_all, fit.shift_all, ...
    fit.NRF_resampled, fit.cosineSimilarity, fit.fglsCoef, ...
    fit.fglsVarCoef, fit.olsCoef};
assert(numel(actual) == numel(numericOutput));
for idx = 1:numel(actual)
    assert(isequaln(actual{idx}, numericOutput{idx}), ...
        'Private numerical mapping differs for %s output %d.', ...
        templateName, idx);
end
end

function passed = run_jitter_oracles(cases, functionsRoot)
passed = 0;
for idx = 1:numel(cases)
    testCase = cases(idx);
    clear jittercorrect
    rehash path;
    assert_path(which('jittercorrect'), ...
        fullfile(functionsRoot, 'jittercorrect.m'));
    output = cell(1, 3);
    failure = struct('identifier', '', 'message', '');
    try
        [output{:}] = jittercorrect(testCase.data, testCase.NRF, ...
            testCase.fs, testCase.fs_NRF, testCase.jitter_ms, ...
            testCase.start_ms);
    catch ME
        output = {};
        failure.identifier = ME.identifier;
        failure.message = ME.message;
    end
    assert(strcmp(failure.identifier, testCase.error_identifier), ...
        'Jitter error identifier differs for %s.', testCase.name);
    assert(strcmp(failure.message, testCase.error_message), ...
        'Jitter error message differs for %s.', testCase.name);
    assert(isequaln(output, testCase.output), ...
        'Jitter outputs differ for %s.', testCase.name);
    passed = passed + 1;
end
end

function passed = run_qc_oracles(qc, functionsRoot)
passed = 0;
for idx = 1:numel(qc.coordinator)
    testCase = qc.coordinator(idx);
    clear quality_control_features
    rehash path;
    assert_path(which('quality_control_features'), ...
        fullfile(functionsRoot, 'quality_control_features.m'));
    output = [];
    failure = struct('identifier', '', 'message', '');
    lastwarn('', '');
    try
        output = quality_control_features(testCase.input);
    catch ME
        failure.identifier = ME.identifier;
        failure.message = ME.message;
    end
    [warningMessage, warningIdentifier] = lastwarn;
    assert(strcmp(warningIdentifier, testCase.warning_identifier), ...
        'QC coordinator warning identifier differs for %s.', testCase.name);
    assert(strcmp(warningMessage, testCase.warning_message), ...
        'QC coordinator warning message differs for %s.', testCase.name);
    assert(strcmp(failure.identifier, testCase.error_identifier), ...
        'QC coordinator identifier differs for %s.', testCase.name);
    assert(strcmp(failure.message, testCase.error_message), ...
        'QC coordinator message differs for %s.', testCase.name);
    if isempty(testCase.error_identifier) && isempty(testCase.error_message)
        assert(isequaln(output, testCase.output), ...
            'QC coordinator output differs for %s.', testCase.name);
    else
        assert(isempty(output));
    end
    passed = passed + 1;
end

for idx = 1:numel(qc.direct)
    testCase = qc.direct(idx);
    value = [];
    failure = struct('identifier', '', 'message', '');
    lastwarn('', '');
    try
        value = feval(testCase.calculator, testCase.data, ...
            testCase.Fs, testCase.t_ms);
    catch ME
        failure.identifier = ME.identifier;
        failure.message = ME.message;
    end
    [warningMessage, warningIdentifier] = lastwarn;
    assert(strcmp(warningIdentifier, testCase.warning_identifier), ...
        'QC calculator warning identifier differs for %s/%s.', ...
        testCase.calculator, testCase.case_name);
    assert(strcmp(warningMessage, testCase.warning_message), ...
        'QC calculator warning message differs for %s/%s.', ...
        testCase.calculator, testCase.case_name);
    assert(strcmp(failure.identifier, testCase.error_identifier), ...
        'QC calculator identifier differs for %s/%s.', ...
        testCase.calculator, testCase.case_name);
    assert(strcmp(failure.message, testCase.error_message), ...
        'QC calculator message differs for %s/%s.', ...
        testCase.calculator, testCase.case_name);
    assert(isequaln(value, testCase.output), ...
        'QC calculator output differs for %s/%s.', ...
        testCase.calculator, testCase.case_name);
    passed = passed + 1;
end
end

function passed = run_clean_contract_tests(repoRoot, oracle)
passed = 0;
responseCases = oracle.response.cases;
defaultIdx = find(strcmp({responseCases.name}, ...
    'noxious_NRF_500Hz_post'), 1);
assert(~isempty(defaultIdx));
fixture = responseCases(defaultIdx).input;
explicitOptions = responseCases(defaultIdx).options;
defaultOutput = estimate_response(fixture, struct());
explicitOutput = estimate_response(fixture, explicitOptions);
assert(isequaln(defaultOutput, explicitOutput), ...
    'Empty response options do not equal the explicit clean defaults.');
passed = passed + 1;

validZeroPre = explicitOptions;
validZeroPre.projectionTimes_pre = 0;
validZeroPre.projectionTimes_post = [];
estimate_response(fixture, validZeroPre);
validZeroPost = explicitOptions;
validZeroPost.projectionTimes_pre = [];
validZeroPost.projectionTimes_post = 0;
estimate_response(fixture, validZeroPost);
passed = passed + 2;

invalid = { ...
    [], [], 'both_empty'; ...
    -400, 400, 'both_supplied'; ...
    [-400 -200], [], 'pre_vector'; ...
    [], [200 400], 'post_vector'; ...
    100, [], 'positive_pre'; ...
    [], -100, 'negative_post'; ...
    NaN, [], 'pre_nan'; ...
    [], Inf, 'post_inf'; ...
    1i, [], 'pre_complex'; ...
    true, [], 'pre_logical'; ...
    'minus400', [], 'pre_text'};
for idx = 1:size(invalid, 1)
    options = explicitOptions;
    options.projectionTimes_pre = invalid{idx, 1};
    options.projectionTimes_post = invalid{idx, 2};
    assert_error_id(@() estimate_response(fixture, options), ...
        'SIMPLE:estimate_response:InvalidProjectionTimes', invalid{idx, 3});
    passed = passed + 1;
end

templatePath = fullfile(repoRoot, 'NRFs', 'noxious_NRF_500Hz.mat');
pathOptions = explicitOptions;
pathOptions.NRFName = templatePath;
pathOutput = estimate_response(fixture, pathOptions);
assert(isequaln(clear_history(explicitOutput), clear_history(pathOutput)), ...
    'Logical and explicit template paths differ outside history.');
assert(isfield(pathOutput.epoch(1), 'noxious_NRF_500Hz'));
passed = passed + 1;

shadowRoot = tempname;
mkdir(shadowRoot);
shadowCleanup = onCleanup(@() remove_tree(shadowRoot)); %#ok<NASGU>
NRF = zeros(10, 1); %#ok<NASGU>
fs = 500; %#ok<NASGU>
save(fullfile(shadowRoot, 'noxious_NRF_500Hz.mat'), 'NRF', 'fs');
addpath(shadowRoot, '-begin');
shadowPathCleanup = onCleanup(@() rmpath_if_present(shadowRoot)); %#ok<NASGU>
shadowOutput = estimate_response(fixture, explicitOptions);
assert(isequaln(explicitOutput, shadowOutput), ...
    'An ambient same-named template altered logical repository binding.');
passed = passed + 1;

assert_any_error(@() estimate_response(fixture, struct(), 'unexpected'), ...
    'estimate_response accepted an unsupported argument count.');
passed = passed + 1;

publicEntries = {'preproc','estimate_response','jittercorrect', ...
    'quality_control_features', 'validate_dataset_registry_paths'};
for idx = 1:numel(publicEntries)
    assert_path(which(publicEntries{idx}), fullfile(repoRoot, 'functions', ...
        [publicEntries{idx} '.m']));
end
passed = passed + 1;
end

function result = run_extended_contract_tests(repoRoot, eeglabRoot, ...
    testsRoot, functionsRoot, templatesRoot, basePath, oracle)
% Finite semantic and system-boundary coverage for the repository APIs.
result = struct();
result.events = run_event_contract_tests();
result.response = run_response_semantic_tests(repoRoot, oracle);
result.resolver = run_resolver_and_template_tests(repoRoot, templatesRoot, ...
    oracle);
result.config_cache = run_config_and_cache_tests(repoRoot, oracle);
result.overlay = run_overlay_tests(repoRoot, testsRoot, templatesRoot);
result.jitter = run_jitter_semantic_tests(oracle.jitter);
result.qc = run_qc_semantic_tests(oracle.qc);
result.diagnostics = run_diagnostic_wrapper_tests(oracle.qc);
result.dependencies = run_dependency_boundary_tests(eeglabRoot, testsRoot, ...
    functionsRoot, basePath, oracle);
result.logger = run_isolated_logger_test(repoRoot, testsRoot, basePath);
result.preproc = run_preproc_extended_tests(oracle.preproc);
result.total = result.events + result.response + result.resolver + ...
    result.config_cache + result.overlay + result.jitter + result.qc + ...
    result.diagnostics + result.dependencies + result.logger + ...
    result.preproc;
path(basePath);
clear corr fgls robustfit eeg_checkset log_command_window logger_probe
rehash path;
end

function passed = run_preproc_extended_tests(preprocCases)
passed = 0;
fixtureIdx = find(arrayfun(@(x) ~isempty(x.input), preprocCases), 1);
assert(~isempty(fixtureIdx));
emptyEEG = repmat(preprocCases(fixtureIdx).input, 0, 1);
assert_any_error(@() preproc(emptyEEG, struct()), ...
    'An empty EEG struct array was not rejected.');
passed = passed + 1;
end

function passed = run_event_contract_tests()
passed = 0;

emptyEEG = rmfield(make_event_fixture(), 'event');
[emptyOut, emptyReport] = add_offset_events(emptyEEG, 'sourceA', 100, ...
    'targetA');
assert(isequaln(emptyOut, emptyEEG));
assert(emptyReport.total_before == 0 && emptyReport.total_after == 0 && ...
    emptyReport.added_count == 0);
passed = passed + 1;

EEG = make_event_fixture();
[noSourceOut, noSourceReport] = add_offset_events(EEG, 'absent', 100, ...
    'absent_offset');
assert(isequaln(noSourceOut, EEG));
assert(noSourceReport.added_count == 0 && ...
    isequal(noSourceReport.missing_sources, {'absent'}));
passed = passed + 1;

[added, report] = add_offset_events(EEG, ...
    {'sourceA', 'sourceB', 'missing'}, 100, ...
    {'targetA', 'targetB', 'targetMissing'});
assert(report.total_before == 4 && report.added_count == 2 && ...
    report.total_after == 6 && report.skipped_oob_count == 0);
assert(isequal(report.missing_sources, {'missing'}));
assert(report.per_type_added.targetA == 1 && ...
    report.per_type_added.targetB == 1 && ...
    report.per_type_added.targetMissing == 0);
types = normalize_event_types(added.event);
assert(sum(strcmp(types, 'targetA')) == 2, ...
    'An existing target event was overwritten or suppressed.');
newIndex = find(strcmp(types, 'targetA') & ...
    [added.event.latency] == 30, 1);
assert(~isempty(newIndex));
assert(isequal(added.event(newIndex).annotation, ...
    {'manually_added_dummy'}));
assert(strcmp(added.event(newIndex).urtype, 'NA'));
assert(isnan(added.event(newIndex).urlatency));
assert(isempty(added.event(newIndex).duration) || ...
    isequal(added.event(newIndex).duration, 0));
passed = passed + 1;

oobEEG = make_event_fixture();
oobEEG.event = oobEEG.event(1);
oobEEG.event.latency = 95;
[skipped, skipReport] = add_offset_events(oobEEG, 'sourceA', 100, ...
    'targetA', [], []);
assert(isequaln(skipped, oobEEG));
assert(skipReport.added_count == 0 && ...
    skipReport.skipped_oob_count == 1);
[allowed, allowReport] = add_offset_events(oobEEG, 'sourceA', 100, ...
    'targetA', {'synthetic'}, 'allow_oob');
assert(allowReport.added_count == 1 && ...
    allowReport.skipped_oob_count == 0);
assert(any(strcmp(normalize_event_types(allowed.event), 'targetA') & ...
    [allowed.event.latency] == 105));
negativeOobEEG = oobEEG;
negativeOobEEG.event.latency = 5;
[negativeAllowed, negativeReport] = add_offset_events(negativeOobEEG, ...
    'sourceA', -100, 'targetA', [], 'allow_oob');
assert(negativeReport.added_count == 1 && ...
    negativeReport.skipped_oob_count == 0);
assert(any(strcmp(normalize_event_types(negativeAllowed.event), ...
    'targetA') & [negativeAllowed.event.latency] == -5));
assert_error_id(@() add_offset_events(oobEEG, 'sourceA', 100, ...
    'targetA', [], 'unknown'), 'add_offset_events:BadPolicy', ...
    'offset bad policy');
assert_error_id(@() add_offset_events(EEG, 'sourceA', 1, ...
    'targetA', [], 'unknown'), 'add_offset_events:BadPolicy', ...
    'offset bad in-bounds policy');
epochedOobEEG = oobEEG;
epochedOobEEG.pnts = 50;
epochedOobEEG.trials = 2;
epochedOobEEG.data = zeros(1, 50, 2);
assert_error_id(@() add_offset_events(epochedOobEEG, 'sourceA', ...
    100, 'targetA', [], 'allow_oob'), ...
    'add_offset_events:AllowOobRequiresContinuous', ...
    'epoched allow-oob policy');
[epochedSkipped, epochedSkipReport] = add_offset_events( ...
    epochedOobEEG, 'sourceA', 100, 'targetA', [], 'skip_oob');
assert(isequaln(epochedSkipped, epochedOobEEG) && ...
    epochedSkipReport.skipped_oob_count == 1);
passed = passed + 7;

badRate = EEG;
badRate.srate = 0;
assert_error_id(@() add_offset_events(badRate, 'sourceA', 1, 'x'), ...
    'add_offset_events:InvalidSRate', 'offset invalid srate');
assert_error_id(@() add_offset_events(EEG, 'sourceA', Inf, 'x'), ...
    'add_offset_events:InvalidOffset', 'offset invalid scalar');
textRate = EEG;
textRate.srate = 'x';
assert_error_id(@() add_offset_events(textRate, 'sourceA', 1, 'x'), ...
    'add_offset_events:InvalidSRate', 'offset text srate');
complexRate = EEG;
complexRate.srate = 100i;
assert_error_id(@() add_offset_events(complexRate, 'sourceA', 1, 'x'), ...
    'add_offset_events:InvalidSRate', 'offset complex srate');
logicalRate = EEG;
logicalRate.srate = true;
assert_error_id(@() add_offset_events(logicalRate, 'sourceA', 1, 'x'), ...
    'add_offset_events:InvalidSRate', 'offset logical srate');
assert_error_id(@() add_offset_events(EEG, 'sourceA', 'x', 'x'), ...
    'add_offset_events:InvalidOffset', 'offset text offset');
assert_error_id(@() add_offset_events(EEG, 'sourceA', 1i, 'x'), ...
    'add_offset_events:InvalidOffset', 'offset complex offset');
assert_error_id(@() add_offset_events(EEG, 'sourceA', true, 'x'), ...
    'add_offset_events:InvalidOffset', 'offset logical offset');
assert_error_id(@() add_offset_events(EEG, {'sourceA','sourceB'}, 1, ...
    {'x'}), 'add_offset_events:TypeListMismatch', ...
    'offset mismatched mappings');
[numericLabelOutput, numericLabelReport] = add_offset_events(EEG, ...
    'sourceA', 1, {7});
assert(numericLabelReport.per_type_added.x7 == 1);
assert(any(strcmp(normalize_event_types(numericLabelOutput.event), '7')));
collisionEEG = EEG;
collisionEEG.event = collisionEEG.event(1:2);
[collisionOutput, collisionReport] = add_offset_events(collisionEEG, ...
    {'sourceA','sourceB'}, 1, {'a-b','a_b'});
collisionFields = fieldnames(collisionReport.per_type_added);
assert(numel(collisionFields) == 2 && ...
    all(cellfun(@isvarname, collisionFields)) && ...
    all(startsWith(collisionFields, 'a_b')));
assert(all(structfun(@(value) value == 1, ...
    collisionReport.per_type_added)));
collisionTypes = normalize_event_types(collisionOutput.event);
assert(any(strcmp(collisionTypes, 'a-b')) && ...
    any(strcmp(collisionTypes, 'a_b')));
keywordEEG = EEG;
keywordEEG.event = keywordEEG.event(1);
[keywordOutput, keywordReport] = add_offset_events(keywordEEG, ...
    'sourceA', 1, 'end');
keywordFields = fieldnames(keywordReport.per_type_added);
assert(numel(keywordFields) == 1 && isvarname(keywordFields{1}) && ...
    keywordReport.per_type_added.(keywordFields{1}) == 1);
assert(any(strcmp(normalize_event_types(keywordOutput.event), 'end')));
assert_error_id(@() add_offset_events(EEG, ...
    {'sourceA','sourceA'}, 1, {'targetA','targetB'}), ...
    'add_offset_events:TypeMappingConflict', ...
    'duplicate source conflicting target mapping');
[sharedOutput, sharedReport] = add_offset_events(EEG, ...
    {'sourceA','sourceB'}, 1, {'shared','shared'});
assert(sharedReport.added_count == 2 && ...
    sharedReport.per_type_added.shared == 2);
assert(sum(strcmp(normalize_event_types(sharedOutput.event), 'shared')) == 2);
integerEEG = EEG;
integerEEG.srate = uint16(100);
[integerOutput, integerReport] = add_offset_events(integerEEG, ...
    'sourceA', int16(100), 'integer_target');
[doubleOutput, doubleReport] = add_offset_events(EEG, ...
    'sourceA', 100, 'integer_target');
integerOutput.srate = double(integerOutput.srate);
assert(isequaln(integerOutput, doubleOutput) && ...
    isequaln(integerReport, doubleReport));
passed = passed + 15;

noEventEEG = rmfield(EEG, 'event');
[deletedEmpty, emptyDeleteReport] = delete_unwanted_events(noEventEEG);
assert(isequaln(deletedEmpty, noEventEEG));
assert(emptyDeleteReport.removed_count == 0 && ...
    isequal(emptyDeleteReport.labels_requested, {'na'}));
passed = passed + 1;

deleteEEG = EEG;
deleteEEG.event(1).type = ' NA ';
deleteEEG.event(2).type = "bad";
deleteEEG.event(3).type = 7;
deleteEEG.event(4).type = 'bad-extra';
[deleted, deleteReport] = delete_unwanted_events(deleteEEG, ...
    {'na', 'BAD', 7, 'bad'});
remaining = normalize_event_types(deleted.event);
assert(isequal(remaining, {'bad-extra'}));
assert(deleteReport.total_before == 4 && ...
    deleteReport.removed_count == 3 && deleteReport.total_after == 1);
assert(deleteReport.removed_by_label.na == 1 && ...
    deleteReport.removed_by_label.bad == 1 && ...
    deleteReport.removed_by_label.x7 == 1);
assert(isequal(deleteReport.labels_requested, {'na','bad','7'}));
passed = passed + 1;

deleteCollisionEEG = EEG;
deleteCollisionEEG.event = deleteCollisionEEG.event(1:2);
deleteCollisionEEG.event(1).type = 'a-b';
deleteCollisionEEG.event(2).type = 'a_b';
[deleteCollisionOutput, deleteCollisionReport] = ...
    delete_unwanted_events(deleteCollisionEEG, {'a-b','a_b'});
assert(isempty(deleteCollisionOutput.event));
deleteCollisionFields = fieldnames(deleteCollisionReport.removed_by_label);
assert(numel(deleteCollisionFields) == 2 && ...
    all(cellfun(@isvarname, deleteCollisionFields)) && ...
    all(startsWith(deleteCollisionFields, 'a_b')));
assert(all(structfun(@(value) value == 1, ...
    deleteCollisionReport.removed_by_label)));
passed = passed + 1;

deleteKeywordEEG = EEG;
deleteKeywordEEG.event = deleteKeywordEEG.event(1);
deleteKeywordEEG.event.type = 'end';
[deleteKeywordOutput, deleteKeywordReport] = ...
    delete_unwanted_events(deleteKeywordEEG, 'end');
deleteKeywordFields = fieldnames(deleteKeywordReport.removed_by_label);
assert(isempty(deleteKeywordOutput.event) && ...
    numel(deleteKeywordFields) == 1 && ...
    isvarname(deleteKeywordFields{1}) && ...
    deleteKeywordReport.removed_by_label.(deleteKeywordFields{1}) == 1);
passed = passed + 1;

[unchanged, noMatchReport] = delete_unwanted_events(EEG, 'absent');
assert(isequaln(unchanged, EEG) && noMatchReport.removed_count == 0);
[emptyLabels, emptyLabelsReport] = delete_unwanted_events(EEG, 42);
assert(isequaln(emptyLabels, EEG) && ...
    isempty(emptyLabelsReport.labels_requested));
passed = passed + 2;
end

function EEG = make_event_fixture()
EEG = eeg_emptyset;
EEG.data = zeros(1, 100);
EEG.nbchan = 1;
EEG.pnts = 100;
EEG.trials = 1;
EEG.srate = 100;
EEG.xmin = 0;
EEG.xmax = 0.99;
EEG.times = 0:10:990;
EEG.chanlocs = struct('labels', 'Cz');
prototype = struct('type', '', 'latency', 1, ...
    'annotation', {{'original'}}, 'urtype', 1, 'urlatency', 1, ...
    'duration', 0);
EEG.event = repmat(prototype, 1, 4);
EEG.event(1).type = 'sourceA'; EEG.event(1).latency = 20;
EEG.event(2).type = 'sourceB'; EEG.event(2).latency = 50;
EEG.event(3).type = 'targetA'; EEG.event(3).latency = 70;
EEG.event(4).type = 'other';   EEG.event(4).latency = 80;
end

function types = normalize_event_types(events)
types = cell(1, numel(events));
for idx = 1:numel(events)
    value = events(idx).type;
    if iscell(value), value = value{1}; end
    if isstring(value), value = char(value); end
    if isnumeric(value), value = num2str(value); end
    types{idx} = strtrim(value);
end
end

function passed = run_response_semantic_tests(repoRoot, oracle)
passed = 0;
[fixture, explicitOptions] = default_response_fixture(oracle);

badTrials = fixture;
badTrials.trials = 1;
assert_error_id(@() estimate_response(badTrials, explicitOptions), ...
    'SIMPLE:estimate_response:InsufficientEpochs', ...
    'trials independently insufficient');
badEpochs = fixture;
badEpochs.epoch = badEpochs.epoch(1);
assert_error_id(@() estimate_response(badEpochs, explicitOptions), ...
    'SIMPLE:estimate_response:InsufficientEpochs', ...
    'epoch metadata independently insufficient');
passed = passed + 2;

altFixture = add_synthetic_channel(fixture, 'ALT');
partialOptions = struct('channel', 'ALT');
fullOptions = explicitOptions;
fullOptions.channel = 'ALT';
partialOutput = estimate_response(altFixture, partialOptions);
fullOutput = estimate_response(altFixture, fullOptions);
assert(isequaln(clear_history(partialOutput), clear_history(fullOutput)), ...
    'Partial options did not receive the documented clean defaults.');
assert(isequal({partialOutput.chanlocs.labels}, {'ALT'}));
assert(contains(partialOutput.history, 'estimate_response(EEG,') && ...
    contains(partialOutput.history, 'ALT'));
passed = passed + 1;

output = estimate_response(fixture, explicitOptions);
fitFields = {'projectionTimes','pearsonR','shifted_data_all','shift_all', ...
    'NRF_resampled','cosineSimilarity','fglsCoef','fglsVarCoef','olsCoef'};
logicalName = explicitOptions.NRFName;
for epochIndex = 1:numel(output.epoch)
    assert(isfield(output.epoch(epochIndex), logicalName));
    fit = output.epoch(epochIndex).(logicalName);
    assert(isequal(sort(fieldnames(fit)), sort(fitFields(:))));
    assert(isscalar(fit.projectionTimes) && ...
        fit.projectionTimes == explicitOptions.projectionTimes_post);
    assert(iscell(fit.shifted_data_all) && ...
        numel(fit.shifted_data_all) == 1);
    numericFields = setdiff(fitFields, ...
        {'projectionTimes','shifted_data_all','NRF_resampled'});
    for fieldIndex = 1:numel(numericFields)
        assert(isnumeric(fit.(numericFields{fieldIndex})) && ...
            isscalar(fit.(numericFields{fieldIndex})));
    end
end
assert(contains(output.history, 'estimate_response(EEG,'));
passed = passed + 1;

arrayOutput = estimate_response([fixture fixture], explicitOptions);
assert(numel(arrayOutput) == 2);
for datasetIndex = 1:2
    assert(isfield(arrayOutput(datasetIndex).epoch(1), logicalName));
end
passed = passed + 1;

offGrid = explicitOptions;
offGrid.projectionTimes_post = explicitOptions.projectionTimes_post + 0.5;
assert_error_id(@() estimate_response(fixture, offGrid), ...
    'SIMPLE:estimate_response:ProjectionOffSampleGrid', ...
    'post-event off-grid projection');
offGridPre = explicitOptions;
offGridPre.projectionTimes_pre = -400.5;
offGridPre.projectionTimes_post = [];
assert_error_id(@() estimate_response(fixture, offGridPre), ...
    'SIMPLE:estimate_response:ProjectionOffSampleGrid', ...
    'pre-event off-grid projection');
outOfBounds = explicitOptions;
outOfBounds.projectionTimes_post = 1e6;
assert_error_id(@() estimate_response(fixture, outOfBounds), ...
    'SIMPLE:estimate_response:ProjectionOutOfBounds', ...
    'upper response window bound');
lowerBound = explicitOptions;
lowerBound.projectionTimes_pre = double(fixture.xmin) * 1000;
lowerBound.projectionTimes_post = [];
assert_error_id(@() estimate_response(fixture, lowerBound), ...
    'SIMPLE:estimate_response:ProjectionOutOfBounds', ...
    'lower response window bound');
passed = passed + 4;

badRate = fixture;
badRate.srate = '500';
assert_error_id(@() estimate_response(badRate, explicitOptions), ...
    'SIMPLE:estimate_response:InvalidSamplingRate', ...
    'invalid response sampling rate');
badOrigin = fixture;
badOrigin.xmin = NaN;
assert_error_id(@() estimate_response(badOrigin, explicitOptions), ...
    'SIMPLE:estimate_response:InvalidTimeOrigin', ...
    'invalid response time origin');
passed = passed + 2;

invalidJitter = {-1, NaN, true};
for idx = 1:numel(invalidJitter)
    options = explicitOptions;
    options.jitter = invalidJitter{idx};
    assert_error_id(@() estimate_response(fixture, options), ...
        'SIMPLE:estimate_response:InvalidJitter', ...
        sprintf('invalid jitter %d', idx));
    passed = passed + 1;
end
invalidBaseline = {-1, Inf, true};
for idx = 1:numel(invalidBaseline)
    options = explicitOptions;
    options.baselineLength = invalidBaseline{idx};
    assert_error_id(@() estimate_response(fixture, options), ...
        'SIMPLE:estimate_response:InvalidBaselineLength', ...
        sprintf('invalid baseline %d', idx));
    passed = passed + 1;
end
invalidChannels = {'', {'Cz'}, ["Cz","ALT"]};
for idx = 1:numel(invalidChannels)
    options = explicitOptions;
    options.channel = invalidChannels{idx};
    assert_error_id(@() estimate_response(fixture, options), ...
        'SIMPLE:estimate_response:InvalidChannel', ...
        sprintf('invalid channel %d', idx));
    passed = passed + 1;
end
stringChannel = explicitOptions;
stringChannel.channel = string(explicitOptions.channel);
stringOutput = estimate_response(fixture, stringChannel);
charOutput = estimate_response(fixture, explicitOptions);
assert(isequaln(clear_history(stringOutput), clear_history(charOutput)));
passed = passed + 1;

integerRateFixture = fixture;
integerRateFixture.srate = uint16(fixture.srate);
integerRateOutput = estimate_response(integerRateFixture, explicitOptions);
integerRateOutput.srate = double(integerRateOutput.srate);
assert(isequaln(integerRateOutput, charOutput), ...
    'An equal-valued integer sampling rate changed scientific output.');
passed = passed + 1;

nearGrid = explicitOptions;
sampleDelta = 5e-10;
nearGrid.projectionTimes_post = ...
    explicitOptions.projectionTimes_post + ...
    sampleDelta * 1000 / double(fixture.srate);
lastwarn('', '');
console = evalc('nearGridOutput = estimate_response(fixture, nearGrid);');
[warningMessage, warningIdentifier] = lastwarn;
assert(isempty(warningMessage) && isempty(warningIdentifier));
assert(~contains(console, 'Warning:', 'IgnoreCase', true));
assert(isequaln(nearGridOutput, charOutput), ...
    ['A within-tolerance start was not emitted canonically as the exact ' ...
    'sample-grid projection.']);
passed = passed + 1;

assert(isfile(fullfile(repoRoot, 'NRFs', [logicalName '.mat'])));
end

function EEG = add_synthetic_channel(EEG, label)
newData = double(EEG.data(1,:,:)) * 1.25;
newData = newData + reshape(linspace(-0.2, 0.2, EEG.pnts), ...
    1, EEG.pnts, 1);
EEG.data(end+1,:,:) = cast(newData, 'like', EEG.data);
EEG.nbchan = size(EEG.data, 1);
newLocation = EEG.chanlocs(1);
newLocation.labels = label;
EEG.chanlocs(end+1) = newLocation;
end

function [fixture, options] = default_response_fixture(oracle)
names = {oracle.response.cases.name};
idx = find(strcmp(names, 'noxious_NRF_500Hz_post'), 1);
assert(~isempty(idx));
fixture = oracle.response.cases(idx).input;
options = oracle.response.cases(idx).options;
end

function passed = run_resolver_and_template_tests(repoRoot, templatesRoot, ...
    oracle)
passed = 0;
templateName = 'noxious_NRF_500Hz';
expectedFile = fullfile(templatesRoot, [templateName '.mat']);
references = {templateName, string(templateName), ...
    [templateName '.mat'], expectedFile, erase(expectedFile, '.mat')};
for idx = 1:numel(references)
    [logicalName, templateFile] = NRFUtils.resolveTemplateFile( ...
        references{idx}, repoRoot);
    assert(strcmp(logicalName, templateName));
    assert_path(templateFile, expectedFile);
    passed = passed + 1;
end

invalidReferences = {"", ["a","b"], 3, 'bad.txt', ...
    'bad-template-name', 'not_a_bundled_template'};
for idx = 1:numel(invalidReferences)
    assert_any_error(@() NRFUtils.resolveTemplateFile( ...
        invalidReferences{idx}, repoRoot), ...
        sprintf('Resolver accepted invalid reference %d.', idx));
    passed = passed + 1;
end
assert_error_id(@() NRFUtils.resolveTemplateFile(templateName, ...
    fullfile(repoRoot, 'not-a-folder')), ...
    'SIMPLE:NRFUtils:InvalidRepositoryRoot', 'resolver invalid root');
passed = passed + 1;

[fixture, options] = default_response_fixture(oracle);
temporaryRoot = tempname;
mkdir(temporaryRoot);
cleanup = onCleanup(@() remove_tree(temporaryRoot)); %#ok<NASGU>

NRF = (1:10)'; %#ok<NASGU>
fs = fixture.srate; %#ok<NASGU>
missingNRF = fullfile(temporaryRoot, 'missingNRF.mat');
save(missingNRF, 'fs');
missingFs = fullfile(temporaryRoot, 'missingFs.mat');
save(missingFs, 'NRF');
badNRF = fullfile(temporaryRoot, 'badNRF.mat');
NRF = [1 NaN 3]; %#ok<NASGU>
save(badNRF, 'NRF', 'fs');
badFs = fullfile(temporaryRoot, 'badFs.mat');
NRF = (1:10)'; fs = -1; %#ok<NASGU>
save(badFs, 'NRF', 'fs');
wrongRate = fullfile(temporaryRoot, 'wrongRate.mat');
fs = fixture.srate * 2; %#ok<NASGU>
save(wrongRate, 'NRF', 'fs');
paths = {missingNRF, missingFs, badNRF, badFs, wrongRate};
for idx = 1:numel(paths)
    badOptions = options;
    badOptions.NRFName = paths{idx};
    assert_any_error(@() estimate_response(fixture, badOptions), ...
        sprintf('Malformed template %d was accepted.', idx));
    passed = passed + 1;
end
end

function passed = run_config_and_cache_tests(repoRoot, oracle)
passed = 0;
configPath = fullfile(repoRoot, 'NRFs', 'nrf_config.ini');
profiles = NRFUtils.parseIni(configPath);
profiles = NRFUtils.validateProfiles(profiles);
expectedNames = {'term_foot_nox','term_thigh_nox','term_hand_nox', ...
    'term_foot_early','prem_foot_nox'};
assert(isequal(fieldnames(profiles), expectedNames(:)));
assert(isequal(profiles.term_foot_nox.channel, {'CZ','Cz'}));
assert(profiles.term_foot_nox.proj_scalar == 400);
passed = passed + 1;

temporaryRoot = tempname;
mkdir(temporaryRoot);
cleanup = onCleanup(@() remove_tree(temporaryRoot)); %#ok<NASGU>
badIni = { ...
    '', ...
    '[p]\nunknown = 1\n', ...
    '[p]\nNRFName = x\nbaselineLength = nope\n', ...
    '[p]\nline without equals\n'};
for idx = 1:numel(badIni)
    iniPath = fullfile(temporaryRoot, sprintf('bad_%d.ini', idx));
    write_text_file(iniPath, sprintf(badIni{idx}));
    assert_any_error(@() NRFUtils.parseIni(iniPath), ...
        sprintf('Malformed INI %d was accepted.', idx));
    passed = passed + 1;
end
assert_any_error(@() NRFUtils.parseIni(fullfile(temporaryRoot, 'missing.ini')), ...
    'A missing INI was accepted.');
passed = passed + 1;

invalidProfile = struct('NRFName','bad/path', 'baselineLength',200, ...
    'jitter',50, 'channel',{{'Cz'}}, 'projectionTimes_pre',[], ...
    'projectionTimes_post',400);
assert_any_error(@() NRFUtils.validateProfiles(struct('p',invalidProfile)), ...
    'A path-valued profile NRFName was accepted.');
invalidProfile.NRFName = 'noxious_NRF_500Hz';
invalidProfile.projectionTimes_pre = -100;
assert_any_error(@() NRFUtils.validateProfiles(struct('p',invalidProfile)), ...
    'A profile with both projection sides was accepted.');
invalidProfile.projectionTimes_pre = [];
invalidProfile.channel = {};
assert_any_error(@() NRFUtils.validateProfiles(struct('p',invalidProfile)), ...
    'A profile with no channel was accepted.');
validProfile = struct('NRFName','noxious_NRF_500Hz', ...
    'baselineLength',200, 'jitter',50, 'channel',{{'Cz'}}, ...
    'projectionTimes_pre',[], 'projectionTimes_post',400);
negativeBaseline = validProfile;
negativeBaseline.baselineLength = -1;
assert_any_error(@() NRFUtils.validateProfiles( ...
    struct('p',negativeBaseline)), ...
    'A profile with negative baselineLength was accepted.');
negativeJitter = validProfile;
negativeJitter.jitter = -1;
assert_any_error(@() NRFUtils.validateProfiles( ...
    struct('p',negativeJitter)), ...
    'A profile with negative jitter was accepted.');
passed = passed + 5;

[fixture, options] = default_response_fixture(oracle);
profile = options;
profile.NRFName = 'noxious_NRF_500Hz';
profile.proj_scalar = profile.projectionTimes_post;
profile.channel = {fixture.chanlocs(1).labels};
cacheProfiles = struct('primary', profile);
labels = {fixture.chanlocs.labels};
zeroTime = -double(fixture.xmin) * 1000;
[fitCache, templateInfo] = NRFUtils.fitAndCache(fixture, cacheProfiles, ...
    {'primary','primary'}, labels, zeroTime, repoRoot);
channelField = profile.channel{1};
assert(isfield(fitCache, 'primary') && ...
    isfield(fitCache.primary, channelField));
assert(isfield(templateInfo, profile.NRFName));
assert_path(templateInfo.(profile.NRFName).file, ...
    fullfile(repoRoot, 'NRFs', [profile.NRFName '.mat']));
passed = passed + 1;

missingProfile = profile;
missingProfile.channel = {'NOT_PRESENT'};
[missingCache, missingInfo] = NRFUtils.fitAndCache(fixture, ...
    struct('missing', missingProfile), {'missing'}, labels, zeroTime, repoRoot);
assert(isempty(fieldnames(missingCache)) && ...
    isfield(missingInfo, missingProfile.NRFName));
passed = passed + 1;

gridProfile = profile;
gridProfile.proj_scalar = profile.proj_scalar + 0.5;
assert_any_error(@() NRFUtils.fitAndCache(fixture, ...
    struct('grid', gridProfile), {'grid'}, labels, zeroTime, repoRoot), ...
    'fitAndCache accepted an off-grid start.');
boundProfile = profile;
boundProfile.proj_scalar = -zeroTime + boundProfile.jitter - 1;
assert_any_error(@() NRFUtils.fitAndCache(fixture, ...
    struct('bound', boundProfile), {'bound'}, labels, zeroTime, repoRoot), ...
    'fitAndCache accepted a search start before its jitter bound.');
rateRoot = fullfile(temporaryRoot, 'rate_repository');
mkdir(fullfile(rateRoot, 'NRFs'));
NRF = sin((0:15)' * pi / 8);
NRF = NRF - mean(NRF);
NRF = NRF / norm(NRF, 2); %#ok<NASGU>
fs = double(fixture.srate) * 2; %#ok<NASGU>
save(fullfile(rateRoot, 'NRFs', 'wrong_rate_template.mat'), 'NRF', 'fs');
rateProfile = profile;
rateProfile.NRFName = 'wrong_rate_template';
assert_error_message(@() NRFUtils.fitAndCache(fixture, ...
    struct('rate', rateProfile), {'rate'}, labels, zeroTime, rateRoot), ...
    sprintf('Sampling-rate mismatch for %s: NRF fs=%g, EEG.srate=%g', ...
    rateProfile.NRFName, fs, fixture.srate));
passed = passed + 3;

edgeProfile = profile;
edgeAbsoluteStart = 50;
edgeProfile.jitter = 50.5;
edgeProfile.projectionTimes_pre = edgeAbsoluteStart - zeroTime;
edgeProfile.projectionTimes_post = [];
edgeProfile.proj_scalar = edgeProfile.projectionTimes_pre;
edgeSearchStart = ceil((edgeAbsoluteStart - edgeProfile.jitter) / ...
    1000 * double(fixture.srate)) + 1;
assert(edgeSearchStart == 1 && edgeAbsoluteStart < edgeProfile.jitter);
[edgeCache, ~] = NRFUtils.fitAndCache(fixture, ...
    struct('edge', edgeProfile), {'edge'}, labels, zeroTime, repoRoot);
assert(isfield(edgeCache, 'edge') && ...
    isfield(edgeCache.edge, channelField));
passed = passed + 1;
end

function passed = run_overlay_tests(repoRoot, testsRoot, templatesRoot)
passed = 0;
templateName = 'noxious_NRF_500Hz';
templatePath = fullfile(templatesRoot, [templateName '.mat']);
template = load(templatePath, 'NRF', 'fs');
times = (-200:1000/template.fs:1200)';
y = zeros(size(times));
[~, anchor] = min(abs(times - 400));
insertion = anchor + 2;
y(insertion:insertion + numel(template.NRF) - 1) = ...
    1.5 + 2.25 * template.NRF(:);

[logicalOverlay, logicalFit] = ts_nrf_overlay(y, templateName, times, ...
    400, 20);
[pathOverlay, pathFit] = ts_nrf_overlay(y, templatePath, times, 400, 20);
assert(isequaln(logicalOverlay, pathOverlay));
assert(isequaln(logicalFit, pathFit));
assert(strcmp(logicalFit.nrfName, templateName));
assert_path(logicalFit.nrfFile, templatePath);
assert(strcmp(logicalFit.support_policy, ...
    'full_template_all_requested_shifts'));
assert(logicalFit.full_template_required && ...
    ~logicalFit.partial_template_support_used && ...
    ~logicalFit.search_was_clipped);
assert(logicalFit.x_shift_samples == 2);
assert(all(isnan(logicalOverlay(1:logicalFit.s_best-1))));
assert(all(isnan(logicalOverlay( ...
    logicalFit.s_best + logicalFit.nrf_length:end))));
passed = passed + 2;

shadowRoot = tempname;
mkdir(shadowRoot);
shadowCleanup = onCleanup(@() remove_tree(shadowRoot)); %#ok<NASGU>
NRF = zeros(10,1); fs = template.fs; %#ok<NASGU>
save(fullfile(shadowRoot, [templateName '.mat']), 'NRF', 'fs');
oldPath = path;
pathCleanup = onCleanup(@() path(oldPath)); %#ok<NASGU>
addpath(shadowRoot, '-begin');
clear ts_nrf_overlay NRFUtils
rehash path;
[shadowOverlay, shadowFit] = ts_nrf_overlay(y, templateName, times, 400, 20);
assert(isequaln(logicalOverlay, shadowOverlay));
assert(isequaln(logicalFit, shadowFit));
path(oldPath);
clear ts_nrf_overlay NRFUtils
rehash path;
passed = passed + 1;

assert_error_id(@() ts_nrf_overlay(y, templateName, times, ...
    times(1), 20), 'ts_nrf_overlay:FullTemplateSearchOutOfBounds', ...
    'overlay lower support bound');
nonuniform = times;
nonuniform(10) = nonuniform(10) + 0.25;
assert_error_id(@() ts_nrf_overlay(y, templateName, nonuniform, ...
    400, 20), 'ts_nrf_overlay:TimesNotUniform', ...
    'overlay nonuniform sample grid');
wrongRate = fullfile(shadowRoot, 'wrong_rate_template.mat');
NRF = sin((0:15)' * pi / 8);
NRF = NRF - mean(NRF);
NRF = NRF / norm(NRF, 2); %#ok<NASGU>
fs = double(template.fs) * 2; %#ok<NASGU>
save(wrongRate, 'NRF', 'fs');
assert_error_id(@() ts_nrf_overlay(y, wrongRate, times, 400, 20), ...
    'ts_nrf_overlay:FsMismatch', 'overlay wrong template rate');
passed = passed + 3;

assert(isfolder(fullfile(repoRoot, 'NRFs')) && ...
    isfile(fullfile(testsRoot, 'run_all_tests.m')));
end

function passed = run_jitter_semantic_tests(cases)
passed = 0;
for idx = 1:numel(cases)
    testCase = cases(idx);
    if ~isempty(testCase.error_identifier) || ~isempty(testCase.error_message)
        continue
    end
    [shifted, shift, template] = jittercorrect(testCase.data, ...
        testCase.NRF, testCase.fs, testCase.fs_NRF, testCase.jitter_ms, ...
        testCase.start_ms);
    assert(isscalar(shift) && isfinite(shift) && shift == round(shift));
    assert(abs(shift) <= round(testCase.jitter_ms / 1000 * testCase.fs));
    assert(isequal(template, testCase.NRF(:)));
    original = testCase.data(:)';
    assert(isrow(shifted) && numel(shifted) == numel(original));
    if shift > 0
        assert(isequal(shifted(1:end-shift), original(shift+1:end)));
        assert(all(shifted(end-shift+1:end) == 0));
    elseif shift < 0
        amount = abs(shift);
        assert(all(shifted(1:amount) == 0));
        assert(isequal(shifted(amount+1:end), original(1:end-amount)));
    else
        assert(isequal(shifted, original));
    end
    passed = passed + 1;
end
end

function passed = run_qc_semantic_tests(qc)
passed = 0;
success = find(arrayfun(@(x) isempty(x.error_identifier) && ...
    isempty(x.error_message) && ~isempty(x.output), qc.coordinator), 1);
assert(~isempty(success));
fixture = qc.coordinator(success).input;
fresh = quality_control_features(fixture);
sentinel = fixture;
for idx = 1:numel(sentinel.epoch)
    sentinel.epoch(idx).qc = struct('existing', -999);
end
overwritten = quality_control_features(sentinel);
assert(isequaln(fresh, overwritten), ...
    'QC did not completely overwrite an existing qc structure.');
expectedFields = {'Channels','maxAbsEpoch','maxAbsBaseline','maxAbsPost', ...
    'sdEpoch','invSdEpoch','MeanAbsDiffNorm','MaxAbsDiffNorm', ...
    'RobustSlopeNorm','AutoCorrLag1Pos','AutoCorrLag1Neg','KatzFDNorm'};
for epochIndex = 1:numel(overwritten.epoch)
    actual = overwritten.epoch(epochIndex).qc;
    assert(isequal(sort(fieldnames(actual)), sort(expectedFields(:))));
    assert(numel(actual.Channels) == numel(overwritten.chanlocs));
end
passed = passed + 1;

arrayOutput = quality_control_features([fixture fixture]);
assert(numel(arrayOutput) == 2);
storedFixture = eeg_checkset(fixture);
storedFresh = quality_control_features(storedFixture);
for datasetIndex = 1:2
    assert(isequaln(arrayOutput(datasetIndex).data, storedFixture.data));
    assert(numel(arrayOutput(datasetIndex).epoch) == ...
        numel(storedFresh.epoch));
    for epochIndex = 1:numel(storedFresh.epoch)
        assert(isequaln(arrayOutput(datasetIndex).epoch(epochIndex).qc, ...
            storedFresh.epoch(epochIndex).qc));
    end
end
passed = passed + 1;

fallback = rmfield(fixture, 'times');
fallbackOutput = quality_control_features(fallback);
assert(all(cellfun(@(x) isfield(x, 'qc'), num2cell(fallbackOutput.epoch))));
passed = passed + 1;
end

function passed = run_diagnostic_wrapper_tests(qc)
passed = 0;
success = find(arrayfun(@(x) isempty(x.error_identifier) && ...
    isempty(x.error_message) && ~isempty(x.output), qc.coordinator), 1);
assert(~isempty(success));
fixture = qc.coordinator(success).input;
warningID = 'stats:statrobustfit:IterationLimit';
originalState = warning;
originalLast = cell(1,2);
[originalLast{:}] = lastwarn;
cleanup = onCleanup(@() restore_complete_warning_state( ...
    originalState, originalLast)); %#ok<NASGU>

warning('off', warningID);
warning('off', 'backtrace');
warning('on', 'verbose');
lastwarn('synthetic sentinel', 'SIMPLE:test:LastWarning');
before = diagnostic_warning_snapshot(warningID);
console = evalc(['output = quality_control_features_with_diagnostics(' ...
    'fixture, 17, ''synthetic.set'');']);
after = diagnostic_warning_snapshot(warningID);
assert(isequal(before, after));
assert(isequaln(output, quality_control_features(fixture)));
assert(contains(console, 'dataset_list row 17') && ...
    contains(console, 'synthetic.set'));
passed = passed + 1;

bad = fixture;
bad.epoch = [];
before = diagnostic_warning_snapshot(warningID);
assert_any_error(@() quality_control_features_with_diagnostics( ...
    bad, 18, 'bad.set'), 'Diagnostic wrapper swallowed a QC failure.');
after = diagnostic_warning_snapshot(warningID);
assert(isequal(before, after));
passed = passed + 1;
end

function snapshot = diagnostic_warning_snapshot(warningID)
snapshot = struct();
snapshot.iteration = warning('query', warningID);
snapshot.backtrace = warning('query', 'backtrace');
snapshot.verbose = warning('query', 'verbose');
[snapshot.lastMessage, snapshot.lastIdentifier] = lastwarn;
end

function restore_complete_warning_state(state, last)
warning(state);
lastwarn(last{1}, last{2});
end

function passed = run_dependency_boundary_tests(eeglabRoot, testsRoot, ...
    functionsRoot, basePath, oracle)
passed = 0;
dependencies = {'fgls','robustfit','corr','eeg_checkset', ...
    'pop_select','pop_rmbase','pop_cleanline'};
for idx = 1:numel(dependencies)
    resolved = which(dependencies{idx});
    assert(~isempty(resolved), 'Required test dependency missing: %s', ...
        dependencies{idx});
    passed = passed + 1;
end
assert(path_is_within(which('eeg_checkset'), eeglabRoot));
assert_path(which('estimate_response'), ...
    fullfile(functionsRoot, 'estimate_response.m'));

[fixture, options] = default_response_fixture(oracle);
assert_stub_error(@() estimate_response(fixture, options), ...
    fullfile(testsRoot, 'stubs', 'dependency_fgls'), 'fgls', ...
    'SIMPLE:test:MissingFGLS', basePath);
assert_stub_error(@() calc_RobustSlopeNorm( ...
    sin(1:40) + (1:40)/20, 500, 1:40), ...
    fullfile(testsRoot, 'stubs', 'dependency_robustfit'), 'robustfit', ...
    'SIMPLE:test:MissingRobustfit', basePath);
assert_stub_error(@() jittercorrect(1:60, sin(1:10), 500, 500, 2, 20), ...
    fullfile(testsRoot, 'stubs', 'dependency_corr'), 'corr', ...
    'SIMPLE:test:MissingCorr', basePath);
eventFixture = make_event_fixture();
assert_stub_error(@() add_offset_events(eventFixture, ...
    'sourceA', 100, 'targetA'), ...
    fullfile(testsRoot, 'stubs', 'dependency_eeg_checkset'), ...
    'eeg_checkset', 'SIMPLE:test:MissingEEGLAB', basePath);
passed = passed + 4;
end

function assert_stub_error(callback, stubRoot, dependency, expectedID, basePath)
path(basePath);
addpath(stubRoot, '-begin');
clear(dependency);
rehash path;
assert_path(which(dependency), fullfile(stubRoot, [dependency '.m']));
didThrow = false;
try
    callback();
catch ME
    didThrow = true;
    assert(strcmp(ME.identifier, expectedID), ...
        'Dependency %s failure was changed to %s.', dependency, ME.identifier);
end
path(basePath);
clear(dependency);
rehash path;
assert(didThrow, 'Missing dependency was silently accepted: %s', dependency);
end

function passed = run_isolated_logger_test(repoRoot, testsRoot, basePath)
passed = 0;
temporaryRoot = tempname;
scriptsRoot = fullfile(temporaryRoot, 'scripts');
mkdir(scriptsRoot);
cleanup = onCleanup(@() cleanup_logger_test(temporaryRoot, basePath)); %#ok<NASGU>
copyfile(fullfile(repoRoot, 'scripts', 'log_command_window.m'), ...
    fullfile(scriptsRoot, 'log_command_window.m'));
copyfile(fullfile(testsRoot, 'helpers', 'logger_probe.m'), ...
    fullfile(scriptsRoot, 'logger_probe.m'));
logsRoot = fullfile(temporaryRoot, 'data', 'logs');
mkdir(logsRoot);
logPath = fullfile(logsRoot, 'logger_probe.log');
write_text_file(logPath, 'STALE_LOG_CONTENT');

path(basePath);
addpath(scriptsRoot, '-begin');
clear log_command_window logger_probe
rehash path;
assert_path(which('log_command_window'), ...
    fullfile(scriptsRoot, 'log_command_window.m'));
logger_probe;
diary off;
assert(isfile(logPath));
contents = fileread(logPath);
assert(contains(contents, 'SIMPLE_ISOLATED_LOGGER_TOKEN'));
assert(~contains(contents, 'STALE_LOG_CONTENT'));
listing = dir(fullfile(logsRoot, '*.log'));
assert(numel(listing) == 1 && strcmp(listing.name, 'logger_probe.log'));
assert(~isfolder(fullfile(temporaryRoot, 'logs')));
log_command_window('stop');
passed = passed + 1;
end

function cleanup_logger_test(temporaryRoot, basePath)
diary off;
path(basePath);
clear log_command_window logger_probe
rehash path;
remove_tree(temporaryRoot);
end

function write_text_file(filePath, contents)
fid = fopen(filePath, 'wt');
assert(fid >= 0, 'Could not create synthetic text fixture: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
count = fwrite(fid, contents, 'char');
assert(count == numel(contents));
end

function assert_template_inventory(expected, templateRoot)
assert(isfolder(templateRoot), 'Missing repository-local NRF directory.');
expectedNames = {'early_NRF_500Hz', 'noxious_NRF_500Hz', ...
    'noxious_preterm_NRF_500Hz'};
assert(isequal(sort({expected.name}), sort(expectedNames)), ...
    'The template fixture must describe exactly the three 500-Hz NRFs.');
listing = dir(fullfile(templateRoot, '*.mat'));
assert(numel(listing) == numel(expected), ...
    'Repository-local NRF template count differs.');
for idx = 1:numel(expected)
    templatePath = fullfile(templateRoot, [expected(idx).name '.mat']);
    assert(isfile(templatePath), 'Missing template: %s', expected(idx).name);
    assert(strcmp(sha256_file(templatePath), expected(idx).sha256), ...
        'Template bytes differ: %s', expected(idx).name);
    value = load(templatePath);
    assert(isequal(sort(fieldnames(value)), {'NRF'; 'fs'}), ...
        'Template variables differ: %s', expected(idx).name);
    assert(isa(value.fs, 'double') && isreal(value.fs) && ...
        isscalar(value.fs) && isfinite(value.fs) && value.fs == 500);
    assert(isequal(value.fs, expected(idx).fs));
    assert(isa(value.NRF, 'double') && isreal(value.NRF) && ...
        iscolumn(value.NRF) && all(isfinite(value.NRF)));
    assert(numel(value.NRF) == expected(idx).length);
    assert(abs(mean(value.NRF)) <= 1e-12, ...
        'Template mean is not zero: %s', expected(idx).name);
    assert(abs(norm(value.NRF, 2) - 1) <= 1e-12, ...
        'Template L2 norm is not one: %s', expected(idx).name);
end
end

function EEG = clear_history(EEG)
for idx = 1:numel(EEG)
    if isfield(EEG(idx), 'history')
        EEG(idx).history = '';
    end
end
end

function assert_error_id(callback, expectedIdentifier, label)
didThrow = false;
try
    callback();
catch ME
    didThrow = true;
    assert(strcmp(ME.identifier, expectedIdentifier), ...
        'Expected %s for %s, received %s.', ...
        expectedIdentifier, label, ME.identifier);
end
assert(didThrow, 'Expected failure did not occur: %s', label);
end

function assert_error_message(callback, expectedMessage)
didThrow = false;
try
    callback();
catch ME
    didThrow = true;
    assert(strcmp(ME.message, expectedMessage), ...
        'Expected error "%s", received "%s".', expectedMessage, ME.message);
end
assert(didThrow, 'Expected failure did not occur: %s', expectedMessage);
end

function assert_any_error(callback, failureMessage)
didThrow = false;
try
    callback();
catch
    didThrow = true;
end
assert(didThrow, failureMessage);
end

function paths = which_all(name)
resolved = which(name, '-all');
if isempty(resolved)
    paths = {};
elseif ischar(resolved)
    paths = {resolved};
else
    paths = resolved;
end
end

function remove_canonical_path(targetPath)
targetCanonical = canonical_path(targetPath);
entries = strsplit(path, pathsep);
for idx = 1:numel(entries)
    if isempty(entries{idx})
        continue
    end
    if strcmp(canonical_path(entries{idx}), targetCanonical)
        rmpath(entries{idx});
    end
end
end

function rmpath_if_present(targetPath)
targetCanonical = canonical_path(targetPath);
entries = strsplit(path, pathsep);
for idx = 1:numel(entries)
    if ~isempty(entries{idx}) && ...
            strcmp(canonical_path(entries{idx}), targetCanonical)
        rmpath(entries{idx});
    end
end
end

function inside = path_is_within(inputPath, rootPath)
if isempty(inputPath)
    inside = false;
    return
end
inputCanonical = canonical_path(inputPath);
rootCanonical = canonical_path(rootPath);
inside = strcmp(inputCanonical, rootCanonical) || ...
    startsWith(inputCanonical, [rootCanonical filesep]);
end

function assert_path(actualPath, expectedPath)
assert(~isempty(actualPath), 'Expected source did not resolve: %s', expectedPath);
assert(strcmp(canonical_path(actualPath), canonical_path(expectedPath)), ...
    'Resolved path mismatch. Expected %s, received %s.', ...
    canonical_path(expectedPath), canonical_path(actualPath));
end

function value = canonical_path(inputPath)
value = char(java.io.File(inputPath).getCanonicalPath());
end

function remove_tree(rootPath)
if isfolder(rootPath)
    rmdir(rootPath, 's');
end
end

function digest = sha256_file(filePath)
fid = fopen(filePath, 'rb');
assert(fid >= 0, 'Could not open file for hashing: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
engine = java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes = fread(fid, 1024 * 1024, '*uint8');
    if isempty(bytes)
        break
    end
    engine.update(typecast(bytes(:), 'int8'));
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), 'uint8'), 2).', ...
    1, []));
end
