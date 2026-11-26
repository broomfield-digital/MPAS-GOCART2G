# natural_120km

A short global run with the two aerosol components that need no external
emission data: dust and sea salt. It exists to show that a build works end to
end on a workstation, using public inputs only.

```bash
scripts/run_case.sh natural_120km            # 3 simulated hours
scripts/run_case.sh natural_120km --hours 24 --name natural_24h
```

## Configuration

| Item | Setting |
|---|---|
| Mesh | `x1.40962`, quasi-uniform 120 km, 40,962 cells |
| Vertical grid | 55 levels, 30-km top |
| Start | 2024-10-15 00 UTC (the date of the tutorial's Example-1) |
| Meteorology | NOAA GFS 0.25-degree `f000`, through WPS ungrib |
| Time step | 720 s |
| Physics | `MPAS-GOCART2G` suite |
| Components | `DU2G` and `SS2G` on; carbon, sulfate, nitrate, and SOA off |
| Couplings | aerosols to RRTMG, MYNN, Thompson, and nTiedtke all on |
| Ranks | 8 for the atmosphere; 1 for both init passes |

## What is synthetic

This case is a software test. Three inputs are placeholders:

- **Emissions are zero.** Anthropogenic, biogenic, and fire emission files are
  all-zero files from `scripts/make_zero_emissions.py`. They exist because the
  model reads those streams regardless of which components are enabled.
- **Background fields are zero.** No `BACKGROUND_*.dat` files are used, so the
  OH, H2O2, NO3, DMS, and tropopause-pressure fields in the init file are
  zero. The enabled components do not use them.
- **Aerosols start from zero.** There is no MERRA-2 initial condition. The
  upstream tutorial recommends two weeks of spin-up before aerosol fields are
  used for science.

Dust and sea-salt emissions are computed by the model from its own winds and
surface fields, so those two components are real, only unspun.

## What it exercises

Both `init_atmosphere` passes with the GOCART-2G static, emission, and
background structures; the GOCART-2G driver; online dust and sea-salt
emission; settling and deposition; tracer transport by dynamics, boundary-layer
mixing, and convection; the Mie-table reader; and aerosol optical diagnostics.

It does not exercise real emission inventories, sulfate or nitrate chemistry,
carbonaceous aerosols, MERRA-2 initialization, restarts, or nudging.

## Output

Written to `$G2G_WORK/runs/<name>/`; a 3-hour run takes 2.6 GB.

| File | Interval | Contents |
|---|---|---|
| `aerosol.*.nc` | hourly | dust and sea-salt emission, deposition, column and surface mass, 3-D mass mixing ratio, optical depth at 550 nm, PM, plus winds, PBL height, and rain (`stream_list.atmosphere.aerosol`) |
| `history.*.nc` | 6 hours | full model state including all tracers (`scalars`); 0.66 GB per frame |
| `diag.*.nc` | 3 hours | standard MPAS diagnostics |
| `check_summary.json` | once | results of `scripts/check_run.py` |

## Reference results

From upstream commit `42f1a064`, GNU Fortran 15.2.0, Open MPI 5.0.10,
single-precision reals, 8 ranks, 16-core workstation, 2026-11-26.

| Stage | Wall time |
|---|---|
| static pass | 116 s |
| init pass | 15 s |
| atmosphere, 3 simulated hours | 212 s |

Memory: about 3.5 GB per rank, 28 GB in total on 8 ranks.

State at 2024-10-15 03 UTC:

| Quantity | Dust | Sea salt |
|---|---|---|
| Global emission rate, as Tg per year | 816 | 3927 |
| Global burden, Tg | 0.421 | 2.496 |
| Largest column mass, kg m-2 | 5.1e-4 | 1.6e-3 |

Optical depth at 550 nm: global mean 0.0050, maximum 0.73.

These numbers describe what this configuration produced. They have not been
compared with observations or with a Derecho run.

A second complete run, after rebuilding both executables from a clean copy,
reproduced every number in `check_summary.json` exactly. Other rank counts,
compilers, and machines have not been compared, so there is no tolerance for
those yet. Treat a change as a prompt to look, not as a failure.

## Open observation: burden exceeds diagnosed emission

Starting from zero aerosol, the global burden should stay below the emission
integrated over the run, because deposition only removes mass. In this case
it does not:

| Run | Dust burden / emitted | Sea-salt burden / emitted |
|---|---|---|
| 1 hour, emission summed over every model step | 1.00 | 1.17 |
| 3 hours, emission summed from hourly output | 1.41 | 1.93 |

In the 1-hour run the dry-deposition, settling, and convective-scavenging
diagnostics add up to about a quarter of the emitted mass for both species, so
the gap to a closed budget is larger than the ratios alone show. The
wet-deposition diagnostics (`duWT_bin*`, `ssWT_bin*`) are negative in the
global sum. The sea-salt excess is concentrated in precipitating columns: the
largest column mass after one hour is about 350 times what that cell emitted.

Two one-hour sensitivity runs, each changing one coupling (ratios here use
the emission rate at the end of the hour):

| Change | Sea-salt burden / emitted | Largest sea-salt column, kg m-2 |
|---|---|---|
| none (this case) | 1.16 | 1.1e-3 |
| `config_gocart2G_toTHOM = false` | 1.06 | 2.0e-4 |
| convective tracer transport and scavenging off | 1.49 | 1.7e-4 |

The cause has not been investigated. It may be a real mass source in the
aerosol-microphysics coupling, an effect of starting that coupling from zero
aerosol, or diagnostics that do not describe the tendencies actually applied.
`scripts/check_run.py` reports the related numbers but does not fail on them.
