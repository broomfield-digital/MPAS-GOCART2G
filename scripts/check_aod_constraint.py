#!/usr/bin/env python3
"""Check a run that used the AOD constraint.

  scripts/check_aod_constraint.py RUN_DIR [--free FREE_RUN_DIR]

The checks use the constraint's own diagnostics in the run's output and, with
--free, the tracers of a twin run made with the constraint off
(scripts/run_case.sh CASE --free). They establish that the update did what it
is defined to do. They say nothing about whether the observations or the
resulting aerosol are right.

From the diagnostics, at every output time:
  1. where an update was applied and the factor was not at a limit, the
     analyzed optical depth equals the observation;
  2. the analyzed optical depth is the fixed part plus the factor times the
     scaled part, and the two parts add up to the first guess;
  3. where no update was applied, the factor is 1 and nothing changed;
  4. the flags agree with the factor and its limits.
With the constraint applied at every time step (the constraint_check case):
  5. the first guess equals the model's own column optical depth, totEXTTAU;
  6. after the first application the factor stays close to 1, which it can only
     do if the whole aerosol the optics sees was scaled.
With --free, comparing the tracers after the first time step:
  7. the scaled tracers equal the free ones times the factor in every layer
     below the tropopause layer, and are bit-identical in the tropopause layer
     and above;
  8. every other tracer, and every column without an update, is bit-identical.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import netCDF4
import numpy as np

DIAGNOSTICS = [
    "observed_aod", "first_guess_aod", "analyzed_aod", "tropospheric_aod", "stratospheric_aod",
    "aod_scale_factor", "aod_update_applied", "aod_clamped_low", "aod_clamped_high",
    "aod_below_stratosphere", "aod_tropopause_pressure",
]  # fmt: skip
SCALED = (
    [f"qdust{n}" for n in range(1, 6)] + [f"qseas{n}" for n in range(1, 6)]
    + ["qso4", "qmsa", "qni1", "qni2", "qni3", "qnh4a"]
    + ["qbcphobic", "qbcphilic", "qbrphobic", "qbrphilic", "qocphobic", "qocphilic"]
)  # fmt: skip
REL = 2e-5  # single-precision arithmetic over a few operations


def namelist_value(run: Path, name: str) -> str:
    text = (run / "namelist.atmosphere").read_text()
    match = re.search(rf"^\s*{name}\s*=\s*(.+?)\s*$", text, re.M)
    if match is None:
        raise SystemExit(f"ERROR: {name} is not in {run}/namelist.atmosphere")
    return match.group(1).strip("'\"")


def seconds(interval: str) -> float:
    days, _, clock = interval.rpartition("_")
    parts = [float(part) for part in clock.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return (float(days) if days else 0.0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def output_files(run: Path) -> list[Path]:
    """Files that hold the diagnostics: the check stream if the case has one, else the aerosol stream."""
    check = run / "aod_check.nc"
    return [check] if check.exists() else sorted(run.glob("aerosol.*.nc"))


def frames(files: list[Path]):
    """Yield (label, {name: array}) for every time in the files, with totEXTTAU if present."""
    for path in files:
        with netCDF4.Dataset(path) as nc:
            nc.set_auto_mask(False)
            missing = [name for name in DIAGNOSTICS if name not in nc.variables]
            if missing:
                raise SystemExit(f"ERROR: {path.name} lacks {missing}; add them to the output stream")
            for t in range(nc.dimensions["Time"].size):
                label = b"".join(nc["xtime"][t]).decode().strip("\x00 ")
                data = {name: nc[name][t].astype("f8") for name in DIAGNOSTICS}
                if "totEXTTAU" in nc.variables:
                    data["totEXTTAU"] = np.squeeze(nc["totEXTTAU"][t].astype("f8"))
                yield label, data


def close(a: np.ndarray, b: np.ndarray, floor: float = 1e-6) -> np.ndarray:
    return np.abs(a - b) <= REL * np.maximum(np.abs(b), floor) + 1e-7


def check_diagnostics(run: Path) -> tuple[list[str], dict]:
    rmin = float(namelist_value(run, "config_gocart2G_aod_ratio_min"))
    rmax = float(namelist_value(run, "config_gocart2G_aod_ratio_max"))
    eps = float(namelist_value(run, "config_gocart2G_aod_eps"))
    every_step = seconds(namelist_value(run, "config_gocart2G_aod_interval")) <= float(
        namelist_value(run, "config_dt")
    )
    failures: list[str] = []
    summary: dict = {"every_step": every_step, "times": []}
    applications = 0
    for label, d in frames(output_files(run)):
        applied = d["aod_update_applied"] > 0.5
        low, high = d["aod_clamped_low"] > 0.5, d["aod_clamped_high"] > 0.5
        factor, first, analyzed = d["aod_scale_factor"], d["first_guess_aod"], d["analyzed_aod"]
        trop, strat, observed = d["tropospheric_aod"], d["stratospheric_aod"], d["observed_aod"]
        if not first.any():
            continue  # written before the first application
        applications += 1
        free_fit = applied & ~low & ~high

        def fail(what: str, bad: np.ndarray) -> None:
            if bad.any():
                failures.append(f"{label}: {what} in {int(bad.sum())} cells")

        fail("analyzed AOD differs from the observation where the update was not limited",
             free_fit & ~close(analyzed, observed))
        fail("analyzed AOD is not fixed + factor * scaled", applied & ~close(analyzed, strat + factor * trop))
        fail("fixed + scaled parts do not add up to the first guess", ~close(trop + strat, first))
        fail("factor is not 1 where no update was applied", ~applied & (factor != 1.0))
        fail("analyzed AOD changed where no update was applied", ~applied & (analyzed != first))
        fail("update applied without an observation", applied & (observed < 0))
        fail("update applied where the scaled part is below eps", applied & (trop < eps * (1 - REL)))
        fail("factor outside its limits", (factor < rmin * (1 - REL)) | (factor > rmax * (1 + REL)))
        fail("low-limit flag disagrees with the factor", low != (applied & (factor <= rmin * (1 + REL))))
        fail("high-limit flag disagrees with the factor", high != (applied & (factor >= rmax * (1 - REL))))
        fail("below-stratosphere flag disagrees", (d["aod_below_stratosphere"] > 0.5) != (applied & (observed < strat)))
        entry = {
            "time": label,
            "fraction_updated": float(applied.mean()),
            "fraction_at_lower_limit": float(low.mean()),
            "fraction_at_upper_limit": float(high.mean()),
        }
        if applied.any():
            entry["mean_first_guess_where_updated"] = float(first[applied].mean())
            entry["mean_analyzed_where_updated"] = float(analyzed[applied].mean())
            entry["mean_observed_where_updated"] = float(observed[applied].mean())
        if every_step and "totEXTTAU" in d:
            fail("first guess differs from totEXTTAU", ~close(first, d["totEXTTAU"]))
            if applications > 1 and free_fit.any():
                spread = np.percentile(factor[free_fit], [1, 50, 99])
                entry["factor_percentiles_1_50_99"] = [float(v) for v in spread]
                if not (0.9 <= spread[0] and spread[2] <= 1.1 and abs(spread[1] - 1) <= 0.02):
                    failures.append(
                        f"{label}: on re-application the factor is not close to 1 "
                        f"(1st, 50th, 99th percentile {spread[0]:.3f}, {spread[1]:.3f}, {spread[2]:.3f})"
                    )
        summary["times"].append(entry)
    if applications == 0:
        failures.append("no output time holds an application of the constraint")
    return failures, summary


def check_against_free(run: Path, free: Path) -> tuple[list[str], dict]:
    """Compare tracers after the first time step with a twin that ran without the constraint."""
    failures: list[str] = []
    with netCDF4.Dataset(run / "aod_check.nc") as a, netCDF4.Dataset(free / "aod_check.nc") as b:
        a.set_auto_mask(False)
        b.set_auto_mask(False)
        names = [name for name in a.variables if a[name].dimensions == ("Time", "nCells", "nVertLevels")]
        tracers = [name for name in names if name.startswith(("q", "n")) and name in b.variables]
        missing = [name for name in SCALED if name not in tracers]
        if missing:
            raise SystemExit(f"ERROR: aod_check.nc lacks the tracers {missing}")
        t = 1  # frame 0 is the initial state; frame 1 follows the first time step
        factor = a["aod_scale_factor"][t].astype("f8")
        applied = a["aod_update_applied"][t] > 0.5
        ptrop = a["aod_tropopause_pressure"][t].astype("f8")
        pressure = (a["pressure_p"][t] + a["pressure_base"][t]).astype("f8")  # mid-layer, surface first
        if not np.array_equal(pressure, (b["pressure_p"][t] + b["pressure_base"][t]).astype("f8")):
            failures.append("the two runs differ in pressure after one step; they are not twins")

        changed_any = np.zeros(pressure.shape, dtype=bool)
        worst = 0.0
        for name in tracers:
            x, y = a[name][t], b[name][t]
            changed = x != y
            if name not in SCALED:
                if changed.any():
                    failures.append(f"{name} is not scaled but differs from the free run in {int(changed.sum())} places")
                continue
            if changed[~applied].any():
                failures.append(f"{name} differs in {int(changed[~applied].sum())} places of columns without an update")
            changed_any |= changed
            # where the free value is not zero, the ratio must be the column's factor
            ratio_ok = np.isclose(x.astype("f8"), y.astype("f8") * factor[:, None], rtol=2e-6, atol=0.0)
            bad = changed & ~ratio_ok
            if bad.any():
                failures.append(f"{name}: {int(bad.sum())} changed values are not free * factor")
            with np.errstate(divide="ignore", invalid="ignore"):
                error = np.abs(x.astype("f8") / (y.astype("f8") * factor[:, None]) - 1)
            worst = max(worst, float(np.nanmax(np.where(changed, error, 0.0))))

        # layers: changed layers lie below the tropopause; at most the tropopause layer itself may be
        # unchanged with a mid-layer pressure greater than the tropopause pressure
        above = pressure < ptrop[:, None]
        scaled_columns = applied & (factor != 1.0)
        wrong_above = changed_any & above
        if wrong_above.any():
            failures.append(f"{int(wrong_above.sum())} layers above the tropopause pressure were changed")
        unchanged_below = (~changed_any & ~above)[scaled_columns].sum(axis=1)
        if unchanged_below.size and unchanged_below.max() > 1:
            failures.append(
                f"up to {int(unchanged_below.max())} layers below the tropopause pressure were left unscaled "
                "in one column; only the tropopause layer may be"
            )
    summary = {
        "columns_updated": int(applied.sum()),
        "columns_scaled": int(scaled_columns.sum()),
        "layers_changed": int(changed_any.sum()),
        "layers_changed_above_tropopause_pressure": int(wrong_above.sum()),
        "largest_relative_error_of_scaled_values": worst,
        "tracers_compared": len(tracers),
    }
    return failures, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("run", type=Path)
    parser.add_argument("--free", type=Path, help="run directory of the twin without the constraint")
    args = parser.parse_args()

    failures, summary = check_diagnostics(args.run)
    result = {"diagnostics": summary}
    if args.free is not None:
        more, twin = check_against_free(args.run, args.free)
        failures += more
        result["twin"] = twin
    result["failures"] = failures
    (args.run / "check_aod_constraint.json").write_text(json.dumps(result, indent=2) + "\n")

    for entry in summary["times"]:
        line = f"[aod constraint] {entry['time']}: updated {entry['fraction_updated']:.1%} of cells"
        if "mean_first_guess_where_updated" in entry:
            line += (
                f"; there, first guess {entry['mean_first_guess_where_updated']:.4f}, "
                f"analyzed {entry['mean_analyzed_where_updated']:.4f}, "
                f"observed {entry['mean_observed_where_updated']:.4f}"
            )
        line += f"; at limits {entry['fraction_at_lower_limit']:.2%} low, {entry['fraction_at_upper_limit']:.2%} high"
        if "factor_percentiles_1_50_99" in entry:
            p = entry["factor_percentiles_1_50_99"]
            line += f"; factor 1st/50th/99th percentile {p[0]:.3f}/{p[1]:.3f}/{p[2]:.3f}"
        print(line)
    if args.free is not None:
        twin = result["twin"]
        print(
            f"[aod constraint] twin after one step: {twin['columns_scaled']} columns scaled, "
            f"{twin['layers_changed']} layers changed, {twin['layers_changed_above_tropopause_pressure']} "
            f"of them above the tropopause pressure; largest relative error of a scaled value "
            f"{twin['largest_relative_error_of_scaled_values']:.1e}"
        )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        print(f"[aod constraint] {len(failures)} check(s) failed; see {args.run}/check_aod_constraint.json")
        return 1
    print("[aod constraint] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
