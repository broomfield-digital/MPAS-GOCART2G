---
name: gocart2g-prepare-inputs
description: Download, derive, and verify MPAS-GOCART2G model inputs on a Linux workstation, including the mesh and static files, dust-source geog tiles, GOCART-2G optics tables, GFS meteorology through WPS ungrib, and zero-emission placeholder files. Use when inputs are missing, when a run needs a new start date or mesh, when a model log reports an unreadable or missing input file, or to explain which inputs are only available on Derecho.
---

# Prepare MPAS-GOCART2G inputs

Read `AGENTS.md` first; "How a run is configured" and "Where the inputs come
from" define what each input is for.

## Date-independent inputs

```bash
scripts/fetch_inputs.sh            # mesh + geog + optics
scripts/fetch_inputs.sh optics     # one set
```

Files land in `$G2G_WORK/inputs/` and are verified against
`test_cases/inputs.sha256`. On a checksum mismatch, stop and report it. Do not
edit the manifest to make a changed download pass.

## Meteorology for a start date

```bash
scripts/build_ungrib.sh            # once
scripts/prepare_gfs.sh YYYYMMDDHH  # writes inputs/gfs/YYYYMMDDHH/ungrib/GFS:YYYY-MM-DD_HH
```

The script's download path is verified for cycles from 2022 onward; the NOAA
bucket uses a different layout for early 2021. Set `CASE_CYCLE` in the case's
`case.env` to the same cycle.

## Emissions

`scripts/run_case.sh` calls `scripts/make_zero_emissions.py` during the init
stage. It reads the variable lists from the Registry in the source tree and
writes one all-zero file per emission stream plus stream blocks for each core.
Zero emissions are a software test input. Say so whenever results from such a
run are reported.

Real emissions come from `UPTEMPO/` (see its README files). That path needs
CAMS downloads from ECCAD, FINN text files, an MPAS SCRIP file for the mesh,
and ESMF regridding; none of it is automated here.

## Inputs kept on Derecho

`BACKGROUND_sulf.dat`, `BACKGROUND_dms.dat`, `BACKGROUND_ptrop.dat`, the
MERRA-2 aerosol intermediate files, the processed Example-1 emissions, and the
reference namelist and stream templates exist only on Derecho under
`/glade/campaign/acom/MUSICA/MPAS/`. Do not fabricate substitutes for a
science run.

Copying them needs the maintainer's NCAR password and Duo approval, so an
agent cannot run the transfer unattended. Ask the maintainer to run it:

```bash
scripts/fetch_derecho_inputs.sh --sets            # sets and their remote paths
scripts/fetch_derecho_inputs.sh --dry-run core    # names and total size only
scripts/fetch_derecho_inputs.sh core              # templates, background, optics, MERRA-2
```

Files land in `$G2G_WORK/inputs/derecho/` under the same relative paths. If
the internal disk is short of space, `G2G_BULK=/path/on/another/drive` sends
the large emission and grid directories there and links them into that tree;
the drive may be exFAT, and it must be mounted whenever those directories are
used. The `core` sets do not depend on the mesh. The `emis60` and `grid60` sets are on
the tutorial's 60-km mesh and cannot be used on another mesh; emissions for
another mesh must be regridded with `UPTEMPO/` from the `emis-raw` set.

The directory names in the script come from this repository's documentation,
not from a listing. To see what is really there, run
`scripts/derecho_inventory.sh` on a Derecho or Casper login node (it is
self-contained and read-only) and bring the output back. Its output can
contain user names, so keep it out of the repository.

## Rules for any new input file

- The model reads NetCDF through PnetCDF only. Confirm `ncdump -k` reports
  `classic`, `64-bit offset`, or `cdf5`; convert NetCDF-4 files with
  `nccopy -k cdf5`.
- Emission files need `xtime(Time, StrLen=64)` records before and after the
  whole run, and variables dimensioned `(Time, nCells)` on the exact mesh.
- A new mesh needs its own static file, partition files for the rank counts
  in use, and a time step of about 6 s per km of grid spacing.
- Record the source URL and SHA-256 of anything added to
  `scripts/fetch_inputs.sh` in `test_cases/inputs.sha256`.
