---
name: gocart2g-aod-constraint
description: Configure, run, check, and diagnose an MPAS-GOCART2G run with the AOD constraint, which scales tropospheric aerosol toward observed optical depth at 550 nm. Use when turning the constraint on for a case, staging or checking observation files, running a constrained run and its free twin, reading the constraint's diagnostics or log lines, changing the constraint code under gocartMPAS/src/core_atmosphere/chemistry/*aod*, or when a constrained run shows no updates, limits everywhere, or optical depth that does not hold.
---

# AOD constraint in MPAS-GOCART2G

Read `AGENTS.md`, section "AOD constraint", first: it has the options, the
file format, and what is scaled. This skill is the procedure.

## Run the software check after any change to the constraint

```bash
scripts/test_aod_kernel.sh                         # arithmetic; seconds
scripts/build_model.sh atmosphere                  # about a minute after a small change
scripts/run_case.sh constraint_check_120km         # synthetic observations, 1 hour
scripts/run_case.sh constraint_check_120km --name constraint_check_free --free
scripts/check_aod_constraint.py $G2G_WORK/runs/constraint_check_120km \
    --free $G2G_WORK/runs/constraint_check_free
```

To save the twin's static and init stages (about 2.5 minutes), hard-link
`x1.40962.static_chems.nc` and `x1.40962.init.nc` from the first run
directory into the twin's and add `--stage atm`.

Then confirm the option does nothing when off: `scripts/run_case.sh
full_120km` must reproduce the numbers in its README exactly.

Compare the check's output with the table in
`test_cases/constraint_check_120km/README.md`. The line to look at hardest is
the factor on re-application: it stays within a few percent of 1 only if
everything the optics sees was scaled and stayed scaled through a time step.

## Run with real observations

1. Put the daily files under `$G2G_WORK/inputs/aod_obs/<mesh>/` (or point
   `G2G_AOD_OBS` at them). They are made outside this repository. They must
   cover from three hours before the start to three hours after the stop.
2. `scripts/run_case.sh constrained_120km`, and the twin with
   `--name constrained_120km_free --free`.
3. The run script checks the files against the mesh before the model starts
   and runs `check_aod_constraint.py` in its check stage.

## Read the log

Each application writes, in `log.atmosphere.0000.out`:

```
AOD constraint: cells = ..., observed = ..., updated = ..., at lower limit = ...,
                at upper limit = ..., observation below fixed AOD = ..., without a tropopause layer = ...
AOD constraint: fraction of cells updated = ...; means over updated cells: observed, first guess, analyzed
```

| What you see | Likely cause |
|---|---|
| `observed = 0` at every application | no record within three hours: wrong dates, a missing file, or the stream is not in the streams file. Look for "no observation record" |
| `without a tropopause layer` equals `cells` | no tropopause climatology in the init file; the case needs `CASE_BACKGROUND=yes`, or use `config_gocart2G_aod_tropo_only = false` |
| `updated` much smaller than `observed` | optical depth of the scaled layers below `config_gocart2G_aod_eps` |
| many cells at a limit | the model and the observations differ by more than a factor of ten; look at where before changing the limits |
| analyzed mean differs from observed mean | expected only through cells at a limit |

## Change the code

- The arithmetic lives in `mpas_chemistry_gocart2G_aod_kernel.F90` and has no
  model dependencies; add a unit test in `tests/fortran/test_aod_kernel.F90`
  with every change.
- If a tracer is added to the aerosol scheme, decide whether it is particulate
  and used by the aerosol processes; if so add it to `scale_layer` and to
  `SCALED` in `scripts/check_aod_constraint.py`. Species in thermodynamic
  equilibrium with each other must be scaled together.
- Dust and sea salt are copied into their components; the other components
  point at the interface arrays. A new component needs the same care.
- Do not edit the process code under `gocart2G/` for the constraint.

## Report

State which checks ran and their numbers, the fraction of cells updated, the
cells at each limit, and the mean first guess, analyzed, and observed optical
depth. Say that the checks establish what the update did, not that the
constrained aerosol is right; that takes independent observations.
