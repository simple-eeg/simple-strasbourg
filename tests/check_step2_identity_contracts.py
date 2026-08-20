#!/usr/bin/env python3
"""Static public contracts for the optional identity route."""

from __future__ import annotations

import pathlib
import re
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read(root: pathlib.Path, relative: str) -> str:
    path = root / relative
    require(path.is_file(), f"missing optional-route path: {relative}")
    return path.read_text(encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} REPOSITORY_ROOT")
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)

    heading = read(root, "README.md").splitlines()[0].strip()
    require(heading in {"# SIMPLE Oxford", "# SIMPLE Strasbourg"},
            f"unexpected README heading: {heading!r}")
    is_oxford = heading == "# SIMPLE Oxford"

    shared_functions = (
        "build_pseudonymised_dataset_registry",
        "inspect_identity_state",
        "inspect_pseudonymisation_inputs",
        "load_dataset_identity_registry",
        "run_pseudonymisation_transaction",
        "run_sanitisation_transaction",
        "sanitise_eeglab_dataset",
        "verify_sanitised_eeglab_dataset",
    )
    dataset_terms = ("simple-oxford", "simple-strasbourg", "oxford",
                     "strasbourg", "petal", "noci")
    for name in shared_functions:
        text = read(root, f"functions/{name}.m")
        require(re.search(
            rf"(?m)^function\b[^\n=]*(?:=\s*)?{re.escape(name)}\(",
            text) is not None,
            f"{name}: public declaration differs")
        present = [term for term in dataset_terms if term in text.lower()]
        require(not present, f"{name}: dataset-specific terms {present}")

    entries = {
        "scripts/step_2_raw_10_pseudonymise_ids.m":
            ("run_pseudonymisation_transaction",
             "result = run_pseudonymisation_transaction(baseDir);"),
        "scripts/step_2_raw_11_sanitise_sets.m":
            ("run_sanitisation_transaction",
             "result = run_sanitisation_transaction(repositoryRoot);"),
    }
    forbidden = (
        "simple-oxford", "simple-strasbourg", "petal", "noci-prem",
        "/volumes/", "uigetfile", "questdlg", "input(",
        "failure_point", "interruption_point", "usable_bytes",
        "available_bytes_override", "save_version",
    )
    for relative, (runner, exact_call) in entries.items():
        text = read(root, relative)
        for anchor in (
            "mfilename('fullpath')", "addpath(", "rehash path", "which(",
            "getCanonicalPath", "log_command_window('start')",
            "log_command_window('stop')",
        ):
            require(anchor in text, f"{relative}: missing {anchor!r}")
        require(text.count(exact_call) == 1 and text.count(runner + "(") == 1,
                f"{relative}: runner call is not exactly bounded")
        present = [term for term in forbidden if term in text.lower()]
        require(not present, f"{relative}: forbidden terms {present}")

    if is_oxford:
        helper = read(root, "functions/construct_medscinet_subject_ids.m")
        present = [term for term in ("petal", "noci")
                   if term in helper.lower()]
        require(not present,
                f"Oxford MedSciNet helper is dataset-specific: {present}")

    print("Optional identity-route public contracts passed")


if __name__ == "__main__":
    main()
