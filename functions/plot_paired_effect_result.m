function handles = plot_paired_effect_result(ax, true_values, reference_values, effect_result, true_label, reference_label, effect_specification, alpha)
%PLOT_PAIRED_EFFECT_RESULT Plot paired values and one paired-difference estimate.
%   This helper performs no estimation, bootstrap, or random-number operation.

if ~isgraphics(ax, 'axes')
    error('plot_paired_effect_result:InvalidAxes', 'The first input must be a valid axes handle.');
end
validateattributes(true_values, {'single','double'}, {'real','vector','nonempty','finite'}, mfilename, 'true_values');
validateattributes(reference_values, {'single','double'}, {'real','vector','nonempty','finite'}, mfilename, 'reference_values');

true_values = true_values(:);
reference_values = reference_values(:);
if numel(true_values) ~= numel(reference_values)
    error('plot_paired_effect_result:PairCountMismatch', ...
        'true_values and reference_values must contain the same number of paired observations.');
end

if ~istable(effect_result) || height(effect_result) ~= 1 || ...
        ~all(ismember({'Estimate','ConfidenceIntervals'}, effect_result.Properties.VariableNames))
    error('plot_paired_effect_result:InvalidEffectResult', ...
        'effect_result must be a one-row table containing Estimate and ConfidenceIntervals.');
end

estimate = effect_result.Estimate(1);
ci = effect_result.ConfidenceIntervals(1, :);
if ~isnumeric(effect_result.Estimate) || ~isreal(effect_result.Estimate) || ...
        ~isnumeric(effect_result.ConfidenceIntervals) || ...
        ~isreal(effect_result.ConfidenceIntervals) || ...
        ~isscalar(estimate) || ~isfinite(estimate) || numel(ci) ~= 2 || ...
        any(~isfinite(ci)) || ci(2) < ci(1)
    error('plot_paired_effect_result:InvalidEffectValues', ...
        'The effect estimate and ordered two-sided confidence interval must be finite.');
end

true_label = string(true_label);
reference_label = string(reference_label);
required_specification = {'effect','estimand','direction','axis_label', ...
    'contrast_tick_label','positive_value_interpretation','scale'};
if ~isstruct(effect_specification) || ~isscalar(effect_specification) || ...
        ~all(isfield(effect_specification, required_specification))
    error('plot_paired_effect_result:InvalidEffectSpecification', ...
        'effect_specification is missing one or more required fields.');
end
effect_description = string(effect_specification.estimand);
effect_direction = string(effect_specification.direction);
effect_axis_label = string(effect_specification.axis_label);
contrast_tick_label = string(effect_specification.contrast_tick_label);
if ~isscalar(true_label) || ismissing(true_label) || strlength(strtrim(true_label)) == 0 || ...
        ~isscalar(reference_label) || ismissing(reference_label) || strlength(strtrim(reference_label)) == 0 || ...
        ~isscalar(effect_description) || ismissing(effect_description) || strlength(strtrim(effect_description)) == 0 || ...
        ~isscalar(effect_direction) || ismissing(effect_direction) || strlength(strtrim(effect_direction)) == 0 || ...
        ~isscalar(effect_axis_label) || ismissing(effect_axis_label) || strlength(strtrim(effect_axis_label)) == 0 || ...
        ~isscalar(contrast_tick_label) || ismissing(contrast_tick_label) || strlength(strtrim(contrast_tick_label)) == 0
    error('plot_paired_effect_result:InvalidLabels', 'All display labels must be nonblank string scalars.');
end
validateattributes(alpha, {'single','double'}, {'real','scalar','>',0,'<',1}, mfilename, 'alpha');
confidence_percent = 100 * (1 - alpha);

cla(ax, 'reset');
yyaxis(ax, 'left');
hold(ax, 'on');

n_pairs = numel(true_values);
paired_x = repmat([1; 2; NaN], n_pairs, 1);
paired_y = reshape([true_values, reference_values, NaN(n_pairs, 1)].', [], 1);
handles.pairs = plot(ax, paired_x, paired_y, '-', ...
    'Color', [0.70 0.70 0.70], 'LineWidth', 0.75, ...
    'Tag', 'paired-separation-lines', 'HandleVisibility', 'off');
handles.true = scatter(ax, ones(n_pairs, 1), true_values, 22, 'filled', ...
    'DisplayName', char(true_label), 'Tag', 'paired-separation-true');
handles.reference = scatter(ax, 2 * ones(n_pairs, 1), reference_values, 22, 'filled', ...
    'DisplayName', char(reference_label), 'Tag', 'paired-separation-reference');
ylabel(ax, 'Observed value');

yyaxis(ax, 'right');
hold(ax, 'on');
handles.zero = yline(ax, 0, ':', 'Color', [0.55 0.55 0.55], ...
    'Tag', 'paired-separation-zero', 'HandleVisibility', 'off');
handles.interval = plot(ax, [3 3], ci, '-', ...
    'LineWidth', 1.25, 'Color', [0 0.4470 0.7410], ...
    'Tag', 'paired-separation-interval', 'HandleVisibility', 'off');
handles.interval_caps = plot(ax, ...
    [2.94 3.06 NaN 2.94 3.06], [ci(1) ci(1) NaN ci(2) ci(2)], '-', ...
    'LineWidth', 1.25, 'Color', [0 0.4470 0.7410], ...
    'Tag', 'paired-separation-interval-caps', 'HandleVisibility', 'off');
handles.effect = scatter(ax, 3, estimate, 45, 's', 'filled', ...
    'DisplayName', sprintf('%s with %g%% BCa CI', effect_description, confidence_percent), ...
    'Tag', 'paired-separation-effect');
handles.effect.UserData = struct('effect_result', effect_result, ...
    'effect_specification', effect_specification, ...
    'direction', char(effect_direction));
ylabel(ax, effect_axis_label);

xticks(ax, [1 2 3]);
xticklabels(ax, [true_label, reference_label, contrast_tick_label]);
ax.TickLabelInterpreter = 'none';
xlim(ax, [0.5 3.35]);
title(ax, 'Paired separation check: true - internal reference');
grid(ax, 'on');
box(ax, 'on');
handles.axes = ax;
end
