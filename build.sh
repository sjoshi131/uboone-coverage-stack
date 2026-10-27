#!/bin/bash
# build.sh -- from-scratch build of the Tier-2 coverage stack.
#
# Usage (inside the fnal-dev-sl7 container, from the repo directory):
#   ./build.sh all                 # every stage below, in order
#   ./build.sh <stage> [<stage>..] # check prepare genie reweight nuisance runtime verify
#   ./build.sh verify /path/to/ghep_input.root   # verify + 2000-event smoke test
#   ./build.sh runtime verify /path/to/ghep.root # the input may follow 'verify' (or 'all') anywhere
#
# Stages are idempotent: re-running a finished stage re-checks it quickly.
# Logs: ${WORK}/logs/<stage>.log

set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO}/config.sh"
source "${REPO}/ups_versions.sh"
LOGDIR="${WORK}/logs"
mkdir -p "${LOGDIR}"

say()  { echo -e "\n\033[1m[build] $*\033[0m"; }
die()  { echo -e "\n\033[31m[build] ERROR: $*\033[0m" >&2; exit 1; }
ok()   { echo "[build]   OK: $*"; }

# make -j, falling back to a serial make (GENIE's recursive makefiles are not
# always -j safe; the serial pass resumes where the parallel one stopped)
pmake() { make -j"${NJOBS}" "$@" || { echo "[build] parallel make failed, retrying serially"; make "$@"; }; }

git_head() { ( cd "$1" 2>/dev/null && git rev-parse --verify -q HEAD 2>/dev/null ) || true; }

clone_pinned() {   # url branch commit dest
  local url=$1 br=$2 commit=$3 dest=$4 head
  if [ -e "${dest}" ]; then
    head=$(git_head "${dest}")
    if [ "${head}" = "${commit}" ]; then ok "$(basename "${dest}") already at ${commit:0:9}"; return; fi
    if [ -n "${head}" ]; then
      die "${dest} is a valid checkout at ${head:0:9}, expected ${commit:0:9}. Remove it or fix config.sh."
    fi
    # Not a valid repository: leftover of an interrupted clone. Safe to remove,
    # because valid clones only ever appear here via the atomic mv below.
    echo "[build]   ${dest} is an incomplete clone (no valid HEAD) -- removing it"
    rm -rf "${dest}"
  fi
  # Clone to a temporary directory and move it into place only when complete,
  # so an interrupted clone can never be mistaken for a good one.
  rm -rf "${dest}.partial"
  git clone --branch "${br}" "${url}" "${dest}.partial"
  ( cd "${dest}.partial" && git checkout -q --detach "${commit}" )
  [ "$(git_head "${dest}.partial")" = "${commit}" ] || die "checkout of ${commit:0:9} failed in ${dest}.partial"
  mv "${dest}.partial" "${dest}"
  ok "$(basename "${dest}") @ ${commit:0:9}"
}

find_in_ldpath() {  # first LD_LIBRARY_PATH dir containing <libname>*
  local d; local IFS=:
  for d in ${LD_LIBRARY_PATH}; do ls "${d}/$1"* >/dev/null 2>&1 && { echo "${d}"; return 0; }; done
  for d in /usr/lib64 /usr/lib; do ls "${d}/$1"* >/dev/null 2>&1 && { echo "${d}"; return 0; }; done
  return 1
}
first_dir_with() {  # <relative file> <candidate dirs...>
  local f=$1; shift; local d
  for d in "$@"; do [ -n "${d}" ] && [ -f "${d}/${f}" ] && { echo "${d}"; return 0; }; done
  return 1
}

# ---------------------------------------------------------------------------
stage_check() {
  say "check: environment"
  grep -q "release 7" /etc/redhat-release || die "not in an SL7 container: $(cat /etc/redhat-release)"
  ok "$(cat /etc/redhat-release)"
  [ -d /cvmfs/dune.opensciencegrid.org/products ] || die "/cvmfs not mounted (apptainer -B /cvmfs)"
  stack_ups_setup || die "ups setup failed"
  ok "ups genie ${UPS_GENIE} at ${UPS_GENIE_DIR}; ROOT $(root-config --version)"
  command -v git >/dev/null || die "git not found"
  git ls-remote "${NUISANCE_URL}" HEAD >/dev/null || die "cannot reach GitHub (${NUISANCE_URL})"
  ok "GitHub reachable"
  [ -d "${SBNDATA_SRC}" ] || die "SBNDATA_SRC not readable: ${SBNDATA_SRC}"
  ok "sbndata source readable"
  mkdir -p "${STACK}" "${WORK}" || die "cannot create ${STACK} / ${WORK}"
  ok "STACK=${STACK}"; ok "WORK=${WORK}"
}

stage_prepare() {
  say "prepare: stack skeleton"
  mkdir -p "${STACK}"/{local_install,fcl,cards,sbndata,grid}
  cp "${REPO}/setup.sh" "${REPO}/ups_versions.sh" "${REPO}/prepare_card.sh" "${REPO}/check_output.sh" "${STACK}/"
  chmod +x "${STACK}"/*.sh
  cp "${REPO}"/fcl/*.fcl   "${STACK}/fcl/"
  cp "${REPO}"/cards/*.xml "${STACK}/cards/"
  cp "${REPO}"/grid/run_throws.sh "${STACK}/grid/"
  echo "${STACK_VERSION}" > "${STACK}/STACK_VERSION"
  ok "skeleton in ${STACK}"
}

stage_genie() {
  say "genie: custom GENIE Generator"
  stack_ups_setup
  local LGD="${STACK}/local_install"
  clone_pinned "${GENERATOR_URL}" "${GENERATOR_BRANCH}" "${GENERATOR_COMMIT}" "${LGD}/GENIE-Generator"
  export GENIE="${LGD}/GENIE-Generator"
  cd "${GENIE}"

  if [ -f "${LGD}/lib/libGFwGHEP.so" ] && [ -f src/make/Make.config ]; then
    ok "already built and installed (delete ${LGD}/lib to force a rebuild)"; return
  fi

  # --- locate the ups dependencies (variable names differ between products)
  local lhapdf_lib lhapdf_inc log4_lib log4_inc xml_lib xml_inc py6_lib gf_lib
  lhapdf_lib=$(find_in_ldpath libLHAPDF.so)    || die "libLHAPDF not on LD_LIBRARY_PATH"
  lhapdf_inc=$(first_dir_with LHAPDF/LHAPDF.h "${LHAPDF_INC}" "${lhapdf_lib}/../include") || die "LHAPDF headers not found"
  log4_lib=$(find_in_ldpath liblog4cpp.so)     || die "liblog4cpp not on LD_LIBRARY_PATH"
  log4_inc=$(first_dir_with log4cpp/Category.hh "${LOG4CPP_INC}" "${log4_lib}/../include") || die "log4cpp headers not found"
  xml_lib=$(find_in_ldpath libxml2.so)         || die "libxml2 not found"
  xml_inc=$(first_dir_with libxml/parser.h "${LIBXML2_FQ_DIR:+${LIBXML2_FQ_DIR}/include/libxml2}" \
              "${xml_lib}/../include/libxml2" /usr/include/libxml2) || die "libxml2 headers not found"
  py6_lib=$(find_in_ldpath libPythia6.so)      || die "libPythia6 not on LD_LIBRARY_PATH"
  gf_lib=$(dirname "$(gfortran -print-file-name=libgfortran.so)")
  ok "LHAPDF ${lhapdf_lib} | log4cpp ${log4_lib} | libxml2 ${xml_lib} | Pythia6 ${py6_lib}"

  # --- feature flags: mirror the reference build if its Make.config is readable.
  # Every GOPT_ENABLE_* key that GENIE's configure writes is mapped, so nothing
  # the reference enabled can silently fall back to configure's default.
  local feat=()
  refget() { grep -E "^$1=" "${REF_GENIE_MAKECONFIG}" 2>/dev/null | head -1 | cut -d= -f2-; }
  if [ -r "${REF_GENIE_MAKECONFIG}" ]; then
    declare -A MAP=( [PYTHIA6]=pythia6 [PYTHIA8]=pythia8 [INCL]=incl [GEANT4_INTERFACE]=geant4
      [LHAPDF5]=lhapdf5 [LHAPDF6]=lhapdf6 [APFEL]=apfel [FLUX_DRIVERS]=flux-drivers
      [GEOM_DRIVERS]=geom-drivers [T2K]=t2k [FNAL]=fnal [ATMO]=atmo [NUCLEON_DECAY]=nucleon-decay
      [NNBAR_OSCILLATION]=nnbar-oscillation [BOOSTED_DARK_MATTER]=boosted-dark-matter
      [HEAVY_NEUTRAL_LEPTON]=heavy-neutral-lepton [HNL_VALIDATION]=hnl-validation
      [DARK_NEUTRINO]=dark-neutrino [EVTLIB]=event-library [MASTERCLASS]=masterclass [TEST]=test
      [DYLIBVERSION]=dylibversion [LOW_LEVEL_MESG]=lowlevel-mesg [PROFILER]=profiler
      [DOXYGEN_DOC]=doxygen-doc [GFORTRAN]=gfortran [G2C]=g2c [PROFESSOR2]=professor2 )
    local k v
    while IFS='=' read -r k v; do
      k=${k#GOPT_ENABLE_}
      [ -n "${MAP[$k]}" ] || die "reference Make.config has unknown option GOPT_ENABLE_${k}; add it to MAP in build.sh"
      if [ "$v" = "YES" ]; then feat+=("--enable-${MAP[$k]}"); else feat+=("--disable-${MAP[$k]}"); fi
    done < <(grep -E '^GOPT_ENABLE_' "${REF_GENIE_MAKECONFIG}" | sort -u)
    ok "feature flags mirrored from ${REF_GENIE_MAKECONFIG}"
    for k in INCL GEANT4_INTERFACE APFEL PROFILER DOXYGEN_DOC; do
      [ "$(refget "GOPT_ENABLE_${k}")" = "YES" ] && die "reference enables ${k}, which this script cannot locate yet"
    done
  else
    feat=(--enable-lhapdf6 --disable-lhapdf5 --enable-gfortran --enable-fnal --enable-atmo)
    echo "[build]   reference Make.config not readable; using default feature flags"
  fi

  # --- Pythia8 (only if enabled). Must be on LD_LIBRARY_PATH from ups, so that
  # setup.sh provides it at run time too (and PYTHIA8DATA is set).
  local py8=()
  if printf '%s\n' "${feat[@]}" | grep -qx -- "--enable-pythia8"; then
    local py8_lib py8_inc ref8
    py8_lib=$(find_in_ldpath libpythia8.so) || py8_lib=""
    if [ -z "${py8_lib}" ]; then
      ref8=$(refget GOPT_WITH_PYTHIA8_LIB)
      echo "[build]   Pythia8 is enabled in the reference build but libpythia8 is not set up by ups here."
      if [[ "${ref8}" =~ /products/([^/]+)/([^/]+)/[^/]*-(e[0-9]+)-(prof|debug)/lib ]]; then
        echo "[build]   The reference used: ${ref8}"
        echo "[build]   Add this line inside stack_ups_setup() in ups_versions.sh, then rerun:"
        echo "[build]       setup ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} -q ${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
      fi
      die "libpythia8 not on LD_LIBRARY_PATH"
    fi
    py8_inc=$(first_dir_with Pythia8/Pythia.h "${PYTHIA8_INC}" "${py8_lib}/../include" "${PYTHIA8:+${PYTHIA8}/include}") \
      || die "Pythia8 headers (Pythia8/Pythia.h) not found next to ${py8_lib}"
    [ -n "${PYTHIA8DATA}" ] || echo "[build]   WARNING: PYTHIA8DATA is not set by ups; Pythia8 needs it at run time"
    py8=(--with-pythia8-lib="${py8_lib}" --with-pythia8-inc="${py8_inc}")
    ok "Pythia8 ${py8_lib}"
  fi

  ./configure --prefix="${LGD}" "${feat[@]}" \
      --with-lhapdf6-inc="${lhapdf_inc}" --with-lhapdf6-lib="${lhapdf_lib}" \
      --with-log4cpp-inc="${log4_inc}"   --with-log4cpp-lib="${log4_lib}" \
      --with-libxml2-inc="${xml_inc}"    --with-libxml2-lib="${xml_lib}" \
      --with-pythia6-lib="${py6_lib}"    --with-gfortran-lib="${gf_lib}" "${py8[@]}"

  if [ -r "${REF_GENIE_MAKECONFIG}" ]; then
    if ! diff <(grep -E '^GOPT_ENABLE_' "${REF_GENIE_MAKECONFIG}" | sort) \
              <(grep -E '^GOPT_ENABLE_' src/make/Make.config | sort); then
      die "configure feature flags differ from the reference build (diff above). Fix and rerun."
    fi
    ok "feature flags identical to reference build"
  fi

  pmake
  make install
  [ -f "${LGD}/lib/libGFwGHEP.so" ] || die "make install did not produce ${LGD}/lib/libGFwGHEP.so"
  ok "GENIE $(./bin/genie-config --version 2>/dev/null || cat VERSION) installed in ${LGD}"
}

stage_reweight() {
  say "reweight: custom GENIE Reweight"
  stack_ups_setup
  local LGD="${STACK}/local_install"
  export GENIE="${LGD}/GENIE-Generator"
  [ -f "${GENIE}/src/make/Make.config" ] || die "run the genie stage first"
  clone_pinned "${REWEIGHT_URL}" "${REWEIGHT_BRANCH}" "${REWEIGHT_COMMIT}" "${LGD}/GENIE-Reweight"
  export GENIE_REWEIGHT="${LGD}/GENIE-Reweight"
  export LD_LIBRARY_PATH="${LGD}/lib:${LD_LIBRARY_PATH}"
  cd "${GENIE_REWEIGHT}"
  if [ ! -f "${LGD}/lib/libGRwClc.so" ] || ! cmp -s "${LGD}/lib/libGRwClc.so" lib/libGRwClc.so; then
    pmake
    make install
  fi
  local n1 n2
  n1=$(strings "${LGD}/lib/libGRwFwk.so" | grep -c -E "XSecShape_CCMEC_Martini|DecayAng2MEC|EnergyDependence_CCMEC" || true)
  n2=$(strings "${LGD}/lib/libGRwClc.so" | grep -c "Non-finite XSecShape weight" || true)
  [ "${n1}" -gt 0 ] || die "installed libGRwFwk lacks the Tier-2 dial enums"
  [ "${n2}" -gt 0 ] || die "installed libGRwClc lacks the XSecShape non-finite guard (3ea24a5)"
  cmp -s "${LGD}/lib/libGRwClc.so" lib/libGRwClc.so || die "installed and in-tree libGRwClc differ"
  ok "Tier-2 enums (${n1}) + XSecShape guard present; installed == in-tree"
}

stage_nuisance() {
  say "nuisance: NUISANCE + built-in nusystematics"
  STACK_QUIET=1 source "${STACK}/setup.sh"
  mkdir -p "${WORK}"
  clone_pinned "${NUSYST_URL}"   "${NUSYST_BRANCH}"   "${NUSYST_COMMIT}"   "${WORK}/nusystematics"
  clone_pinned "${NUISANCE_URL}" "${NUISANCE_BRANCH}" "${NUISANCE_COMMIT}" "${WORK}/nuisance"

  grep -q "kXSecTwkDial_XSecShape_CCMEC_Martini" \
      "${WORK}/nusystematics/src/nusystematics/systproviders/GENIEReWeightEngineConfig.cc" \
      || die "nusystematics checkout does not wire the Tier-2 dials (is 90556fb reverted?)"
  ok "nusystematics wires Tier-2 dials"
  if ! grep -q "nominal_band" "${WORK}/nuisance/src/Routines/SystematicRoutines.cxx"; then
    ( cd "${WORK}/nuisance" && git apply "${REPO}/patches/nuissyst_nominal_cv.patch" )
    ok "applied nominal-output patch"
  else
    ok "nominal-output patch already in NUISANCE"
  fi

  local B="${WORK}/build-nuisance"
  mkdir -p "${B}"
  export CPM_SOURCE_CACHE="${WORK}/cpm-cache"
  cmake -S "${WORK}/nuisance" -B "${B}" \
      -DCMAKE_INSTALL_PREFIX="${STACK}/nuisance" \
      -DCMAKE_SKIP_INSTALL_RPATH=ON \
      -Dnusystematics_ENABLED=ON -Dnusystematics_BUILTIN=ON \
      -DCPM_nusystematics_SOURCE="${WORK}/nusystematics" 2>&1 | tee "${LOGDIR}/cmake-nuisance.log"
  grep -q "XSecMECReWeight: TRUE" "${LOGDIR}/cmake-nuisance.log" || die "GENIE XSecMEC reweight not enabled (see cmake log)"
  grep -E "GENIE LIB_DIRS" "${LOGDIR}/cmake-nuisance.log" | grep -q "${STACK}/local_install" \
      || die "cmake picked up a GENIE outside ${STACK}/local_install"
  ok "cmake found custom GENIE + Reweight"

  cmake --build "${B}" -j "${NJOBS}"
  cmake --install "${B}"

  # Pull in any shared library the installed nuissyst still cannot resolve
  # (CPM sub-projects do not always install their libraries).
  local pass lib f
  for pass in 1 2 3; do
    local missing; missing=$(ldd "${STACK}/nuisance/bin/nuissyst" | awk '/not found/{print $1}')
    [ -z "${missing}" ] && break
    for lib in ${missing}; do
      f=$(find "${B}" -name "${lib}" -print -quit)
      [ -n "${f}" ] || die "cannot find ${lib} anywhere in ${B}"
      cp -aL "${f}" "${STACK}/nuisance/lib/" && echo "[build]   copied ${lib}"
    done
  done
  ldd "${STACK}/nuisance/bin/nuissyst" | grep -q "not found" && die "nuissyst still has unresolved libraries"
  ok "nuissyst installed in ${STACK}/nuisance/bin"
}

stage_runtime() {
  say "runtime: data, configuration, manifest"
  local f
  for f in "${SBNDATA_FILES[@]}"; do
    [ -e "${SBNDATA_SRC}/${f}" ] || die "missing ${SBNDATA_SRC}/${f}"
    mkdir -p "${STACK}/sbndata/$(dirname "${f}")"
    cp -a "${SBNDATA_SRC}/${f}" "${STACK}/sbndata/$(dirname "${f}")/"
  done
  ok "sbndata: $(du -sh "${STACK}/sbndata" | cut -f1)"
  cp "${REPO}"/fcl/*.fcl "${STACK}/fcl/"; cp "${REPO}"/cards/*.xml "${STACK}/cards/"
  cp "${REPO}/setup.sh" "${REPO}/ups_versions.sh" "${REPO}/prepare_card.sh" "${REPO}/check_output.sh" "${STACK}/"
  cp "${REPO}"/grid/run_throws.sh "${STACK}/grid/"; chmod +x "${STACK}"/*.sh "${STACK}"/grid/*.sh
  {
    echo "stack_version   ${STACK_VERSION}"
    echo "built           $(date -u +%FT%TZ) on $(hostname) by ${USER}"
    echo "repo_commit     $( (cd "${REPO}" && git rev-parse HEAD) 2>/dev/null || echo 'not a git checkout')"
    echo "generator       ${GENERATOR_URL} ${GENERATOR_COMMIT}"
    echo "reweight        ${REWEIGHT_URL} ${REWEIGHT_COMMIT}"
    echo "nusystematics   ${NUSYST_URL} ${NUSYST_COMMIT}"
    echo "nuisance        ${NUISANCE_URL} ${NUISANCE_COMMIT}"
    echo "ups             cmake ${UPS_CMAKE}; boost ${UPS_BOOST}; genie ${UPS_GENIE}; genie_xsec ${UPS_GENIE_XSEC}"
    echo "sbndata_src     ${SBNDATA_SRC}"
  } > "${STACK}/MANIFEST"
  ok "MANIFEST written"
}

stage_verify() {
  say "verify: clean-environment checks"
  local input=""
  if [ -n "$1" ]; then
    input=$(readlink -f "$1")          # the smoke test runs in a temp dir: path must be absolute
    [ -f "${input}" ] || die "smoke-test input not found: $1"
    ok "smoke-test input ${input}"
  fi
  env -i HOME="${HOME}" USER="${USER}" PATH=/usr/bin:/bin TERM="${TERM}" \
      STACK_DIR="${STACK}" WORK_DIR="${WORK}" INPUT="${input}" \
      bash --noprofile --norc -c '
    set -e
    source "${STACK_DIR}/setup.sh"
    fail() { echo "[verify] FAIL: $*"; exit 1; }
    command -v nuissyst >/dev/null || fail "nuissyst not on PATH"
    ldd "$(command -v nuissyst)" | grep "not found" && fail "unresolved libraries"
    ldd "$(command -v nuissyst)" | grep -q "${WORK_DIR}" && fail "nuissyst links into the build area ${WORK_DIR}"
    ldd "$(command -v nuissyst)" | grep -E "libGRw|libGFwGHEP" | grep -qv "${STACK_DIR}" && fail "GENIE libs not from the stack"
    [ "$(genie-config --version)" = "999.999.999" ] || fail "genie-config is not the custom build"
    for f in "$GENIE/config/MartiniMECHadronTensorModel.xml" "$GENIE_REWEIGHT/config/reweight_master_config.xml" \
             "$STACK/fcl/systs_atmospherics_uboone_tier2.fcl"; do [ -f "$f" ] || fail "missing $f"; done
    ls "$GENIE"/data/evgen/hadron_tensors/martini/Martini_*_MEC_FullAll.dat >/dev/null || fail "Martini tensors missing"
    echo "[verify] static checks passed"
    if [ -n "${INPUT}" ]; then
      SD="${WORK_DIR}/smoke/$(date +%Y%m%d_%H%M%S)"; mkdir -p "${SD}"; cd "${SD}"
      "${STACK}/prepare_card.sh" "${COVERAGE_CARDS}/smoke_test_tier2.xml" "${INPUT}" smoke.xml
      echo "[verify] running nuissyst (2000 events, 3 throws; typically several minutes, no output until done)"
      echo "[verify]   log: ${SD}/smoke.log"
      echo "[verify]   follow it from another shell with:  tail -f ${SD}/smoke.log | grep -v \"DEBUG CalcWeightZExp\""
      t0=$(date +%s)
      set +e; nuissyst -c smoke.xml -o smoke.root -n 2000 > smoke.log 2>&1; rc=$?; set -e
      echo "[verify] nuissyst finished in $(( $(date +%s) - t0 )) s with exit code ${rc}"
      grep -v "DEBUG CalcWeightZExp" smoke.log | tail -25
      echo "[verify] full log: $(pwd)/smoke.log"
      "${STACK}/check_output.sh" "${rc}" smoke.log smoke.root || fail "smoke test failed"
      for d in XSecShape_CCMEC_Martini EnergyDependence_CCMEC DecayAngMECVariationResponse; do
        grep -q "Added NuSyst param, ${d} " smoke.log || fail "Tier-2 dial ${d} was not registered"
      done
      echo "[verify] Tier-2 dials registered; smoke test output: $(pwd)/smoke.root"
    fi
    echo "[verify] ALL CHECKS PASSED"
  '
}

# ---------------------------------------------------------------------------
CURRENT_STAGE=""
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${CURRENT_STAGE}" ] && echo -e "\n\033[31m[build] stage \"${CURRENT_STAGE}\" FAILED (exit $rc) -- full log: ${LOGDIR}/${CURRENT_STAGE}.log\033[0m" >&2' EXIT

run_stage() {   # runs in a subshell so each stage starts from a clean environment;
  local s=$1; shift   # with 'set -e' + pipefail, a failing stage stops the script here
  CURRENT_STAGE="${s}"
  ( "stage_${s}" "$@" ) 2>&1 | tee "${LOGDIR}/${s}.log"
  CURRENT_STAGE=""
}

[ $# -ge 1 ] || { sed -n '2,13p' "$0"; exit 1; }

# Parse ALL arguments before running anything: stage names (or 'all'), and an
# optional smoke-test input that may follow 'verify' or 'all' anywhere.
STAGES=(); SMOKE_INPUT=""; prev=""
for a in "$@"; do
  if [ "$a" = "all" ]; then
    STAGES+=(check prepare genie reweight nuisance runtime verify)
  elif declare -f "stage_${a}" >/dev/null; then
    STAGES+=("$a")
  elif [ "${prev}" = "verify" ] || [ "${prev}" = "all" ]; then
    [ -z "${SMOKE_INPUT}" ] || die "more than one smoke-test input given"
    SMOKE_INPUT="$a"
  else
    die "unknown stage '${a}' (a smoke-test input must directly follow 'verify' or 'all')"
  fi
  prev="$a"
done
if [ -n "${SMOKE_INPUT}" ]; then
  [ -f "${SMOKE_INPUT}" ] || die "smoke-test input not found: ${SMOKE_INPUT}"
  printf '%s\n' "${STAGES[@]}" | grep -qx verify || die "a smoke-test input was given but no 'verify' stage"
fi

for s in "${STAGES[@]}"; do
  if [ "$s" = "verify" ]; then run_stage verify "${SMOKE_INPUT}"; else run_stage "$s"; fi
done
say "done."
