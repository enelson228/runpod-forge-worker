# Forge RunPod Worker (SDXL)

This directory contains the configuration for a RunPod Serverless worker running **Stable Diffusion WebUI Forge**.

## Image Strategy
This image is intentionally slimmed down for RunPod Serverless cold starts:
- Forge code and Python dependencies are baked into the image.
- Model weights are **not** baked into the image.
- Checkpoints can be pulled into `/opt/models/Stable-diffusion` at startup with `FORGE_MODEL_DOWNLOADS`.

## Deployment Instructions

### 1. Build the Image
From this directory, run:
```bash
export IMAGE_NAME=ghcr.io/enelson228/runpod-forge-worker:latest
docker build -t "$IMAGE_NAME" .
```
*Note: This still takes time because of Forge and PyTorch dependencies, but it no longer bakes multi-GB checkpoints into the image.*

### 2. Push to Registry
```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u enelson228 --password-stdin
docker push "$IMAGE_NAME"
```

Make sure the GHCR package is visible to RunPod:
- easiest path: publish the package as **public**
- if you keep it private, configure RunPod registry credentials for `ghcr.io`

You can also let GitHub Actions publish the image automatically:
- workflow: `.github/workflows/publish-ghcr.yml`
- image: `ghcr.io/enelson228/runpod-forge-worker:latest`
- pushes to `main` and manual `workflow_dispatch` both publish the image

### 3. Create RunPod Endpoint
1. Go to [RunPod Serverless](https://www.runpod.io/console/serverless).
2. Create a New Endpoint.
3. Image Name: `ghcr.io/enelson228/runpod-forge-worker:latest`.
4. **Container Disk:** 20GB is usually enough for the slim image itself. Increase it only if you copy models into the worker filesystem at startup.
5. **GPU Support:** A100, A6000, or L40 recommended.
6. **Active Workers:** 0 (Autoscale).
7. Set `FORGE_MODEL_DOWNLOADS` to the checkpoint(s) you want the worker to fetch on cold start.
   *Example for Juggernaut XL v9:*
   `Juggernaut-XL-v9.safetensors=https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors`

### 4. Update Infinity Site
Update your `SD_ENDPOINT_ID` in your environment variables with the new ID provided by RunPod.

## Technical Details
- **API Port:** 7860
- **Handler:** `handler.py` (Maps RunPod input to Forge `/sdapi/v1/txt2img`)
- **Args:** `--nowebui --api --xformers --skip-torch-cuda-test`
- **Model Directory:** `/opt/models/Stable-diffusion`
- **Model Download Manifest:** `FORGE_MODEL_DOWNLOADS`

## Behavior Notes
- The container starts Forge first and waits for the local API to become reachable before registering with RunPod.
- Startup will fail after `FORGE_STARTUP_TIMEOUT` seconds instead of waiting forever. Default: `900`.
- The handler now checks HTTP status codes from Forge and returns structured error details when generation fails.
- Default checkpoint selection is controlled by `FORGE_MODEL_CHECKPOINT`.
- If `FORGE_MODEL_CHECKPOINT` is unset, the worker will not force a checkpoint override and Forge will use its current default.
- The image no longer includes `sd_xl_base_1.0.safetensors` or `realvisxl_v50.safetensors`; provide them separately if you still want them.
- If `FORGE_MODEL_DOWNLOADS` is set, the startup script downloads each missing checkpoint before Forge launches.
- `FORGE_MODEL_DOWNLOADS` format is comma-separated `filename=url` pairs.
- If `FORGE_MODEL_CHECKPOINT` is unset, the first downloaded filename becomes the default checkpoint automatically.

## Suggested Serverless Model Delivery
For `0` active workers, the practical pattern is:
- Host your checkpoint files at stable direct-download URLs, such as Hugging Face, Cloudflare R2, S3, or another object store.
- Set `FORGE_MODEL_DOWNLOADS` on the RunPod endpoint, for example:

```bash
FORGE_MODEL_DOWNLOADS=realvisxl_v50.safetensors=https://your-bucket.example/realvisxl_v50.safetensors
```

- If you want more than one model available:

```bash
FORGE_MODEL_DOWNLOADS=realvisxl_v50.safetensors=https://your-bucket.example/realvisxl_v50.safetensors,sd_xl_base_1.0.safetensors=https://your-bucket.example/sd_xl_base_1.0.safetensors
```

- Keep `FORGE_MODEL_CHECKPOINT` empty to default to the first downloaded model, or set it explicitly.

## Supported Job Input
The worker accepts the usual txt2img fields plus a few convenience options:

```json
{
  "input": {
    "prompt": "cinematic portrait of an astronaut",
    "negative_prompt": "blurry, low quality",
    "num_inference_steps": 30,
    "guidance_scale": 7.5,
    "width": 1024,
    "height": 1024,
    "seed": -1,
    "sampler_name": "Euler a",
    "batch_size": 1,
    "n_iter": 1,
    "model_checkpoint": "realvisxl_v50.safetensors"
  }
}
```
