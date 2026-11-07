# Proposal: shared INPUT default resolution

Status: design draft. The interfaces and schema below are proposed, not
implemented. Runtime behavior is unchanged by this document.

Issue [#7719](https://github.com/deepmodeling/abacus-develop/issues/7719)
requires omitted parameters to receive useful contextual defaults, explicit
legal requests to survive, and invalid requests to fail with an explanation
and the parameter manual link. Shared value/dependency validation from
[#8192](https://github.com/deepmodeling/abacus-develop/pull/8192) checks legality;
it does not prevent an old reset from replacing one legal value with another.

The proposed endpoint is one default-resolution mechanism for **every INPUT
registration**, including constants, conditional defaults, formulas, vectors
and defaults that need structure or build context. Registrations describe the
rules. The engine owns presence, precedence, dependency ordering, assignment
and diagnostics, without branching on parameter names. Adding `is_read()`
guards to individual callbacks is not the
completion criterion.

## Current sources and migration boundary

The [inventory](input_defaults_inventory.md) covers all 634 registrations at
`27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0`. There are 626 registrations with
documentation type metadata, 96 reset callbacks, and 113 registrations using
vector synchronization helpers that can resize on the reading rank. These
counts overlap; neither callbacks nor resize calls are themselves bug counts.

Today the default can come from an `Input_para`/`MD_para` initializer, an
unstructured `default_value` string, a reader/reset callback, a broadcast
helper, or a later scientific module. Some callbacks also enforce constraints,
convert units, implement aliases, or update internal calculation state. These
operations must be assigned their proper contracts during migration.

The existing [availability](input_availability.md) grammar and
[value/dependency contracts](input_validation.md) remain distinct:

| Declaration | Question it answers | Runtime action |
| --- | --- | --- |
| Availability | When does this parameter apply? | Describe applicability; no implicit rejection or overwrite |
| Value/domain and requirements | Is this supplied/resolved request legal? | Accept or report a diagnostic |
| Default | What value is used when this parameter was omitted? | Resolve only an omitted target |
| Public automatic option | What does a documented explicit `auto`, `0`, or other selector request? | Resolve that documented mode while retaining its origin |
| Alias/unit representation | Do two spellings represent the same request? | Normalize once; reject conflicting supplied requests |

A default formula is not a required equality. For example, a default
`mixing_restart=sc_scf_thr` does not make a different explicit restart
threshold invalid. Conversely, defaulting `cal_force` to true for relaxation
does not excuse an explicitly incompatible false value: the requirement must
reject it. A default must never repair an invalid request.

## One definition for execution and documentation

Keep the C++ registration as the source of truth, as for availability.
Store a typed declaration/AST, export its schema to generated YAML, and render
the same rules in CLI help and the manual. The program does not fetch or parse
the online manual. A handwritten prose default and an unrelated C++ assignment
must not remain two authoritative definitions after migration.

Proposed exported form, using the intended DeltaSpin omission behavior:

```yaml
name: mixing_restart
default:
  cases:
    - when: sc_mag_switch==false
      value: 0.0
    - when: sc_mag_switch==true and sc_scf_thr!=10
      expr: sc_scf_thr
    - when: sc_mag_switch==true and sc_scf_thr==10
      expr: scf_thr/10
```

Omission is an engine precondition, so registrations do not repeat it.
Each branch supplies exactly one of `value`, `expr`, or a named `provider`.
Literal strings are typed values, not expressions. The public type controls
conversion; integer division/truncation must not silently implement a real
formula. Units belong to the declaration and are checked at provider/binding
boundaries. Initially, arithmetic supports references, constants, `+ - * /`,
parentheses and a small specified set of numeric functions such as `min` and
`max`; arbitrary C++ or script evaluation is not part of the schema.

Conditions reuse availability's Boolean/comparison syntax and typed checks.
Default conditions additionally need a presence predicate, proposed as
`supplied(name)`. This predicate is not part of today's availability grammar;
it is an explicit extension for default selection. It observes original input
presence, not whether a dependency happened to be resolved earlier.

Branches must be mutually exclusive for a resolved configuration. More than
one match is a declaration error, not "last assignment wins". `otherwise` is
an explicit fallback used only after all applicable conditions are known to
be false. Missing references and type errors fail registration checks;
ambiguous matches and unresolved cases also fail at runtime. Structural
checks and tests must not claim to prove arbitrary predicates disjoint.

Every registration declares what omission means: a constant, conditional rule,
context provider, or required/no-value contract. Public automatic selectors
are a separate declaration: for example, an omitted `diago_proc` can default
to `0`, while explicitly supplying `0` requests the same automatic mode with
a different origin. Empty strings/vectors can be real typed defaults. "No
default" does not mean numerical zero, and an inactive parameter need not
acquire a fake valid value just to satisfy a universal completion check.

## Presence and ownership

The parser records presence when it recognizes a keyword, independently of
its token count. An explicit empty value must be checked against that
parameter's grammar; it must not become an omission because
`str_values.empty()` is true. Explicit `0`, `false`, a legal negative value,
and a value numerically equal to the default all retain explicit origin.

Parsing produces per-keyword typed requests before committing to shared
storage. Aliases and alternate units retain both requests until agreement or
conflict has been determined. This is necessary because the current
`smearing_sigma_temp` reader can overwrite `smearing_sigma` before the existing
explicit-value snapshot is taken.

The preparation state keeps three properties separate from numeric storage:
origin (omitted or explicitly supplied), request kind (literal or documented
automatic mode), and readiness (pending dependencies/context or resolved).
Resolving a value does not erase its origin. Runtime numeric fields stay
numeric. Existing initialization sentinels need not all become null, but their
numeric value no longer decides whether the user supplied an input. A code initializer alone
never licenses a public automatic option.

The resolver computes typed results and commits through bindings for the
declared targets. A default provider gets read-only declared dependencies and
returns a value; it does not receive unrestricted mutable `Parameter&` or
write another parameter. Scientific providers may implement algorithms, but
cannot redefine precedence or secretly read undeclared globals. This removes
the failure mode of one reset modifying several explicit inputs.

Resolved configuration is read-only to consumers. Mutable iteration state,
such as an adaptive convergence threshold, belongs to execution state rather
than the original user request. Existing read-only `Parameter` accessors are a
useful boundary, but the remaining writer/friend and alias paths must also be
audited before claiming global protection.

## Dependency resolution

Defaults are evaluated from selected dependencies, including references in
conditions. Explicit literal requests form fixed roots; documented automatic
requests use their declared resolution rules. For an omitted target, determine
its branch, resolve the referenced values, evaluate the result, and validate
it. Memoization/readiness tracking makes declaration order irrelevant. Cycle
diagnostics report the dependency path. Division by zero, nonfinite results,
out-of-range conversions and missing required input are errors.

The cutoff pair demonstrates why an unconditional dependency graph is
insufficient:

```yaml
name: ecutwfc
default:
  cases:
    - when: supplied(ecutrho)
      expr: ecutrho/4
    - when: supplied(ecutrho)==false and basis_type==lcao
      value: 100.0
    - when: supplied(ecutrho)==false and basis_type!=lcao
      value: 50.0
---
name: ecutrho
default:
  expr: 4*ecutwfc
```

| Supplied input | Resolution |
| --- | --- |
| Neither cutoff | Select the basis default for `ecutwfc`, then derive `ecutrho` |
| Only `ecutrho` | Preserve it and derive `ecutwfc` |
| Only `ecutwfc` | Preserve it and derive `ecutrho` |
| Both | Preserve both and apply the actual cutoff requirements |

Only dependencies selected by the branch form evaluation edges. An explicit
target does not evaluate its default dependencies. An unknown/pending condition
must not be treated as false. Short-circuiting may prove a branch irrelevant;
otherwise the resolver waits for the condition's dependencies. A genuine
cycle is rejected rather than iterating resets until values happen to settle.

`md_dt`/`td_dt` needs the same mechanism: a default `md_dt=1 fs` when neither is
supplied, derivation in the appropriate direction when only one is supplied,
and a separately declared consistency check when both are supplied. The
comparison tolerance must follow the physical/unit contract, not a generic
"defaults are equal" assumption.

## Context that becomes available later

A single engine can resume at several readiness boundaries. It cannot compute
all defaults immediately after reading INPUT:

| Context | Examples |
| --- | --- |
| INPUT and build/runtime capabilities | SCF thresholds, solver selection, process-count automatic options |
| Structure metadata | `ntype`, per-type omitted vectors |
| Pseudopotentials and orbitals | electron count, functional selection, automatic band count |

Bootstrap paths needed to read STRU are resolved first. Reading STRU publishes
typed facts to the resolver; it does not start a second default policy. Later
providers use the same origin protection, readiness checks, diagnostics and
documentation contract. Provider dependencies are explicit and their returned
values pass the normal domain checks. A provider identifies its algorithm and
context in the manual when a compact formula is insufficient.

For a documented public selector such as `diago_proc=0`, the original request
remains "automatic" and the effective value is resolved from the process
count. Internal `scf_thr=-1` remains forbidden as explicit input. Public
negative modes such as `md_tlast<0` require an explicit auto-mode declaration;
they must not be inferred from negative storage initializers.

```text
Requests --> Alias/domain checks --> Shared resolver --> Ready checks
                                          ^                  |
                                          |                  v
                                   Available context   Configuration
```

Rank zero resolves metadata/defaults; errors are broadcast before collective
value transfers. Broadcast helpers copy resolved values. They may allocate
receiving storage, but must not supply, truncate or pad the root's explicit
request. Rank-local operational state is derived separately from the shared
configuration. `--check-input` uses the same available boundaries and clearly
reports any context it cannot evaluate; it must not silently certify pending
late constraints.

## Migration and completion criteria

Use one implementation workstream and one coverage ledger. Ordinary commits
can build and verify the engine, migrate registrations, then remove legacy
paths; these are implementation steps towards the same global contract, not
independent parameter-specific default mechanisms.

1. Introduce typed requests, origin/readiness, default expressions, bindings,
   providers and schema export. Add an engine test matrix independent of ABACUS
   parameter names.
2. Account for every row in the inventory. Move constants and conditional
   defaults into the common declarations. Separate mixed callbacks into
   default rules, constraints, representation conversion and runtime state.
   Resolve the eight registrations missing public metadata explicitly.
3. Replace contextual default writes in readers, resets, vector broadcasts and
   later initialization with the shared resolver. Wire all context providers;
   preserve documented automatic selectors and deliberate shorthand.
4. Generate help/manual defaults from those declarations. Remove duplicate
   handwritten authoritative defaults and the old default-writing paths.
5. Require complete registration coverage and no undeclared default writers
   before describing the migration as global. Schema coverage alone does not
   establish the absence of downstream overwrites.

During migration, unconverted paths must be visibly listed. A temporary
adapter that still decides presence or modifies arbitrary parameters is not
an acceptable final resolver. Existing scientific algorithms need not be
rewritten as formulas; their pure providers participate in the same mechanism.

Safe C++ object initialization may remain, including internal sentinels, but
must not be a second semantic default source. Code/tests that construct
`Input_para` and consume fields without preparation must be inventoried.
Any retained semantic constant must have one owned definition shared by the
initializer and schema, rather than two separately maintained values.

### Required evidence before runtime migration is ready

- Permuting registration order and INPUT line order gives the same results.
  Explicit values equal to defaults, explicit zero/false/negative values,
  omitted values, empty custom grammars and public automatic requests retain
  their distinct meaning.
- Defaults chain across conditions and formulas, including selected-edge
  cutoff and timestep dependencies. Tests detect real cycles, overlapping
  cases, missing references, division by zero and numeric conversion errors.
- Invalid explicit input fails before any repair; invalid generated defaults
  fail as implementation/declaration errors. Both identify the parameter,
  relevant rule and manual link. MPI ranks leave consistently without hanging.
- Complete explicit vectors survive unchanged; omitted vectors resolve only
  after their size dependencies are ready. Public repeat/single-value
  shorthand is preserved; silent excess-value truncation is rejected.
- Unit aliases are parsed independently and contradictions are rejected
  independent of input order. Value equivalence follows a documented unit
  policy rather than string equality.
- The full registration ledger has a reviewed disposition and tests for every
  default-rule branch/provider family. Generated help/YAML/manual match the
  executable schema and retain readable wrapping and links.
- Re-reading ABACUS-generated INPUT gives an equivalent configuration.
  Diagnostics/default provenance are kept separate from the restartable
  INPUT: inactive values and internal sentinels must not become user requests.
- Representative PW/LCAO, relaxation, MD/TDDFT, hybrid, structure-dependent and
  serial/MPI cases retain their intended numerical behavior. Hardware/build
  paths not tested remain explicit validation gaps, not claimed coverage.

The principal compatibility changes are intentional rejection of previously
repaired input and removal of accidental registration-order effects.
Conditional defaults, documented automatic options, unit conversion and
scientific adaptation remain supported with explicit contracts. Existing
uncertain physical constraints require review; the migration must not turn a
recommended default into a newly invented legal bound.
