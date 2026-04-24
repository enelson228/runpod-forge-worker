FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime

# Build Timestamp: 2026-04-22 00:00
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip setuptools==69.5.1 wheel
RUN pip install --no-cache-dir runpod requests
RUN pip install --no-cache-dir xformers==0.0.27 --index-url https://download.pytorch.org/whl/cu121

RUN mkdir -p /opt/stable-diffusion-webui-forge
WORKDIR /opt/stable-diffusion-webui-forge

RUN git clone --recursive https://github.com/lllyasviel/stable-diffusion-webui-forge.git . && \
    git submodule update --init --recursive

RUN pip install --no-cache-dir --no-build-isolation git+https://github.com/openai/CLIP.git && \
    pip install --no-cache-dir --no-build-isolation open_clip_torch && \
    if [ -f requirements_versions.txt ]; then pip install --no-cache-dir --no-build-isolation -r requirements_versions.txt; fi && \
    if [ -f requirements.txt ]; then pip install --no-cache-dir --no-build-isolation -r requirements.txt; fi

RUN if [ -d packages_3rdparty ]; then \
    for d in packages_3rdparty/* ; do \
        if [ -f "$d/setup.py" ] || [ -f "$d/pyproject.toml" ]; then \
            pip install --no-cache-dir --no-build-isolation "$d"; \
        fi; \
    done; \
    fi

# Clone repos that Forge expects to bootstrap at runtime.
RUN mkdir -p repositories && \
    git clone https://github.com/lllyasviel/huggingface_guess.git repositories/huggingface_guess && \
    cd repositories/huggingface_guess && \
    git checkout 84826248b49bb7ca754c73293299c4d4e23a548d && \
    cd /opt/stable-diffusion-webui-forge && \
    git clone https://github.com/salesforce/BLIP.git repositories/BLIP && \
    cd repositories/BLIP && \
    git checkout 48211a1594f1321b00f14c9f7a5b4813144b2fb9

# Keep model weights out of the container image. Mount or populate this path externally.
RUN mkdir -p /opt/models/Stable-diffusion && \
    ln -sfn /opt/models/Stable-diffusion /opt/stable-diffusion-webui-forge/models/Stable-diffusion

COPY handler.py /opt/stable-diffusion-webui-forge/handler.py
COPY start.sh /opt/stable-diffusion-webui-forge/start.sh
RUN chmod +x /opt/stable-diffusion-webui-forge/start.sh

ENV WEBUI_ARGS="--nowebui --api --skip-torch-cuda-test --skip-python-version-check --skip-install --xformers --listen --port 7860 --disable-console-progressbars"
ENV HF_HOME="/tmp/huggingface"
ENV TRANSFORMERS_CACHE="/tmp/huggingface/transformers"
ENV FORGE_MODEL_DIR="/opt/models/Stable-diffusion"
ENV FORGE_MODEL_CHECKPOINT=""
ENV FORGE_HF_CACHE_ROOT="/runpod-volume/huggingface-cache/hub"

CMD ["/opt/stable-diffusion-webui-forge/start.sh"]
