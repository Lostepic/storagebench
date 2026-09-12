"""Exercise terminal prompts without running disk workloads."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time

SCRIPT = Path(__file__).resolve().parents[1] / "storagebench.sh"


def session(args, replies, expected, env):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", str(SCRIPT), *args], env)
    output = b""
    cursor = 0
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
            if replies and replies[0][0].encode() in output[cursor:]:
                _, answer = replies.pop(0)
                cursor = len(output)
                os.write(fd, (answer + "\n").encode())
        else:
            raise AssertionError(f"Prompt timeout: {output.decode(errors='replace')}")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == expected, output.decode(errors="replace")
        assert not replies, output.decode(errors="replace")
        return output.decode(errors="replace")
    finally:
        os.close(fd)
        if pid:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    target = root / "target with spaces"
    target.mkdir()
    binaries = root / "bin"
    binaries.mkdir()
    fio = binaries / "fio"
    fio.write_text('#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo fio-3.38; else exit 42; fi\n')
    fio.chmod(0o755)
    env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}")
    common = ["--profile", "quick", "--output", str(root / "results")]
    output = session(common, [("Select target", "nope"), ("Select target", "q")], 0, env)
    assert "OS/root filesystem" in output
    assert "Choose a listed number" in output
    # Root filesystem may be selected without ever starting a workload.
    session(common, [("Select target", "2"), ("Run benchmark?", "n")], 0, env)
    assert not (root / "results").exists()
    session(common, [("Select target", "c"), ("Existing directory path", str(target)),
                     ("Run benchmark?", "y")], 42, env)
    assert not list(target.iterdir()), "Failed workload left temporary files"
    # A detached process must not silently choose a disk or consume piped script input.
    result = subprocess.run(["bash", str(SCRIPT), *common], env=env,
                            stdin=subprocess.DEVNULL, capture_output=True, start_new_session=True)
    assert result.returncode != 0 and b"No terminal available" in result.stderr
print("Interactive target selection tests passed.")
