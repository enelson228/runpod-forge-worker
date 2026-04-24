#!/bin/bash
set -euo pipefail

MODEL_DIR="${FORGE_MODEL_DIR:-/opt/models/Stable-diffusion}"
MODEL_DOWNLOADS="${FORGE_MODEL_DOWNLOADS:-}"
HF_CACHE_ROOT="${FORGE_HF_CACHE_ROOT:-/runpod-volume/huggingface-cache/hub}"

echo "Starting Forge WebUI in API mode..."
echo "WEBUI_ARGS=${WEBUI_ARGS:-unset}"
echo "FORGE_STARTUP_TIMEOUT=${FORGE_STARTUP_TIMEOUT:-900}"
echo "FORGE_REQUEST_TIMEOUT=${FORGE_REQUEST_TIMEOUT:-600}"
echo "TRANSFORMERS_CACHE=${TRANSFORMERS_CACHE:-unset}"
echo "FORGE_MODEL_DIR=${MODEL_DIR}"
echo "FORGE_HF_MODEL_REPO=${FORGE_HF_MODEL_REPO:-unset}"
echo "FORGE_HF_MODEL_FILE=${FORGE_HF_MODEL_FILE:-unset}"

# Force Forge to skip all environment preparation and installation
# This prevents the long 'pip install' wait you saw in the logs
export SKIP_VENV=1
export PIP_SKIP_INTERNET_CHECK=1
mkdir -p "${HF_HOME:-/tmp/huggingface}" "${TRANSFORMERS_CACHE:-/tmp/huggingface/transformers}" "${MODEL_DIR}"

find_cached_snapshot_dir() {
    local repo_id="$1"
    local cache_name
    local repo_root
    local ref_file
    local snapshot

    cache_name="${repo_id//\//--}"
    repo_root="${HF_CACHE_ROOT}/models--${cache_name}"
    ref_file="${repo_root}/refs/main"

    if [[ -f "${ref_file}" ]]; then
        snapshot="$(<"${ref_file}")"
        if [[ -n "${snapshot}" && -d "${repo_root}/snapshots/${snapshot}" ]]; then
            printf '%s\n' "${repo_root}/snapshots/${snapshot}"
            return 0
        fi
    fi

    if compgen -G "${repo_root}/snapshots/*" > /dev/null; then
        find "${repo_root}/snapshots" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1
        return 0
    fi

    return 1
}

link_cached_model() {
    local repo_id="${FORGE_HF_MODEL_REPO:-}"
    local requested_file="${FORGE_HF_MODEL_FILE:-}"
    local snapshot_dir
    local source
    local filename

    [[ -z "${repo_id}" ]] && return 1

    snapshot_dir="$(find_cached_snapshot_dir "${repo_id}")" || {
        echo "Cached model repo not found for ${repo_id} under ${HF_CACHE_ROOT}"
        return 1
    }

    if [[ -n "${requested_file}" ]]; then
        source="${snapshot_dir}/${requested_file}"
        if [[ ! -f "${source}" ]]; then
            echo "Cached model file not found: ${source}"
            return 1
        fi
    else
        source="$(find "${snapshot_dir}" -maxdepth 1 -type f \( -name '*.safetensors' -o -name '*.ckpt' \) | sort | head -n 1)"
        if [[ -z "${source}" ]]; then
            echo "No checkpoint file found in cached snapshot ${snapshot_dir}"
            return 1
        fi
    fi

    filename="$(basename "${source}")"
    ln -sfn "${source}" "${MODEL_DIR}/${filename}"
    export FORGE_MODEL_CHECKPOINT="${filename}"
    echo "Linked cached model ${filename} from ${source}"
    return 0
}

download_model() {
    local filename="$1"
    local url="$2"
    local destination="${MODEL_DIR}/${filename}"
    local partial="${destination}.partial"

    if [[ -f "${destination}" ]]; then
        echo "Model already present: ${filename}"
        return
    fi

    echo "Downloading model ${filename} from ${url}"
    rm -f "${partial}"
    curl -L --fail --retry 5 --retry-delay 3 --output "${partial}" "${url}"
    mv "${partial}" "${destination}"
}

sync_models() {
    local manifest
    local line
    local filename
    local url
    local first_filename=""

    # Support a simpler single MODEL_URL variable to avoid UI issues with '='
    if [[ -n "${MODEL_URL:-}" && -z "${MODEL_DOWNLOADS}" ]]; then
        echo "Using MODEL_URL for single model download."
        url="${MODEL_URL}"
        filename=$(basename "${url%%\?*}")
        if [[ "${filename}" != *.safetensors && "${filename}" != *.ckpt ]]; then
            filename="model.safetensors"
        fi
        download_model "${filename}" "${url}"
        export FORGE_MODEL_CHECKPOINT="${filename}"
        return
    fi

    if link_cached_model; then
        return
    fi

    if [[ -z "${MODEL_DOWNLOADS}" ]]; then
        echo "No cached model or download manifest configured; assuming models are already available."
        return
    fi

    manifest="${MODEL_DOWNLOADS//$'\n'/,}"
    for line in ${manifest//,/ }; do
        [[ -z "${line}" ]] && continue
        if [[ "${line}" != *=* ]]; then
            echo "Invalid FORGE_MODEL_DOWNLOADS entry: ${line}"
            exit 1
        fi

        filename="${line%%=*}"
        url="${line#*=}"
        [[ -z "${filename}" || -z "${url}" ]] && {
            echo "Invalid FORGE_MODEL_DOWNLOADS entry: ${line}"
            exit 1
        }

        if [[ -z "${first_filename}" ]]; then
            first_filename="${filename}"
        fi

        download_model "${filename}" "${url}"
    done

    if [[ -z "${FORGE_MODEL_CHECKPOINT:-}" && -n "${first_filename}" ]]; then
        export FORGE_MODEL_CHECKPOINT="${first_filename}"
        echo "Defaulting FORGE_MODEL_CHECKPOINT to ${FORGE_MODEL_CHECKPOINT}"
    fi
}

sync_models

cleanup() {
    if [[ -n "${FORGE_PID:-}" ]] && kill -0 "${FORGE_PID}" 2>/dev/null; then
        echo "Stopping Forge process ${FORGE_PID}..."
        kill "${FORGE_PID}" 2>/dev/null || true
        wait "${FORGE_PID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

python launch.py ${WEBUI_ARGS} --skip-prepare-environment &
FORGE_PID=$!
echo "Forge started with PID ${FORGE_PID}"

echo "Launching RunPod Handler..."
python handler.py
