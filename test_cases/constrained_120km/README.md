# constrained_120km

`full_120km` with the AOD constraint on: every hour, where MODIS or VIIRS has
a valid retrieval, the tropospheric aerosol of the column is scaled so that
the column optical depth at 550 nm matches the observation.

```bash
scripts/run_case.sh constrained_120km                                    # 24 simulated hours
scripts/run_case.sh constrained_120km --name constrained_120km_free --free
```

The second command runs the free twin, the same case with the constraint off.
A constrained run is compared with its twin, not with its own first guess:
the first guess already carries the earlier updates.

## Inputs beyond full_120km

Daily observation files on this mesh, `modis_viirs_aod_3hr.x1.40962.<YYYYMMDD>.nc`,
under `$G2G_WORK/inputs/aod_obs/x1.40962/` (or `$G2G_AOD_OBS`), for every day
from three hours before the start to three hours after the stop. Their format
is in `AGENTS.md`, "AOD constraint". They are not made in this repository;
`scripts/check_aod_obs.py` checks them before the run, and
`scripts/make_synthetic_aod_obs.py` writes test files.

## What it adds to full_120km

| Item | Setting |
|---|---|
| `&aod_constraint` | on, tropospheric only, `config_gocart2G_aod_interval = '01:00:00'`, limits 0.1 and 10, `eps` 0.01 |
| `aod_obs` stream | one file per day, 3-hour windows stamped at their centers |
| `aerosol` stream | the constraint diagnostics added |

The tropopause is the monthly climatology the model already reads
(`background_ptrop`), not a diagnosed one.

## Reading the output

| Variable | Meaning |
|---|---|
| `observed_aod` | observation interpolated to the update time; -999 where none |
| `first_guess_aod`, `analyzed_aod` | column optical depth before and after the update |
| `tropospheric_aod`, `stratospheric_aod` | first-guess optical depth of the scaled layers and of the layers held fixed |
| `aod_scale_factor` | factor applied; 1 where no update |
| `aod_update_applied`, `aod_clamped_low`, `aod_clamped_high`, `aod_below_stratosphere` | 0 or 1 |
| `aod_tropopause_pressure` | tropopause pressure used |

They hold the most recent update, which is made at the end of the first time
step of each hour; the output written on the hour therefore shows the update
of 48 minutes earlier. `totEXTTAU` and the other GOCART-2G diagnostics are
computed before an update: they are first-guess values. Mask by
`aod_update_applied` before averaging `observed_aod`.
