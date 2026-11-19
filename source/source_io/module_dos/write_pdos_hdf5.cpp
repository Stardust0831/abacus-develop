#include "write_pdos_hdf5.h"
#include "pdos_orbitals.h"
#include "source_base/matrix.h"
#include "source_cell/unitcell.h"

#include <H5Cpp.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <random>
#include <stdexcept>
#include <sys/stat.h>

namespace
{
void write_int_attribute(H5::H5Object& obj, const char* name, int value)
{
    const H5::DataSpace scalar(H5S_SCALAR);
    auto attr = obj.createAttribute(name, H5::PredType::NATIVE_INT, scalar);
    attr.write(H5::PredType::NATIVE_INT, &value);
}

template <typename T>
void write_vector(H5::Group& group, const char* name, const H5::DataType& type, const std::vector<T>& values)
{
    const hsize_t count = values.size();
    const H5::DataSpace space(1, &count);
    auto dataset = group.createDataSet(name, type, space);
    dataset.write(values.data(), type);
}

void write_record(H5::Group& record, const UnitCell& cell, const std::vector<ModuleBase::matrix>& pdos,
                  int nspin, double emin, double de, int step)
{
    const int nenergy = pdos.front().nc;
    const bool spinor = nspin == 4;
    write_int_attribute(record, "ionic_step", step);
    write_int_attribute(record, "nspin", nspin);
    std::vector<double> energy(nenergy);
    for (int n = 0; n < nenergy; ++n)
    {
        energy[n] = emin + n * de;
    }
    write_vector(record, "energy_eV", H5::PredType::NATIVE_DOUBLE, energy);

    std::vector<std::vector<ModuleIO::PdosOrbital>> orbitals(cell.ntype);
    for (int it = 0; it < cell.ntype; ++it)
    {
        orbitals[it] = ModuleIO::pdos_orbitals(cell.atoms[it]);
    }
    std::vector<int> offsets{0};
    std::vector<int> l;
    std::vector<int> m;
    std::vector<const char*> species;
    for (int iat = 0; iat < cell.nat; ++iat)
    {
        const int it = cell.iat2it[iat];
        species.push_back(cell.atoms[it].label.c_str());
        for (const auto& orbital : orbitals[it])
        {
            l.push_back(orbital.l);
            m.push_back(orbital.m);
        }
        offsets.push_back(l.size());
    }
    H5::StrType label_type(H5::PredType::C_S1, H5T_VARIABLE);
    label_type.setCset(H5T_CSET_UTF8);
    write_vector(record, "species", label_type, species);
    write_vector(record, "atom_offsets", H5::PredType::NATIVE_INT, offsets);
    write_vector(record, "l", H5::PredType::NATIVE_INT, l);
    write_vector(record, "m", H5::PredType::NATIVE_INT, m);

    const hsize_t ne = nenergy;
    const hsize_t shape[] = {pdos.size(), l.size(), ne};
    H5::DataSpace space(3, shape);
    auto values = record.createDataSet("pdos", H5::PredType::NATIVE_DOUBLE, space);
    const H5::DataSpace scalar(H5S_SCALAR);
    const H5::StrType unit_type(H5::PredType::C_S1, 5);
    auto units = values.createAttribute("units", unit_type, scalar);
    units.write(unit_type, "1/eV");
    std::vector<double> block;
    for (size_t is = 0; is < pdos.size(); ++is)
    {
        for (int iat = 0; iat < cell.nat; ++iat)
        {
            const auto& channels = orbitals[cell.iat2it[iat]];
            const int first = cell.get_iat2iwt()[iat];
            block.resize(channels.size() * ne);
            for (size_t c = 0; c < channels.size(); ++c)
            {
                for (int n = 0; n < nenergy; ++n)
                {
                    block[c * ne + n] = channels[c].value(pdos[is], first, n, spinor);
                }
            }
            const hsize_t count[] = {1, channels.size(), ne};
            const hsize_t start[] = {is, static_cast<hsize_t>(offsets[iat]), 0};
            const H5::DataSpace memory(3, count);
            space.selectHyperslab(H5S_SELECT_SET, count, start);
            values.write(block.data(), H5::PredType::NATIVE_DOUBLE, memory, space);
        }
    }
}

void add_record(H5::H5File& file, bool initialize, const UnitCell& cell,
                const std::vector<ModuleBase::matrix>& pdos, int nspin, double emin, double de, int step)
{
    if (initialize)
    {
        write_int_attribute(file, "schema_version", 1);
        file.createGroup("records");
    }
    else
    {
        int version = 0;
        file.openAttribute("schema_version").read(H5::PredType::NATIVE_INT, &version);
        if (version != 1)
        {
            throw std::runtime_error("unsupported PDOS schema version " + std::to_string(version));
        }
    }
    auto records = file.openGroup("records");
    const auto next = records.getNumObjs() + 1;
    const std::string name = "records/" + std::to_string(next);
    // Only completed records are linked below /records. A retry can discard an interrupted write.
    if (file.nameExists("_pending"))
    {
        file.unlink("_pending");
    }
    {
        auto record = file.createGroup("_pending");
        write_record(record, cell, pdos, nspin, emin, de, step);
    }
    file.flush(H5F_SCOPE_LOCAL);
    file.move("_pending", name);
}
}

std::string ModuleIO::write_pdos_hdf5(const UnitCell& cell, const std::vector<ModuleBase::matrix>& pdos,
                                      int nspin, double emin, double de, const std::string& out_dir,
                                      int istep, int out_app_flag)
{
    const int step = istep < 0 ? 1 : istep + 1;
    const bool per_step = out_app_flag == 2 && istep >= 0;
    const std::string suffix = per_step ? "g" + std::to_string(step) : "";
    const std::string path = out_dir + "pdos" + suffix + ".h5";
    try
    {
        if (out_app_flag == 1 && istep > 0)
        {
            struct stat info;
            const bool exists = stat(path.c_str(), &info) == 0;
            const unsigned int flags = exists ? H5F_ACC_RDWR : H5F_ACC_EXCL;
            H5::H5File file(path, flags);
            add_record(file, !exists, cell, pdos, nspin, emin, de, step);
            file.close();
        }
        else
        {
            // Keep the previous complete file until its replacement closes successfully.
            const std::string temp = path + ".tmp." + std::to_string(std::random_device{}());
            H5::H5File file(temp, H5F_ACC_EXCL);
            try
            {
                add_record(file, true, cell, pdos, nspin, emin, de, step);
                file.close();
                if (std::rename(temp.c_str(), path.c_str()) != 0)
                {
                    throw std::runtime_error(std::strerror(errno));
                }
            }
            catch (...)
            {
                std::remove(temp.c_str());
                throw;
            }
        }
    }
    catch (const H5::Exception& e)
    {
        throw std::runtime_error(path + ": " + e.getDetailMsg());
    }
    catch (const std::exception& e)
    {
        throw std::runtime_error(path + ": " + e.what());
    }
    return path;
}
