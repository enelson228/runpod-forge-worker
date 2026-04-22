import json
import os
import time

import requests
import runpod

# Configuration
FORGE_API_URL = "http://127.0.0.1:7860/sdapi/v1/txt2img"
CHECK_URL = "http://127.0.0.1:7860/sdapi/v1/memory"
CHECK_INTERVAL_SECONDS = float(os.getenv("FORGE_HEALTHCHECK_INTERVAL", "5"))
STARTUP_TIMEOUT_SECONDS = int(os.getenv("FORGE_STARTUP_TIMEOUT", "900"))
REQUEST_TIMEOUT_SECONDS = int(os.getenv("FORGE_REQUEST_TIMEOUT", "600"))
DEFAULT_MODEL = os.getenv("FORGE_MODEL_CHECKPOINT", "").strip()


def _build_payload(job_input):
    payload = {
        "prompt": job_input.get("prompt", "A beautiful sunset"),
        "negative_prompt": job_input.get("negative_prompt", ""),
        "steps": job_input.get("num_inference_steps", 30),
        "width": job_input.get("width", 1024),
        "height": job_input.get("height", 1024),
        "cfg_scale": job_input.get("guidance_scale", 7.5),
        "seed": job_input.get("seed", -1),
        "sampler_name": job_input.get("sampler_name", "Euler a"),
        "batch_size": job_input.get("batch_size", 1),
        "n_iter": job_input.get("n_iter", 1),
    }

    checkpoint = (job_input.get("model_checkpoint") or DEFAULT_MODEL or "").strip()
    if checkpoint:
        payload["override_settings"] = {"sd_model_checkpoint": checkpoint}

    return payload

def wait_for_api():
    """Wait for the Forge API to be ready."""
    print(
        f"Starting Forge API health check with timeout={STARTUP_TIMEOUT_SECONDS}s "
        f"interval={CHECK_INTERVAL_SECONDS}s..."
    )
    attempts = 0
    start_time = time.time()
    while time.time() - start_time < STARTUP_TIMEOUT_SECONDS:
        attempts += 1
        try:
            response = requests.get(CHECK_URL, timeout=5)
            if response.status_code < 500:
                print(f"Forge API is ready after {attempts} attempts.")
                return
            print(
                f"Forge health check returned status {response.status_code} "
                f"on attempt {attempts}."
            )
        except requests.exceptions.ConnectionError:
            if attempts % 10 == 0:
                print(f"Still waiting for Forge API... (Attempt {attempts})")
        except Exception as e:
            print(f"Health check encountered an error: {e}")

        time.sleep(CHECK_INTERVAL_SECONDS)

    raise TimeoutError(
        f"Forge API was not ready within {STARTUP_TIMEOUT_SECONDS} seconds."
    )

def handler(job):
    """
    The handler function that will be called by RunPod.
    """
    job_input = job.get("input") or {}
    payload = _build_payload(job_input)

    print(f"Processing job {job.get('id', 'unknown')} with Forge API...")
    try:
        response = requests.post(
            FORGE_API_URL,
            json=payload,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        result = response.json()

        images = result.get("images", [])
        print(
            f"Job {job.get('id', 'unknown')} completed. "
            f"Generated {len(images)} images."
        )

        return {
            "images": images,
            "parameters": result.get("parameters"),
            "info": _safe_json_loads(result.get("info")),
        }
    except requests.HTTPError as exc:
        details = _extract_error_details(response=exc.response)
        print(f"Forge request failed: {details}")
        return {"error": "Forge request failed", "details": details}
    except requests.RequestException as exc:
        print(f"Network error during job processing: {exc}")
        return {"error": "Network error while calling Forge", "details": str(exc)}
    except Exception as e:
        print(f"Error during job processing: {e}")
        return {"error": str(e)}


def _safe_json_loads(value):
    if not value:
        return None

    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return value


def _extract_error_details(response):
    if response is None:
        return "No HTTP response received from Forge."

    try:
        body = response.json()
    except ValueError:
        body = response.text

    return {
        "status_code": response.status_code,
        "body": body,
    }


if __name__ == "__main__":
    wait_for_api()
    print("Registering worker with RunPod Serverless...")
    runpod.serverless.start({"handler": handler})
