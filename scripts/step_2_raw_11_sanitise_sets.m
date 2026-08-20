%% step_2_raw_11_sanitise_sets.m
% Optional Step 2 route: sanitise embedded metadata in the active mapped SETs.
%
% Prerequisite: step_2_raw_10_pseudonymise_ids.m completed successfully.
% This script never changes data/raw_orig or the private identity mapping.

log_command_window('start');
clear; clc;

try

fprintf('step_2_raw_11_sanitise_sets.m\n');

scriptPath = mfilename('fullpath');
scriptsDir = fileparts(scriptPath);
[repositoryRoot, scriptsLeaf] = fileparts(scriptsDir);
if ~strcmp(scriptsLeaf, 'scripts')
    error('SIMPLE:Step2Sanitise:ScriptLocation', ...
        'This workflow script must remain in the repository scripts folder.');
end
if ~canonical_equal(pwd, scriptsDir)
    error('SIMPLE:Step2Sanitise:WorkingDirectory', ...
        'Run this script with the current MATLAB folder set to scripts.');
end

functionsDir = fullfile(repositoryRoot, 'functions');

% Step 2.11 verifies every candidate with EEGLAB. Start EEGLAB before adding
% repository helpers because EEGLAB adds and reorders its own paths.
assert(exist('eeglab', 'file') == 2, 'EEGLAB not found on path.');
eeglab;
assert(exist('pop_loadset', 'file') == 2 && ...
    exist('eeg_checkset', 'file') == 2, ...
    'Required EEGLAB SET verification functions are unavailable.');

addpath(functionsDir, '-begin');
requiredHelpers = { ...
    'load_dataset_identity_registry', ...
    'build_pseudonymised_dataset_registry', ...
    'inspect_pseudonymisation_inputs', ...
    'inspect_identity_state', ...
    'run_sanitisation_transaction', ...
    'sanitise_eeglab_dataset', ...
    'verify_sanitised_eeglab_dataset'};
for helperIndex = 1:numel(requiredHelpers)
    helperName = requiredHelpers{helperIndex};
    clear(helperName);
    rehash path;
    activeHelper = which(helperName);
    expectedHelper = fullfile(functionsDir, [helperName '.m']);
    if isempty(activeHelper) || ...
            ~canonical_equal(activeHelper, expectedHelper)
        error('SIMPLE:Step2Sanitise:HelperResolution', ...
            'A required repository-local Step 2.11 helper is not active.');
    end
end

result = run_sanitisation_transaction(repositoryRoot);
fprintf('Status: %s\n', result.status);
fprintf('Recordings governed: %d | verified: %d\n', ...
    result.recording_count, result.verified_count);
if result.recovered
    fprintf('Recovery completed. Run this script again separately to sanitise.\n');
elseif result.no_op
    fprintf('No files changed; the completed sanitised route was re-verified.\n');
else
    fprintf('The mapped active SET metadata are sanitised and verified.\n');
end

catch ME
    log_command_window('stop');
    rethrow(ME);
end
log_command_window('stop');

function tf = canonical_equal(first, second)
first = char(java.io.File(char(first)).getCanonicalPath());
second = char(java.io.File(char(second)).getCanonicalPath());
if ispc
    tf = strcmpi(first, second);
else
    tf = strcmp(first, second);
end
end
