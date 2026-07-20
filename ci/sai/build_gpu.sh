#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?CI_SOURCE must point to the staged ABACUS checkout}"
: "${BUILD_ROOT:?BUILD_ROOT must be set}"
: "${INSTALL_ROOT:?INSTALL_ROOT must be set}"
: "${TOOLCHAIN_FILE:?TOOLCHAIN_FILE must be set}"

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 1
}
sai_load_toolchain

: "${SAI_DEPENDENCY_ROOT:?}"
: "${SAI_DEPS_PREFIX:?}"
: "${SAI_CNPY_SOURCE:?}"
: "${SAI_DEEPMD_ROOT:?}"
: "${SAI_TORCH_ROOT:?}"
: "${SAI_REFERENCE_ROOT:?}"
: "${SAI_CMAKE_PREFIX_ROOT:?}"
: "${SAI_CUDA_ROOT:?}"
: "${SAI_NVHPC_ROOT:?}"
: "${SAI_CUSOLVERMP_ROOT:?}"
: "${SAI_CUBLASMP_ROOT:?}"
: "${SAI_NCCL_ROOT:?}"
: "${SAI_FFTW_INCLUDE:?}"

MPI_CC=$(command -v mpicc)
MPI_CXX=$(command -v mpicxx)
MPI_FC=$(command -v mpifort)
MPI_RUN=$(command -v mpirun)
SAI_MPI_ROOT=$(cd "$(dirname "$MPI_CC")/.." && pwd)
export SAI_MPI_ROOT

for path in \
    "$CI_SOURCE/CMakeLists.txt" \
    "$SAI_CUDA_ROOT/bin/nvcc" \
    "$SAI_CUSOLVERMP_ROOT/include/cusolverMp.h" \
    "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    "$SAI_CUBLASMP_ROOT/include/cublasmp.h" \
    "$SAI_CUBLASMP_ROOT/lib/libcublasmp.so.0" \
    "$SAI_NCCL_ROOT/include/nccl.h" \
    "$SAI_NCCL_ROOT/lib/libnccl.so" \
    "$SAI_CNPY_SOURCE/CMakeLists.txt" \
    "$SAI_DEEPMD_ROOT/include/deepmd/c_api.h" \
    "$SAI_DEEPMD_ROOT/lib/libdeepmd_c.so" \
    "$SAI_TORCH_ROOT/share/cmake/Torch/TorchConfig.cmake"; do
    [[ -e "$path" ]] || {
        echo "Required toolchain path is missing: $path" >&2
        exit 1
    }
done

PEXSI_CONFIG=$(find "$SAI_DEPS_PREFIX" -type f \
    \( -name PEXSIConfig.cmake -o -name pexsi-config.cmake \) \
    -print -quit 2>/dev/null || true)
[[ -n "$PEXSI_CONFIG" ]] || {
    echo "PEXSI CMake package not found under $SAI_DEPS_PREFIX" >&2
    exit 1
}
PEXSI_DIR=$(dirname "$PEXSI_CONFIG")

DFTD4_CONFIG=$(find "$SAI_DEPS_PREFIX" -type f \
    \( -name dftd4-config.cmake -o -name dftd4Config.cmake \) \
    -print -quit 2>/dev/null || true)
[[ -n "$DFTD4_CONFIG" ]] || {
    echo "DFT-D4 CMake package not found under $SAI_DEPS_PREFIX" >&2
    exit 1
}

mkdir -p "$BUILD_ROOT" "$INSTALL_ROOT"

export NVHPC_ROOT_DIR="$SAI_NVHPC_ROOT"
export CUSOLVERMP_PATH="$SAI_CUSOLVERMP_ROOT"
export CUBLASMP_PATH="$SAI_CUBLASMP_ROOT"
export NCCL_PATH="$SAI_NCCL_ROOT"
export TORCH_CUDA_ARCH_LIST=7.0
export CPATH="$SAI_REFERENCE_ROOT/cereal-master/include:$SAI_REFERENCE_ROOT/rapidjson-master/include:$SAI_REFERENCE_ROOT/LibRI-master/include:$SAI_REFERENCE_ROOT/LibComm-master/include:${CPATH:-}"
export CMAKE_PREFIX_PATH="$SAI_DEPS_PREFIX:$SAI_DEEPMD_ROOT:$SAI_TORCH_ROOT:$SAI_CMAKE_PREFIX_ROOT/cereal:$SAI_CMAKE_PREFIX_ROOT/rapidjson:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:$SAI_DEPS_PREFIX/lib:$SAI_DEPS_PREFIX/lib64:$SAI_DEEPMD_ROOT/lib:$SAI_TORCH_ROOT/lib:$SAI_REFERENCE_ROOT/NEP_CPU-main/lib:${LD_LIBRARY_PATH:-}"

summary="$BUILD_ROOT/toolchain-summary.txt"
{
    echo "TOOLCHAIN_FILE=$TOOLCHAIN_FILE"
    echo "MPI_ROOT=$SAI_MPI_ROOT"
    echo "MPI_RUN=$MPI_RUN"
    echo "CUDA_ROOT=$SAI_CUDA_ROOT"
    echo "CUSOLVERMP_ROOT=$SAI_CUSOLVERMP_ROOT"
    echo "CUBLASMP_ROOT=$SAI_CUBLASMP_ROOT"
    echo "NCCL_ROOT=$SAI_NCCL_ROOT"
    "$MPI_RUN" --version | head -2
    "$SAI_CUDA_ROOT/bin/nvcc" --version
    module -t list 2>&1
} | tee "$summary"

cmake -S "$CI_SOURCE" -B "$BUILD_ROOT" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
    -DCMAKE_C_COMPILER="$MPI_CC" \
    -DCMAKE_CXX_COMPILER="$MPI_CXX" \
    -DCMAKE_Fortran_COMPILER="$MPI_FC" \
    -DCMAKE_CUDA_COMPILER="$SAI_CUDA_ROOT/bin/nvcc" \
    -DCMAKE_CUDA_ARCHITECTURES=70 \
    -DCMAKE_CUDA_FLAGS="-I$SAI_CUSOLVERMP_ROOT/include -I$SAI_CUBLASMP_ROOT/include -I$SAI_FFTW_INCLUDE" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=x86-64-v3 -mtune=generic" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$SAI_MPI_ROOT/lib -Wl,--no-as-needed $SAI_DEEPMD_ROOT/lib/libdeepmd_c.so -Wl,--as-needed" \
    -DENABLE_NATIVE_OPTIMIZATION=OFF \
    -DENABLE_MPI=ON -DENABLE_OPENMP=ON \
    -DUSE_CUDA=ON -DUSE_CUDA_MPI=ON \
    -DENABLE_LCAO=ON -DENABLE_ELPA=ON -DENABLE_LIBXC=ON \
    -DENABLE_LIBRI=ON -DENABLE_MLALGO=ON -DENABLE_RAPIDJSON=ON \
    -DENABLE_PEXSI=ON -DENABLE_DFTD4=ON -DENABLE_CNPY=ON \
    -DENABLE_CUSOLVERMP=ON -DENABLE_CUBLASMP=ON \
    -DENABLE_NCCL_PARALLEL_DEVICE=ON \
    -DBUILD_TESTING=OFF -DGIT_SUBMODULE=OFF \
    -DCAL_CUSOLVERMP_PATH="$SAI_CUSOLVERMP_ROOT" \
    -DCUSOLVERMP_LIBRARY="$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    -DCUSOLVERMP_INCLUDE_DIR="$SAI_CUSOLVERMP_ROOT/include" \
    -DCUBLASMP_PATH="$SAI_CUBLASMP_ROOT" \
    -DCUBLASMP_LIBRARY="$SAI_CUBLASMP_ROOT/lib/libcublasmp.so.0" \
    -DCUBLASMP_INCLUDE_DIR="$SAI_CUBLASMP_ROOT/include" \
    -DNVHPC_ROOT_DIR="$SAI_NVHPC_ROOT" \
    -DNCCL_PATH="$SAI_NCCL_ROOT" \
    -DNCCL_LIBRARY="$SAI_NCCL_ROOT/lib/libnccl.so" \
    -DNCCL_INCLUDE_DIR="$SAI_NCCL_ROOT/include" \
    -DPEXSI_DIR="$PEXSI_DIR" \
    -DFETCHCONTENT_SOURCE_DIR_CNPY="$SAI_CNPY_SOURCE" \
    -DDeePMD_DIR="$SAI_DEEPMD_ROOT" \
    -DProtobuf_DIR="$SAI_TORCH_ROOT/lib/cmake/protobuf" \
    -DLIBRI_DIR="$SAI_REFERENCE_ROOT/LibRI-master" \
    -DLIBCOMM_DIR="$SAI_REFERENCE_ROOT/LibComm-master" \
    -Dcereal_DIR="$SAI_CMAKE_PREFIX_ROOT/cereal/lib/cmake/cereal" \
    -DRapidJSON_DIR="$SAI_CMAKE_PREFIX_ROOT/rapidjson/lib/cmake/RapidJSON" \
    -DTorch_DIR="$SAI_TORCH_ROOT/share/cmake/Torch" \
    -DNEP_DIR="$SAI_REFERENCE_ROOT/NEP_CPU-main" \
    -Dlibnpy_INCLUDE_DIR="$SAI_REFERENCE_ROOT/libnpy-1.0.1/include"

cmake --build "$BUILD_ROOT" --parallel "${SAI_BUILD_JOBS:-32}"
cmake --install "$BUILD_ROOT"

if [[ -x "$INSTALL_ROOT/bin/abacus_max_gpu" ]]; then
    ln -sfn abacus_max_gpu "$INSTALL_ROOT/bin/abacus"
fi
ABACUS_BIN="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS_BIN" ]] || {
    echo "ABACUS binary was not installed at $ABACUS_BIN" >&2
    exit 1
}

"$ABACUS_BIN" --info | tee "$INSTALL_ROOT/abacus-info.txt"
ldd "$ABACUS_BIN" | tee "$INSTALL_ROOT/ldd.txt"
! grep -q "not found" "$INSTALL_ROOT/ldd.txt"
grep -q "$SAI_CUSOLVERMP_ROOT" "$INSTALL_ROOT/ldd.txt"
grep -q "$SAI_CUBLASMP_ROOT" "$INSTALL_ROOT/ldd.txt"
sha256sum "$ABACUS_BIN" | tee "$INSTALL_ROOT/abacus.sha256"

echo "ABACUS_BUILD_PASSED binary=$ABACUS_BIN"
