function passed = run_saved_reference_tests()
%RUN_SAVED_REFERENCE_TESTS Check that saved-reference bounds stay selective.

passed = 0;
base = struct('data', single([0 4.5]), 'srate', 500, ...
    'times', [0 2], 'epoch', struct('latency', 1), 'etc', struct('label', 'fixture'));
changed = base;
changed.data(1) = single(9.63e-17);
passed = passed + check(changed, base, 'preproc', '', true);
changed.data(1) = single(2e-15);
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.srate = base.srate + eps(base.srate);
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.times(1) = 1e-16;
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.etc.label = 'different';
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.epoch.latency = single(1);
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.data = double(base.data);
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.data = base.data';
passed = passed + check(changed, base, 'preproc', '', false);
changed = base;
changed.newField = [];
passed = passed + check(changed, base, 'preproc', '', false);

fit = struct('pearsonR', 0.4, 'cosineSimilarity', 0.2, 'olsCoef', 5, ...
    'fglsCoef', 9.824518191205222, 'fglsVarCoef', 113.64147222584852, ...
    'shift_all', 0, 'shifted_data_all', [0 1], 'NRF_resampled', [0 0.2]);
response = struct('data', single([0 1]), 'epoch', struct('template', fit));
changed = response;
changed.epoch.template.fglsCoef = fit.fglsCoef - 1.4697921102424516e-8;
changed.epoch.template.fglsVarCoef = fit.fglsVarCoef + 9.366640085772815e-8;
changed.epoch.template.pearsonR = fit.pearsonR + 1e-15;
passed = passed + check(changed, response, 'response', 'template', true);
changed.epoch.template.fglsCoef = fit.fglsCoef + 1e-6;
passed = passed + check(changed, response, 'response', 'template', false);
changed = response;
changed.epoch.template.shift_all = 1e-16;
passed = passed + check(changed, response, 'response', 'template', false);
changed = response;
changed.epoch.template.shifted_data_all(1) = 1e-16;
passed = passed + check(changed, response, 'response', 'template', false);
changed = response;
changed.epoch.template.NRF_resampled(1) = 1e-16;
passed = passed + check(changed, response, 'response', 'template', false);
changed = response;
changed.data(1) = single(1e-16);
passed = passed + check(changed, response, 'response', 'template', false);
changed = response;
changed.epoch.template.pearsonR = fit.pearsonR + 1e-15;
passed = passed + check(changed, response, 'response', 'other_template', false);
metadata = struct('etc', struct('fglsCoef', 10));
changed = metadata;
changed.etc.fglsCoef = 10 + 1e-10;
passed = passed + check(changed, metadata, 'response', 'template', false);

qc = struct('epoch', struct('qc', struct('Channels', {{'Cz'}}, ...
    'AutoCorrLag1Pos', 4.3322240795748392, 'AutoCorrLag1Neg', 0.00037239584454273889, ...
    'RobustSlopeNorm', 0.0001, 'maxAbsEpoch', 5)));
changed = qc;
changed.epoch.qc.AutoCorrLag1Pos = qc.epoch.qc.AutoCorrLag1Pos + 1.13e-12;
changed.epoch.qc.AutoCorrLag1Neg = qc.epoch.qc.AutoCorrLag1Neg + 1.34e-15;
passed = passed + check(changed, qc, 'qc', '', true);
changed.epoch.qc.AutoCorrLag1Pos = qc.epoch.qc.AutoCorrLag1Pos + 1e-10;
passed = passed + check(changed, qc, 'qc', '', false);
changed = qc;
changed.epoch.qc.maxAbsEpoch = 5 + 1e-14;
passed = passed + check(changed, qc, 'qc', '', false);
changed = qc;
changed.epoch.qc.Channels = {'CZ'};
passed = passed + check(changed, qc, 'qc', '', false);

special = [NaN Inf -Inf 0 1];
passed = passed + check(special, special, 'response_value', 'fglsCoef', true);
passed = passed + check([NaN -Inf -Inf 0 1], special, 'response_value', 'fglsCoef', false);
passed = passed + check([0 Inf -Inf NaN 1], special, 'response_value', 'fglsCoef', false);
passed = passed + check([NaN Inf -Inf Inf 1], special, 'response_value', 'fglsCoef', false);
passed = passed + check(complex(1, 1e-16), 1, 'response_value', 'pearsonR', false);
passed = passed + check(int32(1), 1, 'response_value', 'fglsCoef', false);
passed = passed + check(1e-16, 0, 'response_value', 'shift_all', false);
passed = passed + check(1 + 1e-10, 1, 'response_value', 'fglsCoef', true);
passed = passed + check(1 + 1e-10, 1, 'response_value', 'olsCoef', false);
passed = passed + check(1e-15, 0, 'qc_value', 'calc_RobustSlopeNorm', true);
passed = passed + check(1e-15, 0, 'qc_value', 'calc_maxAbsEpoch', false);
passed = passed + check({single(1)}, {double(1)}, 'preproc', '', false);
passed = passed + check(1 + 1e-11, 1, 'qc_value', 'calc_AutoCorrLag1Pos', false);
fprintf('SAVED REFERENCE COMPARATOR TESTS PASSED: %d\n', passed);
end

function passed = check(actual, expected, scope, selector, expectedMatch)
observed = saved_reference_matches(actual, expected, scope, selector);
assert(isequal(observed, expectedMatch), ...
    'Saved-reference comparison returned %d instead of %d for %s/%s.', ...
    observed, expectedMatch, scope, selector);
passed = 1;
end
