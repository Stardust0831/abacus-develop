**结论：PR16 曾正确合入；后续 Wrapper 重构重新引入过滤错误。**

具体首坏候选是 **[`4ed89410a5a6d7a891015879e8f0be0868af632d`](https://github.com/abacusmodeling/LibRI/commit/4ed89410a5a6d7a891015879e8f0be0868af632d)**（直接父提交 `6c6c8711894f6379d47448f71fd718170995d2fe`）。它重新筛选中间求和原子 `Aa2`，并恢复部分旧参数顺序，而新 GPU filter 仍按新顺序解释。本次新实验确认发布版失败，局部修补通过；该提交边界由精确源码 diff 确定，未冒称完成未经修改的历史二进制二分。

2026-11-21 查询时，`master` 与 `v0.3.0.0` 均为 `a385ac9b1d04c151f26f9d14cc0c2588f96557ab`。全部新文件仅在指定隔离目录，未改上游、安装或 ABACUS 限制。

**时间线**

| 提交 | 变化及证据 |
| --- | --- |
| 10-24 PR16 merge `a0661cb` | GitHub 确认 12:39:37 UTC 合并；包含 `cdeab575`、`4a41b913`、`11de9ee6`：补 GPU 回调、修输出参数、避免截断中间求和。历史日志确认完整修正通过。 |
| 11-09 [`6c6c871`](https://github.com/abacusmodeling/LibRI/commit/6c6c8711894f6379d47448f71fd718170995d2fe) | 拆 CPU/GPU filter，同步调整循环参数与 fixture，收缩时自动选择过滤器。源码仍正确保留中间求和。 |
| 11-10 `0e8afc393` | 在共同父提交 `ab81ac9` 的另一分支升级 DDLA，**未包含上述拆分**；GPU loop、filter、fixture 与 PR16 merge 三文件逐字节相同，因此此前通过与现状不矛盾。 |
| 11-10 [`4ed8941`](https://github.com/abacusmodeling/LibRI/commit/4ed89410a5a6d7a891015879e8f0be0868af632d) | 加 Wrapper 时撤回部分循环改动，重加四处 `filter_for2(Aa01,Aa2)`；GPU filter 仅新增注释，参数解释未同步改变；fixture 又恢复直接使用 CPU filter。**首坏候选。** |
| 11-10 `0415707` | 合并 `4ed8941` 与 `0e8afc393`，保留错误。 |
| 11-20 `e8cf659` → 11-21 `8032cad` → `a385ac9` | 加生成器、迁移 DDLA API、发布；错误一直保留。发布 GPU loop 相对 `0415707` 只新增生成器注释；生成器自身也包含错误。 |

原 fix 的保留情况：缺失回调已移入 GPU filter；`a01b01_a2b2` 的输出筛选仍正确且本次通过；避免筛中间 `Aa2` 的关键修正被撤回，并新增另一族输出参数错位。完整父关系、diff、散列见 [chronology.json](chronology.json)、[source-comparisons.json](source-comparisons.json)、[详细证据](EVIDENCE_DETAILS.md)。

**两组错误及 ABACUS 调用**

- `a01b2_a2b01` 四个 label：发布 [GPU loop:2109](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/ri/LRI-cal_loop3_GPU.hpp#L2109) 把中间 `Aa2` 交给输出筛选；下一层的参数也倒置。[GPU filter:47、65](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L47) 因而筛 `(Aa01,Aa2)`。对合法输出 `(1,0,R=1)`，六个中间 atom/cell 项仅留下 `Aa2=(0,1)`；实测 `a1b2_a2b1` 元素误差 `4.89589`。
- `a01b01_a01b2` 四个 label：发布 [GPU loop:436](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/ri/LRI-cal_loop3_GPU.hpp#L436) 传 `(Aa01,Aa2,Ab01)`，而 [GPU filter:63](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L63) 据新约定筛成 `(Ab01,Aa2)`；输出 `(1,0,R=1)` 被误当 `(0,1,R=-1)` 拒绝，实测 output atom count mismatch。

ABACUS 设置 `lri.cal_mode` 后调用 `RI::Exx::set_symmetry`，当前库 [Exx.hpp:40](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/Exx.hpp#L40) 已正确用 Wrapper；未发现这里遗漏 API 迁移。原 fixture 直接构造 CPU filter 确实过时，但**只迁移 Wrapper 后仍失败**。参考是完整无过滤 CPU 收缩再独立 mask 输出键，结构/元素检查及原 `1e-10 × (1+|reference|)` 容差未改；两个 CPU 后端、旧算法与修补后 GPU 均通过相同参考。

ABACUS 能量路径 [cal_Hs:274](https://github.com/abacusmodeling/LibRI/blob/a385ac9b1d04c151f26f9d14cc0c2588f96557ab/include/RI/physics/Exx.hpp#L274) 包含第二组的 `a0b0_a1b2`，不包含第一组的 `a1b2_a2b1`；不能直接拿独立测试首个误差解释 Si2 能量差，但确有失败分支位于能量调用链。

**新复现结果**

作业 **2670730**：`16V100/16v100n09`，1 V100、1 rank、OMP/BLAS=1，限时 30 分钟，实际 1 分 51 秒；GCC 13.3，复用已有依赖。四种构建使用同一 DDLA 安装（先前溯源 `7c0ca08`），本次 `libddla.so` SHA256 `f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af`。493 个运行源码/脚本文件散列全部匹配；原发布副本 118 个实现头文件未修改。

| 构建/检查 | 结果 |
| --- | --- |
| 发布原 fixture | **失败 exit 1**：`a1b1_a2b2`、sector 1、GPU mode 2，block count mismatch。 |
| 发布实现 + Wrapper fixture | CPU 两模式全部通过；GPU 单独 18 labels 中 **8 失败、10 通过**，组合求和亦失败。失败在 real 阶段停止，未计入未执行的 complex 检查。 |
| 发布实现 + Wrapper fixture + 局部循环补丁 | **通过 exit 0，456 CHECK / 38 PASS**：18 labels + 合计、CPU 两模式/GPU、实复数、四扇区、空/seeded 输出、signed/zero 累加。 |
| `0e8afc393` + 当前 DDLA 适配 | **通过 exit 0，同样 456 CHECK / 38 PASS**；仅适配 `GPU_Backend.h`，旧收缩/filter 原样保留，明确属于控制实验。 |

构建/运行命令在 [origin.sbatch](origin.sbatch)；最小失败执行参数为 `build/release-wrapper/test_lri_gpu_symmetry 1 gpu real`（上述 MPI/线程条件）。详见 [test-summary.json](test-summary.json)、[失败日志](remote-results/logs/release-wrapper-label-1.log)、[修补后日志](remote-results/logs/release-patched-all.log)、[调度记录](remote-results/logs/scheduler.txt)。Slurm 的完成状态仅说明采集脚本完成，**发布版测试仍失败**。

**后续与限制**

建议审查 [局部修补](proposed-loop-contract-fix.patch) 与 [fixture 迁移](fixture-wrapper.patch)：删除四处中间筛选，修正八处回调参数，并同步生成器；[生成检查](generator-verification.json) 证明生成输出与已测修补头文件一致。保留 ABACUS 当前 `device_exx=gpu + effective symmetry=1` 全部拒绝条件，之后另行验证应用再讨论解除。

既有 Si2 real/complex 记录仍是能量差 `0.032459305870816 eV`、应力差 `0.3058679098 kbar`，关闭实空间约化的控制一致；力为零。本次未重建/重跑 ABACUS，**尚未证明修补消除应用误差**，下一步应验证 Si2 能量/应力及非零力构型。历史 PR16 的 20/20 计算、16 个 backend comparisons 和 DDLA 0.0.4 GPU 日志已核对，但属于历史证据；旧 DDLA 目录当前不可读，未做原样历史二分。多 rank、BSE、GW/RPA、MAGMA、自定义 filter 完整契约未获本次覆盖。

完整解释、原始 GitHub 证据、历史/当前差异见 [EVIDENCE_DETAILS.md](EVIDENCE_DETAILS.md)。复现包 [test-bundle.tar.gz](test-bundle.tar.gz)、结果 [remote-results.tar.gz](remote-results.tar.gz)、[SHA256SUMS](SHA256SUMS) 均在本目录；远端目录为 `/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121`。
