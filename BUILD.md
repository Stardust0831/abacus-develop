# Building the two recorded variants

The package provides ABACUS integration patches and fixed source identities. It does not bundle compilers, dependencies, or ABACUS executables. Full dependency/toolchain choices are recorded in `versions.json` and `build-options.json`.

| Component | Source | Commit |
| --- | --- | --- |
| ABACUS | https://github.com/deepmodeling/abacus-develop | `4e9f1636b7ca27d1dc634711915c18087654b911` |
| Baseline LibRI | https://github.com/abacusmodeling/LibRI | `0e8afc3931ee4cdf564699811ca220215570dd6b` |
| PR LibRI | https://github.com/maki49/LibRI | `5025261859f0c8b53d84eb1e2476aaec3f7bf202` |
| DDLA | https://github.com/userchba/LibDDLA | `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7` |
| LibXC | https://gitlab.com/libxc/libxc | `3c7794c5047d5f19c088b856b24879ac7174ddfe` |

Use GCC 13.3, CUDA 12.9, C++17, and CUDA architecture 70 for the measured V100 configuration. Build DDLA with its CUDA backend and LibXC with CUDA support. Both ABACUS variants must use the same DDLA, LibXC, MPI, BLAS/LAPACK, FFTW and ELPA installations. LibComm, cereal and nlohmann-json are also required. The measured optional GPU libraries included cuSOLVERMp, cuBLASMp and NCCL; machine-learning support was disabled. Set the CMake package paths according to your installations.

Prepare two separate ABACUS source trees at the recorded commit. Apply `patches/abacus-gpu-libs.patch` to both. It enables GPU RI through DDLA and supplies `SAI_RI_DEVICE=cpu|gpu` and `SAI_LIBXC_DEVICE=cpu|gpu`. Apply `patches/abacus-residency.patch` only to the PR tree. For example, from an existing package directory and a pristine checkout:

```bash
export BENCH_PACKAGE="$PWD"
git -C /path/to/abacus-baseline apply "$BENCH_PACKAGE/patches/abacus-gpu-libs.patch"
git -C /path/to/abacus-pr17 apply "$BENCH_PACKAGE/patches/abacus-gpu-libs.patch"
git -C /path/to/abacus-pr17 apply "$BENCH_PACKAGE/patches/abacus-residency.patch"
```

Configure the baseline with `LIBRI_DIR` pointing to `0e8afc3`; configure the PR build with `LIBRI_DIR` pointing to `5025261`. Use the same flags and installed dependencies for both. The key settings are:

```text
CMAKE_BUILD_TYPE=Release
CMAKE_CXX_STANDARD=17
CMAKE_CXX_FLAGS=-march=znver3 -mtune=znver3
CMAKE_C_FLAGS=-march=znver3 -mtune=znver3
CMAKE_CUDA_ARCHITECTURES=70
BUILD_TESTING=OFF
GIT_SUBMODULE=OFF
ENABLE_MPI=ON
ENABLE_OPENMP=ON
ENABLE_LCAO=ON
ENABLE_LIBRI=ON
ENABLE_LIBXC=ON
ENABLE_ELPA=ON
ENABLE_JSON=ON
ENABLE_MLALGO=OFF
USE_CUDA=ON
USE_CUDA_MPI=ON
ENABLE_CUSOLVERMP=ON
ENABLE_CUBLASMP=ON
ENABLE_NCCL_PARALLEL_DEVICE=ON
```

The CPU architecture flags above match the measured AMD 5995WX host. Use suitable flags on a different host, consistently for both variants, and record that change. CMake also needs `LIBCOMM_DIR`, `cereal_DIR`, `nlohmann_json_DIR`, `Libxc_DIR`, `LibDDLA_DIR`, and `ELPA_DIR` for installed dependencies. `CMAKE_EXPORT_COMPILE_COMMANDS=ON` allows comparison of the complete flags; the original comparison matched 1054 translation units.

The PR tree supports `SAI_RI_RESIDENT=0|1`. Setting it to 1 calls the public LibRI resident API with `data_names={"Cs_", "Vs_"}` and `budget_gib=0`, using the upstream automatic budget `min(free device memory / 3, 4 GiB)`. No LibRI source modifications were applied. The default and resident PR measurements use the same executable; the CPU/GPU backend measurements use the baseline executable.

The GPU LibXC adapter in the shared patch covers the tested HSE/PBE potential path. Its scope is separate from the LibRI PR. Original CTest and build-flag verification records are included under `evidence/checks/`; their successful results apply to the measured environment and fixed sources.
