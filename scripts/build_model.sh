#!/usr/bin/env bash
# Build MPAS-GOCART2G out of tree with the GNU toolchain.
#
#   scripts/build_model.sh [init_atmosphere|atmosphere|all] [--clean] [--debug]
#
# The source in gocartMPAS/ is copied to $G2G_WORK/build/<core>/gocartMPAS and
# compiled there, one copy per core. Reasons:
#   * the repository tracks generated files (Registry_processed.xml and
#     src/core_*/inc/*.inc) that every build rewrites, so an in-tree build
#     leaves the worktree dirty;
#   * a separate copy per core avoids the full rebuild MPAS needs when one
#     tree switches between init_atmosphere and atmosphere.
#
# The build is serial on purpose. src/core_init_atmosphere/Makefile orders
# core_hyd_init before core_gocart2G only by position, so "make -j" compiles
# the GOCART-2G init modules before init_atm_hinterp.mod exists and fails.
#
# The atmosphere build also runs build_tables once to create the Thompson
# microphysics lookup tables (about 15 minutes).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

cores=()
clean=false
debug=false
for arg in "$@"; do
    case "$arg" in
        init_atmosphere|atmosphere) cores+=("$arg") ;;
        all) cores=(init_atmosphere atmosphere) ;;
        --clean) clean=true ;;
        --debug) debug=true ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) g2g_die "unknown argument: $arg" ;;
    esac
done
[ "${#cores[@]}" -gt 0 ] || cores=(init_atmosphere atmosphere)

g2g_activate
mkdir -p "$G2G_LOGS"
g2g_require_symlinks "$G2G_WORK"

for core in "${cores[@]}"; do
    tree="$G2G_BUILD/$core/gocartMPAS"
    log="$G2G_LOGS/build_$core.log"
    previous_debug="$(grep '^debug=' "$G2G_BUILD/$core/BUILD_INFO" 2>/dev/null | cut -d= -f2 || true)"
    if [ -n "$previous_debug" ] && [ "$previous_debug" != "$debug" ]; then
        echo "[$core] debug setting changed ($previous_debug -> $debug); starting from a clean copy"
        clean_core=true
    else
        clean_core=$clean
    fi
    if $clean_core; then
        echo "[$core] removing $tree"
        rm -rf "${G2G_BUILD:?}/$core"
    fi
    mkdir -p "$tree"
    # No --delete: the build tree also holds objects, fetched physics
    # externals, and lookup tables that do not exist in the source.
    rsync -a "$G2G_REPO/gocartMPAS/" "$tree/"

    {
        echo "source_commit=$(git -C "$G2G_REPO" rev-parse HEAD)"
        if [ -n "$(git -C "$G2G_REPO" status --porcelain -- gocartMPAS)" ]; then
            echo "source_dirty=yes"
        else
            echo "source_dirty=no"
        fi
        echo "core=$core"
        echo "debug=$debug"
        echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "fortran=$(gfortran --version | head -1)"
        echo "mpi=$(mpiexec --version | head -1)"
        echo "pnetcdf=$(pnetcdf-config --version | head -1)"
    } > "$G2G_BUILD/$core/BUILD_INFO"

    make_args=(gnu "CORE=$core" GOCART2G=true)
    $debug && make_args+=(DEBUG=true)

    echo "[$core] make ${make_args[*]}  (serial; log: $log)"
    start=$SECONDS
    if ! (cd "$tree" && make "${make_args[@]}") > "$log" 2>&1; then
        tail -n 30 "$log" >&2
        g2g_die "$core build failed; full log: $log"
    fi
    [ -x "$tree/${core}_model" ] || g2g_die "$core build produced no ${core}_model; see $log"
    echo "[$core] built $tree/${core}_model in $((SECONDS - start)) s"

    if [ "$core" = atmosphere ]; then
        missing=false
        for table in QRacrQG QRacrQS QIautQS freezeH2O; do
            [ -s "$tree/MP_THOMPSON_${table}_DATA.DBL" ] || missing=true
        done
        if $missing; then
            echo "[atmosphere] build_tables (Thompson lookup tables; log: $G2G_LOGS/build_tables.log)"
            start=$SECONDS
            (cd "$tree" && rm -f MP_THOMPSON_*_DATA.DBL && ./build_tables) > "$G2G_LOGS/build_tables.log" 2>&1 \
                || g2g_die "build_tables failed; see $G2G_LOGS/build_tables.log"
            for table in QRacrQG QRacrQS QIautQS freezeH2O; do
                [ -s "$tree/MP_THOMPSON_${table}_DATA.DBL" ] || g2g_die "build_tables did not write MP_THOMPSON_${table}_DATA.DBL"
            done
            echo "[atmosphere] lookup tables written in $((SECONDS - start)) s"
        fi
    fi
done
