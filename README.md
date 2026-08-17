# SIMPLE Strasbourg

SIMPLE Strasbourg is the MATLAB/EEGLAB workflow for the NOCI-Prem neonatal EEG
dataset supplied by the Strasbourg collaborators. It covers BrainVision source
preparation, the complete SIMPLE EEG workflow, and Strasbourg-specific
subject-level export.

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

### Step 8 — Strasbourg analysis export

`step_8_jasp_1_data_prep_eeg.m` reads the screened pooled QC and NRF tables and
uses the BrainVision marker files to establish recording chronology. It writes:

- `data/jasp/jasp_data_eeg.csv`, containing the earliest timestamped cannula
  recording selected for each subject before screening flags are consulted;
- `data/jasp/jasp_data_eeg_median.csv`, containing the within-subject median of
  complete recording pairs for which both `cannula` and `cannula_prestim` are
  retained; and
- `data/jasp/jasp_selection_manifest.csv`, recording chronology, selection,
  screening and contribution provenance for both routes.

The earliest-recording route does not substitute a later recording when the
selected true-event epoch is excluded. The median route uses one common set of
complete retained recording pairs for all four analytical values. Step 8
creates CSV files only; it does not create or execute a JASP archive.

## User decisions and scientific boundaries

Review enabled and disabled user options rather than assuming the checked-in
settings are appropriate for another execution. In particular, confirm source
paths, event mappings, channels, sampling rates, filters, epoch and baseline
windows, NRF profiles, screening settings, exclusion handling and Step 8
selection rules.

The core processing unit is one analysed event-channel instance. NOCI-Prem
recordings remain separate through Steps 1–7. The selected within-subject
median is introduced only by its Step 8 export; it does not alter an earlier
framework input, screening unit or output. Group-level inference requires one
prespecified participant-level contribution or an analysis that accounts for
repeated observations.

Source data, manual screening, figures and final statistical interpretation
remain human-reviewed scientific inputs. A successful script or regression
test establishes technical behaviour; it does not replace those decisions.

## Tests

`tests/run_all_tests.m` uses synthetic EEG fixtures only. It exercises the
preprocessing, response, jitter and QC contracts, all six bundled templates,
registry paths, effective preprocessing provenance, stale-NRF clearing, path
precedence, local template binding and the public APIs in the verified
MATLAB/EEGLAB environment. It does not read project datasets or run a numbered
workflow script.

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
