classdef NRFUtils
    % NRFUtils
    % A light, stateless namespace for NRF feature-extraction utilities.
    %
    % Public static API:
    %   profiles = NRFUtils.parseIni(config_path)
    %   profiles = NRFUtils.validateProfiles(profiles)
    %   map      = NRFUtils.readEpochTypeMapping(epoch_csv, profiles, families)
    %   [fit_cache, templ_info] = NRFUtils.fitAndCache(EEG, profiles, used_profile_names, labels, zero_t_ms)
    %
    % Notes:
    % - No user paths are hard-coded here; everything is passed in.
    % - Methods are stateless and throw informative errors on invalid inputs.

    methods (Static)

        function profiles = parseIni(config_path)
            % Parse a minimal INI with:
            %   - Whole-line comments starting with '#'
            %   - [section] headers
            %   - key = value pairs (keys case-insensitive; normalized to expected names)
            % Keys required per section:
            %   NRFName, baselineLength, jitter, channel, projectionTimes_pre, projectionTimes_post
            if ~exist(config_path,'file'); error('INI file not found: %s', config_path); end
            lines = splitlines(string(fileread(config_path)));

            profiles = struct();
            current = struct(); current_name = '';

            for i = 1:numel(lines)
                L = strtrim(lines(i));
                if L == "" || startsWith(L, "#")
                    continue;
                end
                if startsWith(L, "[") && endsWith(L, "]")
                    % Finish previous section if any
                    if ~isempty(current_name)
                        profiles.(current_name) = current;
                    end
                    % Safe extraction of the section name
                    Lchar = char(L);
                    if Lchar(1) ~= '[' || Lchar(end) ~= ']'
                        error('Bad INI section header: %s', Lchar);
                    end
                    current_name = strtrim(Lchar(2:end-1));
                    % Initialize blank with all expected keys (validated later)
                    current = struct('NRFName', '', 'baselineLength', [], 'jitter', [], ...
                        'channel', {{}}, 'projectionTimes_pre', [], 'projectionTimes_post', []);
                    continue;
                end

                % key = value
                parts = split(L, "=", 2);
                if numel(parts) ~= 2
                    error('Bad INI line (no "="): %s', L);
                end
                key = strtrim(parts(1));
                val = strtrim(parts(2));

                % Normalize key
                switch lower(key)
                    case 'nrfname'
                        current.NRFName = char(val);
                    case 'baselinelength'
                        current.baselineLength = NRFUtils.parseScalarOrError(val, 'baselineLength');
                    case 'jitter'
                        current.jitter = NRFUtils.parseScalarOrError(val, 'jitter');
                    case 'channel'
                        current.channel = NRFUtils.parseChannelList(val); % cellstr, deduped, order-preserving
                    case 'projectiontimes_pre'
                        current.projectionTimes_pre = NRFUtils.parseScalarOrEmpty(val, 'projectionTimes_pre');
                    case 'projectiontimes_post'
                        current.projectionTimes_post = NRFUtils.parseScalarOrEmpty(val, 'projectionTimes_post');
                    otherwise
                        error('Unknown INI key "%s". Allowed keys: NRFName, baselineLength, jitter, channel, projectionTimes_pre, projectionTimes_post.', key);
                end
            end
            % finalize last section
            if ~isempty(current_name)
                profiles.(current_name) = current;
            end

            if isempty(fieldnames(profiles))
                error('No profiles found in INI: %s', config_path);
            end
        end

        function profiles = validateProfiles(profiles)
            % Enforce:
            %   - NRFName non-empty (char)
            %   - channel is non-empty list (cellstr)
            %   - baselineLength, jitter numeric scalars
            %   - Exactly one of projectionTimes_pre / projectionTimes_post is scalar; the other empty.
            %   - Sign conventions (allow zero): pre ≤ 0 if present; post ≥ 0 if present
            % Add:
            %   - proj_scalar (the single start, ms)
            names = fieldnames(profiles);
            for i = 1:numel(names)
                nm = names{i};
                p = profiles.(nm);

                if isempty(p.NRFName) || ~ischar(p.NRFName)
                    error('Profile "%s": NRFName must be a non-empty string.', nm);
                end
                if isempty(p.channel) || ~iscell(p.channel)
                    error('Profile "%s": channel must be a comma-separated list.', nm);
                end
                if ~isscalar(p.baselineLength) || ~isfinite(p.baselineLength)
                    error('Profile "%s": baselineLength must be a numeric scalar.', nm);
                end
                if ~isscalar(p.jitter) || ~isfinite(p.jitter)
                    error('Profile "%s": jitter must be a numeric scalar.', nm);
                end

                hasPre  = ~isempty(p.projectionTimes_pre);
                hasPost = ~isempty(p.projectionTimes_post);
                if xor(hasPre, hasPost) == 0
                    error('Profile "%s": exactly one of projectionTimes_pre or projectionTimes_post must be a scalar (the other empty).', nm);
                end
                if hasPre
                    if ~isscalar(p.projectionTimes_pre) || ~isfinite(p.projectionTimes_pre)
                        error('Profile "%s": projectionTimes_pre must be a numeric scalar or empty.', nm);
                    end
                    if ~(p.projectionTimes_pre <= 0)
                        error('Profile "%s": projectionTimes_pre must be ≤ 0 (ms).', nm);
                    end
                    p.proj_scalar = p.projectionTimes_pre;
                end
                if hasPost
                    if ~isscalar(p.projectionTimes_post) || ~isfinite(p.projectionTimes_post)
                        error('Profile "%s": projectionTimes_post must be a numeric scalar or empty.', nm);
                    end
                    if ~(p.projectionTimes_post >= 0)
                        error('Profile "%s": projectionTimes_post must be ≥ 0 (ms).', nm);
                    end
                    p.proj_scalar = p.projectionTimes_post;
                end

                profiles.(nm) = p;
            end
        end

        function map = readEpochTypeMapping(epoch_csv, profiles, families)
            % Read CSV with columns: Type, early_NRF, noxious_NRF, noxious_preterm_NRF
            % Build three containers.Map: for each family, Type (case-sensitive) -> profileName
            if ~exist(epoch_csv,'file'); error('Mapping CSV not found: %s', epoch_csv); end
            Tmap = readtable(epoch_csv, 'PreserveVariableNames', true);

            % Required-column check
            req = [{'Type'}, families];
            missingCols = setdiff(req, Tmap.Properties.VariableNames);
            if ~isempty(missingCols)
                error('Mapping CSV missing required cols: %s', strjoin(missingCols, ', '));
            end

            map = struct();
            for f = 1:numel(families)
                map.(families{f}) = containers.Map('KeyType','char','ValueType','char');
            end

            for i = 1:height(Tmap)
                % Robustly extract Type as a string scalar
                rawType  = Tmap.Type(i);
                etype_s  = string(rawType);
                if ismissing(etype_s) || strlength(strtrim(etype_s)) == 0
                    error('Row %d in CSV has empty Type.', i);
                end
                etype = char(etype_s); % case-sensitive

                for f = 1:numel(families)
                    fam = families{f};
                    raw        = Tmap.(fam)(i);   % string or 1x1 cellstr or char
                    cellval_s  = string(raw);     % normalize

                    % Treat blank/whitespace as empty
                    if ismissing(cellval_s) || strlength(strtrim(cellval_s)) == 0
                        continue; % unmapped for this family
                    end

                    pname = char(strtrim(cellval_s));
                    if ~isfield(profiles, pname)
                        error('CSV references profile "%s" (family %s) at Type "%s" but it is not defined in INI.', ...
                            pname, fam, etype);
                    end
                    map.(fam)(etype) = pname;
                end
            end
        end

        function [fit_cache, templ_info] = fitAndCache(EEG, profiles, used_profile_names, labels, zero_t_ms)
            % Build per-dataset caches once per (profile, channel).
            %
            % Inputs:
            %   EEG               - EEGLAB struct, already loaded
            %   profiles          - struct of profileName -> options (validated; has .proj_scalar)
            %   used_profile_names- cellstr of profile names that are needed for this dataset
            %   labels            - cellstr of EEG channel labels present in this dataset
            %   zero_t_ms         - scalar ms from epoch start to "0 ms"
            %
            % Outputs:
            %   fit_cache         - struct: profileName -> channel -> EEG_fit (whole-dataset fits)
            %   templ_info        - struct: NRFName -> .fs, .duration_ms

            templ_info = struct();   % keyed by NRFName
            fit_cache  = struct();   % keyed by profileName -> channel

            for up = 1:numel(used_profile_names)
                pname = used_profile_names{up};
                p = profiles.(pname);

                % Template info (load once)
                if ~isfield(templ_info, p.NRFName)
                    S = load([p.NRFName, '.mat']); % must contain NRF and fs; on MATLAB path
                    if ~isfield(S, 'NRF') || ~isfield(S, 'fs')
                        error('NRF file %s.mat must contain variables NRF and fs.', p.NRFName);
                    end
                    templ_info.(p.NRFName).fs = S.fs;
                    templ_info.(p.NRFName).duration_ms = numel(S.NRF)/S.fs*1000;
                end
                if templ_info.(p.NRFName).fs ~= EEG.srate
                    error('Sampling-rate mismatch for %s: NRF fs=%g, EEG.srate=%g', ...
                        p.NRFName, templ_info.(p.NRFName).fs, EEG.srate);
                end

                % Runtime checks tied to dataset/sample rate (once per profile)
                start_ms     = p.proj_scalar;           % scalar (pre ≤ 0 or post ≥ 0)
                abs_start_ms = zero_t_ms + start_ms;
                if abs_start_ms < p.jitter
                    error(['Profile "%s": abs_start_ms (zero_t + start = %.3f ms) ', ...
                        'must be >= jitter (%.3f ms). Consider increasing pre-stimulus window or reducing jitter.'], ...
                        pname, abs_start_ms, p.jitter);
                end
                if ~NRFUtils.isIndexInteger(abs_start_ms, EEG.srate)
                    step_ms = 1000/EEG.srate;
                    error(['Profile "%s": abs_start_ms = %.3f ms is not aligned to the sample grid. ', ...
                        'At %.0f Hz, valid starts are multiples of %.3f ms.'], ...
                        pname, abs_start_ms, EEG.srate, step_ms);
                end

                % Channels present for this profile
                ch_present = {};
                for c = 1:numel(p.channel)
                    if any(strcmp(labels, p.channel{c}))
                        ch_present{end+1} = p.channel{c}; %#ok<AGROW>
                    end
                end
                if isempty(ch_present)
                    % No present channels for this profile in this dataset; nothing to cache.
                    continue;
                end

                % Initialize cache slot for this profile
                if ~isfield(fit_cache, pname)
                    fit_cache.(pname) = struct();
                end

                % Compute fits once per present channel (whole dataset)
                for c = 1:numel(ch_present)
                    ch = ch_present{c};
                    if isfield(fit_cache.(pname), ch)
                        continue; % already cached
                    end

                    opt = struct( ...
                        'NRFName',              p.NRFName, ...
                        'baselineLength',       p.baselineLength, ...
                        'jitter',               p.jitter, ...
                        'channel',              ch, ...
                        'projectionTimes_pre',  p.projectionTimes_pre, ...
                        'projectionTimes_post', p.projectionTimes_post);

                    EEG_fit = pop_estimate_response(EEG, opt);   % computes for ALL epochs at this channel
                    fit_cache.(pname).(ch) = EEG_fit;
                end
            end
        end

    end % methods (Static)

    methods (Static, Access = private)

        function val = parseScalarOrError(strval, keyname)
            % Parse a numeric scalar from INI "key = value" form. Error if invalid.
            strval = char(strtrim(strval));
            if isempty(strval)
                error('INI key %s must be specified.', keyname);
            end
            val = str2double(strval);
            if ~isscalar(val) || ~isfinite(val)
                error('INI key %s must be a numeric scalar.', keyname);
            end
        end

        function val = parseScalarOrEmpty(strval, keyname)
            % Parse either empty or a numeric scalar (no lists).
            % Empty means: nothing after '=', or whitespace only.
            strval = char(strtrim(strval));
            if isempty(strval)
                val = [];
                return;
            end
            val = str2double(strval);
            if ~isscalar(val) || ~isfinite(val)
                error('INI key %s must be empty or a numeric scalar.', keyname);
            end
        end

        function chs = parseChannelList(strval)
            % Parse comma-separated channel labels into a cellstr,
            % trimming spaces and deduplicating while preserving order (case-sensitive).
            if isstring(strval); strval = char(strval); end
            chs = {};
            if isempty(strtrim(strval))
                return;
            end
            parts = regexp(strval, ',', 'split');
            for i = 1:numel(parts)
                lab = strtrim(parts{i});
                if isempty(lab), continue; end
                if ~any(strcmp(chs, lab)) % dedupe, preserve case & order
                    chs{end+1} = lab; %#ok<AGROW>
                end
            end
        end

        function tf = isIndexInteger(abs_start_ms, fs)
            % Test whether abs_start_ms * fs / 1000 is (near) an integer index.
            idx = abs_start_ms * fs / 1000;
            tf = abs(idx - round(idx)) < 1e-9;
        end

    end % methods (Static, Access = private)

end