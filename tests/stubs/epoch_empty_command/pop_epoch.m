function [EEG, indices, com] = pop_epoch(EEG, varargin) %#ok<INUSD>
%POP_EPOCH Test-only success with no history command.
indices = [];
com = '';
EEG.trials = 1;
EEG.epoch = struct('eventtype', 'stimulus');
end
