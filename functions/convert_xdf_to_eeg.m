function [EEG, ok] = convert_xdf_to_eeg(srcDir, mainFile, sidecars, annotationToType)
% convert_xdf_to_eeg
% Load XDF, replace events from sidecar CSV, map Annotation->Type, and return EEG.
% (Saving is handled by the caller.)
%
% Inputs:
%   srcDir           - absolute source folder (e.g., .../data/source/sub-.../eeg)
%   mainFile         - main EEG filename (e.g., 'sub-XX_ses-YY_run-ZZ_eeg.xdf')
%   sidecars         - struct with field:
%                        .events_csv (RELATIVE filename, resolved with srcDir)
%   annotationToType - containers.Map: Annotation -> Type (case-sensitive; keys trimmed)
%
% Outputs:
%   EEG - EEGLAB dataset struct (ready to save)
%   ok  - logical, true if build succeeded
%
% Behavior:
%   - Requires events CSV to include: latency, duration, type, annotation
%   - Backs up original event codes to EEG.event.urtype
%   - Sets EEG.event.type from mapping; unmapped/empty -> 'NA'
%   - Stores missing annotations as empty string '' (1x1 cell)
%   - Removes any EEG.urevent / per-event urevent field
%   - Does NOT save; caller should pop_saveset(...)

ok = false;
EEG = [];

% -------- Paths & existence checks --------
xdfPath   = fullfile(srcDir, mainFile);
eventsCsv = fullfile(srcDir, sidecars.events_csv);

if strlength(mainFile) == 0 || ~isfile(xdfPath)
    error("convert_xdf_to_eeg: missing XDF file: %s", xdfPath);
end
if strlength(string(sidecars.events_csv)) == 0 || ~isfile(eventsCsv)
    error("convert_xdf_to_eeg: missing events CSV: %s", string(eventsCsv));
end

% -------- Load XDF --------
EEG = pop_loadxdf(xdfPath);
EEG = eeg_checkset(EEG);

% -------- Load events from sidecar CSV --------
evOpts = detectImportOptions(eventsCsv, 'TextType','string', 'VariableNamingRule','preserve');

% Force expected variable types if present
vn = string(evOpts.VariableNames);
if any(vn == "latency"),    evOpts = setvartype(evOpts, "latency", "double"); end
if any(vn == "duration"),   evOpts = setvartype(evOpts, "duration", "double"); end
if any(vn == "type"),       evOpts = setvartype(evOpts, "type", "char");      end
if any(vn == "annotation"), evOpts = setvartype(evOpts, "annotation", "char");end

evTbl = readtable(eventsCsv, evOpts);

% Require core columns
coreCols = ["latency","duration","type","annotation"];
if ~all(ismember(coreCols, string(evTbl.Properties.VariableNames)))
    error("convert_xdf_to_eeg: events CSV missing required columns (need: latency, duration, type, annotation): %s", eventsCsv);
end

% Keep only core columns (ignore extras)
evTbl = evTbl(:, coreCols);

% Table -> struct array (initial)
EEG.event = table2struct(evTbl);

% Ensure annotation is a 1x1 cell and normalize empties to ''
for iEv = 1:numel(EEG.event)
    % Normalize annotation
    if isfield(EEG.event, 'annotation')
        a = string(EEG.event(iEv).annotation);
        if ismissing(a) || strlength(a) == 0
            EEG.event(iEv).annotation = {''};
        else
            EEG.event(iEv).annotation = {char(a)};
        end
    else
        EEG.event(iEv).annotation = {''};
    end
end

% Sort by latency
if ~isempty(EEG.event) && isfield(EEG.event, 'latency')
    [~, si] = sort([EEG.event.latency]);
    EEG.event = EEG.event(si);
end

% Remove any 'urevent' baggage (defensive)
if isfield(EEG, 'urevent'); EEG = rmfield(EEG, 'urevent'); end
if ~isempty(EEG.event) && isfield(EEG.event, 'urevent')
    EEG.event = rmfield(EEG.event, 'urevent');
end

% -------- Backup original code and apply Annotation -> Type mapping --------
for iEv = 1:numel(EEG.event)
    % Backup original code from CSV 'type'
    if isfield(EEG.event, 'type')
        EEG.event(iEv).urtype = EEG.event(iEv).type;
    else
        EEG.event(iEv).urtype = '';
    end

    % Trim annotation for lookup (case-sensitive)
    ann = "";
    if ~isempty(EEG.event(iEv).annotation) && iscell(EEG.event(iEv).annotation)
        ann = strtrim(string(EEG.event(iEv).annotation{1}));
    end
    if strlength(ann) > 0 && isKey(annotationToType, char(ann))
        mapped = string(annotationToType(char(ann)));
        if strlength(mapped) > 0
            EEG.event(iEv).type = char(mapped);
        else
            EEG.event(iEv).type = 'NA';
        end
    else
        EEG.event(iEv).type = 'NA';
    end
end

% Final consistency check
EEG = eeg_checkset(EEG, 'eventconsistency');

ok = true;
end