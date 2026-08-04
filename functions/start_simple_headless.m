function start_simple_headless(varargin)
% start_simple_headless  Start EEGLAB in nogui and initialize SIMPLE.
%
% Usage:
%   start_simple_headless
%   start_simple_headless('eeglabRoot','/Users/you/Documents/MATLAB/eeglab2024.2')
%
% Name-Value pairs:
%   'eeglabRoot' (char) : Path to EEGLAB root if it's not already on the MATLAB path.
%   'check'      (logical, default true): Warn if SIMPLE core functions aren't found.
%
% Notes:
% - Safe to call multiple times per session (idempotent).
% - Requires the SIMPLE plugin folder to be inside <eeglabRoot>/plugins/simple
%   or otherwise already on the path.

% ---- parse inputs ----
p = inputParser;
p.addParameter('eeglabRoot','',@(s)ischar(s) || isstring(s));
p.addParameter('check',true,@(b)islogical(b) && isscalar(b));
p.parse(varargin{:});
eeglabRoot = char(p.Results.eeglabRoot);
doCheck    = p.Results.check;

% ---- ensure EEGLAB is on path ----
if ~exist('eeglab','file')
    if ~isempty(eeglabRoot) && exist(eeglabRoot,'dir')
        addpath(eeglabRoot);  % let "eeglab nogui" manage its own subpaths
    else
        error(['EEGLAB not found on path. Either add it to the MATLAB path first ' ...
            'or call start_simple_headless(''eeglabRoot'',''/path/to/eeglab2024.2'').']);
    end
end

% ---- start EEGLAB in nogui (idempotent) ----
eeglab nogui;

% ---- ensure SIMPLE plugin entry point is reachable ----
if ~exist('eegplugin_simple','file')
    % Try the conventional plugin location; prefer the newest versioned "simple*" folder.
    if ~isempty(eeglabRoot)
        pluginsDir = fullfile(eeglabRoot,'plugins');
        if exist(pluginsDir,'dir')
            cand = dir(fullfile(pluginsDir,'simple*'));
            cand = cand([cand.isdir]);
            % pick highest semantic version among names like "simple1.0.0"
            bestName = '';
            bestVer  = [];
            for k = 1:numel(cand)
                t = regexp(cand(k).name, '^simple(\d+(?:\.\d+)*)$', 'tokens', 'once');
                if ~isempty(t)
                    v = str2double(strsplit(t{1},'.'));
                    L = max(numel(v), numel(bestVer));
                    vp = [v, zeros(1,L-numel(v))];
                    bp = [bestVer, zeros(1,L-numel(bestVer))];
                    if isempty(bestVer) || any(vp > bp) && ~any(vp < bp)
                        bestVer  = v;
                        bestName = cand(k).name;
                    elseif isempty(bestVer)
                        bestName = cand(k).name;
                    end
                end
            end
            if ~isempty(bestName)
                addpath(fullfile(pluginsDir, bestName));
            else
                % fallback to unversioned "simple" if present
                if exist(fullfile(pluginsDir,'simple'),'dir')
                    addpath(fullfile(pluginsDir,'simple'));
                end
            end
        end
    end
    if ~exist('eegplugin_simple','file')
        error('SIMPLE plugin not found (eegplugin_simple.m). Check your installation in <eeglabRoot>/plugins/simple');
    end
end

% ---- initialize SIMPLE (idempotent: your plugin guards duplicate paths) ----
eegplugin_simple([], struct, struct);

% ---- optional sanity check ----
if doCheck
    missing = {};
    if isempty(which('estimate_response')),        missing{end+1} = 'estimate_response'; end %#ok<AGROW>
    if isempty(which('quality_control_features')), missing{end+1} = 'quality_control_features'; end %#ok<AGROW>
    if isempty(which('pop_preproc')),              missing{end+1} = 'pop_preproc'; end %#ok<AGROW>
    if ~isempty(missing)
        warning('SIMPLE appears not fully initialized (missing: %s). Check plugin subfolders/paths.', strjoin(missing, ', '));
    end
end
end