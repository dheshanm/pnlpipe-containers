#!/bin/bash

PREFIX=/opt/conda/envs/dmri_seg/
# export LD_LIBRARY_PATH=${PREFIX}/lib
${PREFIX}/bin/python /opt/pnl/CNN-Diffusion-MRIBrain-Segmentation/pipeline/dwi_masking.py $@

