#!/usr/bin/env bash
# Stage and run an MPAS-GOCART2G test case on this workstation.
#
#   scripts/run_case.sh CASE [options]
#
#   CASE                    directory name under test_cases/ (for example natural_120km)
#   --name NAME             run directory name under $G2G_WORK/runs   [CASE]
#   --hours N               run length in hours                       [case.env]
#   --ranks N               MPI ranks for atmosphere_model            [case.env]
#   --history-interval I    interval of the full-state history stream [case.env]
#   --stage S               static | init | atm | check | all         [all]
#   --fresh                 redo the static and init stages even if their output exists
#
# Stages:
#   static  init_atmosphere pass 1: vertical grid plus the GOCART-2G dust
#           source fields (erod, clayfrac, sandfrac) -> <mesh>.static_chems.nc
#   init    init_atmosphere pass 2: GFS meteorology plus the emission and
#           background structures -> <mesh>.init.nc
#   atm     atmosphere_model
#   check   scripts/check_run.py on the run directory
#
# Two init passes are required. The emission flags make init_atmosphere read
# erod from its input file, so the dust fields must already be in that file;
# and the atmosphere core refuses an init file without the background
# dimensions that only the second pass writes.
#
# Both init passes run on one rank. The static pass interpolates geographic
# tiles, and only the serial path has been tested. The init pass takes about
# 15 s serially on the 120-km mesh.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

[ "$#" -ge 1 ] || g2g_die "usage: run_case.sh CASE [options]; see --help"
case "$1" in
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
case_name="$1"; shift
case_dir="$G2G_REPO/test_cases/$case_name"
[ -r "$case_dir/case.env" ] || g2g_die "no test case at $case_dir"
# shellcheck disable=SC1091
. "$case_dir/case.env"

run_name="$case_name"
hours="$CASE_HOURS"
ranks="$CASE_RANKS"
history_interval="$CASE_HISTORY_INTERVAL"
stage=all
fresh=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) run_name="$2"; shift 2 ;;
        --hours) hours="$2"; shift 2 ;;
        --ranks) ranks="$2"; shift 2 ;;
        --history-interval) history_interval="$2"; shift 2 ;;
        --stage) stage="$2"; shift 2 ;;
        --fresh) fresh=true; shift ;;
        *) g2g_die "unknown option: $1" ;;
    esac
done
case "$stage" in static|init|atm|check|all) ;; *) g2g_die "unknown stage: $stage" ;; esac
[[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ] || g2g_die "--hours must be a positive integer"
[[ "$ranks" =~ ^[0-9]+$ ]] && [ "$ranks" -gt 0 ] || g2g_die "--ranks must be a positive integer"

mesh="$CASE_MESH"
cycle="$CASE_CYCLE"
start_time="${cycle:0:4}-${cycle:4:2}-${cycle:6:2}_${cycle:8:2}:00:00"
start_day="${cycle:0:4}-${cycle:4:2}-${cycle:6:2}"
stop_day="$(date -u -d "$start_day ${cycle:8:2}:00:00 UTC + $hours hours" +%Y-%m-%d)"
run_duration="$(printf '%d_%02d:00:00' $((hours / 24)) $((hours % 24)))"

run="$G2G_RUNS/$run_name"
mesh_dir="$G2G_INPUTS/mesh/$mesh"
gfs="$G2G_INPUTS/gfs/$cycle/ungrib/GFS:${start_time:0:13}"
init_tree="$G2G_BUILD/init_atmosphere/gocartMPAS"
atm_tree="$G2G_BUILD/atmosphere/gocartMPAS"
chem_src="$G2G_REPO/gocartMPAS/src/core_atmosphere/chemistry"

want() { case "$stage" in all|"$1") return 0 ;; *) return 1 ;; esac; }

need_file() { [ -e "$1" ] || g2g_die "missing $1 ($2)"; }

render() {  # render <template> <output> [emission-stream fragment]
    local template="$1" out="$2" fragment="${3:-}"
    sed -e "s|@MESH@|$mesh|g" \
        -e "s|@START_TIME@|$start_time|g" \
        -e "s|@RUN_DURATION@|$run_duration|g" \
        -e "s|@HISTORY_INTERVAL@|$history_interval|g" \
        -e "s|@GEOG_PATH@|$G2G_INPUTS/geog|g" \
        "$template" > "$out.tmp"
    if [ -n "$fragment" ]; then
        sed -e "/@EMISSION_STREAMS@/{r $fragment" -e "d}" "$out.tmp" > "$out"
        rm -f "$out.tmp"
    else
        mv "$out.tmp" "$out"
    fi
    if grep -q '@[A-Z_]*@' "$out"; then
        g2g_die "unrendered placeholder left in $out"
    fi
}

# Run one model executable and fail loudly: MPAS can exit 0 after logging errors.
run_model() {  # run_model <core> <ranks> <label>
    local core="$1" n="$2" label="$3" log="log.$1.0000.out"
    rm -f log."$core".*.out log."$core".*.err
    echo "[$label] mpiexec -n $n ./${core}_model  (in $run)"
    local start=$SECONDS status=0
    mpiexec -n "$n" "./${core}_model" > "$label.stdout" 2>&1 || status=$?
    local elapsed=$((SECONDS - start))
    if [ "$status" -ne 0 ] || ! grep -q "Critical error messages = *0" "$log" 2>/dev/null \
        || ! grep -q "Error messages = *0" "$log" 2>/dev/null || ls log."$core".*.err >/dev/null 2>&1; then
        grep -h -n "ERROR" "$log" log."$core".*.err 2>/dev/null | head -20 >&2 || true
        tail -n 5 "$label.stdout" >&2
        g2g_die "$label failed (exit $status); see $run/$log and $run/$label.stdout"
    fi
    cp "$log" "log.$label.out"
    echo "[$label] finished in $elapsed s"
}

g2g_activate
mkdir -p "$run"
g2g_require_symlinks "$run"
cd "$run"

if want static || want init; then
    need_file "$init_tree/init_atmosphere_model" "run scripts/build_model.sh init_atmosphere"
    need_file "$mesh_dir/$mesh.static.nc" "run scripts/fetch_inputs.sh mesh"
    ln -sf "$init_tree/init_atmosphere_model" .
    ln -sf "$mesh_dir/$mesh.static.nc" .
    # The decomposition prefix must resolve even though one rank reads no partition file.
    ln -sf "$mesh_dir/$mesh.graph.info.part.$ranks" .
fi

if want static; then
    if [ -s "$mesh.static_chems.nc" ] && ! $fresh; then
        echo "[static] keeping existing $mesh.static_chems.nc (use --fresh to rebuild)"
    else
        for tiles in erod clayfrac_5m sandfrac_5m; do
            need_file "$G2G_INPUTS/geog/$tiles/index" "run scripts/fetch_inputs.sh geog"
        done
        rm -f "$mesh.static_chems.nc"
        render "$case_dir/namelist.init_atmosphere.static_chems" namelist.init_atmosphere
        render "$case_dir/streams.init_atmosphere.static_chems" streams.init_atmosphere
        run_model init_atmosphere 1 static
        [ -s "$mesh.static_chems.nc" ] || g2g_die "static stage wrote no $mesh.static_chems.nc"
    fi
fi

if want init; then
    if [ -s "$mesh.init.nc" ] && ! $fresh; then
        echo "[init] keeping existing $mesh.init.nc (use --fresh to rebuild)"
    else
        need_file "$mesh.static_chems.nc" "run the static stage first"
        need_file "$gfs" "run scripts/prepare_gfs.sh $cycle"
        ln -sf "$gfs" .
        rm -f "$mesh.init.nc" "$mesh".zero.*.nc
        python "$G2G_REPO/scripts/make_zero_emissions.py" \
            --chemistry-dir "$chem_src" --mesh "$mesh.static_chems.nc" --grid-name "$mesh" \
            --start "$start_day" --stop "$stop_day" --outdir "$run" \
            --streams-atmosphere-out streams.emissions.atmosphere \
            --streams-init-out streams.emissions.init_atmosphere
        render "$case_dir/namelist.init_atmosphere.init" namelist.init_atmosphere
        render "$case_dir/streams.init_atmosphere.init" streams.init_atmosphere streams.emissions.init_atmosphere
        run_model init_atmosphere 1 init
        [ -s "$mesh.init.nc" ] || g2g_die "init stage wrote no $mesh.init.nc"
    fi
fi

if want atm; then
    need_file "$atm_tree/atmosphere_model" "run scripts/build_model.sh atmosphere"
    need_file "$mesh.init.nc" "run the init stage first"
    need_file streams.emissions.atmosphere "run the init stage first"
    need_file "$mesh_dir/$mesh.graph.info.part.$ranks" "no partition file for $ranks ranks"
    # The emission files written by the init stage must still bracket this run.
    last_record="$(ncdump -v xtime "$mesh.zero.anth_bc_emissions.nc" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_' | tail -1)"
    [[ "${last_record%_}" > "$stop_day" ]] \
        || g2g_die "emission files end at ${last_record%_}, before the run stops ($stop_day); rerun with --stage init --fresh"

    ln -sf "$atm_tree/atmosphere_model" .
    ln -sf "$mesh_dir/$mesh.graph.info.part.$ranks" .
    for f in "$atm_tree"/src/core_atmosphere/physics/physics_wrf/files/* "$atm_tree"/MP_THOMPSON_*_DATA.DBL; do
        ln -sf "$f" .
    done
    need_file MP_THOMPSON_QRacrQG_DATA.DBL "run scripts/build_model.sh atmosphere"
    for table in $CASE_OPTICS; do
        for f in "optics_$table.nc" "opticsBands_$table.RRTMG.nc"; do
            need_file "$G2G_INPUTS/optics/raw/$f" "run scripts/fetch_inputs.sh optics"
            ln -sf "$G2G_INPUTS/optics/raw/$f" .
        done
    done
    # Stream lists generated by the build follow the Registry of that build.
    cp "$atm_tree"/stream_list.atmosphere.* .
    cp "$case_dir"/stream_list.atmosphere.* .
    render "$case_dir/namelist.atmosphere" namelist.atmosphere
    render "$case_dir/streams.atmosphere" streams.atmosphere streams.emissions.atmosphere
    rm -f history.*.nc diag.*.nc aerosol.*.nc
    run_model atmosphere "$ranks" atmosphere
    cat > run_info.txt <<EOF
case=$case_name
mesh=$mesh
start_time=$start_time
hours=$hours
ranks=$ranks
source_commit=$(git -C "$G2G_REPO" rev-parse HEAD)
build_source_commit=$(grep '^source_commit=' "$G2G_BUILD/atmosphere/BUILD_INFO" 2>/dev/null | cut -d= -f2)
EOF
fi

if want check; then
    python "$G2G_REPO/scripts/check_run.py" "$run" --hours "$hours"
fi
