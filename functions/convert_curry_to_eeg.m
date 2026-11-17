function [EEG, ok] = convert_curry_to_eeg(srcDir, mainFile, sidecars, annotationToType, curryVersion)
% convert_curry_to_eeg
% Load Curry 7/8 data via loadcurry, replace events from CEF/CEO, map
% Annotation->Type (unmapped/empty -> 'NA'), and return EEG (no saving).
%
% Boundary-event handling:
%   - Preserve any 'boundary' events created by loadcurry for epoched data:
%       1) call loadcurry
%       2) capture existing boundary event latencies
%       3) rebuild events from CEF/CEO (our authoritative source for codes/annotations)
%       4) append boundary events with preserved latencies (type='boundary'; urtype=''; annotation='')
%       5) sort & consistency check
%
% Inputs:
%   srcDir           - absolute source eeg/ folder
%   mainFile         - main data file name: '.dat' (Curry 7) or '.cdt' (Curry 8)
%   sidecars         - struct with fields (RELATIVE names from spreadsheet):
%                        Curry 7:  .dap, .rs3, .cef, .ceo
%                        Curry 8:  .cdt_dpa, .cdt_cef, .cdt_ceo
%   annotationToType - containers.Map: Annotation -> Type (case-sensitive; keys trimmed)
%   curryVersion     - "Curry 7" or "Curry 8"
%
% Outputs:
%   EEG - EEGLAB dataset (ready to save)
%   ok  - logical true if successful
%
% Notes:
%   - Prefers .cef events; falls back to .ceo if .cef missing
%   - Omits EEG.event.duration for Curry (can be added later if needed)
%   - Stores missing annotations as empty string '' (1x1 cell)
%   - Removes EEG.urevent and any per-event 'urevent' field
%   - Sorts events by latency
%   - Throws errors on missing required files (fail-fast)

ok  = false;
EEG = [];

% -------- 1) Resolve paths & validate required files --------
mainPath = fullfile(srcDir, mainFile);

switch string(curryVersion)
    case "Curry 7"
        % Required data components for Curry 7
        datPath = mainPath;  % mainFile expected to be *.dat
        dapPath = fullfile(srcDir, sidecars.dap);
        rs3Path = fullfile(srcDir, sidecars.rs3);
        cefPath = fullfile(srcDir, sidecars.cef);
        ceoPath = fullfile(srcDir, sidecars.ceo);

        if strlength(mainFile)==0 || ~isfile(datPath)
            error("convert_curry_to_eeg: missing Curry 7 .dat file: %s", datPath);
        end
        if strlength(sidecars.dap)==0 || ~isfile(dapPath)
            error("convert_curry_to_eeg: missing Curry 7 .dap: %s", dapPath);
        end
        if strlength(sidecars.rs3)==0 || ~isfile(rs3Path)
            error("convert_curry_to_eeg: missing Curry 7 .rs3: %s", rs3Path);
        end

        % Event file: prefer .cef, fallback .ceo
        if strlength(sidecars.cef)>0 && isfile(cefPath)
            evtPath = cefPath;
        elseif strlength(sidecars.ceo)>0 && isfile(ceoPath)
            evtPath = ceoPath;
        else
            error("convert_curry_to_eeg: missing Curry 7 event file (.cef or .ceo) for base: %s", mainFile);
        end

        loadFile = datPath;

    case "Curry 8"
        % Required data components for Curry 8
        cdtPath  = mainPath;  % mainFile expected to be *.cdt
        dpaPath  = fullfile(srcDir, sidecars.cdt_dpa);
        cef8Path = fullfile(srcDir, sidecars.cdt_cef);
        ceo8Path = fullfile(srcDir, sidecars.cdt_ceo);

        if strlength(mainFile)==0 || ~isfile(cdtPath)
            error("convert_curry_to_eeg: missing Curry 8 .cdt file: %s", cdtPath);
        end
        if strlength(sidecars.cdt_dpa)==0 || ~isfile(dpaPath)
            error("convert_curry_to_eeg: missing Curry 8 .cdt.dpa file: %s", dpaPath);
        end

        % Event file: prefer .cdt.cef, fallback .cdt.ceo
        if strlength(sidecars.cdt_cef)>0 && isfile(cef8Path)
            evtPath = cef8Path;
        elseif strlength(sidecars.cdt_ceo)>0 && isfile(ceo8Path)
            evtPath = ceo8Path;
        else
            error("convert_curry_to_eeg: missing Curry 8 event file (.cdt.cef or .cdt.ceo) for base: %s", mainFile);
        end

        loadFile = cdtPath;

    otherwise
        error("convert_curry_to_eeg: unsupported curryVersion: %s", string(curryVersion));
end

% -------- 2) Import data via loadcurry (and capture 'boundary' events) --------
EEG = loadcurry(loadFile);
EEG = eeg_checkset(EEG);

% Capture boundary event latencies BEFORE we overwrite EEG.event
boundaryLat = [];
if isfield(EEG, 'event') && ~isempty(EEG.event)
    boundaryMask = false(1, numel(EEG.event));
    for ii = 1:numel(EEG.event)
        t = [];
        if isfield(EEG.event, 'type')
            t = EEG.event(ii).type;
        end
        % Boundary events in EEGLAB are labeled with the literal string 'boundary'
        if (ischar(t) || (isstring(t) && isscalar(t))) && strcmpi(char(t), 'boundary')
            boundaryMask(ii) = true;
        end
    end
    if any(boundaryMask)
        boundaryLat = double([EEG.event(boundaryMask).latency]);
        % Ensure row-shape
        boundaryLat = boundaryLat(:).';
    end
end

% -------- 3) Read events from CEF/CEO and replace EEG.event --------
% Parser returns: event_time (latency in samples), event_numbers (codes), annotations (cellstr)
[event_time, event_numbers, event_annotations] = read_events_from_curry_cef(evtPath);

% Build a fresh events struct array (omit duration for Curry)
nEv = numel(event_time);
EEG.event = struct('latency', cell(1,nEv), 'type', cell(1,nEv), 'annotation', cell(1,nEv), 'urtype', cell(1,nEv));
for i = 1:nEv
    % Use parser latency as-is (samples, 1-based)
    EEG.event(i).latency = double(event_time(i));
    % Original code (numeric) as string for uniformity; store in type initially
    EEG.event(i).type    = strtrim(num2str(event_numbers(i)));
    % Missing annotation -> empty string ''
    if i <= numel(event_annotations) && ~isempty(event_annotations{i})
        EEG.event(i).annotation = {event_annotations{i}};
    else
        EEG.event(i).annotation = {''};
    end
    % Backup original code to urtype (before mapping)
    EEG.event(i).urtype = EEG.event(i).type;
end

% Optional: remove any duplicate annotation storage in EEG.etc
if isfield(EEG, 'etc') && isfield(EEG.etc, 'annotations')
    EEG.etc = rmfield(EEG.etc, 'annotations');
end

% -------- 4) Normalize annotation & sort by latency --------
for i = 1:numel(EEG.event)
    if ~iscell(EEG.event(i).annotation)
        EEG.event(i).annotation = {char(EEG.event(i).annotation)};
    end
end
if ~isempty(EEG.event)
    [~, si] = sort([EEG.event.latency]);
    EEG.event = EEG.event(si);
end

% -------- 5) Strip any 'urevent' baggage from loadcurry --------
if isfield(EEG, 'urevent'); EEG = rmfield(EEG, 'urevent'); end
if ~isempty(EEG.event) && isfield(EEG.event, 'urevent')
    EEG.event = rmfield(EEG.event, 'urevent');
end

% -------- 6) Apply Annotation -> Type mapping (empty/missing -> 'NA') --------
% Skip boundary events (we will append them later and do not map them)
for i = 1:numel(EEG.event)
    % NOTE: At this point there are no boundary events in EEG.event (we haven't appended yet)
    ann = "";
    if ~isempty(EEG.event(i).annotation) && iscell(EEG.event(i).annotation)
        ann = strtrim(string(EEG.event(i).annotation{1})); % trim, case-sensitive
    end
    if strlength(ann) > 0 && isKey(annotationToType, char(ann))
        mapped = string(annotationToType(char(ann)));
        if strlength(mapped) > 0
            EEG.event(i).type = char(mapped);
        else
            EEG.event(i).type = 'NA';
        end
    else
        EEG.event(i).type = 'NA';
    end
end

% -------- 7) Append preserved boundary events (unmapped) --------
if ~isempty(boundaryLat)
    nb = numel(boundaryLat);

    % Build boundary event structs. Keep fields consistent with EEG.event.
    % type='boundary'; annotation={''}; urtype='' (placeholder to match fieldset)
    boundaryEvents = struct( ...
        'latency',    num2cell(boundaryLat), ...
        'type',       repmat({'boundary'}, 1, nb), ...
        'annotation', repmat({{''}}, 1, nb), ...
        'urtype',     repmat({''}, 1, nb) ...
    );

    % Append and resort by latency
    EEG.event = [EEG.event, boundaryEvents];
    [~, si] = sort([EEG.event.latency]);
    EEG.event = EEG.event(si);
end

% -------- 8) Final consistency check --------
EEG = eeg_checkset(EEG, 'eventconsistency');

ok = true;
end
