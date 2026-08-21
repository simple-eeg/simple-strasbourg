# SIMPLE Strasbourg

SIMPLE Strasbourg is the MATLAB/EEGLAB workflow for the NOCI-Prem neonatal EEG
dataset supplied by the Strasbourg collaborators. It covers BrainVision source
preparation, the complete SIMPLE EEG workflow, and the Strasbourg-specific
post-core guardrail figure.

Associated methods paper: citation and link to be added when available.

## Repository layout

```text
simple-strasbourg/
├── data/                 local inputs, intermediate files, outputs and logs
├── data_lists/           local dataset lists and study spreadsheets
├── functions/            MATLAB functions used by the workflow
├── NRFs/                 bundled NRF templates and nrf_config.ini
├── scripts/              numbered workflow scripts and the logging helper
├── tests/                synthetic regression fixtures and test runners
├── .gitignore
├── LICENSE
└── README.md
```

`data/` and `data_lists/` are present in a checkout through tracked `.gitkeep`
files. Every runtime descendant of `data/` is local and ignored by Git. CSV and
XLSX files anywhere beneath `data_lists/` are also ignored. Do not put data
files in version control.

Each numbered script writes its Command Window diary to `data/logs/`. A run
replaces the existing log for that script, and all logs are ignored by Git.

## Software and setup

The workflow requires MATLAB and EEGLAB. The verified environment is
MATLAB R2026a Update 4 with EEGLAB 2026.0.0. Required functionality includes:

- Statistics and Machine Learning Toolbox operations such as `corr`,
  `robustfit` and `fitlm`;
- Econometrics Toolbox `fgls`;
- Signal Processing Toolbox operations used by filtering and spectral checks;
- Wavelet Toolbox for the time-frequency check; and
- BrainVision import support providing `pop_loadbv`.

CleanLine is optional. Preprocessing uses it when selected and otherwise uses
the configured notch-filter route.

Scripts that call repository functions start EEGLAB, prepend this checkout's
`functions/` directory to the MATLAB path, and verify that required functions
resolve there. Do not add `NRFs/` to the MATLAB path; logical template names
are resolved directly against this repository.

The scripts contain editable Strasbourg root variables such as `baseDir`,
`root`, `local_base` or `PROJECT_ROOT`; the first source-inventory script also
contains the external source location. Set those declarations for the current
installation before running a stage. Run numbered scripts from the `scripts/`
folder using ordinary MATLAB script semantics. The workflow is staged and
includes deliberate manual inspection points; it is not a single batch
command.

## Functions

The repository contains the functions used by the Strasbourg workflow.
Important public entry points include:

- `preproc(EEG, options)` for rereferencing, resampling, filtering, line-noise
  handling, epoching and baseline correction;
- `add_offset_events` for the separate, explicit offset-event mechanism;
- `quality_control_features` and its 11 `calc_*` feature calculators;
- `estimate_response(EEG, options)` and `jittercorrect` for NRF estimation;
- `NRFUtils` for configuration, mapping, template resolution and fit caching;
- `validate_dataset_registry_paths` for fail-closed registry path and target
  validation;
- Curry/XDF conversion and event-reading functions;
- time-series averaging, NRF-overlay and paired-effect helpers; and
- diagnostics, plotting and save helpers used by the numbered scripts.

`preproc` intentionally does not create offset events. Step 3 first performs
continuous preprocessing, then calls `add_offset_events` under the configured
source-event, annotation and out-of-bounds policy, and finally calls `preproc`
again for epoching and baseline correction.

## NRF templates and configuration

`NRFs/` contains six tracked templates:

```text
early_NRF_500Hz.mat
early_NRF_2000Hz.mat
noxious_NRF_500Hz.mat
noxious_NRF_2000Hz.mat
noxious_preterm_NRF_500Hz.mat
noxious_preterm_NRF_2000Hz.mat
```

Every template MAT file contains `NRF` and `fs`. The template sampling rate
must exactly equal the EEG sampling rate; the estimator does not resample
templates.

`NRFs/nrf_config.ini` defines the profiles used by Step 4 NRF feature
extraction. Each profile has exactly six settings: `NRFName`,
`baselineLength`, `jitter`, `channel`, `projectionTimes_pre` and
`projectionTimes_post`. `NRFName` is a logical basename that resolves to the
matching file in this repository's `NRFs/` directory.

Exactly one projection start must be supplied per fit:

- `projectionTimes_pre` may be one finite scalar at or before 0 ms while the
  post value is empty; or
- `projectionTimes_post` may be one finite scalar at or after 0 ms while the
  pre value is empty.

Vectors, two starts, no start, nonfinite values and wrong-sign starts are
rejected before computation. The public estimator defaults to an empty pre
start and a post start of 400 ms. Estimator and plotting calls may also use an
explicit MAT-file path; outputs retain the validated logical basename as the
NRF identity and record the canonical file used as provenance.

## Workflow

Run scripts in numerical order, checking each script's user-editable settings
and expected inputs before execution.

### Step 1 — Strasbourg source preparation

Inventories the flat BrainVision source export, derives subject/session/run
identities, verifies the expected `.vhdr`, `.vmrk` and `.dat` triplets, and
copies complete triplets into the local `data/source/` tree. Review
`data_lists/dataset_list_prelim.xlsx` and its missing-file flags before the copy
stage.

### Step 2 — Strasbourg raw-data preparation

Loads the BrainVision recordings, inventories and maps event types, applies
user-completed event and channel filters, applies configured latency
corrections, and saves one-file EEGLAB datasets beneath `data/raw/`. The final
`data_lists/dataset_list.csv` contains `subjectID`, `sessionID`, `runID`,
`path_raw` and `EEGfile_raw` for recordings admitted to the framework.

Step 2.9 creates those five columns in that exact order. Two final Step 2
scripts are optional:

- `step_2_raw_10_pseudonymise_ids.m` preserves the complete original raw tree
  as private `data/raw_orig/`, builds a new active `data/raw/` containing the
  admitted recordings under replacement subject/session/run labels, and
  expands the private registry to the exact mapped core
  `subjectID_orig`, `sessionID_orig`, `runID_orig`, `subjectID`, `sessionID`,
  `runID`, `path_raw_orig`, `path_raw`, `EEGfile_raw_orig`, `EEGfile_raw`.
  Replacement labels preserve leading zeros and follow the recording
  hierarchy. The copied `.set` bytes are not altered by this script.
- `step_2_raw_11_sanitise_sets.m` may run only after Step 2.10. It sanitises
  identifier- and path-bearing metadata inside the active pseudonymised
  `.set` files while preserving the EEG signals and scientific metadata. It
  never changes `data/raw_orig/`.

Both transactions tolerate ordinary, singly linked `.DS_Store` files as
volatile macOS Finder metadata in `data/raw/` and `data/raw_orig/`. They do not
delete these files or treat them as EEG inputs; active-tree checks and the
`raw_orig` recovery digest ignore them. Links, hard links, and special objects
bearing that name remain unsafe; a directory bearing it receives no exemption.
Every other unexplained file or directory remains rejected, and the internal
transaction workspaces remain exact and fail-closed.

The supported routes are therefore: skip both scripts; run Step 2.10 only; or
run Step 2.10 followed by Step 2.11. Running Step 2.11 without Step 2.10 is
rejected. Both scripts are fail-closed transactions with restart recovery;
they run only immediately after Step 2.9 and before material Step 3-or-later
state, and they do not use the university server. `dataset_list.csv`,
`data/raw_orig/`, and an unsanitised Step-2.10-only `data/raw/` remain private
linkage material. Even sanitised replacement SETs remain governed,
pseudonymised research data and are not automatically suitable for sharing.
The replacement-ID route is pseudonymisation, not anonymisation.

Each EEG filename must be a basename with the exact lowercase `.set`
extension. Raw directories must be `data/raw` or descendants of it. Derived
processed and summary directories must likewise be under the exact
`data/processed` and `data/summary` roots. Paths must be non-empty
project-relative forward-slash paths: absolute paths, traversal components,
repeated separators, backslashes, path-like filenames and symlink-based canonical escapes
are rejected. Processed dataset targets and the four per-dataset summary
targets must be unique. Every registry path is validated before a governed write,
so an invalid row stops the stage before the registry, a dataset or a summary
output is changed.

Manual checkpoints include completing `Type_new` mappings, reviewing filter
fields and latency-correction flags, and checking the final event/channel
inventories.

### Steps 3–7 — SIMPLE framework

The middle block implements the five stages documented in `simple`:

| Strasbourg step | Framework step | Stage |
|---|---|---|
| Step 3 | Step 1 | processing and epoching (`proc`) |
| Step 4 | Step 2 | QC and NRF quantification (`quant`) |
| Step 5 | Step 3 | individual summaries and pooling (`sum`) |
| Step 6 | Step 4 | manual epoch-channel screening (`screen`) |
| Step 7 | Step 5 | post-screening checks (`check`) |

These scripts run from this repository. See the `simple` README for
detailed stage inputs, outputs, rationale, manual checkpoints and operating
rules.

Step 3 preprocesses continuous recordings, removes unwanted events, adds
configured offset or internal-reference events, and performs epoching and
baseline correction. Step 4 calculates per-event/channel QC features and NRF
fits. Step 5 creates individual and pooled summaries. Step 6 creates the fixed
screening package, records manual decisions and applies them to pooled outputs.
Step 7 provides display and machine-readable checks of the screened results.

The Strasbourg settings use `cannula` and `cannula_prestim` epochs at `Cz`, a
200 ms pre-event and 1200 ms post-event epoch, and the configured preterm NRF
route. Review these settings against the intended execution before running the
dependent scripts.

### Step 8 — General manuscript output

`step_8_gen_1_check_plots.m` creates the fixed post-core guardrail Figure 6
under `data/results/` and leaves the corresponding MATLAB figure, configuration,
calculated panel data and graphics handles in the workspace for inspection. It
loads the screened pooled epochs and the saved Step 7.6/7.7 separation results,
then writes
`figure_6_post_core_guardrails_in_the_noci_prem_dataset.pdf` as a vector PDF.

The figure has four rows and two columns: recording-level average time series,
time-frequency and PSD panels for `cannula_prestim` and `cannula`, followed by
the saved QC and preterm-noxious-NRF feature-separation checks. The first three
rows use the active Strasbourg Step 7.3--7.5 settings, including the configured
preterm NRF overlay. The final row validates and plots the saved schema-v2 Step
7 results without rerunning their bootstrap or changing the caller's random-
number-generator state. Step 8 does not aggregate recordings within participant.
It does not call a Step 7 script or prepare a JASP file.

The script starts a fresh exact-name Command Window log before clearing the
Command Window, validates all inputs before creating its scientific target,
and replaces only its own PDF transactionally. A rejected run may create or
replace only `data/logs/step_8_gen_1_check_plots.log`; it removes its transient
PDF paths and preserves any prior accepted PDF and unrelated results.

## User decisions and scientific boundaries

Review enabled and disabled user options rather than assuming the checked-in
settings are appropriate for another execution. In particular, confirm source
paths, event mappings, channels, sampling rates, filters, epoch and baseline
windows, NRF profiles, screening settings, exclusion handling and Step 8 plot
settings.

The core processing unit is one analysed event-channel instance. NOCI-Prem
recordings remain separate through Steps 1–8, including the Figure 6 guardrail
display. This descriptive manuscript figure does not perform group-level
inference. Any later group-level inference requires one prespecified
participant-level contribution or an analysis that accounts for repeated
observations.

Source data, manual screening, figures and final statistical interpretation
remain human-reviewed scientific inputs. A successful script or regression
test establishes technical behaviour; it does not replace those decisions.

## Tests

`tests/run_all_tests.m` uses synthetic EEG fixtures only. It exercises the
preprocessing, response, jitter and QC contracts, all six bundled templates,
registry paths, the optional Step 2 identity and `.set`-sanitisation
transactions, effective preprocessing provenance, stale-NRF clearing, path
precedence, local template binding, the Step 8 guardrail-figure transaction,
and the public APIs in the verified MATLAB/EEGLAB environment. It does not read
project datasets or run a numbered workflow script against repository data.

From MATLAB, call the runner with explicit roots:

```matlab
addpath(fullfile(strasbourgRoot, 'tests'), '-begin');
results = run_all_tests(strasbourgRoot, eeglabRoot);
assert(results.passed);
```

The static repository checks can be run from the checkout root:

```sh
./tests/run_static_checks.sh
```

## License

This repository is licensed under the Apache License 2.0. See `LICENSE`.
