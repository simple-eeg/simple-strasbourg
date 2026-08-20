#!/usr/bin/env python3
"""Static contracts for dataset-write and processing-state safety."""

from __future__ import annotations

import pathlib
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def require_order(text: str, first: str, second: str, label: str) -> None:
    first_index = text.find(first)
    second_index = text.find(second)
    require(first_index >= 0, f"{label}: missing {first!r}")
    require(second_index >= 0, f"{label}: missing {second!r}")
    require(first_index < second_index, f"{label}: {first!r} must precede {second!r}")


def read(root: pathlib.Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} REPOSITORY_ROOT")
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)

    create_registry = read(root, "scripts/step_2_raw_9_create_dataset_list.m")
    require_order(
        create_registry,
        "inspect_identity_state",
        "writetable(",
        "Step 2.9 optional-identity-state preflight",
    )
    require("Step29" in create_registry,
            "Step 2.9 must expose a dedicated fail-closed state error surface")

    add_processed = read(root, "scripts/step_3_proc_3_add_processeds.m")
    require_order(
        add_processed,
        "validate_dataset_registry_paths(T, baseDir, 'raw');",
        "for r = 1:N",
        "processed-path derivation raw preflight",
    )
    require_order(
        add_processed,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "writetable(T, fileListPath);",
        "processed-path derivation candidate preflight",
    )

    preprocessing = read(root, "scripts/step_3_proc_4_preprocessing.m")
    require_order(
        preprocessing,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "for idx = 1:totalToDo",
        "preprocessing registry preflight",
    )
    require_order(
        preprocessing,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "mkdir(outDir);",
        "preprocessing directory-write preflight",
    )
    require_order(
        preprocessing,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "pop_saveset(EEG_pre",
        "preprocessing dataset-write preflight",
    )
    require("eff.reref              = logical(optsA.reref);" in preprocessing,
            "effective rereference provenance must use adjusted optsA")
    require("if optsA.reref" in preprocessing,
            "effective reference-channel provenance must branch on applied rereference")
    require("eff.refchan        = optsA.refchan;" in preprocessing,
            "effective reference channels must use adjusted optsA")
    require("eff.refchan        = {};" in preprocessing,
            "disabled rereferencing must record no effective reference channels")
    require("eff.resample           = logical(optsA.resample);" in preprocessing,
            "effective resampling provenance must use adjusted optsA")

    qc = read(root, "scripts/step_4_quant_1_QC_feature_extraction.m")
    require_order(
        qc,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "for idx = 1:totalToDo",
        "QC registry preflight",
    )
    require_order(
        qc,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "pop_saveset(EEG",
        "QC dataset-write preflight",
    )

    nrf = read(root, "scripts/step_4_quant_3_NRF_feature_extraction.m")
    require_order(
        nrf,
        "NRFUtils.resolveTemplateFile(",
        "%% --- Load EEG dataset list ---",
        "NRF all-template preflight",
    )
    require_order(
        nrf,
        "NRFUtils.resolveTemplateFile(",
        "pop_loadset(",
        "NRF all-template before-dataset preflight",
    )
    require_order(
        nrf,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "for i = 1:N",
        "NRF registry preflight",
    )
    require_order(
        nrf,
        "had_previous_nrf = false;",
        "EEG.epoch(e).NRF = struct();",
        "NRF stale-state detection",
    )
    require("fits_done > 0 || had_previous_nrf" in nrf,
            "NRF save condition must persist clearing prior state")
    require_order(
        nrf,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "pop_saveset(EEG",
        "NRF dataset-write preflight",
    )

    add_summary = read(root, "scripts/step_5_sum_1_add_summaries.m")
    require_order(
        add_summary,
        "validate_dataset_registry_paths(T, baseDir, 'processed');",
        "for r = 1:N",
        "summary-path derivation input preflight",
    )
    require_order(
        add_summary,
        "validate_dataset_registry_paths(T, baseDir, 'summary');",
        "writetable(T, fileListPath);",
        "summary-path derivation candidate preflight",
    )

    individual = read(root, "scripts/step_5_sum_2_summarise_individual.m")
    require_order(
        individual,
        "validate_dataset_registry_paths(T, baseDir, 'summary');",
        "for r = 1:N",
        "individual-summary registry preflight",
    )
    for output_token in ("mkdir(outDir)", "save(out_epochs", "writetable(qc_rows"):
        require_order(
            individual,
            "validate_dataset_registry_paths(T, baseDir, 'summary');",
            output_token,
            f"individual-summary write preflight ({output_token})",
        )

    for text, label in (
        (add_processed, "processed-path derivation"),
        (add_summary, "summary-path derivation"),
    ):
        require("expectedValidator = fullfile(functionsDir" in text,
                f"{label}: missing repository-local validator binding")
        require("which('validate_dataset_registry_paths')" in text,
                f"{label}: missing validator resolution check")

    print("Processing safety source contracts passed")


if __name__ == "__main__":
    main()
