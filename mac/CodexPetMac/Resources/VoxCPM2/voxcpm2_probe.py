import json
import os
import sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_DATASETS_OFFLINE", "1")

def fail():
    sys.stderr.write("VOXCPM2_FAILED\n")
    raise SystemExit(1)

def reject():
    raise RuntimeError("invalid VoxCPM2 probe")

try:
    request = json.load(sys.stdin)
    from voxcpm import VoxCPM
    if not os.path.isdir(request["snapshot_root"]):
        reject()
    if not callable(getattr(VoxCPM, "from_pretrained", None)):
        reject()
    model = VoxCPM.from_pretrained(
        request["model_root"], local_files_only=True, load_denoiser=False,
        optimize=False, device="auto"
    )
    sample_rate = int(model.tts_model.sample_rate)
    device = str(model.tts_model.device).lower()
    if sample_rate != 48000:
        reject()
    if device.startswith("mps"):
        device_kind = "mps"
    elif device.startswith("cuda"):
        device_kind = "cuda"
    elif device.startswith("cpu"):
        device_kind = "cpu"
    else:
        reject()
    with open(request["probe_output"], "w", encoding="utf-8") as handle:
        json.dump({"schema": 1, "device": device_kind, "sample_rate": sample_rate}, handle)
except BaseException:
    fail()
