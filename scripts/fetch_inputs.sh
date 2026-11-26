#!/usr/bin/env bash
# Download the date-independent public inputs into $G2G_WORK/inputs.
#
#   scripts/fetch_inputs.sh [mesh] [geog] [optics]      (default: all three)
#
#   mesh    x1.40962 (120 km) grid, static file, and graph partitions
#   geog    WPS tiles for the dust source: erod, clayfrac_5m, sandfrac_5m
#   optics  GOCART-2G Mie tables (monochromatic and RRTMG band files)
#
# Existing files are kept. Every file is checked against
# test_cases/inputs.sha256; a mismatch stops the script and leaves the file in
# place for inspection.
#
# The optics tables come from the NOAA UFS regression-test bucket. It carries
# no opticsBands_BRC.v1_5.RRTMG.nc, so the brown-carbon component
# (config_gocart2G_do_CA2Gbr) cannot be enabled from these files alone.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

GEOG_URL="https://www2.mmm.ucar.edu/wrf/src/wps_files"
MESH_URL="https://www2.mmm.ucar.edu/projects/mpas/atmosphere_meshes"
OPTICS_URL="https://noaa-ufs-regtests-pds.s3.amazonaws.com/input-data-20251015/GOCART/p8c_5d/ExtData"
MANIFEST="$G2G_REPO/test_cases/inputs.sha256"

fetch() {  # fetch <url> <path relative to inputs/>
    local url="$1" rel="$2" dest="$G2G_INPUTS/$2" want got
    mkdir -p "$(dirname "$dest")"
    if [ ! -s "$dest" ]; then
        echo "downloading $rel"
        curl -sS --fail --location --retry 3 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    want="$(awk -v p="$rel" '$2 == p {print $1}' "$MANIFEST")"
    [ -n "$want" ] || g2g_die "$rel has no entry in $MANIFEST"
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || g2g_die "checksum mismatch for $dest (expected $want, got $got)"
}

do_mesh() {
    local dir="$G2G_INPUTS/mesh/x1.40962" f
    for f in x1.40962.tar.gz x1.40962_static.tar.gz; do
        fetch "$MESH_URL/$f" "mesh/x1.40962/$f"
    done
    [ -s "$dir/x1.40962.grid.nc" ] || tar -xzf "$dir/x1.40962.tar.gz" -C "$dir"
    [ -s "$dir/x1.40962.static.nc" ] || tar -xzf "$dir/x1.40962_static.tar.gz" -C "$dir"
    echo "mesh ready: $dir"
}

do_geog() {
    local dir="$G2G_INPUTS/geog" f
    for f in erod clayfrac_5m sandfrac_5m; do
        fetch "$GEOG_URL/$f.tar.bz2" "geog/$f.tar.bz2"
        [ -s "$dir/$f/index" ] || tar -xjf "$dir/$f.tar.bz2" -C "$dir"
    done
    echo "geog ready: $dir"
}

do_optics() {
    local f
    for f in BC DU NI OC SS SU; do
        case "$f" in
            DU) v=v15_3 ;; NI) v=v2_5 ;; SS) v=v3_3 ;; *) v=v1_3 ;;
        esac
        fetch "$OPTICS_URL/optics/opticsBands_$f.$v.RRTMG.nc" "optics/raw/opticsBands_$f.$v.RRTMG.nc"
        fetch "$OPTICS_URL/monochromatic/optics_$f.$v.nc" "optics/raw/optics_$f.$v.nc"
    done
    fetch "$OPTICS_URL/monochromatic/optics_BRC.v1_5.nc" "optics/raw/optics_BRC.v1_5.nc"
    echo "optics ready: $G2G_INPUTS/optics/raw"
}

[ "$#" -gt 0 ] || set -- mesh geog optics
for what in "$@"; do
    case "$what" in
        mesh) do_mesh ;;
        geog) do_geog ;;
        optics) do_optics ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) g2g_die "unknown input set: $what" ;;
    esac
done
