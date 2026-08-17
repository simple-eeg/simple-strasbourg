% estimate_response() - Estimate NRF fit metrics for an epoched dataset.
%
% Usage:
%   >> EEG = estimate_response(EEG, options);
%
% Inputs:
%   EEG       - EEGLAB EEG structure with at least two epochs
%   options   - structure containing options. Omitted fields use:
%                   default = struct('NRFName','noxious_NRF_500Hz', ...
%                           'baselineLength',500, ...
%                           'jitter',50, ...
%                           'channel',{'Cz'}, ...
%                           'projectionTimes_pre',[], ...
%                           'projectionTimes_post',400);
%
% options.NRFName             - logical bundled-template basename, or an
%                               explicit template path
% options.baselineLength      - baseline length in milliseconds
% options.jitter              - maximum jitter correction in milliseconds
% options.channel             - channel label to fit
% options.projectionTimes_pre - one finite scalar start at or before 0 ms,
%                               with projectionTimes_post empty
% options.projectionTimes_post- one finite scalar start at or after 0 ms,
%                               with projectionTimes_pre empty
%
% Output:
%   EEG_singleChannel - channel-selected EEGLAB structure containing fit
%                       measures in EEG.epoch.(NRFName) for every epoch

function EEG_singleChannel = estimate_response(EEG, options)

if nargin < 1
    help estimate_response;
    return
end
if nargin < 2
    error('SIMPLE:estimate_response:OptionsRequired', ...
        'estimate_response requires an explicit options structure.');
end
if ~isstruct(options) || ~isscalar(options)
    error('SIMPLE:estimate_response:InvalidOptions', ...
        'options must be one scalar structure.');
end

if length(EEG) == 1
    hasTwoTrials = isfield(EEG, 'trials') && isscalar(EEG.trials) && EEG.trials >= 2;
    hasTwoEpochs = isfield(EEG, 'epoch') && numel(EEG.epoch) >= 2;
    if ~(hasTwoTrials && hasTwoEpochs)
        error('SIMPLE:estimate_response:InsufficientEpochs', ...
            ['No epoched data. Please epoch first. An EEGLAB EEG struct needs at least two epochs. ' ...
            'If you only have one event in your dataset, add a dummy event.'])
    end
end

% Fill omitted options fields.
default = struct('NRFName','noxious_NRF_500Hz', ...
    'baselineLength',500, ...
    'jitter',50, ...
    'channel',{'Cz'}, ...
    'projectionTimes_pre',[], ...
    'projectionTimes_post',400);

s_merged = rmfield(default, intersect(fieldnames(default), fieldnames(options)));
names = [fieldnames(s_merged); fieldnames(options)];
opt = cell2struct([struct2cell(s_merged); struct2cell(options)], names, 1);

if ~valid_projection_pair(opt.projectionTimes_pre, opt.projectionTimes_post)
    error('SIMPLE:estimate_response:InvalidProjectionTimes', ...
        ['Specify exactly one finite real numeric scalar projection start: ' ...
        'projectionTimes_pre must be empty or <= 0, and ' ...
        'projectionTimes_post must be empty or >= 0.'])
end
if ~isnumeric(opt.jitter) || ~isreal(opt.jitter) || ...
        ~isscalar(opt.jitter) || ~isfinite(opt.jitter) || opt.jitter < 0
    error('SIMPLE:estimate_response:InvalidJitter', ...
        'jitter must be a finite nonnegative real numeric scalar in milliseconds.');
end
if ~isnumeric(opt.baselineLength) || ~isreal(opt.baselineLength) || ...
        ~isscalar(opt.baselineLength) || ~isfinite(opt.baselineLength) || ...
        opt.baselineLength < 0
    error('SIMPLE:estimate_response:InvalidBaselineLength', ...
        ['baselineLength must be a finite nonnegative real numeric scalar ' ...
        'in milliseconds.']);
end
if isstring(opt.channel)
    if ~isscalar(opt.channel) || ismissing(opt.channel)
        error('SIMPLE:estimate_response:InvalidChannel', ...
            'channel must be one non-empty character vector or string scalar.');
    end
    opt.channel = char(opt.channel);
end
if ~ischar(opt.channel) || size(opt.channel, 1) ~= 1 || ...
        isempty(strtrim(opt.channel))
    error('SIMPLE:estimate_response:InvalidChannel', ...
        'channel must be one non-empty character vector or string scalar.');
end
opt.channel = strtrim(opt.channel);
opt.jitter = double(opt.jitter);
opt.baselineLength = double(opt.baselineLength);
if ~isempty(opt.projectionTimes_pre)
    opt.projectionTimes_pre = double(opt.projectionTimes_pre);
end
if ~isempty(opt.projectionTimes_post)
    opt.projectionTimes_post = double(opt.projectionTimes_post);
end

% Process multiple datasets through EEGLAB's ordinary array dispatcher.
if length(EEG) > 1
    EEG_singleChannel = eeg_eval('estimate_response', EEG, 'params', {opt});
    return
end

if ~isfield(EEG, 'srate') || ~isnumeric(EEG.srate) || ...
        ~isreal(EEG.srate) || ~isscalar(EEG.srate) || ...
        ~isfinite(EEG.srate) || EEG.srate <= 0
    error('SIMPLE:estimate_response:InvalidSamplingRate', ...
        'EEG.srate must be a finite positive real numeric scalar.');
end
if ~isfield(EEG, 'xmin') || ~isnumeric(EEG.xmin) || ...
        ~isreal(EEG.xmin) || ~isscalar(EEG.xmin) || ~isfinite(EEG.xmin)
    error('SIMPLE:estimate_response:InvalidTimeOrigin', ...
        'EEG.xmin must be a finite real numeric scalar in seconds.');
end

% Resolve logical names only against this repository's bundled templates.
repositoryRoot = fileparts(fileparts(mfilename('fullpath')));
[logicalName, templateFile] = NRFUtils.resolveTemplateFile( ...
    opt.NRFName, repositoryRoot);
template = load(templateFile);

if ~isfield(template, 'NRF')
    error('A NRF file needs to contain a NRF variable.')
elseif ~isfield(template, 'fs')
    error('A NRF file needs to contain the NRF sampling rate.')
end
if ~isnumeric(template.NRF) || ~isreal(template.NRF) || ...
        ~isvector(template.NRF) || numel(template.NRF) < 2 || ...
        ~all(isfinite(template.NRF(:)))
    error('A NRF variable must be a finite real numeric vector with at least two samples.')
end
if ~isnumeric(template.fs) || ~isreal(template.fs) || ...
        ~isscalar(template.fs) || ~isfinite(template.fs) || template.fs <= 0
    error('A NRF sampling rate must be a finite positive numeric scalar.')
end
dataSamplingRate = double(EEG.srate);
templateSamplingRate = double(template.fs);
if templateSamplingRate ~= dataSamplingRate
    error(['NRF (sampling rate: ', num2str(template.fs), ...
        'Hz) and data (sampling rate: ', num2str(EEG.srate), ...
        'Hz) have incompatible sampling rates.'])
end

if isempty(opt.projectionTimes_pre)
    projectionStartMs = opt.projectionTimes_post;
else
    projectionStartMs = opt.projectionTimes_pre;
end
zeroTimeMs = -double(EEG.xmin) * 1000;
absoluteStartMs = zeroTimeMs + double(projectionStartMs);
sampleStart = absoluteStartMs * dataSamplingRate / 1000;
if abs(sampleStart - round(sampleStart)) >= 1e-9
    error('SIMPLE:estimate_response:ProjectionOffSampleGrid', ...
        ['The absolute projection start must align exactly with the EEG ' ...
        'sample grid.']);
end
sampleStart = round(sampleStart);
absoluteStartMs = sampleStart * 1000 / dataSamplingRate;
canonicalProjectionStartMs = absoluteStartMs - zeroTimeMs;
if isempty(opt.projectionTimes_pre)
    opt.projectionTimes_post = canonicalProjectionStartMs;
else
    opt.projectionTimes_pre = canonicalProjectionStartMs;
end

% Match jittercorrect's retained search-window rounding exactly, but reject
% invalid windows before channel selection, baseline correction or fitting.
searchStartIndex = ceil((absoluteStartMs - double(opt.jitter)) / ...
    1000 * dataSamplingRate) + 1;
searchEndIndex = ceil((absoluteStartMs + double(opt.jitter)) / ...
    1000 * dataSamplingRate + numel(template.NRF) - 1) + 1;
dataPointCount = size(EEG.data, 2);
if searchStartIndex < 1 || searchEndIndex > dataPointCount
    error('SIMPLE:estimate_response:ProjectionOutOfBounds', ...
        ['The NRF projection and its full jitter search window must fit ' ...
        'inside every EEG epoch.']);
end

% Select and baseline-correct the requested channel.
EEG_singleChannel = pop_select(EEG, 'channel', {opt.channel});
baselineEndIndex = find(EEG_singleChannel.times < 0, 1, 'last');
if isempty(baselineEndIndex)
    error('SIMPLE:estimate_response:NoNegativeBaseline', ...
        'NRF fitting requires at least one negative-time sample for baseline correction.')
end
baselineEndMs = EEG_singleChannel.times(baselineEndIndex);
EEG_singleChannel = pop_rmbase(EEG_singleChannel, ...
    [-opt.baselineLength baselineEndMs]);

disp('Estimating responses...')
for numEpoch = 1:length(EEG_singleChannel.epoch)
    [pearsonR, shifted_data_all, shift_all, NRF_resampled, ...
        cosineSimilarity, coef, varcoef, ols_coef] = ...
        estimate_response_epoch( ...
        double(EEG_singleChannel.data(:,:,numEpoch)), template.NRF, ...
        dataSamplingRate, templateSamplingRate, opt.jitter, ...
        absoluteStartMs);

    EEG_singleChannel.epoch(numEpoch).(logicalName).projectionTimes = ...
        [opt.projectionTimes_pre, opt.projectionTimes_post];
    EEG_singleChannel.epoch(numEpoch).(logicalName).pearsonR = pearsonR;
    EEG_singleChannel.epoch(numEpoch).(logicalName).shifted_data_all = shifted_data_all;
    EEG_singleChannel.epoch(numEpoch).(logicalName).shift_all = shift_all;
    EEG_singleChannel.epoch(numEpoch).(logicalName).NRF_resampled = NRF_resampled;
    EEG_singleChannel.epoch(numEpoch).(logicalName).cosineSimilarity = cosineSimilarity;
    EEG_singleChannel.epoch(numEpoch).(logicalName).fglsCoef = coef;
    EEG_singleChannel.epoch(numEpoch).(logicalName).fglsVarCoef = varcoef;
    EEG_singleChannel.epoch(numEpoch).(logicalName).olsCoef = ols_coef;
end

historyOptions = opt;
templateRequest = char(opt.NRFName);
if contains(templateRequest, '/') || contains(templateRequest, '\')
    historyOptions.NRFName = templateFile;
else
    historyOptions.NRFName = logicalName;
end
historyOptions.channel = char(historyOptions.channel);
historyCommand = sprintf('EEG = estimate_response(EEG, %s);', ...
    vararg2str({historyOptions}));
EEG_singleChannel = eeg_hist(EEG_singleChannel, historyCommand);

end

function tf = valid_projection_pair(pre_t, post_t)
preWellFormed = isnumeric(pre_t) && isreal(pre_t) && ...
    (isempty(pre_t) || (isscalar(pre_t) && isfinite(pre_t)));
postWellFormed = isnumeric(post_t) && isreal(post_t) && ...
    (isempty(post_t) || (isscalar(post_t) && isfinite(post_t)));
if ~(preWellFormed && postWellFormed)
    tf = false;
    return
end
hasPre = ~isempty(pre_t);
hasPost = ~isempty(post_t);
if ~xor(hasPre, hasPost)
    tf = false;
    return
end
if hasPre
    tf = pre_t <= 0;
else
    tf = post_t >= 0;
end
end

function [pearsonR, shifted_data_all, shift_all, NRF_resampled, ...
    cosineSimilarity, fgls_coef, fgls_varcoef, ols_coef] = ...
    estimate_response_epoch(data, NRF, fs, fs_NRF, jitter, absolute_start_ms)
% Retained single-epoch numerical calculation. This is intentionally local:
% the supported public interface is estimate_response(EEG, options).

t = absolute_start_ms;
shifted_data_all = cell(length(t),1);
shift_all = NaN(length(t),1);
cosineSimilarity = NaN(length(t),1);
fgls_coef = NaN(length(t),1);
fgls_varcoef = NaN(length(t),1);
ols_coef = NaN(length(t),1);

for n = 1:length(t)
    start_time = t(n);
    start_index = round(start_time*fs/1000) + 1;
    [shifted_data, shift, NRF_resampled] = jittercorrect( ...
        data, NRF, fs, fs_NRF, jitter, start_time);
    epoch = shifted_data(start_index:start_index + length(NRF_resampled)-1);
    if ~isequal(length(NRF_resampled), length(epoch))
        error('NRF does not have the same length as data')
    end
    shifted_data_all{n} = shifted_data;
    shift_all(n) = shift;

    pearsonR(n) = corr(NRF_resampled, epoch'); %#ok<AGROW>
    cosineSimilarity(n) = dot(epoch, NRF_resampled) / ...
        (norm(epoch) * norm(NRF_resampled));

    x_NRF = NRF_resampled;
    y_DATA = epoch';
    [fgls_coef(n), sterror] = fgls((x_NRF - mean(x_NRF)), ...
        (y_DATA - mean(y_DATA)), Intercept=false, InnovMdl="AR", ...
        ARLags=1, NumIter=5, Plot="off");
    fgls_varcoef(n) = sterror^2;
    ols_coef(n) = fgls((x_NRF - mean(x_NRF)), ...
        (y_DATA - mean(y_DATA)), Intercept=false, InnovMdl="CLM", ...
        NumIter=1, Plot="off");
end
end
