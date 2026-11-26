#!/usr/bin/env python3
"""Write a SCRIP description of an MPAS mesh for ESMF regridding.

UPTEMPO regrids emission inventories with ESMF and needs the destination mesh
as a SCRIP file. Upstream builds that file with the Fortran mpas2esmf tool;
this script writes the same information from an MPAS grid, static, or init
file with numpy and netCDF4 only.

Each MPAS cell becomes one SCRIP cell whose corners are the cell's vertices in
their stored (counter-clockwise) order. Cells with fewer vertices than
maxEdges repeat their last vertex, which ESMF treats as a degenerate edge.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import netCDF4
import numpy as np


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mesh", type=Path, help="MPAS grid, static, or init file")
    parser.add_argument("scrip", type=Path, help="SCRIP file to write")
    args = parser.parse_args()

    with netCDF4.Dataset(args.mesh) as mesh:
        lat_cell = mesh["latCell"][:].astype("f8")
        lon_cell = mesh["lonCell"][:].astype("f8")
        lat_vertex = mesh["latVertex"][:].astype("f8")
        lon_vertex = mesh["lonVertex"][:].astype("f8")
        n_edges = mesh["nEdgesOnCell"][:].astype("i8")
        vertices = mesh["verticesOnCell"][:].astype("i8") - 1      # to 0-based
        area = mesh["areaCell"][:].astype("f8")
        radius = float(getattr(mesh, "sphere_radius", 1.0))

    n_cells, max_edges = vertices.shape
    # Pad each row with its last valid vertex.
    column = np.minimum(np.arange(max_edges)[None, :], (n_edges - 1)[:, None])
    padded = np.take_along_axis(vertices, column, axis=1)
    if padded.min() < 0 or padded.max() >= lat_vertex.size:
        raise SystemExit("verticesOnCell holds an index outside the vertex arrays")

    two_pi = 2.0 * np.pi
    with netCDF4.Dataset(args.scrip, "w", format="NETCDF3_64BIT_OFFSET") as out:
        out.createDimension("grid_size", n_cells)
        out.createDimension("grid_corners", max_edges)
        out.createDimension("grid_rank", 1)

        dims = out.createVariable("grid_dims", "i4", ("grid_rank",))
        dims[:] = [n_cells]
        mask = out.createVariable("grid_imask", "i4", ("grid_size",))
        mask[:] = 1

        def radians(name: str, shape: tuple[str, ...], values: np.ndarray) -> None:
            var = out.createVariable(name, "f8", shape)
            var.units = "radians"
            var[:] = values

        radians("grid_center_lat", ("grid_size",), lat_cell)
        radians("grid_center_lon", ("grid_size",), np.mod(lon_cell, two_pi))
        radians("grid_corner_lat", ("grid_size", "grid_corners"), lat_vertex[padded])
        radians("grid_corner_lon", ("grid_size", "grid_corners"), np.mod(lon_vertex[padded], two_pi))

        grid_area = out.createVariable("grid_area", "f8", ("grid_size",))
        grid_area.units = "radians^2"
        grid_area[:] = area / radius**2

        out.title = f"SCRIP description of the MPAS mesh in {args.mesh.name}"
        out.comment = "Written by scripts/make_mpas_scrip.py"

    print(f"wrote {args.scrip}: {n_cells} cells, up to {max_edges} corners")
    return 0


if __name__ == "__main__":
    sys.exit(main())
