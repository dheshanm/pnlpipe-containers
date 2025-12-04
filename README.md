# PNLPIPE Singularity Container

Build with Docker using the included `Dockerfile`. Once built, convert the Docker image to a Singularity image using the provided `docker2singularity.sh` script.

## Usage

```bash
export SIF_IMAGE=<path_to_your_singularity_image>.sif
singularity shell --cleanenv --containall $SIF_IMAGE
export HOME=/home/pnlbwh
export PNLPIPE_TMPDIR=/data/pnlx/home/dm1447/tmp
cd
source .bashrc
```
