#include "source_hsolver/kernels/cuda/diag_cusolver.cuh"

#include <gtest/gtest.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <complex>
#include <iostream>
#include <limits>
#include <vector>

namespace
{
class CusolverDensityTest : public testing::Test
{
  protected:
    void SetUp() override
    {
        int devices = 0;
        const cudaError_t result = cudaGetDeviceCount(&devices);
        if (result != cudaSuccess || devices == 0)
        {
            GTEST_SKIP() << "A CUDA device is required";
        }
    }
};

// Only the upper triangle is valid input, including a non-diagonal SPD S.
void matrices(const int n, std::vector<double>& h, std::vector<double>& s)
{
    const std::size_t count = static_cast<std::size_t>(n) * n;
    const double invalid = std::numeric_limits<double>::quiet_NaN();
    h.assign(count, invalid);
    s.assign(count, invalid);
    for (int col = 0; col < n; ++col)
    {
        for (int row = 0; row <= col; ++row)
        {
            const int index = row + col * n;
            h[index] = row == col ? 0.5 + row * 0.13 : 0.02 / (col - row);
            s[index] = row == col ? 1.2 + row * 0.01 : 0.01 / (col - row);
        }
    }
}

void check_density(Diag_Cusolver_gvd& solver, const int n, const int bands, const bool subset)
{
    std::vector<double> h;
    std::vector<double> s;
    matrices(n, h, s);
    const std::size_t vector_count = static_cast<std::size_t>(n) * bands;
    const std::size_t matrix_count = static_cast<std::size_t>(n) * n;
    std::vector<double> eigenvalues(bands);
    std::vector<double> eigenvectors(vector_count);
    if (subset)
    {
        ASSERT_TRUE(solver.solve_subset(n, bands, h.data(), s.data(), eigenvalues.data(), eigenvectors.data()));
    }
    else
    {
        solver.solve_full(n, bands, h.data(), s.data(), eigenvalues.data(), eigenvectors.data());
    }
    const std::vector<double> reference_vectors = eigenvectors;
    // The DM must use the retained device result, not the host output.
    std::fill(eigenvectors.begin(), eigenvectors.end(), 0.0);
    std::vector<double> weights(bands);
    std::vector<double> density(matrix_count);
    for (int repeat = 0; repeat < 2; ++repeat)
    {
        for (int band = 0; band < bands; ++band)
        {
            const double magnitude = 1.7 / (band + repeat + 1);
            weights[band] = band % 3 == 0 ? 0.0 : magnitude;
            if (repeat == 1 && band % 3 == 2)
            {
                weights[band] = -weights[band];
            }
        }
        ASSERT_TRUE(solver.density_matrix(weights.data(), density.data()));
        double max_error = 0.0;
        double trace = 0.0;
        double electrons = 0.0;
        for (int band = 0; band < bands; ++band)
        {
            electrons += weights[band];
        }
        for (int col = 0; col < n; ++col)
        {
            for (int row = 0; row < n; ++row)
            {
                double reference = 0.0;
                for (int band = 0; band < bands; ++band)
                {
                    reference += weights[band] * reference_vectors[row + band * n]
                                 * reference_vectors[col + band * n];
                }
                const int index = row + col * n;
                const double error = std::abs(density[index] - reference);
                max_error = std::max(max_error, error);
                EXPECT_NEAR(density[index], reference, 2.0e-12);
                const int upper = std::min(row, col) + std::max(row, col) * n;
                trace += density[index] * s[upper];
            }
        }
        EXPECT_NEAR(trace, electrons, 2.0e-12);
        const double trace_error = std::abs(trace - electrons);
        std::cout << "n=" << n << " bands=" << bands << " subset=" << subset
                  << " max_dm_error=" << max_error << " trace_error=" << trace_error << '\n';
    }
}
} // namespace

TEST_F(CusolverDensityTest, UnavailableResult)
{
    Diag_Cusolver_gvd solver;
    const double weight = 1.0;
    double density = -1.0;
    EXPECT_FALSE(solver.density_matrix(&weight, &density));
    EXPECT_DOUBLE_EQ(density, -1.0);
}

TEST_F(CusolverDensityTest, FullWithFractionalAndSignedWeights)
{
    Diag_Cusolver_gvd solver;
    check_density(solver, 11, 7, false);
    check_density(solver, 67, 17, false);
}

TEST_F(CusolverDensityTest, RepeatedSolveReplacesRetainedVectors)
{
    Diag_Cusolver_gvd solver;
    check_density(solver, 67, 17, false);
    check_density(solver, 11, 11, false);
}

#if CUDART_VERSION >= 10010
TEST_F(CusolverDensityTest, SubsetWithFractionalAndSignedWeights)
{
    Diag_Cusolver_gvd solver;
    check_density(solver, 11, 3, true);
    check_density(solver, 67, 17, true);
    check_density(solver, 11, 7, false);
}
#endif

TEST_F(CusolverDensityTest, ComplexSolveClearsRealResult)
{
    Diag_Cusolver_gvd solver;
    check_density(solver, 11, 7, false);
    const std::complex<double> h = 2.0;
    const std::complex<double> s = 1.0;
    std::complex<double> vector;
    double eigenvalue = 0.0;
    solver.solve_full(1, 1, &h, &s, &eigenvalue, &vector);
    const double weight = 1.0;
    double density = -1.0;
    EXPECT_FALSE(solver.density_matrix(&weight, &density));
    EXPECT_DOUBLE_EQ(density, -1.0);
}
