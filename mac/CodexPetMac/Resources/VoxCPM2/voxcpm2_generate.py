import json
import os
import sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

def fail():
    sys.stderr.write("VOXCPM2_FAILED\n")
    raise SystemExit(1)

try:
    request = json.load(sys.stdin)
    if request.get("load_denoiser") is not False or request.get("optimize") is not False:
        fail()
    from voxcpm import VoxCPM
    import soundfile as sf
    model = VoxCPM.from_pretrained(
        request["snapshot_root"], local_files_only=True, load_denoiser=False,
        optimize=False, device="auto"
    )
    wav = model.generate(
        text=request["text"], prompt_wav_path=request["reference_file"],
        prompt_text=request["reference_text"], reference_wav_path=request["reference_file"],
        cfg_value=request["cfg_value"], inference_timesteps=request["inference_timesteps"],
        seed=request["seed"]
    )
    sf.write(request["output_file"], wav, 48000, subtype="PCM_16")
except BaseException:
    fail()
