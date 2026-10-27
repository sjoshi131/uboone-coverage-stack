# setup.sh -- runtime environment for the coverage stack.
# Source it INSIDE an SL7 container (fnal-dev-sl7 interactively, fnal-wn-sl7 on
# the grid). It locates itself, so the same file works from
#   /exp/dune/app/users/<you>/coverage-stack/<version>/setup.sh   (gpvm)
#   ${INPUT_TAR_DIR_LOCAL}/<version>/setup.sh                     (grid, unpacked tarball)

if ! grep -q "release 7" /etc/redhat-release 2>/dev/null; then
  echo "[setup.sh] ERROR: not inside an SL7 container (see README, step 0)." >&2
  return 1 2>/dev/null || exit 1
fi

export STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${STACK}/ups_versions.sh"
stack_ups_setup || { echo "[setup.sh] ERROR: ups setup failed" >&2; return 1 2>/dev/null || exit 1; }

# --- custom GENIE Generator + Reweight (same layout as Pierre's local_install)
export LOCAL_GENIE_DIR="${STACK}/local_install"
export GENIE="${LOCAL_GENIE_DIR}/GENIE-Generator"          # config/ + data/ (incl. Martini tensors)
export GENIE_REWEIGHT="${LOCAL_GENIE_DIR}/GENIE-Reweight"  # config/reweight_master_config.xml
export GENIE_LIB="${LOCAL_GENIE_DIR}/lib"
export GENIE_INC="${LOCAL_GENIE_DIR}/include"
export GENIE_FQ_DIR="${LOCAL_GENIE_DIR}"                   # genie-config fallback -> custom build
if [ ! -d "${GENIE}/data/evgen/intranuke" ] && [ -n "${UPS_GENIE_DIR}" ]; then
  export GINUKEHADRONDATA="${UPS_GENIE_DIR}/data/evgen/intranuke"
fi

# --- NUISANCE (+ built-in nusystematics/systematicstools/fhiclcpp)
export NUISANCE="${STACK}/nuisance"
export PATH="${NUISANCE}/bin:${LOCAL_GENIE_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${NUISANCE}/lib:${LOCAL_GENIE_DIR}/lib:${LD_LIBRARY_PATH}"
export ROOT_INCLUDE_PATH="${LOCAL_GENIE_DIR}/include/GENIE:${LOCAL_GENIE_DIR}/include:${ROOT_INCLUDE_PATH}"

# --- systematics configuration and data
export SBNDATA_DIR="${STACK}/sbndata"
export FHICL_FILE_PATH=".:${STACK}/fcl:${NUISANCE}/fcl:${FHICL_FILE_PATH}"
export COVERAGE_CARDS="${STACK}/cards"

if [ -z "${STACK_QUIET}" ]; then
  echo "[setup.sh] coverage stack $(cat "${STACK}/STACK_VERSION" 2>/dev/null) at ${STACK}"
  echo "[setup.sh]   GENIE=${GENIE}"
  echo "[setup.sh]   nuissyst=$(command -v nuissyst || echo 'NOT FOUND')"
fi
