---
name: gocart2g-build
description: Build or rebuild the MPAS-GOCART2G init_atmosphere and atmosphere executables on a Linux workstation with the GNU toolchain, and diagnose build failures. Use for build requests, compiler or linker errors, missing executables or Thompson lookup tables, debug builds, or rebuilding after a source change under gocartMPAS/.
---

# Build MPAS-GOCART2G

Read `AGENTS.md` first; its "How the model is built" section explains every
constraint below.

## Build

```bash
scripts/build_model.sh                    # both cores
scripts/build_model.sh atmosphere         # one core
scripts/build_model.sh atmosphere --debug # bounds checks, FPE traps, backtraces
scripts/build_model.sh all --clean        # discard the build copies first
```

The script copies `gocartMPAS/` to `$G2G_WORK/build/<core>/gocartMPAS`, runs a
serial `make gnu CORE=<core> GOCART2G=true` there, and, for the atmosphere
core, runs `build_tables` if the Thompson tables are missing. It writes
`$G2G_WORK/build/<core>/BUILD_INFO` with the source commit and tool versions.

Measured on a 16-core workstation: init_atmosphere 1.5 min, atmosphere 6 min,
lookup tables 3.5 min.

## Rules

- Do not build inside the repository and do not add `-j`. Both fail in ways
  described in `AGENTS.md`.
- Leave `PIO` unset. The script unsets it; a manual `make` must too.
- A debug build and an optimized build cannot share a tree. The script
  discards the build copy when `--debug` differs from the previous build, so
  expect a full rebuild after switching.
- The first atmosphere build needs network access for the physics externals
  and tables. Report a fetch failure separately from a compile failure.

## When a build fails

1. Read the tail of `$G2G_WORK/logs/build_<core>.log`; the script prints it.
2. Search the log for the first `Error` line, not the last: later errors are
   usually consequences.
3. `Cannot open module file` right after a clean start means a build-order
   problem. Confirm the build was serial before changing any Makefile.
4. If the fix is a source change, make it under `gocartMPAS/` in the
   repository and rerun the script. Never edit the build copy; the next run
   overwrites it.

## Verify

Confirm `$G2G_WORK/build/<core>/gocartMPAS/<core>_model` exists and is newer
than the edited sources, and that the log ends with the MPAS build summary
including `MPAS was built with GOCART-2G enabled` and `Using the SMIOL
library`. Run a test case with `gocart2g-run-test` only when the request
includes it.
