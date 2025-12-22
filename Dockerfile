# syntax=docker/dockerfile:1.5
# Multi-stage optimized Dockerfile for PNL Pipeline Container (with Slicer)
# Uses minimal base image with controlled parallelization to avoid over-utilization
# Each Python environment builds with resource limits for stability
# Heavy software and envs installed under /opt for fast UID/GID remap at startup

# =============================================================================
# Global Arguments
# =============================================================================
ARG CMAKE_VER=3.31.0
ARG DCM2NIIX_REF=v1.0.20250506
ARG ANTS_REF=v2.6.2
ARG UKF_REF=v2.1
ARG FSL_SHORT=6.0.7
ARG FSL_VER=6.0.7.18
ARG FS_VER=8.1.0

ARG BUILD_JOBS_SMALL=2
ARG BUILD_JOBS_MEDIUM=4
ARG BUILD_DATE

# =============================================================================
# Base builder stage - minimal image with build tools
# =============================================================================
FROM redhat/ubi9-minimal:9.7 AS compiler-base

ARG CMAKE_VER
ARG TARGETARCH

RUN if [ "$TARGETARCH" != "amd64" ]; then \
        echo "ERROR: This container requires x86_64 architecture. Detected: $TARGETARCH"; \
        exit 1; \
    fi

RUN --mount=type=cache,target=/var/cache/dnf \
    microdnf install -y \
        wget ca-certificates \
        tar gzip bzip2 unzip \
        gcc gcc-c++ make patch \
        git \
        openssl-devel \
        libstdc++-static \
    && microdnf clean all

WORKDIR /build

# CMake
RUN set -e; \
    CMAKE_TGZ="cmake-${CMAKE_VER}-linux-x86_64.tar.gz"; \
    CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/${CMAKE_TGZ}"; \
    wget -q "$CMAKE_URL" -O "${CMAKE_TGZ}"; \
    tar -xzf "${CMAKE_TGZ}"; \
    mv "cmake-${CMAKE_VER}-linux-x86_64" "cmake"; \
    rm -f "${CMAKE_TGZ}"

# =============================================================================
# C++ Application Builders
# =============================================================================
FROM compiler-base AS dcm2niix-builder
ARG DCM2NIIX_REF
ARG BUILD_JOBS_SMALL
RUN git clone --depth 1 --branch "$DCM2NIIX_REF" https://github.com/rordenlab/dcm2niix.git && \
    /build/cmake/bin/cmake -S dcm2niix -B dcm2niix/build -DCMAKE_BUILD_TYPE=Release && \
    /build/cmake/bin/cmake --build dcm2niix/build --parallel ${BUILD_JOBS_SMALL}

FROM compiler-base AS ants-builder
ARG ANTS_REF
ARG BUILD_JOBS_MEDIUM
RUN git clone --depth 1 --branch "$ANTS_REF" https://github.com/ANTsX/ANTs.git && \
    /build/cmake/bin/cmake -S ANTs -B ANTs/build -DCMAKE_BUILD_TYPE=Release && \
    /build/cmake/bin/cmake --build ANTs/build --parallel ${BUILD_JOBS_MEDIUM}

FROM compiler-base AS ukf-builder
ARG UKF_REF
ARG BUILD_JOBS_MEDIUM
RUN --mount=type=cache,target=/var/cache/dnf \
    microdnf install -y \
        libX11-devel \
        libgfortran \
        mesa-libGL libSM libXrender libXt \
    && microdnf clean all
RUN git clone --depth 1 --branch "$UKF_REF" https://github.com/pnlbwh/ukftractography.git && \
    mkdir -p ukftractography/build && \
    /build/cmake/bin/cmake -S ukftractography -B ukftractography/build -DCMAKE_BUILD_TYPE=Release && \
    /build/cmake/bin/cmake --build ukftractography/build --parallel ${BUILD_JOBS_MEDIUM} --verbose

# =============================================================================
# Consolidated Python Environment Builder (installs into /opt/conda)
# =============================================================================
FROM compiler-base AS python-env-builder

COPY .condarc /root/.condarc

# Install Miniforge to /opt/conda
RUN --mount=type=cache,target=/tmp/download-cache \
    wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O Miniforge3.sh && \
    bash Miniforge3.sh -b -p /opt/conda && \
    rm -f Miniforge3.sh

ENV PATH="/opt/conda/bin:$PATH"

# Clone Python repositories (read-only, will live under /opt/pnl)
RUN --mount=type=cache,target=/root/.cache/git \
    git clone --depth 1 https://github.com/pnlbwh/pnlNipype.git && \
    git clone --depth 1 https://github.com/pnlbwh/luigi-pnlpipe.git && \
    git clone --depth 1 https://github.com/pnlbwh/HCPpipelines.git && \
    git clone --depth 1 https://github.com/pnlbwh/conversion.git && \
    git clone --depth 1 https://github.com/pnlbwh/CNN-Diffusion-MRIBrain-Segmentation.git && \
    git clone --depth 1 --single-branch --branch pnl https://github.com/pnlbwh/HD-BET.git && \
    git clone --depth 1 https://github.com/demianw/tract_querier.git

# Download CNN model
RUN --mount=type=cache,target=/tmp/download-cache \
    cd CNN-Diffusion-MRIBrain-Segmentation && \
    wget -q https://github.com/pnlbwh/CNN-Diffusion-MRIBrain-Segmentation/releases/download/v0.3/model_folder.tar.gz && \
    tar -xzf model_folder.tar.gz && rm -f model_folder.tar.gz

# Create environments (cached)
RUN --mount=type=cache,target=/root/.cache/pip --mount=type=cache,target=/opt/conda/pkgs \
    conda create -y -n pnlpipe9 -c conda-forge --override-channels python && \
    conda run -n pnlpipe9 python -m pip install -r pnlNipype/requirements.txt && \
    conda clean -y --all

RUN --mount=type=cache,target=/root/.cache/pip --mount=type=cache,target=/opt/conda/pkgs \
    conda create -y -n dmri_seg -c conda-forge --override-channels python=3.11 && \
    conda run -n dmri_seg python -m pip install scikit-image "git+https://github.com/pnlbwh/conversion.git" tensorflow==2.15.1 && \
    conda clean -y --all

RUN --mount=type=cache,target=/root/.cache/pip --mount=type=cache,target=/opt/conda/pkgs \
    conda create -y -n hd-bet -c conda-forge --override-channels python=3.9 && \
    conda run -n hd-bet python -m pip install HD-BET/ && \
    conda run -n hd-bet python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio && \
    conda clean -y --all

# HD-BET params into the installed package directory
RUN --mount=type=cache,target=/tmp/download-cache \
    HDBET_DIR="$(conda run -n hd-bet python -c 'import os, HD_BET; print(os.path.dirname(HD_BET.__file__))')" && \
    mkdir -p "${HDBET_DIR}/params" && \
    for i in 0 1 2 3 4; do \
        n=0; \
        until wget -q -O "${HDBET_DIR}/params/${i}.model" "https://zenodo.org/record/2540695/files/${i}.model"; do \
            n=$((n+1)); \
            if [ "$n" -ge 3 ]; then \
                echo "Failed to download ${i}.model after 3 attempts"; \
                exit 1; \
            fi; \
            sleep 2; \
        done; \
    done

RUN --mount=type=cache,target=/root/.cache/pip --mount=type=cache,target=/opt/conda/pkgs \
    conda create -y -n wma -c conda-forge --override-channels python=3.9 && \
    conda run -n wma python -m pip install "git+https://github.com/SlicerDMRI/whitematteranalysis.git" tract_querier/ plumbum && \
    conda clean -y --all

# =============================================================================
# FSL Builder
# =============================================================================
FROM redhat/ubi9-minimal:9.7 AS fsl-builder
ARG FSL_VER
ARG FSL_SHORT
RUN --mount=type=cache,target=/var/cache/dnf \
    microdnf install -y wget ca-certificates findutils python3 tar gzip && microdnf clean all
WORKDIR /build
COPY .condarc /root/.condarc
COPY fslinstaller.py.mgb /build/fslinstaller.py
RUN --mount=type=cache,target=/tmp/download-cache \
    wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/download-cache/Miniforge3.sh && \
    python3 fslinstaller.py -V "${FSL_VER}" -d "/build/fsl-${FSL_SHORT}" --miniconda /tmp/download-cache/Miniforge3.sh --cuda none --skip_ssl_verify --no_env && \
    ln -sfn eddy_cuda11.0 "/build/fsl-${FSL_SHORT}/share/fsl/bin/eddy_cuda" && \
    rm -f fslinstaller.py

# =============================================================================
# FreeSurfer Builder (from local RPM)
# =============================================================================
FROM redhat/ubi9-minimal:9.7 AS freesurfer-builder
ARG FS_VER
RUN --mount=type=cache,target=/var/cache/dnf \
    microdnf install -y \
        wget ca-certificates tar gzip unzip which findutils cpio \
        java-17-openjdk \
    && microdnf clean all

# tcsh (required by FreeSurfer)
RUN --mount=type=cache,target=/tmp/download-cache \
    set -e; \
    TCSH_PKG=tcsh-6.22.03-6.el9.x86_64.rpm && \
    wget -q https://dl.rockylinux.org/pub/rocky/9/devel/x86_64/os/Packages/t/${TCSH_PKG} -O /tmp/download-cache/${TCSH_PKG} && \
    rpm -ivh /tmp/download-cache/${TCSH_PKG}

WORKDIR /build

# Copy pre-downloaded FreeSurfer RPM from build context
# Place freesurfer-Rocky8-8.1.0-1.x86_64.rpm next to this Dockerfile
COPY freesurfer-Rocky8-8.1.0-1.x86_64.rpm /tmp/freesurfer.rpm

RUN set -e; \
    rpm2cpio /tmp/freesurfer.rpm | cpio -idmv; \
    mv "usr/local/freesurfer/${FS_VER}-1" "freesurfer-${FS_VER}"; \
    rm -rf usr /tmp/freesurfer.rpm; \
    export FREESURFER_HOME="/build/freesurfer-${FS_VER}"; \
    source "${FREESURFER_HOME}/SetUpFreeSurfer.sh"; \
    fs_install_mcr R2019b

# Apply FreeSurfer patch
COPY fs_patch/bin/fsr-getxopts /build/freesurfer-${FS_VER}/bin/fsr-getxopts
RUN chmod a+x /build/freesurfer-${FS_VER}/bin/fsr-getxopts

# =============================================================================
# Final runtime stage
# =============================================================================
FROM redhat/ubi9-minimal:9.7

LABEL org.opencontainers.image.authors="Tashrif Billah <tbillah@bwh.harvard.edu>"
LABEL org.opencontainers.image.description="PNL Pipeline Container with FSL, FreeSurfer, ANTs, dcm2niix, ukftractography, Python environments, and Slicer 5.8.1 + SlicerDMRI for White Matter Analysis"
LABEL org.opencontainers.image.url="https://github.com/pnlbwh/pnlpipe-containers"
LABEL org.opencontainers.image.source="https://github.com/pnlbwh/pnlpipe-containers"
LABEL org.opencontainers.image.vendor="Psychiatry Neuroimaging Laboratory, Brigham and Women's Hospital"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="PNL Pipeline Container"
LABEL org.opencontainers.image.created=${BUILD_DATE}

ARG CMAKE_VER
ARG FSL_SHORT
ARG FS_VER

ENV HOME=/home/pnlbwh \
    USER=pnlbwh \
    LANG=en_US.UTF-8 \
    TZ=America/New_York

# Enable Rocky Linux 9 BaseOS + AppStream repos so we can pull extra libs (incl. libnsl)
RUN printf '[rocky-baseos]\nname=Rocky Linux 9 BaseOS\nbaseurl=https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/rocky-baseos.repo \
    && printf '[rocky-appstream]\nname=Rocky Linux 9 AppStream\nbaseurl=https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/rocky-appstream.repo

# --- Slicer-related environment ------------------------------------------------
ENV SLICER_DIR=/opt/slicer \
    WM_USE_SLICER_PYTHON=1 \
    PYTHON=/opt/slicer/bin/PythonSlicer \
    PYTHONNOUSERSITE=1 \
    MPLCONFIGDIR=/tmp/mpl \
    QT_QPA_PLATFORM=xcb \
    XDG_RUNTIME_DIR=/tmp \
    XDG_DATA_HOME=/opt/slicer-data \
    XDG_CONFIG_HOME=/opt/slicer-config

ENV CTK_PLUGIN_PATH=/opt/extensions/qt-loadable-modules:/opt/slicer/lib/Slicer-5.8/qt-loadable-modules
ENV LD_LIBRARY_PATH=/opt/slicer/lib:/opt/slicer/lib/Slicer-5.8:/opt/extensions/lib:${LD_LIBRARY_PATH}

# Runtime deps
# First remove coreutils-single to avoid conflicts, then install packages
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm -e --nodeps coreutils-single || true \
    && microdnf install -y \
        wget ca-certificates tzdata findutils file \
        bzip2 unzip tar which vim git hostname \
        glibc-langpack-en \
        libgfortran \
        # GL / X11 / Qt stack
        mesa-libGL mesa-libGLU mesa-libEGL mesa-libGLES mesa-dri-drivers \
        libSM libICE \
        libX11 libXext libXrender libXt libXtst libxcrypt-compat \
        libXcomposite libXcursor libXdamage libXi libXrandr libXfixes \
        libXinerama libXScrnSaver \
        libxshmfence \
        # XCB / xkbcommon for Qt xcb plugin
        libxcb libX11-xcb \
        libxkbcommon libxkbcommon-x11 \
        xcb-util xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm \
        # headless X server
        xorg-x11-server-Xvfb xorg-x11-xauth \
        # NSS (libnss3)
        nss \
        # audio stubs
        alsa-lib pulseaudio-libs pulseaudio-libs-glib2 \
        # fonts + fontconfig + freetype
        fontconfig freetype dejavu-sans-fonts \
        # DBus
        dbus-libs \
        # **this is the important one for your current error**
        libnsl2 \
        # misc tools
        shadow-utils util-linux \
        libgomp bc perl perl-interpreter \
        procps-ng \
        coreutils \
    && ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && microdnf clean all

RUN set -eux; \
    for cand in /usr/lib64/libnsl.so.* /lib64/libnsl.so.*; do \
        if [ -e "$cand" ] && [ "${cand##*.}" != "1" ]; then \
            ln -sf "$cand" "$(dirname "$cand")/libnsl.so.1"; \
            break; \
        fi; \
    done || true

# Install tree directly from Rocky Linux (not available in UBI minimal repos)
RUN --mount=type=cache,target=/tmp/download-cache \
    set -e; \
    TREE_PKG=tree-1.8.0-10.el9.x86_64.rpm && \
    wget -q https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/t/${TREE_PKG} -O /tmp/download-cache/${TREE_PKG} && \
    rpm -ivh /tmp/download-cache/${TREE_PKG}

# tcsh (required by FreeSurfer)
RUN --mount=type=cache,target=/tmp/download-cache \
    set -e; \
    TCSH_PKG=tcsh-6.22.03-6.el9.x86_64.rpm && \
    wget -q https://dl.rockylinux.org/pub/rocky/9/devel/x86_64/os/Packages/t/${TCSH_PKG} -O /tmp/download-cache/${TCSH_PKG} && \
    rpm -ivh /tmp/download-cache/${TCSH_PKG}

# ------------------------------------------------------------------------------
# Slicer 5.8.1 + SlicerDMRI + WMA (Slicer's Python) + headless wrapper
# ------------------------------------------------------------------------------

# Copy pre-downloaded Slicer tarball from build context
# Place Slicer-5.8.1-linux-amd64.tar.gz next to this Dockerfile
COPY Slicer-5.8.1-linux-amd64.tar.gz /tmp/Slicer-5.8.1-linux-amd64.tar.gz

# Core Slicer 5.8.1 install from local tarball
RUN set -eux; \
    mkdir -p /opt; \
    cd /opt; \
    tar -xzf /tmp/Slicer-5.8.1-linux-amd64.tar.gz; \
    mv Slicer-5.8.1-linux-amd64 slicer; \
    rm -f /tmp/Slicer-5.8.1-linux-amd64.tar.gz; \
    ln -sf /opt/slicer/Slicer /usr/local/bin/Slicer

# whitematteranalysis into Slicer's Python (in addition to conda wma env)
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    /opt/slicer/bin/PythonSlicer -m pip install --no-cache-dir --upgrade pip; \
    if ! /opt/slicer/bin/PythonSlicer -m pip install --no-cache-dir "whitematteranalysis==0.4.3"; then \
        /opt/slicer/bin/PythonSlicer -m pip install --no-cache-dir \
            "git+https://github.com/SlicerDMRI/whitematteranalysis@master"; \
    fi

# Prepare dirs and write the SlicerDMRI install script
RUN set -eux; \
    mkdir -p "${XDG_RUNTIME_DIR}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" /tmp/mpl \
        /opt/cli /opt/extensions/qt-loadable-modules /opt/extensions/lib; \
cat >/tmp/install_ext.py <<'PY'
import slicer
em = slicer.app.extensionsManagerModel()
em.interactive = False
em.updateExtensionsMetadataFromServer(True, True)
ok = em.downloadAndInstallExtensionByName("SlicerDMRI", True, True)
print("Install SlicerDMRI ->", ok)
slicer.util.exit(0 if ok else 2)
PY

# Run Slicer headlessly to install SlicerDMRI, then expose FiberTractMeasurements
RUN set -eux; \
    # Make sure runtime env is sane for Qt/X11
    export LD_LIBRARY_PATH="/usr/lib64:/lib64:/opt/slicer/lib:/opt/slicer/lib/Slicer-5.8:/opt/extensions/lib:"; \
    export QT_QPA_PLATFORM=xcb; \
    export XDG_RUNTIME_DIR=/tmp; \
    mkdir -p "$XDG_RUNTIME_DIR"; \
    # This is the important part: DISPLAY must be EXPORTED
    export DISPLAY=":99"; \
    # Start Xvfb and give it a moment to come up
    Xvfb "$DISPLAY" -screen 0 1280x1024x24 -ac +extension GLX +render -noreset & \
    xvfb_pid=$!; \
    sleep 3; \
    set +e; \
    /opt/slicer/Slicer \
        --no-splash \
        --no-main-window \
        --exit-after-startup \
        --disable-modules \
        --python-script /tmp/install_ext.py; \
    status=$?; \
    set -e; \
    kill "$xvfb_pid" || true; \
    rm -f /tmp/install_ext.py; \
    if [ "$status" -ne 0 ]; then \
        echo "ERROR: SlicerDMRI installation failed (exit $status)" >&2; \
        exit "$status"; \
    fi; \
    FTM=""; \
    for root in \
        "/opt/slicer-data/NA-MIC" \
        "/opt/slicer-config/NA-MIC" \
        /root /opt/slicer-data /opt/slicer-config; do \
        [ -d "$root" ] || continue; \
        FTM=$(find "$root" -type f -name FiberTractMeasurements \
            -path "*Extensions-*/SlicerDMRI*/lib/Slicer-5.8/cli-modules/*" \
            -print -quit 2>/dev/null || true); \
        [ -n "$FTM" ] && break; \
    done; \
    if [ -z "$FTM" ]; then \
        FTM=$(find / -xdev -type f -name FiberTractMeasurements \
            -path "*Extensions-*/SlicerDMRI*/lib/Slicer-5.8/cli-modules/*" \
            -print -quit 2>/dev/null || true); \
    fi; \
    [ -n "$FTM" ] && [ -f "$FTM" ] || { echo "ERROR: FiberTractMeasurements not found"; exit 90; }; \
    install -m 0755 "$FTM" /opt/cli/FiberTractMeasurements; \
    EXT_LIB_ROOT="$(dirname "$(dirname "$FTM")")"; \
    if [ -d "$EXT_LIB_ROOT/qt-loadable-modules" ]; then \
        cp -a "$EXT_LIB_ROOT/qt-loadable-modules/." /opt/extensions/qt-loadable-modules/; \
    fi; \
    cp -a "$EXT_LIB_ROOT/." /opt/extensions/lib/ || true
	

# SlicerHeadless wrapper: always runs Slicer with Xvfb + launcher env
RUN cat >/usr/local/bin/SlicerHeadless <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export QT_QPA_PLATFORM=xcb
# Let Slicer launcher tell us what to export (PATH, libs, etc.)
eval "$(/opt/slicer/Slicer --launcher-show-set-environment)"
DISPLAY="${DISPLAY:-:99}"
Xvfb "$DISPLAY" -screen 0 1280x1024x24 &
xvfb_pid=$!
trap "kill $xvfb_pid || true" EXIT
export DISPLAY
exec /opt/slicer/Slicer --no-splash --no-main-window "$@"
EOF
RUN chmod +x /usr/local/bin/SlicerHeadless

# ------------------------------------------------------------------------------
# Existing PNL stack
# ------------------------------------------------------------------------------

# Create non-root user (home will remain small)
RUN useradd -m -s /bin/bash -d /home/pnlbwh pnlbwh
WORKDIR /home/pnlbwh

# Copy Python envs and repositories into /opt
COPY --from=python-env-builder /opt/conda /opt/conda
COPY --from=python-env-builder /build/pnlNipype /opt/pnl/pnlNipype
COPY --from=python-env-builder /build/luigi-pnlpipe /opt/pnl/luigi-pnlpipe
COPY --from=python-env-builder /build/HCPpipelines /opt/pnl/HCPpipelines
COPY --from=python-env-builder /build/conversion /opt/pnl/conversion
COPY --from=python-env-builder /build/CNN-Diffusion-MRIBrain-Segmentation /opt/pnl/CNN-Diffusion-MRIBrain-Segmentation
COPY --from=python-env-builder /build/HD-BET /opt/pnl/HD-BET
COPY --from=python-env-builder /build/tract_querier /opt/pnl/tract_querier

# Copy compiled/built software into /opt or /usr/local/bin
COPY --from=dcm2niix-builder /build/dcm2niix/build/bin/dcm2niix /usr/local/bin/dcm2niix
COPY --from=fsl-builder /build/fsl-${FSL_SHORT} /opt/fsl-${FSL_SHORT}
COPY --from=freesurfer-builder /build/freesurfer-${FS_VER} /opt/freesurfer-${FS_VER}
COPY --from=ukf-builder /build/ukftractography /opt/ukftractography
COPY --from=ants-builder /build/ANTs /opt/ANTs

# Ensure broad read/execute on software directories (keep owned by root)
RUN chmod -R a+rX /opt && \
    git config --system --add safe.directory '*'

# User shell configuration and helper scripts
COPY .bashrc /home/pnlbwh/.bashrc
COPY .condarc /home/pnlbwh/.condarc
RUN chown pnlbwh:pnlbwh /home/pnlbwh/.bashrc /home/pnlbwh/.condarc

COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*

COPY startup.sh /startup.sh
RUN chmod +x /startup.sh && mkdir -p /home/pnlbwh/bin && chown pnlbwh:pnlbwh /home/pnlbwh/bin

# Make conda base binaries + Slicer + CLI visible
ENV PATH="/opt/slicer/bin:/opt/cli:/opt/conda/bin:$PATH"

ENTRYPOINT ["/startup.sh"]