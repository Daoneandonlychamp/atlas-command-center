#!/usr/bin/env python3
import sys
import os
import json
from pathlib import Path
import numpy as np

# Suppress noisy warnings on stderr/stdout
os.environ["PYTHONWARNINGS"] = "ignore"

# ATLAS passes the model directory in, because only the app knows where the
# user pointed it. Falling back to the default download location keeps the
# worker runnable by hand for debugging.
ATLAS_SUPPORT = Path.home() / "Library/Application Support/ATLAS"

MODEL_PATH = Path(os.environ.get(
    "ATLAS_TTS_MODEL_PATH",
    ATLAS_SUPPORT / "Models/tts/model",
))
SAMPLES_DIR = Path(os.environ.get(
    "ATLAS_TTS_SAMPLES_DIR",
    ATLAS_SUPPORT / "Models/tts/samples/humanization",
))

def send_event(obj):
    print(json.dumps(obj), flush=True)

def parse_duration_sec(dur_val):
    if isinstance(dur_val, (int, float)):
        return float(dur_val)
    s = str(dur_val).strip()
    if ":" in s:
        parts = s.split(":")
        if len(parts) == 3:
            h, m, sec = parts
            return float(h) * 3600.0 + float(m) * 60.0 + float(sec)
        elif len(parts) == 2:
            m, sec = parts
            return float(m) * 60.0 + float(sec)
    try:
        return float(s)
    except Exception:
        return 0.0

def main():
    if not MODEL_PATH.exists():
        send_event({"event": "error", "error": f"Model path not found: {MODEL_PATH}"})
        sys.exit(1)

    try:
        from mlx_audio.audio_io import write as audio_write
        from mlx_audio.tts.utils import load_model
        from mlx_audio.utils import load_audio

        model = load_model(model_path=str(MODEL_PATH))

        # Pre-load Lewis + Onyx reference audio files
        references = {}
        ref_mappings = {
            "conversational": "lewis_onyx_blend_conversational.wav",
            "mission": "lewis_onyx_blend_mission.wav",
            "wakeup": "lewis_onyx_blend_wakeup.wav",
            "warning": "lewis_onyx_blend_mission.wav"
        }

        min_samples = int(model.sample_rate * 5.25)

        for mode_key, ref_filename in ref_mappings.items():
            ref_path = SAMPLES_DIR / ref_filename
            if ref_path.exists():
                arr = np.asarray(load_audio(str(ref_path), sample_rate=model.sample_rate))
                if arr.size < min_samples:
                    repeats = int(np.ceil(min_samples / arr.size))
                    arr = np.tile(arr, repeats)[:min_samples]
                references[mode_key] = arr
            else:
                send_event({"event": "warning", "message": f"Reference file missing: {ref_path}"})

        # Send ready event once model and references are fully loaded
        send_event({
            "event": "ready",
            "model": "chatterbox-turbo-4bit",
            "sample_rate": int(model.sample_rate),
            "loaded_references": list(references.keys())
        })

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                req = json.loads(line)
            except Exception as e:
                send_event({"event": "error", "error": f"Invalid JSON line: {e}"})
                continue

            action = req.get("action", "synthesize")

            if action == "ping":
                send_event({"event": "pong"})
                continue
            elif action == "shutdown":
                send_event({"event": "shutdown_ack"})
                break
            elif action == "synthesize":
                req_id = req.get("id", "req")
                text = req.get("text", "")
                mode = req.get("mode", "conversational")
                output_path = req.get("output_path", "")
                max_tokens = req.get("max_tokens", 500)

                if not text or not output_path:
                    send_event({"event": "error", "id": req_id, "error": "Missing text or output_path"})
                    continue

                ref_audio = references.get(mode)
                if ref_audio is None:
                    # Fallback to conversational reference if mode is missing
                    ref_audio = list(references.values())[0] if references else None

                if ref_audio is None:
                    send_event({"event": "error", "id": req_id, "error": "No reference audio available"})
                    continue

                try:
                    # Ensure parent directory exists for output WAV
                    os.makedirs(os.path.dirname(output_path), exist_ok=True)

                    result = next(
                        model.generate(
                            text=text,
                            ref_audio=ref_audio,
                            temperature=0.7,
                            repetition_penalty=1.25,
                            top_p=0.95,
                            max_tokens=max_tokens,
                            verbose=False,
                        )
                    )

                    audio_write(
                        output_path,
                        np.asarray(result.audio),
                        result.sample_rate,
                        format="wav",
                    )

                    dur_sec = parse_duration_sec(getattr(result, "audio_duration", 0.0))

                    send_event({
                        "event": "completed",
                        "id": req_id,
                        "output_path": output_path,
                        "duration": float(dur_sec),
                        "sample_rate": int(result.sample_rate)
                    })
                except Exception as e:
                    send_event({"event": "error", "id": req_id, "error": str(e)})
            else:
                send_event({"event": "error", "error": f"Unknown action: {action}"})

    except Exception as e:
        send_event({"event": "error", "error": f"Worker crashed during initialization: {e}"})
        sys.exit(1)

if __name__ == "__main__":
    main()
