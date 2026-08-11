#include "source_io/module_parameter/availability_validator.h"

#include <cerrno>
#include <cstdlib>
#include <stdexcept>
#include <set>
#include <utility>

namespace ModuleIO
{
namespace
{

bool starts_with(const std::string& value, const std::string& prefix)
{
    return value.compare(0, prefix.size(), prefix) == 0;
}

bool is_vector(const AvailabilityValueKind kind)
{
    return kind == AvailabilityValueKind::BooleanVector
           || kind == AvailabilityValueKind::IntegerVector
           || kind == AvailabilityValueKind::RealVector
           || kind == AvailabilityValueKind::StringVector;
}

AvailabilityValueKind element_kind(const AvailabilityValueKind kind)
{
    switch (kind)
    {
        case AvailabilityValueKind::BooleanVector:
            return AvailabilityValueKind::Boolean;
        case AvailabilityValueKind::IntegerVector:
            return AvailabilityValueKind::Integer;
        case AvailabilityValueKind::RealVector:
            return AvailabilityValueKind::Real;
        case AvailabilityValueKind::StringVector:
            return AvailabilityValueKind::String;
        default:
            return kind;
    }
}

bool is_integer(const std::string& value)
{
    if (value.empty())
    {
        return false;
    }
    char* end = nullptr;
    errno = 0;
    std::strtol(value.c_str(), &end, 10);
    return errno != ERANGE && end != value.c_str() && *end == '\0';
}

bool is_real(const std::string& value)
{
    if (value.empty())
    {
        return false;
    }
    char* end = nullptr;
    errno = 0;
    std::strtod(value.c_str(), &end);
    return errno != ERANGE && end != value.c_str() && *end == '\0';
}

bool literal_matches(const std::string& value, const AvailabilityValueKind kind)
{
    switch (kind)
    {
        case AvailabilityValueKind::Boolean:
            return value == "true" || value == "false" || value == "0" || value == "1";
        case AvailabilityValueKind::Integer:
            return is_integer(value);
        case AvailabilityValueKind::Real:
            return is_real(value);
        case AvailabilityValueKind::String:
            return !value.empty();
        default:
            return false;
    }
}

void fail(const std::string& owner, const std::string& message)
{
    throw std::invalid_argument("Invalid availability for '" + owner + "': " + message);
}

void validate_condition(
    const std::string& owner,
    const AvailabilityCondition& condition,
    const std::map<std::string, AvailabilityValueKind>& parameter_types)
{
    const auto parameter = parameter_types.find(condition.param);
    if (parameter == parameter_types.end())
    {
        fail(owner, "unknown parameter '" + condition.param + "'");
    }
    if (parameter->second == AvailabilityValueKind::Unknown)
    {
        fail(owner, "parameter '" + condition.param + "' has no machine-readable type");
    }

    const AvailabilityValueKind kind = parameter->second;
    if (condition.op == "contains" && !is_vector(kind))
    {
        fail(owner, "operator 'contains' requires a vector parameter, but '" + condition.param
                        + "' is scalar");
    }
    if ((condition.op == ">" || condition.op == ">=" || condition.op == "<"
         || condition.op == "<=")
        && kind != AvailabilityValueKind::Integer && kind != AvailabilityValueKind::Real)
    {
        fail(owner, "ordered comparison requires a numeric scalar parameter, but '"
                        + condition.param + "' is not one");
    }

    const AvailabilityValueKind literal_kind = element_kind(kind);
    for (const std::string& value : condition.values)
    {
        const bool legacy_string_vector
            = kind == AvailabilityValueKind::StringVector && condition.op == "in";
        if (!legacy_string_vector && !literal_matches(value, literal_kind))
        {
            fail(owner,
                 "value '" + value + "' is incompatible with parameter '" + condition.param
                     + "'");
        }
    }
}

void validate_node(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityValueKind>& parameter_types)
{
    if (expression.is_leaf())
    {
        if (!expression.condition.param.empty())
        {
            validate_condition(owner, expression.condition, parameter_types);
        }
        return;
    }
    for (const AvailabilityExpr& child : expression.children)
    {
        validate_node(owner, child, parameter_types);
    }
}

} // namespace

AvailabilityValueKind availability_value_kind(const std::string& type)
{
    if (starts_with(type, "Vector of Boolean"))
    {
        return AvailabilityValueKind::BooleanVector;
    }
    if (starts_with(type, "Vector of Integer") || starts_with(type, "A number(ntype) of Integers")
        || starts_with(type, "Integer \\[Integer\\]"))
    {
        return AvailabilityValueKind::IntegerVector;
    }
    if (starts_with(type, "Vector of Real"))
    {
        return AvailabilityValueKind::RealVector;
    }
    if (starts_with(type, "Vector of String") || starts_with(type, "Vector of string"))
    {
        return AvailabilityValueKind::StringVector;
    }
    if (type == "Boolean")
    {
        return AvailabilityValueKind::Boolean;
    }
    if (type == "Integer")
    {
        return AvailabilityValueKind::Integer;
    }
    if (type == "Real" || type == "Float")
    {
        return AvailabilityValueKind::Real;
    }
    if (type == "String")
    {
        return AvailabilityValueKind::String;
    }
    return AvailabilityValueKind::Unknown;
}

void validate_availability_expr(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityValueKind>& parameter_types)
{
    validate_node(owner, expression, parameter_types);
}

namespace
{

using EqualitySet = std::set<std::pair<std::string, std::string>>;

/// Collect the equality conditions (`param==value`) that are guaranteed to hold
/// whenever \p expression is true. "and" contributes the union of its children;
/// "or" contributes only the intersection shared by every branch.
EqualitySet guaranteed_equalities(const AvailabilityExpr& expression)
{
    if (expression.is_leaf())
    {
        const AvailabilityCondition& condition = expression.condition;
        if (condition.op == "==" && condition.values.size() == 1)
        {
            return {std::make_pair(condition.param, condition.values[0])};
        }
        return {};
    }
    if (expression.op == "and")
    {
        EqualitySet result;
        for (const AvailabilityExpr& child : expression.children)
        {
            const EqualitySet child_equalities = guaranteed_equalities(child);
            result.insert(child_equalities.begin(), child_equalities.end());
        }
        return result;
    }
    EqualitySet result;
    bool first = true;
    for (const AvailabilityExpr& child : expression.children)
    {
        const EqualitySet child_equalities = guaranteed_equalities(child);
        if (first)
        {
            result = child_equalities;
            first = false;
        }
        else
        {
            EqualitySet intersection;
            for (const auto& equality : result)
            {
                if (child_equalities.count(equality))
                {
                    intersection.insert(equality);
                }
            }
            result = std::move(intersection);
        }
    }
    return result;
}

/// Check every reference against the equality conditions guaranteed on its
/// path (the conjunction that encloses it). A referenced parameter's own
/// guaranteed equalities must be present on that path; transitivity follows
/// because any prerequisite that is included becomes another reference with its
/// own prerequisites checked.
void validate_node_self_contained(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityExpr>& expressions,
    const EqualitySet& path_equalities)
{
    if (expression.is_leaf())
    {
        if (expression.condition.param.empty())
        {
            return;
        }
        const std::string& referenced = expression.condition.param;
        const auto it = expressions.find(referenced);
        if (it != expressions.end())
        {
            const EqualitySet prerequisites = guaranteed_equalities(it->second);
            for (const auto& prerequisite : prerequisites)
            {
                if (!path_equalities.count(prerequisite))
                {
                    fail(owner,
                         "references '" + referenced + "', whose availability requires '"
                             + prerequisite.first + "==" + prerequisite.second
                             + "'; include it in the same conjunction");
                }
            }
        }
        return;
    }

    EqualitySet inherited = path_equalities;
    if (expression.op != "or")
    {
        // "and": equalities guaranteed by the whole group hold on every child path.
        const EqualitySet group_equalities = guaranteed_equalities(expression);
        inherited.insert(group_equalities.begin(), group_equalities.end());
    }
    for (const AvailabilityExpr& child : expression.children)
    {
        validate_node_self_contained(owner, child, expressions, inherited);
    }
}

} // namespace

void validate_availability_self_contained(
    const std::string& owner,
    const AvailabilityExpr& expression,
    const std::map<std::string, AvailabilityExpr>& expressions)
{
    validate_node_self_contained(owner, expression, expressions, EqualitySet{});
}

} // namespace ModuleIO
