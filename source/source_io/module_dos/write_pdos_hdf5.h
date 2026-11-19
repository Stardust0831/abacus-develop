#ifndef WRITE_PDOS_HDF5_H
#define WRITE_PDOS_HDF5_H

#include <string>
#include <vector>

class UnitCell;
namespace ModuleBase
{
class matrix;
}

namespace ModuleIO
{
/// Write the reduced PDOS on rank zero and return the path of the completed file.
std::string write_pdos_hdf5(const UnitCell& ucell, const std::vector<ModuleBase::matrix>& pdos, int nspin,
                            double emin, double de, const std::string& out_dir, int istep, int out_app_flag);
}
#endif
