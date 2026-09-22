## start a new job

Check active jobs:

squeue -u $USER 

srun --pty --jobid <job_id> /bin/bash

## test run for coda dataset (DAAAM)

export PROJECT=/proj/rpl-soro/users/$USER

# Open a separate IDE terminal for each long-running command.

apptainer shell --nv \
    -B $PROJECT/ros2_ws:/ros2_ws \
    -B $PROJECT/rosbags:/rosbags \
    $PROJECT/containers/daaam.sif

source /ros2_ws/setup_daaam.sh
export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH

ros2 bag play /ros2_ws/data/CODa/coda_0_with_depth_20260410_110731.bag \
    --clock -p \
    --qos-profile-overrides-path ~/.tf_overrides.yaml

export CODA_ROOT_DIR=/ros2_ws/data/CODa
ros2 launch daaam_ros dataloader_coda_with_depth.launch.yaml \
    sequence:=0 \
    dataset_path:=${CODA_ROOT_DIR} \
    bag_path:=${CODA_ROOT_DIR}/coda_0_with_depth.bag \
    depth_source:=3d_raw_estimated

ros2 launch daaam_ros coda_daaam_hydra.launch.yaml scene:=coda_sequence_0

---
## Export rosbag for EGG Dataset

python3 /ros2_ws/tools/create_egg_bag.py \
    --batch-dir /ros2_ws/data/EGG-Dataset/batch_2 \
    --output /ros2_ws/data/EGG-Dataset/bags/egg_batch_2_full.bag


## EGG dataset (HC-DAAAM, bjob IDE workflow)

bjob connect <job_id> auto


## EGG dataset (HC-DAAAM, manual)

export PROJECT=/proj/rpl-soro/users/$USER

apptainer shell --nv \
    -B $PROJECT/ros2_ws:/ros2_ws \
    -B $PROJECT/rosbags:/rosbags \
    $PROJECT/containers/daaam.sif

source /ros2_ws/setup_daaam.sh
export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH

export BATCH_NAME=batch_1
export COSMOS_URL=http://node088:8000/v1

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

# Do not kill the launch immediately after the bag ends. Wait for shutdown logs:
# "Saved corrections", "Saved final DSG state", and "[Shutdown] Cosmos HOI task wait complete".
# The matching run logs are written beside output/egg at /ros2_ws/src/daaam/output/logs/<timestamp>.

## Manual group_events (if HOI processing was skipped or Cosmos was unreachable during the run)

export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/out_YYYYMMDD_HHMMSS  # update to actual run dir
export COSMOS_URL=$(cat $PROJECT/.cosmos_url)

python3 -c "
from pathlib import Path
from daaam.human_reason import group_events
group_events(Path('${OUTPUT_DIR}'), base_url='${COSMOS_URL}', model='cosmos-reason2', api_key='EMPTY')
"

## Query / reasoning

export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/merged_egg  # update to actual run dir

python3 /ros2_ws/src/daaam/scripts/demo_query.py \
--dsg-path ${OUTPUT_DIR}/dsg.json \
--hoi-output-dir ${OUTPUT_DIR} \
--model-name gpt-5.4-mini

## Merge multiple batch outputs into a single queryable result

python3 /ros2_ws/src/daaam/scripts/merge_dsgs.py \
/ros2_ws/src/daaam/output/egg/egg_batch_1_out_20260511_185452 \
/ros2_ws/src/daaam/output/egg/egg_batch_2_out_20260511_190616 \
/ros2_ws/src/daaam/output/egg/egg_batch_3_out_20260511_195728 \
/ros2_ws/src/daaam/output/egg/egg_batch_4_out_20260511_200644 \
/ros2_ws/src/daaam/output/egg/egg_batch_5_out_20260511_202114 \
/ros2_ws/src/daaam/output/egg/egg_batch_6_out_20260511_203841 \
/ros2_ws/src/daaam/output/egg/egg_batch_7_out_20260511_211651 \
--output /ros2_ws/src/daaam/output/egg/merged_egg


## Rerun export
export OUTPUT_DIR=/ros2_ws/src/daaam/output/egg/out_20260521_142808  # update to actual run dir

python3 /ros2_ws/src/daaam/scripts/export_rerun_output.py \
  --output-dir ${OUTPUT_DIR} \
  --no-spawn \
  --rrd ${OUTPUT_DIR}/daaam_output.rrd