function log_command_window(action)
% LOG_COMMAND_WINDOW  Start/stop mirroring MATLAB Command Window to a per-script log.
%
% Place calls at the top and bottom of each analysis script:
%   log_command_window('start');
%   clear; clc;
%   % ... your code ...
%   log_command_window('stop');
%
% Behavior:
%   - 'start': derives <project_root>/data/logs/<caller_script>.log and replaces it.
%              silently closes any previous diary, then starts a fresh one.
%   - 'stop' : turns diary off (idempotent; silent if already off).
%
% Assumptions:
%   - This file lives in <project_root>/scripts/.
%   - The repository-local helper must be on the MATLAB path.

% -------------------- 0) Validate input ------------------------------
if nargin ~= 1 || ~(ischar(action) || isstring(action))
    error('log_command_window:BadInput', ...
        'Usage: log_command_window(''start''|''stop'').');
end
act = lower(string(action));
if ~(act == "start" || act == "stop")
    error('log_command_window:BadAction', ...
        'Action must be ''start'' or ''stop''.');
end

% -------------------- 1) Stop case -----------------------------------
if act == "stop"
    diary off;  % safe if already off
    return;
end

% -------------------- 2) Determine caller script ---------------------
st = dbstack('-completenames');
if numel(st) < 2
    error('log_command_window:NoCaller', ...
        'log_command_window(''start'') must be called from a script or function.');
end
callerPath = st(2).file;             % e.g., .../scripts/step_1_source_1_create_dataset_list_prelim.m
[~, callerBase, ~] = fileparts(callerPath);

% -------------------- 3) Locate project root from THIS helper --------
helperFull = mfilename('fullpath');  % e.g., .../scripts/log_command_window.m
helperDir  = fileparts(helperFull);  % .../scripts
[projectRoot, leaf] = fileparts(helperDir);

if ~strcmpi(leaf, 'scripts')
    % Defensive fallback: walk up to find a folder named 'scripts'
    cur = helperDir;
    found = false;
    while true
        [parent, name] = fileparts(cur);
        if strcmpi(name, 'scripts')
            projectRoot = parent;
            found = true;
            break;
        end
        if isempty(parent) || strcmp(parent, cur)
            break; % reached filesystem root
        end
        cur = parent;
    end
    if ~found
        error('log_command_window:LayoutError', ...
            'Expected log_command_window.m to be inside a "scripts" folder.');
    end
end

% -------------------- 4) Ensure data/logs/ exists --------------------
logsDir = fullfile(projectRoot, 'data', 'logs');
if ~exist(logsDir, 'dir')
    ok = mkdir(logsDir);
    if ~ok
        error('log_command_window:MakeLogsFailed', ...
            'Failed to create logs directory: %s', logsDir);
    end
end

% -------------------- 5) Build fresh logfile path --------------------
logFile = fullfile(logsDir, [callerBase, '.log']);
if exist(logFile, 'file')
    try
        delete(logFile);  % replace, not append
    catch ME
        error('log_command_window:DeleteFailed', ...
            'Could not delete existing log file "%s": %s', logFile, ME.message);
    end
end

% -------------------- 6) Reset any prior diary; start new one --------
diary off;            % silently close any previous diary/file
diary(logFile);
diary on;

end
