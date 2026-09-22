## start a new job

Check active jobs: 
squeue -u $USER 

Start a new job:
srun --pty --jobid <job_id> /bin/bash

---
## Export rosbag for EGG Dataset

python3 /ros2_ws/tools/create_egg_bag.py \
    --batch-dir /ros2_ws/data/EGG-Dataset/batch_2 \
    --output /ros2_ws/data/EGG-Dataset/bags/egg_batch_2_full.bag

## EGG dataset (HC-DAAAM, manual)

export PROJECT=/proj/<your-group>/users/$USER   # or just: bjob (sets it for you)

apptainer shell --nv \
    -B $PROJECT/ros2_ws:/ros2_ws \
    -B $PROJECT/rosbags:/rosbags \
    $PROJECT/containers/daaam.sif

source /ros2_ws/setup_daaam.sh
export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH

export BATCH_NAME=batch_3
export COSMOS_URL=http://node077:8000/v1

ros2 launch daaam_ros egg_daaam_hydra.launch.yaml scene:=egg_${BATCH_NAME}_dynamic hydra_config_path:=/ros2_ws/src/daaam_ros/config/hydra_config/egg_dataset_khronos_dynamic.yaml input_config_path:=/ros2_ws/src/daaam_ros/config/hydra_ros_config/egg_dataset_input_config.yaml depth_scale:=1000.0 exit_after_clock:=true verbosity:=1 save_human_clips:=true enable_cosmos_hoi_processing:=true cosmos_hoi_debug_preview:=true cosmos_hoi_base_url:=${COSMOS_URL} human_clip_output_fps:=${HOI_FPS} cosmos_hoi_fps:=${HOI_FPS} cosmos_hoi_media_root:=$PROJECT

# If you want to run with the batch_X in the name:
ros2 launch daaam_ros egg_daaam_hydra.launch.yaml \
  scene:=egg_${BATCH_NAME}_dynamic \
  hydra_config_path:=/ros2_ws/src/daaam_ros/config/hydra_config/egg_dataset_khronos_dynamic.yaml \
  input_config_path:=/ros2_ws/src/daaam_ros/config/hydra_ros_config/egg_dataset_input_config.yaml \
  depth_scale:=1000.0 \
  exit_after_clock:=true \
  verbosity:=1 \
  save_human_clips:=true \
  enable_cosmos_hoi_processing:=true \
  cosmos_hoi_debug_preview:=true \
  cosmos_hoi_base_url:=${COSMOS_URL} \
  cosmos_hoi_media_root:=$PROJECT \
  output_run_prefix:=egg_${BATCH_NAME}_


ros2 bag play /ros2_ws/data/EGG-Dataset/bags/egg_${BATCH_NAME}_full.bag --clock -p --qos-profile-overrides-path /ros2_ws/tools/egg_bag_qos_overrides.yaml --start-paused

## For HOI4D tests

# Terminal A — launch
export COSMOS_URL=$(cat $PROJECT/.cosmos_url)
export BATCH_NAME=laptop
ros2 launch daaam_ros hoi4d_daaam_hydra.launch.yaml \
    scene:=hoi4d_${BATCH_NAME} \
    save_human_clips:=true \
    enable_cosmos_hoi_processing:=true \
    cosmos_hoi_base_url:=${COSMOS_URL} \
    cosmos_hoi_media_root:=$PROJECT

# Terminal B — bag
export BATCH_NAME=laptop
ros2 bag play /ros2_ws/data/hoi4d/bags/hoi4d_${BATCH_NAME}.bag --clock -p \
    --qos-profile-overrides-path /ros2_ws/tools/egg_bag_qos_overrides.yaml

## Manual group_events (if HOI processing was skipped or Cosmos was unreachable during the run)

export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/out_YYYYMMDD_HHMMSS  # update to actual run dir
export COSMOS_URL=$(cat $PROJECT/.cosmos_url)

python3 -c "
from pathlib import Path
from daaam.human_reason import group_events
group_events(Path('${OUTPUT_DIR}'), base_url='${COSMOS_URL}', model='cosmos-reason2', api_key='EMPTY')
"

## Query / reasoning

export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/20260608_12/merged_egg_v3
export OPENAI_BASE_URL=https://openrouter.ai/api/v1

python3 /ros2_ws/src/daaam/scripts/demo_query.py \
--dsg-path ${OUTPUT_DIR}/dsg.json \
--hoi-output-dir ${OUTPUT_DIR} \
--model-name openai/gpt-5.4-mini
 
## Merge multiple batch outputs into a single queryable result

python3 $PROJECT/ros2_ws/src/daaam/scripts/merge_dsgs.py \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_1_out_20260610_162220 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_2_out_20260610_163159 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_3_out_20260610_164926 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_4_out_20260610_165700 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_5_out_20260610_170813 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_6_out_20260610_172234 \
$PROJECT/ros2_ws/src/daaam/output/egg/20260610/egg_batch_7_out_20260610_173117 \
--output /ros2_ws/src/daaam/output/egg/20260610/merged_egg_v1


## Rerun export
export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/out_20260521_142808  # update to actual run dir

python3 /ros2_ws/src/daaam/scripts/export_rerun_output.py \
  --output-dir ${OUTPUT_DIR} \
  --no-spawn \
  --rrd ${OUTPUT_DIR}/daaam_output.rrd

  
## Semantic post-processing
python3 -m daaam.human_reason.semantic_post_processing \
  output/egg/out_20260521_112230 \
  --base-url http://node022:8000/v1 \
  --model cosmos-reason2 \
  --output-name events_semantic_rerun.yaml

---
## Reaching a job's service (ssh-helper)

`ssh-helper` is the **robot/laptop side** and ships in the percorso-perception
repo (`tools/ssh-helper`). Full docs: that repo's `tools/README.md`.

```bash
# on the robot / laptop:
export PERCORSO_SSH_TARGET=<user>@berzelius1.nsc.liu.se
ssh-helper login
ssh-helper connect <node> stream && ssh-helper connect <node> bridge
```

**On the cluster you do not need it** — compute nodes are directly reachable from
a login node, so there is nothing to forward. Use `percorso-demo status` to see
what is up and on which node; run a `ssh-helper` verb here and it says so.

Compute nodes are private and change every allocation, so nothing is hardcoded:
the node comes from `squeue` over ssh, matched on exact job names.

---
## NSC's efficiency killer (why profiles are 59 minutes)

NSC terminates jobs whose **moving-average power stays below 90 W** (idle is 52 W;
they have announced a rise to 100 W+). Exempt:

- the **first hour** of any job — which is exactly why every profile here is `00:59:59`;
- **NSC `interactive` jobs under 8 h** (`interactive --gpus=1 -t 04:00:00 ...`);
- jobs inside a **reservation** — `safe` (node[006,044,050,058-059]) and `devel`
  (node049) are both ACTIVE and usable by us, verified by actually running there;
- the CPU partition, and whitelisted projects.

A live demo cannot use the one-hour dodge: it idles between questions by design. So
the `percorso` profile sets `D_RESERVATION=safe`, and `bjob` now passes
`--reservation` whenever a profile declares one (shown in the launch banner and the
profile list as `res:<name>`).

**Measure, don't guess.** `sacct` cannot help — energy accounting is off on this
cluster, so `ConsumedEnergyRaw` is 0 for every job. Sample it live instead:

```bash
percorso-demo power 60            # one-shot: mean/min/max vs the floor
percorso-demo power --watch       # detached, one line per sample, through a demo
percorso-demo logs power -f
```

For any *other* job — you don't need to be inside its shell — `bjob power
<jobid> [seconds] [interval]` samples the same way via `srun --overlap`, from
any terminal. Both share the same sampler and floor/warn thresholds
(`berzelius-toolbox/bin/lib/power.sh`).

Measured on an idle reserved node: **52 W** — exactly NSC's stated idle level, so the
reading is the right quantity. What a running pipeline draws is still unmeasured;
capture it during the first full run with `--watch`.

All reservation nodes are **thin (A100 40 GB)**. Fine for the pipeline alone; one more
reason not to co-locate vLLM with it.

---
## Live demo against an EGG rosbag (percorso-demo)

Controlled stand-in for the robot: the bag replaces the sensor, everything else
(bridge, rolling buffer, mid-run event refresh, remote query) is the real path.

**Two jobs, two nodes.** Start the pipeline with the **`percorso`** bjob profile and
cosmos with **`cosmos-reason2`** as a *separate* job; they find each other through
`$PROJECT/.cosmos_url`. Do not use `daaam-cosmos` for the demo: it co-locates vLLM
and the pipeline on one GPU (vLLM at 0.75 utilisation, ~25% left for the pipeline),
which OOMs on 40 GB cards and survives on 80 GB ones. It is kept only as the paper
reproduction path.

The `percorso` profile also enters the container with the **demo** environment
applied (overlay sourced, demo lib on `PYTHONPATH`), unlike `daaam`, which gives you
the paper environment on purpose. So in a `percorso` shell what you type matches
what `percorso-demo` runs.

```bash
percorso-demo where                # where this tool and everything it touches lives
percorso-demo overlay              # ONE TIME: build the percorso_perception_ros overlay
percorso-demo doctor               # confirms DEMO code will run, not the paper code

# inside a SLURM job — ONE shell is enough. 'run' picks the params per mode,
# so this is the whole thing, one command each:
percorso-demo run bag batch_7      # mock test: local bag, no robot needed
percorso-demo run live             # real demo: robot pushes over 'stream', :9001

# 'stream'/'pipeline'/'bag' still exist individually for manual control —
# 'run' just calls them in the right order with the right params:
percorso-demo stream                # raw-TCP-push receiver alone, detaches, returns
percorso-demo pipeline              # perception + query bridge on :8100 (foreground)
percorso-demo bag batch_7           # play the bag HERE alone (--loop repeats)

percorso-demo status               # what is running on this node, and is it healthy
percorso-demo logs stream -f       # tail a detached service
percorso-demo stop all             # stop everything this tool started here
```

**One terminal is the design point.** The documented workflow is one tmux window
inside one `apptainer shell` inside one SLURM job, and a second terminal costs you
an ssh hop plus re-attaching to a private node. So anything that is a *daemon*
rather than something you watch — `stream`/`snapshot` — detaches by default, writing a pid and
a log to `$PROJECT/.percorso/run/<node>/`. `--fg` watches it anyway; `--bg`
detaches `pipeline`/`bag`, which are foreground by default because their output is
the thing you actually want to read.

The run directory is **per node** on purpose: compute nodes are ephemeral, so a
pidfile from yesterday's node describes a process that cannot exist, and treating
it as live would be worse than having no state at all.

A detached service is verified, not assumed: `stream` waits for the port to accept
a connection, `pipeline --bg` waits up to 180 s for `/status` (model load and
TensorRT warmup dominate). If the process dies during startup you get the log tail
and a non-zero exit, instead of a cheerful "started" for something already gone.

Then from your laptop:

```bash
ssh-helper login
ssh-helper connect <node> bridge        # returns immediately; no window to keep open
curl -s localhost:8100/status
curl -s -X POST localhost:8100/recent_video/ask \
     -H 'Content-Type: application/json' \
     -d '{"question":"what is the person doing?"}' | python3 -m json.tool
```

**Two ROS packages, distinct names.** The paper package is `daaam_ros` (built in
`ros2_ws/install`); the demo package is **`percorso_perception_ros`**, built in the
`percorso_overlay` workspace from the `percorso-perception-ros` worktree. Because
the names differ, sourcing order does not decide which one you get, and
`ros2 launch percorso_perception_ros …` cannot resolve to paper code.

It used to: the demo package was also called `daaam_ros` and won only by being
sourced last. That made three separate things silently order-dependent — the node,
its launch file, and its configs — and the configs did in fact leak.

What is still environment-selected is the Python lib `daaam` (via `PYTHONPATH`), but
that one fails loudly: the demo node imports a module the paper lib does not have.
`percorso-demo doctor` reports every layer regardless, so you never have to guess.

`pipeline` takes an optional *label* (default `live`) that only names the output
directory — it is not a batch, because with the live robot feed the bag is on the
robot instead of here. All
these commands work from inside the `apptainer shell` or outside it; the tool
detects which, since there is no apptainer binary inside to nest with.

`exit_after_clock:=false` is deliberate — when the bag ends the node stays alive so
the last 30 s remains queryable. Sim time freezes then, which is harmless.
