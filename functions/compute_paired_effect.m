function [effect_result, rng_specification, effect_specification] = compute_paired_effect(true_values, reference_values, effect_name, alpha, n_bootstraps, rng_seed, rng_algorithm)
%COMPUTE_PAIRED_EFFECT Estimate one statistic of paired true-reference differences.

validateattributes(true_values, {'single','double'}, {'real','vector','nonempty','finite'}, mfilename, 'true_values');
validateattributes(reference_values, {'single','double'}, {'real','vector','nonempty','finite'}, mfilename, 'reference_values');
if numel(true_values) ~= numel(reference_values)
    error('compute_paired_effect:PairCountMismatch', ...
        'true_values and reference_values must contain the same number of paired observations.');
end
if numel(true_values) < 2
    error('compute_paired_effect:InsufficientPairs', ...
        'At least two complete pairs are required for a BCa bootstrap interval.');
end
validateattributes(alpha, {'single','double'}, {'real','scalar','>',0,'<',1}, mfilename, 'alpha');
validateattributes(n_bootstraps, {'numeric'}, {'real','scalar','integer','positive','finite'}, mfilename, 'n_bootstraps');
validateattributes(rng_seed, {'numeric'}, {'real','scalar','integer','nonnegative','finite'}, mfilename, 'rng_seed');

effect_specification = describe_effect(effect_name);
effect_name = effect_specification.effect;

true_values = double(true_values(:));
reference_values = double(reference_values(:));
pair_differences = true_values - reference_values;
switch effect_name
    case 'pairedmediandiff'
        statistic_function = @median;
    case 'pairedmeandiff'
        statistic_function = @mean;
    otherwise
        error('compute_paired_effect:InternalEffect', ...
            'The validated paired-difference effect has no implementation.');
end

rng_algorithm = string(rng_algorithm);
if ~isscalar(rng_algorithm) || ismissing(rng_algorithm) || ...
        strlength(strtrim(rng_algorithm)) == 0
    error('compute_paired_effect:InvalidRNGAlgorithm', ...
        'rng_algorithm must be a nonblank string scalar.');
end
rng_algorithm = char(strtrim(rng_algorithm));

previous_rng = rng;
rng_cleanup = onCleanup(@() rng(previous_rng));
rng(rng_seed, rng_algorithm);
generating_rng = rng;

estimate = statistic_function(pair_differences);
bootstrap_options = statset('bootstrp');
bootstrap_options.UseParallel = false;
bootstrap_options.UseSubstreams = false;
confidence_interval = bootci(n_bootstraps, ...
    {statistic_function, pair_differences}, ...
    'Type', 'bca', 'Alpha', alpha, 'Options', bootstrap_options);
confidence_interval = reshape(double(confidence_interval), 1, []);
effect_result = table(double(estimate), confidence_interval, ...
    'VariableNames', {'Estimate','ConfidenceIntervals'}, ...
    'RowNames', {effect_specification.table_row_name});

if ~istable(effect_result) || height(effect_result) ~= 1 || ...
        ~all(ismember({'Estimate','ConfidenceIntervals'}, effect_result.Properties.VariableNames)) || ...
        ~isnumeric(effect_result.Estimate) || ~isreal(effect_result.Estimate) || ...
        ~isscalar(effect_result.Estimate) || ~isfinite(effect_result.Estimate) || ...
        ~isnumeric(effect_result.ConfidenceIntervals) || ...
        ~isreal(effect_result.ConfidenceIntervals) || ...
        numel(effect_result.ConfidenceIntervals) ~= 2 || ...
        any(~isfinite(effect_result.ConfidenceIntervals(:))) || ...
        effect_result.ConfidenceIntervals(2) < effect_result.ConfidenceIntervals(1)
    error('compute_paired_effect:InvalidEstimatorResult', ...
        'The paired-difference estimator did not return one finite estimate with an ordered finite two-sided interval.');
end

rng_specification = struct( ...
    'seed', double(rng_seed), ...
    'generator', rng_algorithm, ...
    'generating_state', generating_rng.State, ...
    'bootstrap_resamples', double(n_bootstraps), ...
    'bootstrap_interval', 'bias-corrected and accelerated (BCa)', ...
    'bootstrap_function', 'MATLAB bootci', ...
    'resampling_unit', 'complete pair represented by one true-minus-reference difference score', ...
    'difference_definition', 'true_values - reference_values in matched input order', ...
    'statistic', effect_specification.statistic);
end

function specification = describe_effect(effect_name)
effect_name = string(effect_name);
if ~isscalar(effect_name) || ismissing(effect_name) || ...
        strlength(strtrim(effect_name)) == 0
    error('compute_paired_effect:InvalidEffect', ...
        'effect_name must be a nonblank string scalar.');
end
effect_name = lower(strtrim(effect_name));

specification = struct();
specification.effect = char(effect_name);

switch effect_name
    case "pairedmediandiff"
        specification.estimand = 'Median of within-pair differences';
        specification.statistic = 'median';
        specification.table_row_name = 'PairedMedianDifference';
        specification.direction = ...
            'true event minus internal reference within each complete pair';
        specification.axis_label = ...
            'Median paired difference (true - reference)';
        specification.contrast_tick_label = 'Median paired difference';
        specification.positive_value_interpretation = ...
            'Positive values indicate a positive median within-pair true-minus-reference difference.';
        specification.scale = 'original metric units';
    case "pairedmeandiff"
        specification.estimand = 'Mean of within-pair differences';
        specification.statistic = 'mean';
        specification.table_row_name = 'PairedMeanDifference';
        specification.direction = ...
            'true event minus internal reference within each complete pair';
        specification.axis_label = ...
            'Mean paired difference (true - reference)';
        specification.contrast_tick_label = 'Mean paired difference';
        specification.positive_value_interpretation = ...
            'Positive values indicate a positive mean within-pair true-minus-reference difference.';
        specification.scale = 'original metric units';
    otherwise
        error('compute_paired_effect:UnsupportedEffect', ...
            ['Unsupported paired separation effect ''%s''. Supported effects are ', ...
             'pairedmediandiff and pairedmeandiff.'], char(effect_name));
end
end
