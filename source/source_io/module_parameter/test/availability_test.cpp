/// Unit tests for the INPUT availability parser and metadata validator.
#include "source_io/module_parameter/availability.h"
#include "source_io/module_parameter/availability_validator.h"
#include "source_io/module_parameter/input_item.h"

#include "gtest/gtest.h"

#include <map>
#include <stdexcept>

namespace ModuleIO
{

TEST(AvailabilityParser, LeafEqualityRoundTrip)
{
    const AvailabilityExpr e = parse_availability("basis_type==pw");
    EXPECT_TRUE(e.is_leaf());
    EXPECT_EQ(e.condition.param, "basis_type");
    EXPECT_EQ(e.condition.op, "==");
    EXPECT_EQ(e.condition.values, (std::vector<std::string>{"pw"}));
    EXPECT_EQ(e.to_string(), "basis_type==pw");
}

TEST(AvailabilityParser, SlashRemainsPartOfSingleEqualityValue)
{
    const AvailabilityExpr e = parse_availability("basis_type==pw/lcao");
    ASSERT_EQ(e.condition.values.size(), 1u);
    EXPECT_EQ(e.condition.values[0], "pw/lcao");
    EXPECT_EQ(e.to_string(), "basis_type==pw/lcao");
}

TEST(AvailabilityParser, InListRoundTrip)
{
    const AvailabilityExpr e = parse_availability("vdw_method in [d2, d3_0]");
    EXPECT_TRUE(e.is_leaf());
    EXPECT_EQ(e.condition.op, "in");
    EXPECT_EQ(e.condition.values, (std::vector<std::string>{"d2", "d3_0"}));
    EXPECT_EQ(e.to_string(), "vdw_method in [d2, d3_0]");
}

TEST(AvailabilityParser, ContainsVectorSemantics)
{
    const AvailabilityExpr e = parse_availability("td_ttype contains 2");
    EXPECT_TRUE(e.is_leaf());
    EXPECT_EQ(e.condition.op, "contains");
    EXPECT_EQ(e.condition.values, (std::vector<std::string>{"2"}));
    EXPECT_EQ(e.to_string(), "td_ttype contains 2");
}

TEST(AvailabilityParser, AndGroup)
{
    const AvailabilityExpr e = parse_availability("basis_type==lcao and esolver_type==tddft");
    EXPECT_FALSE(e.is_leaf());
    EXPECT_EQ(e.op, "and");
    ASSERT_EQ(e.children.size(), 2u);
    EXPECT_EQ(e.to_string(), "basis_type==lcao and esolver_type==tddft");
}

TEST(AvailabilityParser, ParenthesisedOrNesting)
{
    const AvailabilityExpr e = parse_availability(
        "symmetry==1 and (dft_functional in [hse, hf] or rpa==true)");
    EXPECT_FALSE(e.is_leaf());
    EXPECT_EQ(e.op, "and");
    ASSERT_EQ(e.children.size(), 2u);
    EXPECT_EQ(e.to_string(),
              "symmetry==1 and (dft_functional in [hse, hf] or rpa==true)");
}

TEST(AvailabilityParser, EmptyIsAlwaysAvailable)
{
    const AvailabilityExpr e = parse_availability("");
    EXPECT_TRUE(e.is_leaf());
    EXPECT_TRUE(e.condition.param.empty());
}

TEST(AvailabilityParser, InvalidExpressionsAreRejected)
{
    const char* invalid_expressions[] = {
        "Only used for plane wave basis.",
        "   ",
        "and",
        " or",
        "basis_type==pw or",
        "a and",
        " and basis_type==pw",
        "basis_type==lcao and esolver_type==tddft or ",
        "basis_type==pw==lcao",
        "basis_type==pw)",
        "(basis_type==pw",
    };
    for (const char* expression : invalid_expressions)
    {
        EXPECT_THROW(parse_availability(expression), std::invalid_argument) << expression;
    }
}

TEST(AvailabilityParser, SetterRequiresCanonicalInputAndPreservesStateOnFailure)
{
    Input_Item item("example");
    item.set_availability("basis_type==pw");
    EXPECT_EQ(item.get_availability(), "basis_type==pw");

    EXPECT_THROW(item.set_availability("basis_type == pw"), std::invalid_argument);
    EXPECT_THROW(item.set_availability("basis_type==pw and"), std::invalid_argument);
    EXPECT_EQ(item.get_availability(), "basis_type==pw");
}

TEST(AvailabilityValidator, AcceptsKnownTypedReferences)
{
    const std::map<std::string, AvailabilityValueKind> types = {
        {"basis_type", AvailabilityValueKind::String},
        {"mixing_restart", AvailabilityValueKind::Real},
        {"td_ttype", AvailabilityValueKind::IntegerVector},
        {"relax_method", AvailabilityValueKind::StringVector},
    };
    EXPECT_NO_THROW(validate_availability_expr(
        "example",
        parse_availability("basis_type==pw and mixing_restart>0"),
        types));
    EXPECT_NO_THROW(validate_availability_expr(
        "example", parse_availability("td_ttype contains 2"), types));
    EXPECT_NO_THROW(validate_availability_expr(
        "example", parse_availability("relax_method in [cg 2]"), types));
}

TEST(AvailabilityValidator, InfersDocumentedTypes)
{
    EXPECT_EQ(availability_value_kind("Vector of string"),
              AvailabilityValueKind::StringVector);
    EXPECT_EQ(availability_value_kind("Integer \\[Integer\\](optional)"),
              AvailabilityValueKind::IntegerVector);
    EXPECT_EQ(availability_value_kind("Float"), AvailabilityValueKind::Real);
    EXPECT_EQ(availability_value_kind("Integer or string"), AvailabilityValueKind::Unknown);
}

TEST(AvailabilityValidator, RejectsUnknownAndIncompatibleReferences)
{
    const std::map<std::string, AvailabilityValueKind> types = {
        {"basis_type", AvailabilityValueKind::String},
        {"mixing_restart", AvailabilityValueKind::Real},
    };
    EXPECT_THROW(validate_availability_expr(
                     "example", parse_availability("missing==1"), types),
                 std::invalid_argument);
    EXPECT_THROW(validate_availability_expr(
                     "example", parse_availability("basis_type contains pw"), types),
                 std::invalid_argument);
    EXPECT_THROW(validate_availability_expr(
                     "example", parse_availability("basis_type>0"), types),
                 std::invalid_argument);
    EXPECT_THROW(validate_availability_expr(
                     "example", parse_availability("mixing_restart>none"), types),
                 std::invalid_argument);
}

TEST(AvailabilityValidator, AcceptsDependenciesOfDependencies)
{
    std::map<std::string, AvailabilityExpr> expressions;
    expressions["esolver_type"] = parse_availability("");
    expressions["basis_type"] = parse_availability("");
    expressions["out_dos"] = parse_availability("");
    expressions["method_sto"] = parse_availability("esolver_type==sdft");
    expressions["cal_cond"] = parse_availability("basis_type==pw");
    // Each referenced parameter carries its own enclosing requirement, both
    // directly (method_sto -> esolver_type==sdft) and transitively
    // (cal_cond -> basis_type==pw) along its own path.
    expressions["npart_sto"] = parse_availability(
        "esolver_type==sdft and ((method_sto==2 and out_dos==1) or (basis_type==pw and cal_cond==true))");
    EXPECT_NO_THROW(validate_availability_self_contained(
        "npart_sto", expressions["npart_sto"], expressions));

    // A requirement present only on a different OR branch does not satisfy the
    // referencing path.
    expressions["broken"] = parse_availability(
        "(method_sto==2 and out_dos==1) or (esolver_type==sdft and cal_cond==true)");
    EXPECT_THROW(validate_availability_self_contained(
                     "broken", expressions["broken"], expressions),
                 std::invalid_argument);
}

TEST(AvailabilityValidator, RejectsMissingTransitiveRequirement)
{
    std::map<std::string, AvailabilityExpr> expressions;
    expressions["esolver_type"] = parse_availability("");
    expressions["out_dos"] = parse_availability("");
    expressions["method_sto"] = parse_availability("esolver_type==sdft");
    expressions["npart_sto"] = parse_availability("method_sto==2 and out_dos==1");
    EXPECT_THROW(validate_availability_self_contained(
                     "npart_sto", expressions["npart_sto"], expressions),
                 std::invalid_argument);
}

} // namespace ModuleIO
