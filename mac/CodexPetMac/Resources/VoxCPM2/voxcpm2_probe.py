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
else:
    try:
        os.close(_FAILURE_FD)
    except OSError:
        os._exit(1)
