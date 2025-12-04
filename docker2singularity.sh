export OUTPUT_DIR=<your_output_directory>
export CONTAINER_NAME=<your_docker_image_name:tag>

docker run -v /var/run/docker.sock:/var/run/docker.sock -v $OUTPUT_DIR:/output --privileged -t --rm quay.io/singularity/docker2singularity $CONTAINER_NAME