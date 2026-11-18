function result = run_step2_downstream_identity_tests(repoRoot)
%RUN_STEP2_DOWNSTREAM_IDENTITY_TESTS Exercise identity-bearing Steps 3-7.
%
% Three temporary repositories follow the original, Step 2.10-only, and
% Step 2.10-plus-2.11 routes. Production transactions and representative
% production scripts then prove that downstream science and decisions are
% invariant while every public identity surface follows the active registry.

arguments
    repoRoot (1,:) char
end

requiredFunctions = {'eeg_emptyset', 'eeg_checkset', 'pop_loadset', ...
    'pmtm', 'bootci'};
for index = 1:numel(requiredFunctions)
    assert(exist(requiredFunctions{index}, 'file') == 2, ...
        'Required MATLAB/EEGLAB function is unavailable: %s', ...
        requiredFunctions{index});
end
repoRoot = canonical_path(repoRoot);
assert(isfolder(repoRoot));

originalFolder = pwd;
originalPath = path;
originalVisibility = get(groot, 'defaultFigureVisible');
suiteRoot = tempname;
mkdir(suiteRoot);
cleanup = onCleanup(@() cleanup_suite( ...
    suiteRoot, originalFolder, originalPath, originalVisibility));
set(groot, 'defaultFigureVisible', 'off');
assert_eventdescription_science_normalisation();

[~, repositoryName] = fileparts(repoRoot);
if strcmp(repositoryName, 'simple-strasbourg')
    referenceEvent = "cannula_prestim";
    trueEvent = "cannula";
elseif strcmp(repositoryName, 'simple-oxford')
    referenceEvent = "lance_prestim";
    trueEvent = "lance";
else
    error('SIMPLE:Step2Downstream:UnsupportedRepository', ...
        'The shared downstream identity test supports Oxford and Strasbourg.');
end

routeNames = ["original"; "step210_only"; "step210_step211"];
routes = cell(numel(routeNames), 1);
for routeIndex = 1:numel(routeNames)
    routeRoot = fullfile(suiteRoot, char(routeNames(routeIndex)));
    routes{routeIndex} = run_route(repoRoot, routeRoot, ...
        routeNames(routeIndex), referenceEvent, trueEvent, originalPath);
end

original = routes{1};
mapped = routes{2};
sanitised = routes{3};
originalSubjects = ["PRIVSUBA"; "PRIVSUBB"; "PRIVSUBC"];
canonicalSubjects = ["001"; "002"; "003"];

assert(original.identity.mode == "original");
assert(mapped.identity.mode == "mapped" && sanitised.identity.mode == "mapped");
assert(original.step2_state == "original");
assert(mapped.step2_state == "mapped_unsanitised");
assert(sanitised.step2_state == "mapped_modified");
assert(isequal(original.subjects, originalSubjects));
assert(isequal(mapped.subjects, canonicalSubjects));
assert(isequal(sanitised.subjects, canonicalSubjects));
assert(isequal(original.sessions, "VISITPRIVATE") && ...
    isequal(original.runs, "RUNPRIVATE"));
assert(isequal(mapped.sessions, "01") && isequal(mapped.runs, "01"));
assert(isequal(sanitised.sessions, mapped.sessions) && ...
    isequal(sanitised.runs, mapped.runs));
assert(isequaln(original.set_science, mapped.set_science));
assert(isequaln(original.set_science, sanitised.set_science));
assert(original.active_sets_byte_identical_to_originals);
assert(mapped.active_sets_byte_identical_to_originals);
assert(~sanitised.active_sets_byte_identical_to_originals);
assert(sanitised.active_sets_verified_sanitised);

assert_route_ids(original.pooled_qc, original.subjects, ...
    original.sessions, original.runs);
assert_route_ids(mapped.pooled_qc, mapped.subjects, mapped.sessions, mapped.runs);
assert_route_ids(sanitised.pooled_qc, sanitised.subjects, ...
    sanitised.sessions, sanitised.runs);
assert(isequaln(science_table(original.pooled_qc), ...
    science_table(mapped.pooled_qc)));
assert(isequaln(science_table(original.pooled_qc), ...
    science_table(sanitised.pooled_qc)));
assert(isequaln(science_table(original.pooled_nrf), ...
    science_table(mapped.pooled_nrf)));
assert(isequaln(science_table(original.pooled_nrf), ...
    science_table(sanitised.pooled_nrf)));
assert(isequaln(science_epochs(original.pooled_epochs, false), ...
    science_epochs(mapped.pooled_epochs, false)));
assert(isequaln(science_epochs(original.pooled_epochs, false), ...
    science_epochs(sanitised.pooled_epochs, false)));

assert_route_ids(original.package.items, original.subjects, ...
    original.sessions, original.runs);
assert_route_ids(mapped.package.items, mapped.subjects, ...
    mapped.sessions, mapped.runs);
assert_route_ids(sanitised.package.items, sanitised.subjects, ...
    sanitised.sessions, sanitised.runs);
assert(isequaln(science_table(original.package.items), ...
    science_table(mapped.package.items)));
assert(isequaln(science_table(original.package.items), ...
    science_table(sanitised.package.items)));
assert(isequaln(original.package.qc_values, mapped.package.qc_values));
assert(isequaln(original.package.qc_values, sanitised.package.qc_values));
assert(isequaln(original.package.qc_found, mapped.package.qc_found));
assert(isequaln(original.package.qc_found, sanitised.package.qc_found));

assert(contains(original.viewer_title, ...
    "| PRIVSUBA | VISITPRIVATE | RUNPRIVATE |"));
assert(contains(mapped.viewer_title, "| 001 | 01 | 01 |"));
assert(contains(sanitised.viewer_title, "| 001 | 01 | 01 |"));
assert(erase_identity(original.viewer_title, ...
    "PRIVSUBA", "VISITPRIVATE", "RUNPRIVATE") == ...
    erase_identity(mapped.viewer_title, "001", "01", "01"));
assert(mapped.viewer_title == sanitised.viewer_title);

assert(isequaln(science_table(original.screened_qc), ...
    science_table(mapped.screened_qc)));
assert(isequaln(science_table(original.screened_qc), ...
    science_table(sanitised.screened_qc)));
assert(isequaln(science_table(original.screened_nrf), ...
    science_table(mapped.screened_nrf)));
assert(isequaln(science_table(original.screened_nrf), ...
    science_table(sanitised.screened_nrf)));
assert(isequaln(science_epochs(original.screened_epochs, true), ...
    science_epochs(mapped.screened_epochs, true)));
assert(isequaln(science_epochs(original.screened_epochs, true), ...
    science_epochs(sanitised.screened_epochs, true)));
assert(sum(original.screened_qc.Exclude) == 1 && ...
    sum(mapped.screened_qc.Exclude) == 1 && ...
    sum(sanitised.screened_qc.Exclude) == 1);

assert(original.excluded_filename == ...
    "sub-PRIVSUBA_ses-VISITPRIVATE_run-RUNPRIVATE_epoch-3_chan-Cz_control.png");
assert(mapped.excluded_filename == ...
    "sub-001_ses-01_run-01_epoch-3_chan-Cz_control.png");
assert(sanitised.excluded_filename == mapped.excluded_filename);

assert_route_ids(original.separation.pairing_table, original.subjects, ...
    original.sessions, original.runs);
assert_route_ids(mapped.separation.pairing_table, mapped.subjects, ...
    mapped.sessions, mapped.runs);
assert_route_ids(sanitised.separation.pairing_table, sanitised.subjects, ...
    sanitised.sessions, sanitised.runs);
assert(isequaln(science_table(original.separation.pairing_table), ...
    science_table(mapped.separation.pairing_table)));
assert(isequaln(science_table(original.separation.pairing_table), ...
    science_table(sanitised.separation.pairing_table)));
assert(isequaln(original.separation.pair_differences, ...
    mapped.separation.pair_differences));
assert(isequaln(original.separation.pair_differences, ...
    sanitised.separation.pair_differences));
assert(isequaln(original.separation.estimate, mapped.separation.estimate));
assert(isequaln(original.separation.estimate, sanitised.separation.estimate));
assert(original.separation.counts.pairs_analysed == 3);

assert(contains(original.designated_log, "PRIVSUBA | VISITPRIVATE | RUNPRIVATE"));
assert(contains(mapped.designated_log, "001 | 01 | 01"));
assert(contains(sanitised.designated_log, "001 | 01 | 01"));
privateTokens = [originalSubjects; "VISITPRIVATE"; "RUNPRIVATE"];
assert_no_tokens(mapped.downstream_text, privateTokens);
assert_no_tokens(sanitised.downstream_text, privateTokens);

caseNames = [ ...
    "three_route_step2_state_and_set_science"; ...
    "pooled_csv_mat_identity_and_science"; ...
    "screening_package_identity_and_science"; ...
    "viewer_title_identity_surface"; ...
    "screened_outputs_decision_invariance"; ...
    "saved_excluded_filename_identity_surface"; ...
    "separation_table_identity_and_science"; ...
    "designated_log_and_private_token_guard"];
result = struct();
result.schema = 'simple-step2-downstream-identity-tests-v1';
result.case_names = caseNames;
result.total = numel(caseNames);
result.passed = true;
fprintf('STEP 2 DOWNSTREAM IDENTITY TESTS PASSED: %d\n', result.total);
end

function route = run_route(repoRoot, root, routeName, ...
        referenceEvent, trueEvent, originalPath)
setup_repository(repoRoot, root);
activate_repository(root, originalPath);
create_original_step2_state(root);

if routeName ~= "original"
    step210 = run_pseudonymisation_transaction( ...
        root, struct('usable_bytes', 2^50));
    assert(step210.status == "completed");
end
if routeName == "step210_step211"
    step211 = run_sanitisation_transaction(root, ...
        struct('available_bytes_override', 2^50, 'save_version', "v6"));
    assert(strcmp(step211.status, 'completed'));
end

identity = load_dataset_identity_registry( ...
    fullfile(root, 'data_lists', 'dataset_list.csv'));
step2State = inspect_identity_state(root);
[setScience, byteIdentical, verifiedSanitised] = ...
    inspect_route_sets(identity, routeName);

run_fixture_script(fullfile(root, 'scripts', ...
    'step_3_proc_3_add_processeds.m'));
run_fixture_script(fullfile(root, 'scripts', ...
    'step_5_sum_1_add_summaries.m'));
identity = load_dataset_identity_registry( ...
    fullfile(root, 'data_lists', 'dataset_list.csv'));
write_summary_inputs(identity, referenceEvent, trueEvent);

run_fixture_script(fullfile(root, 'scripts', ...
    'step_5_sum_3_summarise_pooled.m'));
pooledDir = fullfile(root, 'data', 'summary', 'pooled');
pooledQc = read_csv(fullfile(pooledDir, 'pooled_eeg_qc_features.csv'));
pooledNrf = read_csv(fullfile(pooledDir, 'pooled_eeg_nrf_features.csv'));
manifest = read_csv(fullfile(pooledDir, 'pooled_eeg_manifest.csv'));
loaded = load(fullfile(pooledDir, 'pooled_eeg_epochs.mat'), 'epochs_pooled');
pooledEpochs = loaded.epochs_pooled;
designatedLog = string(fileread(fullfile(root, 'data', 'logs', ...
    'step_5_sum_3_summarise_pooled.log')));

run_fixture_script(fullfile(root, 'scripts', ...
    'step_6_screen_1_init_package.m'));
screeningDir = fullfile(root, 'data', 'summary', 'screening');
packageFile = fullfile(screeningDir, 'screening_package.mat');
loaded = load(packageFile, 'package');
package = loaded.package;

run_fixture_script(fullfile(root, 'scripts', ...
    'step_6_screen_2_viewer_rate_epochs.m'));
[viewerTitle, viewerFigure] = current_viewer_title();
close(viewerFigure);
drawnow;

decisionFile = fullfile(screeningDir, 'screening_decisions.mat');
loaded = load(decisionFile, 'decisions');
decisions = loaded.decisions;
controlItem = find(package.items.subjectID == identity.table.subjectID(1) & ...
    package.items.eventtype == "control", 1, 'first');
assert(~isempty(controlItem));
decisions.exclude_mask(:) = false;
decisions.exclude_mask(controlItem) = true;
save(decisionFile, 'decisions', '-v7');

run_fixture_script(fullfile(root, 'scripts', ...
    'step_6_screen_3_apply_decisions.m'));
screenedQc = read_csv(fullfile(screeningDir, ...
    'pooled_screened_eeg_qc_features.csv'));
screenedNrf = read_csv(fullfile(screeningDir, ...
    'pooled_screened_eeg_nrf_features.csv'));
loaded = load(fullfile(screeningDir, ...
    'pooled_screened_eeg_epochs.mat'), 'epochs_pooled');
screenedEpochs = loaded.epochs_pooled;

run_fixture_script(fullfile(root, 'scripts', ...
    'step_7_check_1_save_excluded_figs.m'));
excludedDirectory = fullfile(screeningDir, 'excluded_epochs');
pngs = dir(fullfile(excludedDirectory, '*.png'));
assert(isscalar(pngs) && pngs.bytes > 0);
excludedFilename = string(pngs.name);

run_fixture_script(fullfile(root, 'scripts', ...
    'step_7_check_6_sep_check_qc.m'));
close(findall(groot, 'Type', 'figure'));
loaded = load(fullfile(screeningDir, ...
    'step_7_check_6_sep_check_qc_result.mat'), 'separation_result');
separation = loaded.separation_result;

route = struct();
route.name = routeName;
route.identity = identity;
route.step2_state = step2State.name;
route.subjects = unique(string(identity.table.subjectID), 'stable');
route.sessions = unique(string(identity.table.sessionID), 'stable');
route.runs = unique(string(identity.table.runID), 'stable');
route.set_science = setScience;
route.active_sets_byte_identical_to_originals = byteIdentical;
route.active_sets_verified_sanitised = verifiedSanitised;
route.pooled_qc = pooledQc;
route.pooled_nrf = pooledNrf;
route.pooled_epochs = pooledEpochs;
route.manifest = manifest;
route.package = package;
route.viewer_title = viewerTitle;
route.screened_qc = screenedQc;
route.screened_nrf = screenedNrf;
route.screened_epochs = screenedEpochs;
route.excluded_filename = excludedFilename;
route.separation = separation;
route.designated_log = designatedLog;
route.downstream_text = collect_downstream_text(route);
end

function setup_repository(repoRoot, root)
mkdir(root);
mkdir(fullfile(root, 'functions'));
copyfile(fullfile(repoRoot, 'functions', 'private'), ...
    fullfile(root, 'functions', 'private'));
mkdir(fullfile(root, 'scripts'));
mkdir(fullfile(root, 'data'));
mkdir(fullfile(root, 'data', 'raw'));
mkdir(fullfile(root, 'data_lists'));

functionNames = { ...
    'build_pseudonymised_dataset_registry.m', ...
    'inspect_identity_state.m', ...
    'inspect_pseudonymisation_inputs.m', ...
    'load_dataset_identity_registry.m', ...
    'run_pseudonymisation_transaction.m', ...
    'run_sanitisation_transaction.m', ...
    'sanitise_eeglab_dataset.m', ...
    'verify_sanitised_eeglab_dataset.m', ...
    'validate_dataset_registry_paths.m', ...
    'compute_paired_effect.m', ...
    'plot_paired_effect_result.m', ...
    'save_paired_separation_result.m'};
for index = 1:numel(functionNames)
    copyfile(fullfile(repoRoot, 'functions', functionNames{index}), ...
        fullfile(root, 'functions', functionNames{index}));
end
copyfile(fullfile(repoRoot, 'scripts', 'log_command_window.m'), ...
    fullfile(root, 'scripts', 'log_command_window.m'));
scriptNames = { ...
    'step_3_proc_3_add_processeds.m', ...
    'step_5_sum_1_add_summaries.m', ...
    'step_5_sum_3_summarise_pooled.m', ...
    'step_6_screen_1_init_package.m', ...
    'step_6_screen_2_viewer_rate_epochs.m', ...
    'step_6_screen_3_apply_decisions.m', ...
    'step_7_check_1_save_excluded_figs.m', ...
    'step_7_check_6_sep_check_qc.m'};
for index = 1:numel(scriptNames)
    source = fullfile(repoRoot, 'scripts', scriptNames{index});
    destination = fullfile(root, 'scripts', scriptNames{index});
    copy_script_with_root(source, destination, root);
end
end

function activate_repository(root, originalPath)
diary off;
close all force;
path(originalPath);
addpath(fullfile(root, 'functions'), '-begin');
addpath(fullfile(root, 'scripts'), '-begin');
clear build_pseudonymised_dataset_registry inspect_identity_state ...
    inspect_pseudonymisation_inputs ...
    load_dataset_identity_registry run_pseudonymisation_transaction ...
    run_sanitisation_transaction sanitise_eeglab_dataset ...
    verify_sanitised_eeglab_dataset validate_dataset_registry_paths ...
    compute_paired_effect plot_paired_effect_result ...
    save_paired_separation_result log_command_window
rehash path;
end

function create_original_step2_state(root)
subjectID = ["PRIVSUBA"; "PRIVSUBB"; "PRIVSUBC"];
sessionID = repmat("VISITPRIVATE", 3, 1);
runID = repmat("RUNPRIVATE", 3, 1);
path_raw = "data/raw/sub-" + subjectID + ...
    "/ses-" + sessionID + "/eeg";
EEGfile_raw = "sub-" + subjectID + "_ses-" + sessionID + ...
    "_run-" + runID + "_eeg.set";
registry = table(subjectID, sessionID, runID, path_raw, EEGfile_raw);
writetable(registry, fullfile(root, 'data_lists', 'dataset_list.csv'), ...
    'QuoteStrings', true);

excluded_datasets = repmat("", 3, 1);
channel_exclusion = repmat("", 3, 1);
included_datasets = repmat("included", 3, 1);
preliminary = table(subjectID, sessionID, runID, EEGfile_raw, path_raw, ...
    excluded_datasets, channel_exclusion, included_datasets, ...
    'VariableNames', {'subjectID', 'sessionID', 'runID', ...
    'EEGfile_reformatted', 'path_reformatted', 'excluded_datasets', ...
    'channel_exclusion', 'included_datasets'});
writetable(preliminary, fullfile(root, 'data_lists', ...
    'dataset_list_prelim.xlsx'), 'FileType', 'spreadsheet');

for row = 1:height(registry)
    directory = join_relative(root, registry.path_raw(row));
    mkdir(directory);
    EEG = make_raw_eeg(subjectID(row), sessionID(row), runID(row), ...
        EEGfile_raw(row), row);
    destination = fullfile(directory, char(EEGfile_raw(row)));
    save(destination, '-v6', '-mat', '-struct', 'EEG');
end
end

function EEG = make_raw_eeg(subject, session, run, filename, row)
EEG = eeg_emptyset;
[~, stem] = fileparts(char(filename));
EEG.setname = stem;
EEG.filename = char(filename);
EEG.filepath = ['/private/source/' char(subject)];
EEG.subject = char(subject);
EEG.session = char(session);
EEG.run = char(run);
EEG.group = 'synthetic group';
EEG.condition = 'synthetic condition';
EEG.comments = ['private source ' char(subject)];
EEG.history = ['loaded /private/source/' char(subject)];
EEG.nbchan = 1;
EEG.pnts = 64;
EEG.trials = 1;
EEG.srate = 128;
EEG.xmin = 0;
EEG.xmax = (EEG.pnts - 1) / EEG.srate;
EEG.times = (0:EEG.pnts - 1) * 1000 / EEG.srate;
EEG.data = single(row + sin((0:EEG.pnts - 1) * 2 * pi / 16));
EEG.chanlocs = struct('labels', 'Cz', 'type', 'EEG', ...
    'X', 0, 'Y', 0, 'Z', 1);
EEG.event = struct('type', 'stim', 'latency', 16, 'duration', 0, ...
    'urevent', 1, 'code', 'S 1', 'bvmknum', 1);
EEG = eeg_checkset(EEG, 'eventconsistency');
EEG = eeg_checkset(EEG);
EEG.event.bvtime = 'private-time';
EEG.urevent.bvtime = 'private-time';
end

function [science, byteIdentical, verifiedSanitised] = ...
        inspect_route_sets(identity, routeName)
science = cell(identity.recording_count, 1);
byteIdentical = routeName ~= "step210_step211";
verifiedSanitised = false;
for row = 1:identity.recording_count
    active = char(identity.targets.raw_files(row));
    loaded = pop_loadset('filename', active, 'loadmode', 'all');
    science{row} = set_science(loaded);
    if identity.mode == "mapped"
        source = join_file(identity.repository_root, ...
            identity.table.path_raw_orig(row), ...
            identity.table.EEGfile_raw_orig(row));
        if routeName == "step210_only"
            byteIdentical = byteIdentical && ...
                strcmp(sha256_file(active), sha256_file(source));
            verifiedSanitised = false;
        else
            expected = struct('subjectID', char(identity.table.subjectID(row)), ...
                'sessionID', char(identity.table.sessionID(row)), ...
                'runID', char(identity.table.runID(row)), ...
                'EEGfile_raw', char(identity.table.EEGfile_raw(row)));
            privacy = struct('row_number', row, ...
                'original_subject_id', char(identity.table.subjectID_orig(row)), ...
                'original_session_id', char(identity.table.sessionID_orig(row)), ...
                'original_run_id', char(identity.table.runID_orig(row)), ...
                'original_filename', char(identity.table.EEGfile_raw_orig(row)), ...
                'original_path', char(identity.table.path_raw_orig(row)), ...
                'blocked_tokens', strings(0, 1));
            verify_sanitised_eeglab_dataset(source, active, expected, privacy);
            verifiedSanitised = true;
            byteIdentical = false;
        end
    end
end
science = vertcat(science{:});
end

function value = set_science(EEG)
authorised = {'filename', 'filepath', 'setname', 'subject', 'session', ...
    'run', 'comments', 'history'};
present = intersect(authorised, fieldnames(EEG));
value = rmfield(EEG, present);
if isfield(value, 'event') && isfield(value.event, 'bvtime')
    value.event = rmfield(value.event, 'bvtime');
end
if isfield(value, 'urevent') && isfield(value.urevent, 'bvtime')
    value.urevent = rmfield(value.urevent, 'bvtime');
end
if isfield(value, 'epoch') && isstruct(value.epoch) && ...
        isfield(value.epoch, 'eventbvtime')
    value.epoch = rmfield(value.epoch, 'eventbvtime');
end
if isfield(value, 'eventdescription') && ...
        iscell(value.eventdescription) && ...
        all(cellfun(@isempty, value.eventdescription))
    % EEGLAB sizes this empty bookkeeping mirror to the event-field count.
    value.eventdescription = {};
end
end

function assert_eventdescription_science_normalisation()
emptySeven = struct();
emptySeven.eventdescription = cell(1, 7);
emptySix = struct();
emptySix.eventdescription = cell(1, 6);
assert(isequaln(set_science(emptySeven), set_science(emptySix)));

nonempty = struct();
nonempty.eventdescription = {'', 'scientific description'};
preserved = set_science(nonempty);
assert(isequaln(preserved.eventdescription, nonempty.eventdescription));
end

function write_summary_inputs(identity, referenceEvent, trueEvent)
T = identity.table;
for row = 1:height(T)
    directory = join_relative(identity.repository_root, T.path_summary(row));
    mkdir(directory);
    [~, stem] = fileparts(char(T.EEGfile_processed(row)));
    subjectID = repmat(string(T.subjectID(row)), 3, 1);
    sessionID = repmat(string(T.sessionID(row)), 3, 1);
    runID = repmat(string(T.runID(row)), 3, 1);
    epoch_index = (1:3)';
    channel = repmat("Cz", 3, 1);
    eventtype = [referenceEvent; trueEvent; "control"];
    eventannotation = repmat("", 3, 1);
    base = row * 10 + (1:3)';
    maxAbsEpoch = base + 1;
    sdEpoch = base + 2;
    invSdEpoch = 1 ./ sdEpoch;
    MeanAbsDiffNorm = [row; row + row; row + 0.25];
    MaxAbsDiffNorm = base + 3;
    RobustSlopeNorm = base / 10;
    AutoCorrLag1Pos = 0.1 + base / 1000;
    AutoCorrLag1Neg = -0.1 - base / 1000;
    KatzFDNorm = 1 + base / 100;
    qc = table(subjectID, sessionID, runID, epoch_index, channel, ...
        eventtype, eventannotation, maxAbsEpoch, sdEpoch, invSdEpoch, ...
        MeanAbsDiffNorm, MaxAbsDiffNorm, RobustSlopeNorm, ...
        AutoCorrLag1Pos, AutoCorrLag1Neg, KatzFDNorm);

    NRFName = repmat("synthetic_nrf", 3, 1);
    template_dur_ms = repmat(100, 3, 1);
    projectionTimes_ms = [-10; 0; 10];
    shift_samples = [-1; 0; 1];
    pearsonR = 0.2 + base / 1000;
    cosineSimilarity = 0.3 + base / 1000;
    olsCoef = base / 20;
    fglsCoef = base / 21;
    fglsVarCoef = base / 22;
    nrf = table(subjectID, sessionID, runID, epoch_index, channel, ...
        eventtype, eventannotation, NRFName, template_dur_ms, ...
        projectionTimes_ms, shift_samples, pearsonR, cosineSimilarity, ...
        olsCoef, fglsCoef, fglsVarCoef);

    n_channels = ones(3, 1);
    n_points = repmat(256, 3, 1);
    indexTable = table(subjectID, sessionID, runID, epoch_index, ...
        eventtype, eventannotation, n_channels, n_points);

    sample = (0:255) / 200;
    data = zeros(1, 256, 3, 'single');
    for epoch = 1:3
        data(1, :, epoch) = single(row + epoch / 10 + ...
            sin(2 * pi * (3 + epoch) * sample));
    end
    epochs = struct();
    epochs.data = data;
    epochs.times_ms = -200 + (0:255) * 5;
    epochs.channels = {'Cz'};
    epochs.epoch_index = (1:3)';
    epochs.eventtype = cellstr(eventtype);
    epochs.eventannotation = {'', '', ''};
    epochs.srate = 200;

    writetable(qc, fullfile(directory, [stem '_qc_features.csv']));
    writetable(nrf, fullfile(directory, [stem '_nrf_features.csv']));
    writetable(indexTable, fullfile(directory, [stem '_epochs_index.csv']));
    save(fullfile(directory, [stem '_epochs.mat']), 'epochs', '-v7');
end
end

function T = read_csv(pathValue)
options = detectImportOptions(pathValue, 'PreserveVariableNames', true, ...
    'TextType', 'string');
textColumns = intersect({'subjectID', 'sessionID', 'runID', 'channel', ...
    'eventtype', 'eventannotation', 'NRFName', 'stem', 'path_summary', ...
    'qc_csv', 'nrf_csv', 'idx_csv', 'epochs_mat'}, ...
    options.VariableNames, 'stable');
if ~isempty(textColumns)
    options = setvartype(options, textColumns, 'string');
end
T = readtable(pathValue, options);
end

function assert_route_ids(T, subjects, sessions, runs)
assert(all(ismember({'subjectID', 'sessionID', 'runID'}, ...
    T.Properties.VariableNames)));
assert(isequal(unique(string(T.subjectID), 'stable'), subjects));
assert(isequal(unique(string(T.sessionID), 'stable'), sessions));
assert(isequal(unique(string(T.runID), 'stable'), runs));
end

function T = science_table(T)
identityColumns = {'subjectID', 'sessionID', 'runID', 'stem', ...
    'path_summary', 'qc_csv', 'nrf_csv', 'idx_csv', 'epochs_mat', ...
    'source_epochs_mat'};
T = removevars(T, intersect(identityColumns, T.Properties.VariableNames));
end

function epochs = science_epochs(epochs, keepExclusion)
identityFields = {'subjectID', 'sessionID', 'runID', 'stem', ...
    'path_summary', 'source_epochs_mat'};
if ~keepExclusion
    identityFields{end + 1} = 'Exclude';
end
epochs = rmfield(epochs, intersect(identityFields, fieldnames(epochs)));
end

function [titleText, figureHandle] = current_viewer_title()
figureHandle = findall(groot, 'Type', 'figure', ...
    'Name', 'SIMPLE Epoch Screening');
assert(isscalar(figureHandle));
state = guidata(figureHandle);
value = string(state.ax.tlo.Title.String);
titleText = join(value(:), newline);
assert(isscalar(titleText) && strlength(titleText) > 0);
end

function value = erase_identity(value, subject, session, run)
tuple = "| " + subject + " | " + session + " | " + run + " |";
value = replace(value, tuple, ...
    "| <subject> | <session> | <run> |");
end

function textValues = collect_downstream_text(route)
values = {route.pooled_qc, route.pooled_nrf, route.pooled_epochs, ...
    route.manifest, route.package, route.viewer_title, ...
    route.screened_qc, route.screened_nrf, route.screened_epochs, ...
    route.excluded_filename, route.separation, route.designated_log};
textValues = strings(0, 1);
for index = 1:numel(values)
    textValues = [textValues; collect_text(values{index})]; %#ok<AGROW>
end
end

function values = collect_text(value)
values = strings(0, 1);
if istable(value)
    for index = 1:width(value)
        name = value.Properties.VariableNames{index};
        values = [values; collect_text(value.(name))]; %#ok<AGROW>
    end
elseif isstruct(value)
    names = fieldnames(value);
    for element = 1:numel(value)
        for index = 1:numel(names)
            values = [values; collect_text(value(element).(names{index}))]; %#ok<AGROW>
        end
    end
elseif iscell(value)
    for index = 1:numel(value)
        values = [values; collect_text(value{index})]; %#ok<AGROW>
    end
elseif ischar(value) || isstring(value) || iscategorical(value)
    current = string(value);
    current = current(~ismissing(current) & strlength(current) > 0);
    values = current(:);
end
end

function assert_no_tokens(values, tokens)
values = lower(string(values));
for index = 1:numel(tokens)
    assert(~any(contains(values, lower(tokens(index)))), ...
        'A mapped downstream surface retained a private source token.');
end
end

function copy_script_with_root(sourcePath, destinationPath, root)
source = fileread(sourcePath);
pattern = 'baseDir\s*=\s*''[^'']+'';';
matches = regexp(source, pattern, 'match');
assert(isscalar(matches), ...
    'Expected one configurable baseDir assignment in %s.', sourcePath);
replacement = sprintf('baseDir = ''%s'';', strrep(root, '''', ''''''));
source = regexprep(source, pattern, replacement, 'once');
if endsWith(sourcePath, 'step_7_check_6_sep_check_qc.m')
    count = count_occurrences(source, 'bootstrap_resamples = 100000;');
    assert(count == 1, 'Unexpected separation bootstrap configuration.');
    source = strrep(source, 'bootstrap_resamples = 100000;', ...
        'bootstrap_resamples = 399;');
end
write_text(destinationPath, source);
end

function count = count_occurrences(value, pattern)
count = numel(strfind(value, pattern));
end

function run_fixture_script(scriptPath)
scriptFolder = fileparts(scriptPath);
cd(scriptFolder);
evalin('base', 'clear;');
diaryCleanup = onCleanup(@() diary('off'));
command = sprintf('run(''%s'');', strrep(scriptPath, '''', ''''''));
evalin('base', command);
end

function write_text(pathValue, value)
fid = fopen(pathValue, 'wt');
assert(fid >= 0, 'Could not create a temporary production-script copy.');
cleanup = onCleanup(@() fclose(fid));
count = fwrite(fid, value, 'char');
assert(count == numel(value));
end

function pathValue = join_file(root, relative, filename)
pathValue = fullfile(join_relative(root, relative), char(filename));
end

function directory = join_relative(root, relative)
parts = cellstr(split(string(relative), '/'));
directory = fullfile(root, parts{:});
end

function digest = sha256_file(pathValue)
engine = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(pathValue, 'rb');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
while true
    bytes = fread(fid, 1024 * 1024, '*uint8');
    if isempty(bytes)
        break
    end
    engine.update(bytes);
end
digest = lower(reshape(dec2hex(typecast(engine.digest(), ...
    'uint8'), 2).', 1, []));
end

function cleanup_suite(root, originalFolder, originalPath, originalVisibility)
diary off;
evalin('base', 'clear;');
close all force;
path(originalPath);
set(groot, 'defaultFigureVisible', originalVisibility);
if isfolder(originalFolder)
    cd(originalFolder);
end
clear build_pseudonymised_dataset_registry inspect_identity_state ...
    inspect_pseudonymisation_inputs ...
    load_dataset_identity_registry run_pseudonymisation_transaction ...
    run_sanitisation_transaction sanitise_eeglab_dataset ...
    verify_sanitised_eeglab_dataset validate_dataset_registry_paths ...
    compute_paired_effect plot_paired_effect_result ...
    save_paired_separation_result log_command_window
if isfolder(root)
    rmdir(root, 's');
end
rehash path;
end

function value = canonical_path(value)
value = char(java.io.File(char(value)).getCanonicalPath());
end
