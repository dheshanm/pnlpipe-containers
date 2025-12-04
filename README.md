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

## Building outside MGB Environment

To build the Docker image outside of the MGB environment, remove the `channel_alias: https://anaconda.mgb.org/` line from the `.condarc` file before building the Docker image.

Also remove the following line at line 3118 in `fslinstaller.py.mgb`:

```python
condarc += 'channel_alias: https://anaconda.mgb.org/\n'
```

This line forces the use of MGB's Anaconda proxy, which might not be accessible outside the MGB network.
