#!/bin/bash
set -euo pipefail

MODEL_DIR="${FORGE_MODEL_DIR:-/opt/models/Stable-diffusion}"
MODEL_DOWNLOADS="${FORGE_MODEL_DOWNLOADS:-}"

echo "Starting Forge WebUI in API mode..."
echo "WEBUI_ARGS=${WEBUI_ARGS:-unset}"
echo "FORGE_STARTUP_TIMEOUT=${FORGE_STARTUP_TIMEOUT:-900}"
echo "FORGE_REQUEST_TIMEOUT=${FORGE_REQUEST_TIMEOUT:-600}"
echo "TRANSFORMERS_CACHE=${TRANSFORMERS_CACHE:-unset}"
echo "FORGE_MODEL_DIR=${MODEL_DIR}"

# Force Forge to skip all environment preparation and installation
# This prevents the long 'pip install' wait you saw in the logs
export SKIP_VENV=1
export PIP_SKIP_INTERNET_CHECK=1
mkdir -p "${HF_HOME:-/tmp/huggingface}" "${TRANSFORMERS_CACHE:-/tmp/huggingface/transformers}" "${MODEL_DIR}"

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

    if [[ -z "${MODEL_DOWNLOADS}" ]]; then
        echo "FORGE_MODEL_DOWNLOADS is unset; assuming models are already available."
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

python launch.py ${WEBUI_ARGS} --skip-prepare-environment --api-log &
FORGE_PID=$!
echo "Forge started with PID ${FORGE_PID}"

echo "Launching RunPod Handler..."
python handler.py
