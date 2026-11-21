**LibRI GPU 实空间对称性回归溯源（2026-11-21）**

结论：PR16 已合入，原修正确实保留到了此前使用的 `0e8afc393`；后续 Wrapper 重构部分撤回了修正，并混用了两套 GPU 回调参数约定。具体首坏候选是 **[`4ed89410a5a6d7a891015879e8f0be0868af632d`](https://github.com/abacusmodeling/LibRI/commit/4ed89410a5a6d7a891015879e8f0be0868af632d)**，其直接父提交为 `6c6c8711894f6379d47448f71fd718170995d2fe`。这是精确源码差异定位；本次数值端点为旧算法控制组、发布版和局部修补版，未把历史原样二进制二分冒称为已完成。

当前 GitHub `master` 与 `v0.3.0.0` 均为 `a385ac9b1d04c151f26f9d14cc0c2588f96557ab`。发布版迁移测试调用方式后仍失败；局部恢复循环与过滤器契约后完整小型回归通过。所有源码副本、补丁和新日志仅位于本目录及指定远端隔离目录，ABACUS 限制未改动。

**提交演变与 PR16 修正去向**

| 时间（UTC）/提交 | 证据与含义 |
| --- | --- |
| 10-24，PR16 merge [`a0661cb`](https://github.com/abacusmodeling/LibRI/commit/a0661cbb4b4f89ceeb23e040d49accb00943093f) | GitHub 记录 PR16 于 12:39:37 合并，包含 `cdeab575`、`4a41b913`、`11de9ee6` 三个修正及 PR15。修复缺失回调、`a01b01_a2b2` 输出参数顺序、四个 crossed contraction 的中间原子误筛。 |
| 11-09，[`6c6c871`](https://github.com/abacusmodeling/LibRI/commit/6c6c8711894f6379d47448f71fd718170995d2fe) | 从共同父提交 `ab81ac9` 分支，拆分 CPU/GPU 过滤器；GPU 回调改按循环嵌套顺序传参，每次收缩按 `flag_symmetry` 构造过滤器。测试同步使用新 flag/sector API，并检查关闭对称性后的过滤器替换。相关循环仍不筛中间 `Aa2`。 |
| 11-10 03:07，[`0e8afc393`](https://github.com/abacusmodeling/LibRI/commit/0e8afc3931ee4cdf564699811ca220215570dd6b) | 在同一父提交 `ab81ac9` 的另一分支升级 DDLA 公共 API；**尚未包含 `6c6c871`**。GPU 循环、共享对称性过滤器、回归测试三文件与 PR16 merge 逐字节相同。它此前通过测试与当前回归不矛盾。 |
| 11-10 08:04:21，[`4ed8941`](https://github.com/abacusmodeling/LibRI/commit/4ed89410a5a6d7a891015879e8f0be0868af632d) | 加入持有 `cal_mode` 引用的 Wrapper，移除 contraction 内的自动过滤器选择；同时恢复了多个旧回调顺序，重新加入四处 `filter_for2(Aa01,Aa2)`。GPU 过滤器相对父提交仅增加作者注释，仍解释新参数顺序。测试恢复为直接构造 CPU 过滤器，并删除关闭对称性检查，未迁移到 Wrapper。 |
| 11-10 08:04:24，[`0415707`](https://github.com/abacusmodeling/LibRI/commit/0415707188ba17386f7ee6a0eb6b50a16e284b05) | 合并 `4ed8941` 与 `0e8afc393`，将错误带入合并后的历史。GPU 循环、两个新过滤器、Exx 调用、测试均与 `4ed8941` 相同。 |
| 11-20，[`e8cf659`](https://github.com/abacusmodeling/LibRI/commit/e8cf65997137dd6dd29e56934e7e4fc9ed0fa169) | 加入代码生成器；错误的回调顺序及中间筛选也存在于生成器。不是此次错误首次出现的提交。 |
| 11-21，[`8032cad`](https://github.com/abacusmodeling/LibRI/commit/8032cad042a7af1d63738a45956e33d0edbb22c5) → [`a385ac9`](https://github.com/abacusmodeling/LibRI/commit/a385ac9b1d04c151f26f9d14cc0c2588f96557ab) | 前者调整 DDLA 公共计算 API，后者发布 0.3.0.0。发布版相对 `0415707` 的 GPU 循环仅增加生成器说明，过滤器与 fixture 源码完全相同，回归未修复。 |

精确父关系、API 原始响应、逐提交 diff 和文件散列见 [chronology.json](chronology.json)、[github/](github/)、[source-comparisons.json](source-comparisons.json)、[callback-sites.txt](callback-sites.txt)。PR16 的三个功能并非全部消失：GPU 过滤器保留了缺失回调处理；`a01b01_a2b2` 的新调用顺序与 GPU 过滤器一致，本次通过；中间 `Aa2` 误筛则被明确重新引入，另有一组输出参数错位。

**两处可直接解释错误的过滤决定**

1. `a01b2_a2b01` 四个 label：发布版 [GPU loop L2104–2115](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/ri/LRI-cal_loop3_GPU.hpp#L2104) 在 `Aa2` 求和循环中调用 `filter_for2(label,Aa01,Aa2)`；[GPU filter L47–52](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L47) 将第二个参数当成输出右原子。随后 `filter_for32(Aa01,Ab01,Aa2)` 又被 [L65–66](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L65) 解读为筛 `(Aa01,Aa2)`。扇区仅含 `(1,0,R=1)` 时，合法输出 `Aa01=1, Ab01=(0,1)` 本应对全部六个 atom/cell 中间项求和，却只保留 `Aa2=(0,1)`。这正是 PR16 最后修复的错误再次出现；新实测 `a1b2_a2b1` 元素误差为 `4.89589`。

2. `a01b01_a01b2` 四个 label：发布版 [GPU loop L431–436](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/ri/LRI-cal_loop3_GPU.hpp#L431) 传 `(Aa01,Aa2,Ab01)`，而 [GPU filter L62–63](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L62) 按 `(Aa01,Ab01,Aa2)` 解释，筛成 `(Ab01,Aa2)`，交换输出左右原子并反转相对平移。例如应保留 `Aa2=(1,0), Ab01=(0,1)`，却查找不存在的 `(0,1,R=-1)`。实测对应四个 label 均出现 output atom count mismatch。

**调用者、fixture 与独立参考的区别**

ABACUS [exx_lri_interface.h:56](/home/stardust/orca/workspaces/sai-hpc-software/cp2k/.work/abacus-libri-pr-ready-20261121/abacus/source/source_lcao/module_ri/exx_lri_interface.h:56) 设置 `lri.cal_mode`，[exx_lri.hpp:862](/home/stardust/orca/workspaces/sai-hpc-software/cp2k/.work/abacus-libri-pr-ready-20261121/abacus/source/source_lcao/module_ri/exx_lri.hpp:862) 调用 `RI::Exx::set_symmetry(true, sector)`；发布版 [Exx.hpp:40](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/Exx.hpp#L40) 已正确创建 Wrapper，其 [L49–58、L94](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_Wrapper.h#L49) 保存模式引用并动态选 GPU filter。未发现这里遗漏 API 迁移，fixture 先构造 Wrapper 再切换模式也有效。

原版 fixture 直接使用 CPU filter，因此它最初的 block-count 失败包含调用方式过时的问题；[fixture-wrapper.patch](fixture-wrapper.patch) 只改 include 与构造函数。迁移后仍有上述数值/输出键错误，不能以“测试旧了”解释。参考仍是**关闭过滤的 CPU 完整收缩，再独立按输出键 mask**，并强制检查 2 个原子、每个 6 个完整块；输出结构、shape、非有限数、元素误差检查及 `1e-10 × (1+|reference|)` 容差均保持原样。两个 CPU 后端、旧 GPU 算法、修补后 GPU 均通过这一相同参考，支持过滤错误定位。

特别注意：ABACUS 能量 `cal_Hs` 使用 [Exx.hpp:274–279](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/Exx.hpp#L274) 的四个 label，其中包括第二类错误 `a0b0_a1b2`，**并不包含**独立测试最先数值失败的 `a1b2_a2b1`。因此不能直接用后者的数值解释 Si2 能量差；第二类缺陷确实位于 ABACUS 该调用路径。

**本次新复现：单 V100 作业 2670730**

SAI `16V100/16v100n09`，1 V100，1 MPI rank，OMP/BLAS 线程均 1；Slurm 限时 30 分钟，实际 1 分 51 秒完成。GCC 13.3，复用已有 Open MPI/CUDA/DDLA。所有变体均链接同一 DDLA 安装（先前溯源为 `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7`），本次记录 `libddla.so` SHA256 为 `f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af`。源码核验 493 个文件无差异，原发布副本 118 个实现头文件保持原样。

| 新检查 | 结果 |
| --- | --- |
| 发布版原 fixture，`-1 all all` | **失败，exit 1**；real `a1b1_a2b2`、sector 1、GPU mode 2，output block count differs。 |
| 发布版 + fixture Wrapper 迁移，`-1 cpu all` | 通过；两个 CPU 模式，实/复数、18 labels + 合计，304 CHECK / 38 PASS。 |
| 同一发布实现，逐 label `0..18 gpu all` | 单独 18 labels 中 **8 失败、10 通过**，合计也失败；失败分别为 crossed 族 `{a1b2_a2b1,a1b2_a2b0,a0b2_a2b1,a0b2_a2b0}` 与 `{a0b1_a1b2,a0b2_a1b1,a0b0_a1b2,a0b2_a1b0}`。失败项在 real 阶段停止，未把未执行的 complex 阶段计为通过。 |
| 发布版 + Wrapper fixture + 局部循环补丁，`-1 all all` | **通过，exit 0**；456 CHECK / 38 PASS，覆盖所有 label 和合计、三种模式、实/复数、四扇区、空/seeded 输出及 `-0.5/0/1.25` 累加。 |
| `0e8afc393` 算法 + 当前 DDLA 接口适配，原 fixture，`-1 all all` | **通过，exit 0**；相同 456 CHECK / 38 PASS。只替换 `GPU_Backend.h` 为当前公共 API 适配版本；数值循环/过滤器未修改。这是控制实验，非未经修改的历史二进制重跑。 |

最小失败命令（构建参数完整记录于 [origin.sbatch](origin.sbatch)）：

```sh
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/release-wrapper/test_lri_gpu_symmetry 1 gpu real
# atoms=1,0 cell=1 element=0 error=4.89589 ; exit 1
```

逐项退出码及原始输出见 [test-summary.json](test-summary.json)、[status.tsv](remote-results/logs/status.tsv)、[失败日志](remote-results/logs/release-wrapper-label-1.log)、[修补后日志](remote-results/logs/release-patched-all.log)、[旧算法控制日志](remote-results/logs/dev-current-ddla-all.log)。Slurm 完成只表示脚本完成采集，**不表示发布版测试通过**。调度记录见 [scheduler.txt](remote-results/logs/scheduler.txt)，原始结果归档为 [remote-results.tar.gz](remote-results.tar.gz)。两次未成功提交的资源参数尝试也保留在 `logs/job-submit*.txt`；实际仅运行一个 1-GPU 作业。

**既有 ABACUS 与历史验证证据**

既有 release 验证记录在 [previous-symmetry-regression.json](logs/previous-symmetry-regression.json)：pre-guard ABACUS `c1d3b81e97f7fcd4d4fafd0d65416fa227151a81` 的 Si2 real/complex GPU RI 与 CPU 均差 `0.032459305870816 eV`、最大应力分量 `0.3058679098 kbar`；关闭实空间约化的对应控制一致。该对称构型力为零，不能据此声称非零力通过。本次读取并保留原始 LibRI 失败日志，未重建/重跑 ABACUS，因此尚未证明局部补丁消除此 Si2 能量/应力差。

已核对 PR16 [历史说明](github/historical-pr16-validation.md)、[合并验证说明](github/historical-merged-validation.md)、[原始 summary](github/historical-merged-summary.json) 与 [GPU OMP1 原始日志](github/historical-merged-gpu-omp1.log)：记录 DDLA 0.0.4 下四个原 ABACUS abort 被修复，合并验证 20/20 计算通过、16 个 backend comparisons 通过，GPU 数值日志有 38 PASS。这些是历史结果；本次新增控制验证为上表，不混同。旧 DDLA 0.0.4 目录对当前 SSH 用户拒绝读取，未绕过权限或重建安装，故保留原样历史提交二分的限制。DDLA 0.0.6 的原公共 API 与本次安装不同，不能仅按版本号替换；[dev-current-ddla.patch](dev-current-ddla.patch) 明确记录了适配差异。

**最小后续建议与边界**

- 审查 [proposed-loop-contract-fix.patch](proposed-loop-contract-fix.patch)：生成头文件中删除四处中间 `Aa2` 筛选，修正两族各四处 `filter_for32` 参数；同时修改生成器的两处模板，避免重新生成时恢复错误。[generator-verification.json](generator-verification.json) 证明生成结果与已测补丁头文件逐字节相同。
- 同步应用 fixture 的 Wrapper 迁移，并恢复后端切换/关闭对称性的回归覆盖。此次最小补丁未改无效的 `filter_for31` 参数顺序；默认对称性过滤器对此始终 no-op，自定义过滤器的完整契约另需审查。
- 在受控后续验证中，用同一补丁重跑 ABACUS Si2 real/complex 的能量/应力比较，再加入非零力构型；多 rank、BSE、GW/RPA、MAGMA、本任务外性能均未建立覆盖。
- 保留当前 ABACUS `device_exx=gpu + effective symmetry=1` 的全部拒绝条件（与 `exx_symmetry_realspace` 无关）。现有 `VALIDATION_NOTES.md` 的早期较窄限制已过时，应以当前 `read_inp_exx_dftu.cpp:273` 和协调者的最终文档为准；本任务未修改其他 worker 的文件，也未发布任何上游改动。

远端隔离目录：`/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121`。精确运行源码/fixture/脚本可用 [test-bundle.tar.gz](test-bundle.tar.gz) 重建，对应 [test-source-sha256.json](test-source-sha256.json)；全目录文件校验见 [SHA256SUMS](SHA256SUMS)。
