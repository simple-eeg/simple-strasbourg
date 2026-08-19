function seriesByEvent = collect_guardrail_event_series(epochs_pooled, channel, eventtypes, useExclusionFlags)
%COLLECT_GUARDRAIL_EVENT_SERIES Validate and collect screened event series.
%   seriesByEvent = COLLECT_GUARDRAIL_EVENT_SERIES(epochs_pooled, channel,
%   eventtypes, useExclusionFlags) returns one ordered struct element per
%   requested event type. The helper performs no plotting, logging, file
%   access, base-workspace access, or aggregation.

if ~isstruct(epochs_pooled) || isempty(epochs_pooled)
    error('collect_guardrail_event_series:InvalidEpochs', ...
        'epochs_pooled must be a non-empty struct array.');
end

channel = text_scalar(channel, 'channel');
eventtypes = string(eventtypes(:));
if isempty(eventtypes) || any(ismissing(eventtypes)) || ...
        any(strlength(strtrim(eventtypes)) == 0)
    error('collect_guardrail_event_series:InvalidEvents', ...
        'eventtypes must be a non-empty vector of nonblank text values.');
end
eventtypes = strtrim(eventtypes);
if numel(unique(eventtypes, 'stable')) ~= numel(eventtypes)
    error('collect_guardrail_event_series:DuplicateEvents', ...
        'eventtypes must contain distinct exact labels in the requested order.');
end
if ~islogical(useExclusionFlags) || ~isscalar(useExclusionFlags)
    error('collect_guardrail_event_series:InvalidExclusionSetting', ...
        'useExclusionFlags must be a logical scalar.');
end

nEvents = numel(eventtypes);
emptyIdentities = table(strings(0,1), strings(0,1), strings(0,1), ...
    zeros(0,1), strings(0,1), strings(0,1), ...
    'VariableNames', {'subjectID','sessionID','runID','epoch_index', ...
    'channel','eventtype'});
prototype = struct( ...
    'eventtype', "", ...
    'channel', channel, ...
    'data', [], ...
    'times_ms', [], ...
    'srate', NaN, ...
    'identities', emptyIdentities, ...
    'candidate_identities', emptyIdentities, ...
    'candidate_exclude', false(0,1), ...
    'n_candidates', 0, ...
    'n_flagged', 0, ...
    'n_excluded', 0, ...
    'n_admitted', 0, ...
    'use_exclusion_flags', useExclusionFlags);
seriesByEvent = repmat(prototype, nEvents, 1);
for eventIdx = 1:nEvents
    seriesByEvent(eventIdx).eventtype = eventtypes(eventIdx);
end

candidateData = cell(nEvents, 1);
candidateIdentities = cell(nEvents, 1);
candidateExclude = cell(nEvents, 1);
for eventIdx = 1:nEvents
    candidateData{eventIdx} = [];
    candidateIdentities{eventIdx} = emptyIdentities;
    candidateExclude{eventIdx} = false(0,1);
end

commonTimes = [];
commonSrate = NaN;

requiredFields = {'data','times_ms','channels','eventtype','epoch_index', ...
    'srate','subjectID','sessionID','runID','Exclude'};
for datasetIdx = 1:numel(epochs_pooled)
    ep = epochs_pooled(datasetIdx);
    for fieldIdx = 1:numel(requiredFields)
        if ~isfield(ep, requiredFields{fieldIdx})
            error('collect_guardrail_event_series:MissingField', ...
                'Dataset %d is missing required field %s.', ...
                datasetIdx, requiredFields{fieldIdx});
        end
    end

    if ~isnumeric(ep.data) || ~isreal(ep.data) || isempty(ep.data) || ...
            ndims(ep.data) > 3
        error('collect_guardrail_event_series:InvalidData', ...
            ['Dataset %d: data must be a non-empty real numeric ', ...
            '[nChannels x nPoints x nEpochs] array.'], datasetIdx);
    end
    if any(~isfinite(ep.data(:)))
        error('collect_guardrail_event_series:NonfiniteData', ...
            'Dataset %d: the full data array contains a nonfinite value.', ...
            datasetIdx);
    end

    nChannels = size(ep.data, 1);
    nPoints = size(ep.data, 2);
    nEpochs = size(ep.data, 3);
    if nPoints < 2
        error('collect_guardrail_event_series:InsufficientSamples', ...
            'Dataset %d: at least two time samples are required.', datasetIdx);
    end
    if ~islogical(ep.Exclude) || ...
            ~isequal(size(ep.Exclude), [nChannels, nEpochs])
        error('collect_guardrail_event_series:InvalidExclude', ...
            ['Dataset %d: Exclude must be logical with exact shape ', ...
            '[%d x %d].'], datasetIdx, nChannels, nEpochs);
    end

    subjectID = text_scalar(ep.subjectID, sprintf('dataset %d subjectID', datasetIdx));
    sessionID = text_scalar(ep.sessionID, sprintf('dataset %d sessionID', datasetIdx));
    runID = text_scalar(ep.runID, sprintf('dataset %d runID', datasetIdx));
    channelLabels = text_vector(ep.channels, datasetIdx, 'channels');
    epochEventtypes = text_vector(ep.eventtype, datasetIdx, 'eventtype');
    if numel(channelLabels) ~= nChannels
        error('collect_guardrail_event_series:ChannelCountMismatch', ...
            'Dataset %d: channels must contain %d labels.', ...
            datasetIdx, nChannels);
    end
    if numel(unique(lower(channelLabels))) ~= nChannels
        error('collect_guardrail_event_series:DuplicateChannels', ...
            ['Dataset %d: channel labels must be unique after ', ...
            'case-insensitive trimming.'], datasetIdx);
    end
    if numel(epochEventtypes) ~= nEpochs
        error('collect_guardrail_event_series:EventCountMismatch', ...
            'Dataset %d: eventtype must contain %d labels.', ...
            datasetIdx, nEpochs);
    end

    if ~isnumeric(ep.epoch_index) || ~isreal(ep.epoch_index)
        error('collect_guardrail_event_series:InvalidEpochIndex', ...
            'Dataset %d: epoch_index must be a real numeric vector.', datasetIdx);
    end
    epochIndex = double(ep.epoch_index(:));
    if numel(epochIndex) ~= nEpochs || any(~isfinite(epochIndex)) || ...
            any(mod(epochIndex, 1) ~= 0) || numel(unique(epochIndex)) ~= nEpochs
        error('collect_guardrail_event_series:InvalidEpochIndex', ...
            ['Dataset %d: epoch_index must contain one unique finite ', ...
            'integer per epoch.'], datasetIdx);
    end

    if ~isnumeric(ep.times_ms) || ~isreal(ep.times_ms)
        error('collect_guardrail_event_series:InvalidTimes', ...
            'Dataset %d: times_ms must be a real numeric vector.', datasetIdx);
    end
    thisTimes = double(ep.times_ms(:));
    if numel(thisTimes) ~= nPoints || any(~isfinite(thisTimes)) || ...
            any(diff(thisTimes) <= 0)
        error('collect_guardrail_event_series:InvalidTimes', ...
            ['Dataset %d: times_ms must contain %d finite, strictly ', ...
            'increasing samples.'], datasetIdx, nPoints);
    end
    if ~isnumeric(ep.srate) || ~isreal(ep.srate) || ~isscalar(ep.srate) || ...
            ~isfinite(ep.srate) || ep.srate <= 0
        error('collect_guardrail_event_series:InvalidSrate', ...
            'Dataset %d: srate must be one positive finite value.', datasetIdx);
    end
    thisSrate = double(ep.srate);
    expectedStepMs = 1000 / thisSrate;
    stepToleranceMs = max(1e-9, 1e-6 * expectedStepMs);
    if any(abs(diff(thisTimes) - expectedStepMs) > stepToleranceMs)
        error('collect_guardrail_event_series:IncoherentTimes', ...
            'Dataset %d: times_ms spacing is not coherent with srate.', datasetIdx);
    end

    channelMatches = find(lower(channelLabels) == lower(channel));
    if numel(channelMatches) > 1
        error('collect_guardrail_event_series:AmbiguousChannel', ...
            'Dataset %d: channel %s matched more than one label.', ...
            datasetIdx, channel);
    end
    if isempty(channelMatches)
        continue;
    end
    channelIdx = channelMatches(1);

    datasetContributes = any(ismember(epochEventtypes, eventtypes));
    if datasetContributes
        if isempty(commonTimes)
            commonTimes = thisTimes;
            commonSrate = thisSrate;
        else
            if ~isequal(commonTimes, thisTimes)
                error('collect_guardrail_event_series:TimeMismatch', ...
                    'Dataset %d: time vector differs from the first candidate dataset.', ...
                    datasetIdx);
            end
            % The consolidated series feeds both the TF and PSD routes,
            % whose Step 7 contracts require exact sampling-rate equality
            % across contributing datasets.
            if thisSrate ~= commonSrate
                error('collect_guardrail_event_series:SrateMismatch', ...
                    ['Dataset %d: sampling rate %.12g differs from the ', ...
                    'first candidate rate %.12g Hz.'], ...
                    datasetIdx, thisSrate, commonSrate);
            end
        end
    end

    for eventIdx = 1:nEvents
        matchingEpochs = find(epochEventtypes == eventtypes(eventIdx));
        if isempty(matchingEpochs)
            continue;
        end
        for matchIdx = 1:numel(matchingEpochs)
            epochIdx = matchingEpochs(matchIdx);
            thisSeries = reshape(ep.data(channelIdx, :, epochIdx), [], 1);
            if ~isvector(thisSeries) || numel(thisSeries) ~= nPoints
                error('collect_guardrail_event_series:MalformedSeries', ...
                    'Dataset %d, epoch_index %g: selected series is malformed.', ...
                    datasetIdx, epochIndex(epochIdx));
            end
            if ~isa(thisSeries, 'single') && ~isa(thisSeries, 'double')
                thisSeries = single(thisSeries);
            end
            if isempty(candidateData{eventIdx})
                candidateData{eventIdx} = thisSeries;
            else
                candidateData{eventIdx}(:, end+1) = thisSeries; %#ok<AGROW>
            end
            newIdentity = table(subjectID, sessionID, runID, epochIndex(epochIdx), ...
                channelLabels(channelIdx), eventtypes(eventIdx), ...
                'VariableNames', emptyIdentities.Properties.VariableNames);
            candidateIdentities{eventIdx} = [candidateIdentities{eventIdx}; newIdentity]; %#ok<AGROW>
            candidateExclude{eventIdx}(end+1, 1) = ep.Exclude(channelIdx, epochIdx); %#ok<AGROW>
        end
    end

end

allCandidateIdentities = emptyIdentities;
for eventIdx = 1:nEvents
    identities = candidateIdentities{eventIdx};
    if ~isempty(identities)
        allCandidateIdentities = [allCandidateIdentities; identities]; %#ok<AGROW>
    end
end
if ~isempty(allCandidateIdentities)
    identityKeys = allCandidateIdentities;
    identityKeys.channel = lower(strtrim(identityKeys.channel));
    [~, uniqueRows] = unique(identityKeys, 'rows', 'stable');
    if numel(uniqueRows) ~= height(identityKeys)
        error('collect_guardrail_event_series:DuplicateIdentity', ...
            'Selected candidates contain a duplicate full item identity.');
    end
end

for eventIdx = 1:nEvents
    nCandidates = size(candidateData{eventIdx}, 2);
    flags = candidateExclude{eventIdx};
    if nCandidates == 0
        error('collect_guardrail_event_series:NoCandidates', ...
            'No series matched channel %s and eventtype %s.', ...
            channel, eventtypes(eventIdx));
    end
    if numel(flags) ~= nCandidates || ...
            height(candidateIdentities{eventIdx}) ~= nCandidates
        error('collect_guardrail_event_series:InternalAssembly', ...
            'Internal candidate data and identity counts do not agree.');
    end
    if useExclusionFlags
        keepMask = ~flags;
        nExcluded = sum(flags);
    else
        keepMask = true(nCandidates, 1);
        nExcluded = 0;
    end
    if ~any(keepMask)
        error('collect_guardrail_event_series:NoAdmittedSeries', ...
            ['All candidates for channel %s and eventtype %s were ', ...
            'excluded; no series remain.'], channel, eventtypes(eventIdx));
    end

    seriesByEvent(eventIdx).data = candidateData{eventIdx}(:, keepMask);
    seriesByEvent(eventIdx).times_ms = commonTimes;
    seriesByEvent(eventIdx).srate = commonSrate;
    seriesByEvent(eventIdx).identities = candidateIdentities{eventIdx}(keepMask, :);
    seriesByEvent(eventIdx).candidate_identities = candidateIdentities{eventIdx};
    seriesByEvent(eventIdx).candidate_exclude = flags;
    seriesByEvent(eventIdx).n_candidates = nCandidates;
    seriesByEvent(eventIdx).n_flagged = sum(flags);
    seriesByEvent(eventIdx).n_excluded = nExcluded;
    seriesByEvent(eventIdx).n_admitted = sum(keepMask);
end
end

function value = text_scalar(value, label)
value = string(value);
if ~isscalar(value) || ismissing(value) || strlength(strtrim(value)) == 0
    error('collect_guardrail_event_series:InvalidTextScalar', ...
        '%s must be one nonblank text value.', label);
end
value = strtrim(value);
end

function values = text_vector(values, datasetIdx, label)
if ischar(values)
    values = string(cellstr(values));
elseif isstring(values) || iscellstr(values)
    values = string(values(:));
else
    error('collect_guardrail_event_series:InvalidTextVector', ...
        'Dataset %d: %s must be a text vector.', datasetIdx, label);
end
values = strtrim(values(:));
if any(ismissing(values)) || any(strlength(values) == 0)
    error('collect_guardrail_event_series:BlankText', ...
        'Dataset %d: %s contains a blank or missing value.', datasetIdx, label);
end
end
