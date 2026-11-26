#!/usr/bin/env bash
# Build WPS ungrib (and rd_intermediate) into $G2G_WORK/src/WPS-4.6.0.
#
#   scripts/build_ungrib.sh
#
# ungrib converts GRIB2 analyses into the WPS intermediate format that
# init_atmosphere_model reads. Only ungrib is built; WRF is not needed.
#
# WPS's classic ./compile is a csh script and this workstation has no csh, so
# the build uses the CMake path. Three things in that path need help:
#   * with -x, configure_new skips its own option prompts, so USE_WRF and
#     BUILD_EXTERNALS are passed to CMake directly;
#   * the bundled zlib, libpng, and JasPer are pre-C99 sources that GCC 14+
#     rejects by default, hence the permissive CFLAGS;
#   * libpng's configure does not look in the bundled zlib prefix on its own,
#     hence LDFLAGS and CPPFLAGS.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

WPS_TAG="v4.6.0"
wps="$G2G_TOOLS/WPS-4.6.0"

g2g_activate
command -v cmake >/dev/null || g2g_die "cmake not on PATH"
mkdir -p "$G2G_TOOLS" "$G2G_LOGS"

if [ -x "$wps/_build/ungrib/ungrib" ] && [ -x "$wps/_build/util/rd_intermediate" ]; then
    echo "ungrib already built: $wps/_build/ungrib/ungrib"
    exit 0
fi

[ -d "$wps/.git" ] || git clone --quiet --depth 1 --branch "$WPS_TAG" https://github.com/wrf-model/WPS.git "$wps"

grib2="$wps/install/grib2"
export CFLAGS="-std=gnu17 -fPIC -fpermissive -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion"
export LDFLAGS="-L$grib2/lib"
export CPPFLAGS="-I$grib2/include"

cd "$wps"
rm -rf _build
echo "configuring WPS (log: $G2G_LOGS/wps_configure.log)"
./configure_new -p gfortran -x -d "$wps/_build" -i "$wps/install" -- \
    -DUSE_WRF=OFF -DBUILD_EXTERNALS=ON -DUSE_MPI=OFF -DUSE_OPENMP=OFF \
    > "$G2G_LOGS/wps_configure.log" 2>&1 || g2g_die "WPS configure failed; see $G2G_LOGS/wps_configure.log"

echo "building ungrib (log: $G2G_LOGS/wps_build.log)"
cmake --build "$wps/_build" --target ungrib rd_intermediate --parallel 8 \
    > "$G2G_LOGS/wps_build.log" 2>&1 || g2g_die "ungrib build failed; see $G2G_LOGS/wps_build.log"

[ -x "$wps/_build/ungrib/ungrib" ] || g2g_die "no ungrib executable after build"
echo "built $wps/_build/ungrib/ungrib"
