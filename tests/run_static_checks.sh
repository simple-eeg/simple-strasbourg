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
require(isinstance(catalog, list) and len(catalog) == 37, "test catalog count differs")
require(isinstance(coverage, list) and len(coverage) == 66, "coverage row count differs")
catalog_ids = [item.get("id") for item in catalog]
require(all(isinstance(x, str) and x for x in catalog_ids), "blank catalog id")
require(len(catalog_ids) == len(set(catalog_ids)), "duplicate catalog id")
catalog_by_id = {item["id"]: item for item in catalog}

expected_keys = set(["baseline_routes","cleanline_routes","closure_clone","closure_config","closure_current_surface","closure_function_inventory","closure_generated","closure_git","closure_ignore_hyp","closure_ignore_real","closure_logs","closure_manifest","closure_paths","closure_readme","closure_root","closure_step54","closure_step72","closure_step73","closure_strasbourg","closure_templates","closure_viewer_qc_example","config_profiles_cache","delete_contracts","dependency_missing","dependency_present","epoch_failures","epoch_modes","filter_modes","jitter_edges","jitter_shapes_shifts","jitter_ties_padding","line_frequency_edges","line_off_notch","numeric_results","offset_consistency","offset_mapping_fields","offset_no_event","offset_no_source","offset_oob","offset_report_keys","offset_validation","prep_defaults","prep_empty_array","prep_empty_data","prep_inputs","prep_multi_array","preproc_order_history","preprocessing_caller_contract","qc_coord_schema","qc_direct_matrix","qc_overwrite_array_times","reref_modes","resample_modes","resolver_failures_shadow","resolver_local_explicit","response_channel","response_every_epoch_array","response_inputs_defaults","response_insufficient","response_public_contract","response_rate_grid_bounds","response_scalar_options","response_schema_history","response_xor","templates_six_rates","warning_restoration"])
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
require(len(catalog_item("matlab.response.oracle")["cases"]) == 17, "response oracle count")
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

expected_totals = {"runner_sha256":"dcef9e0b597db19e492ff62af0f636c5d0fa3d6df2f8e497822522eea3e92d11","preproc":30,"response":17,"jitter":11,"qc":284,"clean_contract":18,"extended":120}
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
    "host": "macOS 26.6.1 build 25G76 arm64",
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
    "response": 17,
    "jitter": 11,
    "quality_control_coordinator": 9,
    "quality_control_direct": 275,
    "templates": 6,
}, "scientific-oracle case counts differ")
fixture = oracle_json["fixture"]
require(fixture == {
    "path": "tests/fixtures/simple_scientific_oracle_v1.mat",
    "bytes": 5157895,
    "sha256": "5477d510e9d321c26ce47ab14d13f335b79400285c0615860488d219b40bf547",
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
print("66 coverage rows; 37 named test groups; exact scientific-oracle cardinalities and binding")
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
        compute_paired_effect.m \
        convert_curry_to_eeg.m \
        convert_xdf_to_eeg.m \
        delete_unwanted_events.m \
        estimate_response.m \
        jittercorrect.m \
        plot_paired_effect_result.m \
        preproc.m \
        quality_control_features.m \
        quality_control_features_with_diagnostics.m \
        read_annotations_from_xdf_csv.m \
        read_events_from_curry_cef.m \
        save_paired_separation_result.m \
        ts_average_NRFshifted.m \
        ts_average_simple.m \
        ts_average_woody.m \
        ts_nrf_overlay.m | LC_ALL=C sort > "$expected"
    git -C "$candidate" ls-files functions | sed 's#^functions/##' | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ "$(wc -l < "$actual" | tr -d ' ')" -eq 30 ] || return 1
    printf 'exact 30-function inventory'
}

check_template_inventory() {
    expected="$work_root/templates.expected"
    actual="$work_root/templates.actual"
    printf '%s  %s\n' \
        dc63ba1418a5492bbc7c7c21bc399eb74fcdef42941b66a64624cfdf114e95e5 early_NRF_2000Hz.mat \
        c036e1aa2905298b0d50a91e41c9353c4121507e2e3fa1062aaec9c247099059 early_NRF_500Hz.mat \
        a8f962450b8674003cfc32d41bf5508b39e1a2bbe87e5b7313255a0a8ec341e6 noxious_NRF_2000Hz.mat \
        d4552315c38abcf030922719b8f707de82fa5707c849d31888034e459fa42d62 noxious_NRF_500Hz.mat \
        f0de306e714f3d77bb021261bc3a84c55d85818dec3264928fb4a658426e733e noxious_preterm_NRF_2000Hz.mat \
        8acf14c5401d0af20391e329fcc17de8cf119c691da0ca7072ae328ddc7ea375 noxious_preterm_NRF_500Hz.mat \
        | LC_ALL=C sort > "$expected"
    for path in "$candidate"/NRFs/*.mat; do
        printf '%s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$(basename -- "$path")"
    done | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ -f "$candidate/NRFs/nrf_config.ini" ] || return 1
    [ "$(git -C "$candidate" ls-files NRFs | wc -l | tr -d ' ')" -eq 7 ] || {
        printf 'NRFs tracked inventory is not exactly six templates plus nrf_config.ini\n'
        return 1
    }
    printf 'six exact template digests and local INI'
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
    "NRFs/nrf_config.ini": ["[term_foot_nox]"],
    "scripts/log_command_window.m": [
        "logsDir = fullfile(projectRoot, 'data', 'logs');",
    ],
    "tests/run_all_tests.m": [
        "function results = run_all_tests(repoRoot, eeglabRoot)",
        "simple_scientific_oracle_v1.mat",
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
bad = []
for parent in (root / "functions", root / "scripts"):
    for path in parent.glob("*.m"):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"fullfile\([^\n;]*['\"]logs['\"]", text,
                                 re.IGNORECASE):
            expression = match.group(0)
            constructors.append(f"{path.relative_to(root)}:{expression}")
            if not re.search(r"['\"]data['\"][^\n;]*['\"]logs['\"]",
                             expression, re.IGNORECASE):
                bad.append(f"{path.relative_to(root)}:{expression}")
if bad:
    raise AssertionError("; ".join(bad))
if len(constructors) != 1:
    raise AssertionError(f"log-constructor count differs: {constructors}")
PY
    printf 'single data/logs constructor; replacement and ignore anchors present'
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
print("EEGLAB-before-local-path; no preproc shadow; stored provenance field; separate delete/offset mechanism; exact two preproc option blocks")
PY
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
        step_8_jasp_1_data_prep_eeg.m | LC_ALL=C sort > "$expected"
    git -C "$candidate" ls-files 'scripts/step_*.m' | \
        sed 's#^scripts/##' | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" || return 1
    [ "$(wc -l < "$actual" | tr -d ' ')" -eq 34 ] || return 1

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

step3 = require_tokens("scripts/step_3_proc_4_preprocessing.m", [
    "PreprocOptions.src_types    = {'cannula'};",
    "PreprocOptions.new_types    = {'cannula_prestim'};",
    "PreprocOptions.epochevents_true  = {'cannula'};",
    "PreprocOptions.epochevents_dummy = {'cannula_prestim'};",
    "PreprocOptions.epochlimpre_ms  = 200;",
    "PreprocOptions.epochlimpost_ms = 1200;",
    "EEG_pre.etc.simple.preproc = preprocProvenance;",
])
require_tokens("scripts/step_4_quant_1_QC_feature_extraction.m", [
    "channels_of_interest = {'Cz','CZ'};",
])
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

require_tokens("scripts/step_8_jasp_1_data_prep_eeg.m", [
    'expected_channel = "Cz";',
    'expected_nrfname = "noxious_preterm_NRF_500Hz";',
    'expected_ref_event = "cannula_prestim";',
    'expected_true_event = "cannula";',
    'selection_rule = "earliest_timestamped_cannula_event_per_subject";',
    '"within_subject_median_of_complete_retained_matched_recording_pairs";',
    '%% 6) Rank recordings chronologically and freeze selection before Exclude',
    '%% 9) Aggregate complete retained matched recordings within subject by median',
])
print("exact 34-script Strasbourg event/channel/window/preterm/Step-8 contract")
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
    "NRFs/early_NRF_2000Hz.mat", "NRFs/early_NRF_500Hz.mat",
    "NRFs/noxious_NRF_2000Hz.mat", "NRFs/noxious_NRF_500Hz.mat",
    "NRFs/noxious_preterm_NRF_2000Hz.mat",
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
        'tests/run_all_tests.m' \
        'run_all_tests(strasbourgRoot, eeglabRoot);' \
        "tests/run_static_checks.sh"; do
        grep -Fq "$token" "$file" || {
            printf 'README contract anchor missing: %s\n' "$token"
            return 1
        }
    done
    for template in \
        early_NRF_500Hz.mat early_NRF_2000Hz.mat \
        noxious_NRF_500Hz.mat noxious_NRF_2000Hz.mat \
        noxious_preterm_NRF_500Hz.mat noxious_preterm_NRF_2000Hz.mat; do
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
    [ "$digest" = '07dde048029d3fa85d0a98685f3008bca074bd85cebeb79cdc73b99dd6180de9' ] || {
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
    "step_3_proc_4_preprocessing.m",
    "step_4_quant_1_QC_feature_extraction.m",
    "step_4_quant_3_NRF_feature_extraction.m",
    "step_5_sum_4_plot_epochs.m",
    "step_7_check_2_plot_included_epochs.m",
    "step_7_check_3_plot_average_ts.m",
    "step_7_check_6_sep_check_qc.m",
    "step_7_check_7_sep_check_nrf.m",
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
    has_named_assertion = "which(" in text and re.search(r"expected(?:Function|NRFUtils|NRFUtilsFile)", text)
    has_shared_assertion = "assert_local_helper_paths(" in text
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
    if re.search(r"which\s*\([^)]*(?:NRF_500Hz|NRF_2000Hz|NRFName|templateReference)", text):
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
run_check 'static.callers.step5_4' check_step5_4
run_check 'static.callers.step7_2' check_step7_2
run_check 'static.callers.step7_3' check_step7_3
run_check 'static.repository.strasbourg_contract' check_strasbourg_contract
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
