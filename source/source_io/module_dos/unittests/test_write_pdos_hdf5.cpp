#include "../write_pdos_hdf5.h"
#include "source_base/matrix.h"
#include "source_cell/unitcell.h"

#include <H5Cpp.h>
#include <gtest/gtest.h>
#include <cstdio>
#include <cstdlib>

namespace
{
class WritePdosHdf5 : public testing::Test
{
protected:
    UnitCell cell;
    std::string dir;
    std::vector<ModuleBase::matrix> pdos;

    void SetUp() override
    {
        const std::string pattern = testing::TempDir() + "/abacus-pdos-XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back('\0');
        ASSERT_NE(mkdtemp(name.data()), nullptr);
        dir = std::string(name.data()) + "/";

        cell.nat = 2;
        cell.ntype = 2;
        cell.atoms = new Atom[2];
        cell.set_atom_flag = true;
        cell.iat2it = {0, 1};
        cell.iat2ia = {0, 0};
        cell.atoms[0].label = "H";
        cell.atoms[0].nw = 1;
        cell.atoms[0].nwl = 0;
        cell.atoms[0].iw2l = {0};
        cell.atoms[0].iw2m = {0};
        cell.atoms[1].label = "Si";
        cell.atoms[1].nw = 5;
        cell.atoms[1].nwl = 1;
        cell.atoms[1].iw2l = {0, 0, 1, 1, 1};
        cell.atoms[1].iw2m = {0, 0, 0, 1, 2};
    }

    void TearDown() override
    {
        if (!dir.empty())
        {
            std::remove((dir + "pdos.h5").c_str());
            std::remove((dir + "pdosg3.h5").c_str());
            std::remove(dir.c_str());
        }
    }

    std::string write(int nspin, int istep, int mode)
    {
        const int npol = nspin == 4 ? 2 : 1;
        cell.set_iat2iwt_for_test({0, npol}, npol);
        pdos.resize(nspin == 2 ? 2 : 1);
        for (size_t is = 0; is < pdos.size(); ++is)
        {
            pdos[is].create(6 * npol, 2);
            for (int w = 0; w < 6 * npol; ++w)
            {
                pdos[is](w, 0) = 10 * is + w + 1;
                pdos[is](w, 1) = -1e-8;
            }
        }
        return ModuleIO::write_pdos_hdf5(cell, pdos, nspin, -1.5, 0.25, dir, istep, mode);
    }
};

template <typename T>
std::vector<T> read(H5::Group& group, const char* name, const H5::DataType& type)
{
    auto dataset = group.openDataSet(name);
    std::vector<T> data(dataset.getSpace().getSimpleExtentNpoints());
    dataset.read(data.data(), type);
    return data;
}

TEST_F(WritePdosHdf5, MixedSpeciesZetasAndSpinChannels)
{
    const std::string path = write(2, -1, 0);
    H5::H5File file(path, H5F_ACC_RDONLY);
    auto record = file.openGroup("records/1");
    const auto space = record.openDataSet("pdos").getSpace();
    ASSERT_EQ(space.getSimpleExtentNdims(), 3);
    hsize_t shape[3];
    space.getSimpleExtentDims(shape);
    EXPECT_EQ(shape[0], 2u);
    EXPECT_EQ(shape[1], 5u);
    EXPECT_EQ(shape[2], 2u);
    EXPECT_EQ(read<int>(record, "atom_offsets", H5::PredType::NATIVE_INT), (std::vector<int>{0, 1, 5}));
    EXPECT_EQ(read<int>(record, "l", H5::PredType::NATIVE_INT), (std::vector<int>{0, 0, 1, 1, 1}));
    EXPECT_EQ(read<int>(record, "m", H5::PredType::NATIVE_INT), (std::vector<int>{0, 0, 0, 1, -1}));
    EXPECT_EQ(read<double>(record, "energy_eV", H5::PredType::NATIVE_DOUBLE), (std::vector<double>{-1.5, -1.25}));
    EXPECT_EQ(read<double>(record, "pdos", H5::PredType::NATIVE_DOUBLE),
              (std::vector<double>{1, 0, 5, 0, 4, 0, 5, 0, 6, 0, 11, 0, 25, 0, 14, 0, 15, 0, 16, 0}));
}

TEST_F(WritePdosHdf5, SpinorPairsUseEachAtomsBasisOffset)
{
    const std::string path = write(4, 2, 2);
    EXPECT_EQ(path, dir + "pdosg3.h5");
    H5::H5File file(path, H5F_ACC_RDONLY);
    auto record = file.openGroup("records/1");
    int nspin = 0;
    record.openAttribute("nspin").read(H5::PredType::NATIVE_INT, &nspin);
    EXPECT_EQ(nspin, 4);
    EXPECT_EQ(read<double>(record, "pdos", H5::PredType::NATIVE_DOUBLE),
              (std::vector<double>{3, 0, 18, 0, 15, 0, 19, 0, 23, 0}));
}

TEST_F(WritePdosHdf5, AppendsCompleteRecordsAndTruncatesOnFirstStep)
{
    const std::string path = write(1, 2, 1); // first output can occur after step one
    {
        H5::H5File file(path, H5F_ACC_RDWR);
        file.createGroup("_pending"); // interrupted before publication
    }
    write(2, 4, 1);
    {
        H5::H5File file(path, H5F_ACC_RDONLY);
        EXPECT_EQ(file.openGroup("records").getNumObjs(), 2u);
        EXPECT_FALSE(file.nameExists("_pending"));
        int step = 0;
        file.openGroup("records/2").openAttribute("ionic_step").read(H5::PredType::NATIVE_INT, &step);
        EXPECT_EQ(step, 5);
    }
    write(1, 0, 1);
    {
        H5::H5File file(path, H5F_ACC_RDONLY);
        EXPECT_EQ(file.openGroup("records").getNumObjs(), 1u);
        int step = 0;
        file.openGroup("records/1").openAttribute("ionic_step").read(H5::PredType::NATIVE_INT, &step);
        EXPECT_EQ(step, 1);
    }
    write(1, 3, 0);
    H5::H5File file(path, H5F_ACC_RDONLY);
    EXPECT_EQ(file.openGroup("records").getNumObjs(), 1u);
    int step = 0;
    file.openGroup("records/1").openAttribute("ionic_step").read(H5::PredType::NATIVE_INT, &step);
    EXPECT_EQ(step, 4);
}

TEST_F(WritePdosHdf5, RejectsIncompatibleAppendWithoutReplacingExistingData)
{
    const std::string path = write(1, 0, 1);
    {
        H5::H5File file(path, H5F_ACC_RDWR);
        const int future_version = 2;
        file.openAttribute("schema_version").write(H5::PredType::NATIVE_INT, &future_version);
    }
    EXPECT_THROW(write(1, 1, 1), std::runtime_error);
    H5::H5File file(path, H5F_ACC_RDONLY);
    EXPECT_EQ(file.openGroup("records").getNumObjs(), 1u);
    EXPECT_FALSE(file.nameExists("_pending"));
    auto record = file.openGroup("records/1");
    EXPECT_EQ(read<double>(record, "pdos", H5::PredType::NATIVE_DOUBLE),
              (std::vector<double>{1, 0, 5, 0, 4, 0, 5, 0, 6, 0}));
}
}
