function matches = saved_reference_matches(actual, expected, scope, selector)
%SAVED_REFERENCE_MATCHES Compare saved synthetic outputs across platforms.
% Only the named calculated fields below allow floating-point differences.
% Types, shapes, other fields, NaN positions, and signed infinities stay exact.
% These bounds apply to saved references, not same-runner equivalence checks.
%
% Hosted R2026a Update 4 checks found preprocessing differences <=9.63e-17,
% ordinary calculated differences <=1.13e-12 (at magnitude 4.33), and scalar
% iterative FGLS relative differences <=1.50e-9. The bounds below provide a
% small margin without changing the scientific calculations or fixtures.

if nargin < 4
    selector = '';
end
assert(ismember(scope, {'preproc', 'response', 'qc', ...
    'response_value', 'qc_value'}), 'Unknown saved-reference comparison scope.');
matches = compare_node(actual, expected, scope, selector, {});
end

function matches = compare_node(actual, expected, scope, selector, fields)
matches = false;
if ~strcmp(class(actual), class(expected)) || ~isequal(size(actual), size(expected))
    return;
end
if isstruct(actual)
    names = fieldnames(actual);
    if ~isequal(sort(names), sort(fieldnames(expected)))
        return;
    end
    for element = 1:numel(actual)
        for index = 1:numel(names)
            name = names{index};
            if ~compare_node(actual(element).(name), expected(element).(name), ...
                    scope, selector, [fields {name}])
                return;
            end
        end
    end
    matches = true;
elseif iscell(actual)
    for index = 1:numel(actual)
        if ~compare_node(actual{index}, expected{index}, scope, selector, ...
                [fields {'cell'}])
            return;
        end
    end
    matches = true;
elseif isnumeric(actual)
    if isreal(actual) ~= isreal(expected) || issparse(actual) ~= issparse(expected)
        return;
    end
    if isequaln(actual, expected)
        matches = true;
        return;
    end
    [absoluteTolerance, relativeTolerance] = field_tolerance(scope, selector, fields);
    if ~isfloat(actual) || ~isreal(actual) || ...
            (absoluteTolerance == 0 && relativeTolerance == 0)
        return;
    end
    if ~isequal(isnan(actual), isnan(expected)) || ...
            ~isequal(isinf(actual), isinf(expected)) || ...
            ~isequal(actual(isinf(actual)), expected(isinf(expected)))
        return;
    end
    finite = isfinite(expected);
    a = double(actual(finite));
    b = double(expected(finite));
    matches = all(abs(a - b) <= absoluteTolerance + relativeTolerance .* abs(b));
else
    matches = isequaln(actual, expected);
end
end

function [absoluteTolerance, relativeTolerance] = field_tolerance(scope, selector, fields)
absoluteTolerance = 0;
relativeTolerance = 0;
name = '';
if strcmp(scope, 'preproc') && isequal(fields, {'data'})
    absoluteTolerance = 1e-15;
    return;
elseif strcmp(scope, 'response') && numel(fields) == 3 && ...
        strcmp(fields{1}, 'epoch') && strcmp(fields{2}, selector)
    name = fields{3};
elseif strcmp(scope, 'qc') && numel(fields) == 3 && ...
        strcmp(fields{1}, 'epoch') && strcmp(fields{2}, 'qc')
    name = fields{3};
elseif strcmp(scope, 'response_value') && isempty(fields)
    name = selector;
elseif strcmp(scope, 'qc_value') && isempty(fields) && ...
        ismember(selector, {'calc_RobustSlopeNorm', ...
        'calc_AutoCorrLag1Pos', 'calc_AutoCorrLag1Neg'})
    name = selector(6:end);
end
if ismember(scope, {'response', 'response_value'})
    if ismember(name, {'fglsCoef', 'fglsVarCoef'})
        absoluteTolerance = 1e-12;
        relativeTolerance = 5e-9;
    elseif ismember(name, {'pearsonR', 'cosineSimilarity', 'olsCoef'})
        absoluteTolerance = 1e-14;
        relativeTolerance = 1e-12;
    end
elseif ismember(scope, {'qc', 'qc_value'}) && ...
        ismember(name, {'RobustSlopeNorm', 'AutoCorrLag1Pos', 'AutoCorrLag1Neg'})
    absoluteTolerance = 1e-14;
    relativeTolerance = 1e-12;
end
end
