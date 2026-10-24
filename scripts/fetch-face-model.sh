#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib, urllib.request
from pathlib import Path
target = Path('Vendor/faces/sface.onnx')
expected = '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79'
def valid(path):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected
target.parent.mkdir(parents=True, exist_ok=True)
if not valid(target):
    cached = Path('.dev/people-eval/models/face_recognition_sface_2021dec.onnx')
    if valid(cached): target.write_bytes(cached.read_bytes())
    else:
        url = 'https://media.githubusercontent.com/media/opencv/opencv_zoo/48b10fa505aeb51fbd127fc60a5c660040e823b7/models/face_recognition_sface/face_recognition_sface_2021dec.onnx'
        with urllib.request.urlopen(url, timeout=90) as response: target.write_bytes(response.read())
    if not valid(target): raise SystemExit('Face model checksum mismatch')
print('Verified pinned SFace model')
PY
