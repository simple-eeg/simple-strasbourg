# SIMPLE Strasbourg

SIMPLE Strasbourg is the MATLAB/EEGLAB workflow for the NOCI-Prem neonatal EEG
dataset supplied by the Strasbourg collaborators. It prepares BrainVision
recordings, runs SIMPLE (Single-event Measurement Pipeline for EEG), and
creates the study's post-screening descriptive-check figure.

**Software credits:** [Marianne van der Vaart](https://github.com/mvandervaart), [Simon Marchant](https://github.com/simonmarchant), and [Luke Baxter](https://github.com/lukebax) contributed equally to the development of this software.

Associated methods paper: citation and link to be added when available.

## Start here

This repository contains the code and templates for the NOCI-Prem workflow;
the clinical recordings and study spreadsheets are not included. Running the
workflow requires access to those inputs and familiarity with MATLAB and
EEGLAB.

- **New to SIMPLE?** Start with the [framework guide](https://github.com/simple-eeg/simple#start-here).
- **Want to try the workflow without clinical data?** Follow the [synthetic tutorial](https://github.com/simple-eeg/simple#synthetic-tutorial), which uses the [synthetic EEG generator](https://github.com/simple-eeg/simple-synthetic-eeg-generator).
- **Working with the Strasbourg data?** Follow [setup](#before-you-begin) and the [workflow](#workflow) below. This repository contains its own functions and scripts; a separate `simple` checkout is not required.
- **Checking an option or file format?** See the [technical reference](#technical-reference).

An *epoch* is a segment of EEG around an event. SIMPLE calculates
quality-control (QC) features and fits neurodynamic response functions (NRFs)
to these segments. Screening reviews one event on one channel at a time,
using its waveform and QC evidence. Internal-reference epochs provide nearby
EEG segments for comparison with true-event epochs.

## Before you begin

### Software

The verified environment is MATLAB R2026a Update 4 with EEGLAB 2026.0.0.
Required functionality includes:

- Statistics and Machine Learning Toolbox operations such as `corr`,
  `robustfit`, and `fitlm`;
- Econometrics Toolbox `fgls`;
- Signal Processing Toolbox operations used by filtering and spectral checks;
- Wavelet Toolbox for the time-frequency check; and
- BrainVision import support providing `pop_loadbv`.

CleanLine is optional. Preprocessing uses it when selected and otherwise uses
the configured notch-filter route.

### Local setup

1. Download or clone this repository to a local folder.
2. In MATLAB, make EEGLAB available and open the repository's `scripts/`
   folder. Replace both example paths below with your local paths:

   ```matlab
   strasbourgRoot = '/path/to/simple-strasbourg';
   eeglabRoot = '/path/to/eeglab';
   addpath(eeglabRoot);
   cd(fullfile(strasbourgRoot, 'scripts'));
   ```

3. Before running each script, set its project-root variable to your checkout.
   These variables have names such as `baseDir`, `root`, `local_base`, or
   `PROJECT_ROOT`; setting the variable above does not update them.
4. In Step 1.1, replace the `remote_base` placeholder in your local copy with
   the approved BrainVision export folder. Keep this private path out of Git.
5. Review each script's settings and inputs, then run the numbered scripts
   in numerical order, pausing at the manual checkpoints below.

The steps that need EEGLAB start it themselves. Scripts that use repository
helpers put this checkout's `functions/` directory first on the MATLAB path
and check which helpers are loaded. Do not add `NRFs/` to the MATLAB path;
templates are loaded directly from this repository.

Review both enabled and disabled options before using the workflow for a new
analysis. Check source paths, event mappings, channels, sampling rates,
filters, epoch and baseline windows, NRF profiles, screening settings,
exclusion handling, and plot settings. The checked-in choices describe this
workflow; they are not automatically appropriate for other data.

## Workflow

### Step 1 — Prepare the Strasbourg source data

Steps 1.1–1.3 list the flat BrainVision source export, derive subject, session,
and run identities, check the expected `.vhdr`, `.vmrk`, and `.dat` file
triplets, and copy complete triplets into `data/source/`.

After Step 1.2, review `data_lists/dataset_list_prelim.xlsx` and its
missing-file flags before running the Step 1.3 copy stage.

### Step 2 — Prepare the raw EEGLAB datasets

Steps 2.1–2.9 load the BrainVision recordings, map event types, apply the
chosen event and channel filters and latency corrections, and save one-file
EEGLAB datasets beneath `data/raw/`. Step 2.9 creates
`data_lists/dataset_list.csv` for the admitted recordings, with these five
columns in order: `subjectID`, `sessionID`, `runID`, `path_raw`, and
`EEGfile_raw`.

Pause for the following checks. The **event mapping CSV** is
`data/info_prelim/event_types_original/event_types_original_summary.csv`,
created by Step 2.1. The **channel summary CSV** is
`data/info_prelim/channels/channel_summary.csv`, created by Step 2.7.

| Before running | File or setting | What to review or complete |
| --- | --- | --- |
| Step 2.2 | Event mapping CSV | Choose any event filters using `Filter_AND`, `Filter_OR`, and `Filter_NOT`. Empty filter columns impose no restriction. |
| Step 2.4 | Event mapping CSV | Complete the `Type_new` mappings. At least one must be populated; a blank mapping becomes `NA`. |
| Step 2.5 | Event mapping CSV, `data_lists/dataset_list_prelim.xlsx`, and the script's `CORRECTION_MS` setting | If latency correction is required, mark the relevant original event types with `LatencyCorrect = 1` and the relevant recordings with `latency_correct = 1`, and check the correction size. |
| Step 2.8 | Channel summary CSV | Review the channel inventory and choose any `Filter_AND`, `Filter_OR`, and `Filter_NOT` rules. |
| Step 2.9 | Standardised event and channel inventories, and `data_lists/dataset_list_prelim.xlsx` | Check the resulting mappings, filters, and recording exclusions before creating the final dataset list. |

For both event and channel filters, AND requires all marked entries to be
present, OR requires at least one, and NOT requires none. An OR rule needs
at least two marked entries; use AND for a single required entry.
Rerunning Step 2.1 or Step 2.7
recreates its summary CSV with blank editable columns, so preserve any
reviewed mappings or filter choices before doing so.

#### Optional replacement identifiers and metadata cleanup

Immediately after Step 2.9, choose one of three routes:

- Skip both optional scripts and retain the original identifiers.
- Run `step_2_raw_10_pseudonymise_ids.m` to create replacement subject,
  session, and run labels while preserving the original raw tree privately.
- Run Step 2.10, then `step_2_raw_11_sanitise_sets.m` to remove identifying
  metadata from the active replacement-ID files while preserving EEG signals
  and scientific metadata.

Step 2.11 cannot run without Step 2.10. Both scripts must run before Step 3 or
later stages have created downstream state. They stop if their checks fail,
can recover from recognised interruptions, and do not use the university
server. See [the identity reference](#optional-identity-files-and-recovery)
for the exact file and recovery rules.

These routes provide pseudonymisation, not anonymisation. The dataset list,
original raw files, and replacement-ID files that have not been sanitised
remain private linkage material. Even sanitised files remain governed
research data and are not automatically suitable for sharing.

### Steps 3–7 — Process, quantify, summarise, screen, and check

These stages implement the shared SIMPLE workflow using this repository's
scripts. The [core workflow reference](https://github.com/simple-eeg/simple#workflow-reference)
explains their inputs, outputs, manual checkpoints, and operating rules.
Software stages group operations differently from the five scientific steps
in the methods paper.

| Strasbourg step | Core software step | Stage |
| --- | --- | --- |
| Step 3 | Step 1 | Processing and epoching (`proc`) |
| Step 4 | Step 2 | QC and NRF quantification (`quant`) |
| Step 5 | Step 3 | Individual summaries and pooling (`sum`) |
| Step 6 | Step 4 | Manual epoch-channel screening (`screen`) |
| Step 7 | Step 5 | Post-screening checks (`check`) |

Step 3 preprocesses continuous recordings, removes unwanted events, adds
configured offset or internal-reference events, and performs epoching and
baseline correction. Step 4 calculates per-event/channel QC features and NRF
fits. Step 5 creates individual and pooled summaries. Step 6 creates a fixed
screening package, records manual decisions, and applies them to pooled
outputs. Step 7 provides descriptive displays and machine-readable checks
without changing those decisions.

**NOCI-Prem NRF mapping:** Step 3 prepares `cannula` and `cannula_prestim`
epochs at `Cz` from −200 to 1200 ms at 500 Hz. Step 4.2 writes
`data/info/epoch_types/epoch_type_summary.csv` with blank NRF columns.
Before running Step 4.3, enter `prem_foot_nox` in the `noxious_preterm_NRF`
column for both epoch types. Leave the other two NRF columns blank.

**Screening:** review each item using its waveform and QC evidence; keep NRF
magnitudes and downstream group or outcome information out of screening
decisions. True-event and internal-reference items receive separate statuses.
The Step 6.2 viewer's `File > Save PDF...` command saves the complete current
display, including all plots and the Navigator, to a location you choose.
Exporting a snapshot does not change the screening decisions.

### Step 8 — General manuscript output

`step_8_gen_1_check_plots.m` creates Figure 3b, the NOCI-Prem post-screening
descriptive checks. It loads the screened pooled epochs and the saved Step 7.7
NRF separation result, then writes
`figure_3b_post_screening_descriptive_checks_noci_prem.pdf` as a vector PDF
under `data/results/`.
The MATLAB figure, configuration, calculated panel data, and graphics handles
remain in the workspace for inspection.

The figure has seven panels across four rows. The first three rows show
recording-level average time-series, time-frequency, and power spectral
density (PSD) plots, with `cannula` true events on the left and
`cannula_prestim` internal references on the right. They use the active
Strasbourg Step 7.3–7.5 settings, including the configured preterm NRF (p-NRF)
overlay. The final row shows p-NRF magnitudes and paired differences in µV.

Step 8 plots the saved NRF comparison without rerunning its bootstrap or
changing the caller's random-number-generator state. The QC comparison result
is not required. It does not call a Step 7 script or prepare a JASP file. Inputs are
validated before the PDF is replaced; a rejected run preserves the previous
accepted PDF and unrelated results. See [figure output handling](#figure-output-handling)
for the exact log and file behaviour.

### Interpreting the outputs

NOCI-Prem recordings remain separate through Steps 1–8, including Figure 3b;
the workflow does not aggregate recordings within participant. This figure
provides descriptive checks, not group-level inference. Any later group-level
inference requires one prespecified participant-level contribution or an
analysis that accounts for repeated observations.

Source data, manual screening, figures, and statistical interpretation require
human review. A successful script or test establishes technical behaviour;
it does not replace those scientific decisions.

## Technical reference

### Repository layout and local files

```text
simple-strasbourg/
├── data/                 local inputs, intermediate files, outputs, and logs
├── data_lists/           local dataset lists and study spreadsheets
├── functions/            MATLAB functions used by the workflow
├── NRFs/                 bundled NRF templates and nrf_config.ini
├── scripts/              numbered workflow scripts and the logging helper
├── tests/                synthetic regression fixtures and test runners
├── .gitignore
├── LICENSE
└── README.md
```

`data/` and `data_lists/` contain tracked `.gitkeep` placeholders in a fresh
checkout. All runtime files and subdirectories under `data/` are local and
ignored by Git. CSV and XLSX files anywhere beneath `data_lists/` are also
ignored. Do not put data files in version control.

Each numbered script writes its Command Window diary to `data/logs/`. A run
replaces the existing log for that script, and all logs are ignored by Git.

### Dataset paths

Each EEG filename must be a filename alone, with the exact lowercase `.set`
extension. Raw directories must be `data/raw` or its descendants. Derived
processed and summary directories must likewise be under the exact
`data/processed` and `data/summary` roots.

Paths must be non-empty, relative to the project, and use forward slashes.
Absolute paths, traversal components such as `..`, repeated separators,
backslashes, paths in filename fields, and symbolic links that resolve outside
the permitted roots are rejected. Processed dataset targets and the four
per-dataset summary targets must be unique.
Every registry path is validated before a governed write: an invalid row
stops the stage before the registry, a
dataset, or a summary output changes.

### Optional identity files and recovery

Step 2.10 preserves the complete original `data/raw/` tree as private
`data/raw_orig/` and builds a new active `data/raw/` containing the admitted
recordings under replacement labels. The labels preserve leading zeros and
follow the recording hierarchy. The copied `.set` bytes are unchanged.
The private dataset registry expands to this exact ten-column core:

```text
subjectID_orig, sessionID_orig, runID_orig, subjectID, sessionID,
runID, path_raw_orig, path_raw, EEGfile_raw_orig, EEGfile_raw
```

Step 2.11 sanitises identifier- and path-bearing metadata inside the active
pseudonymised `.set` files. It preserves the EEG signals and scientific
metadata and never changes `data/raw_orig/`.

Both operations tolerate ordinary, singly linked `.DS_Store` files as
temporary macOS Finder metadata in `data/raw/` and `data/raw_orig/`. They do
not delete these files or treat them as EEG inputs. Active-tree checks and
the digest used to verify `raw_orig` recovery ignore them. Symbolic links,
hard links, and special filesystem objects with that name remain unsafe;
a directory named `.DS_Store` receives no exemption. All other unexplained
files or directories are rejected. The temporary directories used by the
operations must match their expected contents exactly; a mismatch stops the
operation.

### NRF templates and configuration

`NRFs/` contains three templates at 500 Hz:

```text
early_NRF_500Hz.mat
noxious_NRF_500Hz.mat
noxious_preterm_NRF_500Hz.mat
```

Each MAT file stores a real double column vector `NRF` and scalar `fs = 500`.
Each stored NRF has mean zero and discrete L2 norm one within floating-point
precision. The dimensionless template gives its signed fitted coefficient
the EEG input's unit; that coefficient is not a peak EEG amplitude. The
template and EEG sampling rates must match exactly; the estimator does not
resample templates.

[`NRFs/nrf_config.ini`](NRFs/nrf_config.ini) defines the profiles used by
Step 4.3. A profile is a named set of six fitting settings: `NRFName`,
`baselineLength`, `jitter`, `channel`, `projectionTimes_pre`, and
`projectionTimes_post`. `NRFName` is the template's basename, resolved to the
matching file in this repository's `NRFs/` directory.

Exactly one projection start must be supplied per fit:

- `projectionTimes_pre` may be one finite scalar at or before 0 ms while the
  post value is empty; or
- `projectionTimes_post` may be one finite scalar at or after 0 ms while the
  pre value is empty.

Vectors, two starts, no start, nonfinite values, and wrong-sign starts are
rejected before computation. The public estimator defaults to an empty pre
start and a post start of 400 ms. Estimator and plotting calls may also use an
explicit MAT-file path; outputs retain the validated basename as the NRF
identity and record the resolved file used.

The preterm template has 501 samples. Before jitter alignment, its first and
last fitted samples are at 0 and 1000 ms relative to each event; the 1002 ms
boundary is excluded. With ±100 ms jitter, the fit requires samples from
−100 through 1100 ms, in addition to the pre-event baseline.

### Functions

The repository supplies the functions used by its scripts. See their opening
comments for function-specific help. Entry points include:

- `preproc(EEG, options)` for rereferencing, resampling, filtering, line-noise
  handling, epoching, and baseline correction;
- `add_offset_events` for adding events at a specified offset from source events;
- `quality_control_features` and its 11 `calc_*` feature calculators;
- `estimate_response(EEG, options)` and `jittercorrect` for NRF estimation;
- `NRFUtils` for configuration, mapping, template resolution, and fit caching;
- `validate_dataset_registry_paths` for checking registry paths and output targets;
- Curry/XDF conversion and event-reading functions;
- time-series averaging, NRF-overlay, and paired-effect helpers; and
- diagnostics, plotting, and save helpers used by the numbered scripts.

`preproc` does not create offset events. Step 3 first performs continuous
preprocessing, then calls `add_offset_events` with the configured source-event,
annotation, and out-of-bounds policy, and finally calls `preproc` again for
epoching and baseline correction.

### Figure output handling

Step 8 validates and plots the saved schema-v2 Step 7.7 NRF result. It starts
`data/logs/step_8_gen_1_check_plots.log` before clearing the Command Window,
validates all inputs before creating the figure PDF, and replaces only its
own PDF after successful completion. A rejected run may create or replace
only that log. It removes temporary PDF paths and preserves any previous
accepted PDF and unrelated results.

## Tests

[`tests/run_all_tests.m`](tests/run_all_tests.m) checks the workflow's technical
behaviour using synthetic EEG fixtures. It does not read project datasets or
run a numbered workflow script against repository data.

The suite covers preprocessing, response estimation, jitter alignment, QC,
and all three bundled templates. It also checks dataset paths, optional
identifier replacement and metadata sanitisation, recorded preprocessing
settings, removal of obsolete NRF results, use of the correct functions and
local templates, Step 8 figure replacement, and the public APIs in the
verified MATLAB/EEGLAB environment.

In MATLAB, set `strasbourgRoot` to this checkout and `eeglabRoot` to your
EEGLAB installation, then call the runner:

```matlab
addpath(fullfile(strasbourgRoot, 'tests'), '-begin');
results = run_all_tests(strasbourgRoot, eeglabRoot);
assert(results.passed);
```

For static source checks, run the following in a terminal from the checkout
root:

```sh
./tests/run_static_checks.sh
```

## License

This repository is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
