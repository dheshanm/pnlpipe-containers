# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

alias ls='ls --color=auto'

# FSL
export FSLDIR=/opt/fsl-6.0.7
export FSLOUTPUTTYPE=NIFTI_GZ
export PATH="$FSLDIR/share/fsl/bin:$PATH"

# FreeSurfer
export FREESURFER_HOME=/opt/freesurfer-8.1.0
# Default subjects dir in user's home (writable, small until used)
export SUBJECTS_DIR="$HOME/FS_SUBJECTS_DIR"
# Source FS setup on shell startup
if [ -f "${FREESURFER_HOME}/SetUpFreeSurfer.sh" ]; then
    # shellcheck disable=SC1091
    . "${FREESURFER_HOME}/SetUpFreeSurfer.sh"
fi

# ukftractography / Teem
export PATH="/opt/ukftractography/build/bin:/opt/ukftractography/build/UKFTractography-build/UKFTractography/bin:$PATH"

# ANTs
export ANTSPATH=/opt/ANTs/build/ANTS-build/Examples
export PATH="$ANTSPATH:/opt/ANTs/Scripts:$PATH"

# Conda envs
export PATH="/opt/conda/condabin:/opt/conda/envs/pnlpipe9/bin:$PATH"

# PNL repos and scripts
export PYTHONPATH="/opt/pnl/luigi-pnlpipe:${PYTHONPATH:-}"
export PATH="/opt/pnl/pnlNipype/scripts:$PATH"

export LANG=en_US.UTF-8