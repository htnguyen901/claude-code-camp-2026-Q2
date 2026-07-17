#!/usr/bin/env python3
"""
The single entry point for talking to the MUD. Call it once per command:

    python3 mud_cmd.py "look"
    python3 mud_cmd.py "kill goblin"
    python3 mud_cmd.py "practice kick"
    python3 mud_cmd.py ""            # poll for combat output / re-show prompt
    python3 mud_cmd.py --stop        # end the session cleanly

It does not try to interpret what you're asking for - it sends exactly the
command text you give it and hands back exactly what the MUD said, plus
whatever HP/mana/moves the status line reports. Deciding *what* command to
send (where to go, what to fight, when to flee) is the caller's job -
that's how this stays general instead of hard-coding a handful of
memorized paths.

Starts the connection daemon automatically on first use if it isn't
already running, so you don't need to think about connection lifecycle -
just send commands.
"""

import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
RUNTIME_DIR = SCRIPT_DIR / ".runtime"
LOG_PATH = RUNTIME_DIR / "daemon.log"
DAEMON_SCRIPT = SCRIPT_DIR / "mud_daemon.py"

# Must match mud_daemon.py's derivation exactly - see the comment there.
_skill_id = hashlib.sha256(str(SCRIPT_DIR.resolve()).encode()).hexdigest()[:12]
SOCKET_PATH = Path(tempfile.gettempdir()) / f"mud-player-{_skill_id}.sock"


def daemon_alive() -> bool:
    if not SOCKET_PATH.exists():
        return False
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(str(SOCKET_PATH))
        s.close()
        return True
    except Exception:
        try:
            SOCKET_PATH.unlink()
        except FileNotFoundError:
            pass
        return False


def start_daemon() -> bool:
    RUNTIME_DIR.mkdir(exist_ok=True)
    with open(LOG_PATH, 'a') as log:
        subprocess.Popen(
            [sys.executable, str(DAEMON_SCRIPT)],
            stdout=log, stderr=log,
            start_new_session=True,
            cwd=str(SCRIPT_DIR),
        )
    # Worst-case login (connect + username + password + menu prompts) can
    # take up to ~15s; give it a generous budget since this cost is paid
    # once per session, not per command.
    for _ in range(100):
        if SOCKET_PATH.exists():
            time.sleep(0.3)
            return True
        time.sleep(0.25)
    return False


def send(cmd: str) -> dict:
    if not daemon_alive():
        if not start_daemon():
            return {"error": "Could not start the MUD connection. Check .runtime/daemon.log for details."}

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(str(SOCKET_PATH))
        s.sendall(json.dumps({"cmd": cmd}).encode())
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b''.join(chunks).decode())
    except Exception as e:
        return {"error": f"Could not reach the MUD connection daemon: {e}"}
    finally:
        s.close()


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: mud_cmd.py <command> | mud_cmd.py --stop"}))
        sys.exit(1)

    arg = ' '.join(sys.argv[1:])

    if arg.strip() == '--stop':
        if daemon_alive():
            result = send("__STOP__")
        else:
            result = {"ok": True, "message": "No active session."}
        print(json.dumps(result, indent=2))
        return

    print(json.dumps(send(arg), indent=2))


if __name__ == "__main__":
    main()
