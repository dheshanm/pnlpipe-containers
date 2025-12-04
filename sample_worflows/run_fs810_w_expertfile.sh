#!/bin/bash 
# Original at /data/pnlx/Collaborators/EDCRP/PANDAS/scripts/run_fs8.1.0_with_run.sh

set -euo pipefail
trap 'echo "Script failed at line $LINENO"; exit 1' ERR

# Check dependencies
for cmd in rsync mkdir rmdir; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it before running this script." >&2
        exit 2
    fi
done


# ===== EDIT BELOW THIS LINE =====

export SUBJECT_ID="sub-$1"
export SESSION_ID="ses-01"
# set to e.g. "01" to use _run-01_T1w.nii.gz
export RUN_ID="2"   # e.g. RUN_ID="01"

export HOLDING_DIR="/PHShome/dm1447/scratch/fs_810_workspace"
export TAG="fs810_multi_part_expert_patched"

export SUBJECTS_DIR="/data/pnlx/Collaborators/EDCRP/PANDAS/BIDS/rawdata"
export PIPELINE_OUTPUT_DIR="/data/pnlx/Collaborators/EDCRP/PANDAS/BIDS/derivatives/pnlpipe/$TAG"
export FS_LICENSE="/data/pnlx/home/kc1031/MRI_ROOT/license.txt"

# Use double quotes to wrap expert file options
export EXPERT_FILE_CONTENTS="\
mris_inflate -n 55
"

export SINGULARITY_BIN="/apps/released/gcc-toolchain/gcc-4.x/singularity/singularity-3.7.0/bin/singularity"
export SIF="/data/pnlx/home/dm1447/pnlpipe-optimized_fs810-p-2025-11-24-6598b4679d6c.sif"
export NUM_THREADS=8

export GHGRP_GROUP="BWH-PNL-G"

# ===== EDIT ABOVE THIS LINE =====

export SIF_HOME="/home/pnlbwh"
umask u=rwx,g=rwx,o=rx

# Check Singularity binary exists
if [ ! -x "$SINGULARITY_BIN" ]; then
    echo "Error: Singularity binary not found or not executable at: $SINGULARITY_BIN" >&2
    exit 1
fi

IDENTIFIER="${SUBJECT_ID}-${SESSION_ID}"
export HOLDING_DIR="${HOLDING_DIR}_${USER}_$(date +%s)_${IDENTIFIER}"

PIPELINE_OUTPUT_DIR="$PIPELINE_OUTPUT_DIR/$SUBJECT_ID/$SESSION_ID/anat"
FS_OUTPUT_DIR="$PIPELINE_OUTPUT_DIR/fs8.1.0"
# Skip if output already exists
if [ -d "$FS_OUTPUT_DIR" ]; then
    echo "Output directory already exists for subject $SUBJECT_ID, session $SESSION_ID at:"
    echo "  $FS_OUTPUT_DIR"
    echo "Skipping processing."
    exit 0
fi

# Logging
echo "Running FreeSurfer Singularity container..."
echo "Subject: $SUBJECT_ID, Session: $SESSION_ID"
if [ -n "${RUN_ID:-}" ]; then
    echo "Using T1 run: run-${RUN_ID}"
else
    echo "Using T1 without run tag"
fi
echo "License: $FS_LICENSE"
echo "Output: $PIPELINE_OUTPUT_DIR"
echo "Container: $SIF"
echo "HOLDING_DIR: $HOLDING_DIR"

export SUBJECT_DIR="${SUBJECTS_DIR}/${SUBJECT_ID}/${SESSION_ID}"
export T1W_IMAGE="${SUBJECT_DIR}/anat/${SUBJECT_ID}_${SESSION_ID}_run-${RUN_ID}_T1w.nii.gz"

# Check if input T1w image exists
if [ ! -f "$T1W_IMAGE" ]; then
    echo "Error: T1-weighted image not found at:"
    echo "  $T1W_IMAGE"
    echo "subject: $SUBJECT_ID, session: $SESSION_ID, run: ${RUN_ID:-<none>}" >&2
    exit 1
else
    echo "Found T1-weighted image at $T1W_IMAGE"
fi

# Check container + license
for file in "$SIF" "$FS_LICENSE"; do
    if [ ! -f "$file" ]; then
        echo "Error: Required file not found: $file" >&2
        exit 1
    fi
done

# Copy necessary data to holding directory
mkdir -p "$HOLDING_DIR/BIDS/rawdata/$SUBJECT_ID/$SESSION_ID/anat"

T1W_BASENAME="$(basename "$T1W_IMAGE")"
T1W_HOLDING_PATH="$HOLDING_DIR/BIDS/rawdata/$SUBJECT_ID/$SESSION_ID/anat/$T1W_BASENAME"

echo "Copying T1-weighted image to holding directory:"
echo "  $T1W_IMAGE -> $T1W_HOLDING_PATH"
rsync -ah "$T1W_IMAGE" "$T1W_HOLDING_PATH"

OUTPUT_DIR="$HOLDING_DIR/BIDS/derivatives/$TAG"
mkdir -p "$OUTPUT_DIR"

# MPLCONFIGDIR to silence warnings
MPLCONFIGDIR="$HOLDING_DIR/matplotlib_config"
mkdir -p "$MPLCONFIGDIR"

echo "======================================================"
echo "=== Axis Align and Centering ==="
echo "======================================================"

AXIS_ALIGNED_T1W_HOLDING_PARENT_PATH="$OUTPUT_DIR/$SUBJECT_ID/${SESSION_ID}/anat"
AXIS_ALIGNED_T1W_HOLDING_FNAME="${SUBJECT_ID}_${SESSION_ID}_run-${RUN_ID:-}_desc-Xc_T1w"

mkdir -p "$AXIS_ALIGNED_T1W_HOLDING_PARENT_PATH"

$SINGULARITY_BIN exec --cleanenv --containall \
    --env MPLCONFIGDIR=$MPLCONFIGDIR \
    --bind $HOLDING_DIR:$HOLDING_DIR \
    $SIF bash -c "\
        export HOME=$SIF_HOME; \
        export PNLPIPE_TMPDIR=$HOLDING_DIR/tmp; \
        source $SIF_HOME/.bashrc; \
        cd \"$AXIS_ALIGNED_T1W_HOLDING_PARENT_PATH\" && \
        /opt/pnl/pnlNipype/scripts/align.py -i \"$T1W_HOLDING_PATH\" -o \"$AXIS_ALIGNED_T1W_HOLDING_FNAME\" \
    "

AXIS_ALIGNED_T1W_HOLDING_PATH="$AXIS_ALIGNED_T1W_HOLDING_PARENT_PATH/$AXIS_ALIGNED_T1W_HOLDING_FNAME.nii.gz"

echo "Axis-aligned T1w image at: $AXIS_ALIGNED_T1W_HOLDING_PATH"

# Copy License file to holding directory
export HOLDING_LICENSE_DIR="$HOLDING_DIR/license.txt"
rsync -ah "$FS_LICENSE" "$HOLDING_LICENSE_DIR"

# Write expert file to holding directory
export EXPERT_FILE="$HOLDING_DIR/expert_file.txt"
echo -e "$EXPERT_FILE_CONTENTS" > "$EXPERT_FILE"

echo "Starting FreeSurfer processing for $IDENTIFIER"

echo "======================================================"
echo "=== AUTORECON1 - with EXPERT FILE ==="
echo "======================================================"

$SINGULARITY_BIN exec --cleanenv --containall \
    --env MPLCONFIGDIR=$MPLCONFIGDIR \
    --bind $HOLDING_DIR:$HOLDING_DIR \
    --bind $HOLDING_LICENSE_DIR:/opt/freesurfer-8.1.0/.license \
    --bind $EXPERT_FILE:$EXPERT_FILE \
    $SIF bash -c "\
        export HOME=$SIF_HOME; \
        source $SIF_HOME/.bashrc; \
        recon-all -s \"$IDENTIFIER\" -i \"$AXIS_ALIGNED_T1W_HOLDING_PATH\" -sd \"$OUTPUT_DIR\" -parallel -openmp \"${NUM_THREADS}\" -autorecon1 -expert \"$EXPERT_FILE\" \
    "

cp "$OUTPUT_DIR/$IDENTIFIER/mri/T1.mgz" "$OUTPUT_DIR/$IDENTIFIER/mri/brainmask.mgz"
cp "$OUTPUT_DIR/$IDENTIFIER/mri/T1.mgz" "$OUTPUT_DIR/$IDENTIFIER/mri/brainmask.auto.mgz"

echo "======================================================"
echo "=== AUTORECON2 ==="
echo "======================================================"

$SINGULARITY_BIN exec --cleanenv --containall \
    --env MPLCONFIGDIR=$MPLCONFIGDIR \
    --bind $HOLDING_DIR:$HOLDING_DIR \
    --bind $HOLDING_LICENSE_DIR:/opt/freesurfer-8.1.0/.license \
    $SIF bash -c "\
        export HOME=$SIF_HOME; \
        source $SIF_HOME/.bashrc; \
        recon-all -s \"$IDENTIFIER\" -sd \"$OUTPUT_DIR\" -parallel -openmp \"${NUM_THREADS}\" -autorecon2 \
    "

echo "======================================================"
echo "=== AUTORECON3 - SUBFIELDS ==="
echo "======================================================"

$SINGULARITY_BIN exec --cleanenv --containall \
    --env MPLCONFIGDIR=$MPLCONFIGDIR \
    --bind $HOLDING_DIR:$HOLDING_DIR \
    --bind $HOLDING_LICENSE_DIR:/opt/freesurfer-8.1.0/.license \
    $SIF bash -c "\
        export HOME=$SIF_HOME; \
        source $SIF_HOME/.bashrc; \
        recon-all -s \"$IDENTIFIER\" -sd \"$OUTPUT_DIR\" -parallel -openmp \"${NUM_THREADS}\" -autorecon3 -subfields \
    "

echo "======================================================"
echo "=== Moving results back to original data directory ==="
echo "======================================================"

# Define session output dir and move results back
SESSION_OUTPUT_DIR="$OUTPUT_DIR/$IDENTIFIER"

mkdir -p "$FS_OUTPUT_DIR"

echo "Moving results from $SESSION_OUTPUT_DIR to $FS_OUTPUT_DIR"
rsync -rL --no-perms --no-owner --no-group "$SESSION_OUTPUT_DIR/" "$FS_OUTPUT_DIR/"

echo "Copying Axis-Aligned T1w image to output directory"
cp "$AXIS_ALIGNED_T1W_HOLDING_PATH" "$PIPELINE_OUTPUT_DIR/"

chgrp -R $GHGRP_GROUP "$PIPELINE_OUTPUT_DIR"
chmod -R g+rw "$PIPELINE_OUTPUT_DIR"

# Clean up
rm -rf "$HOLDING_DIR"

echo "======================================================"
echo "=== FreeSurfer processing completed successfully  ==="
echo "======================================================"


