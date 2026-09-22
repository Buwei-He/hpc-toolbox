D_ACCOUNT="berzelius-2026-211"
D_PARTITION="berzelius"
D_GPUS="1"
D_TIME="00:59:59"
D_MEM="40G"
D_JOBNAME="cosmos-reason2"
# setup.sh backgrounds vLLM, polls until healthy, writes $PROJECT/.cosmos_url,
# and returns -- verified safe to run with 'bjob submit', nobody watching.
D_SUBMITTABLE="1"
