# merra2_120km

All eight aerosol components on the 120-km mesh, started from MERRA-2 aerosols
with the reference background fields and optics tables. It is the closest
workstation analog of the tutorial's Example-1 that needs no emission
regridding: the only placeholder left is the emission inventories.

```bash
scripts/fetch_derecho_inputs.sh core      # once; needs an NCAR login
scripts/run_case.sh merra2_120km          # 3 simulated hours
```

## Configuration

| Item | Setting |
|---|---|
| Mesh | `x1.40962`, quasi-uniform 120 km, 40,962 cells |
| Vertical grid | 55 levels, 30-km top |
| Start | 2024-10-15 00 UTC |
| Meteorology | NOAA GFS 0.25-degree `f000`, through WPS ungrib |
| Aerosol initial condition | `MERRA2:2024-10-15_00` from Derecho (`config_gocart2G_interp`) |
| Background fields | `BACKGROUND_{sulf,dms,ptrop}.dat` from Derecho (`config_gocart2G_clim`) |
| Optics tables | the versions the reference namelist names: `v1_5` BC and OC, `v2_5` SU, BRC, NI, `v15_5` DU, `v3_5` SS |
| Time step | 720 s, 4 dynamics sub-steps |
| Physics | `MPAS-GOCART2G` suite |
| Components | all eight, with all couplings on |
| Ranks | 8 for the atmosphere; 1 for both init passes |

The namelists follow the reference templates in `scripts/derecho_inventory.txt`
except where the mesh requires otherwise, and except these:

| Setting | Here | Reference |
|---|---|---|
| Emission inventories | all-zero files | CAMS and FINN on the 60-km mesh |
| Init flow | two passes from the downloaded static file | static interpolation from the grid file, then one chemistry pass |
| `config_jedi_da` | not set (false) | true |
| `config_print_detailed_minmax_vel` | false | true |
| `config_epssm` | not set | 0.1; this model version reports the option as no longer supported |

## What is synthetic

**Anthropogenic, biogenic, and fire emissions are zero.** The files come from
`scripts/make_zero_emissions.py`. Black carbon, organic carbon, sulfur dioxide,
and ammonia therefore only decay from their initial values; dust, sea salt,
and DMS are still emitted by the model.

The gas fields in the MERRA-2 file (HNO3, NH3, CO, isoprene) are from 2019,
as the upstream tutorial describes; the file's own header is dated
2019-10-15.

## Output

Written to `$G2G_WORK/runs/<name>/`; a 3-hour run takes 3.0 GB.

`aerosol.*.nc` is hourly and holds the aerosol part of the reference
diagnostics list plus the 3-D mass mixing ratio of each component, 186
variables in all. The
first frame, at the start time, is all zero: the diagnostics are filled
during the first step. The tracers themselves are in `history.*.nc`.

## Reference results

From upstream commit `42f1a064`, GNU Fortran 15.2.0, Open MPI 5.0.10,
single-precision reals, 8 ranks, 16-core workstation, 2026-11-26.

| Stage | Wall time |
|---|---|
| static pass | 114 s |
| init pass | 48 s |
| atmosphere, 3 simulated hours | 292 s |

Memory: about 3.3 GB per rank, 27 GB in total, sampled early in the run.

Global burden in Tg, from the column-mass diagnostics:

| Hour | Dust | Sea salt | Sulfate | Nitrate | Black carbon | Organic carbon | Brown carbon |
|---|---|---|---|---|---|---|---|
| 1 | 11.70 | 12.81 | 1.62 | 1.10 | 0.440 | 3.29 | 0.658 |
| 2 | 11.65 | 12.19 | 1.62 | 1.14 | 0.439 | 3.28 | 0.656 |
| 3 | 11.59 | 11.66 | 1.62 | 1.17 | 0.437 | 3.27 | 0.653 |

Optical depth at 550 nm at hour 3: global mean 0.150, maximum 2.83.
Emission rates at hour 3, as Tg per year: dust 801, sea salt 3897.

These numbers describe what this configuration produced. They have not been
compared with observations, with MERRA-2 itself, or with a Derecho run.

## Observations to follow up

None of these has been investigated.

- **Volcanic sulfur duplicates the rest.** In `MERRA2:2024-10-15_00` the
  fields `SO4V` and `SO2V` are identical to `SO4` and `SO2` at every level
  checked, so the tracers `qso4v` and `qso2v` start as exact copies of `qso4`
  and `qso2` (1.61 Tg and 0.61 Tg each). The `SO4cmass` diagnostic counts one
  copy. Whether optical depth and radiation count both was not checked.
- **Brown carbon is derived at initialization.** The MERRA-2 file has no
  brown carbon, yet the initial brown-carbon burdens are 0.2 times the
  organic-carbon ones to four digits.
- **Sea salt falls by 4 to 5% per hour** over the first three hours, from
  13.5 Tg in the initial condition, while dust stays level.
- The cold-start case `natural_120km` shows a dust and sea-salt burden above
  the diagnosed emissions. This run cannot show that either way, because its
  burden is dominated by the initial condition.
