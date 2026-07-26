#!/usr/bin/env python3
"""
tbaMUD transport layer - owns the telnet connection, handles login,
sends raw commands, and does the small amount of parsing that's actually
reliable (the HP/mana/moves status line).

Deliberately does NOT try to parse room descriptions, NPCs, or exits into
structured objects - MUD room text is free-form prose that varies room to
room, and regex-guessing it produces garbage (e.g. swallowing half the
room description into an "NPC name"). That job is left to whichever caller
is actually reading the text and deciding what it means - a human, or
Claude reasoning over the raw output.

This module also intentionally has no notion of "intent" or "what the
player probably means" - it sends exactly the command it's given. Command
interpretation belongs one layer up.
"""

import socket
import time
import re
import sys
from typing import Optional
from dataclasses import dataclass


@dataclass
class CharacterStatus:
    """Parsed from the status line, e.g. '21H 100M 85V'"""
    hp: int
    mana: int
    moves: int


class MUDClient:
    """Low-level client for a single tbaMUD telnet session."""

    def __init__(self, username: str, password: str,
                 host: str = 'localhost', port: int = 4000,
                 timeout: float = 2.0):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeout = timeout
        self.socket: Optional[socket.socket] = None
        self.is_connected = False
        self.is_logged_in = False

    def connect(self) -> bool:
        """Open the TCP connection and let the server finish its telnet
        negotiation before we try to read anything meaningful."""
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(self.timeout)
            self.socket.connect((self.host, self.port))
            self.is_connected = True
            time.sleep(1)  # server needs a moment to finish protocol negotiation
            self._read_response(timeout=3)
            return True
        except Exception as e:
            print(f"Connection failed: {e}", file=sys.stderr)
            self.is_connected = False
            return False

    def disconnect(self):
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
        self.is_connected = False
        self.is_logged_in = False

    def login(self) -> bool:
        """Log in (or resume) as self.username. tbaMUD's flow is:
        name -> [confirm if new] -> password -> [PRESS RETURN] -> menu -> enter game."""
        if not self.is_connected:
            if not self.connect():
                return False

        try:
            response = self._read_response(timeout=1)

            if "Make your choice" in response:
                # Reconnecting into a session that already got past login
                self._send_command("1")
                time.sleep(1)
                response = self._read_response()
            else:
                self._send_command(self.username)
                time.sleep(0.3)
                response = self._read_response()

                if "Did I get that right" in response:
                    self._send_command("yes")
                    time.sleep(0.3)
                    response = self._read_response()

                if "Password" in response:
                    self._send_command(self.password)
                    time.sleep(1)
                    response = self._read_response()

                if "PRESS RETURN" in response.upper():
                    self._send_command("")
                    time.sleep(0.5)
                    response = self._read_response()

                if "Make your choice" in response:
                    self._send_command("1")
                    time.sleep(1)
                    response = self._read_response()

            if "PRESS RETURN" in response.upper():
                self._send_command("")
                time.sleep(0.5)
                self._read_response()

            self.is_logged_in = True
            return True
        except Exception as e:
            print(f"Login failed: {e}", file=sys.stderr)
            return False

    def send_command(self, command: str) -> str:
        """Send one raw command, return the cleaned response text."""
        if not self.is_connected or not self.is_logged_in:
            if not self.login():
                return "ERROR: Not connected to MUD"

        try:
            self._send_command(command)
            time.sleep(0.3)
            response = self._read_response()
            return self._clean_response(response)
        except Exception as e:
            print(f"Command failed, reconnecting: {e}", file=sys.stderr)
            self.disconnect()
            if self.login():
                return self.send_command(command)
            return f"ERROR: {e}"

    def parse_status(self, response: str) -> Optional[CharacterStatus]:
        """Extract HP/mana/moves from the prompt line. This is the one thing
        worth regexing - tbaMUD's status line format is fixed and reliable,
        unlike room text."""
        match = re.search(r'(\d+)H\s+(\d+)M\s+(\d+)V', response)
        if match:
            return CharacterStatus(
                hp=int(match.group(1)),
                mana=int(match.group(2)),
                moves=int(match.group(3)),
            )
        return None

    # Private helpers

    def _send_command(self, command: str):
        if self.socket:
            self.socket.send((command + '\n').encode())

    def _read_response(self, timeout: Optional[float] = None) -> str:
        if not self.socket:
            return ""

        old_timeout = self.socket.gettimeout()
        self.socket.settimeout(timeout if timeout else self.timeout)

        try:
            data = b''
            while True:
                try:
                    chunk = self.socket.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                except socket.timeout:
                    break
            return data.decode('utf-8', errors='ignore')
        finally:
            self.socket.settimeout(old_timeout)

    def _clean_response(self, response: str) -> str:
        """Strip ANSI color codes and telnet control bytes, trim trailing
        whitespace per line. Leaves the actual game text untouched."""
        ansi_pattern = re.compile(r'\x1b\[[0-9;]*m|\[[0-9;]*m')
        cleaned = ansi_pattern.sub('', response)
        cleaned = re.sub(r'[\x00-\x08\x0b-\x1f]', '', cleaned)
        lines = [line.rstrip() for line in cleaned.split('\n')]
        return '\n'.join(lines).strip()
