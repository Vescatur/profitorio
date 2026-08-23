#!/usr/bin/env python3
"""Drive a running Factorio server over RCON.

Verifying runtime behaviour means asking the live game, and RCON is the only way
in without a GUI: `/silent-command` runs arbitrary Lua and `rcon.print` hands the
answer back. Source-RCON is a four-field binary frame, so this is stdlib `socket`
rather than a dependency -- tools/setup/requirements.txt carries exactly one, and that
one earns it.

The console takes ONE line. It splits the command name on the first whitespace,
and a newline counts, so multi-line Lua comes back as `Unknown command
"silent-command`. Blocks read from stdin are therefore flattened to a single
line. Whole-line `--` comments are dropped on the way, so a harness file can be
commented normally; a TRAILING comment still swallows the rest of the block,
because there is no way to tell one from a `--` inside a string.

Connection details come from the state file `tools/check/probe.ps1` writes, so
neither has to be told the port twice.

Usage:
    powershell tools/check/probe.ps1 -Action start
    echo '/silent-command rcon.print(game.tick)' | python tools/check/probe_client.py
    python tools/check/probe_client.py < harness.lua
    powershell tools/check/probe.ps1 -Action stop

Blocks in stdin are separated by a line containing only `---`.

Stdlib only.
"""

import argparse
import json
import socket
import struct
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STATE = Path(__file__).resolve().parent / ".verify" / "rcon.json"


def state_for(instance=None):
    """Where probe.ps1 wrote this instance's connection details.

    Mirrors tools/lib/instance.ps1. None means the shared install, whose state
    lives beside this script rather than under .factorio/.
    """
    if not instance:
        return STATE
    return REPO / ".factorio" / instance / "state" / "rcon.json"

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2

# An empty-string password is accepted by the protocol but not by the server, so
# a missing state file has to fail loudly rather than connect anonymously.
class RconError(RuntimeError):
    pass


class Rcon:
    """One authenticated RCON connection."""

    def __init__(self, host, port, password, timeout=15):
        self.socket = socket.create_connection((host, port), timeout=timeout)
        self.socket.settimeout(timeout)
        self.request_id = 0
        self._send(SERVERDATA_AUTH, password)
        # Auth answers with an empty RESPONSE_VALUE and then an AUTH_RESPONSE,
        # and only the id distinguishes them: -1 means the password was wrong.
        while True:
            request_id, _, _ = self._receive()
            if request_id == -1:
                raise RconError("RCON authentication failed (wrong password)")
            if request_id == self.request_id:
                return

    def close(self):
        self.socket.close()

    def command(self, line):
        self._send(SERVERDATA_EXECCOMMAND, line)
        return self._receive()[2]

    def _send(self, packet_type, body):
        self.request_id += 1
        payload = struct.pack("<ii", self.request_id, packet_type) + body.encode("utf8") + b"\x00\x00"
        self.socket.sendall(struct.pack("<i", len(payload)) + payload)

    def _receive(self):
        size = struct.unpack("<i", self._read(4))[0]
        data = self._read(size)
        request_id, packet_type = struct.unpack("<ii", data[:8])
        return request_id, packet_type, data[8:-2].decode("utf8", "replace")

    def _read(self, count):
        chunks = b""
        while len(chunks) < count:
            chunk = self.socket.recv(count - len(chunks))
            if not chunk:
                raise RconError("RCON connection closed mid-frame")
            chunks += chunk
        return chunks


def load_state(path=STATE):
    if not path.exists():
        raise RconError(f"No server state at {path}. Run tools/check/probe.ps1 -Action start first.")
    # utf-8-sig, not utf-8: Windows PowerShell 5.1 writes a BOM whatever you ask
    # it for, and json.loads rejects one outright.
    return json.loads(path.read_text(encoding="utf-8-sig"))


def connect(host=None, port=None, password=None, state=STATE, attempts=30):
    """Connect, retrying while the server finishes opening its RCON port.

    The port is bound a second or two after the map finishes loading, so a
    connection attempt that lands early is normal rather than an error.
    """
    if port is None or password is None:
        stored = load_state(state)
        port = port or stored["port"]
        password = password or stored["password"]
        host = host or stored.get("host", "127.0.0.1")

    last = None
    for _ in range(attempts):
        try:
            return Rcon(host or "127.0.0.1", port, password)
        except OSError as error:
            last = error
            time.sleep(1)
    raise RconError(f"RCON never answered on port {port}: {last}")


def flatten(block):
    """One line, because that is all the console accepts.

    Whole-line comments are dropped rather than joined: a file that opens with a
    `--` header would otherwise flatten into one long comment and execute
    nothing. Trailing comments cannot be stripped safely -- `--` appears inside
    string literals too -- so those remain a hazard.
    """
    lines = []
    for part in block.strip().splitlines():
        part = part.strip()
        if part and not part.startswith("--"):
            lines.append(part)
    return " ".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--password")
    parser.add_argument("--state", type=Path, default=None)
    parser.add_argument("--instance", default=None,
                        help="read the port and password of this instance's server")
    parser.add_argument("--command", action="append", default=[],
                        help="run this instead of reading stdin; repeatable")
    arguments = parser.parse_args()
    state = arguments.state or state_for(arguments.instance)

    try:
        rcon = connect(arguments.host, arguments.port, arguments.password, state)
    except RconError as error:
        print(error, file=sys.stderr)
        return 2

    blocks = arguments.command or sys.stdin.read().split("\n---\n")
    for block in blocks:
        line = flatten(block)
        if line:
            print(rcon.command(line))
    rcon.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
