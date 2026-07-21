#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${BUILD_ROOT:?}"
: "${INSTALL_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 1
}
sai_load_toolchain

: "${SAI_CUDA_ROOT:?}"
: "${SAI_NVHPC_ROOT:?}"
: "${SAI_MP_ROOT:?}"
: "${SAI_CUSOLVERMP_ROOT:?}"
: "${SAI_CUBLASMP_ROOT:?}"
: "${SAI_CAL_ROOT:?}"
: "${SAI_NCCL_ROOT:?}"
: "${SAI_RUNTIME_LIBRARY_PATH:?}"

MPI_CC=$(command -v mpicc)
MPI_CXX=$(command -v mpicxx)
MPI_RUN=$(command -v mpirun)

for path in \
    "$CI_SOURCE/CMakeLists.txt" \
    "$SAI_CUDA_ROOT/bin/nvcc" \
    "$SAI_CUSOLVERMP_ROOT/include/cusolverMp.h" \
    "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    "$SAI_CUBLASMP_ROOT/include/cublasmp.h" \
    "$SAI_CUBLASMP_ROOT/lib/libcublasmp.so.0" \
    "$SAI_CAL_ROOT/include/cal.h" \
    "$SAI_CAL_ROOT/lib/libcal.so.0" \
    "$SAI_NCCL_ROOT/include/nccl.h" \
    "$SAI_NCCL_ROOT/lib/libnccl.so" \
    "$SAI_NCCL_ROOT/lib/libnccl.so.2"; do
    [[ -e "$path" ]] || {
        echo "Required toolchain path is missing: $path" >&2
        exit 1
    }
done

read_define() {
    local header=$1
    local name=$2
    awk -v name="$name" '$1 == "#define" && $2 == name {print $3; exit}' "$header"
}

cusolver_header="$SAI_CUSOLVERMP_ROOT/include/cusolverMp.h"
cublas_header="$SAI_CUBLASMP_ROOT/include/cublasmp.h"
nccl_header="$SAI_NCCL_ROOT/include/nccl.h"
[[ $(read_define "$cusolver_header" CUSOLVERMP_VER_MAJOR) == 0 ]]
[[ $(read_define "$cusolver_header" CUSOLVERMP_VER_MINOR) == 5 ]]
[[ $(read_define "$cusolver_header" CUSOLVERMP_VER_PATCH) == 0 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_MAJOR) == 0 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_MINOR) == 2 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_PATCH) == 0 ]]
[[ $(read_define "$nccl_header" NCCL_MAJOR) == 2 ]]
[[ $(read_define "$nccl_header" NCCL_MINOR) == 18 ]]
[[ $(read_define "$nccl_header" NCCL_PATCH) == 5 ]]

NCCL_LINK_LIBRARY=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so")
NCCL_RUNTIME_LIBRARY=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
[[ "$NCCL_LINK_LIBRARY" == "$NCCL_RUNTIME_LIBRARY" ]]
[[ "$NCCL_LINK_LIBRARY" == "$SAI_NCCL_ROOT/lib/libnccl.so.2.18.5" ]]

# cuSolverMp 0.5 is a CAL library. Record and enforce that this legacy test is
# not silently selecting the later NCCL communicator backend.
readelf -d "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    | grep -F 'Shared library: [libcal.so.0]' >/dev/null
if readelf -d "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    | grep -Eq 'Shared library: \[lib(nccl|cublasmp)'; then
    echo "Unexpected NCCL/cuBLASMp dependency in cuSolverMp 0.5" >&2
    exit 1
fi

MPI_VERSION_OUTPUT=$("$MPI_RUN" --version)
CUDA_VERSION_OUTPUT=$("$SAI_CUDA_ROOT/bin/nvcc" --version)
grep -F 'Open MPI) 5.0.8' <<< "$MPI_VERSION_OUTPUT" >/dev/null
grep -F 'release 12.4, V12.4.131' <<< "$CUDA_VERSION_OUTPUT" >/dev/null
[[ "$MPI_CC" == /opt/devtools/openmpi/openmpi-5.0.8-nvhpc245-gnu-avx2/bin/mpicc ]]
module -t list 2>&1 | grep -Fx 'nvhpc/24.5-gnu-tuned' >/dev/null
module -t list 2>&1 | grep -Fx 'openmpi/5.0.8-nvhpc24.5-gnu-auto' >/dev/null

mkdir -p "$BUILD_ROOT" "$INSTALL_ROOT"
summary="$BUILD_ROOT/toolchain-summary.txt"
{
    echo "TOOLCHAIN_FILE=$TOOLCHAIN_FILE"
    echo "MPI_ROOT=$SAI_MPI_ROOT"
    echo "CUDA_ROOT=$SAI_CUDA_ROOT"
    echo "NVHPC_ROOT=$SAI_NVHPC_ROOT"
    echo "CUSOLVERMP_ROOT=$SAI_CUSOLVERMP_ROOT"
    echo "CUBLASMP_ROOT=$SAI_CUBLASMP_ROOT"
    echo "CAL_ROOT=$SAI_CAL_ROOT"
    echo "NCCL_ROOT=$SAI_NCCL_ROOT"
    echo "NCCL_LINK_SYMLINK=$SAI_NCCL_ROOT/lib/libnccl.so"
    echo "NCCL_LINK_TARGET=$(readlink "$SAI_NCCL_ROOT/lib/libnccl.so")"
    echo "NCCL_RUNTIME_SYMLINK=$SAI_NCCL_ROOT/lib/libnccl.so.2"
    echo "NCCL_RUNTIME_TARGET=$(readlink "$SAI_NCCL_ROOT/lib/libnccl.so.2")"
    echo "NCCL_LIBRARY=$NCCL_LINK_LIBRARY"
    grep -E '^#define CUSOLVERMP_(VER_MAJOR|VER_MINOR|VER_PATCH|VERSION)' "$cusolver_header"
    grep -E '^#define CUBLASMP_(VER_MAJOR|VER_MINOR|VER_PATCH|VERSION)' "$cublas_header"
    grep -E '^#define NCCL_(MAJOR|MINOR|PATCH|VERSION_CODE)' "$nccl_header"
    readelf -d "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" | grep NEEDED
    "$MPI_RUN" --version | sed -n '1,2p'
    "$MPI_CXX" --showme:command
    "$MPI_CXX" --showme:compile
    "$MPI_CXX" --showme:link
    "$MPI_CXX" --version | sed -n '1,2p'
    "$SAI_CUDA_ROOT/bin/nvcc" --version
    module -t list 2>&1
} | tee "$summary"

cmake -S "$CI_SOURCE" -B "$BUILD_ROOT" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
    -DCMAKE_C_COMPILER="$MPI_CC" \
    -DCMAKE_CXX_COMPILER="$MPI_CXX" \
    -DCMAKE_CUDA_COMPILER="$SAI_CUDA_ROOT/bin/nvcc" \
    -DCMAKE_CUDA_ARCHITECTURES=70 \
    -DCMAKE_CUDA_FLAGS="-I$SAI_CUSOLVERMP_ROOT/include" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=x86-64-v3 -mtune=generic" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$SAI_MPI_ROOT/lib" \
    -DENABLE_NATIVE_OPTIMIZATION=OFF \
    -DENABLE_MPI=ON -DENABLE_OPENMP=ON \
    -DUSE_CUDA=ON -DUSE_CUDA_MPI=ON \
    -DENABLE_LCAO=ON -DENABLE_ELPA=OFF -DENABLE_LIBXC=ON \
    -DENABLE_LIBRI=OFF -DENABLE_MLALGO=OFF -DENABLE_RAPIDJSON=OFF \
    -DENABLE_PEXSI=OFF -DENABLE_DFTD4=OFF -DENABLE_CNPY=OFF \
    -DENABLE_CUSOLVERMP=ON -DENABLE_CUBLASMP=OFF \
    -DENABLE_NCCL_PARALLEL_DEVICE=OFF \
    -DBUILD_TESTING=OFF -DGIT_SUBMODULE=OFF \
    -DCAL_CUSOLVERMP_PATH="$SAI_CUSOLVERMP_ROOT" \
    -DCUSOLVERMP_LIBRARY="$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    -DCUSOLVERMP_INCLUDE_DIR="$SAI_CUSOLVERMP_ROOT/include" \
    -DNVHPC_ROOT_DIR="$SAI_MP_ROOT"

cmake --build "$BUILD_ROOT" --parallel "${SAI_BUILD_JOBS:-32}"
cmake --install "$BUILD_ROOT"

if [[ -x "$INSTALL_ROOT/bin/abacus_max_gpu" ]]; then
    ln -sfn abacus_max_gpu "$INSTALL_ROOT/bin/abacus"
fi
ABACUS_BIN="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS_BIN" ]]

"$ABACUS_BIN" --info | tee "$INSTALL_ROOT/abacus-info.txt"
ldd "$ABACUS_BIN" | tee "$INSTALL_ROOT/ldd.txt"
! grep -q "not found" "$INSTALL_ROOT/ldd.txt"
grep -q "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" "$INSTALL_ROOT/ldd.txt"
grep -q "$SAI_CAL_ROOT/lib/libcal.so.0" "$INSTALL_ROOT/ldd.txt"
sha256sum "$ABACUS_BIN" | tee "$INSTALL_ROOT/abacus.sha256"

echo "ABACUS_BUILD_PASSED profile=$SAI_PROFILE_NAME binary=$ABACUS_BIN"
