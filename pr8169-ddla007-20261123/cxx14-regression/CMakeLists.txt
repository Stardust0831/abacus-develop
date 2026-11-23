cmake_minimum_required(VERSION 3.18)
project(libri_release_cxx14_check LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
find_package(MPI REQUIRED COMPONENTS CXX)
find_package(OpenMP REQUIRED COMPONENTS CXX)
find_package(BLAS REQUIRED)
find_package(LAPACK REQUIRED)
find_package(LibDDLA 0.0.7 REQUIRED CONFIG)
# Compile the unchanged released numerical regression as C++14. The release's
# own test CMake still requests C++17 for GPU consumers of older DDLA revisions.
add_executable(test_lri_gpu_symmetry
  "${LIBRI_ROOT}/unittests/physics/gpu_symmetry/test_lri_gpu_symmetry.cpp")
target_include_directories(test_lri_gpu_symmetry PRIVATE
  "${LIBRI_ROOT}/include" "${LIBCOMM_ROOT}/include" "${CEREAL_ROOT}/include")
target_compile_definitions(test_lri_gpu_symmetry PRIVATE __GPU_RI __DDLA_RI)
target_link_libraries(test_lri_gpu_symmetry PRIVATE
  MPI::MPI_CXX OpenMP::OpenMP_CXX ${LAPACK_LIBRARIES} ${BLAS_LIBRARIES} ddla::ddla)
