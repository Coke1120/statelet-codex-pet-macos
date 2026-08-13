import json
import os
import sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
try:
    request = json.load(sys.stdin)
    from voxcpm import VoxCPM
    if not os.path.isdir(request["snapshot_root"]):
        raise RuntimeError()
    if not callable(getattr(VoxCPM, "from_pretrained", None)):
        raise RuntimeError()
except BaseException:
    sys.stderr.write("VOXCPM2_FAILED\n")
    raise SystemExit(1)
