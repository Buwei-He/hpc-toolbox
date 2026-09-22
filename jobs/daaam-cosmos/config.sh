# daaam-cosmos — PAPER reproduction profile. vLLM and the DAAAM pipeline share ONE
# GPU (setup.sh drops COSMOS_GPU_MEMORY_UTILIZATION to 0.75 to make room), which
# leaves the pipeline ~25%: fine on an 80 GB card, OOM-prone on a 40 GB one. That is
# why it fails on some nodes and not others.
#
# For the live demo use the 'percorso' profile instead — it runs the pipeline alone
# and reaches a separate cosmos-reason2 job over $PROJECT/.cosmos_url. This profile
# is kept because it carries the paper automation (auto_all / auto_ros_launch /
# auto_bag_play / postprocess_merge) and bjob special-cases it in 12 places.
# If it must be co-located, lower the knob: COSMOS_GPU_MEMORY_UTILIZATION=0.6
D_ACCOUNT="berzelius-2026-211"
D_PARTITION="berzelius"
D_GPUS="1"
D_TIME="00:59:59"
D_MEM="80G"
D_JOBNAME="daaam-cosmos"
