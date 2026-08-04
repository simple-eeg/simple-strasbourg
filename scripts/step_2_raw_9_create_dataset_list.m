%% step_2_raw_9_create_dataset_list.m
% Purpose
%   - Read:  data_lists/dataset_list_prelim.xlsx
%   - Validate required columns exist and are correctly coded.
%   - Determine included vs excluded rows using:
%       excluded_datasets, channel_exclusion
%     Rules (after trimming whitespace; case-insensitive):
%       * allowed values per cell: blank or "excluded"
%       * any other non-empty value -> hard error
%       * row is INCLUDED only if BOTH columns are blank
%   - Append (or recreate) final column: included_datasets
%       "included" for included rows; blank otherwise
%   - Overwrite: data_lists/dataset_list_prelim.xlsx (formatting loss acceptable)
%   - Create: data_lists/dataset_list.csv using included rows only, with columns:
%       subjectID, sessionID, runID, EEGfile_raw, path_raw
%     where:
%       EEGfile_raw <- EEGfile_reformatted
%       path_raw    <- path_reformatted
%   - For included rows only, require non-blank (after trim) in:
%       subjectID, sessionID, runID, EEGfile_reformatted, path_reformatted
%     otherwise hard error
%   - For included rows only, require no duplicate keys:
%       (subjectID, sessionID, runID)
%     otherwise hard error
%   - Sort dataset_list.csv rows by subjectID, then sessionID, then runID

log_command_window('start');
clear; clc;

%% ───────────────────────────── Paths ─────────────────────────────
baseDir = '/Users/lukebaxter/pipeline_paper/simple-strasbourg';
inXlsx  = fullfile(baseDir, 'data_lists', 'dataset_list_prelim.xlsx');
outCsv  = fullfile(baseDir, 'data_lists', 'dataset_list.csv');

fprintf('step_2_raw_9_create_dataset_list.m\n');
fprintf('Input XLSX: %s\n', inXlsx);

if ~isfile(inXlsx)
    error('Input file not found: %s', inXlsx);
end

%% ───────────────────────────── Required columns ─────────────────────────────
REQ_COLS = { ...
    'subjectID', ...
    'sessionID', ...
    'runID', ...
    'excluded_datasets', ...
    'channel_exclusion', ...
    'EEGfile_reformatted', ...
    'path_reformatted' ...
    };

%% ───────────────────────────── Read XLSX robustly as strings ─────────────────────────────
opts = detectImportOptions(inXlsx, 'FileType', 'spreadsheet');

missingCols = setdiff(REQ_COLS, opts.VariableNames);
if ~isempty(missingCols)
    msg = sprintf('Missing required column(s) in dataset_list_prelim.xlsx:\n  - %s', strjoin(missingCols, '\n  - '));
    error('%s', msg);
end

% Force all required columns to import as string to preserve leading zeros,
% and avoid numeric/NaN coercion when columns are entirely blank.
try
    opts = setvartype(opts, REQ_COLS, 'string');
catch
    % Fallback for older MATLABs: set VariableTypes by index
    varTypes = opts.VariableTypes;
    for i = 1:numel(REQ_COLS)
        idx = find(strcmp(opts.VariableNames, REQ_COLS{i}), 1, 'first');
        if ~isempty(idx)
            varTypes{idx} = 'string';
        end
    end
    opts.VariableTypes = varTypes;
end

T = readtable(inXlsx, opts);

% Normalise required columns:
%   - ensure string
%   - coerce <missing> to ""
%   - trim whitespace
for i = 1:numel(REQ_COLS)
    v = REQ_COLS{i};

    if ~ismember(v, T.Properties.VariableNames)
        error('Internal error: required column missing after readtable: %s', v);
    end

    col = T.(v);

    % Coerce to string robustly
    if isstring(col)
        s = col;
    elseif iscellstr(col) || iscell(col)
        s = string(col);
    elseif iscategorical(col)
        s = string(col);
    elseif isnumeric(col) || islogical(col)
        % Numeric should not happen if setvartype succeeded, but handle defensively:
        s = strings(height(T), 1);
        if isnumeric(col)
            mask = ~isnan(col);
            s(mask) = string(col(mask));
        else
            s = string(col);
        end
    else
        s = string(col);
    end

    % Coerce missing to empty string, then trim
    s(ismissing(s)) = "";
    s = strtrim(s);

    % If any NaN slipped through string conversion, treat as blank
    s(lower(s) == "nan") = "";

    T.(v) = s;
end

%% ───────────────────────────── Validate exclusion coding ─────────────────────────────
ex1 = lower(strtrim(T.excluded_datasets));
ex2 = lower(strtrim(T.channel_exclusion));

bad1 = (ex1 ~= "" & ex1 ~= "excluded");
bad2 = (ex2 ~= "" & ex2 ~= "excluded");

if any(bad1)
    idx = find(bad1);
    exampleN = min(10, numel(idx));
    examples = strings(exampleN, 1);
    for k = 1:exampleN
        r = idx(k);
        examples(k) = sprintf('Row %d: "%s"', r, T.excluded_datasets(r));
    end
    msg = sprintf([ ...
        'Invalid value(s) in column excluded_datasets. Allowed: blank or "excluded" (case-insensitive).\n' ...
        'First %d offending row(s):\n  - %s'], ...
        exampleN, strjoin(examples, '\n  - '));
    error('%s', msg);
end

if any(bad2)
    idx = find(bad2);
    exampleN = min(10, numel(idx));
    examples = strings(exampleN, 1);
    for k = 1:exampleN
        r = idx(k);
        examples(k) = sprintf('Row %d: "%s"', r, T.channel_exclusion(r));
    end
    msg = sprintf([ ...
        'Invalid value(s) in column channel_exclusion. Allowed: blank or "excluded" (case-insensitive).\n' ...
        'First %d offending row(s):\n  - %s'], ...
        exampleN, strjoin(examples, '\n  - '));
    error('%s', msg);
end

%% ───────────────────────────── Compute included_datasets (recreate) ─────────────────────────────
isIncluded = (ex1 == "") & (ex2 == "");

includedCol = strings(height(T), 1);
includedCol(isIncluded) = "included";

% Remove existing included_datasets column if present
if ismember('included_datasets', T.Properties.VariableNames)
    T.included_datasets = [];
end

% Append as final column
T.included_datasets = includedCol;

nTotal    = height(T);
nIncluded = sum(isIncluded);
nExcluded = nTotal - nIncluded;

fprintf('Rows read: %d | Included: %d | Excluded: %d\n', nTotal, nIncluded, nExcluded);

%% ───────────────────────────── Overwrite XLSX ─────────────────────────────
writetable(T, inXlsx, 'FileType', 'spreadsheet');
fprintf('Overwrote XLSX with included_datasets appended: %s\n', inXlsx);

%% ───────────────────────────── Create dataset_list.csv (included rows only) ─────────────────────────────
Tincl = T(isIncluded, :);

% For included rows only, enforce non-blank in required fields
REQ_NONBLANK_INCL = { ...
    'subjectID', ...
    'sessionID', ...
    'runID', ...
    'EEGfile_reformatted', ...
    'path_reformatted' ...
    };

blankMask = false(height(Tincl), 1);
whichCol  = strings(height(Tincl), 1);

for i = 1:numel(REQ_NONBLANK_INCL)
    v = REQ_NONBLANK_INCL{i};
    s = strtrim(Tincl.(v));
    s(ismissing(s)) = "";
    s(lower(s) == "nan") = "";
    thisBlank = (s == "");
    hit = thisBlank & ~blankMask;
    whichCol(hit) = v;
    blankMask = blankMask | thisBlank;
end

if any(blankMask)
    idx = find(blankMask);
    exampleN = min(10, numel(idx));
    examples = strings(exampleN, 1);
    for k = 1:exampleN
        r = idx(k);
        examples(k) = sprintf('Included-row %d (in included subset): blank in %s | subjectID="%s" sessionID="%s" runID="%s"', ...
            r, whichCol(r), Tincl.subjectID(r), Tincl.sessionID(r), Tincl.runID(r));
    end
    msg = sprintf([ ...
        'Blank value(s) detected in required field(s) for included rows.\n' ...
        'Required non-blank (included rows only): subjectID, sessionID, runID, EEGfile_reformatted, path_reformatted.\n' ...
        'First %d offending row(s):\n  - %s'], ...
        exampleN, strjoin(examples, '\n  - '));
    error('%s', msg);
end

% Duplicate key check among included rows: (subjectID, sessionID, runID)
if ~isempty(Tincl)
    key = Tincl.subjectID + "|" + Tincl.sessionID + "|" + Tincl.runID;
    [uKey, ia] = unique(key, 'stable');
    if numel(uKey) ~= numel(key)
        dupIdx = setdiff((1:numel(key))', ia);
        dupIdx = unique(dupIdx, 'stable');

        % Report up to 10 duplicate keys with their positions
        exampleN = min(10, numel(dupIdx));
        examples = strings(exampleN, 1);
        for k = 1:exampleN
            d = dupIdx(k);
            examples(k) = sprintf('Duplicate key at included-row %d: subjectID="%s" sessionID="%s" runID="%s"', ...
                d, Tincl.subjectID(d), Tincl.sessionID(d), Tincl.runID(d));
        end

        msg = sprintf([ ...
            'Duplicate (subjectID, sessionID, runID) detected among included rows.\n' ...
            'First %d duplicate instance(s):\n  - %s'], ...
            exampleN, strjoin(examples, '\n  - '));
        error('%s', msg);
    end
end

% Build output table with renamed columns
Tout = table();
Tout.subjectID   = Tincl.subjectID;
Tout.sessionID   = Tincl.sessionID;
Tout.runID       = Tincl.runID;
Tout.path_raw    = Tincl.path_reformatted;
Tout.EEGfile_raw = Tincl.EEGfile_reformatted;

% Sort by subjectID, then sessionID, then runID
if ~isempty(Tout)
    Tout = sortrows(Tout, {'subjectID', 'sessionID', 'runID'});
end

% Sort columns
Tout = Tout(:, {'subjectID','sessionID','runID','path_raw','EEGfile_raw'});

% Overwrite CSV unconditionally
writetable(Tout, outCsv);
fprintf('Wrote CSV: %s (%d rows)\n', outCsv, height(Tout));

log_command_window('stop');