#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_USER="pnlbwh"
TARGET_HOME="/home/${TARGET_USER}"

# Accept multiple env var names for convenience
want_uid="${PNL_UID:-${PUID:-}}"
want_gid="${PNL_GID:-${PGID:-}}"
want_gids="${PNL_GIDS:-${PGIDS:-}}"

# Validate numeric input if provided
if [[ -n "${want_uid}" && ! "${want_uid}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PNL_UID/PUID must be numeric. Got: ${want_uid}" >&2
    exit 1
fi
if [[ -n "${want_gid}" && ! "${want_gid}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PNL_GID/PGID must be numeric. Got: ${want_gid}" >&2
    exit 1
fi
if [[ -n "${want_gids}" ]]; then
    IFS=',' read -ra gids_arr <<< "${want_gids}"
    for gid in "${gids_arr[@]}"; do
        if [[ ! "${gid}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: PNL_GIDS/PGIDS must be a comma-separated list of numeric GIDs. Got: ${gid}" >&2
            exit 1
        fi
    done
fi

cur_uid="$(id -u "${TARGET_USER}")"
cur_gid="$(id -g "${TARGET_USER}")"

changed=0

# Adjust primary group if requested
if [[ -n "${want_gid}" && "${want_gid}" != "${cur_gid}" ]]; then
    if getent group "${want_gid}" >/dev/null 2>&1; then
        grp_name="$(getent group "${want_gid}" | cut -d: -f1)"
        usermod -g "${grp_name}" "${TARGET_USER}"
    else
        groupmod -g "${want_gid}" "${TARGET_USER}"
    fi
    cur_gid="${want_gid}"
    changed=1
fi

# Add user to additional groups if requested
if [[ -n "${want_gids}" ]]; then
    IFS=',' read -ra gids_arr <<< "${want_gids}"
    for gid in "${gids_arr[@]}"; do
        if getent group "${gid}" >/dev/null 2>&1; then
            grp_name="$(getent group "${gid}" | cut -d: -f1)"
        else
            grp_name="pnlgrp${gid}"
            groupadd -g "${gid}" "${grp_name}"
        fi
        usermod -aG "${grp_name}" "${TARGET_USER}"
    done
fi

# Adjust user UID if requested
if [[ -n "${want_uid}" && "${want_uid}" != "${cur_uid}" ]]; then
    if getent passwd "${want_uid}" >/dev/null 2>&1; then
        echo "ERROR: A user with UID ${want_uid} already exists. Choose a different PNL_UID/PUID." >&2
        exit 1
    fi
    usermod -u "${want_uid}" "${TARGET_USER}"
    cur_uid="${want_uid}"
    changed=1
fi

# Fix ownership only for the home directory (now small)
if [[ "${changed}" = "1" ]]; then
    chown -R "${cur_uid}:${cur_gid}" "${TARGET_HOME}" || true
fi

# Run the requested command (or a login shell) as the target user
if [[ $# -gt 0 ]]; then
    exec runuser -u "${TARGET_USER}" -- bash -lc "source ~/.bashrc && $*"
else
    exec runuser -u "${TARGET_USER}" -- bash -l
fi