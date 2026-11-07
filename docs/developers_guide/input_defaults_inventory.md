# Default-resolution inventory

This is a source census for the [shared-default proposal](input_defaults.md), not
an executable default schema. It records current behavior and review destinations;
it does not declare every storage initializer to be a legal public default.

Baseline: `27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0`. The INPUT parameter module is unchanged from the
2026-11-07 issue #7719 audit baseline `3ded45144e3d2584fdf11fc2f16bcdb5b05a7171`.

## Complete registration census

[The CSV ledger](input_defaults_inventory.csv) has one row for each of the 634
registered keywords, with documentation type/default, primary storage field and
initializer, registration/initializer locations, reset/reader/resize markers,
and a review route. 620 primary fields were traced through sync registrations;
the remaining 14 were checked in custom readers. A primary field is not a list
of every field that a callback can write. In particular, alias and multi-target
callbacks still require the decomposition described below.

An initializer is a starting storage value, not necessarily the resolved default.
A row without reset is not proof that later code never changes that parameter.
The 113 resize markers are existing vector synchronization helpers, not 113
confirmed bugs. Custom readers and helper calls overlap these counts.

| Registration file | Keywords | Reset callbacks | Vector sync/resize registrations |
| --- | ---: | ---: | ---: |
| `read_inp_bse.cpp` | 17 | 2 | 3 |
| `read_inp_deepks.cpp` | 16 | 3 | 1 |
| `read_inp_dfpt.cpp` | 12 | 0 | 1 |
| `read_inp_estruc.cpp` | 65 | 16 | 3 |
| `read_inp_exx_dftu.cpp` | 44 | 12 | 6 |
| `read_inp_model.cpp` | 38 | 6 | 0 |
| `read_inp_ofdft.cpp` | 49 | 5 | 17 |
| `read_inp_other.cpp` | 62 | 3 | 3 |
| `read_inp_out.cpp` | 73 | 14 | 38 |
| `read_inp_postproc.cpp` | 29 | 1 | 2 |
| `read_inp_relax.cpp` | 20 | 2 | 0 |
| `read_inp_sccs.cpp` | 22 | 0 | 1 |
| `read_inp_sys.cpp` | 53 | 19 | 3 |
| `read_inp_tddft.cpp` | 77 | 4 | 29 |
| `read_input_item_md.cpp` | 48 | 9 | 6 |
| `read_input_item_sdft.cpp` | 9 | 0 | 0 |

Eight registered keywords have no documentation type metadata: `out_unshrinked_v`, `exx_coul_moment`, `exx_rotate_abfs`, `exx_multip_moments_threshold`, `shrink_abfs_pca_thr`, `shrink_lu_inv_thr`, `cond_mgga_vel`, `relax`.
Their visibility and contract must be decided; they cannot silently disappear
from the completion ledger because the current manual generator omits them.

## All 96 reset callbacks

The proposed destination splits callbacks where necessary. This table is a
migration decision list, not a claim that the listed change is implemented.
Physical limits and conflicting preset behavior need reviewed rules before
they can replace legacy repairs.

| Callback | Destination | Migration note |
| --- | --- | --- |
| [bse_spin_types](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_bse.cpp#L23) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [bse_mem_save](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_bse.cpp#L44) | Multi-target preset | Distribute default proposals to declared targets; explicit conflict policy requires a contract. |
| [deepks_equiv](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_deepks.cpp#L84) | Validation only | Keep as validation/capability checking, outside default resolution. |
| [bessel_descriptor_ecut](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_deepks.cpp#L128) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [deepks_out_unittest](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_deepks.cpp#L277) | Multi-target preset | Distribute default proposals to declared targets; explicit conflict policy requires a contract. |
| [basis_type](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L14) | Mode-dependent remapping | Audit the original request and effective representation before choosing a default or a rejection. |
| [ks_solver](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L39) | Mode-dependent remapping | Includes build/device-dependent defaults and a towannier90 remapping; these are distinct contracts. |
| [nupdown](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L247) | Derived execution state | Keep derived internal state separate from the requested INPUT configuration. |
| [gga_grad](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L443) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [mixing_beta](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L538) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [mixing_beta_mag](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L576) | Default declaration | The callback also sets mixing_gg0_mag. Each target needs its own declared rule and origin guard. |
| [mixing_restart](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L623) | Default declaration | DeltaSpin currently overwrites explicit thresholds and may consume unresolved scf_thr=-1. Both require the common precedence/order rules. |
| [gamma_only](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L745) | Representation / workflow | Preserve the accepted PW Gamma-grid convenience semantics, including KPT generation. |
| [scf_nmax](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L786) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [scf_thr](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L803) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [scf_thr_type](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L848) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [scf_os_ndim](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L902) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [pw_diag_thr](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L1002) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [lcao_ecut](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L1105) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [bx](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L1167) | Mode-dependent remapping | Audit the original request and effective representation before choosing a default or a rejection. |
| [bessel_nao_ecut](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_estruc.cpp#L1234) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_fock_alpha](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L14) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_erfc_alpha](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L62) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_erfc_omega](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L111) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_separate_loop](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L163) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [exx_fock_lambda](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L216) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_ccp_rmesh_times](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L340) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_real_number](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L442) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [exx_singularity_correction](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L467) | Mode-dependent remapping | Default selection also changes exx_gamma_extra. Separate targets and resolve the public default token explicitly. |
| [exx_symmetry_realspace](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L609) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [dft_plus_u](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L680) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [uramping](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L860) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [onsite_radius](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_exx_dftu.cpp#L926) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [vdw_s6](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L314) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [vdw_s8](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L339) | Empty callback | Remove the no-op callback; determine any later lookup/default at its actual consumer. |
| [vdw_a1](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L364) | Empty callback | Remove the no-op callback; determine any later lookup/default at its actual consumer. |
| [vdw_a2](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L389) | Empty callback | Remove the no-op callback; determine any later lookup/default at its actual consumer. |
| [vdw_cutoff_radius](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L517) | Public mode / sentinel review | Separate a documented automatic request from a private initializer; declare conditional values or a provider. |
| [vdw_cn_thr](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_model.cpp#L642) | Default declaration | Move the omitted-value rule into the shared resolver; retain supplied values. |
| [of_kinetic](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_ofdft.cpp#L14) | Multi-target preset | MPN/CPN5 write many ML fields. The omitted preset and explicit-child conflict policy must be declared for every affected target. |
| [of_hold_rho0](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_ofdft.cpp#L245) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [of_read_kernel](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_ofdft.cpp#L303) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [of_full_pw_dim](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_ofdft.cpp#L352) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [of_ml_nkernel](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_ofdft.cpp#L427) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [qo_strategy](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_other.cpp#L228) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [qo_screening_coeff](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_other.cpp#L275) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [rdmft_power_alpha](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_other.cpp#L797) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_freq_ion](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L14) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_freq_td](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L35) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_freq_elec](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L53) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_chg](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L71) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_pot](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L131) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_dmk](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L237) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_dmr](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L276) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_wfc_lcao](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L341) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_dos](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L374) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_band](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L442) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_proj_band](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L471) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [out_stru](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L494) | Omitted output default | Move omission logic into the engine and retain any necessary derived output state separately. |
| [out_level](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L562) | Omitted output default | out_md_control currently carries input presence. Replace it with shared origin tracking without losing output behavior. |
| [rpa_outdir](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_out.cpp#L1690) | Representation / workflow | Preserve documented representation or convenience semantics; do not treat as an ordinary numerical default. |
| [wannier_method](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_postproc.cpp#L371) | Mode-dependent remapping | Audit the original request and effective representation before choosing a default or a rejection. |
| [relax_nmax](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_relax.cpp#L47) | Constraint plus default | Preserve the documented explicit zero dry-run mode; do not confuse it with omission. |
| [force_thr](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_relax.cpp#L89) | Alias / related quantities | The reset changes both unit representations; keep per-keyword requests before conversion and compare consistent dual input. |
| [symmetry](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L329) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [cal_force](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L422) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [kpar](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L453) | Mode-dependent remapping | LCAO retains the request in kpar_lcao; GPU correction needs separate validation. A field change alone is not loss of intent. |
| [assume_isolated](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L594) | Representation / workflow | Preserve documented representation or convenience semantics; do not treat as an ordinary numerical default. |
| [init_wfc](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L671) | Mode-dependent remapping | Audit the original request and effective representation before choosing a default or a rejection. |
| [init_chg](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L753) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [init_vel](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L797) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [cal_stress](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L836) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [diago_proc](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L861) | Documented automatic mode | The description explicitly defines zero as the total MPI process count. |
| [device](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1012) | Validation only | Keep as validation/capability checking, outside default resolution. |
| [cell_factor](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1124) | Constraint plus default | cell-relax raises every value below 2 to 2. Review the actual legal bound independently of the omitted default. |
| [chg_extrap](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1169) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [ecutwfc](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1203) | Mixed default and internal state | Only supplied ecutrho selects reverse derivation; otherwise use the basis default. Do not create an artificial unconditional cycle. |
| [ecutrho](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1236) | Mixed default and internal state | Depends on ecutwfc and sets internal double_grid; the ratio requirement is separate from the 4* default. |
| [ndx](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1334) | Derived execution state | Keep derived internal state separate from the requested INPUT configuration. |
| [ndy](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1372) | Derived execution state | Keep derived internal state separate from the requested INPUT configuration. |
| [ndz](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1405) | Derived execution state | Keep derived internal state separate from the requested INPUT configuration. |
| [kpoint_file](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1525) | Suspect legacy path | The callback targets stru_file rather than its own field; review/remove the path rather than translate blindly. |
| [read_file_dir](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_sys.cpp#L1584) | Representation / workflow | Preserve documented representation or convenience semantics; do not treat as an ordinary numerical default. |
| [td_dt](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_tddft.cpp#L389) | Alias / related quantities | Coupled with md_dt; both missing needs a root default, one supplied selects a direction, and both supplied needs a consistency check. |
| [td_supsine_tstart](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_tddft.cpp#L958) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [td_supsine_tend](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_tddft.cpp#L984) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [lr_init_xc_kernel](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_inp_tddft.cpp#L1114) | Vector grammar / shape | Declare omitted-vector generation separately from explicit shorthand, shape checks and automatic elements. |
| [md_nstep](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L33) | Invalid-input repair | Omission initializes to 10; explicit 0 is changed to 50. The replacement default must not copy this repair. |
| [md_dt](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L51) | Alias / related quantities | A supplied td_dt currently overwrites md_dt, including an explicit negative value, before its late check. |
| [md_tlast](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L110) | Documented automatic mode | The description explicitly defines negative values as md_tfirst; this public automatic mode differs from private sentinels. |
| [md_prec_level](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L133) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [md_tfreq](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L269) | Default declaration | Default is 1/(40*md_dt); the zero initializer alone does not make explicit zero an automatic option. |
| [ref_cell_factor](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L312) | Validation only | Keep as validation/capability checking, outside default resolution. |
| [md_pcouple](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L347) | Constraint plus default | Separate a useful omitted default from the requirement that must reject an explicit conflict. |
| [md_plast](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L381) | Default declaration | Metadata says -1.0 but the omission callback uses md_pfirst; explicit negative pressure is preserved. |
| [md_pfreq](https://github.com/deepmodeling/abacus-develop/blob/27c3e1065bfe0ca6be2d9b90a93da91bfea1ffe0/source/source_io/module_parameter/read_input_item_md.cpp#L397) | Default declaration | Default is 1/(400*md_dt); the zero initializer alone does not make explicit zero an automatic option. |

## Work outside reset callbacks

| Path or parameter family | Required treatment |
| --- | --- |
| `Input_para`, `MD_para`, `System_para` initializers and consumers | Constants join the same schema. Inventory direct construction/consumption so placeholder initializers cannot bypass preparation. |
| `smearing_sigma` / `smearing_sigma_temp`; `force_thr` / `force_thr_ev` | Parse separate requests before unit conversion; the current smearing reader can destroy the first supplied value before snapshots. |
| `init_occ_mat` / `omc`, H/S output aliases, `out_eband` aliases | Declare canonical identities and conflict checks; retain accepted legacy spelling without silently choosing contradictory requests. |
| Vector broadcast helpers | They currently resize in serial and on rank zero as well. Transfer resolved vectors; move omitted generation into defaults and explicit shape checking ahead of transfer. |
| `orbital_corr`, `hubbard_u`, `exciton_fixed_coordinate` | Reject short/excess explicit lists before resize. Omitted-vector defaults and documented shorthand need separate declarations. |
| `ntype` | Publish the atom-type count after reading STRU; resolve dependent vector defaults after this fact is ready. |
| `nelec`, `nbands`, `dft_functional` | Structure/pseudopotential/orbital providers must retain the existing scientific algorithms while the common engine owns omission and automatic-mode handling. |
| `nx/ny/nz` and related grids | Documented automatic requests and explicit grid consistency need context, not a private zero test standing in for presence. |
| `nbands_sto=all` | Preserve the public complete-basis request; its internal zero representation must not license explicit numerical zero. |
| SCCS model presets | Existing documentation explicitly states preset overrides. Review preset/child precedence as a public contract; do not silently call it an undocumented bug. |
| vdW functional tables; Yukawa screening; build-dependent solvers | Register typed context/lookup providers with named dependencies and a documented resolution rule. No unrestricted mutable reset fallback. |
| EXX `ecutexx` clipping | A later module still clips an explicit request. Handle the physical limit as a constraint, not a default. |
| STRU magnetic moments; KPT weights | Separate input formats also lose explicit intent in some paths. Extend source/presence checking there; an INPUT schema alone cannot claim these are fixed. |
| Iterative updates and derived execution fields | Retain legitimate adaptation, normalized units and symmetry operations as execution state; do not reinterpret them as permission to change the original request. |

## Representative inconsistencies to resolve

| Parameter | Current documented default | Current omission path / concern |
| --- | --- | --- |
| `mixing_restart` | `0` | DeltaSpin derives another value; reset also overwrites explicit input and can read an unresolved SCF sentinel. |
| `scf_thr` | PW `1e-9`; localized basis `1e-7` | PW NSCF actually uses `1e-6`, which is absent from the Default field. |
| `sc_scf_thr`, `sc_drop_thr` | `1e-4`, `1e-2` | Both storage initializers are `1e-3`, with no corresponding reset callback. Resolve the intended constants instead of blindly copying either source. |
| `md_plast` | `-1.0` | Omission takes `md_pfirst`; explicit negative pressure is legal and preserved. |
| `cal_force`, `cal_stress` | `False` | Context enables force/stress for relaxation and selected MD cases; explicit conflicting switches are currently overwritten. |
| `cell_factor` | `1.2` | cell-relax raises it to `2`; the hard lower bound must be assessed separately from the omitted default. |
| `md_nstep` | `10` | Omission gives 10, but explicit zero is silently changed to 50 in non-TDDFT cases. |
| `ecutwfc` / `ecutrho` | Basis constants / `4*ecutwfc` | Either explicit cutoff can determine the omitted partner; branch selection must use presence to avoid an artificial cycle. |

## Review and coverage limits

The earlier audit reproduced reader overwrites with serial `--check-input` and
selected four-rank/real SCF controls. This proposal rechecked source locations
and registration coverage; it does not introduce a runtime implementation or
claim fresh numerical validation of one. GPU, ML, hybrid and other late paths
cannot be certified from a source inventory alone.

The implementation ledger must eventually replace every review route with a
reviewed executable disposition and evidence. Completion requires both schema
coverage and removal of default writers outside the shared mechanism. A
subset of migrated callbacks is not a global default policy.
