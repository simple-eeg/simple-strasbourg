%% step_6_screen_3_apply_decisions.m
% Apply epoch–channel screening decisions to pooled outputs.
%
% Inputs (must already exist):
%   <baseDir>/data/summary/pooled/
%       pooled_eeg_epochs.mat           (variable: epochs_pooled)
%       pooled_eeg_qc_features.csv
%       pooled_eeg_nrf_features.csv
%   <baseDir>/data/summary/screening/
%       screening_package.mat           (variable: package)
%       screening_decisions.mat         (variable: decisions)
%
% Outputs (idempotently overwritten):
%   <baseDir>/data/summary/screening/
%       pooled_screened_eeg_epochs.mat          (variable: epochs_pooled; adds field Exclude)
%       pooled_screened_eeg_qc_features.csv     (adds column Exclude, numeric 0/1)
%       pooled_screened_eeg_nrf_features.csv    (adds column Exclude, numeric 0/1)
%
% Core rules
%   - Refuse to run if screeningDir is missing.
%   - Refuse to run if screening_package.mat or screening_decisions.mat missing.
%   - Refuse to run if pooled QC/NRF CSV already contain an "Exclude" column.
%   - For CSVs: every row must map to an item key in package.items_key; otherwise ERROR.
%   - It is OK if some items have no QC/NRF rows (items exist in MAT but not in a CSV).
%   - Preserve input CSV row order exactly; append Exclude as the last column.
%   - Screened MAT must preserve epochs_pooled ordering and structure; only add Exclude.
%   - Validate package_hash against current pooled epochs MAT + pooled QC CSV + feature list.

log_command_window('start');
clear; clc;

%% ───────────────────────────── USER CONFIG ─────────────────────────────
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';

pooledDir    = fullfile(baseDir, 'data', 'summary', 'pooled');
screeningDir = fullfile(baseDir, 'data', 'summary', 'screening');

% Inputs
epochsMat_in = fullfile(pooledDir, 'pooled_eeg_epochs.mat');
qcCsv_in     = fullfile(pooledDir, 'pooled_eeg_qc_features.csv');
nrfCsv_in    = fullfile(pooledDir, 'pooled_eeg_nrf_features.csv');

packagePath   = fullfile(screeningDir, 'screening_package.mat');
decisionsPath = fullfile(screeningDir, 'screening_decisions.mat');

% Outputs (overwrite)
epochsMat_out = fullfile(screeningDir, 'pooled_screened_eeg_epochs.mat');
qcCsv_out     = fullfile(screeningDir, 'pooled_screened_eeg_qc_features.csv');
nrfCsv_out    = fullfile(screeningDir, 'pooled_screened_eeg_nrf_features.csv');

%% ───────────────────────────── PRE-FLIGHT ─────────────────────────────
fprintf('Applying screening decisions to pooled outputs.\n');

assert(exist(screeningDir, 'dir') == 7, ...
    'screeningDir does not exist (expected): %s', screeningDir);

assert(isfile(packagePath),   'Missing screening_package.mat: %s', packagePath);
assert(isfile(decisionsPath), 'Missing screening_decisions.mat: %s', decisionsPath);

assert(isfile(epochsMat_in), 'Missing pooled epochs MAT: %s', epochsMat_in);
assert(isfile(qcCsv_in),     'Missing pooled QC CSV: %s', qcCsv_in);
assert(isfile(nrfCsv_in),    'Missing pooled NRF CSV: %s', nrfCsv_in);

%% ───────────────────────────── LOAD PACKAGE ────────────────────────────
fprintf('\n[1/5] Loading screening_package.mat...\n  %s\n', packagePath);
P = load(packagePath);
assert(isfield(P, 'package'), 'screening_package.mat must contain variable "package".');
package = P.package;

needPkg = {'package_hash','items','items_key','epochs_pooled','qc_feature_names'};
for k = 1:numel(needPkg)
    assert(isfield(package, needPkg{k}), 'package.%s missing from screening_package.mat', needPkg{k});
end
assert(istable(package.items), 'package.items must be a table.');
assert(isstring(package.items_key), 'package.items_key must be a string array.');
assert(numel(package.items_key) == height(package.items), 'package.items_key length mismatch vs items height.');

% Normalise package_hash to char
if isstring(package.package_hash) && isscalar(package.package_hash)
    package.package_hash = char(package.package_hash);
end
assert(ischar(package.package_hash), 'package.package_hash must be char or a string scalar convertible to char.');

nItems = height(package.items);

%% ───────────────────────────── LOAD DECISIONS ──────────────────────────
fprintf('\n[2/5] Loading screening_decisions.mat...\n  %s\n', decisionsPath);
D = load(decisionsPath);
assert(isfield(D, 'decisions'), 'screening_decisions.mat must contain variable "decisions".');
decisions = D.decisions;

needDec = {'exclude_mask','package_hash','last_saved_utc'};
for k = 1:numel(needDec)
    assert(isfield(decisions, needDec{k}), 'decisions.%s missing from screening_decisions.mat', needDec{k});
end
assert(islogical(decisions.exclude_mask), 'decisions.exclude_mask must be logical.');
assert(numel(decisions.exclude_mask) == nItems, ...
    'decisions.exclude_mask length mismatch (expected %d).', nItems);

% Normalise decisions.package_hash to char
if isstring(decisions.package_hash) && isscalar(decisions.package_hash)
    decisions.package_hash = char(decisions.package_hash);
end
assert(ischar(decisions.package_hash), 'decisions.package_hash must be char or a string scalar convertible to char.');

assert(strcmp(decisions.package_hash, package.package_hash), ...
    'Package hash mismatch: decisions do not correspond to this screening_package.mat.');

nExcluded = sum(decisions.exclude_mask);
nIncluded = nItems - nExcluded;
pctExcluded = 100 * (nExcluded / max(1, nItems));

fprintf('  Items: %d | Included: %d | Excluded: %d (%.1f%%)\n', nItems, nIncluded, nExcluded, pctExcluded);
fprintf('  last_saved_utc: %s\n', decisions.last_saved_utc);

%% ───────────────────── VERIFY PACKAGE HASH AGAINST INPUTS ──────────────
fprintf('\n[3/5] Verifying package hash against current pooled inputs...\n');

% Normalise qc_feature_names to a single comma-separated string (same as init script)
qcFeat = package.qc_feature_names;
if isstring(qcFeat)
    qcFeat = cellstr(qcFeat);
end
assert(iscell(qcFeat) && ~isempty(qcFeat), 'package.qc_feature_names must be a non-empty cell/string array.');
qcFeat = cellfun(@char, qcFeat, 'UniformOutput', false);

hash_epochs = sha256_file(epochsMat_in);
hash_qc     = sha256_file(qcCsv_in);
hash_feats  = sha256_string(strjoin(string(qcFeat), ','));

pkg_hash_now = sha256_string(string(hash_epochs) + "|" + string(hash_qc) + "|" + string(hash_feats));
pkg_hash_now = char(pkg_hash_now);

assert(strcmp(pkg_hash_now, package.package_hash), ...
    ['Package hash does not match current pooled epochs/QC inputs. ', ...
    'You likely rebuilt pooled files or changed QC feature list after creating screening_package.mat.']);

% Optional: warn if recorded source paths differ from what we are using now
if isfield(package, 'source_epochs_mat') && ~isempty(package.source_epochs_mat)
    try
        if ~strcmp(char(package.source_epochs_mat), epochsMat_in)
            warning('Screening:Apply:SourcePathMismatch', ...
                'package.source_epochs_mat differs from current epochsMat_in (hash still matches).');
        end
    catch
        % ignore
    end
end
if isfield(package, 'source_qc_csv') && ~isempty(package.source_qc_csv)
    try
        if ~strcmp(char(package.source_qc_csv), qcCsv_in)
            warning('Screening:Apply:SourcePathMismatch', ...
                'package.source_qc_csv differs from current qcCsv_in (hash still matches).');
        end
    catch
        % ignore
    end
end

fprintf('  package_hash verified.\n');

%% ───────────────────── APPLY TO POOLED_EEG_EPOCHS.MAT ──────────────────
fprintf('\n[4/5] Applying Exclude mask into pooled_eeg_epochs.mat...\n');
S = load(epochsMat_in);
assert(isfield(S, 'epochs_pooled'), 'Expected variable "epochs_pooled" in: %s', epochsMat_in);
epochs_pooled = S.epochs_pooled;

assert(isstruct(epochs_pooled) && ~isempty(epochs_pooled), 'epochs_pooled must be a non-empty struct array.');
nDatasets = numel(epochs_pooled);

% Confirm dataset keys and order match package.epochs_pooled exactly
pkg_epochs = package.epochs_pooled;
assert(isstruct(pkg_epochs) && numel(pkg_epochs) == nDatasets, ...
    'package.epochs_pooled count mismatch vs pooled_eeg_epochs.mat.');

keys_in  = dataset_keys_from_epochs(epochs_pooled);
keys_pkg = dataset_keys_from_epochs(pkg_epochs);

assert(isequal(keys_in, keys_pkg), ...
    ['pooled_eeg_epochs.mat does not match package.epochs_pooled exactly (keys/order mismatch). ', ...
    'Refusing to write screened MAT.']);

% Ensure pooled input has no existing Exclude field (pre-screening expectation)
if isfield(epochs_pooled, 'Exclude')
    error('pooled_eeg_epochs.mat already contains field "Exclude". This should not happen pre-screening.');
end

% Required item columns
needCols = {'item_id','dataset_idx','epoch_pos','channel_pos'};
missCols = setdiff(string(needCols), string(package.items.Properties.VariableNames));
assert(isempty(missCols), 'package.items missing required columns: %s', strjoin(cellstr(missCols), ', '));

% Defensive: ensure item_id is 1..N and aligns with decisions vector indexing
item_id = double(package.items.item_id);
assert(all(item_id(:) == (1:nItems)'), 'package.items.item_id must be exactly 1..N in order.');

% Precompute per-item indices
ds_idx = double(package.items.dataset_idx);
ep_pos = double(package.items.epoch_pos);
ch_pos = double(package.items.channel_pos);

% Apply per dataset
exclude_mats_written = 0;
for d = 1:nDatasets
    E = epochs_pooled(d);
    assert(isfield(E, 'data') && ndims(E.data) == 3, 'Dataset %d: expected E.data as 3-D array.', d);

    nCh = size(E.data, 1);
    nEp = size(E.data, 3);

    rows = find(ds_idx == d);
    if isempty(rows)
        % Should not happen: package items were built from epochs_pooled
        error('Dataset %d: no items found in package.items for this dataset_idx.', d);
    end
    if numel(rows) ~= (nCh * nEp)
        error('Dataset %d: items count mismatch (items=%d, expected=%d=nCh*nEp).', d, numel(rows), nCh*nEp);
    end

    Ex = false(nCh, nEp); % logical mask in MAT (MATLAB-idiomatic)
    lin = sub2ind([nCh, nEp], ch_pos(rows), ep_pos(rows));
    Ex(lin) = decisions.exclude_mask(item_id(rows));

    % Attach without changing anything else
    epochs_pooled(d).Exclude = Ex;
    exclude_mats_written = exclude_mats_written + 1;
end

% Save screened MAT (same variable name: epochs_pooled)
try
    save(epochsMat_out, 'epochs_pooled', '-v7');
    fprintf('  Wrote screened epochs MAT (-v7): %s\n', epochsMat_out);
catch ME
    warning('Screening:Apply:SaveV7Failed', ...
        'Saving screened epochs MAT with -v7 failed (%s). Retrying with -v7.3.', ME.message);
    save(epochsMat_out, 'epochs_pooled', '-v7.3');
    fprintf('  Wrote screened epochs MAT (-v7.3): %s\n', epochsMat_out);
end
fprintf('  Datasets updated with Exclude: %d / %d\n', exclude_mats_written, nDatasets);

%% ───────────────────── APPLY TO POOLED CSVs (QC + NRF) ─────────────────
fprintf('\n[5/5] Applying Exclude column into pooled CSVs...\n');

items_key = package.items_key;

% --- QC CSV ---
fprintf('  Loading pooled QC CSV:\n    %s\n', qcCsv_in);

optsQC = detectImportOptions(qcCsv_in, 'PreserveVariableNames', true, 'TextType', 'string');

forceStr = {'subjectID','sessionID','runID','channel','eventtype','eventannotation'};
forceStr = intersect(forceStr, optsQC.VariableNames, 'stable');
if ~isempty(forceStr)
    optsQC = setvartype(optsQC, forceStr, 'string');
end

Tqc = readtable(qcCsv_in, optsQC);

assert(~any(strcmp(Tqc.Properties.VariableNames, 'Exclude')), ...
    'pooled_eeg_qc_features.csv already contains column "Exclude". This should not happen pre-screening.');

reqQC = {'subjectID','sessionID','runID','epoch_index','channel'};
missQC = setdiff(reqQC, Tqc.Properties.VariableNames);
if ~isempty(missQC)
    error('QC CSV missing required column(s): %s', strjoin(missQC, ', '));
end

qc_key = make_row_keys(Tqc);
[hit_qc, loc_qc] = ismember(qc_key, items_key);

if ~all(hit_qc)
    report_missing_keys('QC', qc_key, hit_qc);
end

Tqc.Exclude = uint8(decisions.exclude_mask(loc_qc)); % numeric 0/1 in CSV
writetable(Tqc, qcCsv_out);
fprintf('  Wrote screened QC CSV:  %s  (rows=%d)\n', qcCsv_out, height(Tqc));

% --- NRF CSV ---
fprintf('  Loading pooled NRF CSV:\n    %s\n', nrfCsv_in);

optsNRF = detectImportOptions(nrfCsv_in, 'PreserveVariableNames', true, 'TextType', 'string');

forceStr = {'subjectID','sessionID','runID','channel','eventtype','eventannotation','NRFName'};
forceStr = intersect(forceStr, optsNRF.VariableNames, 'stable');
if ~isempty(forceStr)
    optsNRF = setvartype(optsNRF, forceStr, 'string');
end

Tnrf = readtable(nrfCsv_in, optsNRF);

assert(~any(strcmp(Tnrf.Properties.VariableNames, 'Exclude')), ...
    'pooled_eeg_nrf_features.csv already contains column "Exclude". This should not happen pre-screening.');

reqNRF = {'subjectID','sessionID','runID','epoch_index','channel'};
missNRF = setdiff(reqNRF, Tnrf.Properties.VariableNames);
if ~isempty(missNRF)
    error('NRF CSV missing required column(s): %s', strjoin(missNRF, ', '));
end

nrf_key = make_row_keys(Tnrf);
[hit_nrf, loc_nrf] = ismember(nrf_key, items_key);

if ~all(hit_nrf)
    report_missing_keys('NRF', nrf_key, hit_nrf);
end

Tnrf.Exclude = uint8(decisions.exclude_mask(loc_nrf)); % numeric 0/1 in CSV
writetable(Tnrf, nrfCsv_out);
fprintf('  Wrote screened NRF CSV: %s  (rows=%d)\n', nrfCsv_out, height(Tnrf));

%% ───────────────────────────── FINAL SUMMARY ──────────────────────────
fprintf('\nDONE.\n');
fprintf('  Inputs:\n');
fprintf('    epochs: %s\n', epochsMat_in);
fprintf('    QC CSV: %s\n', qcCsv_in);
fprintf('    NRFCSV: %s\n', nrfCsv_in);
fprintf('    package: %s\n', packagePath);
fprintf('    decisions: %s\n', decisionsPath);
fprintf('  Outputs:\n');
fprintf('    epochs: %s\n', epochsMat_out);
fprintf('    QC CSV: %s\n', qcCsv_out);
fprintf('    NRFCSV: %s\n', nrfCsv_out);
fprintf('  Items: %d | Excluded: %d (%.1f%%)\n', nItems, nExcluded, pctExcluded);

log_command_window('stop');

%% ───────────────────────────── Local helpers ───────────────────────────

function keys = dataset_keys_from_epochs(epochs_pooled)
% Build dataset keys used for strict equality checks (order-sensitive).
% Includes stem as an extra safeguard.
n = numel(epochs_pooled);
keys = strings(n,1);
for i = 1:n
    E = epochs_pooled(i);
    keys(i) = string(E.subjectID) + "|" + string(E.sessionID) + "|" + string(E.runID) + "|" + string(E.stem);
end
end

function row_key = make_row_keys(T)
% Build join keys for pooled QC/NRF rows:
%   subjectID|sessionID|runID|epoch_index|channel
% Matching is case-sensitive and whitespace-trimmed.
subj = strtrim(string(T.subjectID));
sess = strtrim(string(T.sessionID));
run  = strtrim(string(T.runID));
chan = strtrim(string(T.channel));

% epoch_index: coerce to double, then to string (integer-like expected)
ep = double(T.epoch_index);
if any(~isfinite(ep))
    error('Found non-finite epoch_index values in CSV table.');
end
ep_str = string(ep);

row_key = subj + "|" + sess + "|" + run + "|" + ep_str + "|" + chan;
end

function report_missing_keys(label, keys, hitMask)
missing = keys(~hitMask);
nMiss = numel(missing);
nShow = min(10, nMiss);

msg = sprintf('%s CSV contains %d row(s) that do not map to any screening item key. This is an error.\n', label, nMiss);
msg = [msg, sprintf('Example missing key(s) (up to %d shown):\n', nShow)]; %#ok<AGROW>
for i = 1:nShow
    msg = [msg, sprintf('  %s\n', missing(i))]; %#ok<AGROW>
end
error('%s', msg);
end

function h = sha256_file(filePath)
% Compute SHA-256 hash of a file using streaming Java digest.
if ~isfile(filePath)
    error('sha256_file:FileNotFound', 'File not found: %s', filePath);
end

md = java.security.MessageDigest.getInstance('SHA-256');
fis = java.io.FileInputStream(java.io.File(filePath));

bufSize = 1024 * 1024; % 1 MiB buffer
buffer  = zeros(1, bufSize, 'int8');

cleanup = onCleanup(@() try_close(fis));

while true
    n = fis.read(buffer, 0, bufSize);
    if n == -1
        break;
    end
    md.update(buffer(1:n));
end

d = md.digest();
h = bytes2hex(d);
end

function h = sha256_string(s)
% Compute SHA-256 hash of a UTF-8 string using Java digest.
md = java.security.MessageDigest.getInstance('SHA-256');
bytes = unicode2native(char(s), 'UTF-8');
md.update(int8(bytes));
d = md.digest();
h = bytes2hex(d);
end

function h = bytes2hex(javaInt8Array)
u = typecast(javaInt8Array, 'uint8');
h = lower(reshape(dec2hex(u, 2).', 1, []));
end

function try_close(fis)
try %#ok<TRYNC>
    if ~isempty(fis)
        fis.close();
    end
end
end