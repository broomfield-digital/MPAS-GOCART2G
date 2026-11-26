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

## Reference results

GNU, single precision, 8 ranks, 24 simulated hours from 2024-10-15 00 UTC,
with the free twin run the same way. Observations: MODIS (Terra and Aqua,
collection 6.1) and VIIRS (SNPP and NOAA-20), Dark Target and Deep Blue from
each, eight streams merged; about 18 percent of the cells have a value in a
3-hour window.

| Quantity | Constrained | Free twin |
|---|---|---|
| Wall time | 2638 s | 2447 s |
| Global mean AOD at 550 nm after 24 hours | 0.1697 | 0.1390 |
| Maximum AOD | 4.13 | 2.31 |
| Dust burden (Tg) | 11.53 | 11.11 |
| Sea salt burden (Tg) | 9.52 | 6.97 |
| Sulfate burden (Tg) | 1.93 | 1.55 |
| Nitrate burden (Tg) | 1.20 | 1.15 |
| Black carbon burden (Tg) | 0.514 | 0.409 |
| Organic carbon burden (Tg) | 3.67 | 2.98 |
| Brown carbon burden (Tg) | 0.793 | 0.655 |

The 24 hourly updates:

| Quantity | Value |
|---|---|
| Cells updated at each update | 25.9 to 29.3 percent |
| Cells at the lower limit, at the upper limit | at most 0.42 percent, at most 0.03 percent |
| First update: mean first guess, mean observed, in updated cells | 0.0987, 0.1316 |
| Later updates: difference of those two means | median 0.003, at most 0.014 |
| Analyzed against observed, and the other arithmetic checks | pass at all 24 updates (`check_aod_constraint.py`) |

The larger differences among the later updates come every third hour, when
the pair of 3-hour windows around the model time changes and new cells get
an observation.

Against AERONET (Level 1.5, 275 sites, 1790 hourly site means paired with
the model cell that contains the site; computed outside this repository):

| Run | Bias | Root-mean-square error | Correlation |
|---|---|---|---|
| Free twin | -0.003 | 0.148 | 0.68 |
| Constrained | -0.004 | 0.112 | 0.83 |

AERONET is independent of the retrievals the constraint uses, so this is
evidence that the constraint moved the model toward the atmosphere and not
only toward the satellites. It is one day, with quality level 1.5, and a sun
photometer reports under the same clear skies in which a satellite retrieves.

## What this case does not establish

- That the constrained aerosol is right in composition or in the vertical:
  one factor per column keeps both as the model had them.
- Behaviour over more than a day. The meteorology is a free forecast from
  one analysis and is not nudged, and the aerosol feeds back on it, so the
  two runs differ in weather as well as in aerosol.
- A restart of a constrained run, whole-column mode
  (`config_gocart2G_aod_tropo_only = false`), and a case without the
  tropopause climatology have not been run.
