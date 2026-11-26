# Shared environment for the MPAS-GOCART2G workstation scripts.
#
# Source this file; do not execute it. Every scripts/*.sh entry point sources
# it first, so the locations below are the single place they are defined.
#
#   G2G_WORK       work root outside the repository      [$HOME/Data/MPAS-GOCART2G]
#   G2G_CONDA_ENV  conda environment with the toolchain   [mpas]
#
# Layout under G2G_WORK:
#   build/<core>/gocartMPAS   out-of-tree build copy, one per core
#   inputs/                   downloaded and derived model inputs
#   runs/<name>/              run directories
#   src/                      third-party tools built locally (WPS)
#   logs/                     build and preparation logs

if [ -z "${BASH_VERSION:-}" ]; then
    echo "g2g_env.sh needs bash" >&2
    return 1 2>/dev/null || exit 1
fi

G2G_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G2G_WORK="${G2G_WORK:-$HOME/Data/MPAS-GOCART2G}"
G2G_CONDA_ENV="${G2G_CONDA_ENV:-mpas}"
G2G_BUILD="$G2G_WORK/build"
G2G_INPUTS="$G2G_WORK/inputs"
G2G_RUNS="$G2G_WORK/runs"
G2G_TOOLS="$G2G_WORK/src"
G2G_LOGS="$G2G_WORK/logs"
export G2G_REPO G2G_WORK G2G_CONDA_ENV G2G_BUILD G2G_INPUTS G2G_RUNS G2G_TOOLS G2G_LOGS

g2g_die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Put the GNU/Open MPI/PnetCDF toolchain on PATH. The model is built against
# SMIOL, so PIO must stay unset: with PIO set the Makefile drops the SMIOL link
# line that the GOCART-2G optics reader needs.
g2g_activate() {
    if [ "${CONDA_DEFAULT_ENV:-}" != "$G2G_CONDA_ENV" ]; then
        local base
        base="$(conda info --base 2>/dev/null)" || base=""
        [ -n "$base" ] || for base in "$HOME/miniforge3" "$HOME/miniconda3"; do
            [ -r "$base/etc/profile.d/conda.sh" ] && break
        done
        [ -r "$base/etc/profile.d/conda.sh" ] || g2g_die "conda not found; activate '$G2G_CONDA_ENV' first"
        # conda's activation scripts reference unset variables
        set +u
        # shellcheck disable=SC1091
        . "$base/etc/profile.d/conda.sh"
        conda activate "$G2G_CONDA_ENV" || g2g_die "cannot activate conda env '$G2G_CONDA_ENV'"
        set -u
    fi
    local tool
    for tool in mpif90 mpicc mpiexec gfortran pnetcdf-config ncdump python; do
        command -v "$tool" >/dev/null || g2g_die "'$tool' not on PATH in conda env '$G2G_CONDA_ENV'"
    done
    unset PIO
    export NETCDF="$CONDA_PREFIX" PNETCDF="$CONDA_PREFIX"
}
