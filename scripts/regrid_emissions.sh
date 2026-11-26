#!/usr/bin/env bash
# Regrid the raw CAMS and FINN inventories onto an MPAS mesh with UPTEMPO.
#
#   scripts/regrid_emissions.sh [anth] [biog] [fire] [options]   (default: all three)
#
#   --mesh NAME          mesh prefix under $G2G_WORK/inputs/mesh/    [x1.40962]
#   --year YYYY          CAMS-GLOB-ANT year; also stamps the output  [2024]
#   --fire-start DATE    first day of fire emissions, YYYY-MM-DD     [2024-10-14]
#   --fire-end DATE      last day of fire emissions                  [2024-10-20]
#
# Needs the raw inventories: scripts/fetch_derecho_inputs.sh emis-raw-2024.
# Output goes to $G2G_WORK/inputs/emis/<mesh>/ under the file names the
# reference stream files use:
#   <mesh>-<year>-anth_<species>.MPAS.nc      seven species, monthly, by sector
#   <mesh>-<year>-biog_<species>.MPAS.nc      five species, monthly (2019 climatology)
#   FINNv2.5.1_modvrs_nrt_MOZART_<year>_<mesh>.static_hourly_netcdf3.nc
#
# The work is done by the tools in UPTEMPO/, unchanged; this script writes
# their YAML configuration, runs them, and renames the results. See the
# UPTEMPO README files for what each tool does.
#
# UPTEMPO needs ESMF's Python interface, which the model toolchain does not
# have. The first run creates a separate conda environment for it at
# $G2G_WORK/envs/uptempo (about 0.6 GB).
#
# Fire emissions must cover the whole run with a day to spare on each side:
# the model interpolates between the records before and after the model time.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

mesh=x1.40962
year=2024
fire_start=2024-10-14
fire_end=2024-10-20
steps=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        anth|biog|fire) steps+=("$1"); shift ;;
        --mesh) mesh="$2"; shift 2 ;;
        --year) year="$2"; shift 2 ;;
        --fire-start) fire_start="$2"; shift 2 ;;
        --fire-end) fire_end="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) g2g_die "unknown argument: $1" ;;
    esac
done
[ "${#steps[@]}" -gt 0 ] || steps=(anth biog fire)

raw="$G2G_INPUTS/derecho/input"
mesh_dir="$G2G_INPUTS/mesh/$mesh"
out="$G2G_INPUTS/emis/$mesh"
work="$out/work"
env_dir="$G2G_WORK/envs/uptempo"
py="$env_dir/bin/python"
uptempo="$G2G_REPO/UPTEMPO"
mkdir -p "$work" "$G2G_LOGS"

[ -r "$mesh_dir/$mesh.grid.nc" ] || g2g_die "missing $mesh_dir/$mesh.grid.nc (run scripts/fetch_inputs.sh mesh)"
[ -d "$raw/EMIS" ] || g2g_die "missing $raw/EMIS (run scripts/fetch_derecho_inputs.sh emis-raw-2024; is the bulk drive mounted?)"

if [ ! -x "$py" ]; then
    echo "creating the UPTEMPO environment at $env_dir (log: $G2G_LOGS/uptempo_env.log)"
    base="$(conda info --base 2>/dev/null)" || base=""
    [ -n "$base" ] || for base in "$HOME/miniforge3" "$HOME/miniconda3"; do
        [ -r "$base/etc/profile.d/conda.sh" ] && break
    done
    [ -r "$base/etc/profile.d/conda.sh" ] || g2g_die "conda not found"
    set +u
    # shellcheck disable=SC1091
    . "$base/etc/profile.d/conda.sh"
    set -u
    installer=conda
    command -v mamba >/dev/null && installer=mamba
    "$installer" create -y -q -p "$env_dir" -c conda-forge \
        python=3.12 esmpy=8.9.1 xarray netcdf4 pyyaml numpy cftime pandas \
        > "$G2G_LOGS/uptempo_env.log" 2>&1 || g2g_die "could not create $env_dir; see $G2G_LOGS/uptempo_env.log"
fi

scrip="$work/$mesh.scrip.nc"
[ -s "$scrip" ] || "$py" "$G2G_REPO/scripts/make_mpas_scrip.py" "$mesh_dir/$mesh.grid.nc" "$scrip"

run_uptempo() {  # run_uptempo <label> <tool.py> <config.yaml>
    local label="$1" tool="$2" config="$3" log="$G2G_LOGS/regrid_$1.log" start=$SECONDS
    echo "[$label] $tool (log: $log)"
    # The tools import one another, so they run from their own directory.
    (cd "$uptempo" && "$py" "$tool" "$config") > "$log" 2>&1 \
        || { tail -n 15 "$log" >&2; g2g_die "$label regridding failed; see $log"; }
    echo "[$label] finished in $((SECONDS - start)) s"
}

# UPTEMPO appends a creation date to each file it writes; move the newest
# match to the name the stream files expect.
collect() {  # collect <pattern in work/> <final name>
    local newest
    newest="$(ls -t $1 2>/dev/null | head -n 1)"
    [ -n "$newest" ] || g2g_die "no output matching $1"
    mv "$newest" "$out/$2"
    echo "  $2"
}

for step in "${steps[@]}"; do
    case "$step" in
    anth)
        # CAMS-GLOB-ANT name -> short name -> reference file name
        anth_species="black-carbon:bc:black-carbon organic-carbon:oc:organic-carbon ammonia:nh3:ammonia
                      carbon-monoxide:co:carbon-monoxide sulphur-dioxide:so2:sulfur-dioxide
                      isoprene:iso:isoprene monoterpenes:mnt:monoterpenes"
        {
            echo "year: $year"
            echo "species:"
            for s in $anth_species; do IFS=: read -r cams short _ <<< "$s"; echo "  - $cams: $short"; done
            echo "CAMS_grid_file: '$raw/Gridinfo_CAMS-GLOB-ANT_c20240709.nc'"
            echo "SERR_scrip_file: '$scrip'"
            echo "Regridding_weights_file: '$work/ESMF_Weight_CAMS-GLOB-ANT_to_$mesh.nc'"
            echo "dst_file_format: '$work/anth_{year}_SPC.nc'"
            echo "inp_file_format: '$raw/EMIS/CAMS_ANTH/CAMS-GLOB-ANT_v6.2_SPC_{year}.nc'"
            echo "sectors: []"
            # Agricultural waste burning is already in FINN.
            echo "sector_exclude: ['awb']"
        } > "$work/cams_anth.yaml"
        rm -f "$work"/anth_"$year"_*.nc
        run_uptempo anth Regrid_cams_anth_emis_to_MPAS.py "$work/cams_anth.yaml"
        for s in $anth_species; do
            IFS=: read -r _ short name <<< "$s"
            collect "$work/anth_${year}_${short}_c*.nc" "$mesh-$year-anth_$name.MPAS.nc"
        done
        ;;
    biog)
        biog_species="alpha-pinene:mnta beta-pinene:mntb carbon-monoxide:co isoprene:iso other-monoterpenes:mnt"
        {
            echo "year: $year"
            echo "species:"
            for s in $biog_species; do IFS=: read -r cams short <<< "$s"; echo "  - $cams: $short"; done
            echo "CAMS_grid_file: '$raw/Gridinfo_CAMS-GLOB-BIOG_c20260116.nc'"
            echo "SERR_scrip_file: '$scrip'"
            echo "Regridding_weights_file: '$work/ESMF_Weight_CAMS-GLOB-BIO_to_$mesh.nc'"
            echo "dst_file_format: '$work/biog_{year}_SPC.nc'"
            echo "inp_file_format: '$raw/EMIS/CAMS_BIOG/CAMS-GLOB-BIO_v3.1_SPC_2019.nc'"
            echo "sectors: []"
        } > "$work/cams_biog.yaml"
        rm -f "$work"/biog_"$year"_*.nc
        run_uptempo biog Regrid_cams_biog_emis_to_MPAS.py "$work/cams_biog.yaml"
        for s in $biog_species; do
            IFS=: read -r cams short <<< "$s"
            collect "$work/biog_${year}_${short}_c*.nc" "$mesh-$year-biog_$cams.MPAS.nc"
        done
        ;;
    fire)
        [ -r "$mesh_dir/$mesh.static.nc" ] || g2g_die "missing $mesh_dir/$mesh.static.nc"
        cat > "$work/finn.yaml" <<EOF
start_date: '$fire_start'
end_date: '$fire_end'
file_type: 'daily'
emis_dir: '$raw/EMIS/FINN2nrt/{year}/'
emis_file_pattern: 'FINNv2.5.1_modvrs_nrt_MOZART_{year}{month}*.txt'
dst_file_dir: '$work/'
output_file_pattern: 'finn_{year}{month}_{freq}.nc'
mpas_grid_file: '$mesh_dir/$mesh.static.nc'
HOURLY: true
lt_fac: [.43, .43, .43, .43, .43, .43, .43, .43, .43, 3., 6., 10., 14., 17., 14., 12., 9., 6., 3., .43, .43, .43, .43, .43]
output_format: 'NETCDF3_64BIT'
species_map:
  BC: bc_biob_modis
  OC: oc_biob_modis
  CO: co_biob_modis
  NH3: nh3_biob_modis
  SO2: so2_biob_modis
  ISOP: iso_biob_modis
  BIGENE: mnt_biob_modis
species_type:
  BC: aerosol
  OC: aerosol
  CO: gas
  NH3: gas
  SO2: gas
  ISOP: gas
  BIGENE: gas
EOF
        rm -f "$work"/finn_*_hourly.nc
        run_uptempo fire Regrid_FINN_to_MPAS.py "$work/finn.yaml"
        collect "$work/finn_*_hourly.nc" "FINNv2.5.1_modvrs_nrt_MOZART_${year}_$mesh.static_hourly_netcdf3.nc"
        ;;
    esac
done

echo "emission files in $out:"
du -sh "$out"/*.nc 2>/dev/null | sed 's|\t.*/|\t|'
