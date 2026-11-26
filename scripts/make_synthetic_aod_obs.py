#!/usr/bin/env python3
"""Write synthetic observation files for the AOD constraint.

The constraint reads aerosol optical depth at 550 nm on the model mesh from
one file per UTC day, eight 3-hour windows each (the format is described in
AGENTS.md, "AOD constraint"). Real files come from satellite retrievals. This
tool writes files with a known, simple content so the model option can be
tested without them:

  uniform   the same optical depth in every cell
  box       that optical depth inside a latitude-longitude box, no
            observation elsewhere
  none      no observation anywhere (the constraint must then change nothing)

Synthetic observations are a software test input, not data.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

import netCDF4
import numpy as np

CONTRACT = "mpas-aod-obs-v1"
PRODUCT = "modis_viirs_aod_3hr"
WINDOW_SECONDS = 10800
WINDOWS_PER_DAY = 8
STR_LEN = 64
FILL = -999.0


def filename(mesh_name: str, day: dt.date) -> str:
    return f"{PRODUCT}.{mesh_name}.{day:%Y%m%d}.nc"


def window_centers(day: dt.date) -> list[str]:
    """Centers of the eight 3-hour windows of a UTC day, as MPAS time strings."""
    start = dt.datetime(day.year, day.month, day.day)
    return [
        f"{start + dt.timedelta(seconds=(index + 0.5) * WINDOW_SECONDS):%Y-%m-%d_%H:%M:%S}"
        for index in range(WINDOWS_PER_DAY)
    ]


def observed_cells(mode: str, lat: np.ndarray, lon: np.ndarray, box: list[float]) -> np.ndarray:
    """Cells that get an observation. Latitude and longitude are in radians."""
    if mode == "uniform":
        return np.ones(lat.size, dtype=bool)
    if mode == "none":
        return np.zeros(lat.size, dtype=bool)
    south, north, west, east = box
    lat_deg = np.degrees(lat)
    lon_deg = (np.degrees(lon) + 180.0) % 360.0 - 180.0
    inside = (lat_deg >= south) & (lat_deg <= north)
    if west <= east:
        return inside & (lon_deg >= west) & (lon_deg <= east)
    return inside & ((lon_deg >= west) | (lon_deg <= east))


def write_day(
    path: Path,
    mesh_name: str,
    lat: np.ndarray,
    lon: np.ndarray,
    day: dt.date,
    observed: np.ndarray,
    value: float,
    uncertainty: float,
) -> None:
    n_cells = lat.size
    with netCDF4.Dataset(path, "w", format="NETCDF3_64BIT_DATA") as nc:
        nc.createDimension("Time", None)
        nc.createDimension("nCells", n_cells)
        nc.createDimension("StrLen", STR_LEN)
        xtime = nc.createVariable("xtime", "S1", ("Time", "StrLen"))
        xtime.long_name = "center of the 3-hour observation window"
        stamps = [text.ljust(STR_LEN).encode() for text in window_centers(day)]
        xtime[:, :] = np.array([list(stamp) for stamp in stamps], dtype="u1").view("S1")
        for name, values in (("latCell", lat), ("lonCell", lon)):
            variable = nc.createVariable(name, "f8", ("nCells",))
            variable.units = "rad"
            variable[:] = values
        rows = np.broadcast_to(observed, (WINDOWS_PER_DAY, n_cells))
        for name, long_name, number in (
            ("AOD_mean", "merged column aerosol optical depth at 550 nm", value),
            ("AOD_uncertainty", "one-sigma uncertainty of AOD_mean", uncertainty),
        ):
            variable = nc.createVariable(name, "f4", ("Time", "nCells"), fill_value=FILL)
            variable.units = "1"
            variable.long_name = long_name
            variable[:, :] = np.where(rows, number, FILL)
        count = nc.createVariable("AOD_count", "i4", ("Time", "nCells"), fill_value=0)
        count.units = "1"
        count.long_name = "accepted Level-2 pixels in the cell and window"
        count[:, :] = np.where(rows, 1, 0)
        nc.contract = CONTRACT
        nc.mesh_name = mesh_name
        nc.aod_wavelength_nm = 550
        nc.window_length_s = WINDOW_SECONDS
        nc.time_convention = "xtime is the center of each window; UTC, Gregorian calendar"
        nc.source = "synthetic test input written by scripts/make_synthetic_aod_obs.py"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--mesh-file", type=Path, required=True, help="grid, static, or init file")
    parser.add_argument("--mesh-name", required=True, help="for example x1.40962")
    parser.add_argument("--start", required=True, help="first UTC day, YYYY-MM-DD")
    parser.add_argument("--days", type=int, required=True, help="number of daily files")
    parser.add_argument("--outdir", type=Path, required=True)
    parser.add_argument("--mode", choices=("uniform", "box", "none"), default="uniform")
    parser.add_argument("--aod", type=float, default=0.2, help="optical depth where observed")
    parser.add_argument("--uncertainty", type=float, default=0.05)
    parser.add_argument(
        "--box",
        type=float,
        nargs=4,
        default=[-30.0, 30.0, -60.0, 60.0],
        metavar=("SOUTH", "NORTH", "WEST", "EAST"),
        help="degrees; used by --mode box",
    )
    args = parser.parse_args()
    if args.aod < 0 or args.days < 1:
        parser.error("--aod must not be negative and --days must be at least 1")

    with netCDF4.Dataset(args.mesh_file) as mesh:
        lat = np.asarray(mesh["latCell"][:], dtype="f8")
        lon = np.asarray(mesh["lonCell"][:], dtype="f8")
    observed = observed_cells(args.mode, lat, lon, args.box)
    first = dt.datetime.strptime(args.start, "%Y-%m-%d").date()
    args.outdir.mkdir(parents=True, exist_ok=True)
    for offset in range(args.days):
        day = first + dt.timedelta(days=offset)
        write_day(
            args.outdir / filename(args.mesh_name, day),
            args.mesh_name,
            lat,
            lon,
            day,
            observed,
            args.aod,
            args.uncertainty,
        )
    print(
        f"wrote {args.days} file(s) to {args.outdir}: mode {args.mode}, "
        f"{int(observed.sum())} of {lat.size} cells observed, AOD {args.aod}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
