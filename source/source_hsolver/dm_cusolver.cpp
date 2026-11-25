#if defined(__MPI) && defined(__CUDA)
#include "dm_cusolver.h"
#include "source_base/module_device/device.h"
#include "source_base/module_external/blacs_connector.h"
#include "source_base/module_external/scalapack_connector.h"
#include "source_base/timer.h"

#include <algorithm>
#include <cstdio>
#include <new>
#include <vector>

namespace hsolver
{
bool single_gpu_grid(const Parallel_Blkcyclic& layout, const int world_rank)
{
    const base_device::DeviceContext& context = base_device::DeviceContext::instance();
    const bool grid_root = layout.irproc() == 0 && layout.icproc() == 0;
    int unsupported = context.get_device_count() != 1
                      || context.get_local_rank() != world_rank
                      || grid_root != (world_rank == 0);
    const int grid = layout.ictxt();
    char scope = 'A';
    char topology = ' ';
    Cigsum2d(grid, &scope, &topology, 1, 1, &unsupported, 1, -1, -1);
    return unsupported == 0;
}

bool build_cusolver_dm(DiagoCusolver<std::complex<double>>*, const ModuleBase::matrix&,
                       const Parallel_Blkcyclic&, module_dm::DensityMatrix<std::complex<double>, double>&)
{
    return false;
}

bool build_cusolver_dm(DiagoCusolver<double>* solver, const ModuleBase::matrix& weights,
                       const Parallel_Blkcyclic& layout, module_dm::DensityMatrix<double, double>& dm)
{
    ModuleBase::timer::start("HSolverLCAO", "build_cusolver_dm");
    const int n = layout.nrglb();
    const int context = layout.ictxt();
    const bool root = layout.irproc() == 0 && layout.icproc() == 0;
    std::vector<double> density;
    int success = 0;
    if (root)
    {
        try
        {
            const std::size_t count = static_cast<std::size_t>(n) * n;
            density.resize(count);
            const double* occupations = &weights(0, 0);
            double* result = density.data();
            success = solver != nullptr && solver->dc.density_matrix(occupations, result);
        }
        catch (const std::bad_alloc&)
        {
            success = 0;
        }
    }

    // All ranks take the same fallback; the normal host/distributed psi is
    // still available to the CPU DM builder and other wavefunction consumers.
    char scope = 'A';
    char topology = ' ';
    if (root)
    {
        Cigebs2d(context, &scope, &topology, 1, 1, &success, 1);
        if (!success)
        {
            std::fprintf(stderr, "cuSOLVER density matrix unavailable; using CPU dm_from_psi\n");
        }
    }
    else
    {
        Cigebr2d(context, &scope, &topology, 1, 1, &success, 1, 0, 0);
    }
    if (success)
    {
        const int leading_dimension = layout.irproc() == 0 ? n : 1;
        int full_desc[9] = {1, context, n, n, n, n, 0, 0, leading_dimension};
        int distributed_desc[9];
        const int* descriptor = layout.desc();
        const int* descriptor_end = descriptor + 9;
        std::copy(descriptor, descriptor_end, distributed_desc);
        double* full_density = density.data();
        double* local_density = dm.get_dmk_ptr(0);
        Cpdgemr2d(n, n, full_density, 1, 1, full_desc,
                  local_density, 1, 1, distributed_desc, context);
    }
    ModuleBase::timer::end("HSolverLCAO", "build_cusolver_dm");
    return success != 0;
}
} // namespace hsolver
#endif
