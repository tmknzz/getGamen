#!/usr/bin/env python3
"""Exercise the DEBUG app's real AppKit preflight/approved-quit path with an import."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

bundle = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="getGamen-quit-", dir="/private/tmp"))
env = os.environ.copy()
env.update(GETGAMEN_UI_TEST_ROOT=str(root), GETGAMEN_UI_CREATE_FIXTURE="1",
           GETGAMEN_UI_TEST_IMAGE=str(root / "source.png"))
process = subprocess.Popen([str(bundle / "Contents/MacOS/getGamen"), "--ui-quit-smoke"], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    stdout, stderr = process.communicate(timeout=35)
except subprocess.TimeoutExpired:
    process.kill()
    process.communicate()
    raise SystemExit(f"Termination did not finish within 35 seconds. Evidence retained: {root}")
assert process.returncode == 0, (process.returncode, stderr.decode(errors="replace"))
assert (root / "did-terminate").read_text() == str(process.pid)
documents = list((root / "documents").glob("*/document.json"))
assert len(documents) == 1, documents
originals = list(documents[0].parent.glob("original*"))
assert len(originals) == 1 and originals[0].read_bytes() == (root / "source.png").read_bytes()
outputs = list((root / "exports").glob("*.png"))
assert len(outputs) == 1 and outputs[0].stat().st_size > 0, outputs
print(json.dumps({"passed": True, "pid": process.pid, "evidence": str(root),
                  "historyOriginals": len(originals), "finishedExports": len(outputs)}, indent=2))
