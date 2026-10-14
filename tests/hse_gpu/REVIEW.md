# PW EXX 缓存补丁复核（2026-10-15）

## 最小交付

- fork 分支：`perf/pw-exx-plan-cache`，提交 `93c41db70fe330c61634ee6a0a629fc2af935aca`。
- 基线：上游 develop `f264b4022fd477734de0f3ace723f6da9e306943`；本轮 `git ls-remote upstream refs/heads/develop` 确认仍为该提交。
- 仅修改 `op_pw_exx.cpp` / `.h`，30 行新增、10 行删除。所有 source 文件与原已测试实验提交 `892ee32fc` 相同。
- 原实验设施及本报告保留在 `experiment/hse-gpu-20261014`，没有混入精简分支，没有向上游提交 PR。
- 适用 PW 的 CPU/CUDA 批量 EXX 路径，未修改 LCAO、交换公式、精度、累加顺序或输入默认值。

## 维护性审查

- 两个批量 plan 的有界缓存，避免主块/余块反复创建 FFT plan；单带 plan 与批宽变化解耦。
- 缓冲容量只在增长或网格改变时重新分配；所有使用处仍按实际批宽访问。
- 缓存键包含三个网格维度及批宽；网格改变后失效，析构释放两份批量 plan 和单带 plan。
- CPU FFTW 使用 new-array execute 与 FFTW_UNALIGNED；CUDA 执行时传入缓冲地址，plan 不绑定旧缓冲。
- 未增加依赖、公共接口、全局控制状态、输入选项或不相关重构。额外 plan 的工作区可能增加显存，未声称节省显存。
- 治理检查无 error；缺少 PR 测试/文档字段的两条 warning 由本报告提供验证依据。无用户接口变化，因此不改输入文档。
- 全文件质量评分基线与候选均为 cpp 40 / header 76；低分来自原有文件长度等问题，没有为提高分数进行无关重构。

## 已完成的检查

1. 精简提交经 `.ci/slurm/runner.py` 在 SAI V100 集群构建成功，job `1789546`。后续复用该二进制，未重新修改源码。
2. `python3 -m unittest discover -s .ci/slurm -p test_runner.py -q`：45/45 通过。`git diff --check` 通过。
3. 将实际源码的缓存方法、字段及相关析构片段提取到模拟 plan/分配器的隔离驱动，以 `g++ -std=c++11 -fsanitize=address,undefined` 检查：1,000 次主块/余块交替、第三种宽度淘汰、缓冲增长、同体积不同形状的网格、大小网格切换、释放平衡全部通过。该补充检查不等同于真实 CUDA 或完整类的单元测试。
4. 下表 14 项真实 SCF 均收敛；全网格使用原 `1e-6 eV/atom` 阈值，最大偏差为 `1.55e-7 eV/atom`。多 k 点用相同 KPT 的 CPU 参考，不与 Gamma 参考混比。小网格单独记录，不作为严格等价承诺。
5. `scf_pbe0_spin2_kpar` 双 GPU 的现有能量/力参考回归通过，job `1789659_1`。
6. 之前的同配置新旧版本对照仍有效：32 次 Si8 SCF（每版 8 配置 × 2 次），最大新旧能量差约 `4.03e-9 eV/atom`；PW PBE0 和 LCAO HSE 参考回归通过。详见 RESULTS.md。

本轮数值矩阵 job `1789659_0`。加载集群模块后设定 `OMP_NUM_THREADS=1`，启动日志确认实际单线程。

| 配置 | 收敛 | 相对对应 CPU 参考 / eV·atom⁻¹ |
|---|---|---:|
| cpu_full | PASS | 0.000e+00 |
| cpu_chunk1 | PASS | 0.000e+00 |
| cpu_chunk7 | PASS | 0.000e+00 |
| gpu_chunk1 | PASS | 1.179e-09 |
| gpu_chunk4 | PASS | 1.179e-09 |
| gpu_chunk7 | PASS | 1.179e-09 |
| gpu_chunk19 | PASS | 1.179e-09 |
| gpu_chunk20 | PASS | 1.179e-09 |
| gpu_chunk64 | PASS | 1.179e-09 |
| gpu_small_tail | PASS | 9.042e-10 |
| gpu_noace_tail | PASS | 1.104e-07 |
| cpu_mpi2_tail | PASS | -1.220e-09 |
| cpu_multik | PASS | 0.000e+00 |
| gpu_mpi2_tail | PASS | -1.544e-07 |

## 失败尝试与测试环境更正

- review1：GPU/PW 自动将两个 MPI rank 分成两个 k 池，单 Gamma 点导致空池，未进入 SCF；改用 `1 2 1` KPT 后通过。CPU 双 rank 的分布式 FFT 路径另测通过。
- review1 还发现模块将预设 OMP_NUM_THREADS 覆盖为 8。本轮在模块加载后设为 1。此前性能数据的基线和候选都实际使用 8 线程，已更正原报告；不将两轮不同线程配置混合做性能比较。
- review2 的 14 项数值运行通过，但最后 sanitizer 子项失败，导致 runner 总状态 FAIL。这里保留原始 FAIL，而不是修改其 summary；数值表是对已保存的收敛记录和能量重新独立核验所得。
- review2/3 的 sanitizer 打印 MPI/UCX CUDA context 或设备地址探测 API 错误。单 rank 内存检查改用 OpenMPI `pml=ob1`、`btl=self,sm,tcp`、`accelerator=null`、`coll=^cuda`，保留完整应用/CUDA 内存错误检查。普通并行回归使用原集群通信配置。

## CUDA 内存检查结论

- 候选 review4（job `1789751_0`）与未优化基线 review5（job `1789775_0`）均完成同一 Si8 / batch 7 SCF，最终能量相同：`-848.1090619091797 eV`。
- 两者均报告 **0 bytes leaked / 0 allocations**，未报告非法显存访问或释放错误。
- 两者均有完全相同类别与数量的 **10 条 cuCtxGetLimit / CUDA_ERROR_INVALID_VALUE**，栈位于 cuBLAS/cuSOLVER handle 初始化。
- 未隐藏错误、未放宽 `--error-exitcode 99`；因此两个 sanitizer 作业仍为 FAIL。结论是未发现补丁新增的 sanitizer 报告，不能宣称 sanitizer 零错误通过。库级 API 诊断不在本补丁中修改。

## 范围与复现

这是一项局部资源复用优化，不能据小体系实测宣称所有体系最优。尚未完成大体系显存峰值、长时间 MD/变胞、ROCm 或单精度验证；隔离网格失效测试不是变胞计算的替代。

本地完整控制脚本、INPUT/KPT/STRU、stdout、运行日志、二进制 SHA256 与 runner 结果保留在 `/mnt/g/work/agent/abacus/hse-gpu-results/review*`。
`review/control` 为首次实际构建，`review2/control` 为修正线程/并行配置的矩阵；后续内存检查复用同一二进制。每个目录的 `run.json` 记录精简源码 SHA；单独基线内存检查使用已保存的未优化二进制，须区分该基线与 run.json 中控制任务的源码 SHA。
原实验入口 `.ci/slurm/run_hse_experiment.py` 已修正线程设置顺序，仅位于实验分支。
