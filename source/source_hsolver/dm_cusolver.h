#ifndef HSOLVER_DM_CUSOLVER_H
#define HSOLVER_DM_CUSOLVER_H

#include "diago_cusolver.h"
#include "source_base/parallel_blkcyc.h"
#include "source_estate/module_dm/density_matrix.h"

namespace hsolver
{
/// Collectively check that the grid shares one GPU and its root is world rank 0.
bool single_gpu_grid(const Parallel_Blkcyclic& layout, int world_rank);

/// Build on the solver's device and scatter into the existing DM descriptor.
/// Only the root owns a solver; all ranks receive the same success result.
bool build_cusolver_dm(DiagoCusolver<double>* solver, const ModuleBase::matrix& weights,
                       const Parallel_Blkcyclic& layout, module_dm::DensityMatrix<double, double>& dm);

bool build_cusolver_dm(DiagoCusolver<std::complex<double>>* solver, const ModuleBase::matrix& weights,
                       const Parallel_Blkcyclic& layout,
                       module_dm::DensityMatrix<std::complex<double>, double>& dm);
} // namespace hsolver

#endif
