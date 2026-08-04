%% step_6_screen_1_init_package.m
% Create an immutable, self-contained screening package for epoch–channel rating.
%
% Output:
%   <baseDir>/data/summary/screening/screening_package.mat
%
% Package contents (single struct "package"):
%   - epochs_pooled    : full struct array from pooled_eeg_epochs.mat (self-contained)
%   - items            : flat table, one row per epoch–channel item
%   - qc_values        : numeric matrix [nItems x nQCFeatures], NaN where missing
%   - qc_feature_names : cellstr of QC feature column names used (user-specified)
%   - qc_found         : logical [nItems x 1] (true if any QC row matched the key)
%   - package_hash     : SHA-256 hash tying package to the pooled inputs + feature list
%   - created_utc      : UTC timestamp
%   - source paths     : source_epochs_mat, source_qc_csv
%
% Hard rules:
%   - Refuse to overwrite screening_package.mat if it already exists.
%   - If screening_decisions.mat exists but screening_package.mat does not: error.
%   - QC feature names are user-specified; missing QC column => error.
%   - Duplicate QC rows per key => error.
%   - QC rows not mapping to any epoch–channel item => warn and ignore.
%   - Missing QC rows for an item => keep item; QC values remain NaN.

log_command_window('start');
clear; clc;

%% ───────────────────────────── USER CONFIG ─────────────────────────────
baseDir = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';

pooledDir = fullfile(baseDir, 'data', 'summary', 'pooled');
screenDir = fullfile(baseDir, 'data', 'summary', 'screening');

epochsMat = fullfile(pooledDir, 'pooled_eeg_epochs.mat');        % expects variable epochs_pooled
qcCsv     = fullfile(pooledDir, 'pooled_eeg_qc_features.csv');   % long-format QC table

% QC feature columns to import from pooled_eeg_qc_features.csv (must match headers exactly).
% Default below matches your current pipeline; edit as needed for other datasets.
qcFeatureNames = { ...
    'maxAbsEpoch', ...
    'sdEpoch', ...
    'invSdEpoch', ...
    'MeanAbsDiffNorm', ...
    'MaxAbsDiffNorm', ...
    'RobustSlopeNorm', ...
    'AutoCorrLag1Pos', ...
    'AutoCorrLag1Neg', ...
    'KatzFDNorm' ...
    };

% Output files (fixed names)
packagePath   = fullfile(screenDir, 'screening_package.mat');
decisionsPath = fullfile(screenDir, 'screening_decisions.mat');

%% ───────────────────────────── PRE-FLIGHT ─────────────────────────────
if ~exist(screenDir, 'dir')
    ok = mkdir(screenDir);
    if ~ok
        error('Failed to create screening folder: %s', screenDir);
    end
end

if isfile(packagePath)
    fprintf('[info] screening_package.mat already exists:\n  %s\n', packagePath);
    fprintf('       Refusing to overwrite. Delete/move it if you want to rebuild.\n');
    log_command_window('stop');
    return;
end

if isfile(decisionsPath) && ~isfile(packagePath)
    error('Inconsistent screening folder: decisions exists but package is missing: %s', screenDir);
end

assert(isfile(epochsMat), 'Missing pooled epochs MAT: %s', epochsMat);
assert(isfile(qcCsv),     'Missing pooled QC CSV: %s', qcCsv);

if isempty(qcFeatureNames) || ~iscell(qcFeatureNames)
    error('qcFeatureNames must be a non-empty cell array of QC column names.');
end

%% ───────────────────────────── LOAD EPOCHS ─────────────────────────────
fprintf('[info] Loading pooled epochs MAT:\n  %s\n', epochsMat);
S = load(epochsMat);
assert(isfield(S, 'epochs_pooled'), 'Expected variable "epochs_pooled" in: %s', epochsMat);
epochs_pooled = S.epochs_pooled;

assert(isstruct(epochs_pooled), 'epochs_pooled must be a struct array.');
assert(~isempty(epochs_pooled), 'epochs_pooled is empty.');

% Minimal required fields
reqFields = { ...
    'data','times_ms','channels','epoch_index','eventtype','srate', ...
    'subjectID','sessionID','runID','stem' ...
    };
for f = 1:numel(reqFields)
    if ~isfield(epochs_pooled, reqFields{f})
        error('epochs_pooled is missing required field: %s', reqFields{f});
    end
end

%% ───────────────────── BUILD ITEM INDEX (epoch–channel) ─────────────────────
fprintf('[info] Building flat item index from epochs_pooled...\n');

nDatasets = numel(epochs_pooled);

% First pass: compute total number of items and do minimal per-dataset alignment checks.
totalItems = 0;
for d = 1:nDatasets
    E = epochs_pooled(d);

    if ~isfield(E, 'data') || isempty(E.data) || ndims(E.data) ~= 3
        error('Dataset %d: expected E.data as 3-D array [nCh x nPts x nEp].', d);
    end

    nCh = size(E.data, 1);
    nEp = size(E.data, 3);

    if ~iscell(E.channels) || numel(E.channels) ~= nCh
        error('Dataset %d: E.channels must be a cell array of length nCh.', d);
    end
    if ~iscell(E.eventtype) || numel(E.eventtype) ~= nEp
        error('Dataset %d: E.eventtype must be a cell array of length nEp.', d);
    end
    if ~isnumeric(E.epoch_index) || numel(E.epoch_index) ~= nEp
        error('Dataset %d: E.epoch_index must be numeric vector of length nEp.', d);
    end

    totalItems = totalItems + (nCh * nEp);
end

% Preallocate
item_id       = (1:totalItems).';
dataset_idx   = zeros(totalItems, 1);
epoch_pos     = zeros(totalItems, 1);
channel_pos   = zeros(totalItems, 1);

subjectID     = strings(totalItems, 1);
sessionID     = strings(totalItems, 1);
runID         = strings(totalItems, 1);
stem          = strings(totalItems, 1);

epoch_index   = zeros(totalItems, 1);
channel       = strings(totalItems, 1);
eventtype     = strings(totalItems, 1);
eventannotation = strings(totalItems, 1); % allowed empty

% Fill
k = 0;
for d = 1:nDatasets
    E = epochs_pooled(d);

    nCh = size(E.data, 1);
    nEp = size(E.data, 3);

    % Event annotation is optional; normalise to a cell array of length nEp if present
    annots = repmat({''}, nEp, 1);
    if isfield(E, 'eventannotation') && ~isempty(E.eventannotation)
        if iscell(E.eventannotation) && numel(E.eventannotation) == nEp
            annots = E.eventannotation(:);
        end
    end

    subj = string(E.subjectID);
    sess = string(E.sessionID);
    run  = string(E.runID);
    st   = string(E.stem);

    for c = 1:nCh
        chLabel = string(E.channels{c});
        for e = 1:nEp
            k = k + 1;

            dataset_idx(k) = d;
            epoch_pos(k)   = e;
            channel_pos(k) = c;

            subjectID(k)   = subj;
            sessionID(k)   = sess;
            runID(k)       = run;
            stem(k)        = st;

            epoch_index(k) = double(E.epoch_index(e));
            channel(k)     = chLabel;
            eventtype(k)   = string(E.eventtype{e});

            a = annots{e};
            if isempty(a)
                eventannotation(k) = "";
            else
                eventannotation(k) = string(a);
            end
        end
    end
end

items = table( ...
    item_id, dataset_idx, epoch_pos, channel_pos, ...
    subjectID, sessionID, runID, stem, ...
    epoch_index, channel, eventtype, eventannotation, ...
    'VariableNames', { ...
    'item_id','dataset_idx','epoch_pos','channel_pos', ...
    'subjectID','sessionID','runID','stem', ...
    'epoch_index','channel','eventtype','eventannotation' ...
    } );

% Composite string key for joins (no padding; IDs used exactly as-is)
items_key = items.subjectID + "|" + items.sessionID + "|" + items.runID + "|" + string(items.epoch_index) + "|" + items.channel;

%% ───────────────────────────── LOAD QC CSV ─────────────────────────────
fprintf('[info] Loading pooled QC CSV:\n  %s\n', qcCsv);

opts = detectImportOptions(qcCsv, 'PreserveVariableNames', true, 'TextType', 'string');

% Force key columns to string if present
keyCols = {'subjectID','sessionID','runID','eventtype','eventannotation','channel'};
presentKeyCols = intersect(keyCols, opts.VariableNames, 'stable');
if ~isempty(presentKeyCols)
    opts = setvartype(opts, presentKeyCols, 'string');
end

Tqc = readtable(qcCsv, opts);

% Required columns in QC CSV
reqQC = {'subjectID','sessionID','runID','epoch_index','channel'};
missingReqQC = setdiff(reqQC, Tqc.Properties.VariableNames);
if ~isempty(missingReqQC)
    error('QC CSV missing required column(s): %s', strjoin(missingReqQC, ', '));
end

% QC feature columns must exist (error immediately if any missing)
missingFeat = setdiff(qcFeatureNames, Tqc.Properties.VariableNames);
if ~isempty(missingFeat)
    error('QC CSV missing requested QC feature column(s): %s', strjoin(missingFeat, ', '));
end

% Normalise key columns
Tqc.subjectID = strtrim(string(Tqc.subjectID));
Tqc.sessionID = strtrim(string(Tqc.sessionID));
Tqc.runID     = strtrim(string(Tqc.runID));
Tqc.channel   = strtrim(string(Tqc.channel));

% epoch_index numeric
Tqc.epoch_index = double(Tqc.epoch_index);

% QC features numeric
for f = 1:numel(qcFeatureNames)
    nm = qcFeatureNames{f};
    Tqc.(nm) = double(Tqc.(nm));
end

% Build QC keys
qc_key = Tqc.subjectID + "|" + Tqc.sessionID + "|" + Tqc.runID + "|" + string(Tqc.epoch_index) + "|" + Tqc.channel;

%% ───────────────────── DUPLICATE QC ROW CHECK (ERROR) ─────────────────────
[qc_u, ~, qc_ic] = unique(qc_key, 'stable');
qc_counts = accumarray(qc_ic, 1);

dupMask = qc_counts > 1;
if any(dupMask)
    dupKeys = qc_u(dupMask);
    nShow = min(5, numel(dupKeys));
    msg = "Duplicate QC rows detected for key(s). Example(s):" + newline;
    for i = 1:nShow
        msg = msg + "  " + dupKeys(i) + " (count=" + qc_counts(find(qc_u == dupKeys(i), 1, 'first')) + ")" + newline; %#ok<FNDSB>
    end
    error('%s', char(msg));
end

%% ───────────────────────── LEFT-JOIN QC ONTO ITEMS ─────────────────────────
fprintf('[info] Joining QC onto %d items...\n', height(items));

nItems = height(items);
nFeat  = numel(qcFeatureNames);

qc_values = NaN(nItems, nFeat);
qc_found  = false(nItems, 1);

[isHit, loc] = ismember(items_key, qc_key);

qc_found = isHit;

for f = 1:nFeat
    nm = qcFeatureNames{f};
    tmp = NaN(nItems, 1);
    tmp(isHit) = Tqc.(nm)(loc(isHit));
    qc_values(:, f) = tmp;
end

% Warn about extra QC rows that do not map to any epoch–channel item
qcUsedMask = false(height(Tqc), 1);
qcUsedMask(loc(isHit)) = true;
nExtra = sum(~qcUsedMask);

if nExtra > 0
    warning('Screening:InitPackage:ExtraQCRows', ...
        'QC CSV contains %d row(s) that do not map to any epoch–channel item; ignoring.', nExtra);
end

%% ───────────────────────────── PACKAGE HASH ─────────────────────────────
fprintf('[info] Computing package hash (SHA-256)...\n');
hash_epochs = sha256_file(epochsMat);
hash_qc     = sha256_file(qcCsv);
hash_feats  = sha256_string(strjoin(string(qcFeatureNames), ','));

package_hash = sha256_string(hash_epochs + "|" + hash_qc + "|" + hash_feats);

created_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));

%% ───────────────────────────── BUILD PACKAGE ─────────────────────────────
package = struct();
package.created_utc       = created_utc;
package.baseDir           = baseDir;

package.source_epochs_mat = epochsMat;
package.source_qc_csv     = qcCsv;

package.qc_feature_names  = qcFeatureNames;
package.package_hash      = char(package_hash);

package.epochs_pooled     = epochs_pooled;
package.items             = items;
package.items_key         = items_key;

package.qc_values         = qc_values;
package.qc_found          = qc_found;

%% ───────────────────────────── SAVE PACKAGE ─────────────────────────────
fprintf('[info] Saving screening package:\n  %s\n', packagePath);
try
    save(packagePath, 'package', '-v7');
catch ME
    warning('Screening:InitPackage:SaveV7Failed', ...
        'Saving with -v7 failed (%s). Retrying with -v7.3.', ME.message);
    save(packagePath, 'package', '-v7.3');
end

fprintf('[done] Created screening_package.mat\n');
fprintf('  Datasets: %d\n', numel(epochs_pooled));
fprintf('  Items:    %d\n', height(items));
fprintf('  QC feats: %d\n', numel(qcFeatureNames));
fprintf('  QC hits:  %d (missing: %d)\n', sum(qc_found), sum(~qc_found));
fprintf('  Hash:     %s\n', package.package_hash);

log_command_window('stop');

%% ───────────────────────────── Local helpers ─────────────────────────────
function h = sha256_file(filePath)
%SHA256_FILE Compute SHA-256 hash of a file using streaming Java digest.
if ~isfile(filePath)
    error('sha256_file:FileNotFound', 'File not found: %s', filePath);
end

try
    md = java.security.MessageDigest.getInstance('SHA-256');
    fis = java.io.FileInputStream(java.io.File(filePath));

    % 1 MiB buffer (reasonable compromise)
    bufSize = 1024 * 1024;
    buffer  = zeros(1, bufSize, 'int8');

    while true
        n = fis.read(buffer, 0, bufSize);
        if n == -1
            break;
        end
        md.update(buffer(1:n));
    end

    fis.close();
    d = md.digest();          % int8 array
    h = bytes2hex(d);

catch ME
    % Best-effort close if partially opened
    try %#ok<TRYNC>
        if exist('fis', 'var') && ~isempty(fis)
            fis.close();
        end
    end
    rethrow(ME);
end
end

function h = sha256_string(s)
%SHA256_STRING Compute SHA-256 hash of a UTF-8 string using Java digest.
md = java.security.MessageDigest.getInstance('SHA-256');
bytes = unicode2native(char(s), 'UTF-8'); % uint8 row vector
md.update(int8(bytes));
d = md.digest();
h = bytes2hex(d);
end

function h = bytes2hex(javaInt8Array)
%BYTES2HEX Convert Java int8[] digest into lowercase hex char vector.
u = typecast(javaInt8Array, 'uint8');
h = lower(reshape(dec2hex(u, 2).', 1, []));
end