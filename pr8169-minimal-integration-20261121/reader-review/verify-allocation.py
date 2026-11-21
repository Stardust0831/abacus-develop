import json, os
from pathlib import Path
keys = ["SLURM_JOB_ID", "SLURM_JOB_PARTITION", "SLURM_NTASKS", "SLURM_NNODES", "SLURM_GPUS_ON_NODE", "CUDA_VISIBLE_DEVICES", "MAP_OPT", "RANKS_PER_GPU", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"]
values = {key: os.environ.get(key) for key in keys}
values["allowed_logical_cpus"] = len(os.sched_getaffinity(0))
print(json.dumps(values, indent=2))
assert values["SLURM_JOB_PARTITION"] == "16V100"
assert values["SLURM_NTASKS"] == "4"
assert values["SLURM_NNODES"] == "1"
assert values["SLURM_GPUS_ON_NODE"] == "4"
assert values["allowed_logical_cpus"] == 32
assert values["RANKS_PER_GPU"] == "1"
for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    assert values[key] == "1", key
print("Allocation and mapping verified before configuration/build/tests.")
