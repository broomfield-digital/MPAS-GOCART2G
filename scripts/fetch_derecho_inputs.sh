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
#   G2G_BULK       optional second location, for example an external drive,
#                  that receives the large emission and grid directories
#
# With G2G_BULK set, input/EMIS, input/Example-1/EMIS, and input/Example-1/GRID
# are stored under $G2G_BULK/derecho/ and reached through symbolic links in
# $G2G_WORK/inputs/derecho/, so there is still one tree to read from. The
# drive may be exFAT. The other directories stay in G2G_WORK on purpose: the
# GFS and MERRA-2 intermediate files have a colon in their names (GFS:2024-...),
# which exFAT, FAT, and NTFS cannot store. The drive must be mounted whenever
# the linked directories are read or updated.
#
# Sizes are from the inventory of 2026-11-26 (scripts/derecho_inventory.txt).
#
# Sets that do not depend on the mesh, usable with the 120-km test cases:
#   templates      0.1 MB  reference namelist and stream templates, submit script
#   background     0.7 GB  BACKGROUND_{sulf,dms,ptrop}.dat climatologies
#   optics         1.5 GB  the Mie tables the reference namelist names (v*_5)
#   merra2         1.9 GB  MERRA-2 aerosol intermediate file for 2024-10-15 00 UTC
#   core           4.1 GB  all four of the above
#   merra2-all      11 GB  MERRA-2 intermediate files for 2024-10-15 to 20
#   optics-extra   2.4 GB  optics_new_files/: also the Registry-default versions
#   gfs            4.6 GB  GFS intermediate files for 2024-10-15 to 20
#
# Sets tied to the tutorial's 60-km mesh (x1.163842):
#   emis60          11 GB  processed emission files of Example-1
#   grid60         0.8 GB  grid, static, static_chems, and partition files
#   example1        28 GB  gfs + merra2-all + emis60 + grid60 + background
#
# Raw material for regridding emissions to another mesh with UPTEMPO:
#   emis-raw-2024  7.4 GB  CAMS-GLOB-ANT 2024, CAMS-GLOB-BIO, FINN 2024 text
#                          files, and the two CAMS grid-description files
#   emis-raw        38 GB  every year of CAMS-GLOB-ANT plus FINN 2012
#   regrid60       0.6 GB  60-km grid, static, and SCRIP files under input/
#
# Never copied: archive/ directories (superseded files) and the twelve monthly
# BACKGROUND_sulf_NN.dat pieces, which the model does not read.
#
# A path that does not exist is reported and the other paths still copy.
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
        background) echo "input/BACKGROUND/" ;;
        optics)     echo "input/optics_files/" ;;
        optics-extra) echo "input/optics_files/optics_new_files/" ;;
        merra2)     echo "input/Example-1/MERRA2/MERRA2:2024-10-15_00" ;;
        merra2-all) echo "input/Example-1/MERRA2/" ;;
        core)       echo "$(set_paths templates) $(set_paths background) $(set_paths optics) $(set_paths merra2)" ;;
        gfs)        echo "input/Example-1/GFS/" ;;
        emis60)     echo "input/Example-1/EMIS/" ;;
        grid60)     echo "input/Example-1/GRID/" ;;
        example1)   echo "input/Example-1/" ;;
        emis-raw)   echo "input/EMIS/" ;;
        emis-raw-2024) echo "input/EMIS/ input/Gridinfo_CAMS-GLOB-ANT_c20240709.nc input/Gridinfo_CAMS-GLOB-BIOG_c20260116.nc" ;;
        regrid60)   echo "input/x1.163842.grid.nc input/x1.163842.static.nc input/mpas_scrip.163842.nc" ;;
        *) return 1 ;;
    esac
}
ALL_SETS="templates background optics merra2 core merra2-all optics-extra gfs emis60 grid60 example1 emis-raw-2024 emis-raw regrid60"

# Directories that may live on G2G_BULK: large, and free of colon-named files.
BULK_PATHS="input/EMIS input/Example-1/EMIS input/Example-1/GRID"

dry_run=false
sets=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --sets)
            for s in $ALL_SETS; do
                printf '%-14s' "$s"
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

has_set() { local s; for s in "${sets[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# rsync filter rules; the first matching rule decides.
filters=(--exclude=archive/ '--exclude=BACKGROUND_sulf_[0-9][0-9].dat')
if has_set emis-raw-2024; then
    has_set emis-raw && g2g_die "choose either emis-raw or emis-raw-2024"
    filters+=('--include=CAMS-GLOB-ANT_v6.2_*_2024.nc' '--exclude=CAMS-GLOB-ANT_*' --exclude=FINN25/)
fi
if (has_set optics || has_set core) && ! has_set optics-extra; then
    filters+=(--exclude=optics_new_files/)
fi

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
# --keep-dirlinks makes rsync write through the G2G_BULK links instead of
# replacing them with directories.
opts=(--recursive --times --copy-links --relative --keep-dirlinks --partial --human-readable --chmod=Du+rwx,Fu+rw)
if $dry_run; then
    opts+=(--dry-run --verbose --stats)
else
    opts+=(--info=progress2,stats1)
fi

mkdir -p "$dest" "$G2G_LOGS"
log="$G2G_LOGS/fetch_derecho_inputs.log"

if [ -n "${G2G_BULK:-}" ]; then
    [ -d "$G2G_BULK" ] && [ -w "$G2G_BULK" ] || g2g_die "G2G_BULK=$G2G_BULK is not a writable directory (is the drive mounted?)"
fi
for bp in $BULK_PATHS; do
    covered=false
    for p in "${paths[@]}"; do
        case "$bp/" in "$p"*) covered=true ;; esac
    done
    $covered || continue
    # A link whose drive is not mounted would be replaced by a real directory
    # and the data would land on the wrong disk, so stop instead.
    if [ -L "$dest/$bp" ] && [ ! -d "$dest/$bp" ]; then
        g2g_die "$dest/$bp points to $(readlink "$dest/$bp"), which is not available; mount that drive first"
    fi
    if [ -n "${G2G_BULK:-}" ]; then
        if [ -L "$dest/$bp" ]; then
            echo "bulk: $bp -> $(readlink "$dest/$bp")"
        elif [ -e "$dest/$bp" ]; then
            echo "bulk: $bp already exists in $dest; leaving it there"
        elif $dry_run; then
            echo "bulk: $bp would be stored in $G2G_BULK/derecho/$bp"
        else
            mkdir -p "$G2G_BULK/derecho/$bp" "$(dirname "$dest/$bp")"
            ln -s "$G2G_BULK/derecho/$bp" "$dest/$bp"
            echo "bulk: $bp -> $G2G_BULK/derecho/$bp"
        fi
    fi
done

# Fail early, with a useful message, if the destination cannot hold the
# colon-named intermediate files that some sets contain.
if ! ( : > "$dest/.g2g_probe:$$" ) 2>/dev/null; then
    g2g_die "$dest cannot store file names containing ':' (exFAT, FAT, or NTFS?). Keep G2G_WORK on a Linux filesystem and use G2G_BULK for the external drive"
fi
rm -f "$dest/.g2g_probe:$$"
echo "from: $where"
echo "to:   $dest"
printf 'sets: %s\n' "${sets[*]}"
$dry_run && echo "dry run: nothing will be copied"
[ "$host" = local ] || echo "Expect one password and Duo prompt."

status=0
rsync "${opts[@]}" "${filters[@]}" "${sources[@]}" "$dest/" 2> >(tee "$log" >&2) || status=$?

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
            printf '  %-8s %s\n' "$(du -shL "$dest/$p" | cut -f1)" "$p"
        else
            printf '  %-8s %s\n' "MISSING" "$p"
        fi
    done
fi
exit $(( status == 0 ? 0 : 3 ))
