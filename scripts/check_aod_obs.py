#!/usr/bin/env python3
"""Check AOD observation files before a constrained run.

The AOD constraint reads one file per UTC day, with eight 3-hour windows whose
time stamp is the window center, on the cells of the model mesh in mesh order.
A file for another mesh has the right shape but the wrong cells, and the model
cannot tell; this check can. It also reports how much of the mesh is observed.

  scripts/check_aod_obs.py --mesh-file x1.40962.init.nc modis_viirs_aod_3hr.x1.40962.20241015.nc ...
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import netCDF4
import numpy as np

WINDOW_CENTERS = [f"{hour:02d}:30:00" for hour in range(1, 24, 3)]
CELL_TOLERANCE = 1e-9  # radians


def check(path: Path, lat: np.ndarray, lon: np.ndarray) -> tuple[list[str], float]:
    """Problems found in one file, and the fraction of cell-windows observed."""
    problems: list[str] = []
    with netCDF4.Dataset(path) as nc:
        nc.set_auto_mask(False)
        if nc.data_model == "NETCDF4":
            problems.append("is NetCDF-4; the model reads classic, 64-bit offset, or CDF-5 files")
        for name in ("xtime", "latCell", "lonCell", "AOD_mean"):
            if name not in nc.variables:
                return problems + [f"has no variable {name}"], 0.0
        if nc["AOD_mean"].dimensions != ("Time", "nCells"):
            return problems + [f"AOD_mean has dimensions {nc['AOD_mean'].dimensions}"], 0.0
        if nc.dimensions["nCells"].size != lat.size:
            return problems + [f"has {nc.dimensions['nCells'].size} cells, the mesh {lat.size}"], 0.0
        day = path.name.split(".")[-2]
        expected = [f"{day[:4]}-{day[4:6]}-{day[6:]}_{center}" for center in WINDOW_CENTERS]
        times = [b"".join(row).decode().strip("\x00 ") for row in nc["xtime"][:]]
        if times != expected:
            problems.append(f"has times {times}; expected the window centers of {day}")
        for name, reference in (("latCell", lat), ("lonCell", lon)):
            if np.abs(nc[name][:] - reference).max() > CELL_TOLERANCE:
                problems.append(f"{name} differs from the mesh: another mesh or another cell order")
        aod = nc["AOD_mean"][:]
        if not np.isfinite(aod).all():
            problems.append("AOD_mean has non-finite values")
        observed = float((aod >= 0).mean())
    return problems, observed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--mesh-file", type=Path, required=True, help="static or init file of the run")
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()

    with netCDF4.Dataset(args.mesh_file) as mesh:
        lat = np.asarray(mesh["latCell"][:], dtype="f8")
        lon = np.asarray(mesh["lonCell"][:], dtype="f8")
    failed = False
    for path in args.files:
        problems, observed = check(path, lat, lon)
        if problems:
            failed = True
            for problem in problems:
                print(f"ERROR: {path.name} {problem}")
        else:
            print(f"[aod obs] {path.name}: {observed:.1%} of cell-windows observed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
