---
name: gocart2g-run-test
description: Stage, run, check, and report an MPAS-GOCART2G test case on a Linux workstation, covering both init_atmosphere passes and the atmosphere run. Use for smoke tests after a build or source change, reruns with a different length or rank count, diagnosing a failed init or model run from its logs, comparing two runs, or adding a new test case under test_cases/.
---

# Run an MPAS-GOCART2G test case

Read `AGENTS.md` first, then the README of the case in `test_cases/<case>/`.

## Before running

- Executables exist: `$G2G_WORK/build/{init_atmosphere,atmosphere}/gocartMPAS/`
  (else use `gocart2g-build`). After a source change, rebuild first; the run
  directory links the build copy, not the repository.
- Inputs exist (else use `gocart2g-prepare-inputs`).
- Disk space: `df -h "$G2G_WORK"`. A 3-hour `natural_120km` run needs about
  3 GB; each extra history frame adds 0.66 GB.

## Run

```bash
scripts/run_case.sh natural_120km                    # static + init + atm + check
scripts/run_case.sh natural_120km --hours 24 --name natural_24h
scripts/run_case.sh natural_120km --stage atm        # reuse the init file
scripts/run_case.sh natural_120km --stage init --fresh
```

A run longer than about 10 minutes of wall time should be started in the
background and watched through `log.atmosphere.0000.out` in the run
directory. One simulated hour on the 120-km mesh takes about 80 s on 8 ranks.

Use only rank counts that have a `<mesh>.graph.info.part.<N>` file. A longer
run than the one the init stage was made for needs `--stage init --fresh`
first, because the emission files must bracket the whole run; the script
checks this.

## Check and report

`scripts/check_run.py <run_dir> --hours N` runs automatically and writes
`check_summary.json`. Report:

- pass or fail of each check, and the wall time;
- the printed emission, burden, and optical-depth numbers, next to the
  reference values in the case README;
- the source commit from `run_info.txt`, and whether the build was current;
- which inputs were synthetic (zero emissions, zero backgrounds, cold start).

Do not describe a passing check as scientific validation.

## When a stage fails

1. The script prints the first `ERROR` lines. The full text is in
   `log.<core>.0000.out` and the per-rank `log.<core>.*.err` files.
2. Match the message:
   - `Requested field ... not available`: a stream names a variable the core
     has not registered, or an individual tracer (request `scalars`).
   - `dimensioned by 'nBCKLevels'` or `'nDustErosionDim'` not defined: the
     init passes were run in the wrong order or with the wrong options.
   - `file ... not in run directory`: an optics table for an enabled
     component is missing.
   - An input file that cannot be opened or read: check its format with
     `ncdump -k`.
3. MPAS can exit with status 0 after logging errors. Trust the error counts
   at the end of the log, as the script does, not the exit status.

## Adding a case

Copy `test_cases/natural_120km/`, edit `case.env` and the templates, write the
README (purpose, inputs, what is synthetic, reference numbers with the commit
that produced them), and add the case to the table in `AGENTS.md`. Template
files must keep the `@MESH@`, `@START_TIME@`, `@RUN_DURATION@`,
`@HISTORY_INTERVAL@`, `@GEOG_PATH@`, and `@EMISSION_STREAMS@` tokens where
those values belong.
