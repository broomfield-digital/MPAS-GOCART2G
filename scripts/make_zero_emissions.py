#!/usr/bin/env python3
"""Write all-zero MPAS-GOCART2G emission inputs and the matching stream blocks.

The atmosphere core reads its anthropogenic, biogenic, and biomass-burning
emission streams each time an emission alarm rings; there is no namelist switch
that skips those reads. A run without real UPTEMPO products therefore still
needs files for all of the streams. This tool writes one CDF-5 file per stream
with every variable set to zero, plus an XML fragment that defines the streams.

The variable lists come from the model Registry, so the files follow the
source tree they are generated from. The two cores register different subsets:
init_atmosphere knows every CAMS sector, the atmosphere core only the sectors
it uses. Each file therefore carries the init_atmosphere (superset) list, and
a separate stream fragment is written for each core. Listing a variable a core
has not registered makes its stream parser abort.

Zero emissions are a software test input, not a scientific emission scenario.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

import netCDF4
import numpy as np

STR_LEN = 64
INIT_REGISTRY = "Registry_init_gocart2G_emissions.xml"
ATMOSPHERE_REGISTRY = "Registry_gocart2G_emissions_update.xml"

ANTH_SPECIES = ("bc", "oc", "so2", "nh3", "co", "iso", "mnt")
BIOG_STREAMS = {
    "biog_co_emissions": "co_biog_megan",
    "biog_iso_emissions": "iso_biog_megan",
    "biog_mnt_emissions": "mnt_biog_megan",
    "biog_apinene_emissions": "mnta_biog_megan",
    "biog_bpinene_emissions": "mntb_biog_megan",
}
BIOB_STREAMS = {
    "biob_bc_emissions": "bc_biob_modis",
    "biob_oc_emissions": "oc_biob_modis",
    "biob_ni_emissions": "nh3_biob_modis",
    "biob_su_emissions": "so2_biob_modis",
    "biob_co_emissions": "co_biob_modis",
    "biob_iso_emissions": "iso_biob_modis",
    "biob_mnt_emissions": "mnt_biob_modis",
}


def registry_structs(path: Path) -> dict[str, list[str]]:
    """Return {var_struct name: [variable names]} for a Registry fragment."""
    structs: dict[str, list[str]] = {}
    current = None
    for line in path.read_text().splitlines():
        opened = re.search(r'<var_struct\s+name="([^"]+)"', line)
        if opened:
            current = opened.group(1)
            structs[current] = []
            continue
        if "</var_struct>" in line:
            current = None
            continue
        var = re.search(r'<var\s+name="([^"]+)"', line)
        if var and current is not None:
            structs[current].append(var.group(1))
    return structs


def stream_variables(structs: dict[str, list[str]]) -> dict[str, list[str]]:
    """Map each emission stream the model reads to its Registry variables."""
    for needed in ("CAMS_anth_emissions", "CAMS_biog_emissions", "FINN_biob_emissions"):
        if needed not in structs:
            raise SystemExit(f"Registry has no var_struct named {needed}")

    streams: dict[str, list[str]] = {}
    anth = structs["CAMS_anth_emissions"]
    for species in ANTH_SPECIES:
        names = [name for name in anth if name.startswith(f"{species}_anth_")]
        if not names:
            raise SystemExit(f"Registry has no anthropogenic variables for {species}")
        streams[f"anth_{species}_emissions"] = names
    unassigned = set(anth) - {name for names in streams.values() for name in names}
    if unassigned:
        raise SystemExit(f"Unassigned anthropogenic variables: {sorted(unassigned)}")

    for table, struct in ((BIOG_STREAMS, "CAMS_biog_emissions"), (BIOB_STREAMS, "FINN_biob_emissions")):
        available = set(structs[struct])
        for stream, name in table.items():
            if name not in available:
                raise SystemExit(f"{struct} has no variable named {name}")
            streams[stream] = [name]
        extra = available - set(table.values())
        if extra:
            raise SystemExit(f"Unassigned {struct} variables: {sorted(extra)}")
    return streams


def month_starts(start: dt.date, stop: dt.date) -> list[dt.date]:
    """First-of-month dates from the month of start through the month after stop."""
    dates = []
    year, month = start.year, start.month
    while True:
        dates.append(dt.date(year, month, 1))
        if (year, month) > (stop.year, stop.month):
            return dates
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)


def write_zero_file(path: Path, names: list[str], n_cells: int, dates: list[dt.date]) -> None:
    with netCDF4.Dataset(path, "w", format="NETCDF3_64BIT_DATA") as nc:
        nc.createDimension("Time", None)
        nc.createDimension("nCells", n_cells)
        nc.createDimension("StrLen", STR_LEN)
        xtime = nc.createVariable("xtime", "S1", ("Time", "StrLen"))
        xtime.long_name = "model times"
        stamps = np.zeros((len(dates), STR_LEN), dtype="S1")
        for i, date in enumerate(dates):
            text = date.strftime("%Y-%m-%d_00:00:00").ljust(STR_LEN).encode()
            stamps[i, :] = np.frombuffer(text, dtype="S1")
        xtime[:, :] = stamps
        zeros = np.zeros((len(dates), n_cells), dtype="f4")
        for name in names:
            var = nc.createVariable(name, "f4", ("Time", "nCells"))
            var.units = "kg m^{-2} s^{-1}"
            var.long_name = f"{name} (all zero; software test input)"
            var[:, :] = zeros
        nc.title = "All-zero MPAS-GOCART2G emission input"
        nc.comment = "Generated by scripts/make_zero_emissions.py; not a scientific emission scenario."


def stream_block(stream: str, filename: str, names: list[str]) -> str:
    lines = [
        f'<stream name="{stream}"',
        '        type="input"',
        f'        filename_template="{filename}"',
        '        filename_interval="none"',
        '        input_interval="none" >',
        "",
    ]
    lines += [f'    <var name="{name}"/>' for name in names]
    lines += ["</stream>", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--chemistry-dir", required=True, type=Path,
                        help="gocartMPAS/src/core_atmosphere/chemistry in the source tree")
    parser.add_argument("--mesh", required=True, type=Path,
                        help="any MPAS file on the target mesh (static or init); supplies nCells")
    parser.add_argument("--grid-name", required=True, help="mesh prefix, for example x1.40962")
    parser.add_argument("--start", required=True, help="first simulated day, YYYY-MM-DD")
    parser.add_argument("--stop", required=True, help="last simulated day, YYYY-MM-DD")
    parser.add_argument("--outdir", required=True, type=Path, help="directory for the emission files")
    parser.add_argument("--streams-atmosphere-out", required=True, type=Path,
                        help="file to receive the <stream> blocks for streams.atmosphere")
    parser.add_argument("--streams-init-out", type=Path,
                        help="file to receive the <stream> blocks for streams.init_atmosphere")
    args = parser.parse_args()

    start = dt.date.fromisoformat(args.start)
    stop = dt.date.fromisoformat(args.stop)
    if stop < start:
        raise SystemExit("--stop is before --start")

    with netCDF4.Dataset(args.mesh) as mesh:
        n_cells = mesh.dimensions["nCells"].size

    init_streams = stream_variables(registry_structs(args.chemistry_dir / INIT_REGISTRY))
    atm_streams = stream_variables(registry_structs(args.chemistry_dir / ATMOSPHERE_REGISTRY))
    for stream, names in atm_streams.items():
        missing = set(names) - set(init_streams[stream])
        if missing:
            raise SystemExit(f"{stream}: atmosphere variables absent from init Registry: {sorted(missing)}")

    dates = month_starts(start, stop)
    args.outdir.mkdir(parents=True, exist_ok=True)

    def filename(stream: str) -> str:
        return f"{args.grid_name}.zero.{stream}.nc"

    for stream, names in init_streams.items():
        write_zero_file(args.outdir / filename(stream), names, n_cells, dates)
    print(f"wrote {len(init_streams)} zero-emission files ({n_cells} cells, "
          f"{len(dates)} records {dates[0]}..{dates[-1]}) to {args.outdir}")

    for out, streams in ((args.streams_atmosphere_out, atm_streams), (args.streams_init_out, init_streams)):
        if out is None:
            continue
        out.write_text("\n".join(stream_block(s, filename(s), names) for s, names in streams.items()))
        print(f"wrote stream blocks to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
