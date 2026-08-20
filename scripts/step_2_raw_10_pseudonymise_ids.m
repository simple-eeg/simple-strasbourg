%% step_2_raw_10_pseudonymise_ids.m
% Optionally replace study identifiers after Step 2.9.
%
% This script creates the private ten-column identity map, preserves the
% complete original raw tree as data/raw_orig, and builds the replacement-ID
% active data/raw tree without changing any admitted SET bytes.

log_command_window('start');
clear; clc;
try

%% Repository-local paths and helper binding
scriptPath = mfilename('fullpath');
scriptsDir = fileparts(scriptPath);
[baseDir, scriptsLeaf] = fileparts(scriptsDir);
if ~strcmp(scriptsLeaf, 'scripts')
    error('SIMPLE:Step2Identity:ScriptLocation', ...
        'This script must remain in the repository scripts folder.');
end
if ~strcmp(char(java.io.File(pwd).getCanonicalPath()), ...
        char(java.io.File(scriptsDir).getCanonicalPath()))
    error('SIMPLE:Step2Identity:CurrentFolder', ...
        'Run this script with the repository scripts folder as the current folder.');
end
functionsDir = fullfile(baseDir, 'functions');
addpath(functionsDir, '-begin');
clear load_dataset_identity_registry build_pseudonymised_dataset_registry ...
    inspect_pseudonymisation_inputs inspect_identity_state ...
    run_pseudonymisation_transaction
rehash path

requiredHelpers = {'load_dataset_identity_registry', ...
    'build_pseudonymised_dataset_registry', ...
    'inspect_pseudonymisation_inputs', ...
    'inspect_identity_state', ...
    'run_pseudonymisation_transaction'};
for helperIndex = 1:numel(requiredHelpers)
    helperName = requiredHelpers{helperIndex};
    expectedHelper = char(java.io.File(fullfile(functionsDir, ...
        [helperName '.m'])).getCanonicalPath());
    activeHelper = which(helperName);
    if isempty(activeHelper) || ~strcmp(char(java.io.File( ...
            activeHelper).getCanonicalPath()), expectedHelper)
        error('SIMPLE:Step2Identity:HelperResolution', ...
            'Repository-local helper resolution failed for %s.', helperName);
    end
end

fprintf('step_2_raw_10_pseudonymise_ids.m\n');
result = run_pseudonymisation_transaction(baseDir);
fprintf('Status: %s | recordings: %d | admitted bytes: %0.0f\n', ...
    result.status, result.row_count, result.admitted_bytes);

log_command_window('stop');
catch ME
    log_command_window('stop');
    rethrow(ME)
end
