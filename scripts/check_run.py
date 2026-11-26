#!/usr/bin/env python3
"""Check an MPAS-GOCART2G run directory and summarize its aerosol output.

Pass/fail covers what a software test can decide: the model logged no errors,
the expected hourly aerosol files exist, every field is finite, and each
enabled component (dust, sea salt) emitted mass and built a non-negative
burden. Whether the aerosol amounts are scientifically right is not decided
here; the printed numbers are for a person to judge.

Writes check_summary.json into the run directory. Exit status is 0 when all
checks pass and 1 otherwise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

import netCDF4
import numpy as np

SECONDS_PER_YEAR = 365.0 * 86400.0
COMPONENTS = {"du": "config_gocart2G_do_DU2G", "ss": "config_gocart2G_do_SS2G"}
LABELS = {"du": "dust", "ss": "sea salt"}


def xtime(nc: netCDF4.Dataset) -> dt.datetime:
    text = b"".join(nc["xtime"][0].data).decode().strip()
    return dt.datetime.strptime(text, "%Y-%m-%d_%H:%M:%S")


def namelist_flag(text: str, name: str) -> bool:
    match = re.search(rf"^\s*{name}\s*=\s*\.?(\w+)\.?", text, re.MULTILINE)
    return bool(match) and match.group(1).lower() in ("true", "t")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--hours", type=int, help="expected run length; checks the number of aerosol files")
    args = parser.parse_args()
    run = args.run_dir

    checks: list[tuple[str, bool, str]] = []

    def check(name: str, passed: bool, detail: str) -> None:
        checks.append((name, bool(passed), detail))

    # --- model log ---------------------------------------------------------
    log_path = run / "log.atmosphere.0000.out"
    log = log_path.read_text(errors="replace") if log_path.exists() else ""
    check("log exists", bool(log), str(log_path))
    critical = re.search(r"Critical error messages =\s*(\d+)", log)
    errors = re.search(r"Error messages =\s*(\d+)", log)
    check("no critical errors", bool(critical) and critical.group(1) == "0",
          f"critical={critical.group(1) if critical else 'log incomplete'}")
    check("no errors", bool(errors) and errors.group(1) == "0",
          f"errors={errors.group(1) if errors else 'log incomplete'}")
    err_files = sorted(p.name for p in run.glob("log.atmosphere.*.err"))
    check("no per-rank error logs", not err_files, ", ".join(err_files) or "none")
    wall = re.search(r"^\s*1 total time\s+([\d.]+)", log, re.MULTILINE)
    winds = re.findall(r"global min, max u\s+(\S+)\s+(\S+)", log)

    # --- output files ------------------------------------------------------
    frames = sorted(run.glob("aerosol.*.nc"))
    check("aerosol output exists", bool(frames), f"{len(frames)} files")
    if not frames:
        return report(run, checks, {})
    if args.hours is not None:
        check("aerosol file count", len(frames) == args.hours + 1, f"{len(frames)} files, expected {args.hours + 1}")

    init_files = sorted(run.glob("*.init.nc"))
    check("init file exists", bool(init_files), ", ".join(p.name for p in init_files) or "none")
    if not init_files:
        return report(run, checks, {})
    with netCDF4.Dataset(init_files[0]) as mesh:
        area = mesh["areaCell"][:].astype("f8")

    namelist = (run / "namelist.atmosphere").read_text()
    enabled = [prefix for prefix, flag in COMPONENTS.items() if namelist_flag(namelist, flag)]

    with netCDF4.Dataset(frames[0]) as first, netCDF4.Dataset(frames[-1]) as last:
        start, stop = xtime(first), xtime(last)
        elapsed_h = (stop - start).total_seconds() / 3600.0
        if args.hours is not None:
            check("final output time", abs(elapsed_h - args.hours) < 1e-6,
                  f"{stop:%Y-%m-%d_%H:%M:%S}, {elapsed_h:g} h after start")

        bad = [name for name, var in last.variables.items()
               if var.dtype.kind == "f" and not np.isfinite(var[:]).all()]
        check("all fields finite", not bad, ", ".join(bad) or "ok")

        summary: dict[str, object] = {
            "run_dir": str(run),
            "start": f"{start:%Y-%m-%d_%H:%M:%S}",
            "stop": f"{stop:%Y-%m-%d_%H:%M:%S}",
            "elapsed_hours": elapsed_h,
            "wall_seconds": float(wall.group(1)) if wall else None,
            "n_cells": int(area.size),
            "enabled_components": enabled,
        }
        if winds:
            u_min, u_max = (float(x) for x in winds[-1])
            summary["final_u_min_max_m_s"] = [u_min, u_max]
            check("winds bounded", max(abs(u_min), abs(u_max)) < 250.0, f"u in [{u_min:g}, {u_max:g}] m/s")

        tau = last["totEXTTAU"][0, :, 0].astype("f8")
        summary["aod550_global_mean"] = float((tau * area).sum() / area.sum())
        summary["aod550_max"] = float(tau.max())
        check("total AOD non-negative", tau.min() >= 0.0, f"min={tau.min():.3e}")
        if enabled:
            check("total AOD positive somewhere", tau.max() > 0.0, f"max={tau.max():.3e}")

        for prefix in enabled:
            label = LABELS[prefix]
            emission = sum(last[f"{prefix}EM_bin{k}"][0].astype("f8") for k in range(1, 6))
            column = last[f"{prefix}CMASS"][0].astype("f8")
            rate = float((emission * area).sum())            # kg s-1
            burden = float((column * area).sum())            # kg
            # Cold-start diagnostic: a column cannot hold much more than its own
            # emission since the start unless transport supplied it.
            supply = emission * elapsed_h * 3600.0
            excess = (column > 1e-5) & (column > 10.0 * supply)
            summary[label] = {
                "emission_Tg_per_year_equivalent": rate * SECONDS_PER_YEAR / 1e9,
                "burden_Tg": burden / 1e9,
                "burden_over_emission_rate_hours": burden / rate / 3600.0 if rate > 0 else None,
                "column_mass_max_kg_m2": float(column.max()),
                "aod550_max": float(last[f"{prefix}EXTTAU"][0, :, 0].max()),
                "cells_over_10x_local_supply": int(excess.sum()),
                "burden_share_in_those_cells": float((column[excess] * area[excess]).sum() / burden) if burden > 0 else 0.0,
            }
            check(f"{label} emission positive", rate > 0.0, f"{rate:.3e} kg/s")
            check(f"{label} burden positive", burden > 0.0, f"{burden / 1e9:.4f} Tg")
            check(f"{label} column mass non-negative", column.min() >= 0.0, f"min={column.min():.3e}")

    return report(run, checks, summary)


def report(run: Path, checks: list[tuple[str, bool, str]], summary: dict[str, object]) -> int:
    passed = all(ok for _, ok, _ in checks)
    summary["checks"] = [{"name": name, "passed": ok, "detail": detail} for name, ok, detail in checks]
    summary["passed"] = passed
    (run / "check_summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    for name, ok, detail in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")
    if "elapsed_hours" in summary:
        print(f"\n{summary['elapsed_hours']:g} simulated hours, wall {summary.get('wall_seconds')} s")
        print(f"AOD 550 nm: global mean {summary['aod550_global_mean']:.4f}, max {summary['aod550_max']:.3f}")
        for label in LABELS.values():
            if label in summary:
                s = summary[label]
                print(f"{label}: emission {s['emission_Tg_per_year_equivalent']:.0f} Tg/yr-equivalent, "
                      f"burden {s['burden_Tg']:.4f} Tg, max column {s['column_mass_max_kg_m2']:.2e} kg/m2, "
                      f"{s['cells_over_10x_local_supply']} cells over 10x local supply "
                      f"({100 * s['burden_share_in_those_cells']:.1f}% of burden)")
    print(f"\n{'ALL CHECKS PASSED' if passed else 'CHECKS FAILED'}  ({run / 'check_summary.json'})")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
