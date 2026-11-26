#!/usr/bin/env bash
# Copy MPAS-GOCART2G inputs from Derecho's Campaign Storage to this workstation.
#
#   scripts/fetch_derecho_inputs.sh [--dry-run] SET [SET ...]
#   scripts/fetch_derecho_inputs.sh --sets
#
#   --dry-run   list what would be copied and its total size; copy nothing
#   --sets      print the sets and their remote paths, then exit
#
# Run it on the workstation. It pulls with one rsync over SSH, so there is one
# NCAR password and Duo prompt per invocation. Files land under
# $G2G_WORK/inputs/derecho/ with the same relative paths as on Derecho, and a
# rerun copies only what is missing or changed.
#
#   DERECHO_USER   NCAR user name                 [$USER]
#   DERECHO_HOST   SSH host; "local" reads DERECHO_ROOT from this machine
#                                                 [derecho.hpc.ucar.edu]
#   DERECHO_ROOT   remote root directory          [/glade/campaign/acom/MUSICA/MPAS]
#
# Sets that do not depend on the mesh, usable with the 120-km test cases:
#   templates    reference namelist and stream templates, submission scripts
#   background   BACKGROUND_*.dat oxidant, DMS, and tropopause climatologies
#   optics       GOCART-2G Mie tables, including any brown-carbon band file
#   merra2       MERRA-2 aerosol intermediate files of Example-1
#   core         all four of the above
#
# Sets tied to the tutorial's 60-km mesh (x1.163842):
#   gfs          GFS intermediate files of Example-1
#   emis60       processed emission files of Example-1
#   grid60       grid, static, static_chems, and partition files of Example-1
#   example1     gfs + merra2 + emis60 + grid60 + background
#
# Raw material for regridding emissions to another mesh with UPTEMPO:
#   emis-raw     CAMS and FINN inventories; size unknown, use --dry-run first
#   regrid60     60-km grid, static, and SCRIP files kept directly under input/
#
# The directory names come from docs/tutorial.md, util/submit_mpas_gocart.bash,
# and the UPTEMPO configuration files. Their contents were not visible when
# this script was written; scripts/derecho_inventory.sh, run on Derecho, lists
# them. A path that does not exist is reported and the other paths still copy.
#
# NCAR recommends Globus for large transfers. The collection for these paths is
# "NCAR Campaign Storage".

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/g2g_env.sh"

user="${DERECHO_USER:-$USER}"
host="${DERECHO_HOST:-derecho.hpc.ucar.edu}"
root="${DERECHO_ROOT:-/glade/campaign/acom/MUSICA/MPAS}"
dest="$G2G_INPUTS/derecho"

set_paths() {  # print the paths, relative to the root, that make up a set
    case "$1" in
        templates)  echo "input/namelist_files/ input/stream_files/ scripts/" ;;
        background) echo "input/BACKGROUND/ input/Example-1/BACKGROUND/" ;;
        optics)     echo "input/optics_files/" ;;
        merra2)     echo "input/Example-1/MERRA2/" ;;
        core)       echo "$(set_paths templates) $(set_paths background) $(set_paths optics) $(set_paths merra2)" ;;
        gfs)        echo "input/Example-1/GFS/" ;;
        emis60)     echo "input/Example-1/EMIS/" ;;
        grid60)     echo "input/Example-1/GRID/" ;;
        example1)   echo "input/Example-1/" ;;
        emis-raw)   echo "input/EMIS/" ;;
        regrid60)   echo "input/x1.163842.grid.nc input/x1.163842.static.nc input/mpas_scrip.163842.nc" ;;
        *) return 1 ;;
    esac
}
ALL_SETS="templates background optics merra2 core gfs emis60 grid60 example1 emis-raw regrid60"

dry_run=false
sets=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --sets)
            for s in $ALL_SETS; do
                printf '%-11s' "$s"
                for p in $(set_paths "$s"); do printf ' %s' "$root/$p"; done
                printf '\n'
            done
            exit 0 ;;
        -h|--help) sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) g2g_die "unknown option: $arg" ;;
        *) set_paths "$arg" >/dev/null || g2g_die "unknown set: $arg (see --sets)"; sets+=("$arg") ;;
    esac
done
[ "${#sets[@]}" -gt 0 ] || g2g_die "name at least one set (see --help)"
command -v rsync >/dev/null || g2g_die "rsync not on PATH"

# Unique relative paths, in the order requested.
declare -A seen=()
paths=()
for s in "${sets[@]}"; do
    for p in $(set_paths "$s"); do
        [ -n "${seen[$p]:-}" ] || { seen[$p]=1; paths+=("$p"); }
    done
done

# One rsync, several sources. "/./" marks where --relative starts keeping the
# path, so input/optics_files/x.nc lands at $dest/input/optics_files/x.nc.
# After the first remote source, further sources on the same host start with ":".
sources=()
if [ "$host" = local ]; then
    [ -d "$root" ] || g2g_die "DERECHO_HOST=local but $root is not a directory here"
    for p in "${paths[@]}"; do sources+=("$root/./$p"); done
    where="$root"
else
    prefix="$user@$host"
    for p in "${paths[@]}"; do
        sources+=("$prefix:$root/./$p")
        prefix=""
    done
    where="$user@$host:$root"
fi

# -L copies what a symlink points to: the Example-1 directories may link into
# other parts of /glade. Permissions are not preserved, so group-only files
# from Campaign Storage stay readable here.
opts=(--recursive --times --copy-links --relative --partial --human-readable --chmod=Du+rwx,Fu+rw)
if $dry_run; then
    opts+=(--dry-run --verbose --stats)
else
    opts+=(--info=progress2,stats1)
fi

mkdir -p "$dest" "$G2G_LOGS"
log="$G2G_LOGS/fetch_derecho_inputs.log"
echo "from: $where"
echo "to:   $dest"
printf 'sets: %s\n' "${sets[*]}"
$dry_run && echo "dry run: nothing will be copied"
[ "$host" = local ] || echo "Expect one password and Duo prompt."

status=0
rsync "${opts[@]}" "${sources[@]}" "$dest/" 2> >(tee "$log" >&2) || status=$?

case "$status" in
    0) ;;
    23|24)
        echo
        echo "WARNING: rsync reported paths it could not copy (exit $status); see $log" >&2
        echo "Missing remote paths are expected if a directory name differs on Derecho." >&2 ;;
    *) g2g_die "rsync failed with exit $status; see $log" ;;
esac

if ! $dry_run; then
    echo
    echo "copied into $dest:"
    for p in "${paths[@]}"; do
        if [ -e "$dest/$p" ]; then
            printf '  %-8s %s\n' "$(du -sh "$dest/$p" | cut -f1)" "$p"
        else
            printf '  %-8s %s\n' "MISSING" "$p"
        fi
    done
fi
exit $(( status == 0 ? 0 : 3 ))
