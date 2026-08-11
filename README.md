# simple-strasbourg

A MATLAB/EEGLAB workflow for taking Strasbourg BrainVision recordings through source preparation, raw `.set` creation, SIMPLE processing and quantification, screening, post-screening checks, and subject-level CSV export.

## Repository overview

This repository contains the complete Strasbourg-specific workflow. It is organised into three practical blocks:

1. **Strasbourg source and raw-data preparation (Steps 1–2)**
   - inventory and validate BrainVision source files
   - copy complete BrainVision triplets into a local source tree
   - inspect, filter, and standardise events and channels
   - create framework-ready EEGLAB `.set` files and `dataset_list.csv`
2. **Embedded SIMPLE framework workflow (Steps 3–7)**
   - process and epoch the prepared recordings
   - extract quality-control (QC) and neurodynamic response function (NRF) quantities
   - summarise and pool outputs
   - screen epoch–channel items
   - perform post-screening checks
3. **Strasbourg-specific export (Step 8)**
   - create an earliest-recording subject-level table
   - create a within-subject-median table
   - create an audit manifest describing both routes

Run dependency-bearing stages in numerical order, with explicit inspection and editing checkpoints between some scripts. The Step 7 checks are individually configured diagnostics rather than inputs consumed by Step 8.

## What this repository is for

This repository is for:

- preparing the Strasbourg BrainVision recordings for the SIMPLE workflow
- running the SIMPLE workflow locally on those prepared recordings
- preserving explicit intermediate inventories, summaries, screening decisions, and logs
- exporting screened QC and NRF measures into two alternative subject-level CSV layouts
- retaining an audit manifest for the Step 8 selection and aggregation rules

## What this repository is not for

This repository is not intended to be:

- a general-purpose EEG toolbox
- a substitute for the reusable functions in the `simple` EEGLAB plugin
- the primary location for detailed documentation of the common framework internals
- a one-click workflow with no user judgement or inspection points
- a JASP analysis repository

## Relationship to the other SIMPLE repositories

### How `simple-strasbourg` relates to `simple-framework`

`simple-framework` documents the reusable five-stage framework workflow. In `simple-strasbourg`, that framework is embedded as the middle block of a broader dataset-specific pipeline.

The numbering maps as follows:

- `simple-strasbourg` Step 3 = `simple-framework` Step 1 (`proc`)
- `simple-strasbourg` Step 4 = `simple-framework` Step 2 (`quant`)
- `simple-strasbourg` Step 5 = `simple-framework` Step 3 (`sum`)
- `simple-strasbourg` Step 6 = `simple-framework` Step 4 (`screen`)
- `simple-strasbourg` Step 7 = `simple-framework` Step 5 (`check`)

The Step 3–7 scripts themselves live and run in `simple-strasbourg`. The `simple-framework` repository supplies detailed documentation of the common stages; it is a documentation reference and is not imported at runtime.

### How `simple-strasbourg` differs from `simple-framework`

`simple-strasbourg` is broader in scope. Before the framework block, Steps 1–2 prepare BrainVision source recordings and create EEGLAB raw datasets. After the framework block, Step 8 creates Strasbourg-specific CSV exports.

`simple-framework` begins from already prepared EEGLAB raw datasets and an appropriate `dataset_list.csv`. It is therefore the clearer standalone representation of the framework itself.

### How `simple-strasbourg` relates to `simple`

`simple` is an EEGLAB plugin containing reusable processing, QC, and NRF functions. The local Strasbourg scripts call plugin functions such as `pop_preproc`, `quality_control_features`, and `pop_estimate_response` as part of the wider workflow.

## How to approach this repository

Treat this repository as a staged workflow with deliberate hand-offs:

1. inventory and copy complete source-file triplets
2. inspect and standardise source metadata while creating raw `.set` files
3. run the embedded framework block on the prepared inputs
4. create the Step 8 CSV exports from screened framework outputs

Before running the scripts, read:

- **Before you begin**
- **Workflow stages in this repository**
- **Points where user input or inspection is required**
- **Steps 3–7: embedded framework workflow**
- **Step 8: subject-level CSV export**

The common framework stages are summarised here in their Strasbourg context. Their detailed operational documentation is kept in the `simple-framework` README.

## Repository structure

Data, logs, generated outputs, screening decisions, and downstream analysis files are local working materials excluded from version control; a fresh clone contains the workflow code, tracked configuration, and documentation only.

### `data_lists/`

Tracked configuration and local workflow inventories.

The tracked file is:

- `nrf_config.ini`, which defines NRF fitting profiles used during Step 4

The generated `dataset_list_prelim.xlsx` and `dataset_list.csv` files are local working materials and are excluded from version control.

### `functions/`

MATLAB helper functions used by the runnable scripts, including environment setup, event operations, NRF utilities, and time-series averaging and overlay helpers.

### `scripts/`

Runnable MATLAB scripts organised into Steps 1–8.

This folder also contains `log_command_window.m`, which writes per-script Command Window logs.

### Generated `data/` tree

The scripts create and use local data folders including:

- `data/source/` for copied BrainVision source triplets
- `data/raw/` for framework-ready EEGLAB `.set` files
- `data/info_prelim/` for source and raw-preparation inventories
- `data/info/` for framework-stage inventories
- `data/processed/` for processed datasets
- `data/summary/` for individual, pooled, screening, and checking outputs
- `data/jasp/` for the three Step 8 CSV exports

The entire generated `data/` tree is excluded from version control.

### Generated `logs/`

Per-script Command Window logs written by `log_command_window.m`. The `logs/` folder is excluded from version control.

### `LICENSE`

The repository is distributed under the tracked Apache License 2.0.

## Before you begin

### Software requirements

The tracked code assumes access to:

- **MATLAB**
- **EEGLAB**
- BrainVision I/O support providing `pop_loadbv`
- the **SIMPLE** EEGLAB plugin
- the **Signal Processing Toolbox** for `pmtm`-based plots
- the **Wavelet Toolbox** for continuous-wavelet time–frequency plots
- the **Statistics and Machine Learning Toolbox** for effect-size and regression utilities used by checking and plotting code

No software-version lock is tracked in this repository. Requirements vary by stage, so review the functions called by the scripts you intend to run.

JASP can consume the generated Step 8 CSV files, but it is not required to execute the MATLAB workflow. Step 8 does not create or run a `.jasp` file.

### Expected source data

Step 1 expects BrainVision recordings supplied as matching `.vhdr`, `.vmrk`, and `.dat` triplets. The workflow first inventories a flat source export, then copies complete triplets into a local subject/session EEG tree while preserving the source filenames and their internal BrainVision links.

### Path setup

The runnable scripts define local project roots within the scripts, and the first source-inventory script also defines an external source location. Review those path variables before running any stage. Do not assume that paths from another installation will apply to a new clone.

### Running the scripts

Run dependency-bearing stages in numerical order. Configure and run the Step 7 checks needed for the execution; Step 8 reads the screened Step 6 outputs and source marker files rather than saved Step 7 plots or check results. It is recommended to run scripts from the `scripts/` folder, or otherwise ensure that folder and the required helper/plugin functions are on the MATLAB path.

Several scripts depend on user-reviewed files created by an earlier script. Do not run straight through a documented checkpoint without inspecting or completing the generated fields.

### Logging

The runnable scripts use `log_command_window('start')` and `log_command_window('stop')` to create per-script logs in `logs/`. These logs are local generated outputs and should be retained with the dataset-specific working materials when an execution needs to be audited.

## High-level workflow

```text
BrainVision source export
        |
        v
Step 1: source inventory, validation, and local source tree
        |
        v
Step 2: event/channel review and framework-ready raw .set files
        |
        v
Steps 3–7: embedded SIMPLE framework
        |
        v
Step 8: earliest-recording export, median export, and manifest
```

## Workflow stages in this repository

| Repository step | Prefix | Role |
|---|---|---|
| Step 1 | `step_1_source_*` | Inventory, validate, and copy BrainVision source files |
| Step 2 | `step_2_raw_*` | Standardise events/channels and create raw EEGLAB datasets |
| Step 3 | `step_3_proc_*` | Process and epoch prepared datasets |
| Step 4 | `step_4_quant_*` | Extract QC and NRF quantities |
| Step 5 | `step_5_sum_*` | Summarise and pool outputs |
| Step 6 | `step_6_screen_*` | Create, complete, and apply explicit screening |
| Step 7 | `step_7_check_*` | Inspect screened data and run post-screening checks |
| Step 8 | `step_8_jasp_*` | Create two subject-level data CSVs and an audit manifest |

## Step 1: Strasbourg source preparation

Step 1 inventories the external BrainVision export, verifies each expected file triplet, and creates the local source tree.

### Scripts

#### `step_1_source_1_create_dataset_list_prelim.m`

- scans the configured flat source folder for `.vhdr` files
- derives `subjectID`, `sessionID`, and `runID` values from the source filenames
- predicts the corresponding `.vmrk` and `.dat` filenames
- writes `data_lists/dataset_list_prelim.xlsx`
- does not copy files or yet validate the predicted sidecars

#### `step_1_source_2_find_missing.m`

- reads the preliminary inventory
- checks whether the `.vhdr`, `.vmrk`, and `.dat` files exist for each row
- adds or refreshes the file-specific missing flags
- overwrites the preliminary inventory with those checks

#### `step_1_source_3_create_source.m`

- reads the checked preliminary inventory
- creates a subject/session EEG tree under `data/source/`
- copies only complete `.vhdr`/`.vmrk`/`.dat` triplets
- preserves source filenames and same-directory placement for existing BrainVision file references
- supports file-level restart after interruption by retaining final files, deleting stale local `.partial` files, and recopying absent final files

### Manual checkpoint

Inspect `dataset_list_prelim.xlsx` and its missing-file flags before creating the source tree. Resolve unexpected inventory or sidecar problems before continuing.

### Main outputs

- `data_lists/dataset_list_prelim.xlsx`
- copied BrainVision triplets under `data/source/`
- a Command Window log for each script

## Step 2: Strasbourg raw-data preparation

Step 2 turns the copied BrainVision source recordings into standardised EEGLAB `.set` files and creates the five-column dataset list required by the embedded framework.

### Scripts

#### `step_2_raw_1_get_original_events.m`

- loads each usable BrainVision recording with `pop_loadbv`
- inventories every original event type per recording and across recordings
- adds per-recording event information to the preliminary dataset list
- creates a global event summary with user-editable `Type_new`, event-filter, and latency-correction fields

#### `step_2_raw_2_filter_events.m`

- applies the user-completed `Filter_AND`, `Filter_OR`, and `Filter_NOT` rules
- records whether each dataset satisfies the configured event requirements

#### `step_2_raw_3_add_reformats.m`

- combines missing-file and event-filter outcomes into an upstream dataset-exclusion field
- derives standardised `.set` filenames
- derives project-relative `data/raw/` destination paths

#### `step_2_raw_4_create_raw.m`

- loads each included BrainVision recording
- preserves the original event type in `EEG.event.urtype`
- maps original types to the user-completed `Type_new` values
- maps a blank `Type_new` value to `NA`
- saves a one-file EEGLAB `.set` dataset under `data/raw/`

#### `step_2_raw_5_adjust_latencies.m`

- reads the dataset- and event-level latency-correction flags created earlier
- applies the script's configured fixed time shift only where both levels request it
- checks existing event-latency provenance before overwriting an affected `.set` file
- records original latencies for later provenance checks

Review the script's correction value and the generated flags before running it.

#### `step_2_raw_6_get_standardised_events.m`

- inventories the resulting standardised `EEG.event.type` values
- writes per-recording and global summaries
- updates the preliminary dataset list

#### `step_2_raw_7_get_channels.m`

- inventories channel labels in the included raw datasets
- writes per-recording and global channel summaries
- creates user-editable channel-filter fields

#### `step_2_raw_8_filter_channels.m`

- applies the user-completed channel `Filter_AND`, `Filter_OR`, and `Filter_NOT` rules
- records the resulting channel-based exclusion status

#### `step_2_raw_9_create_dataset_list.m`

- validates the upstream dataset- and channel-exclusion fields
- keeps only rows that pass both sets of criteria
- validates nonblank inputs and unique subject/session/run keys
- writes `data_lists/dataset_list.csv` with:
  - `subjectID`
  - `sessionID`
  - `runID`
  - `path_raw`
  - `EEGfile_raw`

### Manual checkpoints

After `step_2_raw_1_get_original_events.m`:

- inspect the original-event inventories
- complete and review the `Type_new` mappings
- complete and review any event-filter rules
- complete and review any latency-correction flags before running dependent scripts

After `step_2_raw_7_get_channels.m`:

- inspect the channel inventories
- complete and review any channel-filter rules before applying them

### Output handed forward to the framework

By the end of Step 2, the repository is expected to have produced:

- raw EEGLAB `.set` files under `data/raw/`
- a final `data_lists/dataset_list.csv`
- standardised event types in those raw datasets
- the filtered set of recordings that the framework scripts will process

This is the hand-off from Strasbourg-specific data preparation to the embedded framework block.

## Steps 3–7: embedded framework workflow

Steps 3–7 are the local Strasbourg implementation of the same five stages documented in `simple-framework`.

### Step 3: processing (`proc`)

Corresponds to `simple-framework` Step 1.

The scripts:

- inventory raw event types and channel labels
- add processed filenames and paths to `dataset_list.csv`
- preprocess the continuous datasets
- create the configured offset/internal-reference events
- epoch and baseline the data

### Step 4: quantification (`quant`)

Corresponds to `simple-framework` Step 2.

The scripts:

- extract configured QC features
- inventory epoch types and multi-event epochs
- use the tracked `nrf_config.ini` profiles to extract NRF quantities

After the epoch inventory is generated, review and complete its NRF-profile mapping before running NRF extraction.

### Step 5: summarisation and pooling (`sum`)

Corresponds to `simple-framework` Step 3.

The scripts:

- add summary paths
- write individual QC, NRF, and epoch summaries
- concatenate those summaries into pooled outputs
- optionally display pooled epoch plots for inspection

### Step 6: screening (`screen`)

Corresponds to `simple-framework` Step 4.

The scripts:

- create a self-contained screening package
- support manual rating of epoch–channel items in the screening viewer
- apply the resulting decisions to pooled epoch, QC, and NRF outputs

The package-creation script refuses to overwrite an existing screening package. Keep the package fixed and treat the separate decisions file as the mutable screening record.

### Step 7: post-screening checks (`check`)

Corresponds to `simple-framework` Step 5.

The scripts:

- save a rollback-safe, verified PNG batch for excluded epoch–channel items
- display retained epoch–channel items, with strict screening and requested-NRF-overlay coherence checks
- display Simple, NRF-shifted, or Woody group time series and configurable time–frequency and power-spectral-density views
- perform paired QC and NRF separation checks at the recording–channel key defined by subject, session, run, and channel
- atomically save each paired separation result, its exact ordered within-pair differences, bootstrap settings, and source identities using schema `simple-paired-separation-result-v2`

The group time-series script keeps recording-level contributions and offers mean or median aggregation with optional smoothing. Its Strasbourg defaults retain the preterm NRF route and the Strasbourg epoch geometry; these are dataset-specific settings rather than universal SIMPLE rules. The paired checks compute the selected mean or median directly from complete recording-level `true - internal reference` differences and obtain the corresponding 95% paired BCa bootstrap interval from those difference rows.

Steps 7.2–7.5 are display-only apart from their Command Window logs. Step 7.1 writes the excluded-item PNG batch, while Steps 7.6 and 7.7 write the machine-readable result files:

- `data/summary/screening/step_7_check_6_sep_check_qc_result.mat`
- `data/summary/screening/step_7_check_7_sep_check_nrf_result.mat`

### Detailed common documentation

See the **`simple-framework` repository README** for the detailed rationale, inputs, outputs, manual checkpoints, and operating rules of these common stages.

The scripts are duplicated locally so the Strasbourg pipeline executes Steps 3–7 inside this repository. Running `simple-strasbourg` does not import scripts from `simple-framework`.

### Analytical-unit boundary

No within-subject median aggregation is applied in Steps 1–7. Those stages retain their existing recording- and epoch-level units. The within-subject median is introduced only by the separate Step 8 median export and does not alter any earlier framework input, screening unit, or output.

## Step 8: subject-level CSV export

Script:

- `step_8_jasp_1_data_prep_eeg.m`

Step 8 reads the screened pooled QC and NRF feature tables and uses BrainVision marker files to establish acquisition chronology for the candidate cannula recordings. It builds and validates all three output tables before replacing their destination files.

### Earliest-recording route

For `data/jasp/jasp_data_eeg.csv`, the script:

- identifies the candidate cannula recording pairs represented in the screened QC and NRF tables
- ranks each subject's recordings using the timestamp of the cannula event in the corresponding BrainVision marker file
- selects rank 1 before consulting the screening `Exclude` values
- leaves the selected true-event QC and NRF values missing if the true cannula epoch is excluded
- never substitutes a later recording for an excluded selected recording
- retains one output row per subject

### Within-subject-median route

For `data/jasp/jasp_data_eeg_median.csv`, the script:

- includes a recording only when its matched true cannula and `cannula_prestim` epochs are both screening-retained
- uses one common contributor set of complete matched recording pairs for all four analytical values
- calculates the ordinary median separately for each QC or NRF value across a subject's contributing recordings
- retains one row per subject with all four analytical values missing if no complete retained pair contributes

This aggregation occurs only here, after the framework and screening stages.

### Selection manifest

`data/jasp/jasp_selection_manifest.csv` provides recording-level provenance for the two routes. Its fields record:

- the subject, session, and run identity
- recovered acquisition chronology and within-subject rank
- whether the recording was selected by the earliest-recording rule
- the named selection rule
- the relative marker-file path and its SHA-256 checksum
- the true and reference screening flags
- whether the recording contributes to the median route
- the named median-aggregation rule

### Generated CSVs

Step 8 writes exactly:

- `data/jasp/jasp_data_eeg.csv`
- `data/jasp/jasp_data_eeg_median.csv`
- `data/jasp/jasp_selection_manifest.csv`

The two data files share this five-column schema:

- `subjectID`
- `CA_BL_MeanAbsDiffNorm` for the `cannula_prestim` internal-reference epoch
- `CA_ER_MeanAbsDiffNorm` for the `cannula` true-event epoch
- `CA_BL_pnNRF_mag` for the internal-reference epoch's NRF `fglsCoef`
- `CA_ER_pnNRF_mag` for the true-event epoch's NRF `fglsCoef`

Step 8 is configured for a specific expected source-table schema, channel, run, event pair, NRF profile, BrainVision timing assumptions, and snapshot-specific validation assertions. Review those settings before reusing the script with a different dataset state.

Step 8 generates CSV files only. It does not create JASP archives or execute downstream analyses.

## Points where user input or inspection is required

At minimum:

### During Step 1

- review the preliminary source inventory and missing-file flags before copying source files

### During Step 2

- complete and review event relabelling
- complete and review event filters
- complete and review any latency-correction flags and the configured correction value
- complete and review channel filters
- inspect the final included dataset list

### During Steps 3–7

- review the generated event, channel, epoch, and multi-event inventories
- complete the epoch-to-NRF-profile mapping before NRF extraction
- review individual and pooled summaries
- perform and preserve the manual epoch–channel screening decisions
- inspect the post-screening outputs and checks

See the `simple-framework` README for the complete common-stage checkpoints.

### During Step 8

- confirm that the screened inputs and BrainVision marker files match the script's fixed schema and validation assumptions
- review both data exports and the manifest before using them downstream

## Key output contracts

Across the full workflow, the principal generated outputs include:

- `data_lists/dataset_list_prelim.xlsx`
- `data_lists/dataset_list.csv`
- copied BrainVision source triplets
- raw and processed EEGLAB `.set` files
- source, event, channel, epoch, and multi-event inventories
- individual and pooled QC, NRF, and epoch summaries
- screening package and screening decisions
- screened pooled outputs carrying `Exclude` flags
- the verified excluded-item PNG batch
- display-only post-screening figures and console summaries
- schema-v2 paired QC and NRF separation result MAT files
- the three Step 8 CSV files
- per-script Command Window logs

These are generated local working materials, not tracked contents of a fresh clone.

## Logging and provenance

The workflow preserves several forms of operational provenance:

- per-script Command Window logs
- source and raw-data inventories
- path and filename fields in the generated dataset lists
- processing and quantification metadata written into EEGLAB datasets by relevant stages
- a fixed screening package and separate mutable screening decisions
- screening flags in the screened pooled outputs
- Step 8 rule names, chronology, marker paths, marker checksums, and contribution flags in the selection manifest

Retain the generated files together when preserving or reviewing a particular execution. A clone of the tracked repository alone does not contain those local materials.

## License

This repository is licensed under the Apache License 2.0. See `LICENSE`.
