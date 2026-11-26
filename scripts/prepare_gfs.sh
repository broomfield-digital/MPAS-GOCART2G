#!/usr/bin/env bash
# Download a GFS 0.25-degree analysis and convert it for init_atmosphere.
#
#   scripts/prepare_gfs.sh YYYYMMDDHH
#
# Writes $G2G_WORK/inputs/gfs/YYYYMMDDHH/ungrib/GFS:YYYY-MM-DD_HH.
#
# The f000 file is used, not the .anl file: the .anl file has the pressure-
# level analysis but no soil, skin-temperature, sea-ice, snow, or land-sea
# fields, and init_atmosphere needs those. The result holds 33 pressure
# levels plus the surface, so namelists use config_nfglevels = 34.
#
# Requires scripts/build_ungrib.sh to have been run.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

[ "$#" -eq 1 ] || g2g_die "usage: prepare_gfs.sh YYYYMMDDHH"
stamp="$1"
[[ "$stamp" =~ ^[0-9]{10}$ ]] || g2g_die "cycle must be YYYYMMDDHH, got '$stamp'"
ymd="${stamp:0:8}"
hh="${stamp:8:2}"
date_tag="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}_${hh}"

wps="$G2G_TOOLS/WPS-4.6.0"
ungrib="$wps/_build/ungrib/ungrib"
[ -x "$ungrib" ] || g2g_die "ungrib not built; run scripts/build_ungrib.sh"

dir="$G2G_INPUTS/gfs/$stamp"
grib="$dir/gfs.t${hh}z.pgrb2.0p25.f000"
out="$dir/ungrib/GFS:$date_tag"
if [ -s "$out" ]; then
    echo "already prepared: $out"
    exit 0
fi

mkdir -p "$dir/ungrib"
if [ ! -s "$grib" ]; then
    url="https://noaa-gfs-bdp-pds.s3.amazonaws.com/gfs.$ymd/$hh/atmos/gfs.t${hh}z.pgrb2.0p25.f000"
    echo "downloading $url"
    curl -sS --fail --location --retry 3 -o "$grib.part" "$url"
    mv "$grib.part" "$grib"
fi

cd "$dir/ungrib"
ln -sf "$grib" GRIBFILE.AAA
cp "$wps/ungrib/Variable_Tables/Vtable.GFS" Vtable
cat > namelist.wps <<EOF
&share
 wrf_core = 'ARW',
 max_dom = 1,
 start_date = '${date_tag}:00:00',
 end_date = '${date_tag}:00:00',
 interval_seconds = 21600,
/

&ungrib
 out_format = 'WPS',
 prefix = 'GFS',
/
EOF

echo "running ungrib (log: $dir/ungrib/ungrib.stdout)"
"$ungrib" > ungrib.stdout 2>&1 || g2g_die "ungrib failed; see $dir/ungrib/ungrib.stdout"
[ -s "$out" ] || g2g_die "ungrib wrote no $out; see $dir/ungrib/ungrib.stdout"
grep -q "Successful completion of program ungrib" ungrib.stdout \
    || g2g_die "ungrib did not report success; see $dir/ungrib/ungrib.stdout"
echo "wrote $out"
