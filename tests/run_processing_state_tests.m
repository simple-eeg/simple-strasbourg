function result = run_processing_state_tests(repoRoot)
%RUN_PROCESSING_STATE_TESTS Exercise source-bound option and NRF state logic.

arguments
    repoRoot (1,:) char
end

temporaryRoot = tempname;
mkdir(temporaryRoot);
cleanup = onCleanup(@() cleanup_probe(temporaryRoot)); %#ok<NASGU>

preprocessingScript = select_one_script(repoRoot, { ...
    'step_1_proc_4_preprocessing.m', ...
    'step_3_proc_4_preprocessing.m'});
preprocessingSource = fileread(preprocessingScript);
adjustmentBlock = text_between(preprocessingSource, ...
    '        % Idempotence: only resample if current rate differs from target.', ...
    '        EEG_clean = preproc(EEG, optsA);');
effectiveBlock = text_between(preprocessingSource, ...
    '        eff = struct();', ...
    '        eff.srate              = PreprocOptions.srate;');
processingProbe = ...
    "function [optsA, eff] = processing_options_probe(optsA, PreprocOptions, EEG)" + newline + ...
    string(adjustmentBlock) + string(effectiveBlock) + "end" + newline;
write_text(fullfile(temporaryRoot, 'processing_options_probe.m'), ...
    processingProbe);

nrfScript = select_one_script(repoRoot, { ...
    'step_2_quant_3_NRF_feature_extraction.m', ...
    'step_4_quant_3_NRF_feature_extraction.m'});
nrfSource = fileread(nrfScript);
clearBlock = text_between(nrfSource, ...
    '    % --- Detect and clear previous NRF results (keep QC subtree intact) ---', ...
    '    % Dataset-level zero_t (ms): time from epoch start to the stimulus "0 ms"');
saveExpression = regexp(nrfSource, ...
    'if\s+(fits_done\s*>\s*0\s*\|\|\s*had_previous_nrf)', ...
    'tokens', 'once');
assert(~isempty(saveExpression), 'NRF save-after-clear expression was not found.');
nrfProbe = ...
    "function [EEG, had_previous_nrf, should_save] = nrf_state_probe(EEG, fits_done)" + newline + ...
    "nEpochs = numel(EEG.epoch);" + newline + string(clearBlock) + ...
    "should_save = " + string(saveExpression{1}) + ";" + newline + ...
    "end" + newline;
write_text(fullfile(temporaryRoot, 'nrf_state_probe.m'), nrfProbe);

addpath(temporaryRoot, '-begin');
clear processing_options_probe nrf_state_probe
rehash path

result = struct();
result.preprocessing = run_preprocessing_cases();
result.nrf = run_nrf_cases();
result.total = result.preprocessing + result.nrf;
fprintf('PROCESSING STATE TESTS PASSED: preprocessing=%d, nrf=%d\n', ...
    result.preprocessing, result.nrf);
end

function passed = run_preprocessing_cases()
passed = 0;
requested = struct('srate', 500, 'refchan', {{'Fz', 'Missing'}});
options = struct('reref', true, 'refchan', {{'Fz', 'Missing'}}, ...
    'resample', true);

EEG = struct('srate', 500, 'chanlocs', struct('labels', 'Fz'));
[adjusted, effective] = processing_options_probe(options, requested, EEG);
assert(~adjusted.resample && effective.resample == false);
assert(adjusted.reref && isequal(adjusted.refchan, {'Fz'}));
assert(effective.reref && isequal(effective.refchan, {'Fz'}));
passed = passed + 1;

EEG = struct('srate', 1000);
[adjusted, effective] = processing_options_probe(options, requested, EEG);
assert(adjusted.resample && effective.resample);
assert(~adjusted.reref && ~effective.reref && isempty(effective.refchan));
passed = passed + 1;

EEG = struct('srate', 1000, 'chanlocs', struct('labels', 'Cz'));
[adjusted, effective] = processing_options_probe(options, requested, EEG);
assert(~adjusted.reref && ~effective.reref && isempty(effective.refchan));
passed = passed + 1;

EEG = struct('srate', 1000, 'chanlocs', ...
    struct('labels', {'Fz', 'Missing'}));
[adjusted, effective] = processing_options_probe(options, requested, EEG);
assert(adjusted.reref && effective.reref);
assert(isequal(adjusted.refchan, requested.refchan));
assert(isequal(effective.refchan, requested.refchan));
passed = passed + 1;
end

function passed = run_nrf_cases()
passed = 0;
QC = struct('sentinel', 17);
prior = struct('Cz', struct('noxious_NRF_500Hz', struct('pearsonR', 1)));
EEG = struct('epoch', struct('QC', QC, 'NRF', prior));
[cleared, hadPrevious, shouldSave] = nrf_state_probe(EEG, 0);
assert(hadPrevious && shouldSave);
assert(isempty(fieldnames(cleared.epoch.NRF)));
assert(isequal(cleared.epoch.QC, QC));
passed = passed + 1;

EEG = struct('epoch', struct('QC', QC, 'NRF', struct()));
[cleared, hadPrevious, shouldSave] = nrf_state_probe(EEG, 0);
assert(~hadPrevious && ~shouldSave);
assert(isempty(fieldnames(cleared.epoch.NRF)));
passed = passed + 1;

EEG = struct('epoch', struct('QC', QC));
[cleared, hadPrevious, shouldSave] = nrf_state_probe(EEG, 0);
assert(~hadPrevious && ~shouldSave);
assert(isempty(fieldnames(cleared.epoch.NRF)));
passed = passed + 1;

[~, hadPrevious, shouldSave] = nrf_state_probe(EEG, 3);
assert(~hadPrevious && shouldSave);
passed = passed + 1;

EEG = struct('epoch', struct('QC', QC, 'NRF', 42));
[cleared, hadPrevious, shouldSave] = nrf_state_probe(EEG, 0);
assert(hadPrevious && shouldSave);
assert(isempty(fieldnames(cleared.epoch.NRF)));
passed = passed + 1;
end

function value = text_between(text, startMarker, endMarker)
startIndex = strfind(text, startMarker);
endIndex = strfind(text, endMarker);
assert(numel(startIndex) == 1, 'Expected one start marker: %s', startMarker);
assert(numel(endIndex) == 1, 'Expected one end marker: %s', endMarker);
assert(startIndex < endIndex, 'Source markers are out of order.');
value = text(startIndex:endIndex - 1);
end

function scriptPath = select_one_script(repoRoot, names)
paths = cellfun(@(name) fullfile(repoRoot, 'scripts', name), names, ...
    'UniformOutput', false);
present = cellfun(@isfile, paths);
assert(nnz(present) == 1, ...
    'Expected exactly one repository-stage script from: %s', ...
    strjoin(names, ', '));
scriptPath = paths{find(present, 1)};
end

function write_text(filePath, value)
fid = fopen(filePath, 'wt');
assert(fid >= 0, 'Could not create source-bound probe: %s', filePath);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
textValue = char(value);
count = fwrite(fid, textValue, 'char');
assert(count == numel(textValue));
end

function cleanup_probe(root)
if path_contains(root)
    rmpath(root);
end
clear processing_options_probe nrf_state_probe
rehash path
if isfolder(root)
    rmdir(root, 's');
end
end

function tf = path_contains(root)
entries = strsplit(path, pathsep);
canonicalRoot = char(java.io.File(root).getCanonicalPath());
tf = any(cellfun(@(entry) ~isempty(entry) && strcmp( ...
    char(java.io.File(entry).getCanonicalPath()), canonicalRoot), entries));
end
