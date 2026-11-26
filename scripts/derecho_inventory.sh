#!/usr/bin/env bash
# Inventory the MPAS-GOCART2G inputs on Derecho's Campaign Storage.
#
# Run this ON a Derecho or Casper login node. It only reads.
#
#   bash derecho_inventory.sh > derecho_inventory.txt
#   bash derecho_inventory.sh --with-templates > derecho_inventory.txt
#
#   --with-templates   also print the text of the namelist and stream templates
#
#   DERECHO_ROOT       directory to inventory  [/glade/campaign/acom/MUSICA/MPAS]
#
# The script is self-contained: it needs only bash, find, du, and sort, so it
# can be copied to Derecho on its own. It prints sizes, dates, and paths, never
# file owners. The result may still contain user names inside paths or template
# text, so do not commit it to a public repository.
#
# What it answers, for the workstation setup described in AGENTS.md:
#   * exact names and sizes of everything scripts/fetch_derecho_inputs.sh copies
#   * whether any product already exists for the 120-km mesh (x1.40962)
#   * whether the brown-carbon RRTMG optics table exists
#   * which raw emission inventories are available for UPTEMPO

set -uo pipefail

root="${DERECHO_ROOT:-/glade/campaign/acom/MUSICA/MPAS}"
with_templates=false
for arg in "$@"; do
    case "$arg" in
        --with-templates) with_templates=true ;;
        -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -d "$root" ]; then
    echo "ERROR: $root is not a directory here. Run this on a Derecho or Casper login node." >&2
    exit 1
fi

MAX_LINES=400

section() { printf '\n==== %s ====\n' "$1"; }

# Size, date, and path of every file under a directory, largest trees truncated.
list_dir() {  # list_dir <path relative to root> [max depth]
    local rel="$1" depth="${2:-3}" dir="$root/$1" count
    section "$rel"
    if [ ! -e "$dir" ]; then
        echo "MISSING"
        return
    fi
    echo "total: $(du -shL "$dir" 2>/dev/null | cut -f1)"
    count="$(find -L "$dir" -maxdepth "$depth" -type f 2>/dev/null | wc -l)"
    echo "files (to depth $depth): $count"
    find -L "$dir" -maxdepth "$depth" \( -type f -o -type l \) -printf '%12s  %TY-%Tm-%Td  %P\n' 2>/dev/null \
        | sort -k3 | head -n "$MAX_LINES"
    [ "$count" -le "$MAX_LINES" ] || echo "... truncated at $MAX_LINES of $count files"
}

echo "MPAS-GOCART2G Derecho inventory"
echo "root: $root"
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

section "top level of root"
find "$root" -maxdepth 1 -mindepth 1 -printf '%y  %P\n' 2>/dev/null | sort -k2

section "directory sizes under input/ (depth 2)"
du -hL --max-depth=2 "$root/input" 2>/dev/null | sed "s|$root/||" | sort -k2

# Everything scripts/fetch_derecho_inputs.sh knows how to copy.
list_dir input/namelist_files
list_dir input/stream_files
list_dir scripts
list_dir input/optics_files
list_dir input/BACKGROUND
list_dir input/Example-1/BACKGROUND
list_dir input/Example-1/GFS
list_dir input/Example-1/MERRA2
list_dir input/Example-1/EMIS
list_dir input/Example-1/GRID
list_dir input/MERRA2 2
list_dir input/EMIS 3

section "loose files directly under input/"
find -L "$root/input" -maxdepth 1 -type f -printf '%12s  %TY-%Tm-%Td  %P\n' 2>/dev/null | sort -k3

# Print matches of a find expression under the root, or "none".
search() {
    local out
    out="$(find -L "$root" "$@" -printf '%12s  %TY-%Tm-%Td  %P\n' 2>/dev/null | sort -k3 | head -n "$MAX_LINES")"
    echo "${out:-none}"
}

section "anything for the 120-km mesh (name contains 40962)"
search -iname '*40962*'

section "meshes with products (distinct x<N>.<cells> prefixes)"
find -L "$root/input" -maxdepth 4 -type f -name 'x[0-9]*.[0-9]*.*' -printf '%f\n' 2>/dev/null \
    | sed -E 's/^(x[0-9]+\.[0-9]+).*/\1/' | sort | uniq -c

section "regridding support files (SCRIP, ESMF weights, grid info)"
search -type f \( -iname '*scrip*.nc' -o -iname 'ESMF_Weight*' -o -iname 'Gridinfo*' \)

section "brown-carbon RRTMG optics table"
search -name 'opticsBands_BRC*'

section "NetCDF format of sample files (the model reads classic, 64-bit offset, or cdf5 only)"
if command -v ncdump >/dev/null 2>&1; then
    for sample in \
        "$(find -L "$root/input/Example-1/EMIS" -maxdepth 1 -name '*.nc' -print -quit 2>/dev/null)" \
        "$(find -L "$root/input/Example-1/GRID" -maxdepth 1 -name '*static_chems*.nc' -print -quit 2>/dev/null)" \
        "$(find -L "$root/input/optics_files" -maxdepth 1 -name '*.nc' -print -quit 2>/dev/null)"; do
        [ -n "$sample" ] && echo "$(ncdump -k "$sample" 2>&1)  ${sample#"$root"/}"
    done
else
    echo "ncdump not on PATH (try: module load netcdf); skipped"
fi

if $with_templates; then
    for rel in input/namelist_files input/stream_files; do
        while IFS= read -r file; do
            # Text files only; templates are small.
            if [ "$(stat -Lc %s "$file")" -le 200000 ] && grep -Iq . "$file" 2>/dev/null; then
                section "TEXT ${file#"$root"/}"
                cat "$file"
            fi
        done < <(find -L "$root/$rel" -maxdepth 2 -type f 2>/dev/null | sort)
    done
fi

section "end of inventory"
