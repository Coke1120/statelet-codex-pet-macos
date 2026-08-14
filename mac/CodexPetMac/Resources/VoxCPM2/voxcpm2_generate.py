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
    raise RuntimeError("invalid VoxCPM2 request")

try:
    request = json.load(sys.stdin)
    if request.get("load_denoiser") is not False or request.get("optimize") is not False:
        reject()
    from voxcpm import VoxCPM
    import soundfile as sf
    model = VoxCPM.from_pretrained(
        request["model_root"], local_files_only=True, load_denoiser=False,
        optimize=False, device="auto"
    )
    wav = model.generate(
        text=request["text"], prompt_wav_path=request["prompt_wav_path"],
        prompt_text=request["reference_text"], reference_wav_path=request["reference_wav_path"],
        cfg_value=request["cfg_value"], inference_timesteps=request["inference_timesteps"],
        seed=request["seed"]
    )
    sample_rate = int(model.tts_model.sample_rate)
    if sample_rate != 48000:
        reject()
    sf.write(request["output_file"], wav, sample_rate, subtype="PCM_16")
except BaseException:
    fail()
