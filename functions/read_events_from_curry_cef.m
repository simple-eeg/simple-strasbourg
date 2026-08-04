function [event_time, event_numbers, annotations] = read_events_from_curry_cef(eventFile)
%% read_events_from_curry_cef
% Read event timing and annotations from a Curry .cef/.ceo file.
%
% INPUT
%   eventFile (string/char): Path to the .cef (or .ceo) event file.
%
% OUTPUT
%   event_time     (1xN double): Event latencies in **samples** (1-based).
%   event_numbers  (1xN double): Event numeric codes.
%   annotations    (1xN cellstr): Event annotations (trimmed); missing -> ''.
%
% Notes
% - Parses the NUMBER_LIST and REMARK_LIST **data blocks** bracketed by
%   "NUMBER_LIST START_LIST" ... "NUMBER_LIST END_LIST" and
%   "REMARK_LIST START_LIST" ... "REMARK_LIST END_LIST".
% - NUMBER_LIST column meanings (11 integers per row, common in Curry CEFs):
%     col 1: sample (onset)            <-- usually equals col 5 (sanity check)
%     col 2: duration (samples)        <-- ignored (often 0)
%     col 3: type (event code)         <-- used for event_numbers
%     col 5: startsample (onset)       <-- used for latency
%     col 6: endsample
% - The function does **not** derive durations or pair start/end markers.
% - Outputs are row-shaped; malformed lines are skipped with a warning.

%% Init outputs
event_time    = [];
event_numbers = [];
annotations   = {};

%% Check file
if ~isfile(eventFile)
    error('read_events_from_curry_cef: file not found: %s', eventFile);
end

%% Read entire file as text (normalize newlines)
try
    content = fileread(eventFile);
catch
    % Fallback compatible with older MATLABs
    fid = fopen(eventFile, 'rt');
    if fid < 0, error('Failed to open event file: %s', eventFile); end
    c = textscan(fid, '%s', 'Whitespace', '', 'EndOfLine', '§');
    fclose(fid);
    content = c{1}{1};
end
content = strrep(content, sprintf('\r'), ''); % normalize CRLF -> LF

%% Helper: extract lines inside START_LIST ... END_LIST for a given section
extractBlockLines = @(txt, section) local_extract_block_lines(txt, section);

%% Parse NUMBER_LIST (event times/codes)
[numLines, hadNumberBlock] = extractBlockLines(content, 'NUMBER_LIST');
if ~hadNumberBlock || isempty(numLines)
    warning('read_events_from_curry_cef: NUMBER_LIST block not found or empty in %s.', eventFile);
    % No events to return; align outputs to empty row shapes
    event_time    = double(event_time(:)).';
    event_numbers = double(event_numbers(:)).';
    annotations   = annotations(:).';
    return;
end

% Parse each numeric line into integers; collect col5 (latency) & col3 (code)
latencies = [];
codes     = [];
mismatchWarned = false;
for i = 1:numel(numLines)
    lineText = strtrim(numLines{i});
    if isempty(lineText), continue; end
    nums = sscanf(lineText, '%d');
    if numel(nums) < 6
        warning('read_events_from_curry_cef: malformed NUMBER_LIST row %d in %s (only %d ints). Skipping.', i, eventFile, numel(nums));
        continue;
    end
    col1 = nums(1);   % sample (nominal onset)
    col3 = nums(3);   % type (code)
    col5 = nums(5);   % startsample (window start)  <-- now used for latency

    % Optional sanity check: warn once if col1 != col5
    if ~mismatchWarned && col1 ~= col5
        warning('read_events_from_curry_cef: onset mismatch (col1=%d, col5=%d) in %s (row %d). Using col5.', col1, col5, eventFile, i);
        mismatchWarned = true;
    end

    latencies(end+1) = col5; %#ok<AGROW>
    codes(end+1)     = col3; %#ok<AGROW>
end

% If nothing parsed successfully, early return
if isempty(latencies)
    warning('read_events_from_curry_cef: no valid NUMBER_LIST rows parsed in %s.', eventFile);
    event_time    = double([]);
    event_numbers = double([]);
    annotations   = {};
    return;
end

%% Parse REMARK_LIST (annotations)
[remarkLines, hadRemarkBlock] = extractBlockLines(content, 'REMARK_LIST');
if ~hadRemarkBlock
    % No remarks block: pad with empty strings (policy)
    annotations = repmat({''}, 1, numel(latencies));
else
    % Trim each remark line; keep all, then align to event count
    rawAnn = cellfun(@strtrim, remarkLines, 'UniformOutput', false);
    % Filter out trailing EMPTY lines that sometimes sneak in (optional)
    % rawAnn = rawAnn(~cellfun(@isempty, rawAnn));

    nEv   = numel(latencies);
    nAnn  = numel(rawAnn);
    if nAnn < nEv
        annotations = [rawAnn, repmat({''}, 1, nEv - nAnn)];
    else
        annotations = rawAnn(1:nEv);
    end
end

%% Assign outputs (row-shaped)
event_time    = double(latencies(:)).';
event_numbers = double(codes(:)).';
annotations   = annotations(:).';

end

% =======================================================================
% Local helper: extract lines inside "<SECTION> START_LIST" ... "END_LIST"
% Returns:
%   lines (1xM cellstr): each line between the markers (excludes marker lines)
%   found (logical): true if a block was found.
% If multiple blocks exist, the one with the **most lines** is returned.
% =======================================================================
function [lines, found] = local_extract_block_lines(txt, section)
lines = {};
found = false;

startTag = [section ' START_LIST'];
endTag   = [section ' END_LIST'];

sIdx = strfind(txt, startTag);
eIdx = strfind(txt, endTag);
if isempty(sIdx) || isempty(eIdx)
    return;
end

% Build candidate blocks as the first END after each START
blocks = struct('s', {}, 'e', {}, 'lines', {}, 'count', {});
for k = 1:numel(sIdx)
    eAfter = eIdx(eIdx > sIdx(k));
    if isempty(eAfter), continue; end
    s = sIdx(k);
    e = eAfter(1);
    % More robust: slice between markers, then split
    blockText = txt(s:e);
    % Drop the marker lines themselves
    blockText = strip(blockText);
    % Remove the first line (START_LIST...) and the last line (END_LIST...)
    blockLines = regexp(blockText, '\n', 'split');
    if numel(blockLines) >= 2
        blockLines = blockLines(2:end-1); % exclude the marker lines
    else
        blockLines = {};
    end
    % Clean up: drop purely empty lines
    blockLines = blockLines(~cellfun(@(t) isempty(strtrim(t)), blockLines));
    blocks(end+1) = struct('s', s, 'e', e, 'lines', {blockLines}, 'count', numel(blockLines)); %#ok<AGROW>
end

if isempty(blocks), return; end

% Choose the block with the most lines (typical for the data block)
[~, idx] = max([blocks.count]);
lines = blocks(idx).lines;
found = true;
end