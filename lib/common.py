"""common.py - shared helpers for bleakleymm scripts.

Imported by transcode.py, fixity.py, metadata.py, package.py, validate.py, rawcooked.py.
"""
from __future__ import annotations

import logging
import shutil
import signal
import sys


# Suffixes that mark a file as a sidecar / generated output rather than a source.
# Scripts iterating a directory skip files matching these.
SIDECAR_SUFFIXES = (
    ".access.mp4",
    ".mediainfo.txt",
    ".mediainfo.json",
    ".mediatrace.xml",
    ".md5.txt",
    ".sha1.txt",
    ".sha256.txt",
    ".sha512.txt",
    ".crc32.txt",
    ".framemd5",
    ".log",
)


def get_logger(name: str = "tbm") -> logging.Logger:
    """Return a stderr logger with short level-prefixed formatting."""
    log = logging.getLogger(name)
    if not log.handlers:
        h = logging.StreamHandler(sys.stderr)
        h.setFormatter(logging.Formatter("[%(levelname)s] %(message)s"))
        log.addHandler(h)
        log.setLevel(logging.INFO)
        log.propagate = False
    return log


def install_sigterm_trap() -> None:
    """Exit cleanly (status 143) on SIGTERM."""
    def _on_term(_signum, _frame):
        get_logger().warning("terminated")
        sys.exit(143)
    signal.signal(signal.SIGTERM, _on_term)


def is_sidecar(name: str) -> bool:
    """True if filename ends with a known sidecar/output suffix."""
    return name.endswith(SIDECAR_SUFFIXES)


def require(cmd: str) -> None:
    """Assert a command exists on PATH; exit 127 if not."""
    if shutil.which(cmd) is None:
        get_logger().error(f"required tool not found: {cmd}")
        sys.exit(127)
