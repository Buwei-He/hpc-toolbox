D_ACCOUNT=""   # blank: resolved from local.config.json (site.sh), or auto-detected
D_PARTITION="berzelius"
D_GPUS="1"
D_TIME="00:59:59"
D_MEM="40G"
D_JOBNAME="llava-onevision"
# setup.sh backgrounds the server, polls until healthy, writes
# $PROJECT/.llava_url, and returns -- verified safe to run with
# 'bjob submit', nobody watching.
D_SUBMITTABLE="1"
