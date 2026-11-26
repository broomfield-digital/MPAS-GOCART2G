# constraint_check_120km

A software check of the AOD constraint. It is `full_120km` with the constraint
applied at every time step toward synthetic observations: an optical depth of
0.2 at 550 nm inside a box over Africa and the tropical Atlantic (30 S to 30 N,
60 W to 60 E), and no observation anywhere else. It is not a scientific
configuration.

```bash
scripts/run_case.sh constraint_check_120km                                 # 1 simulated hour
scripts/run_case.sh constraint_check_120km --name constraint_check_free --free
scripts/check_aod_constraint.py $G2G_WORK/runs/constraint_check_120km \
    --free $G2G_WORK/runs/constraint_check_free
```

The second command runs the free twin: the same case with the constraint off.
To skip its static and init stages, link `x1.40962.static_chems.nc` and
`x1.40962.init.nc` from the first run directory into the twin's and add
`--stage atm`.

## What it adds to full_120km

| Item | Setting |
|---|---|
| `&aod_constraint` | on, tropospheric only, `config_gocart2G_aod_interval = '00:12:00'` (every time step), limits 0.1 and 10, `eps` 0.01 |
| `aod_obs` stream | daily files written for the run by `scripts/make_synthetic_aod_obs.py` |
| `aod_check` stream | every time step: all tracers, pressure, the constraint diagnostics, and each component's optical depth and column mass. About 0.35 GB per time |

## What the check establishes

`scripts/check_aod_constraint.py` reads `aod_check.nc` and, with `--free`, the
twin's. Reference results (GNU, single precision, 8 ranks):

| Check | Result |
|---|---|
| Analyzed optical depth equals the observation where the factor was not at a limit | all 6849 observed cells, every step |
| First guess equals the model's own `totEXTTAU` | every cell, every step |
| Mean first guess in the box before the first update, and after | 0.2540, then 0.1998 to 0.2000 |
| Factor on re-application, 1st / 50th / 99th percentile | 0.977 / 1.000 / 1.035 at the second step, 0.98 / 1.00 / 1.03 after |
| Cells at the lower limit at the first update | 5 (model optical depth above 2) |
| After one step, scaled tracers against the twin | equal to the twin times the factor, to 6e-8, in 269811 layers |
| Layers changed above the tropopause pressure | 0 |
| Unscaled tracers, and columns without an observation | bit-identical to the twin |
| The same run on 4 ranks | passes; the counts and means in the log agree with 8 ranks to the six digits printed |

The factor staying near 1 on re-application is the test that the whole
aerosol the optics sees was scaled: the model's optics at the next step are
independent of the arithmetic of the update.

## What the check found

In an earlier version ammonium was not scaled, because the optics do not
count it separately. The factor at the second step then ranged from 0.90 to
1.49 (1st to 99th percentile): in strongly scaled columns the fine nitrate
evaporated within one time step, since scaling sulfate without ammonium
changed their ratio and with it the regime of the nitrate thermodynamics.
Coarse nitrate, dust, sea salt, sulfate, and carbon held their increments.
Scaling ammonium (and MSA) with the rest removed the effect.

## What it does not establish

Nothing about real observations or about whether a constrained aerosol is
closer to the truth. The lower limit is exercised in 5 cells; the upper
limit, the `eps` guard, and an observation below the fixed optical depth do
not occur in this box and are covered by the kernel unit tests
(`scripts/test_aod_kernel.sh`) only.
