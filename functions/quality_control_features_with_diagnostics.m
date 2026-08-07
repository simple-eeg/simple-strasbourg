function EEG = quality_control_features_with_diagnostics(EEG, datasetRow, sourceFile)
% Run SIMPLE QC while making robust-fit warnings attributable to one record.

warningID = 'stats:statrobustfit:IterationLimit';
iterationState = warning('query', warningID);
backtraceState = warning('query', 'backtrace');
verboseState = warning('query', 'verbose');
[lastMessage, lastID] = lastwarn;
stateCleanup = onCleanup(@() restore_warning_state(iterationState, ...
    backtraceState, verboseState, lastMessage, lastID)); %#ok<NASGU>

fprintf('   [QC diagnostics] dataset_list row %d | processed file: %s\n', ...
    datasetRow, sourceFile);
warning('on', warningID);
warning('on', 'backtrace');
warning('on', 'verbose');

EEG = quality_control_features(EEG);
end

function restore_warning_state(iterationState, backtraceState, verboseState, ...
    lastMessage, lastID)
warning(iterationState);
warning(backtraceState);
warning(verboseState);
lastwarn(lastMessage, lastID);
end
