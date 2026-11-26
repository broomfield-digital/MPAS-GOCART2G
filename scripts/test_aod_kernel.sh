#!/usr/bin/env bash
# Build and run the unit tests of the AOD-constraint arithmetic.
#
# The kernel depends only on the model's real kind, so it is compiled by itself
# with gfortran, in single and in double precision, under $G2G_WORK. Nothing is
# built inside the repository.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/g2g_env.sh"
g2g_activate

src=$G2G_REPO/gocartMPAS/src
work=$G2G_WORK/build/test_aod_kernel
status=0
for precision in single double; do
  dir=$work/$precision
  rm -rf "$dir" && mkdir -p "$dir"
  flag=""
  [[ $precision == single ]] && flag="-DSINGLE_PRECISION"
  (
    cd "$dir"
    gfortran -cpp $flag -ffree-form -O0 -g -fcheck=all -Wall -Wno-unused-dummy-argument \
      -ffpe-trap=invalid,zero,overflow \
      "$src/framework/mpas_kind_types.F" \
      "$src/core_atmosphere/chemistry/mpas_chemistry_gocart2G_aod_kernel.F90" \
      "$G2G_REPO/tests/fortran/test_aod_kernel.F90" -o test_aod_kernel > build.log 2>&1
  ) || { echo "ERROR: $precision-precision build failed; see $dir/build.log"; exit 1; }
  printf '%-7s ' "$precision"
  "$dir/test_aod_kernel" || status=1
done
exit $status
