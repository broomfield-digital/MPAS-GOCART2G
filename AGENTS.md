# Agent Guide: MPAS-GOCART2G

Shared instructions for coding agents (Claude Code, Codex, and others) working
in this repository. `CLAUDE.md` imports this file, so edit only this one.

MPAS-GOCART2G couples the MPAS-Atmosphere dynamical core (v8.4.1) to the
GOCART-2G aerosol module. This repository is a fork of `NCAR/MPAS-GOCART2G`.
The upstream documentation (`docs/tutorial.md`) covers NSF NCAR's Derecho only.
The fork adds what is needed to build and run test cases on a Linux
workstation: `scripts/`, `test_cases/`, and these agent files.

## Ground rules

- **Remotes.** `origin` is the fork. Do not push to, or open pull requests
  against, `NCAR/MPAS-GOCART2G` unless the maintainer asks. `gh pr create` in a
  fork targets the parent by default, so always pass `--repo` explicitly.
- **Public repository.** Commit no credentials, host names, or personal paths.
  Scripts take locations from `G2G_WORK`, never from a hard-coded home.
- **Never build inside the repository.** The repository tracks generated
  files (`gocartMPAS/src/core_*/Registry_processed.xml` and
  `gocartMPAS/src/core_*/inc/*.inc`) that every build rewrites. Use
  `scripts/build_model.sh`, which builds in a copy under `$G2G_WORK/build`.
  If an in-tree build happened anyway, remove the ignored build products with
  `git clean -fdX gocartMPAS` and restore only the generated files with
  `git checkout -- gocartMPAS/src/core_atmosphere/Registry_processed.xml
  gocartMPAS/src/core_init_atmosphere/Registry_processed.xml
  gocartMPAS/src/core_atmosphere/inc gocartMPAS/src/core_init_atmosphere/inc`.
- **Keep fork additions out of upstream directories.** New files go in
  `scripts/`, `test_cases/`, `.agents/`, or the top level, so merges from
  upstream stay conflict-free. Change files under `gocartMPAS/`, `UPTEMPO/`,
  `init_MPAS-GOCART2G/`, `docs/`, or `util/` only when the task is a model or
  upstream-documentation change.
- **Data stays out of git.** Inputs, builds, and run directories live under
  `$G2G_WORK` (default `$HOME/Data/MPAS-GOCART2G`). Check free disk space
  before long runs: one full-state history frame on the 120-km mesh is 0.66 GB.
- **Report what was established.** "The run finished without errors" and "the
  aerosol fields are scientifically right" are different claims. The checker
  decides only the first; scientific judgment rests with the maintainers.
- `CONTRIBUTING.md` sets the attribution and provenance expectations for any
  code reuse; it applies to agent-produced work too.

## Layout

| Path | Contents |
|---|---|
| `gocartMPAS/` | MPAS-A v8.4.1 source with GOCART-2G (upstream) |
| `gocartMPAS/src/core_atmosphere/chemistry/` | GOCART-2G coupling: `mpas_chemistry_gocart2G_*.F90` (run time), `mpas_chemistry_init_gocart2G_*.F90` (initialization), `Registry_*gocart2G*.xml` (variables, namelist options) |
| `gocartMPAS/src/core_atmosphere/chemistry/gocart2G/` | GOCART-2G process code ported from GEOS |
| `UPTEMPO/` | emission preprocessing (CAMS, FINN) onto an MPAS mesh (upstream) |
| `init_MPAS-GOCART2G/` | MERRA-2 to MPAS intermediate-file conversion (upstream) |
| `docs/`, `util/` | Derecho tutorial and PBS submission script (upstream) |
| `scripts/` | workstation build, input, run, and check scripts (fork) |
| `test_cases/` | tracked reference namelists and streams per test case (fork) |
| `.agents/skills/` | task recipes; each entry in `.claude/skills/` is a symlink to one of them |

## Workstation quick start

Requires a conda environment (default name `mpas`) providing GNU Fortran,
Open MPI, NetCDF, PnetCDF, CMake, and Python with `numpy` and `netCDF4`.
Set `G2G_CONDA_ENV` or `G2G_WORK` to override the defaults in
`scripts/g2g_env.sh`.

```bash
scripts/build_model.sh              # both cores + Thompson tables, about 12 min
scripts/fetch_inputs.sh             # mesh, geog tiles, optics tables, about 1.2 GB
scripts/build_ungrib.sh             # WPS ungrib, once
scripts/prepare_gfs.sh 2024101500   # GFS analysis -> intermediate file
scripts/run_case.sh natural_120km   # static + init + 3-hour run + check
```

Every script is idempotent, stops on the first failure, and names the log to
read. `scripts/run_case.sh --help` lists the stage and length options.

## How the model is built

- Build command: `make gnu CORE=<core> GOCART2G=true`, once per core. Reals
  are single precision by default, as in the upstream tutorial.
- **I/O layer is SMIOL, not PIO.** The optics reader
  (`gocart2G/GOCART2G_MieMod_smiol.F90`) calls SMIOL directly, and the Makefile
  links SMIOL only when `PIO` is unset. Consequence: every NetCDF file the
  model reads must be classic, 64-bit offset, or CDF-5. A NetCDF-4/HDF5 file
  fails to open. Check with `ncdump -k`; convert with `nccopy -k cdf5`.
- **Build serially.** `make -j` fails in `core_init_atmosphere`: the GOCART-2G
  init modules are ordered after `init_atm_hinterp` only by position in the
  `all` target.
- The first atmosphere build needs network access: it clones the MMM physics
  (`PACE-DAAQ/MMM-physics`, branch `gocart2G/cu_ntiedtke`) and UGWP externals
  and downloads the WRF physics tables.
- `build_tables` must run once to create the four `MP_THOMPSON_*_DATA.DBL`
  files; `scripts/build_model.sh` does this.

## How a run is configured

### Initialization (`init_atmosphere_model`, `config_init_case = 7`)

The `&preproc_chemistry` record selects the GOCART-2G steps:

| Option | Produces | Needs in the run directory |
|---|---|---|
| `config_gocart2G_static` | `erod`, `clayfrac`, `sandfrac` (dust source) | WPS tiles `erod/`, `clayfrac_5m/`, `sandfrac_5m/` under `config_geog_data_path` |
| `config_gocart2G_ANTHemis`, `_BIOBemis`, `_BIOGemis` | emission structures at the start time | the emission streams listed below |
| `config_gocart2G_clim` | monthly OH, H2O2, NO3, ocean DMS, tropopause pressure | `BACKGROUND_sulf.dat`, `BACKGROUND_dms.dat`, `BACKGROUND_ptrop.dat` (WPS intermediate format) |
| `config_gocart2G_interp` | aerosol initial condition | `MERRA2:YYYY-MM-DD_HH` intermediate file (`init_MPAS-GOCART2G/run_processing.py`) |

Two passes are required, and their order follows from the package logic in
`mpas_init_atm_core_interface.F`:

1. **static pass**: `config_vertical_grid = true`, `config_gocart2G_static =
   true`, everything else off. Input `<mesh>.static.nc`, output
   `<mesh>.static_chems.nc`. Date-independent.
2. **init pass**: `config_met_interp = true`, `config_vertical_grid = false`,
   plus the emission, climatology, and aerosol options. Input
   `<mesh>.static_chems.nc`, output `<mesh>.init.nc`.

Any emission, climatology, or aerosol option makes the model read `erod` from
its input file, so those options cannot be combined with the static pass on a
plain static file. And the atmosphere core rejects an init file that lacks
the `nBCKLevels` dimension, which is written only when at least one of those
options is on. Run both passes on one MPI rank; only the serial path has been
tested, and the static pass interpolates geographic tiles.

Meteorology comes from a WPS intermediate file (`config_met_prefix`). For GFS
use the `f000` file; the `.anl` file lacks the surface and soil fields. It has
33 pressure levels plus the surface, so `config_nfglevels = 34`.

### Atmosphere (`atmosphere_model`)

- Physics: `config_physics_suite = 'MPAS-GOCART2G'` selects
  `mp_thompson_gocart2G`, `cu_ntiedtke`, `bl_mynn`, `sf_mynn`, `sf_noah`, and
  RRTMG, and turns on tracer mixing and convective transport.
- `&chemistry`: `config_gocart2G_do_<component>` enables DU2G (dust), SS2G
  (sea salt), SU2G (sulfate), NI2G (nitrate), CA2Gbc, CA2Goc, CA2Gbr (carbon),
  and SOA2G. `config_gocart2G_to{RRTMG,MYNN,THOM}` couple the aerosols to
  radiation, boundary-layer mixing, and microphysics; with `toTHOM` on, wet
  removal is done by the Thompson scheme instead of GOCART-2G's own routine.
  Convective transport and scavenging of tracers are switched by
  `config_ntiedtke_ctrchems` and `config_ntiedtke_scavchems`, which the suite
  forces on.
- **Optics tables.** Each enabled component needs `optics_<X>.<ver>.nc` and
  `opticsBands_<X>.<ver>.RRTMG.nc` in the run directory; a missing file is a
  critical error. Default names are in `Registry_gocart2G.xml`.
- **Emission streams are always read.** There are 19 emission input streams:
  `anth_{bc,oc,so2,nh3,co,iso,mnt}_emissions`,
  `biog_{co,iso,mnt,apinene,bpinene}_emissions`, and
  `biob_{bc,oc,ni,su,co,iso,mnt}_emissions`. The init core reads all of them
  when its emission options are on. The atmosphere core reads all but
  `anth_co_emissions` at every emission alarm (daily by default), and no
  namelist option skips that. The streams are not defined in the Registry:
  each needs a `<stream>` block in the streams file, with
  `input_interval="none"`, and a file whose `xtime` records bracket the run.
  `scripts/make_zero_emissions.py` writes all-zero files and the stream blocks
  when real emissions are not available.
- **The two cores register different emission variables.** The init core
  knows every CAMS sector; the atmosphere core only the sectors it uses. A
  stream block that names an unregistered variable aborts the stream parser.
- **Tracers are not individually addressable in streams.** The 30 aerosol
  tracers (`qdust1` ... `qsoapbg`) are constituents of the `scalars` array.
  Request `scalars`, or the per-component diagnostics such as `duMASS`,
  `ssCMASS`, and `totEXTTAU` (optical depth at 550 nm).
- Time step: 720 s on the 120-km mesh. The MPAS rule of thumb is about 6 s
  per km of grid spacing.
- A cold start reports `Variable qi not in input file` and five similar
  warnings. They are expected.

## Where the inputs come from

| Input | Source | Status on a workstation |
|---|---|---|
| Mesh, static file, partitions | MPAS mesh downloads | public, `fetch_inputs.sh` |
| Dust source tiles | WPS geog downloads | public, `fetch_inputs.sh` |
| Optics tables | NOAA UFS regression-test bucket (the GEOS files) | public, `fetch_inputs.sh`; no `opticsBands_BRC` file, so no brown carbon |
| Meteorology | NOAA GFS on AWS, via WPS ungrib | public, `prepare_gfs.sh` |
| Anthropogenic and biogenic emissions | CAMS-GLOB-ANT v6.2, CAMS-GLOB-BIO v3.1 through `UPTEMPO/` | needs an ECCAD account and ESMF; not automated here |
| Fire emissions | FINN v2.5.1 through `UPTEMPO/` | text files are public; not automated here |
| Background oxidants, DMS, tropopause | `BACKGROUND_*.dat` | only on Derecho |
| Aerosol initial condition | MERRA-2 through `init_MPAS-GOCART2G/` | needs a NASA Earthdata login |
| Reference namelist and stream templates | `/glade/campaign/acom/MUSICA/MPAS/input/{namelist_files,stream_files}` | only on Derecho; not in this repository |

The Derecho example (`docs/tutorial.md`, `util/submit_mpas_gocart.bash`) uses
the 60-km mesh `x1.163842` with every input above. The workstation case uses
only the public rows.

## Test cases

`test_cases/<case>/` holds `case.env`, namelist and stream templates with
`@PLACEHOLDER@` tokens, and a README stating what the case does and does not
exercise. `scripts/run_case.sh` renders them into `$G2G_WORK/runs/<name>/`.

| Case | Mesh | Aerosols | Inputs |
|---|---|---|---|
| `natural_120km` | `x1.40962`, 55 levels | dust and sea salt, cold start, zero other emissions | public only |

To add a case, copy a case directory, edit `case.env` and the templates, and
list it here. Keep the README honest about which inputs are synthetic.

## Skills

Task recipes live in `.agents/skills/<name>/SKILL.md`. Codex reads that folder;
Claude Code reads the per-skill symlinks in `.claude/skills/`. A new skill
needs both the folder and the symlink.

| Skill | Use it to |
|---|---|
| `gocart2g-build` | build or rebuild the executables and diagnose build failures |
| `gocart2g-prepare-inputs` | fetch or derive model inputs, including a new date or mesh |
| `gocart2g-run-test` | stage, run, check, and report a test case |

Keep this table, the skill files, and the scripts consistent when any of them
changes.
