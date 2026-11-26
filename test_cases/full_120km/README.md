# full_120km

The 120-km analog of the tutorial's Example-1: all eight aerosol components,
a MERRA-2 start, the reference background fields and optics tables, and real
anthropogenic, biogenic, and fire emissions regridded to this mesh. Nothing in
it is a placeholder.

```bash
scripts/fetch_derecho_inputs.sh core emis-raw-2024   # once; needs an NCAR login
scripts/regrid_emissions.sh                          # once; about 10 minutes
scripts/run_case.sh full_120km                       # 3 simulated hours
```

## Configuration

Identical to `merra2_120km` (see its README for the table and for how the
namelists differ from the reference templates) except for the emissions:

| Emission | Source | File |
|---|---|---|
| Anthropogenic | CAMS-GLOB-ANT v6.2, 2024, monthly, by sector; agricultural waste burning removed from the sector sum | `x1.40962-2024-anth_<species>.MPAS.nc` |
| Biogenic | CAMS-GLOB-BIO v3.1, 2019 climatology, monthly | `x1.40962-2024-biog_<species>.MPAS.nc` |
| Fire | FINN v2.5.1 near-real-time, hourly, 2024-10-14 to 20 | `FINNv2.5.1_modvrs_nrt_MOZART_2024_x1.40962.static_hourly_netcdf3.nc` |

The files come from `scripts/regrid_emissions.sh`, which runs the tools in
`UPTEMPO/` unchanged. The emission streams are written out in this case's
stream templates and match the reference stream files: 19 streams, the same
variables, and the fire streams all reading the one hourly file.

The fire file covers 2024-10-14 to 2024-10-20, so a run may last until
2024-10-20 23 UTC. For a longer run, rerun `scripts/regrid_emissions.sh fire`
with a later `--fire-end` first; the run script checks the coverage.

## What the regridding produced

Global totals in October 2024 after conservative regridding, as Tg per year:

| Species | Anthropogenic | Biogenic |
|---|---|---|
| Black carbon | 3.79 | |
| Organic carbon | 7.55 | |
| Sulfur dioxide | 80.7 | |
| Ammonia | 52.8 | |
| Carbon monoxide | 463 | 71.1 |
| Isoprene | 0.04 | 461 |
| Monoterpenes | 0.24 | 26.7 alpha-pinene, 14.3 beta-pinene, 40.0 other |

The black-carbon total was compared with the 0.1-degree source file and
agrees to 0.01% (120.06 against 120.07 kg/s, sector sum without agricultural
waste burning). The other species were not compared with their sources.

The 2024 ammonia inventory has no `fef` sector, so the model logs
`Variable nh3_anth_fef not in input file` once in each stage and uses zero
for it. That warning is expected.

## Reference results

From upstream commit `42f1a064`, GNU Fortran 15.2.0, Open MPI 5.0.10,
single-precision reals, 8 ranks, 16-core workstation, 2026-11-26.

| Stage | Wall time |
|---|---|
| static pass | 103 s |
| init pass | 47 s |
| atmosphere, 3 simulated hours | 295 s |

Global burden in Tg, from the column-mass diagnostics:

| Hour | Dust | Sea salt | Sulfate | Nitrate | Black carbon | Organic carbon | Brown carbon |
|---|---|---|---|---|---|---|---|
| 1 | 11.70 | 12.81 | 1.62 | 1.10 | 0.441 | 3.29 | 0.659 |
| 2 | 11.65 | 12.19 | 1.62 | 1.14 | 0.440 | 3.29 | 0.658 |
| 3 | 11.60 | 11.66 | 1.63 | 1.17 | 0.439 | 3.27 | 0.657 |

Optical depth at 550 nm at hour 3: global mean 0.151, maximum 2.84.

Emission diagnostics at hour 3, as Tg per year:

| Diagnostic | Value |
|---|---|
| Black carbon: anthropogenic, biofuel, biomass burning (`bcEMAN`, `bcEMBF`, `bcEMBB`) | 2.67, 1.22, 1.13 |
| Organic carbon: anthropogenic, biofuel, biomass burning (`ocEMAN`, `ocEMBF`, `ocEMBB`) | 5.82, 3.60, 6.90 |
| Brown carbon from biomass burning (`brEMBB`) | 7.20 |
| Sulfur dioxide: anthropogenic, biomass burning (`SO2eman`, `SO2embb`) | 79.0, 1.24 |
| Ammonia (`nh3EM`) | 51.7 |
| DMS from the ocean (`suEM_dms`) | 18.7 |
| Dust, sea salt | 801, 3897 |

The biogenic organic-carbon diagnostic `ocEMBG` is zero although the biogenic
streams are read; whether that is by design was not checked.

Compared with `merra2_120km` after three hours, the emissions raise the
black-carbon burden by 0.4% and sulfur dioxide by 4.5%; the run is too short
for them to matter more. These numbers have not been compared with
observations or with a Derecho run. The observations listed in the
`merra2_120km` README apply here unchanged.
