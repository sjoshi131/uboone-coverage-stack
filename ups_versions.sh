# ups_versions.sh -- base products from /cvmfs, shared by build.sh and setup.sh.
# The custom GENIE is built on top of these, so build and runtime MUST use the
# same values. Changing any of them means a full rebuild (bump STACK_VERSION in config.sh).
UPS_CMAKE="v3_21_4"
UPS_BOOST="v1_80_0 -q e26:prof"
UPS_GENIE="v3_06_02e -q e26:prof"            # provides ROOT, LHAPDF6, Pythia6, log4cpp, libxml2, GSL
UPS_GENIE_XSEC="v3_06_00 -q AR2320i00000:e1000:k250"
UPS_IFDHC=""                                 # e.g. "v2_7_2"; empty = whatever setup_dune.sh provides

stack_ups_setup() {
  # ups scripts are not clean under 'set -eu'
  local _old; _old=$(set +o); set +eu
  source /cvmfs/dune.opensciencegrid.org/products/dune/setup_dune.sh >/dev/null
  setup cmake ${UPS_CMAKE}           || { echo "ups: cmake failed";      eval "$_old"; return 1; }
  setup boost ${UPS_BOOST}           || { echo "ups: boost failed";      eval "$_old"; return 1; }
  setup genie ${UPS_GENIE}           || { echo "ups: genie failed";      eval "$_old"; return 1; }
  setup genie_xsec ${UPS_GENIE_XSEC} || { echo "ups: genie_xsec failed"; eval "$_old"; return 1; }
  if [ -n "${UPS_IFDHC}" ]; then setup ifdhc ${UPS_IFDHC}; else setup ifdhc >/dev/null 2>&1; fi
  export UPS_GENIE_DIR="$GENIE"      # remember the ups GENIE before we override GENIE
  eval "$_old"
}
