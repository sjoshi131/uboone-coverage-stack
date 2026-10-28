# uboone-coverage-stack

From-scratch, version-pinned build of everything needed for the MicroBooNE
VisAngle coverage study with the **Tier-2 MEC dials**, packaged as one
relocatable folder / tarball for grid jobs.

| Component | Source | Pinned commit |
| --- | --- | --- |
| GENIE Generator (Martini MEC + tensors) | pgranger23/Generator `dune_atmospherics_fix_inf` | `5bcbee40b` |
| GENIE Reweight (Tier-2 dials, NaN/inf guards) | pgranger23/Reweight `dune_atmospherics_fix_inf` | `328501d3` |
| nusystematics (Tier-2 wiring + builtin CMake fix) | sjoshi131/nusystematics `dune_atmospherics_nuisance_tier2` | `58bf0b1` |
| NUISANCE (VisAngle sample + nominal output) | sjoshi131/nuisance-MicroBooNE-VisAngle `feature/microboone-visangle` | `4842d03` |
| Base products (ROOT, LHAPDF6, Pythia6, log4cpp, boost) | ups on /cvmfs: genie `v3_06_02e e26:prof`, genie_xsec `v3_06_00 AR2320i00000` | — |

Everything is set in `config.sh` and `ups_versions.sh`. Change those files, never the scripts,
and bump `STACK_VERSION` for any change. `STACK_VERSION` is only a label recorded in the stack; it is not a directory.

## Layout of the built stack

```
$STACK = /exp/dune/app/users/$USER/coverage-stack
├── setup.sh  ups_versions.sh  prepare_card.sh  STACK_VERSION  MANIFEST
├── local_install/                  custom GENIE (same layout as Pierre's)
│   ├── lib/ include/ bin/          installed Generator + Reweight
│   ├── GENIE-Generator/            config/, data/ (Martini tensors)  -> $GENIE
│   └── GENIE-Reweight/             config/                           -> $GENIE_REWEIGHT
├── nuisance/                       NUISANCE install (bin/nuissyst, lib/ incl. nusystematics)
├── fcl/systs_atmospherics_uboone_tier2.fcl
├── cards/coverage_all_dials_tier2.xml, smoke_test_tier2.xml
├── sbndata/systematics/AR23Plus/   tables read by CCQETemplate, CCQEXSecCorr, QEInterference
└── grid/run_throws.sh
```

## 0. One-time prerequisites

- **GitHub access from the gpvm.** Set up an SSH key, or use HTTPS for these public repos.
- **This repository on the gpvm.**

  ```
  git clone git@github.com:sjoshi131/uboone-coverage-stack.git ~/uboone-coverage-stack
  ```

- **Disk space.** You need roughly 10 GB in `/exp/dune/app/users/$USER` for the stack and build area.

## 1. Build (about 1–2 h, mostly GENIE)

The build must run in the SL7 container. Running it detached keeps it going if your ssh session drops:

```
cd ~/uboone-coverage-stack
APPT=/cvmfs/oasis.opensciencegrid.org/mis/apptainer/current/bin/apptainer
IMG=/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest
nohup $APPT exec -B /cvmfs,/exp,/nashome --ipc --pid $IMG ./build.sh all > build_all.out 2>&1 &
tail -f build_all.out
```

Or interactively, one stage at a time:

```
$APPT shell -B /cvmfs,/exp,/nashome --ipc --pid $IMG
./build.sh check          # SL7, /cvmfs, ups, GitHub, sbndata
./build.sh prepare        # stack skeleton + setup.sh, fcl, cards
./build.sh genie          # custom GENIE Generator -> local_install
./build.sh reweight       # custom GENIE Reweight  -> local_install (checks Tier-2 enums + guards)
./build.sh nuisance       # NUISANCE + builtin nusystematics -> $STACK/nuisance
./build.sh runtime        # sbndata copy + MANIFEST
./build.sh verify /path/to/ghep_AR23.root   # clean-env checks + 2000-event smoke test
```

Logs go to `$WORK/logs/<stage>.log`. Stages can be re-run safely, so after fixing a failure you rerun only that stage.

The `genie` stage copies the feature flags from Pierre's GENIE `Make.config` when it's readable. It then refuses to continue if the resulting configuration differs, which keeps the build identical to the one he validated.

## 2. Use it interactively

```
$APPT shell -B /cvmfs,/exp,/pnfs,/nashome --ipc --pid $IMG
source /exp/dune/app/users/$USER/coverage-stack/setup.sh
$STACK/prepare_card.sh $COVERAGE_CARDS/coverage_all_dials_tier2.xml /path/to/ghep_AR23.root card.xml
nuissyst -c card.xml -o coverage.root
```

## 3. Package and test the tarball

Inside the container:

```
./package.sh                                                   # -> /exp/dune/app/users/$USER/coverage-stack.tar.gz
./test_tarball.sh /exp/dune/app/users/$USER/coverage-stack.tar.gz /path/to/ghep_AR23.root
```

`test_tarball.sh` unpacks the tarball in a different folder and runs it in a clean environment. It fails if anything still resolves to the original stack or build area. Only submit after it prints `TARBALL OK`.

## 4. Grid campaign

On the gpvm host, not in the container, with a valid token:

```
htgettoken -a htvaultprod.fnal.gov -i dune
grid/submit_throws.sh /exp/dune/app/users/$USER/coverage-stack.tar.gz \
    coverage_all_dials_tier2.xml /pnfs/dune/scratch/users/$USER/inputs/ghep_AR23.root 20 20 alldials
```

For a quick test, add `-n <events>` before the other arguments. Every job then processes only the first that many events of the input, for example 2 jobs × 3 throws on 200 events:

```
bash grid/submit_throws.sh -n 200 /exp/dune/app/users/$USER/coverage-stack.tar.gz \
    cards/smoke_test_tier2.xml /pnfs/dune/scratch/users/$USER/inputs/ghep_AR23.root 2 3 gridtest
```

Each campaign folder gets a `campaign.txt` that records the tarball md5, card, input, number of jobs, throws per job and event limit.

Job `k` writes a non-overlapping block of throws, and only job 0 writes `nominal`. Twenty jobs of 20 throws each give throws 1–400 exactly once. To use a card that isn't in the tarball, pass its path; it's shipped with the job.

When the jobs finish, merge the outputs inside the container after sourcing `setup.sh`:

```
grid/merge_throws.sh /pnfs/dune/scratch/users/$USER/coverage/alldials_<date> [merged.root]
```

The merged file (default `<campaign>/merged.root`) contains `error_bands/`, `nominal_throw/`, `nominal/` and `nominal_band/`.

The merge is done by `grid/fast_merge.py`, which reads only the throw files and takes seconds. It reproduces `nuissyst -f MergeErrors` bit for bit, but it doesn't load the card, the FHiCL or the events. It also warns when a throw number appears in two files (a job resubmitted with the same start) and reports gaps in the throw numbering. To use nuissyst itself, add `--nuissyst` and give the card and input as before:

```
grid/merge_throws.sh --nuissyst <campaign dir> coverage_all_dials_tier2.xml /path/to/ghep_AR23.root
```

That is slow with the production FHiCL, because nuissyst sets up every dial and reads the events before it merges.

## 5. Prior-predictive p-value

```
python3 analysis/throw_pvalue.py merged.root --plot --csv
```

For each sample in the file, the script computes the throw distribution χ²_k = (m_nom − m_k)ᵀ C⁻¹ (m_nom − m_k) and the data value χ²_obs = (d − m_nom)ᵀ C⁻¹ (d − m_nom). C is the data covariance NUISANCE uses (`nominal/<sample>_COV`), inverted once with an eigenvalue cut (`--rcond`, default 1e-10). The p-value is p = (#{χ²_k ≥ χ²_obs} + 1)/(N + 1). χ²_obs is checked against NUISANCE's own χ² (`nominal/likelihood_hist`), which is valid for single-sample cards. `--plot` writes a PNG and `--csv` writes the χ²_k values.

## Notes

- **One card per MicroBooNE VisAngle result.** Each card has the same 68 dials and FHiCL and differs only in the `<sample>` line, so a run gives the results for that sample only:

  | Result | Production card | Smoke card |
  | --- | --- | --- |
  | θ_vis (15 bins) | `coverage_all_dials_tier2.xml` | `smoke_test_tier2.xml` |
  | cosθ_μ (18 bins) | `coverage_uboone_muoncostheta.xml` | `smoke_uboone_muoncostheta.xml` |
  | p_miss (9 bins) | `coverage_uboone_pmiss.xml` | `smoke_uboone_pmiss.xml` |
  | θ_vis in \|p_miss\| slices (27 flattened bins) | `coverage_uboone_thetavis_pmiss.xml` | `smoke_uboone_thetavis_pmiss.xml` |

  The 2D sample needs NUISANCE with the VisAngle 2D commit, so `NUISANCE_COMMIT` must point at it. NUISANCE seeds its throws from the clock, so separate runs get different throws. That doesn't matter for the per-sample coverage. To compare samples throw by throw, use one card holding several `<sample>` lines.

- **FHiCL.** `fcl/systs_atmospherics_uboone_tier2.fcl` is the agreed study configuration. It is derived from Pierre's `systs_atmospherics_v2.fcl` and has one provider for each repeated dial name:
  - `CCQETemplateReweight_SBN_v3_LFGToSF` for `q0bin0..4`
  - `ZExpPCAWeighter_SBN_v3_MvA` (MINERvA) for `b1..b4`
  - `MECq0q3InterpWeighting_SBN_v3_SuSAToMar` for `MECResponse_q0bin0..3`

  `MaCCRES`, `XSecShape_CCMEC`, `XSecShape_CCMEC_Empirical` and `Fakedial` were removed after discussion with colleagues.
- **Card.** `cards/coverage_all_dials_tier2.xml` has 68 dials: 65 thrown (`GAUSSIAN`), including `MECResponse_q0bin0..3`, and 3 decay-angle dials held `FIX` at nominal. FHiCL dials that aren't in the card are still calculated, but they give a weight of 1. The exceptions are the three correction dials, which are always applied. Those calculated-but-unused dials are `ZExpA1..4CCQE`, the four `MiscInteractionSysts` dials, and the corrections.
- **Two Tier-2 dials are left out of the production FHiCL.** `XSecShape_CCMEC_Martini` and `EnergyDependence_CCMEC` are not in `systs_atmospherics_uboone_tier2.fcl` or the cards. Without precomputed GENIE splines, Reweight (`GReWeightXSecMEC::GetXSecIntegral`) does a numerical cross-section integral for every MEC event, at every variation, so the first pass takes hours for a few thousand events. `fcl/systs_atmospherics_uboone_tier2_full.fcl` keeps them, but use it only for small alternative-model runs: copy a card, point `ConfigFHiCL` at the `_full` file, add the dial with `nominal="1.0"` and `state="FIX"`, and keep `-n` small. The proper fix is to load GENIE splines for the alternative MEC models.
- **Decay-angle universes.** For these runs, set `DecayAngMECVariationResponse` to an integer from 1 to 24. This dial has no integral, so it is already in the production FHiCL.
- **Run time is set by the FHiCL, not the card.** For every event, nusystematics evaluates the response of every dial in the FHiCL, at every variation. That includes full GENIE reweighting (`UseFullHERG: true`), the 25 decay-angle universes and the Martini morph. NUISANCE caches these per event on the first pass, so the extra throws after that are cheap. Removing dials from the card saves almost nothing; trimming the FHiCL does. Two consequences:
  - The smoke test uses `fcl/smoke_tier2.fcl`, which evaluates 20 dials (the study FHiCL evaluates 79), on `SMOKE_EVENTS` events (200, set in `config.sh`).
  - On the grid, every job repeats the caching pass for its events. Use fewer jobs with many throws each rather than many short jobs.
- **The `-t` flag of `nuissyst` is ignored.** The number of throws comes from `<config error_throws=...>`, or from `-q error_throws=N` as the grid script uses.
- **Correction dials** `CCQEXSecCorr`, `Theta_Delta2Npi` and `VecFFCCQEshape` are always applied, whatever the card contains.
- **Debug output.** Pierre's Reweight branch (`b0a6118`) prints `[DEBUG CalcWeightZExp] ...` to stdout whenever the raw `ZExpA1..4CCQE` responses are calculated. nusystematics calculates every FHiCL dial, even ones that aren't in the card, so expect large logs. The grid script compresses them. Filter with `grep -v "DEBUG CalcWeightZExp"` when reading.
