% preproc() - Apply a set of preprocessing to a recording.
%
% Usage:
%   >> EEG = preproc(EEG, options);
%
% Inputs:
%   EEG       - EEGLAB EEG structure
%   options   - structure containing options. Fields omitted from the
%               structure use the defaults, which are as follows.
%          default = struct('reref',0,      'refchan',false, ...
%                  'resample',1,   'srate',500, ...
%                  'filter',1, 'cleanline',0, 'highpass',1, 'lowpass',30,...
%                  'linefilter',1, 'linefreq',50, ...
%                  'epoching',0,   'epochevents',false,  'baseadjust',0, ...
%                  'epochlimpre',2000,'epochlimpost',2000);
%
% Description of options fields:
%
% options.reref         - [0,1] if set to 1, re-reference to channel(s) specified in options.refchan
% options.refchan       - [cell] channel names to re-reference to. If multiple
%                               channels are selected, an average reference
%                               will be created from those channels. E.g.
%                                {{'CZ','C3'}}.
% options.resample      - [0,1] if set to 1, resample dataset to options.srate
% options.srate         - [numeric] desired sampling rate for resampling in Hz
% options.filter        - [0,1] apply high-pass and/or low-pass filters, specified
%                           by options.highpass and options.lowpass.
% options.highpass      - [numeric] desired high-pass filter pass-band edge in Hz. NB
%                         specifies the pass-band edge (not cut-off) and uses default
%                         EEGLAB settings to determine transition band
%                         width/slope. See EEGLAB function pop_eegfiltnew.
%                         If set to [], no high-pass filter is applied.
% options.lowpass       - [numeric] desired low-pass filter pass-band edge in Hz. NB
%                         specifies the pass-band edge (not cut-off) and uses default
%                         EEGLAB settings to determine transition band
%                         width/slope. See EEGLAB function pop_eegfiltnew.
%                         If set to [], no low-pass filter is applied.
% options.linefilter    - [0,1] if set to 1, filter out line noise at
%                           options.linefreq
% options.cleanline     - [0,1] if set to 1, use EEGLAB's cleanline plugin to filter
%                           out line noise. if set to 0 (default), a notch filter with
%                           pass-band edges [options.linefreq - 2,
%                           options.linefreq + 2] will be applied.
% options.linefreq      - [numeric] line frequency to filter out in Hz
% options.epoching      - [0,1] if set to 1, create epochs
% options.epochevents   - [cell] eventtypes around which to create epochs
% options.baseadjust    - [0,1] if set to 1, apply baseline correction by
%                           subtracting the pre-stimulus mean
%                           ('epochlimpre')
% options.epochlimpre   - [numeric] time in milliseconds before the event
% options.epochlimpost  - [numeric] time in milliseconds after the event
%
%
% Outputs:
%   EEG       - processed EEGLAB EEG structure

function EEG = preproc(EEG, options)

if nargin < 1
    help preproc;
    return
end
if nargin < 2
    error('SIMPLE:preproc:OptionsRequired', ...
        'preproc requires an explicit options structure.');
end
if isempty(EEG(1).data)
    error('Cannot preprocess empty dataset.');
end

% Fill omitted options fields
% ---------------------------
default = struct('reref',0,      'refchan',false,...
    'resample',1,   'srate',500, ...
    'filter',1, 'cleanline',0, 'highpass',1, 'lowpass',30,...
    'linefilter',1, 'linefreq',50, ...
    'epoching',0,   'epochevents',false,  'baseadjust',0, ...
    'epochlimpre',2000,'epochlimpost',2000);

s_merged = rmfield(default, intersect(fieldnames(default), fieldnames(options))); % Remove overlapping fields from default
names = [fieldnames(s_merged); fieldnames(options)]; % Get field names
opt = cell2struct([struct2cell(s_merged); struct2cell(options)], names, 1); % Merge structs

% Validate inputs
% ---------------
validateattributes(opt,{'struct'},{},'','opt (options structure)')
validateattributes(opt.reref,{'numeric','logical'},{'binary'},'','reref (apply rereferencing)')
validateattributes(opt.refchan,{'cell', 'logical'},{},'','refchan (reference channel)')
validateattributes(opt.resample,{'numeric','logical'},{'binary'},'','resample (apply resampling)')
validateattributes(opt.srate,{'numeric'},{'positive'},'','srate (new sampling rate)')
validateattributes(opt.filter,{'numeric','logical'},{'binary'},'','filter (apply filtering)')
validateattributes(opt.cleanline,{'numeric','logical'},{'binary'},'','cleanline (use cleanline to filter)')
validateattributes(opt.highpass,{'numeric'},{'positive'},'','highpass (passband lower bound)')
validateattributes(opt.lowpass,{'numeric'},{'positive'},'','lowpass (passband upper bound)')
validateattributes(opt.linefilter,{'numeric','logical'},{'binary'},'','linefilter (apply filtering for ''line'' noise)')
validateattributes(opt.linefreq,{'numeric'},{'positive'},'','linefreq (frequency/ies of potential ''line'' noise)')
validateattributes(opt.epoching,{'numeric','logical'},{'binary'},'','epoching (apply epoching)')
validateattributes(opt.epochevents,{'cell','logical'},{},'','epochevents (events to epoch around)')
validateattributes(opt.baseadjust,{'numeric','logical'},{'binary'},'','baseadjust (apply baseline correction)')
validateattributes(opt.epochlimpre,{'numeric'},{'positive'},'','epochlimpre (pre-event epoch length)')
validateattributes(opt.epochlimpost,{'numeric'},{'positive'},'','epochlimpost (post-event epoch length)')

% Process multiple datasets
% -------------------------
if length(EEG) > 1
    EEG = eeg_eval('preproc', EEG, 'params', {opt});
    return;
end

EEG = eeg_checkset(EEG, 'eventconsistency'); % Check all events for consistency & reorder

% Re-referencing
% --------------
if opt.reref
    refchannum = find(ismember({EEG.chanlocs.labels},opt.refchan));
    if refchannum

        % if some channels are missing, proceed with available channels
        if length(refchannum) < length(opt.refchan)
            refchannum_notfound = ~ismember(opt.refchan, {EEG.chanlocs.labels});
            warning("Channel(s) %s selected for re-referencing. " + ...
                "Channel(s) %s not found in the channel list. " + ...
                "Referenced to %s only." ,...
                strjoin(opt.refchan, ' & '), ...
                strjoin(opt.refchan(refchannum_notfound),' & '), ...
                strjoin(opt.refchan(~refchannum_notfound), ' & '));
        end

        EEG = pop_reref(EEG, refchannum);
        EEG = eeg_hist(EEG, sprintf('EEG = pop_reref(EEG, [%s]);',num2str(refchannum)));
    else
        % if all channels are missing, error out
        error("Channel(s) %s selected for re-referencing but none was found in the channel list." + ...
            " Channel names are case sensitive.",...
            strjoin(opt.refchan, ' & '))
    end
end

% Resampling
% ----------
if opt.resample && (abs(double(EEG.srate) - double(opt.srate)) > 1e-6)
    EEG = pop_resample(EEG, opt.srate);
    EEG = eeg_hist(EEG, sprintf('EEG = pop_resample(EEG, %d);', EEG.srate));
end

% Filters
% -------
if opt.filter % high and low pass
    if isempty(opt.highpass) & isempty(opt.lowpass)
        warning('Filtering turned on, but no pass-band edges were specified, therefore no filtering is applied.')
    end

    if ~isempty(opt.highpass)
        [EEG, filterCommand] = pop_eegfiltnew(EEG, 'locutoff',opt.highpass,'plotfreqz',0);
        if ~isempty(filterCommand)
            EEG = eeg_hist(EEG, filterCommand);
        end
    end

    if ~isempty(opt.lowpass)
        [EEG, filterCommand] = pop_eegfiltnew(EEG, 'hicutoff',opt.lowpass,'plotfreqz',0);
        if ~isempty(filterCommand)
            EEG = eeg_hist(EEG, filterCommand);
        end
    end
end
if opt.linefilter % filter mains & other line noise

    % ---------- sanitise line frequencies (support vectors; Nyquist-safe) ----------
    fNyquist = EEG.srate / 2;
    notchHalfWidth = 2; % Hz, +/-2 Hz design

    lf = unique(double(opt.linefreq(:))', 'stable'); % keep order, drop duplicates
    keep = (lf - notchHalfWidth > 0) & (lf + notchHalfWidth < fNyquist);

    if any(~keep)
        warning(['Skipping invalid linefreq value(s) at Fs=%g Hz ' ...
            '(requires f-%g > 0 and f+%g < Nyquist): %s'], ...
            EEG.srate, notchHalfWidth, notchHalfWidth, mat2str(lf(~keep)));
        lf = lf(keep);
    end

    if isempty(lf)
        warning('Line filtering requested, but no valid line frequencies remain after Nyquist checks. Skipping line filtering.');
    else

        if opt.cleanline % if user asked to try cleanline
            try % if cleanline plugin present
                [EEG, com] = pop_cleanline(EEG, ...
                    'linefreqs',            lf, ...
                    'sigtype',              'Channels', ...
                    'scanforlines',         true, ...
                    'bandwidth',            4, ...
                    'p',                    0.01, ...
                    'winsize',              4, ...
                    'winstep',              1, ...
                    'tau',                  100, ...
                    'pad',                  2, ...
                    'computepower',         false, ...
                    'plotfigures',          false, ...
                    'normSpectrum',         false, ...
                    'verb',                 false, ...
                    'newversion',           false);

                if ~isempty(com)
                    EEG = eeg_hist(EEG, com);
                end
            catch err % otherwise fallback to bandstop
                if strcmp(err.identifier,'MATLAB:UndefinedFunction')
                    warning('The cleanline plugin is not installed. Falling back to +/- %g Hz bandstop.', notchHalfWidth);

                    for n = 1:numel(lf)
                        freq = lf(n);
                        EEG = pop_eegfiltnew(EEG, ...
                            'locutoff', freq - notchHalfWidth, ...
                            'hicutoff', freq + notchHalfWidth, ...
                            'revfilt', 1, ...
                            'plotfreqz', 0);

                        EEG = eeg_hist(EEG, sprintf([ ...
                            'EEG = pop_eegfiltnew(EEG, ''locutoff'',%g,''hicutoff'',%g,''revfilt'',1,''plotfreqz'',0);' ], ...
                            freq - notchHalfWidth, freq + notchHalfWidth));
                    end
                else
                    rethrow(err)
                end
            end

        else % if user did not ask to try cleanline (default notch approach)
            for n = 1:numel(lf)
                freq = lf(n);
                EEG = pop_eegfiltnew(EEG, ...
                    'locutoff', freq - notchHalfWidth, ...
                    'hicutoff', freq + notchHalfWidth, ...
                    'revfilt', 1, ...
                    'plotfreqz', 0);

                EEG = eeg_hist(EEG, sprintf([ ...
                    'EEG = pop_eegfiltnew(EEG, ''locutoff'',%g,''hicutoff'',%g,''revfilt'',1,''plotfreqz'',0);' ], ...
                    freq - notchHalfWidth, freq + notchHalfWidth));
            end
        end

    end
end

% Create epochs & baseline
% ------------------------
if opt.epoching
    if ~iscell(opt.epochevents)
        error('Epoching was selected but no events were given for epoching. Pass a cell array of event names, or turn epoching to false.')
    end
    epochevents = opt.epochevents;
    epochlims = [-opt.epochlimpre, opt.epochlimpost];

    warningState = warning;
    try
        if opt.baseadjust
            warning('off', "") % switch off EEGLAB's "remove baseline in menu" warning
        end
        [EEG, ~, epochCommand] = pop_epoch(EEG, epochevents, epochlims/1000);
        warning(warningState) % restore the caller's warning configuration
        if ~isempty(epochCommand)
            EEG = eeg_hist(EEG, epochCommand);
        end

        if opt.baseadjust
            EEG = pop_rmbase(EEG, [EEG.times(1), 0]);
            EEG = eeg_hist(EEG, sprintf('EEG = pop_rmbase(EEG, [%d 0]);',EEG.times(1)));
        end

    catch err
        warning(warningState)
        if strcmp(err.message, 'pop_epoch(): empty epoch range (no epochs were found).')
            warning('Epoching was selected, but no epochs were found.')
        else
            rethrow(err)
        end
    end

    if isempty(EEG.epoch)
        warning('Single epoch created, which is currently not supported by EEGLAB.\n%s', ...
            'You should add another event (e.g. a dummy event) to epoch on.')

    else
        if iscell([EEG.epoch.eventtype])
            warning('At least one epoch contains more than one event. This can create unexpected effects later on.\n%s',...
                'Check epoch length and/or consider removing unnecessary events.')
        end
    end


end

end
