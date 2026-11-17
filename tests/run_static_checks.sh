#!/usr/bin/env bash
# Finite static/Git checks for the simple-strasbourg repository baseline.
# The candidate is built from tracked-current files and untracked source files
# under the documented top-level contract. Project data and external artefacts
# are neither listed nor copied.

set -u
umask 077

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
git_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null) || {
    printf 'Not inside a Git repository: %s\n' "$repo_root" >&2
    exit 2
}
if [ "$git_root" != "$repo_root" ]; then
    printf 'Repository-root mismatch: expected %s, got %s\n' "$repo_root" "$git_root" >&2
    exit 2
fi

if [ "${1-}" = "--result-dir" ]; then
    if [ "$#" -ne 2 ]; then
        printf 'Usage: %s [--result-dir OUTSIDE_REPOSITORY]\n' "$0" >&2
        exit 2
    fi
    result_root=$(python3 - "$2" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
    ) || exit 2
    case "$result_root/" in
        "$repo_root/"*)
            printf 'Result directory must be outside the repository: %s\n' "$result_root" >&2
            exit 2
            ;;
    esac
    if [ -e "$result_root" ] && [ ! -d "$result_root" ]; then
        printf 'Result path exists and is not a directory: %s\n' "$result_root" >&2
        exit 2
    fi
    if [ -d "$result_root" ] &&
        [ -n "$(find "$result_root" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        printf 'Result directory must be empty: %s\n' "$result_root" >&2
        exit 2
    fi
    mkdir -p -- "$result_root" || exit 2
    result_root=$(CDPATH='' cd -- "$result_root" && pwd -P)
elif [ "$#" -eq 0 ]; then
    result_root=$(mktemp -d "${TMPDIR:-/tmp}/simple-strasbourg-static.XXXXXX") || exit 2
else
    printf 'Usage: %s [--result-dir OUTSIDE_REPOSITORY]\n' "$0" >&2
    exit 2
fi

case "$result_root/" in
    "$repo_root/"*)
        printf 'Result directory must be outside the repository: %s\n' "$result_root" >&2
        exit 2
        ;;
esac

work_root="$result_root/.work"
candidate="$work_root/candidate"
fresh_clone="$work_root/fresh-clone"
checks_tsv="$result_root/checks.tsv"
source_before="$work_root/source-before.tsv"
source_after="$work_root/source-after.tsv"
snapshot_errors="$work_root/snapshot-errors.txt"
mkdir -p -- "$candidate"
printf 'check_id\tstatus\tdetail\n' > "$checks_tsv"
: > "$snapshot_errors"

pass_count=0
fail_count=0

normalise_detail() {
    tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

record_pass() {
    check_id=$1
    detail=$2
    printf '%s\tPASS\t%s\n' "$check_id" "$detail" >> "$checks_tsv"
    pass_count=$((pass_count + 1))
    printf 'PASS  %s: %s\n' "$check_id" "$detail"
}

record_fail() {
    check_id=$1
    detail=$2
    printf '%s\tFAIL\t%s\n' "$check_id" "$detail" >> "$checks_tsv"
    fail_count=$((fail_count + 1))
    printf 'FAIL  %s: %s\n' "$check_id" "$detail"
}

run_check() {
    check_id=$1
    check_function=$2
    output_file="$work_root/${check_id//\//_}.out"
    if "$check_function" > "$output_file" 2>&1; then
        detail=$(normalise_detail < "$output_file")
        [ -n "$detail" ] || detail='completed'
        record_pass "$check_id" "$detail"
    else
        detail=$(normalise_detail < "$output_file")
        [ -n "$detail" ] || detail='failed without diagnostic output'
        record_fail "$check_id" "$detail"
    fi
}

validate_relative_path() {
    relative_path=$1
    case "$relative_path" in
        ''|/*|..|../*|*/../*)
            printf 'Unsafe Git path rejected: %s\n' "$relative_path" >> "$snapshot_errors"
            return 1
            ;;
    esac
    return 0
}

append_inventory_group() {
    inventory_output=$1
    shift
    "$@" | while IFS= read -r -d '' relative_path; do
        validate_relative_path "$relative_path" || continue
        source_path="$repo_root/$relative_path"
        if [ -L "$source_path" ]; then
            link_target=$(readlink "$source_path")
            digest=$(printf 'symlink:%s' "$link_target" | shasum -a 256 | awk '{print $1}')
            executable='symlink'
        elif [ -f "$source_path" ]; then
            digest=$(shasum -a 256 "$source_path" | awk '{print $1}')
            if [ -x "$source_path" ]; then executable='x'; else executable='-'; fi
        elif [ -e "$source_path" ]; then
            printf 'Unsupported non-file Git entry: %s\n' "$relative_path" >> "$snapshot_errors"
            continue
        else
            # A missing tracked path is an intentional working-tree deletion.
            continue
        fi
        printf '%s\t%s\t%s\n' "$digest" "$executable" "$relative_path" >> "$inventory_output.unsorted"
    done
}

list_candidate_untracked() {
    git -C "$repo_root" ls-files --others --exclude-standard -z | \
        while IFS= read -r -d '' relative_path; do
            case "$relative_path" in
                .gitignore|LICENSE|README.md|NRFs/*|data/.gitkeep|data_lists/.gitkeep|functions/*|scripts/*|tests/*)
                    printf '%s\0' "$relative_path"
                    ;;
            esac
        done
}

write_source_inventory() {
    inventory_output=$1
    : > "$inventory_output.unsorted"
    append_inventory_group "$inventory_output" git -C "$repo_root" ls-files -z
    append_inventory_group "$inventory_output" list_candidate_untracked
    LC_ALL=C sort -u "$inventory_output.unsorted" > "$inventory_output"
    rm -f -- "$inventory_output.unsorted"
}

copy_group_to_candidate() {
    "$@" | while IFS= read -r -d '' relative_path; do
        validate_relative_path "$relative_path" || continue
        source_path="$repo_root/$relative_path"
        destination_path="$candidate/$relative_path"
        if [ -L "$source_path" ]; then
            mkdir -p -- "$(dirname -- "$destination_path")"
            ln -s -- "$(readlink "$source_path")" "$destination_path"
        elif [ -f "$source_path" ]; then
            mkdir -p -- "$(dirname -- "$destination_path")"
            cp -p -- "$source_path" "$destination_path"
        elif [ -e "$source_path" ]; then
            printf 'Unsupported non-file Git entry: %s\n' "$relative_path" >> "$snapshot_errors"
        fi
    done
}

write_source_inventory "$source_before"
copy_group_to_candidate git -C "$repo_root" ls-files -z
copy_group_to_candidate list_candidate_untracked
write_source_inventory "$source_after"

if [ -s "$snapshot_errors" ]; then
    record_fail '_setup.snapshot' "$(normalise_detail < "$snapshot_errors")"
elif ! cmp -s "$source_before" "$source_after"; then
    diff -u "$source_before" "$source_after" > "$work_root/snapshot-drift.diff" || true
    record_fail '_setup.snapshot' 'source changed while the tracked-current candidate was materialised'
else
    record_pass '_setup.snapshot' 'tracked-current and documented untracked source were stable'
fi

if [ "$fail_count" -ne 0 ]; then
    printf 'Snapshot setup failed; no closure result is valid. Results: %s\n' "$result_root" >&2
    exit 1
fi

git -C "$candidate" init -q -b main
git -C "$candidate" config user.name 'SIMPLE static verifier'
git -C "$candidate" config user.email 'static-verifier@invalid.example'
git -C "$candidate" add -A
source_diff_check='PASS'
: > "$work_root/source-diff-check.txt"
if ! git -C "$repo_root" diff --check >> "$work_root/source-diff-check.txt" 2>&1; then
    source_diff_check='FAIL'
fi
list_candidate_untracked | \
    while IFS= read -r -d '' relative_path; do
        validate_relative_path "$relative_path" || continue
        source_path="$repo_root/$relative_path"
        [ -f "$source_path" ] || continue
        untracked_check="$work_root/untracked-diff-check.txt"
        : > "$untracked_check"
        git diff --no-index --check /dev/null "$source_path" \
            > "$untracked_check" 2>&1 || true
        if [ -s "$untracked_check" ]; then
            printf '%s:\n' "$relative_path" >> "$work_root/source-diff-check.txt"
            cat "$untracked_check" >> "$work_root/source-diff-check.txt"
            printf 'FAIL\n' > "$work_root/source-diff-check.failed"
        fi
    done
if [ -f "$work_root/source-diff-check.failed" ]; then
    source_diff_check='FAIL'
fi
git -C "$candidate" commit -q -m 'Ephemeral closure candidate'
candidate_commit=$(git -C "$candidate" rev-parse HEAD)

git -C "$candidate" ls-files | while IFS= read -r relative_path; do
    file_path="$candidate/$relative_path"
    if [ -L "$file_path" ]; then
        digest=$(printf 'symlink:%s' "$(readlink "$file_path")" | shasum -a 256 | awk '{print $1}')
    else
        digest=$(shasum -a 256 "$file_path" | awk '{print $1}')
    fi
    printf '%s  %s\n' "$digest" "$relative_path"
done > "$result_root/candidate_inventory.sha256"
candidate_inventory_digest=$(shasum -a 256 "$result_root/candidate_inventory.sha256" | awk '{print $1}')
git -C "$repo_root" status --short --untracked-files=all > "$result_root/source_status.txt"

check_manifest() {
    python3 - "$candidate" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = root / "tests" / "coverage_manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

def require(condition, message):
    if not condition:
        raise AssertionError(message)

require(manifest.get("schema") == "simple-repository-coverage-v1", "bad manifest schema")
require(manifest.get("repository") == "simple-strasbourg", "bad repository identity")
require(manifest.get("baseline") == 1, "bad baseline identity")
require(manifest.get("comparison_policy") == {
    "exact_behaviour": "strict isequaln",
    "absolute_tolerance": 0,
    "relative_tolerance": 0,
}, "comparison policy differs from the exact scientific contract")

catalog = manifest.get("test_catalog")
coverage = manifest.get("coverage")
require(isinstance(catalog, list) and len(catalog) == 46, "test catalog count differs")
require(isinstance(coverage, list) and len(coverage) == 76, "coverage row count differs")
catalog_ids = [item.get("id") for item in catalog]
require(all(isinstance(x, str) and x for x in catalog_ids), "blank catalog id")
require(len(catalog_ids) == len(set(catalog_ids)), "duplicate catalog id")
catalog_by_id = {item["id"]: item for item in catalog}

expected_keys = set(["baseline_routes","cleanline_routes","closure_clone","closure_config","closure_current_surface","closure_function_inventory","closure_generated","closure_git","closure_ignore_hyp","closure_ignore_real","closure_logs","closure_manifest","closure_paths","closure_readme","closure_root","closure_step54","closure_step72","closure_step73","closure_step81","closure_strasbourg","closure_templates","closure_viewer_qc_example","config_profiles_cache","dataset_registry_paths","delete_contracts","dependency_missing","dependency_present","effective_preprocessing_provenance","epoch_failures","epoch_modes","filter_modes","jitter_edges","jitter_shapes_shifts","jitter_ties_padding","line_frequency_edges","line_off_notch","nrf_clear_persistence","nrf_template_preflight","numeric_results","offset_consistency","offset_mapping_fields","offset_no_event","offset_no_source","offset_oob","offset_report_keys","offset_validation","prep_defaults","prep_empty_array","prep_empty_data","prep_inputs","prep_multi_array","preproc_order_history","preprocessing_caller_contract","qc_coord_schema","qc_direct_matrix","qc_overwrite_array_times","registry_write_preflight","reref_modes","resample_modes","resolver_failures_shadow","resolver_local_explicit","response_channel","response_every_epoch_array","response_inputs_defaults","response_insufficient","response_public_contract","response_rate_grid_bounds","response_scalar_options","response_schema_history","response_xor","step2_downstream_identity_propagation","step2_pseudonymisation_transaction","step2_set_sanitisation_transaction","step8_guardrail_figure","templates_three_500hz","warning_restoration"])
actual_keys = [row.get("requirement_key") for row in coverage]
require(len(actual_keys) == len(set(actual_keys)), "duplicate requirement key")
require(set(actual_keys) == expected_keys, "required coverage-key set differs")
coverage_ids = [row.get("id") for row in coverage]
require(all(isinstance(x, str) and re.fullmatch(r"BASE-[A-Z]+-\d{3}", x)
            for x in coverage_ids), "coverage id format differs")
require(len(coverage_ids) == len(set(coverage_ids)), "duplicate coverage id")
require({row.get("category") for row in coverage} ==
        {"preprocessing", "response-estimation", "scientific-core", "repository"},
        "coverage categories differ")
for row in coverage:
    require(set(row) == {"id", "category", "requirement_key", "surface",
                         "requirement", "test_refs"},
            f"coverage row fields differ: {row.get('id')}")

referenced = set()
referenced_cases = {test_id: set() for test_id in catalog_ids}
for row in coverage:
    require(isinstance(row.get("surface"), str) and row["surface"],
            f"blank surface in {row.get('id')}")
    require(isinstance(row.get("requirement"), str) and row["requirement"],
            f"blank requirement in {row.get('id')}")
    refs = row.get("test_refs")
    require(isinstance(refs, list) and refs, f"missing test refs in {row.get('id')}")
    for ref in refs:
        test_id = ref.get("test_id")
        require(test_id in catalog_by_id, f"unknown test id {test_id}")
        referenced.add(test_id)
        requested_cases = ref.get("cases", [])
        known_cases = catalog_by_id[test_id].get("cases", [])
        require(set(requested_cases).issubset(set(known_cases)),
                f"unknown case reference for {test_id}: {set(requested_cases) - set(known_cases)}")
        if "cases" in ref:
            referenced_cases[test_id].update(requested_cases)
        else:
            referenced_cases[test_id].update(known_cases)

require(referenced == set(catalog_ids), "catalog contains an unreferenced test")
for test_id, item in catalog_by_id.items():
    require(referenced_cases[test_id] == set(item.get("cases", [])),
            f"catalog contains an unmapped case: {test_id}")

static_catalog_ids = {
    item["id"] for item in catalog if item.get("kind") == "static-git"
}
static_runner = (root / "tests" / "run_static_checks.sh").read_text(encoding="utf-8")
invoked_static_ids = set(re.findall(r"run_check\s+'([^']+)'", static_runner))
require(invoked_static_ids == static_catalog_ids,
        "static catalog and invoked static-check IDs differ")

for item in catalog:
    for field in ("source", "runner"):
        path = root / item[field]
        require(path.is_file(), f"missing catalog {field}: {item[field]}")
    runner_text = (root / item["runner"]).read_text(encoding="utf-8")
    require(item["runner_anchor"] in runner_text,
            f"runner anchor absent: {item['runner_anchor']}")

def catalog_item(test_id):
    return catalog_by_id[test_id]

require(len(catalog_item("matlab.preproc.oracle")["cases"]) == 30, "preproc oracle count")
require(len(catalog_item("matlab.response.oracle")["cases"]) == 11, "response oracle count")
require(len(catalog_item("matlab.jitter.oracle")["cases"]) == 11, "jitter oracle count")
require(len(catalog_item("matlab.qc.coordinator.oracle")["cases"]) == 9, "QC coordinator count")
direct = catalog_item("matlab.qc.direct.oracle")
require(len(direct["calculators"]) == 11 and len(direct["cases"]) == 25,
        "QC direct matrix shape")
require(len(direct["calculators"]) * len(direct["cases"]) == 275,
        "QC direct matrix count")

for item in catalog:
    if not item.get("kind", "").startswith("matlab-"):
        continue
    require(isinstance(item.get("expected_pass_count"), int) and
            item["expected_pass_count"] > 0,
            f"missing expected pass count: {item['id']}")
    represented = len(item.get("cases", []))
    if item.get("kind") == "matlab-oracle-matrix":
        represented *= len(item.get("calculators", []))
    require(represented == item["expected_pass_count"],
            f"case/pass count differs: {item['id']}")

expected_totals = {"runner_sha256":"27bf9148afd3f83b8c277fa957c49d5379b06c927b4e55fbcefd086679711c39","preproc":30,"response":11,"jitter":11,"qc":284,"clean_contract":18,"registry":23,"step2_identity":18,"step2_sanitisation":12,"step2_downstream_identity":8,"processing_state":9,"step8_check_plot":8,"extended":120}
require(manifest.get("expected_runtime_totals") == expected_totals,
        "runtime totals differ from the repository test contract")
runner_bytes = (root / "tests" / "run_all_tests.m").read_bytes()
require(hashlib.sha256(runner_bytes).hexdigest() == expected_totals["runner_sha256"],
        "runtime runner differs from its coverage-manifest binding")
extended_ids = [
    "matlab.events.extended", "matlab.response.extended",
    "matlab.resolver.extended", "matlab.config_cache.extended",
    "matlab.overlay.extended", "matlab.jitter.extended",
    "matlab.qc.extended", "matlab.diagnostics.extended",
    "matlab.dependencies.extended", "matlab.logger.extended",
    "matlab.preproc.extended",
]
require(sum(catalog_item(test_id)["expected_pass_count"]
            for test_id in extended_ids) == expected_totals["extended"],
        "extended suite total differs")
require(catalog_item("matlab.preproc.oracle")["expected_pass_count"] ==
        expected_totals["preproc"], "preproc total differs")
require(catalog_item("matlab.response.oracle")["expected_pass_count"] ==
        expected_totals["response"], "response total differs")
require(catalog_item("matlab.jitter.oracle")["expected_pass_count"] ==
        expected_totals["jitter"], "jitter total differs")
require(catalog_item("matlab.qc.coordinator.oracle")["expected_pass_count"] +
        catalog_item("matlab.qc.direct.oracle")["expected_pass_count"] ==
        expected_totals["qc"], "QC total differs")
require(catalog_item("matlab.clean_api")["expected_pass_count"] ==
        expected_totals["clean_contract"], "clean-contract total differs")
require(catalog_item("matlab.registry_paths")["expected_pass_count"] ==
        expected_totals["registry"], "registry-path total differs")
require(catalog_item("matlab.processing_state")["expected_pass_count"] ==
        expected_totals["processing_state"], "processing-state total differs")
require(catalog_item("matlab.step2_identity")["expected_pass_count"] ==
        expected_totals["step2_identity"], "Step-2-identity total differs")
require(catalog_item("matlab.step2_sanitisation")["expected_pass_count"] ==
        expected_totals["step2_sanitisation"], "Step-2-sanitisation total differs")
require(catalog_item("matlab.step2_downstream_identity")["expected_pass_count"] ==
        expected_totals["step2_downstream_identity"],
        "Step-2-downstream-identity total differs")
require(catalog_item("matlab.step8_check_plot")["expected_pass_count"] ==
        expected_totals["step8_check_plot"], "Step-8-check-plot total differs")

oracle_path = root / "tests" / "fixtures" / "simple_scientific_oracle_v1.json"
oracle_json = json.loads(oracle_path.read_text(encoding="utf-8"))
require(set(oracle_json) == {"schema", "environment", "comparison", "case_counts",
                             "fixture", "boundaries"},
        "scientific-oracle manifest fields differ")
require(oracle_json["schema"] == "simple-scientific-oracle-manifest-v1",
        "scientific-oracle manifest schema differs")
require(oracle_json["environment"] == {
    "matlab": "26.1.0.3312084 (R2026a) Update 4",
    "matlab_release": "2026a",
    "eeglab": "2026.0.0",
    "host": "macOS 27.2 build 26B123 arm64",
}, "scientific-oracle environment differs")
require(oracle_json["comparison"] == {
    "exact_behaviour": "strict isequaln",
    "absolute_tolerance": 0,
    "relative_tolerance": 0,
    "supplementary_analytic_absolute_floor": 1e-12,
    "supplementary_analytic_relative_tolerance": 1e-10,
}, "scientific-oracle comparison policy differs")
require(oracle_json["case_counts"] == {
    "preprocessing": 30,
    "response": 11,
    "jitter": 11,
    "quality_control_coordinator": 9,
    "quality_control_direct": 275,
    "templates": 3,
}, "scientific-oracle case counts differ")
fixture = oracle_json["fixture"]
require(fixture == {
    "path": "tests/fixtures/simple_scientific_oracle_v1.mat",
    "bytes": 3166162,
    "sha256": "fc99ea8862378f6b70113a9f871ecbe375f007319ea90f5772d447e2d1e4fb82",
}, "scientific-oracle fixture binding differs")
fixture_path = root / fixture["path"]
require(fixture_path.is_file(), "scientific-oracle fixture is missing")
require(fixture_path.stat().st_size == fixture["bytes"],
        "scientific-oracle fixture size differs")
require(hashlib.sha256(fixture_path.read_bytes()).hexdigest() == fixture["sha256"],
        "scientific-oracle fixture digest differs")
require(oracle_json["boundaries"] == {
    "synthetic_only": True,
    "workflow_scripts_run": 0,
    "real_eeg_files_read": 0,
    "university_server_accesses": 0,
    "dependency_updates": 0,
}, "scientific-oracle boundaries differ")
print("76 coverage rows; 46 named test groups; exact scientific-oracle cardinalities and binding")
PY
}

check_function_inventory() {
    expected="$work_root/functions.expected"
    actual="$work_root/functions.actual"
    printf '%s\n' \
        NRFUtils.m \
        add_offset_events.m \
        calc_AutoCorrLag1Neg.m \
        calc_AutoCorrLag1Pos.m \
        calc_KatzFDNorm.m \
        calc_MaxAbsDiffNorm.m \
        calc_MeanAbsDiffNorm.m \
        calc_RobustSlopeNorm.m \
        calc_invSdEpoch.m \
        calc_maxAbsBaseline.m \
        calc_maxAbsEpoch.m \
        calc_maxAbsPost.m \
        calc_sdEpoch.m \
        collect_guardrail_event_series.m \
        build_pseudonymised_dataset_registry.m \
        compute_paired_effect.m \
        convert_curry_to_eeg.m \
        convert_xdf_to_eeg.m \
        delete_unwanted_events.m \
        estimate_response.m \
        jittercorrect.m \
        inspect_identity_state.m \
        inspect_pseudonymisation_inputs.m \
        load_dataset_identity_registry.m \
        load_guardrail_separation_result.m \
        plot_paired_effect_result.m \
        plot_guardrail_average_psd.m \
        plot_guardrail_average_tf.m \
        plot_guardrail_average_ts.m \
        preproc.m \
        quality_control_features.m \
        quality_control_features_with_diagnostics.m \
        read_annotations_from_xdf_csv.m \
        read_events_from_curry_cef.m \
        run_pseudonymisation_transaction.m \
        run_sanitisation_transaction.m \
        sanitise_eeglab_dataset.m \
        save_paired_separation_result.m \
        ts_average_NRFshifted.m \
        ts_average_simple.m \
        ts_average_woody.m \
        ts_nrf_overlay.m \
        validate_dataset_registry_paths.m \
        verify_sanitised_eeglab_dataset.m | LC_ALL=C sort > "$expected"
    git -C "$candidate" ls-files functions | sed 's#^functions/##' | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ "$(wc -l < "$actual" | tr -d ' ')" -eq 44 ] || return 1
    printf 'exact 44-function inventory'
}

check_template_inventory() {
    expected="$work_root/templates.expected"
    actual="$work_root/templates.actual"
    printf '%s  %s\n' \
        3cd5eb2385ef9e358c6107ed88912e1f2b9e1d9abf4efa1d38380e115452bf02 early_NRF_500Hz.mat \
        cd9f22b8fa8401ee11fb18d4907dd687732c7bfb0b8f5c790b16dd580e24520f noxious_NRF_500Hz.mat \
        37d9b0b4208e192c4dc881f46e541b150bc279e19c45d6251e7e80b217467721 noxious_preterm_NRF_500Hz.mat \
        | LC_ALL=C sort > "$expected"
    for path in "$candidate"/NRFs/*.mat; do
        printf '%s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$(basename -- "$path")"
    done | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ -f "$candidate/NRFs/nrf_config.ini" ] || return 1
    [ "$(git -C "$candidate" ls-files NRFs | wc -l | tr -d ' ')" -eq 4 ] || {
        printf 'NRFs tracked inventory is not exactly three templates plus nrf_config.ini\n'
        return 1
    }
    printf 'three exact template digests and local INI'
}

check_current_surface() {
    python3 - "$candidate" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required = {
    "functions/preproc.m": ["function EEG = preproc(EEG, options)"],
    "functions/estimate_response.m": [
        "function EEG_singleChannel = estimate_response(EEG, options)",
        "NRFUtils.resolveTemplateFile(",
    ],
    "functions/jittercorrect.m": [
        "function [new_data, shift, NRF_resampled] = jittercorrect(",
    ],
    "functions/quality_control_features.m": [
        "function [EEG] = quality_control_features(EEG)",
    ],
    "functions/validate_dataset_registry_paths.m": [
        "function targets = validate_dataset_registry_paths(T, baseDir, stage)",
        "SIMPLE:DatasetRegistry:CanonicalEscape",
    ],
    "functions/build_pseudonymised_dataset_registry.m": [
        "function mapped = build_pseudonymised_dataset_registry(original)",
    ],
    "functions/inspect_identity_state.m": [
        "function state = inspect_identity_state(repositoryRoot)",
    ],
    "functions/load_dataset_identity_registry.m": [
        "function identity = load_dataset_identity_registry(",
    ],
    "functions/inspect_pseudonymisation_inputs.m": [
        "function snapshot = inspect_pseudonymisation_inputs(",
    ],
    "functions/run_pseudonymisation_transaction.m": [
        "function result = run_pseudonymisation_transaction(",
    ],
    "functions/run_sanitisation_transaction.m": [
        "function result = run_sanitisation_transaction(",
    ],
    "functions/sanitise_eeglab_dataset.m": [
        "function [EEG, report] = sanitise_eeglab_dataset(",
    ],
    "functions/verify_sanitised_eeglab_dataset.m": [
        "function report = verify_sanitised_eeglab_dataset(",
    ],
    "NRFs/nrf_config.ini": ["[term_foot_nox]"],
    "scripts/log_command_window.m": [
        "logsDir = fullfile(projectRoot, 'data', 'logs');",
    ],
    "scripts/step_2_raw_10_pseudonymise_ids.m": [
        "inspect_pseudonymisation_inputs",
        "run_pseudonymisation_transaction",
    ],
    "scripts/step_2_raw_11_sanitise_sets.m": [
        "build_pseudonymised_dataset_registry",
        "inspect_pseudonymisation_inputs",
        "run_sanitisation_transaction",
    ],
    "tests/run_all_tests.m": [
        "function results = run_all_tests(repoRoot, eeglabRoot)",
        "simple_scientific_oracle_v1.mat",
        "results.registry = run_dataset_registry_path_tests(repoRoot);",
        "results.step2_identity = run_step2_identity_tests(repoRoot);",
        "results.step2_sanitisation = run_step2_sanitisation_tests(repoRoot);",
        "run_step2_downstream_identity_tests(repoRoot);",
        "results.processing_state = run_processing_state_tests(repoRoot);",
        "results.step8_check_plot = run_step8_check_plot_tests(repoRoot);",
    ],
    "tests/run_step8_check_plot_tests.m": [
        "function result = run_step8_check_plot_tests(repoRoot)",
    ],
    "tests/run_step2_identity_tests.m": [
        "function result = run_step2_identity_tests(repoRoot)",
    ],
    "tests/run_step2_sanitisation_tests.m": [
        "function result = run_step2_sanitisation_tests(repoRoot)",
    ],
    "tests/run_step2_downstream_identity_tests.m": [
        "function result = run_step2_downstream_identity_tests(repoRoot)",
    ],
    "scripts/step_8_gen_1_check_plots.m": [
        "figure_3b_post_screening_descriptive_checks_noci_prem.pdf",
    ],
}
for relative, anchors in required.items():
    path = root / relative
    if not path.is_file():
        raise AssertionError(f"missing current repository path: {relative}")
    text = path.read_text(encoding="utf-8")
    missing = [anchor for anchor in anchors if anchor not in text]
    if missing:
        raise AssertionError(f"{relative}: missing current anchors {missing}")
print("repository entrypoints, NRF configuration, logger and test runner resolve to the current local surface")
PY
}

check_hypothetical_ignore() {
    ignore_digest=$(shasum -a 256 "$candidate/.gitignore" | awk '{print $1}')
    [ "$ignore_digest" = '2026643a589ace4565bfccaa1cc55b170beff31cdb2a5e327713bd9d89b2b5da' ] || {
        printf '.gitignore digest differs: %s\n' "$ignore_digest"
        return 1
    }
    positive_paths='data/probe.set
data/nested/probe.set
data/logs/probe.log
data_lists/probe.csv
data_lists/probe.xlsx
data_lists/nested/probe.csv
data_lists/nested/probe.xlsx
.DS_Store
functions/.DS_Store'
    negative_paths='data/.gitkeep
data_lists/.gitkeep
NRFs/nrf_config.ini
README.md'
    printf '%s\n' "$positive_paths" | while IFS= read -r path; do
        git -C "$candidate" check-ignore --no-index -q "$path" || {
            printf 'expected ignored: %s\n' "$path" >&2
            exit 1
        }
    done || return 1
    printf '%s\n' "$negative_paths" | while IFS= read -r path; do
        if git -C "$candidate" check-ignore --no-index -q "$path"; then
            printf 'expected visible: %s\n' "$path" >&2
            exit 1
        fi
    done || return 1
    printf 'exact data/data-list/Finder ignore rules and visible repository files'
}

check_real_ignore() {
    mkdir -p -- "$candidate/data/nested" "$candidate/data/logs" \
        "$candidate/data_lists/nested"
    printf 'probe\n' > "$candidate/data/probe.set"
    printf 'probe\n' > "$candidate/data/nested/probe.set"
    printf 'probe\n' > "$candidate/data/logs/probe.log"
    printf 'probe\n' > "$candidate/data_lists/probe.csv"
    printf 'probe\n' > "$candidate/data_lists/probe.xlsx"
    printf 'probe\n' > "$candidate/data_lists/nested/probe.csv"
    printf 'probe\n' > "$candidate/data_lists/nested/probe.xlsx"
    printf 'probe\n' > "$candidate/.DS_Store"
    printf 'probe\n' > "$candidate/functions/.DS_Store"
    for path in \
        data/probe.set data/nested/probe.set data/logs/probe.log \
        data_lists/probe.csv data_lists/probe.xlsx \
        data_lists/nested/probe.csv data_lists/nested/probe.xlsx \
        .DS_Store functions/.DS_Store; do
        git -C "$candidate" check-ignore -q "$path" || {
            printf 'real probe is not ignored: %s\n' "$path"
            return 1
        }
    done
    status=$(git -C "$candidate" status --porcelain --untracked-files=all)
    [ -z "$status" ] || {
        printf 'real ignored probes changed candidate status: %s\n' "$status"
        return 1
    }
    printf 'real isolated probes follow the exact ignore policy and remain status-neutral'
}

check_fresh_clone() {
    git clone -q "$candidate" "$fresh_clone"
    for directory in data data_lists; do
        [ -d "$fresh_clone/$directory" ] || {
            printf 'missing fresh-clone directory: %s\n' "$directory"
            return 1
        }
        entries=$(find "$fresh_clone/$directory" -mindepth 1 -print | sed "s#^$fresh_clone/$directory/##" | LC_ALL=C sort)
        [ "$entries" = '.gitkeep' ] || {
            printf '%s fresh-clone entries differ: %s\n' "$directory" "$entries"
            return 1
        }
        [ ! -s "$fresh_clone/$directory/.gitkeep" ] || {
            printf '%s fresh-clone placeholder is not zero bytes\n' "$directory"
            return 1
        }
    done
    printf 'fresh local clone has placeholder-only data and data_lists'
}

check_logs() {
    logger="$candidate/scripts/log_command_window.m"
    grep -Fq "logsDir = fullfile(projectRoot, 'data', 'logs');" "$logger" || return 1
    grep -Fq "logFile = fullfile(logsDir, [callerBase, '.log']);" "$logger" || return 1
    grep -Fq 'delete(logFile)' "$logger" || return 1
    git -C "$candidate" check-ignore --no-index -q data/logs/probe.log || return 1
    python3 - "$candidate" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
constructors = []
expected_files = {
    "functions/run_pseudonymisation_transaction.m",
    "functions/run_sanitisation_transaction.m",
    "scripts/log_command_window.m",
    "scripts/step_8_gen_1_check_plots.m",
}
for parent in (root / "functions", root / "scripts"):
    for path in parent.glob("*.m"):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"fullfile\([^\n;]*['\"]logs['\"]", text,
                                 re.IGNORECASE):
            expression = match.group(0)
            relative = str(path.relative_to(root))
            constructors.append(f"{relative}:{expression}")
actual_constructor_files = {item.split(":", 1)[0] for item in constructors}
if len(constructors) != 4 or actual_constructor_files != expected_files:
    raise AssertionError(f"log-constructor inventory differs: {constructors}")
PY
    [ "$?" -eq 0 ] || return 1
    printf 'logger, Step 8.1 recovery path and two Step 2 log guards; replacement and ignore anchors present'
}

check_viewer_qc_example() {
    expected="QC_FEATURE_LIST must be a cell array of character vectors (use {''maxAbsEpoch'',''KatzFDNorm'',...})."
    script="$candidate/scripts/step_6_screen_2_viewer_rate_epochs.m"
    count=$(grep -Foc "$expected" "$script")
    [ "$count" -eq 1 ] || {
        printf 'viewer QC assertion example count=%s\n' "$count"
        return 1
    }
    grep -Fq 'QC_BOXPLOT_WHISKER = 6;' "$script" || return 1
    printf 'viewer QC assertion example and whisker-6 setting each match once'
}

check_step3() {
    python3 - "$candidate/scripts/step_3_proc_4_preprocessing.m" <<'PY'
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "eeglab;", "addpath(functionsDir, '-begin')", "delete_unwanted_events(",
    "add_offset_events(", "PreprocOptions.epochevents_true",
    "PreprocOptions.epochevents_dummy", "PreprocOptions.offset_policy",
    "PreprocOptions.epochlimpre_ms", "PreprocOptions.epochlimpost_ms",
]
missing = [token for token in required if token not in text]
if missing:
    raise AssertionError(f"missing Step-3 anchors: {missing}")
positions = [
    text.index("EEG_clean = preproc(EEG, optsA)"),
    text.index("delete_unwanted_events(EEG_clean"),
    text.index("[EEG_clean, repAdd] = add_offset_events("),
    text.index("EEG_pre = preproc(EEG_clean, optsD)"),
]
if positions != sorted(positions) or len(set(positions)) != 4:
    raise AssertionError("Step-3 delete/offset/preproc order differs")
if text.index("eeglab;") > text.index("addpath(functionsDir, '-begin')"):
    raise AssertionError("Step-3 local path is added before EEGLAB")
if re.search(r"(?m)^\s*preproc(?:\.[A-Za-z]\w*)*\s*=", text):
    raise AssertionError("Step-3 workspace variable shadows the preproc function")
if not re.search(r"(?m)^\s*EEG_pre\.etc\.simple\.preproc\s*=", text):
    raise AssertionError("Step-3 stored preprocessing provenance field is missing")
opts_a = set(re.findall(r"optsA\.([A-Za-z]\w*)\s*=", text))
expected_a = {"reref","refchan","resample","srate","filter","highpass","lowpass",
              "linefilter","linefreq","cleanline","epoching","baseadjust"}
opts_d = set(re.findall(r"optsD\.([A-Za-z]\w*)\s*=", text))
expected_d = {"reref","refchan","resample","srate","filter","highpass","lowpass",
              "linefilter","linefreq","cleanline","epoching","epochevents","baseadjust",
              "epochlimpre","epochlimpost"}
if opts_a != expected_a:
    raise AssertionError(f"optsA fields differ: {sorted(opts_a ^ expected_a)}")
if opts_d != expected_d:
    raise AssertionError(f"optsD fields differ: {sorted(opts_d ^ expected_d)}")
effective_block = [
    "eff.reref              = logical(optsA.reref);",
    "if optsA.reref",
    "eff.refchan        = optsA.refchan;",
    "eff.refchan        = {};",
    "eff.resample           = logical(optsA.resample);",
]
missing_effective = [token for token in effective_block if token not in text]
if missing_effective:
    raise AssertionError(
        f"Step-3 effective provenance is not based on applied Block-A options: {missing_effective}")
stale_requested = [
    "eff.reref              = logical(PreprocOptions.reref);",
    "eff.refchan            = PreprocOptions.refchan;",
    "eff.resample           = logical(PreprocOptions.resample);",
]
present_stale = [token for token in stale_requested if token in text]
if present_stale:
    raise AssertionError(
        f"Step-3 effective provenance still reports requested values: {present_stale}")
print("EEGLAB-before-local-path; no preproc shadow; truthful stored provenance; separate delete/offset mechanism; exact two preproc option blocks")
PY
}

check_processing_safety() {
    python3 "$candidate/tests/check_processing_safety_contracts.py" "$candidate"
}

check_step2_identity() {
    python3 "$candidate/tests/check_step2_identity_contracts.py" "$candidate"
}

check_step5_4() {
    file="$candidate/scripts/step_5_sum_4_plot_epochs.m"
    for token in \
        'eeglab;' \
        "addpath(functionsFolder, '-begin')" \
        'overlayNRF = true' \
        'if ~overlayNRF' \
        'if overlayNRF' \
        'NRFUtils.resolveTemplateFile(' \
        'templateFiles' \
        'which(' \
        'expectedNRFUtils'; do
        grep -Fq "$token" "$file" || { printf 'missing Step 5.4 anchor: %s\n' "$token"; return 1; }
    done
    printf 'Step 5.4 overlay off/on, resolver and local-path anchors'
}

check_step7_2() {
    file="$candidate/scripts/step_7_check_2_plot_included_epochs.m"
    for token in \
        'eeglab;' \
        "addpath(functionsFolder, '-begin')" \
        'overlayNRF = true' \
        'if overlayNRF' \
        'else' \
        'NRFUtils.resolveTemplateFile(' \
        'templateFiles' \
        'expectedNRFUtils'; do
        grep -Fq "$token" "$file" || { printf 'missing Step 7.2 anchor: %s\n' "$token"; return 1; }
    done
    printf 'Step 7.2 overlay off/on, resolver and local-path anchors'
}

check_step7_3() {
    file="$candidate/scripts/step_7_check_3_plot_average_ts.m"
    for token in \
        'getNRFOverlays  = true' \
        'plotNRFOverlays = true' \
        'if ~getNRFOverlays && plotNRFOverlays' \
        'if getNRFOverlays' \
        'NRFUtils.resolveTemplateFile(' \
        'overlayNRFFiles_to_compute' \
        'ts_nrf_overlay(' \
        "addpath(functionsDir, '-begin')"; do
        grep -Fq "$token" "$file" || { printf 'missing Step 7.3 anchor: %s\n' "$token"; return 1; }
    done
    [ "$(grep -Fc 'NRFUtils.resolveTemplateFile(' "$file")" -ge 2 ] || return 1
    printf 'Step 7.3 compute/plot off/on and resolved-file overlay anchors'
}

check_strasbourg_contract() {
    expected="$work_root/strasbourg-scripts.expected"
    actual="$work_root/strasbourg-scripts.actual"
    printf '%s\n' \
        step_1_source_1_create_dataset_list_prelim.m \
        step_1_source_2_find_missing.m \
        step_1_source_3_create_source.m \
        step_2_raw_1_get_original_events.m \
        step_2_raw_2_filter_events.m \
        step_2_raw_3_add_reformats.m \
        step_2_raw_4_create_raw.m \
        step_2_raw_5_adjust_latencies.m \
        step_2_raw_6_get_standardised_events.m \
        step_2_raw_7_get_channels.m \
        step_2_raw_8_filter_channels.m \
        step_2_raw_9_create_dataset_list.m \
        step_2_raw_10_pseudonymise_ids.m \
        step_2_raw_11_sanitise_sets.m \
        step_3_proc_1_get_event_types.m \
        step_3_proc_2_get_channels.m \
        step_3_proc_3_add_processeds.m \
        step_3_proc_4_preprocessing.m \
        step_4_quant_1_QC_feature_extraction.m \
        step_4_quant_2_get_epochs.m \
        step_4_quant_3_NRF_feature_extraction.m \
        step_5_sum_1_add_summaries.m \
        step_5_sum_2_summarise_individual.m \
        step_5_sum_3_summarise_pooled.m \
        step_5_sum_4_plot_epochs.m \
        step_6_screen_1_init_package.m \
        step_6_screen_2_viewer_rate_epochs.m \
        step_6_screen_3_apply_decisions.m \
        step_7_check_1_save_excluded_figs.m \
        step_7_check_2_plot_included_epochs.m \
        step_7_check_3_plot_average_ts.m \
        step_7_check_4_plot_average_tf.m \
        step_7_check_5_plot_average_psd.m \
        step_7_check_6_sep_check_qc.m \
        step_7_check_7_sep_check_nrf.m \
        step_8_gen_1_check_plots.m | LC_ALL=C sort > "$expected"
    git -C "$candidate" ls-files 'scripts/step_*.m' | \
        sed 's#^scripts/##' | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ "$(wc -l < "$actual" | tr -d ' ')" -eq 36 ] || return 1

    python3 - "$candidate" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def require_tokens(relative, tokens):
    text = (root / relative).read_text(encoding="utf-8")
    missing = [token for token in tokens if token not in text]
    if missing:
        raise AssertionError(f"{relative}: missing required anchors {missing}")
    return text

standardised_events = require_tokens(
    "scripts/step_2_raw_6_get_standardised_events.m", [
        "data/info_prelim/event_types_standardised/<stem>_event_types_standardised.csv",
        "outCsv = fullfile(eventsFolder, [stem '_event_types_standardised.csv']);",
    ])
output_assignments = [
    line.strip() for line in standardised_events.splitlines()
    if line.strip().startswith("outCsv = fullfile(eventsFolder")
]
if output_assignments != [
        "outCsv = fullfile(eventsFolder, [stem '_event_types_standardised.csv']);"]:
    raise AssertionError("standardised-event output assignment is not unique and exact")
fixture_stem = pathlib.PurePosixPath(
    "sub-TEST_ses-TEST_run-stim2_eeg.set").stem
fixture_output = fixture_stem + "_event_types_standardised.csv"
expected_output = "sub-TEST_ses-TEST_run-stim2_eeg_event_types_standardised.csv"
modality_count = pathlib.PurePosixPath(fixture_output).stem.split("_").count("eeg")
if fixture_output != expected_output or modality_count != 1:
    raise AssertionError(
        f"standardised-event filename contract failed: {fixture_output}")

step33 = require_tokens("scripts/step_3_proc_3_add_processeds.m", [
    "functionsDir = fullfile(baseDir, 'functions');",
    "clear validate_dataset_registry_paths;",
    "expectedValidator = fullfile(functionsDir, 'validate_dataset_registry_paths.m');",
    "resolvedValidator = which('validate_dataset_registry_paths');",
    "char(java.io.File(resolvedValidator).getCanonicalPath())",
    "validate_dataset_registry_paths(T, baseDir, 'raw');",
    "validate_dataset_registry_paths(T, baseDir, 'processed');",
])
if step33.index("validate_dataset_registry_paths(T, baseDir, 'raw');") > \
        step33.index("for r = 1:N"):
    raise AssertionError("Step 3.3 validates raw registry paths after derivation")
if step33.index("validate_dataset_registry_paths(T, baseDir, 'processed');") > \
        step33.index("writetable(T, fileListPath);"):
    raise AssertionError("Step 3.3 validates the candidate registry after writing it")

step3 = require_tokens("scripts/step_3_proc_4_preprocessing.m", [
    "PreprocOptions.src_types    = {'cannula'};",
    "PreprocOptions.new_types    = {'cannula_prestim'};",
    "PreprocOptions.epochevents_true  = {'cannula'};",
    "PreprocOptions.epochevents_dummy = {'cannula_prestim'};",
    "PreprocOptions.epochlimpre_ms  = 200;",
    "PreprocOptions.epochlimpost_ms = 1200;",
    "EEG_pre.etc.simple.preproc = preprocProvenance;",
    "'validate_dataset_registry_paths'",
    "validate_dataset_registry_paths(T, baseDir, 'processed');",
])
step34_validation = step3.index(
    "validate_dataset_registry_paths(T, baseDir, 'processed');")
for write_anchor in ("for idx = 1:totalToDo", "mkdir(outDir);", "pop_saveset("):
    if step34_validation > step3.index(write_anchor):
        raise AssertionError(
            f"Step 3.4 validates the registry after governed anchor: {write_anchor}")
step41 = require_tokens("scripts/step_4_quant_1_QC_feature_extraction.m", [
    "channels_of_interest = {'Cz','CZ'};",
    "'validate_dataset_registry_paths'",
    "validate_dataset_registry_paths(T, baseDir, 'processed');",
])
step41_validation = step41.index(
    "validate_dataset_registry_paths(T, baseDir, 'processed');")
for write_anchor in ("for idx = 1:totalToDo", "pop_saveset("):
    if step41_validation > step41.index(write_anchor):
        raise AssertionError(
            f"Step 4.1 validates the registry after governed anchor: {write_anchor}")
step4_nrf = require_tokens("scripts/step_4_quant_3_NRF_feature_extraction.m", [
    "had_previous_nrf = false;",
    "if isfield(EEG.epoch(e), 'NRF') && ~isempty(EEG.epoch(e).NRF)",
    "if ~isstruct(previous_nrf) || ~isempty(fieldnames(previous_nrf))",
    "had_previous_nrf = true;",
    "EEG.epoch(e).NRF = struct();",
    "if fits_done > 0 || had_previous_nrf",
    "mappedProfileNames = [mappedProfileNames, values(map.(families{f}))];",
    "activeNRFNames{pIdx} = profiles.(mappedProfileNames{pIdx}).NRFName;",
    "[logicalName, templateFile] = NRFUtils.resolveTemplateFile(",
    "activeNRFNames{nIdx}, baseDir);",
    "'validate_dataset_registry_paths'",
    "validate_dataset_registry_paths(T, baseDir, 'processed');",
])
preflight_position = step4_nrf.index("mappedProfileNames = {};")
list_position = step4_nrf.index("%% --- Load EEG dataset list ---")
loop_position = step4_nrf.index("for i = 1:N")
if not preflight_position < list_position < loop_position:
    raise AssertionError(
        "Step-4 all-template preflight does not precede list loading and dataset writes")
step43_validation = step4_nrf.index(
    "validate_dataset_registry_paths(T, baseDir, 'processed');")
for write_anchor in ("for i = 1:N", "pop_saveset("):
    if step43_validation > step4_nrf.index(write_anchor):
        raise AssertionError(
            f"Step 4.3 validates the registry after governed anchor: {write_anchor}")
step51 = require_tokens("scripts/step_5_sum_1_add_summaries.m", [
    "functionsDir = fullfile(baseDir, 'functions');",
    "clear validate_dataset_registry_paths;",
    "expectedValidator = fullfile(functionsDir, 'validate_dataset_registry_paths.m');",
    "resolvedValidator = which('validate_dataset_registry_paths');",
    "char(java.io.File(resolvedValidator).getCanonicalPath())",
    "validate_dataset_registry_paths(T, baseDir, 'processed');",
    "validate_dataset_registry_paths(T, baseDir, 'summary');",
])
if step51.index("validate_dataset_registry_paths(T, baseDir, 'processed');") > \
        step51.index("for r = 1:N"):
    raise AssertionError("Step 5.1 validates processed paths after derivation")
summary_validation = step51.index(
    "validate_dataset_registry_paths(T, baseDir, 'summary');")
if summary_validation < step51.index("T.path_summary = path_summary;") or \
        summary_validation > step51.index("writetable(T, fileListPath);"):
    raise AssertionError("Step 5.1 does not validate candidate summary targets before writing")
obsolete_step51 = [token for token in ("skipped_empty", "warned") if token in step51]
if obsolete_step51:
    raise AssertionError(f"Step 5.1 retains obsolete skip/warn counters: {obsolete_step51}")
step52 = require_tokens("scripts/step_5_sum_2_summarise_individual.m", [
    "functionsFolder = fullfile(baseDir, 'functions');",
    "addpath(functionsFolder, '-begin');",
    "clear validate_dataset_registry_paths;",
    "expectedValidator = fullfile(functionsFolder, 'validate_dataset_registry_paths.m');",
    "resolvedValidator = which('validate_dataset_registry_paths');",
    "char(java.io.File(resolvedValidator).getCanonicalPath())",
    "validate_dataset_registry_paths(T, baseDir, 'summary');",
])
step52_validation = step52.index(
    "validate_dataset_registry_paths(T, baseDir, 'summary');")
for write_anchor in ("for r = 1:N", "mkdir(outDir);", "save(out_epochs", "writetable("):
    if step52_validation > step52.index(write_anchor):
        raise AssertionError(
            f"Step 5.2 validates the registry after governed anchor: {write_anchor}")
require_tokens("scripts/step_5_sum_4_plot_epochs.m", [
    'filterValue = "cannula";', 'channelRequested = "Cz";',
    "'noxious_preterm_NRF_500Hz'",
])
require_tokens("scripts/step_6_screen_2_viewer_rate_epochs.m", [
    "QC_BOXPLOT_WHISKER = 6;",
])
require_tokens("scripts/step_7_check_2_plot_included_epochs.m", [
    'filterValue = "cannula";', 'channelRequested = "Cz";',
    "'noxious_preterm_NRF_500Hz'",
])
require_tokens("scripts/step_7_check_3_plot_average_ts.m", [
    'channelFilter   = "Cz";', 'eventtypeFilter = "cannula";',
    'shiftNRFName = "noxious_preterm_NRF_500Hz";',
    'woodyROI        = [0 1000];', 'xlim_window_ms = [-100 1150];',
])
require_tokens("scripts/step_7_check_6_sep_check_qc.m", [
    'channel_of_interest = "Cz";',
    'eventtype_reference = "cannula_prestim";',
    'eventtype_primary   = "cannula";',
])
require_tokens("scripts/step_7_check_7_sep_check_nrf.m", [
    'channel_of_interest = "Cz";',
    'eventtype_reference = "cannula_prestim";',
    'eventtype_primary   = "cannula";',
    'NRFName_of_interest = "noxious_preterm_NRF_500Hz";',
])

require_tokens("scripts/step_8_gen_1_check_plots.m", [
    "'ordered', [\"cannula_prestim\", \"cannula\"]",
    "'nrf_name', \"noxious_preterm_NRF_500Hz\"",
    "'figure_3b_post_screening_descriptive_checks_noci_prem.pdf'",
])
print("exact 36-script Strasbourg optional-identity/event/channel/window/preterm/Figure-3b contract")
PY
}

check_step8_guardrail() {
    python3 - "$candidate" <<'PY'
import hashlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

def digest(relative):
    return hashlib.sha256((root / relative).read_bytes()).hexdigest()

def script_statements(text):
    statements = []
    in_block_comment = False
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if stripped.startswith("%{"):
            in_block_comment = True
            continue
        if in_block_comment:
            if stripped.startswith("%}"):
                in_block_comment = False
            continue
        if re.match(r"^\s*function\b", raw_line):
            break
        if not stripped or stripped.startswith("%"):
            continue
        code = raw_line.split("%", 1)[0].strip()
        if code:
            statements.append(code)
    return statements

expected = ["step_8_gen_1_check_plots.m"]
actual = sorted(path.name for path in (root / "scripts").glob("step_8_*.m"))
if actual != expected:
    raise AssertionError(f"Step 8 manuscript-output inventory differs: {actual}")

source_hashes = {
    "scripts/step_8_gen_1_check_plots.m":
        "db2041d33807537cca5cc4abf06a08743c0f3dcb4cb524067bffacfe8d4b1c64",
    "functions/collect_guardrail_event_series.m":
        "09fd57796d147f88c008d6a0add4c37ad658ec61f40cff549c349c9541555dc5",
    "functions/plot_guardrail_average_ts.m":
        "617b90c939387436f021771bc3a05c0b1d0d905736c6ab7278ca8da1b84fee2d",
    "functions/plot_guardrail_average_tf.m":
        "9f7a2fe2ec03d1745f9bf961da6dfc24af13289fbdd78ac619301a679978d32f",
    "functions/plot_guardrail_average_psd.m":
        "ae61dd115e3be484b04b2be60541d9bae4b143d3338e7d82e11f949ce67f3088",
    "functions/load_guardrail_separation_result.m":
        "2e81686dc395a34cf704b7007ca4f67da1fbb88a97235157bbce91547e385626",
    "scripts/step_7_check_3_plot_average_ts.m":
        "b6580880523fb25f9e26c3e58fd7d78edc4c271b5c5d929f2590ffc5c4f8ba70",
    "scripts/step_7_check_4_plot_average_tf.m":
        "abe97ea9826a9c214ab1d51811f4917774c1d9e7bee44a2768aeb98c2265302f",
    "scripts/step_7_check_5_plot_average_psd.m":
        "5ac7c7cd07ae5f24326a93b698e026a57868b97a41c76b97c96cac5a5286bfc4",
    "scripts/step_7_check_6_sep_check_qc.m":
        "37bde8cfdb1a35c9cc0c5dbbe45a877361b6e481a9b9850bda378985def63449",
    "scripts/step_7_check_7_sep_check_nrf.m":
        "216a3be171ad0d80291602cc05124bb6e963fe8781bb23877191bf78cfac674a",
}
for relative, expected_hash in source_hashes.items():
    if digest(relative) != expected_hash:
        raise AssertionError(f"Step 8.1 source/reference anchor differs: {relative}")

step81 = (root / "scripts" / expected[0]).read_text(encoding="utf-8")
statements = script_statements(step81)
if not statements or statements[0] != "log_command_window('start');":
    raise AssertionError("Step 8.1 logger start is not the first executable statement")
clear_positions = [i for i, value in enumerate(statements)
                   if re.match(r"^clear(?:\s|;)", value)]
if not clear_positions or clear_positions[0] <= 0:
    raise AssertionError("Step 8.1 logger start does not precede clear")
if step81.count("log_command_window('start');") != 1 or \
        step81.count("log_command_window('stop');") != 2:
    raise AssertionError("Step 8.1 guarded logger inventory differs")
for anchor in (
    "try", "catch ME", "rethrow(ME);", "figure6LogActive",
    "figure6LogStopAttempted",
    "Completed Step 8.1 post-screening descriptive-check figure ",
    "preparation; committing PDF: %s\\n",
):
    if anchor not in step81:
        raise AssertionError(f"Step 8.1 guarded finaliser lacks {anchor}")

step81_anchors = [
    "resultsDir = fullfile(baseDir, 'data', 'results');",
    "'figure_3b_post_screening_descriptive_checks_noci_prem.pdf'",
    "'step_8_gen_1_check_plots.log'",
    "'pooled_screened_eeg_epochs.mat'",
    "'step_7_check_7_sep_check_nrf_result.mat'",
    "'ordered', [\"cannula_prestim\", \"cannula\"]",
    "figure6Config.use_exclusion_flags = true;",
    "'noxious_preterm_NRF_500Hz'", "'fit_time_ms', 0",
    "'jitter_ms', 100", "'aggregator', \"mean\"",
    "'smoothing_ms', 0", "'x_limits_ms', [-100 1150]",
    "'y_limits_uV', [-20 20]", "'voices_per_octave', 12",
    "'baseline_time_agg', \"mean\"", "'epoch_agg', \"mean\"",
    "'y_axis_scale', \"linear\"", "'frequency_limits_hz', [3 30]",
    "'colour_limits_db', [-4 4]", "'epoch_window', \"post-stim\"",
    "'aggregate_domain', \"linear_power\"",
    "'frequency_limits_hz', [-1 251]", "'time_bandwidth_product', 4",
    "'nfft', 1024", "'alpha', 0.05", "'figure_position_cm', [2 2 18 24]",
    "'part_a', 'Time and frequency domain checks'",
    "'reference', 'Internal reference'",
    "'true', 'True event'",
    "'part_b', 'NRF magnitude separation check'",
    "'figure6-label-part-a', 'center'",
    "'figure6-label-part-b', 'center'",
    "dataAxes = gobjects(7, 1);",
    "ylim(dataAxes(7), [0 150]);", "yticks(dataAxes(7), 0:50:150);",
    "numel(unique(actualAxesTags)) ~= 7",
    "numel(unique(labelTags)) ~= 4",
    "0.56 0.75 0.34 0.15", "0.07 0.75 0.34 0.15",
    "0.33 0.08 0.34 0.15", "0.04 0.2439 0.92 0.025",
    "Magnitude (\\muV)", "Median paired difference (\\muV)",
    "'display_label', 'p-NRF'",
    "figure6Config = struct();", "figure6PanelData = struct();",
    "figure6PanelHandles = struct();", "figure6Figure = figure(",
    "collect_guardrail_event_series(", "plot_guardrail_average_ts(",
    "plot_guardrail_average_tf(", "plot_guardrail_average_psd(",
    "load_guardrail_separation_result(", "plot_paired_effect_result(",
    "exportgraphics(figure6Figure, figure6PartialPdf, 'ContentType', 'vector');",
    "figure6InternalFailpoint = \"\";",
]
missing = [anchor for anchor in step81_anchors if anchor not in step81]
if missing:
    raise AssertionError(f"Step 8.1 fixed route differs: {missing}")
if step81.count("load(figure6Config.paths.screened_epochs_mat, 'epochs_pooled')") != 1:
    raise AssertionError("Step 8.1 does not load the screened epoch MAT exactly once")
if re.search(r"\brun\s*\(", step81, flags=re.IGNORECASE):
    raise AssertionError("Step 8.1 invokes a numbered Step 7 script with run")
if re.search(r"step_7_check_[3-7][A-Za-z0-9_]*\s*\(", step81):
    raise AssertionError("Step 8.1 directly invokes a Step 7 script")

expected_axes = [
    "figure6-ts-reference", "figure6-ts-true",
    "figure6-tf-reference", "figure6-tf-true",
    "figure6-psd-reference", "figure6-psd-true",
    "figure6-nrf-separation",
]
expected_labels = [
    "figure6-label-part-a", "figure6-label-reference",
    "figure6-label-true", "figure6-label-part-b",
]
for tag in expected_axes + expected_labels:
    if step81.count(tag) < 2:
        raise AssertionError(f"Step 8.1 tagged inventory lacks checked tag {tag}")

for prohibited in ("qc_result_mat", "qc_expected", "qcSeparation",
                   "figure6-qc-separation", "figure6-label-qc", "figure6-label-nrf"):
    if prohibited in step81:
        raise AssertionError(f"Step 8.1 retains removed QC plot dependency: {prohibited}")

helper_contracts = {
    "collect_guardrail_event_series.m":
        "function seriesByEvent = collect_guardrail_event_series(",
    "plot_guardrail_average_ts.m":
        "function [result, handles] = plot_guardrail_average_ts(",
    "plot_guardrail_average_tf.m":
        "function [result, handles] = plot_guardrail_average_tf(",
    "plot_guardrail_average_psd.m":
        "function [result, handles] = plot_guardrail_average_psd(",
    "load_guardrail_separation_result.m":
        "function result = load_guardrail_separation_result(",
}
for name, signature in helper_contracts.items():
    text = (root / "functions" / name).read_text(encoding="utf-8")
    if signature not in text:
        raise AssertionError(f"Step 8.1 helper signature differs: {name}")
    for prohibited in ("/Users/", "evalin(", "assignin(",
                       "log_command_window(", "diary(", "exportgraphics(",
                       "save(", "writetable("):
        if prohibited in text:
            raise AssertionError(
                f"Step 8.1 helper has prohibited side effect/root: {name} {prohibited}")
if "figure(" in (root / "functions" / "plot_guardrail_average_ts.m").read_text(encoding="utf-8") or \
        "figure(" in (root / "functions" / "plot_guardrail_average_tf.m").read_text(encoding="utf-8") or \
        "figure(" in (root / "functions" / "plot_guardrail_average_psd.m").read_text(encoding="utf-8"):
    raise AssertionError("A Step 8.1 panel helper creates its own figure")

readme = (root / "README.md").read_text(encoding="utf-8")
for anchor in (
    "step_8_gen_1_check_plots.m",
    "figure_3b_post_screening_descriptive_checks_noci_prem.pdf",
    "seven panels across four rows",
    "without rerunning its bootstrap",
    "does not call a Step 7 script",
    "aggregate recordings within participant",
):
    if anchor not in readme:
        raise AssertionError(f"README lacks the Step 8.1 contract: {anchor}")
print("one exact Step 8 script; fixed recording-level Figure 3b helper and transaction route")
PY
}

check_unintended_files() {
    python3 - "$candidate" <<'PY'
import pathlib
import subprocess
import sys
root = pathlib.Path(sys.argv[1])
files = subprocess.run(["git", "-C", str(root), "ls-files"], check=True,
                       text=True, stdout=subprocess.PIPE).stdout.splitlines()
bad = []
blocked_suffixes = {".set", ".fdt", ".log", ".fig", ".png", ".csv", ".xlsx",
                    ".asv", ".partial", ".tmp"}
allowed_mat = {
    "NRFs/early_NRF_500Hz.mat",
    "NRFs/noxious_NRF_500Hz.mat",
    "NRFs/noxious_preterm_NRF_500Hz.mat",
    "tests/fixtures/simple_scientific_oracle_v1.mat",
}
for rel in files:
    path = pathlib.PurePosixPath(rel)
    if path.suffix.lower() in blocked_suffixes or path.name in {".DS_Store", "PASS"}:
        bad.append(rel)
    if path.suffix.lower() == ".mat" and rel not in allowed_mat:
        bad.append(rel)
    if "test_results" in rel.lower():
        bad.append(rel)
if bad:
    raise AssertionError(f"unexpected candidate artefacts: {sorted(set(bad))}")
print(f"{len(files)} committed candidate files; no generated data, log or result artefact")
PY
}

check_readme() {
    file="$candidate/README.md"
    for token in \
        '# SIMPLE Strasbourg' \
        'data/logs/' \
        'tracked `.gitkeep`' \
        'functions/' \
        'NRFs/' \
        'tests/' \
        'preproc(EEG, options)' \
        'estimate_response(EEG, options)' \
        'jittercorrect' \
        'projectionTimes_pre' \
        'projectionTimes_post' \
        'post start of 400 ms' \
        'MATLAB R2026a Update 4' \
        'EEGLAB 2026.0.0' \
        '`fgls`' \
        '`robustfit`' \
        '`corr`' \
        'CleanLine is optional' \
        'Every registry path is validated before a governed write' \
        '`step_2_raw_10_pseudonymise_ids.m`' \
        '`step_2_raw_11_sanitise_sets.m`' \
        '`data/raw_orig/`' \
        'pseudonymisation, not anonymisation' \
        '### Step 8 — General manuscript output' \
        '`step_8_gen_1_check_plots.m`' \
        '`figure_3b_post_screening_descriptive_checks_noci_prem.pdf`' \
        'seven panels across four rows' \
        'without rerunning its bootstrap' \
        'does not call a Step 7 script' \
        'aggregate recordings within participant' \
        '`data/logs/step_8_gen_1_check_plots.log`' \
        'tests/run_all_tests.m' \
        'run_all_tests(strasbourgRoot, eeglabRoot);' \
        "tests/run_static_checks.sh"; do
        grep -Fq "$token" "$file" || {
            printf 'README contract anchor missing: %s\n' "$token"
            return 1
        }
    done
    for template in \
        early_NRF_500Hz.mat \
        noxious_NRF_500Hz.mat \
        noxious_preterm_NRF_500Hz.mat; do
        [ "$(grep -Fc "$template" "$file")" -ge 1 ] || {
            printf 'README template listing missing: %s\n' "$template"
            return 1
        }
    done
    printf 'README layout, APIs, defaults, dependencies, templates, logs and explicit tests'
}

check_root_shape() {
    expected="$work_root/root.expected"
    actual="$work_root/root.actual"
    printf '%s\n' .gitignore LICENSE NRFs README.md data data_lists functions scripts tests | LC_ALL=C sort > "$expected"
    git -C "$candidate" ls-files | awk -F/ 'NF {print $1}' | LC_ALL=C sort -u > "$actual"
    diff -u "$expected" "$actual" || return 1
    printf 'exact documented top-level tracked contract'
}

check_git_diff() {
    [ "$source_diff_check" = 'PASS' ] || {
        cat "$work_root/source-diff-check.txt"
        return 1
    }
    git -C "$repo_root" diff --cached --quiet || {
        printf 'source repository contains staged changes\n'
        return 1
    }
    status=$(git -C "$candidate" status --porcelain --untracked-files=all)
    [ -z "$status" ] || {
        printf 'candidate status changed: %s\n' "$status"
        return 1
    }
    printf 'tracked diff and each documented untracked source file whitespace-clean; source index unstaged; candidate status clean'
}

check_config_location() {
    paths=$(git -C "$candidate" ls-files '*nrf_config.ini')
    [ "$paths" = 'NRFs/nrf_config.ini' ] || {
        printf 'INI paths differ: %s\n' "$paths"
        return 1
    }
    grep -Fq "fullfile(baseDir, 'NRFs', 'nrf_config.ini')" \
        "$candidate/scripts/step_4_quant_3_NRF_feature_extraction.m" || return 1
    grep -Fq "fullfile(repoRoot, 'NRFs', 'nrf_config.ini')" \
        "$candidate/tests/run_all_tests.m" || return 1
    digest=$(shasum -a 256 "$candidate/NRFs/nrf_config.ini" | awk '{print $1}')
    [ "$digest" = 'd26673b1b10dc8ff2365b796cd62b520887c7d5b26ecde7063a127babfa35cb0' ] || {
        printf 'NRF configuration digest differs: %s\n' "$digest"
        return 1
    }
    printf 'one exact NRFs/nrf_config.ini and both executable consumers use it'
}

check_path_precedence() {
    python3 - "$candidate" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
issues = []
checked = []
expected_callers = {
    "step_2_raw_9_create_dataset_list.m",
    "step_2_raw_10_pseudonymise_ids.m",
    "step_2_raw_11_sanitise_sets.m",
    "step_3_proc_3_add_processeds.m",
    "step_3_proc_4_preprocessing.m",
    "step_4_quant_1_QC_feature_extraction.m",
    "step_4_quant_3_NRF_feature_extraction.m",
    "step_5_sum_1_add_summaries.m",
    "step_5_sum_2_summarise_individual.m",
    "step_5_sum_4_plot_epochs.m",
    "step_7_check_2_plot_included_epochs.m",
    "step_7_check_3_plot_average_ts.m",
    "step_7_check_6_sep_check_qc.m",
    "step_7_check_7_sep_check_nrf.m",
    "step_8_gen_1_check_plots.m",
}
for path in (root / "scripts").glob("*.m"):
    text = path.read_text(encoding="utf-8")
    add = re.search(r"addpath\(functions(?:Dir|Folder),\s*['\"]-begin['\"]\)", text)
    if not add:
        continue
    checked.append(path.name)
    eeglab = re.search(r"(?m)^\s*eeglab\s*;", text)
    if eeglab and eeglab.start() > add.start():
        issues.append(f"{path.name}: EEGLAB starts after local addpath")
    has_named_assertion = "which(" in text and re.search(
        r"expected(?:Function|NRFUtils|NRFUtilsFile|Validator|Inspector|Helper)",
        text)
    has_shared_assertion = ("assert_local_helper_paths(" in text or
                            "local_assert_helper_paths(" in text or
                            "local_assert_helpers(" in text)
    if not (has_named_assertion or has_shared_assertion):
        issues.append(f"{path.name}: no canonical local-function assertion")

if set(checked) != expected_callers:
    issues.append(
        "local-path caller inventory differs: "
        f"missing={sorted(expected_callers - set(checked))}; "
        f"unexpected={sorted(set(checked) - expected_callers)}"
    )

for path in list((root / "functions").glob("*.m")) + list((root / "scripts").glob("*.m")):
    text = path.read_text(encoding="utf-8")
    if re.search(r"which\s*\([^)]*(?:NRF_[0-9]+Hz|NRFName|templateReference)", text):
        issues.append(f"{path.relative_to(root)}: ambient template which lookup")

utils = (root / "functions" / "NRFUtils.m").read_text(encoding="utf-8")
for token in ("resolveTemplateFile", "fullfile(repositoryRoot, 'NRFs')", "getCanonicalPath"):
    if token not in utils:
        issues.append(f"NRFUtils missing resolver anchor: {token}")
if issues:
    raise AssertionError("; ".join(issues))
print(f"{len(checked)} local-path callers use repository precedence, canonical checks and direct template resolution")
PY
}

run_check 'static.manifest' check_manifest
run_check 'static.repository.function_inventory' check_function_inventory
run_check 'static.repository.template_inventory' check_template_inventory
run_check 'static.repository.current_surface' check_current_surface
run_check 'static.git.hypothetical_ignore' check_hypothetical_ignore
run_check 'static.git.real_ignore' check_real_ignore
run_check 'static.git.fresh_clone' check_fresh_clone
run_check 'static.repository.logs' check_logs
run_check 'static.repository.viewer_qc_example' check_viewer_qc_example
run_check 'static.callers.step3' check_step3
run_check 'static.repository.processing_safety' check_processing_safety
run_check 'static.repository.step2_identity' check_step2_identity
run_check 'static.callers.step5_4' check_step5_4
run_check 'static.callers.step7_2' check_step7_2
run_check 'static.callers.step7_3' check_step7_3
run_check 'static.repository.strasbourg_contract' check_strasbourg_contract
run_check 'static.callers.step8_guardrail' check_step8_guardrail
run_check 'static.repository.unintended_files' check_unintended_files
run_check 'static.repository.readme' check_readme
run_check 'static.repository.root_shape' check_root_shape
run_check 'static.git.diff_check' check_git_diff
run_check 'static.repository.config_location' check_config_location
run_check 'static.repository.path_precedence' check_path_precedence

python3 - "$checks_tsv" "$result_root/summary.json" "$repo_root" \
    "$candidate_commit" "$candidate_inventory_digest" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

checks_path, summary_path, repo, commit, inventory_digest = sys.argv[1:]
with open(checks_path, newline="", encoding="utf-8") as handle:
    checks = list(csv.DictReader(handle, delimiter="\t"))
failures = [item for item in checks if item["status"] != "PASS"]
summary = {
    "schema": "simple-strasbourg-static-check-results-v1",
    "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "repository_source": str(pathlib.Path(repo).resolve()),
    "ephemeral_candidate_commit": commit,
    "candidate_inventory_sha256": inventory_digest,
    "passed": not failures,
    "pass_count": len(checks) - len(failures),
    "failure_count": len(failures),
    "checks": checks,
}
pathlib.Path(summary_path).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

rm -rf -- "$work_root"
printf 'RESULTS %s\n' "$result_root"
printf 'SUMMARY %s\n' "$result_root/summary.json"
if [ "$fail_count" -ne 0 ]; then
    exit 1
fi
exit 0
