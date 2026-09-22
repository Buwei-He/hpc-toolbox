# daaam-cosmos — PAPER reproduction profile. vLLM and the DAAAM pipeline share ONE
# GPU (setup.sh drops COSMOS_GPU_MEMORY_UTILIZATION to 0.75 to make room), which
# leaves the pipeline ~25%: fine on an 80 GB ("fat") card, OOM-prone on a 40 GB
# ("thin") one. That USED TO BE why it failed on some nodes and not others --
# D_CONSTRAINT="fat" below now asks SLURM for an 80 GB card specifically, instead
# of leaving it to chance. Costs some queue time: only ~40% of nodes are fat.
#
# For the live demo use the 'percorso' profile instead — it runs the pipeline alone
# and reaches a separate cosmos-reason2 job over $PROJECT/.cosmos_url. This profile
# is kept because it carries the paper automation (auto_all / auto_ros_launch /
# auto_bag_play / postprocess_merge), which now lives in its own bjob_hooks.sh
# rather than being special-cased inside bin/bjob itself.
# If it must run on a thin card anyway, lower the knob further:
# COSMOS_GPU_MEMORY_UTILIZATION=0.6 (and drop D_CONSTRAINT below).
D_ACCOUNT="berzelius-2026-211"
D_PARTITION="berzelius"
D_GPUS="1"
D_TIME="00:59:59"
D_MEM="80G"
D_JOBNAME="daaam-cosmos"
D_CONSTRAINT="fat"
