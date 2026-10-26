"""Runs a status line command the way Kimi Code 2.3 does on macOS, for run-tests.sh:
`sh -c COMMAND` in a session of its own (Node's `detached`), the JSON snapshot on stdin,
only the first stdout line kept, and the whole process group killed at the timeout.
Prints "<exit code>\t<milliseconds>\t<first line>" ("timeout" for the exit code).

    python3 -I render.py COMMAND JSON [TIMEOUT_MS]
"""
import os
import signal
import subprocess
import sys
import time

command, payload = sys.argv[1], sys.argv[2]
timeout = int(sys.argv[3]) / 1000 if len(sys.argv) > 3 else 5.0
env = dict(os.environ, KIMI_CODE_STATUS_LINE="1")

start = time.perf_counter()
child = subprocess.Popen(["sh", "-c", command], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env, start_new_session=True)
try:
    out, _ = child.communicate(payload.encode(), timeout=timeout)
    code = str(child.returncode)
except subprocess.TimeoutExpired:
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    out, _ = child.communicate()
    code = "timeout"
ms = (time.perf_counter() - start) * 1000
line = out.decode("utf-8", "replace").split("\n")[0].rstrip()
sys.stdout.write(f"{code}\t{ms:.0f}\t{line}\n")
