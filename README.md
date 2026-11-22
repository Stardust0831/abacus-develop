# Si32 HSE06 with Libxc 7.1.2

This directory contains the displaced 32-atom silicon cell, pseudopotential and numerical orbitals used to time Libxc CPU and CUDA evaluation in ABACUS. The input uses the Gamma point, 416 LCAO functions, 80 bands and a 60 Ry cutoff.

Build ABACUS with CUDA and link it to the official Libxc 7.1.2 release built with `-DENABLE_CUDA=ON`. Start each run from this directory with a fresh output directory. The supplied `INPUT` runs a single point with CPU Libxc. Set `device_xc gpu` to use CUDA Libxc. To calculate forces and stress, set both `cal_force` and `cal_stress` to `1`. Keep `device gpu` and `ks_solver cusolver` for all runs. [Libxc 7.1.2](https://gitlab.com/libxc/libxc/-/releases/7.1.2)

The benchmark used one Tesla V100-SXM2 (16 GB), one MPI rank, four physical CPU cores and single-threaded BLAS. On an allocated GPU, this Open MPI command binds the rank to four cores.

```sh
export OMP_NUM_THREADS=4 OMP_PROC_BIND=close OMP_PLACES=cores
export OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
mpirun -np 1 --bind-to core --map-by slot:PE=4 abacus_std_gpu
```

The CSV gives seconds for each of the three runs per workload and Libxc device. `xc_grid_s` is the Libxc grid evaluation including GPU memory allocation and transfers. `xc_potential_s` includes the surrounding XC potential routine. `wall_s` includes startup, SCF and any requested forces and stress. The PR table uses the median of each column. [Per-run timings](timings.csv)

The measured build used the earlier INPUT spelling `xc_device` and exported the existing timers for both modes. The supplied input uses the current `device_xc` spelling and relative paths to the same basis and pseudopotential files. [Measured ABACUS source](https://github.com/Stardust0831/abacus-develop/commit/f88b7f88082ab69b84fa264fed0aa4f23c003585)
