import os
import re
import sys
import time
import shutil
import codecs
import selectors
import subprocess
from dataclasses import dataclass
from typing import Optional, Sequence, Union, Mapping, Any
from collections import deque

_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)")


def _strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)


def _term_width(default: int = 120) -> int:
    try:
        return shutil.get_terminal_size(fallback=(default, 24)).columns
    except Exception:
        return default


def _truncate_with_ellipsis(s: str, width: int) -> str:
    if width <= 0:
        return ""
    if len(s) <= width:
        return s
    if width == 1:
        return "…"
    return s[: max(0, width - 1)] + "…"


def _clear_line() -> None:
    sys.stdout.write("\r\x1b[2K")


def _erase_rendered_block(rendered_count: int) -> None:
    if rendered_count <= 0:
        return

    for i in range(rendered_count):
        _clear_line()
        if i < rendered_count - 1:
            sys.stdout.write("\x1b[1A")  # up one line
    sys.stdout.flush()


@dataclass
class _StreamState:
    decoder: Any
    text_buf: str = ""       
    visual_line: str = ""   

    def feed_text(self, text: str) -> list[str]:
        events: list[str] = []
        self.text_buf += text

        i = 0
        n = len(self.text_buf)
        while i < n:
            ch = self.text_buf[i]
            if ch == "\r":
                self.visual_line = ""
                i += 1
            elif ch == "\n":
                s = _strip_ansi(self.visual_line).strip()
                if s:
                    events.append(s)
                self.visual_line = ""
                i += 1
            else:
                self.visual_line += ch
                i += 1

        self.text_buf = ""

        s_live = _strip_ansi(self.visual_line).strip()
        if s_live:
            events.append(s_live)

        return events

def run_and_log(
    cmd: Union[str, Sequence[str]],
    *,
    log_path: Optional[str] = None,
    shell: bool = True,
    env: Optional[Mapping[str, str]] = None,
    cwd: Optional[str] = None,
    fps: float = 60.0,
    encoding: str = "utf-8",
    errors: str = "replace",
    lines: int = 8,
    simple_output: bool = False,
) -> int:

    if simple_output:
        if log_path is not None:
            log_path = os.path.abspath(log_path)
        cmd = f"set -o pipefail; {cmd} |& tee {log_path}"
        result = subprocess.run(cmd, shell=shell, env=env, cwd=cwd, stdout=sys.stdout, stderr=sys.stderr)
        return result.returncode

    is_tty = bool(getattr(sys.stdout, "isatty", lambda: False)())
    lines = max(1, int(lines))

    frame_interval = 1.0 / max(1.0, fps)
    last_render_t = 0.0

    stdout_state = _StreamState(codecs.getincrementaldecoder(encoding)(errors=errors))
    stderr_state = _StreamState(codecs.getincrementaldecoder(encoding)(errors=errors))

    window: deque[str] = deque(maxlen=lines)
    rendered_count = 0

    proc = subprocess.Popen(
        cmd,
        shell=shell,
        env=env,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    assert proc.stdout is not None and proc.stderr is not None
    os.set_blocking(proc.stdout.fileno(), False)
    os.set_blocking(proc.stderr.fileno(), False)

    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ, data=("stdout", proc.stdout.fileno()))
    sel.register(proc.stderr, selectors.EVENT_READ, data=("stderr", proc.stderr.fileno()))

    def render_block(force: bool = False) -> None:
        nonlocal last_render_t, rendered_count
        if not is_tty:
            return

        now = time.monotonic()
        if not force and (now - last_render_t) < frame_interval:
            return

        width = _term_width()
        block_lines = [_truncate_with_ellipsis(s, max(0, width)) for s in list(window)]

        _erase_rendered_block(rendered_count)
        rendered_count = len(block_lines)

        if rendered_count > 0:
            for idx, line in enumerate(block_lines):
                sys.stdout.write(line)
                if idx < rendered_count - 1:
                    sys.stdout.write("\n")
            sys.stdout.flush()

        last_render_t = now

    def forward_to_terminal_linewise(which: str, decoded_text: str, carry: dict) -> None:
        key = f"{which}_partial"
        partial = carry.get(key, "")
        partial += decoded_text
        pieces = re.split(r"[\r\n]", partial)
        for line in pieces[:-1]:
            if line != "":
                if which == "stderr":
                    print(line, file=sys.stderr, flush=True)
                else:
                    print(line, file=sys.stdout, flush=True)
        carry[key] = pieces[-1]

    carry = {"stdout_partial": "", "stderr_partial": ""}

    def push_events(which: str, events: list[str]) -> bool:
        changed = False
        for s in events:
            s = s.strip()
            if not s:
                continue

            if which == "stderr":
                s = f"[stderr] {s}"
            window.append(s)
            changed = True
        return changed

    logf = open(log_path, "wb", buffering=0) if log_path else None
    try:
        open_streams = 2

        while open_streams > 0:
            if is_tty:
                now = time.monotonic()
                until_next = max(0.0, frame_interval - (now - last_render_t))
                timeout = min(until_next, 1.0)
            else:
                timeout = 1.0

            events = sel.select(timeout=timeout)

            if not events:
                render_block(force=False)
                continue

            for key, _mask in events:
                which, fd = key.data
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue

                if chunk == b"":
                    try:
                        sel.unregister(key.fileobj)
                    except Exception:
                        pass
                    open_streams -= 1
                    continue

                if logf:
                    logf.write(chunk)

                state = stdout_state if which == "stdout" else stderr_state
                decoded = state.decoder.decode(chunk)

                if is_tty:
                    new_events = state.feed_text(decoded)
                    if push_events(which, new_events):
                        render_block(force=False)
                else:
                    forward_to_terminal_linewise(which, decoded, carry)

        for which, state in (("stdout", stdout_state), ("stderr", stderr_state)):
            try:
                tail = state.decoder.decode(b"", final=True)
            except Exception:
                tail = ""
            if not tail:
                continue
            if is_tty:
                new_events = state.feed_text(tail)
                if push_events(which, new_events):
                    render_block(force=True)
            else:
                forward_to_terminal_linewise(which, tail, carry)

        if not is_tty:
            if carry["stdout_partial"]:
                print(carry["stdout_partial"], file=sys.stdout, flush=True)
            if carry["stderr_partial"]:
                print(carry["stderr_partial"], file=sys.stderr, flush=True)
    finally:
        if logf:
            logf.close()

    rc = proc.wait()

    if is_tty:
        _erase_rendered_block(rendered_count)

    return rc


# Example:
# rc = run_and_log(
#     build_cmd,
#     log_path="build.log",
#     shell=True,
#     env=env["ENV"],
#     lines=2,
# )
