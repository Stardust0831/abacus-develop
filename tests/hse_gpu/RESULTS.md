# HSE GPU 首轮实验结果（2026-10-14）

实验仅位于 Stardust0831/abacus-develop 的 `experiment/hse-gpu-20261014` 分支。
没有向上游创建 PR、提交评论或推送分支。

## 代码与环境

- 上游 develop 基线：`f264b4022fd477734de0f3ace723f6da9e306943`。
- 基线测试提交：`377e488d14f43e39bc650ebe7848b2a843b9ea46`，只增加测试设施，计算源码等于上述上游版本。
- 最终候选测试提交：`3ce8507b08abc981b6ca43ccde04731894e73e12`。
- 性能修改提交：`ce6deba0fc5fef9866b604c3e50a1283fcfc7e51`。
- 平台：SAI `16V100`，Tesla V100-SXM2-16GB；CUDA 12.9.86，Libxc 7.0.0，LibRI 2.1.1。
- 使用 `.ci/slurm/runner.py` 的构建、Slurm、回归、归档机制；标准 config.ini 未改变。
- 实验配置额外开启 ENABLE_LIBRI。计算节点不能访问 GitHub，因此在客户端根据现有 toolchain 的版本及 SHA256 下载 LibRI、LibComm、cereal，随 control 文件传输到每次构建目录；不修改集群全局环境。

## 修改内容

`OperatorEXXPW::ensure_exx_batch` 原来在批宽变化时同时重建批量 FFT plan、单带 plan 和工作缓冲。
对于 20 bands / batch 6，每个占据源轨道都会再次经历 6→2→6 的重建。

候选保持缓冲区最大容量，并缓存最多两个批宽的 FFT plan。单源轨道 plan 仅在网格改变时重建。
无交换公式、截断精度、累加顺序或输入默认值变化。缓存有界，但额外 plan 有额外 cuFFT 工作区开销。

## 结论

有尾块时收益可复现：最终 GPU batch 6 墙钟时间减少 14.3%，batch 19 减少 12.1%，CPU batch 6 减少 11.3%。前两轮 GPU batch 6 分别减少约 19% 和 17.5%，方向一致。全带默认路径和小幅变化不据两次重复作稳定提速结论。小交换网格实际启用，但在此小体系上没有明显总时间优势。

## 最终实验

Si8 conventional cell，Gamma，20 bands，ecutwfc=30 Ry，ecutrho=120 Ry，HSE 默认参数。
`scf_thr=1e-12`，初始 `pw_diag_thr=1e-12`，固定随机种子，1 MPI rank，实际运行时 OMP_NUM_THREADS=8（2026-10-15 复核 stdout 后更正：模块覆盖了脚本中预设的 1）。
每项两次，第二遍反向执行，均从头开始 SCF。
下表时间为包含进程启动的实测墙钟时间；负的减少百分比表示该次测量变慢。

| 配置 | 基线平均 / s | 候选平均 / s | 墙钟时间减少 | 最大新旧能量差 / eV·atom⁻¹ |
|---|---:|---:|---:|---:|
| cpu_full | 10.222 | 10.139 | 0.8% | 1.92e-10 |
| cpu_chunk6 | 11.618 | 10.304 | 11.3% | 2.34e-09 |
| gpu_full | 6.036 | 5.881 | 2.6% | 2.48e-09 |
| gpu_chunk5 | 6.100 | 5.807 | 4.8% | 7.67e-10 |
| gpu_chunk6 | 6.983 | 5.984 | 14.3% | 1.63e-09 |
| gpu_chunk19 | 6.976 | 6.132 | 12.1% | 4.03e-09 |
| gpu_small | 6.089 | 5.874 | 3.5% | 2.29e-09 |
| gpu_noace | 12.116 | 11.156 | 7.9% | 7.76e-10 |

候选全网格各路径相对 CPU 全网格参考的最大能量差：1.106e-07 eV/atom。
判据保持 1e-6 eV/atom；小网格单列为精度实验，不纳入严格等价判据。
`gpu_small` 日志确认交换 FFT 网格从 36³ 缩至 25³，不是静默回退。

## 检查与限制

- 最终基线 CI 结果：3/3 PASS，0 失败，0 基础设施失败；构建作业 1789320，测试数组 1789333。
- 最终候选 CI 结果：3/3 PASS，0 失败，0 基础设施失败；构建作业 1789321，测试数组 1789335。
- PW PBE0 `scf_pbe0_spin1`：比较能量与力。
- LCAO HSE `scf_hse_gamma`：比较能量、力与应力。该用例固定较少 EXX 外循环，是现有回归用例，不是生产精度基准。
- HSE 基准每个版本包含 8 配置 × 2 次 = 16 次完整 SCF，检查收敛和能量一致性。
- `python3 -m unittest discover -s .ci/slurm -p test_runner.py -q`：45 项通过。
- Python 编译检查和 `git diff --check` 通过。治理检查无错误，只有文档同步提示；无新 INPUT/用户行为，说明已写入本实验文档。
- 此次没有新增 LCAO EXX GPU kernel，也没有补齐 PW GPU 应力。
- 只有 Si8、Gamma 和单 GPU 数据；不能外推为大体系、多 GPU、SOC 或生产 MD 加速比。
- 两次重复不足以解释小幅涨跌。基线和候选可能分配到不同 GPU/节点，应以尾块路径的稳定变化为主要结论。
- CPU 对照是 1 MPI rank / 8 OpenMP threads，不代表最优全节点 CPU 性能。
- ABACUS 内部内存统计未完整覆盖 cuFFT 私有工作区；未宣称峰值显存降低。

## 未隐藏的先行失败

1. 最初浅克隆无法生成完整远端 bundle；补齐历史后重试，未进入计算。
2. 第一轮标准 CI 未开启 LibRI，LCAO HSE 与参考不符；开启 LibRI 后回归通过。
3. 自动下载依赖在计算节点超时，两次构建主动取消，属于基础设施失败；已用固定校验和的离线依赖解决。
4. 初始 scf_thr=1e-8 时 ACE/非 ACE 相差约 0.020 meV/atom；1e-10 时降至约 0.0025 meV/atom，仍触发严格判据。最终收紧到 1e-12 后差异降到约 0.00011 meV/atom，通过原判据。这些先行失败记录保留，没有放宽判据或修改参考值。

## 复现与产物

参见 README.md 的 `.ci/slurm/run_hse_experiment.py` 命令。
对基线可用 `git worktree add --detach /tmp/abacus-hse-baseline-full 377e488d1`，
再给同一客户端传 `--source-repository /tmp/abacus-hse-baseline-full`，以保持控制脚本和依赖一致。

- 汇总数据：`results/measurements-20261014.json`，含所有有效实验轮次原始测量、源码 SHA、硬件标识和 CI 状态。
- 本地完整日志：`/mnt/g/work/agent/abacus/hse-gpu-results/`。
- 最终基线日志：`baseline5/results/`；最终候选日志：`candidate4/results/`。
- 远端归档：`~/abacus_hse_gpu_experiment/archives/hse-experiment/` 下对应 run-id 的 tar.gz。
- CI 的原始 INPUT、stdout、running_scf.log、模块、CMakeCache、Slurm 状态和 GPU dmon 均已下载。

## 后续优先级

1. 用 Si64/Si216 或实际体系、至少 5 次重复及同一 GPU 的交错 A/B 验证；同时量化 cuFFT 工作区峰值。
2. 扩展多 k 点、自旋、kpar、多 GPU 和 float/ROCm 边界检查后，才能考虑将该补丁当作通用实现。
3. 对真正的大体系 HSE 性能，继续比较 ACE、小交换网格及源轨道复用。
4. LCAO 路线仍应先 profile `D(k)→D(R)`、LibRI 收缩、力/应力，再决定 GPU 后端范围；此次结果不代表 LCAO EXX 已 GPU 化。
