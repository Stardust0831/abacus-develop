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

: "${SAI_CUDA_ROOT:?}"
: "${SAI_NVHPC_ROOT:?}"
: "${SAI_CUSOLVERMP_ROOT:?}"
: "${SAI_CUBLASMP_ROOT:?}"
: "${SAI_NCCL_ROOT:?}"

MPI_CC=$(command -v mpicc)
MPI_CXX=$(command -v mpicxx)
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
    "$SAI_NCCL_ROOT/lib/libnccl.so.2" \
    "$SAI_CUDA_ROOT/version.json"; do
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
[[ $(read_define "$cusolver_header" CUSOLVERMP_VER_MINOR) == 9 ]]
[[ $(read_define "$cusolver_header" CUSOLVERMP_VER_PATCH) == 0 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_MAJOR) == 0 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_MINOR) == 9 ]]
[[ $(read_define "$cublas_header" CUBLASMP_VER_PATCH) == 1 ]]
[[ $(read_define "$nccl_header" NCCL_MAJOR) == 2 ]]
[[ $(read_define "$nccl_header" NCCL_MINOR) == 29 ]]
[[ $(read_define "$nccl_header" NCCL_PATCH) == 3 ]]
NCCL_LINK_LIBRARY=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so")
NCCL_RUNTIME_LIBRARY=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
[[ "$NCCL_LINK_LIBRARY" == "$NCCL_RUNTIME_LIBRARY" ]]
readelf --wide -Ws "$NCCL_LINK_LIBRARY" \
    | awk '$8 == "ncclCommQueryProperties" {found=1} END {exit !found}'
MPI_VERSION_OUTPUT=$("$MPI_RUN" --version)
CUDA_VERSION_OUTPUT=$("$SAI_CUDA_ROOT/bin/nvcc" --version)
grep -F 'Open MPI) 5.0.10' <<< "$MPI_VERSION_OUTPUT" >/dev/null
grep -F 'release 12.9, V12.9.86' <<< "$CUDA_VERSION_OUTPUT" >/dev/null
grep -F '"version" : "12.9.20250531"' "$SAI_CUDA_ROOT/version.json" >/dev/null

mkdir -p "$BUILD_ROOT" "$INSTALL_ROOT"
export NVHPC_ROOT_DIR="$SAI_NVHPC_ROOT"
export CUSOLVERMP_PATH="$SAI_CUSOLVERMP_ROOT"
export CUBLASMP_PATH="$SAI_CUBLASMP_ROOT"
export NCCL_PATH="$SAI_NCCL_ROOT"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

cat > "$BUILD_ROOT/runtime-version-probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*get_version_t)(int *);

static void *open_library(const char *path)
{
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "dlopen(%s): %s\n", path, dlerror());
        exit(2);
    }
    return handle;
}

int main(int argc, char **argv)
{
    int cublasmp_version = 0;
    int nccl_version = 0;
    void *cusolvermp;
    void *cublasmp;
    void *nccl;
    get_version_t cublasmp_get_version;
    get_version_t nccl_get_version;

    if (argc != 4) return 2;
    cusolvermp = open_library(argv[1]);
    cublasmp = open_library(argv[2]);
    nccl = open_library(argv[3]);
    if (dlsym(cusolvermp, "cusolverMpGetVersion") == NULL) return 3;
    cublasmp_get_version = (get_version_t)dlsym(cublasmp, "cublasMpGetVersion");
    nccl_get_version = (get_version_t)dlsym(nccl, "ncclGetVersion");
    if (cublasmp_get_version == NULL || nccl_get_version == NULL) return 3;
    if (cublasmp_get_version(&cublasmp_version) != 0) return 4;
    if (nccl_get_version(&nccl_version) != 0) return 4;
    printf("CUBLASMP_RUNTIME_VERSION=%d\n", cublasmp_version);
    printf("NCCL_RUNTIME_VERSION=%d\n", nccl_version);
    return cublasmp_version == 901 && nccl_version == 22903 ? 0 : 5;
}
EOF
"$MPI_CC" "$BUILD_ROOT/runtime-version-probe.c" -ldl \
    -o "$BUILD_ROOT/runtime-version-probe"
"$BUILD_ROOT/runtime-version-probe" \
    "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    "$SAI_CUBLASMP_ROOT/lib/libcublasmp.so.0" \
    "$NCCL_RUNTIME_LIBRARY" | tee "$BUILD_ROOT/runtime-version.txt"

summary="$BUILD_ROOT/toolchain-summary.txt"
{
    echo "TOOLCHAIN_FILE=$TOOLCHAIN_FILE"
    echo "MPI_ROOT=$SAI_MPI_ROOT"
    echo "MPI_RUN=$MPI_RUN"
    echo "CUDA_ROOT=$SAI_CUDA_ROOT"
    echo "CUSOLVERMP_ROOT=$SAI_CUSOLVERMP_ROOT"
    echo "CUBLASMP_ROOT=$SAI_CUBLASMP_ROOT"
    echo "NCCL_ROOT=$SAI_NCCL_ROOT"
    echo "NCCL_LIBRARY=$NCCL_LINK_LIBRARY"
    grep -E '^#define CUSOLVERMP_(VER_MAJOR|VER_MINOR|VER_PATCH|VERSION)' "$SAI_CUSOLVERMP_ROOT/include/cusolverMp.h"
    grep -E '^#define CUBLASMP_(VER_MAJOR|VER_MINOR|VER_PATCH|VERSION)' "$SAI_CUBLASMP_ROOT/include/cublasmp.h"
    grep -E '^#define NCCL_(MAJOR|MINOR|PATCH|VERSION_CODE)' "$SAI_NCCL_ROOT/include/nccl.h"
    cat "$BUILD_ROOT/runtime-version.txt"
    "$MPI_RUN" --version | sed -n '1,2p'
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
    -DCMAKE_CUDA_FLAGS="-I$SAI_CUSOLVERMP_ROOT/include -I$SAI_CUBLASMP_ROOT/include" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=x86-64-v3 -mtune=generic" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$SAI_MPI_ROOT/lib" \
    -DENABLE_NATIVE_OPTIMIZATION=OFF \
    -DENABLE_MPI=ON -DENABLE_OPENMP=ON \
    -DUSE_CUDA=ON -DUSE_CUDA_MPI=ON \
    -DENABLE_LCAO=ON -DENABLE_ELPA=ON -DENABLE_LIBXC=ON \
    -DENABLE_LIBRI=OFF -DENABLE_MLALGO=OFF -DENABLE_RAPIDJSON=OFF \
    -DENABLE_PEXSI=OFF -DENABLE_DFTD4=OFF -DENABLE_CNPY=OFF \
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
    -DNCCL_INCLUDE_DIR="$SAI_NCCL_ROOT/include"

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
NCCL_LOADED_PATH=$(awk '$1 == "libnccl.so.2" {print $3; exit}' "$INSTALL_ROOT/ldd.txt")
[[ -n "$NCCL_LOADED_PATH" ]]
[[ $(readlink -f "$NCCL_LOADED_PATH") == "$NCCL_RUNTIME_LIBRARY" ]]
sha256sum "$ABACUS_BIN" | tee "$INSTALL_ROOT/abacus.sha256"

echo "ABACUS_BUILD_PASSED binary=$ABACUS_BIN"
