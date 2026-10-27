# config.sh -- everything that defines one build of the coverage stack.
# Edit here, never inside build.sh. Bump STACK_VERSION (a label recorded in
# STACK_VERSION/MANIFEST, not a directory) for any change.

STACK_VERSION="v2.0-tier2"

# Where the finished, relocatable stack is installed (this folder is what gets tarred).
STACK="/exp/dune/app/users/${USER}/coverage-stack"

# Scratch area for NUISANCE sources/build tree and the CPM download cache.
WORK="/exp/dune/app/users/${USER}/coverage-build"

# Parallel make jobs (gpvm: keep modest)
NJOBS=4

# Events used by './build.sh verify <input>' (with the trimmed fcl/smoke_tier2.fcl)
SMOKE_EVENTS=200

# ---------------------------------------------------------------------------
# Sources, pinned to exact commits (branch is only used to fetch).
# Generator/Reweight: switch the URLs to your own forks once you make them.
GENERATOR_URL="https://github.com/pgranger23/Generator.git"
GENERATOR_BRANCH="dune_atmospherics_fix_inf"
GENERATOR_COMMIT="5bcbee40b4f1b91e9d23b9d854b47e12f642965b"

REWEIGHT_URL="https://github.com/pgranger23/Reweight.git"
REWEIGHT_BRANCH="dune_atmospherics_fix_inf"
REWEIGHT_COMMIT="328501d3c905703c159bc20cfcc7a5836957e476"

# fix_inf dial wiring + NUISANCE-builtin CMake fix (8cfccd8), 90556fb reverted
NUSYST_URL="https://github.com/sjoshi131/nusystematics.git"
NUSYST_BRANCH="dune_atmospherics_nuisance_tier2"
NUSYST_COMMIT="58bf0b198ec25393efecd555f0a083dcbad66eef"

# MicroBooNE VisAngle sample + nominal/nominal_band output (merged PR #1)
NUISANCE_URL="https://github.com/sjoshi131/nuisance-MicroBooNE-VisAngle.git"
NUISANCE_BRANCH="feature/microboone-visangle"
NUISANCE_COMMIT="4842d0375632f9d6960ed2570821d33af6a5787c"

# ---------------------------------------------------------------------------
# Runtime inputs copied INTO the stack (grid nodes cannot see these paths).
# Only the files the providers in fcl/systs_atmospherics_uboone_tier2.fcl read.
SBNDATA_SRC="/exp/dune/app/users/pgranger/systematics-sbn/sbndata"
SBNDATA_FILES=(
  "systematics/AR23Plus/CCQETemplateReweight.root"   # CCQETemplateReweight_SBN_v3_LFGToSF
  "systematics/AR23Plus/QE-Fix"                      # CCQEXSecCorr_SBN_v3
  "systematics/AR23Plus/ACHILLES_weights.root"       # QEInterference_SBN_v3
  "systematics/AR23Plus/MEC"                         # MECq0q3InterpWeighting_SBN_v3_SuSAToMar
)

# Optional: Pierre's GENIE Make.config, used only to cross-check configure flags.
REF_GENIE_MAKECONFIG="/exp/dune/app/users/pgranger/systematics-lars/local_install/GENIE-Generator/src/make/Make.config"
