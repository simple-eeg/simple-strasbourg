%% step_5_sum_3_summarise_pooled.m
% Purpose
%   Pool (concatenate) all per-dataset EEG summary outputs produced by Step 5.2
%   into project-level "pooled" files. This script does NOT transform or derive
%   any new features; it simply reads, type-stabilizes, validates lightly, and
%   concatenates data as-is.
%
% Inputs (spreadsheet-led discovery)
%   <baseDir>/data_lists/dataset_list.csv   (must contain columns:)
%     subjectID, sessionID, runID, EEGfile_processed, path_summary
%
%   For each spreadsheet row whose path_summary is non-empty, this script expects
%   the following files to exist under: <baseDir>/<path_summary>/
%     <stem>_qc_features.csv
%     <stem>_nrf_features.csv
%     <stem>_epochs_index.csv
%     <stem>_epochs.mat
%   where <stem> is EEGfile_processed without the ".set" suffix.
%
% Outputs (created in <baseDir>/data/summary/pooled/)
%   pooled_eeg_qc_features.csv      % pooled QC features (schema-identical to per-dataset QC CSVs)
%   pooled_eeg_nrf_features.csv     % pooled NRF features (schema-identical to per-dataset NRF CSVs)
%   pooled_eeg_epochs.mat           % struct array "epochs_pooled", one element per dataset
%   pooled_eeg_manifest.csv         % dataset-level provenance + counts (for auditing)
%
% Key behaviors
%   • Spreadsheet-led discovery (no blind directory crawling).
%   • Pooled CSV schemas exactly match per-dataset schemas (same columns, same order).
%   • Light validation → warnings only (no failures):
%       - QC present but NRF missing (or vice versa)
%       - If epochs_index present: height(QC) == height(Index) * mode(n_channels)
%   • Provenance in a separate manifest CSV (no extra columns added to pooled CSVs).
%   • Pooled epochs MAT saved with adaptive format: try -v7, fallback to -v7.3 (HDF5) if needed.
%   • Progress messages, warnings, and the final summary are captured in the per-script log.

log_command_window('start');
clear; clc;

%% ───────────────────────────── USER CONFIG ─────────────────────────────
% 1) Base paths
baseDir   = '/Users/lukebaxter/Developer/simple-eeg/simple-strasbourg';
fileList  = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

% 2) Output directory (created if missing)
outDir    = fullfile(baseDir, 'data', 'summary', 'pooled');

% 3) Output files (idempotently overwritten on each run)
qc_out_csv     = fullfile(outDir, 'pooled_eeg_qc_features.csv');
nrf_out_csv    = fullfile(outDir, 'pooled_eeg_nrf_features.csv');
epochs_out_mat = fullfile(outDir, 'pooled_eeg_epochs.mat');
manifest_csv   = fullfile(outDir, 'pooled_eeg_manifest.csv');

% 4) Console verbosity (true = per-dataset progress + summary; false = summary + warnings only)
verbose = true;

% 5) Canonical column lists (edit here if your per-dataset CSV schemas change)
%    The pooled CSVs will be ordered to match these lists exactly.
QC_COLS = { ...
    'subjectID','sessionID','runID', ...
    'epoch_index','channel','eventtype','eventannotation', ...
    'maxAbsEpoch','sdEpoch','invSdEpoch', ...
    'MeanAbsDiffNorm','MaxAbsDiffNorm','RobustSlopeNorm', ...
    'AutoCorrLag1Pos','AutoCorrLag1Neg','KatzFDNorm'};

NRF_COLS = { ...
    'subjectID','sessionID','runID', ...
    'epoch_index','channel','eventtype','eventannotation', ...
    'NRFName','template_dur_ms','projectionTimes_ms','shift_samples', ...
    'pearsonR','cosineSimilarity', ...
    'olsCoef','fglsCoef','fglsVarCoef'};

% 6) Manifest: delimiter used to join distinct NRFName values per dataset
NRF_JOIN_DELIM = ';';

%% ─────────────────────── PREP & ACCUMULATORS ──────────────────────────
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

QC_pool         = [];   % table (will grow by vertical concatenation)
NRF_pool        = [];   % table (will grow by vertical concatenation)
epochs_pooled   = [];   % struct array; one element per dataset
manifest_rows   = [];   % table of per-dataset provenance + counts
warnCount       = 0;
datasetCount    = 0;

%% ───────────────────── READ SPREADSHEET & FILTER ──────────────────────
if verbose
    fprintf('Loading dataset list: %s\n', fileList);
end

opts = detectImportOptions(fileList, 'PreserveVariableNames', true, 'TextType', 'string', 'Delimiter', ',');

% Force key columns to string (they may be inferred otherwise depending on content)
forceStr = {'subjectID','sessionID','runID','EEGfile_processed','path_summary'};
for k = 1:numel(forceStr)
    if any(strcmpi(opts.VariableNames, forceStr{k}))
        opts = setvaropts(opts, forceStr{k}, 'Type', 'string');
    end
end

T = readtable(fileList, opts);

need = {'subjectID','sessionID','runID','EEGfile_processed','path_summary'};
missing = setdiff(need, T.Properties.VariableNames);
assert(isempty(missing), 'Missing required columns in dataset_list.csv: %s', strjoin(missing, ', '));

% Normalize to strings and trim
for i = 1:numel(need)
    col = need{i};
    T.(col) = strtrim(string(T.(col)));
    T.(col)(ismissing(T.(col))) = "";
end

% Keep only rows with a non-empty path_summary
T = T(T.path_summary ~= "", :);

% Derive stem from EEGfile_processed (strip .set)
[~, stems, ~] = cellfun(@fileparts, cellstr(T.EEGfile_processed), 'UniformOutput', false);
T.stem = string(stems);

% Drop rows where stem is empty (cannot construct filenames)
T = T(T.stem ~= "", :);

% Deduplicate datasets by (path_summary, stem) to avoid double-processing
[~, firstIdx] = unique(T(:, {'path_summary','stem'}), 'rows', 'stable');
T = T(firstIdx, :);

% Sort for deterministic processing (lexicographic by subject/session/run)
T = sortrows(T, {'subjectID','sessionID','runID'});

if verbose
    fprintf('Datasets to scan (from spreadsheet): %d\n', height(T));
end

%% ──────────────────────── MAIN LOOP OVER DATASETS ─────────────────────
for r = 1:height(T)
    subj = T.subjectID(r);
    sess = T.sessionID(r);
    run  = T.runID(r);
    stem = T.stem(r);
    relDir = T.path_summary(r);                     % e.g., "data/summary/sub-XXX/ses-YY/eeg"
    absDir = fullfile(baseDir, relDir); %#ok<NASGU>

    % Expected per-dataset files (relative & absolute)
    f_qc_rel   = fullfile(relDir,  sprintf('%s_qc_features.csv',   stem));
    f_nrf_rel  = fullfile(relDir,  sprintf('%s_nrf_features.csv',  stem));
    f_idx_rel  = fullfile(relDir,  sprintf('%s_epochs_index.csv',  stem));
    f_mat_rel  = fullfile(relDir,  sprintf('%s_epochs.mat',        stem));
    f_qc_abs   = fullfile(baseDir, f_qc_rel);
    f_nrf_abs  = fullfile(baseDir, f_nrf_rel);
    f_idx_abs  = fullfile(baseDir, f_idx_rel);
    f_mat_abs  = fullfile(baseDir, f_mat_rel);

    hasQC  = isfile(f_qc_abs);
    hasNRF = isfile(f_nrf_abs);
    hasIDX = isfile(f_idx_abs);
    hasMAT = isfile(f_mat_abs);

    if verbose
        fprintf('[%d/%d] %s | %s | %s  ->  %s\n', r, height(T), subj, sess, run, relDir);
        fprintf('   Found: QC=%d, NRF=%d, IDX=%d, MAT=%d\n', hasQC, hasNRF, hasIDX, hasMAT);
    end

    % Read & type-stabilize per-dataset tables (if present)
    Tqc  = table(); Tnrf = table(); Tidx = table();

    if hasQC
        % Force ID/label columns to string to preserve leading zeros in CSV
        optsQC = detectImportOptions(f_qc_abs, 'PreserveVariableNames', true);
        idColsQC = intersect({'subjectID','sessionID','runID','eventtype','eventannotation','channel'}, optsQC.VariableNames);
        if ~isempty(idColsQC), optsQC = setvartype(optsQC, idColsQC, 'string'); end
        Tqc = readtable(f_qc_abs, optsQC);

        % Safety: header must match expected QC columns (same set, regardless of order)
        if ~isempty(setxor(Tqc.Properties.VariableNames, QC_COLS))
            warning('SIMPLE:Step4_3:QCSchema', 'QC schema mismatch for stem %s. Skipping its QC rows.', stem);
            warnCount = warnCount + 1;
            Tqc = table(); hasQC = false;
        else
            % Reorder to canonical
            Tqc = Tqc(:, QC_COLS);

            % IDs/labels already strings from import; ensure numerics are doubles
            Tqc.epoch_index      = double(Tqc.epoch_index);
            Tqc.maxAbsEpoch      = double(Tqc.maxAbsEpoch);
            Tqc.sdEpoch          = double(Tqc.sdEpoch);
            Tqc.invSdEpoch       = double(Tqc.invSdEpoch);
            Tqc.MeanAbsDiffNorm  = double(Tqc.MeanAbsDiffNorm);
            Tqc.MaxAbsDiffNorm   = double(Tqc.MaxAbsDiffNorm);
            Tqc.RobustSlopeNorm  = double(Tqc.RobustSlopeNorm);
            Tqc.AutoCorrLag1Pos  = double(Tqc.AutoCorrLag1Pos);
            Tqc.AutoCorrLag1Neg  = double(Tqc.AutoCorrLag1Neg);
            Tqc.KatzFDNorm       = double(Tqc.KatzFDNorm);
        end
    end

    if hasNRF
        % Force ID/label columns to string to preserve leading zeros in CSV
        optsNRF = detectImportOptions(f_nrf_abs, 'PreserveVariableNames', true);
        idColsNRF = intersect({'subjectID','sessionID','runID','eventtype','eventannotation','channel','NRFName'}, optsNRF.VariableNames);
        if ~isempty(idColsNRF), optsNRF = setvartype(optsNRF, idColsNRF, 'string'); end
        Tnrf = readtable(f_nrf_abs, optsNRF);

        % Safety: header must match expected NRF columns (same set, regardless of order)
        if ~isempty(setxor(Tnrf.Properties.VariableNames, NRF_COLS))
            warning('SIMPLE:Step4_3:NRFSchema', 'NRF schema mismatch for stem %s. Skipping its NRF rows.', stem);
            warnCount = warnCount + 1;
            Tnrf = table(); hasNRF = false;
        else
            % Reorder to canonical
            Tnrf = Tnrf(:, NRF_COLS);

            % IDs/labels already strings from import; ensure numerics are doubles
            Tnrf.epoch_index        = double(Tnrf.epoch_index);
            Tnrf.projectionTimes_ms = double(Tnrf.projectionTimes_ms);
            Tnrf.pearsonR           = double(Tnrf.pearsonR);
            Tnrf.cosineSimilarity   = double(Tnrf.cosineSimilarity);
            Tnrf.shift_samples      = double(Tnrf.shift_samples);
            Tnrf.fglsCoef           = double(Tnrf.fglsCoef);
            Tnrf.fglsVarCoef        = double(Tnrf.fglsVarCoef);
            Tnrf.olsCoef            = double(Tnrf.olsCoef);
            Tnrf.template_dur_ms    = double(Tnrf.template_dur_ms);
        end
    end

    if hasIDX
        optsIdx = detectImportOptions(f_idx_abs, 'PreserveVariableNames', true);
        % If you also want to preserve IDs in index CSV, uncomment:
        % idColsIDX = intersect({'subjectID','sessionID','runID','eventtype'}, optsIdx.VariableNames);
        % if ~isempty(idColsIDX), optsIdx = setvartype(optsIdx, idColsIDX, 'string'); end
        Tidx = readtable(f_idx_abs, optsIdx);
        % Coerce expected numeric types from index
        if any(strcmp(Tidx.Properties.VariableNames, 'n_channels')), Tidx.n_channels = double(Tidx.n_channels); end
        if any(strcmp(Tidx.Properties.VariableNames, 'n_points')),   Tidx.n_points   = double(Tidx.n_points);   end
    end

    % Validation warnings (advisory only)
    if hasQC && ~hasNRF
        warning('SIMPLE:Step4_3:MissingNRF', 'QC present but NRF missing for stem %s', stem);
        warnCount = warnCount + 1;
    elseif hasNRF && ~hasQC
        warning('SIMPLE:Step4_3:MissingQC', 'NRF present but QC missing for stem %s', stem);
        warnCount = warnCount + 1;
    end

    if hasQC && hasIDX && any(strcmp(Tidx.Properties.VariableNames,'n_channels'))
        nCh_mode = mode(Tidx.n_channels);
        if ~isempty(Tqc)
            ok = height(Tqc) == height(Tidx) * nCh_mode;
            if ~ok
                warning('SIMPLE:Step4_3:QCIndexMismatch', ...
                    'QC vs IDX count mismatch for stem %s (QC=%d vs IDX=%d * nCh=%d)', ...
                    stem, height(Tqc), height(Tidx), nCh_mode);
                warnCount = warnCount + 1;
            end
        end
    end

    % Append to pooled tables
    if ~isempty(Tqc)
        QC_pool = [QC_pool; Tqc]; %#ok<AGROW>
    end
    if ~isempty(Tnrf)
        NRF_pool = [NRF_pool; Tnrf]; %#ok<AGROW>
    end

    % Pooled epochs struct-array (as-is + provenance strings)
    srate_here = NaN;
    epochs_found = false;
    if hasMAT
        S = load(f_mat_abs);  % expects variable "epochs" per Step 5.2
        if isfield(S, 'epochs')
            E = S.epochs;
            epochs_found = true;

            % Enforce 3-D data shape [nC x nP x nE] (use nE=1 for single-epoch data)
            data_here = E.data;
            if ndims(data_here) == 2
                data_here = reshape(data_here, size(data_here,1), size(data_here,2), 1);
            end

            ep = struct();
            % Copy numeric/cell fields (with enforced 3-D data)
            ep.data                  = data_here;
            ep.times_ms              = E.times_ms;
            % Step 5.2 saved channel labels under "channels"
            if isfield(E, 'channels')
                ep.channels = E.channels;
            elseif isfield(E,'chanlabels')
                ep.channels = E.chanlabels;
            else
                ep.channels = {};
            end
            ep.epoch_index           = E.epoch_index;
            ep.eventtype             = E.eventtype;
            ep.eventannotation       = E.eventannotation;
            ep.srate                 = E.srate;
            srate_here               = E.srate;

            % Add lightweight provenance for convenience (strings)
            ep.subjectID        = char(subj);
            ep.sessionID        = char(sess);
            ep.runID            = char(run);
            ep.stem             = char(stem);
            ep.path_summary     = char(relDir);
            ep.source_epochs_mat= char(f_mat_rel);

            epochs_pooled = [epochs_pooled; ep]; %#ok<AGROW>
        else
            warning('SIMPLE:Step4_3:EpochsVarMissing', ...
                'epochs.mat for stem %s lacks variable "epochs". Skipping MAT pooling.', stem);
            warnCount = warnCount + 1;
        end
    else
        warning('SIMPLE:Step4_3:EpochsMatMissing', 'epochs.mat missing for stem %s', stem);
        warnCount = warnCount + 1;
    end

    % Manifest row (dataset-level provenance + counts)
    qc_rows  = size(Tqc,  1);
    nrf_rows = size(Tnrf, 1);
    idx_rows = size(Tidx, 1);

    n_channels = NaN;
    n_points   = NaN;
    if ~isempty(Tidx)
        if any(strcmp(Tidx.Properties.VariableNames,'n_channels'))
            n_channels = mode(Tidx.n_channels);
        end
        if any(strcmp(Tidx.Properties.VariableNames,'n_points'))
            n_points   = mode(Tidx.n_points);
        end
    end

    unique_NRFNames = "";
    if ~isempty(Tnrf) && any(strcmp(Tnrf.Properties.VariableNames,'NRFName'))
        u = unique(string(Tnrf.NRFName));
        if ~isempty(u)
            unique_NRFNames = strjoin(u, NRF_JOIN_DELIM);
        end
    end

    % Presence flags
    qc_found     = hasQC;
    nrf_found    = hasNRF;
    idx_found    = hasIDX;

    % Assemble one manifest row
    m = table( ...
        string(subj), string(sess), string(run), string(stem), string(relDir), ...
        string(f_qc_rel), string(f_nrf_rel), string(f_idx_rel), string(f_mat_rel), ...
        qc_rows, nrf_rows, idx_rows, n_channels, n_points, srate_here, ...
        unique_NRFNames, ...
        qc_found, nrf_found, idx_found, epochs_found, ...
        'VariableNames', { ...
        'subjectID','sessionID','runID','stem','path_summary', ...
        'qc_csv','nrf_csv','idx_csv','epochs_mat', ...
        'qc_rows','nrf_rows','idx_rows','n_channels','n_points','srate', ...
        'unique_NRFNames', ...
        'qc_found','nrf_found','idx_found','epochs_mat_found'} ...
        );

    manifest_rows = [manifest_rows; m]; %#ok<AGROW>

    datasetCount = datasetCount + 1;
end

%% ────────────────────────── SORT & WRITE CSVs ─────────────────────────
% Ensure pooled tables have canonical column order (already enforced per-file),
% then sort lexicographically for reproducibility.

if ~isempty(QC_pool)
    QC_pool = QC_pool(:, QC_COLS);
    QC_pool = sortrows(QC_pool, {'subjectID','sessionID','runID','epoch_index','channel'});

    % Final safety: keep ID/label columns as string before writing (preserves leading zeros)
    QC_pool.subjectID       = string(QC_pool.subjectID);
    QC_pool.sessionID       = string(QC_pool.sessionID);
    QC_pool.runID           = string(QC_pool.runID);
    QC_pool.eventtype       = string(QC_pool.eventtype);
    QC_pool.eventannotation = string(QC_pool.eventannotation);
    QC_pool.channel         = string(QC_pool.channel);
end

if ~isempty(NRF_pool)
    NRF_pool = NRF_pool(:, NRF_COLS);
    NRF_pool = sortrows(NRF_pool, {'subjectID','sessionID','runID','epoch_index','channel','NRFName'});

    % Final safety: keep ID/label columns as string before writing (preserves leading zeros)
    NRF_pool.subjectID       = string(NRF_pool.subjectID);
    NRF_pool.sessionID       = string(NRF_pool.sessionID);
    NRF_pool.runID           = string(NRF_pool.runID);
    NRF_pool.eventtype       = string(NRF_pool.eventtype);
    NRF_pool.eventannotation = string(NRF_pool.eventannotation);
    NRF_pool.channel         = string(NRF_pool.channel);
    NRF_pool.NRFName         = string(NRF_pool.NRFName);
end

% Manifest sorted by subject/session/run
if ~isempty(manifest_rows)
    manifest_rows = sortrows(manifest_rows, {'subjectID','sessionID','runID'});
end

% Write pooled CSVs (idempotent overwrite)
writetable(QC_pool,  qc_out_csv);
writetable(NRF_pool, nrf_out_csv);
writetable(manifest_rows, manifest_csv);

if verbose
    fprintf('Wrote pooled QC:  %s  (rows=%d)\n',  qc_out_csv,  height(QC_pool));
    fprintf('Wrote pooled NRF: %s  (rows=%d)\n',  nrf_out_csv, height(NRF_pool));
    fprintf('Wrote manifest:   %s  (rows=%d)\n',  manifest_csv, height(manifest_rows));
end

%% ───────────────────────── WRITE POOLED MAT ───────────────────────────
% Save epochs_pooled as a single variable inside pooled_eeg_epochs.mat.
% Try classic -v7 first (fast/small for modest sizes). If it fails due to size,
% automatically retry with -v7.3 (HDF5) which supports >2GB variables.

if isempty(epochs_pooled)
    if verbose
        fprintf('No epochs MAT files were pooled; skipping pooled MAT save.\n');
    end
else
    try
        save(epochs_out_mat, 'epochs_pooled', '-v7');
        if verbose, fprintf('Wrote pooled MAT (-v7): %s  (elements=%d)\n', epochs_out_mat, numel(epochs_pooled)); end
    catch ME
        % Use exception identifier as warning ID; format message safely
        warning(ME.identifier, 'Saving pooled MAT with -v7 failed: %s. Retrying with -v7.3 (HDF5).', ME.message);
        save(epochs_out_mat, 'epochs_pooled', '-v7.3');
        if verbose, fprintf('Wrote pooled MAT (-v7.3): %s  (elements=%d)\n', epochs_out_mat, numel(epochs_pooled)); end
    end
end

%% ───────────────────────────── FINAL SUMMARY ──────────────────────────
fprintf('\nPooled summary complete.\n');
fprintf('  Datasets scanned:        %d\n', datasetCount);
fprintf('  Pooled QC rows:          %d\n', height(QC_pool));
fprintf('  Pooled NRF rows:         %d\n', height(NRF_pool));
fprintf('  epochs_pooled elements:  %d\n', numel(epochs_pooled));
fprintf('  Warnings emitted:        %d\n', warnCount);
fprintf('Outputs written to: %s\n', outDir);

log_command_window('stop');
