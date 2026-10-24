#!/usr/bin/env python3
"""A fake Soundcraft Ui24R that speaks the Ui WebSocket protocol, for testing Holly Mixer without the mixer.

    sudo python3 tools/fake_ui24.py              # listen on 0.0.0.0:80 (the app always uses port 80)
    python3 tools/fake_ui24.py --port 8080 -v    # another port, for the Python client below or a proxy

The protocol (from the open-source soundcraft-ui-connection library): a WebSocket at ws://<ip>/, text frames that
start with "3:::" and hold lines separated by "\\n": `SETD^i.0.mix^0.75`, `SETS^i.0.name^Vocal`, `VU2^<base64>`.
On connect the mixer sends its whole state; clients send SETD/SETS and "ALIVE" every second. A change is stored and
sent to every other client. See docs/FAKE_MIXER.md.

Python 3.8+, standard library only. Not a real mixer: no EQ, effects, shows or snapshots.
"""

import argparse
import base64
import hashlib
import math
import random
import socket
import struct
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
VU_INTERVAL = 0.05

CHANNELS = [  # name, fader 0...1 (Ui taper), muted, signal level 0...1 or None
    ("Pulpito", 0.82, 0, 0.62), ("Mic Oscar", 0.80, 0, 0.66), ("Guitarra Acus", 0.77, 0, 0.55),
    ("Bajo", 0.70, 0, 0.64), ("Mic Martin", 0.81, 0, 0.58), ("Mic Cata", 0.79, 0, 0.47),
    ("Voz Off", 0.0, 1, None), ("Guit Marcelo", 0.62, 0, 0.45), ("Martin", 0.73, 0, 0.56),
    ("Bateria", 0.77, 0, 0.72), ("Maxi", 0.66, 0, 0.50),
]
AUXES = ["Monitor Pulpito", "IEM Bateria", "IEM Bajo", "Wedge Coro", "Stream", "Lobby"]
VCAS = ["Banda", "Voces", "Pastor", "Playback"]


def initial_state():
    state = {"model": "ui24", "firmware": "3.3.8293-ui24", "mgmask": 0}
    for index in range(24):
        name, mix, mute, _ = CHANNELS[index] if index < len(CHANNELS) else ("", 0.0, 0, None)
        prefix = "i.%d" % index
        state.update({prefix + ".name": name, prefix + ".mix": mix, prefix + ".mute": mute,
                      prefix + ".pan": 0.5, prefix + ".solo": 0, prefix + ".mgmask": 0,
                      prefix + ".stereoIndex": -1, "hw.%d.gain" % index: 0.3, "hw.%d.phantom" % index: 0})
        for aux in range(10):
            state["%s.aux.%d.value" % (prefix, aux)] = round(random.uniform(0.4, 0.76), 3) if name else 0
        for fx in range(4):
            state["%s.fx.%d.value" % (prefix, fx)] = 0.5 if name else 0
    for index in (0, 1):
        state.update({"l.%d.name" % index: "Playback", "l.%d.mix" % index: 0.6, "l.%d.mute" % index: 0,
                      "l.%d.pan" % index: float(index), "l.%d.stereoIndex" % index: index})
    for index in range(4):
        state.update({"f.%d.name" % index: ["Hall", "Plate", "Delay", "Chorus"][index],
                      "f.%d.mix" % index: 0.6, "f.%d.mute" % index: 0})
    for index in range(10):
        state.update({"a.%d.name" % index: AUXES[index] if index < len(AUXES) else "",
                      "a.%d.mix" % index: 0.76, "a.%d.mute" % index: 0})
    for index in range(6):
        state.update({"v.%d.name" % index: VCAS[index] if index < len(VCAS) else "",
                      "v.%d.mix" % index: 0.76, "v.%d.mute" % index: 0})
    state.update({"m.mix": 0.74, "m.pan": 0.5, "m.dim": 0})
    return state


def line_for(key, value):
    return ("SETS^%s^%s" if isinstance(value, str) else "SETD^%s^%s") % (key, value)


class Client:
    def __init__(self, sock, address):
        self.sock = sock
        self.address = address
        self.lock = threading.Lock()
        self.alive = True

    def send_text(self, text):
        payload = text.encode("utf-8")
        header = bytes([0x81])
        if len(payload) < 126:
            header += bytes([len(payload)])
        elif len(payload) < 65536:
            header += bytes([126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([127]) + struct.pack(">Q", len(payload))
        try:
            with self.lock:
                self.sock.sendall(header + payload)
        except OSError:
            self.alive = False


class FakeUi24:
    def __init__(self, verbose=False):
        self.state = initial_state()
        self.clients = []
        self.lock = threading.Lock()
        self.verbose = verbose
        self.started = time.time()

    # --- WebSocket ---

    def handshake(self, sock):
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = sock.recv(4096)
            if not chunk:
                return False
            request += chunk
        headers = {}
        for line in request.decode("latin-1").split("\r\n")[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        key = headers.get("sec-websocket-key")
        if not key:
            sock.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 20\r\n\r\n<h1>Fake Ui24R</h1>\n")
            return False
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        return True

    @staticmethod
    def read_frame(sock):
        def exact(count):
            data = b""
            while len(data) < count:
                chunk = sock.recv(count - len(data))
                if not chunk:
                    raise ConnectionError
                data += chunk
            return data
        first, second = exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", exact(8))[0]
        mask = exact(4) if second & 0x80 else b"\0\0\0\0"
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(length)))
        return opcode, payload

    def serve(self, sock, address):
        try:
            if not self.handshake(sock):
                sock.close()
                return
        except OSError:
            return
        client = Client(sock, address)
        with self.lock:
            dump = "\n".join(line_for(k, v) for k, v in self.state.items())
            self.clients.append(client)
        print("client connected: %s:%d" % address)
        client.send_text("3:::" + dump)
        try:
            while client.alive:
                opcode, payload = self.read_frame(sock)
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    continue
                text = payload.decode("utf-8", errors="replace")
                if not text.startswith("3:::"):
                    continue
                for line in text[4:].split("\n"):
                    self.handle(client, line)
        except (ConnectionError, OSError, ValueError):
            pass
        client.alive = False
        with self.lock:
            self.clients.remove(client)
        sock.close()
        print("client left: %s:%d" % address)

    def handle(self, sender, line):
        if line == "ALIVE" or not line:
            return
        parts = line.split("^", 2)
        if len(parts) != 3 or parts[0] not in ("SETD", "SETS"):
            if self.verbose:
                print("ignored:", line)
            return
        kind, key, value = parts
        if kind == "SETD":
            try:
                value = float(value)
            except ValueError:
                return
        if self.verbose:
            print("%s:%d %s" % (sender.address + (line,)))
        with self.lock:
            self.state[key] = value
            others = [c for c in self.clients if c is not sender]
        for client in others:
            client.send_text("3:::" + line_for(key, value))

    # --- Meters ---

    def vu_frame(self, t):
        counts = [24, 2, 6, 4, 10, 2, 2, 0]
        data = bytearray(counts)

        def level(base, seed):
            if base is None:
                return 0
            swell = (math.sin(t * 0.8 + seed * 1.7) + math.sin(t * 2.3 + seed)) / 2
            return max(0, min(240, int((base + swell * 0.1 + random.uniform(-0.02, 0.02)) / 0.004167508166392142)))

        for index in range(24):
            base = CHANNELS[index][3] if index < len(CHANNELS) else None
            muted = self.state.get("i.%d.mute" % index)
            value = level(base, index)
            data += bytes([value, value, 0 if muted else value, 0, 0, 0])
        data += bytes(6 * 2)                                  # players
        data += bytes(7 * 6)                                  # subgroups
        for index in range(4):
            value = level(0.45, 30 + index)
            data += bytes([value, value, value, value, 0, 0, 0])
        for index in range(10):
            value = level(0.6 if index < len(AUXES) else None, 40 + index)
            data += bytes([value, value, 0, 0, 0])
        for index in range(2):
            value = level(0.7, 60)
            data += bytes([value, value, 0, 0, 0])
        for index in range(2):
            value = level(0.5, 70)
            data += bytes([value, value, value, 0, 0, 0])
        return "3:::VU2^" + base64.b64encode(bytes(data)).decode()

    def meter_loop(self):
        while True:
            frame = self.vu_frame(time.time() - self.started)
            with self.lock:
                clients = list(self.clients)
            for client in clients:
                client.send_text(frame)
            time.sleep(VU_INTERVAL)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("-v", "--verbose", action="store_true", help="log every change a client sends")
    args = parser.parse_args()

    mixer = FakeUi24(verbose=args.verbose)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(16)
    print("fake Ui24R on %s:%d (Ctrl-C to stop)" % (args.host, args.port))
    threading.Thread(target=mixer.meter_loop, daemon=True).start()
    try:
        while True:
            sock, address = server.accept()
            threading.Thread(target=mixer.serve, args=(sock, address), daemon=True).start()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
