#!/usr/bin/env python3
"""
Background process that owns one persistent MUDClient session and serves
commands over a local unix socket.

Why a daemon at all: each mud_cmd.py invocation is a separate process (it's
called once per Bash tool call). Without something holding the telnet
connection open between those calls, every single command would need its
own login - slow, and it would drop the character back to square one each
time in some MUD configurations. A long goal-driven session (dozens or
hundreds of commands) needs one continuous connection underneath it.

Protocol: client connects, sends one JSON object followed by EOF
({"cmd": "<command text>"}), daemon replies with one JSON object and closes
the connection. Command "__STOP__" ends the MUD session and shuts the
daemon down.

Credentials are never hardcoded here - the daemon reads MUD_USERNAME and
MUD_PASSWORD from its environment (set by whoever launched it, normally
mud_cmd.py forwarding its own environment) so it can log in as whichever
character it's been given. The socket/pid are keyed by username too, so
different characters get independent daemons instead of colliding.
"""

import hashlib
import json
import os
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mud_client import MUDClient

RUNTIME_DIR = Path(__file__).parent / ".runtime"

USERNAME = os.environ.get("MUD_USERNAME")
PASSWORD = os.environ.get("MUD_PASSWORD")
if not USERNAME or not PASSWORD:
    print("MUD_USERNAME and MUD_PASSWORD must be set in the environment", file=sys.stderr)
    sys.exit(1)

PID_PATH = RUNTIME_DIR / f"mud_daemon-{USERNAME}.pid"

# Unix sockets have a short path length limit (~104 bytes on macOS), which
# a deeply nested project directory can easily exceed. Put the socket in
# /tmp instead, named from a hash of this skill's location plus the
# username so it doesn't collide with another project's mud-player
# instance, or with another character's daemon in this same project.
_skill_id = hashlib.sha256(f"{Path(__file__).resolve().parent}:{USERNAME}".encode()).hexdigest()[:12]
SOCKET_PATH = Path(tempfile.gettempdir()) / f"mud-player-{_skill_id}.sock"


def main():
    RUNTIME_DIR.mkdir(exist_ok=True)
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()

    client = MUDClient(username=USERNAME, password=PASSWORD)
    if not client.login():
        print(f"Failed to log in to MUD as {USERNAME}", file=sys.stderr)
        sys.exit(1)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCKET_PATH))
    server.listen(5)
    PID_PATH.write_text(str(os.getpid()))

    try:
        while True:
            conn, _ = server.accept()
            try:
                chunks = []
                conn.settimeout(5)
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                request = json.loads(b''.join(chunks).decode())
            except Exception as e:
                conn.close()
                continue

            cmd = request.get("cmd", "")

            if cmd == "__STOP__":
                conn.sendall(json.dumps({"ok": True, "message": "Ending MUD session"}).encode())
                conn.close()
                try:
                    client.send_command("quit")
                except Exception:
                    pass
                break

            raw = client.send_command(cmd)
            status = client.parse_status(raw)
            response = {
                "command": cmd,
                "raw": raw,
                "status": {
                    "hp": status.hp,
                    "mana": status.mana,
                    "moves": status.moves,
                } if status else None,
            }
            conn.sendall(json.dumps(response).encode())
            conn.close()
    finally:
        client.disconnect()
        server.close()
        if SOCKET_PATH.exists():
            SOCKET_PATH.unlink()
        if PID_PATH.exists():
            PID_PATH.unlink()


if __name__ == "__main__":
    main()
