import json
import os
import sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_DATASETS_OFFLINE", "1")


_FAILURE_SENTINEL = b"VOXCPM2_FAILED\n"


def silence_process_output():
    """Keep dependency output off the runner pipes without ever restoring it."""
    failure_fd = None
    sink_fd = None
    try:
        failure_fd = os.dup(2)
        os.set_inheritable(failure_fd, False)
        sink_fd = os.open(os.devnull, os.O_WRONLY)
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(sink_fd, 1)
        os.dup2(sink_fd, 2)
        return failure_fd
    except BaseException:
        target_fd = failure_fd if failure_fd is not None else 2
        try:
            os.write(target_fd, _FAILURE_SENTINEL)
        finally:
            os._exit(1)
    finally:
        if sink_fd is not None:
            try:
                os.close(sink_fd)
            except OSError:
                pass


_FAILURE_FD = silence_process_output()


def close_failure_fd_in_fork_child():
    # Only the original helper process may write to the runner's sentinel pipe.
    # Native/model-library fork children must not keep that pipe alive.
    try:
        os.close(_FAILURE_FD)
    except OSError:
        pass


os.register_at_fork(after_in_child=close_failure_fd_in_fork_child)


def fail():
    # Reassert the sink in case a dependency replaced either process fd. The
    # saved non-inheritable error fd is used only for the fixed sentinel.
    try:
        sink_fd = os.open(os.devnull, os.O_WRONLY)
        try:
            os.dup2(sink_fd, 1)
            os.dup2(sink_fd, 2)
        finally:
            os.close(sink_fd)
    except BaseException:
        pass
    try:
        os.write(_FAILURE_FD, _FAILURE_SENTINEL)
    finally:
        try:
            os.close(_FAILURE_FD)
        finally:
            os._exit(1)


def reject():
    raise RuntimeError("invalid VoxCPM2 request")

try:
    request = json.load(sys.stdin)
    if request.get("load_denoiser") is not False or request.get("optimize") is not False:
        reject()
    seed = request.get("seed")
    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= (2 ** 63 - 1):
        reject()
    from voxcpm import VoxCPM
    import numpy as np
    import random
    import soundfile as sf
    import torch
    model = VoxCPM.from_pretrained(
        request["model_root"], local_files_only=True, load_denoiser=False,
        optimize=False, device="auto"
    )
    # VoxCPM 2.0.3 does not accept `seed` as a generate keyword. Seed every
    # RNG used by its inference stack immediately before generation instead.
    random.seed(seed)
    np.random.seed(seed % (2 ** 32))
    torch.manual_seed(seed)
    mps = getattr(torch, "mps", None)
    mps_backend = getattr(getattr(torch, "backends", None), "mps", None)
    if (mps is not None and callable(getattr(mps, "manual_seed", None))
            and mps_backend is not None
            and callable(getattr(mps_backend, "is_available", None))
            and mps_backend.is_available()):
        mps.manual_seed(seed)
    cuda = getattr(torch, "cuda", None)
    if (cuda is not None and callable(getattr(cuda, "is_available", None))
            and cuda.is_available()
            and callable(getattr(cuda, "manual_seed_all", None))):
        cuda.manual_seed_all(seed)
    wav = model.generate(
        text=request["text"], prompt_wav_path=request["prompt_wav_path"],
        prompt_text=request["reference_text"], reference_wav_path=request["reference_wav_path"],
        cfg_value=request["cfg_value"], inference_timesteps=request["inference_timesteps"]
    )
    sample_rate = int(model.tts_model.sample_rate)
    if sample_rate != 48000:
        reject()
    sf.write(request["output_file"], wav, sample_rate, subtype="PCM_16")
except BaseException:
    fail()
else:
    try:
        os.close(_FAILURE_FD)
    except OSError:
        os._exit(1)
