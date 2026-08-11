#ifndef AVAILABILITY_VALIDATOR_H
#define AVAILABILITY_VALIDATOR_H

#include "source_io/module_parameter/availability.h"

#include <map>
#include <string>

namespace ModuleIO
{

enum class AvailabilityValueKind
{
    Unknown,
    Boolean,
    Integer,
    Real,
    String,
    BooleanVector,
    IntegerVector,
    RealVector,
    StringVector
};

/// Convert the documentation type of an Input_Item into the type information
/// needed to validate availability operators and literals.
AvailabilityValueKind availability_value_kind(const std::string& type);

/// Validate references, operators and literal values in one availability AST.
/// Throws std::invalid_argument when metadata cannot be evaluated safely.
void validate_availability_expr(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityValueKind>& parameter_types);

/// Validate that every referenced parameter in \p expression carries its own
/// enclosing requirements (its "prerequisites") as equality conditions that hold
/// on the path where the parameter is referenced. \p expressions maps every
/// parameter label to its availability AST. Throws std::invalid_argument when a
/// referenced parameter's prerequisites are missing from its referencing path.
void validate_availability_self_contained(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityExpr>& expressions);

} // namespace ModuleIO

#endif // AVAILABILITY_VALIDATOR_H
