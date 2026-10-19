#!/usr/bin/env python3
"""Tests for tools/fake_xair.py. Run from the repo root:

    python3 -m unittest tools.test_fake_xair -v      (or: python3 tools/test_fake_xair.py)
"""

import os
import socket
import struct
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_xair as fx  # noqa: E402


class Client:
    def __init__(self, server, timeout=0.5):
        self.server = ("127.0.0.1", server.port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(timeout)

    def send(self, address, *args):
        self.sock.sendto(fx.osc_encode(address, *args), self.server)

    def recv(self, timeout=None):
        if timeout is not None:
            self.sock.settimeout(timeout)
        try:
            data, _ = self.sock.recvfrom(65535)
        except socket.timeout:
            return None
        return fx.osc_parse(data)[0]

    def query(self, address, *args, timeout=None):
        self.send(address, *args)
        return self.recv(timeout)

    def drain(self, window=0.15):
        out = []
        end = time.monotonic() + window
        while time.monotonic() < end:
            msg = self.recv(max(0.01, end - time.monotonic()))
            if msg:
                out.append(msg)
        return out

    def close(self):
        self.sock.close()


class ServerCase(unittest.TestCase):
    server_args = {}

    def setUp(self):
        self.server = fx.FakeXAir("127.0.0.1", 0, log=lambda text: None, seed=1, **self.server_args).start()
        self.clients = []
        self.addCleanup(self.server.stop)

    def client(self, **kw):
        c = Client(self.server, **kw)
        self.clients.append(c)
        self.addCleanup(c.close)
        return c


class TestCodec(unittest.TestCase):
    def test_round_trip_all_types(self):
        data = fx.osc_encode("/x/y", 7, -3, 0.25, "héllo", b"\x01\x02\x03")
        address, args = fx.osc_parse(data)[0]
        self.assertEqual(address, "/x/y")
        self.assertEqual(args, [7, -3, 0.25, "héllo", b"\x01\x02\x03"])
        self.assertEqual(len(data) % 4, 0)

    def test_bundle_is_unpacked(self):
        a, b = fx.osc_encode("/a", 1), fx.osc_encode("/b", "x")
        bundle = b"#bundle\0" + b"\0" * 8 + struct.pack(">i", len(a)) + a + struct.pack(">i", len(b)) + b
        self.assertEqual(fx.osc_parse(bundle), [("/a", [1]), ("/b", ["x"])])

    def test_garbage_rejected(self):
        for junk in (b"", b"no slash\0\0\0\0", b"/a\0\0,i\0\0"):
            with self.assertRaises((ValueError, struct.error, IndexError)):
                fx.osc_parse(junk)


class TestInfoAndValues(ServerCase):
    def test_info_replies(self):
        c = self.client()
        address, args = c.query("/xinfo")
        self.assertEqual(address, "/xinfo")
        self.assertEqual(len(args), 4)
        self.assertEqual(args[2], "XR18")
        self.assertEqual(args[3], "1.16")
        address, args = c.query("/info")
        self.assertEqual((address, args[2]), ("/info", "XR18"))
        address, args = c.query("/status")
        self.assertEqual((address, args[0]), ("/status", "active"))

    def test_seeded_demo_data(self):
        c = self.client()
        self.assertEqual(c.query("/ch/01/config/name")[1], ["Pulpito"])
        self.assertEqual(c.query("/ch/02/config/name")[1], ["Mic Oscar"])
        self.assertEqual(c.query("/bus/2/config/name")[1], ["IEM Batería"])
        self.assertEqual(c.query("/dca/2/config/name")[1], ["Voces"])
        self.assertEqual(c.query("/ch/07/mix/on")[1], [0])
        self.assertEqual(c.query("/snap/02/name")[1], ["Domingo PM"])
        self.assertEqual(c.query("/snap/40/name")[1], [""])
        self.assertIsNotNone(c.query("/config/mute/3"))

    def test_get_set_round_trip(self):
        c = self.client()
        c.send("/ch/03/mix/fader", 0.4)
        address, args = c.query("/ch/03/mix/fader")
        self.assertEqual(address, "/ch/03/mix/fader")
        self.assertAlmostEqual(args[0], 0.4, places=6)
        c.send("/ch/03/config/name", "Piano")
        self.assertEqual(c.query("/ch/03/config/name")[1], ["Piano"])
        c.send("/headamp/01/phantom", 1)
        self.assertEqual(c.query("/headamp/01/phantom")[1], [1])

    def test_set_coerces_to_stored_type(self):
        c = self.client()
        c.send("/ch/01/mix/on", 0.0)
        self.assertEqual(c.query("/ch/01/mix/on")[1], [0])
        c.send("/ch/01/mix/fader", 1)
        self.assertEqual(c.query("/ch/01/mix/fader")[1], [1.0])

    def test_unknown_get_is_silent_unknown_set_is_remembered(self):
        c = self.client(timeout=0.2)
        self.assertIsNone(c.query("/nothing/here"))
        c.send("/nothing/here", 5)
        self.assertEqual(c.query("/nothing/here")[1], [5])

    def test_malformed_packet_does_not_kill_server(self):
        c = self.client()
        c.sock.sendto(b"\xff\xfe garbage", c.server)
        self.assertEqual(c.query("/xinfo")[0], "/xinfo")

    def test_bundle_is_handled(self):
        c = self.client()
        m = fx.osc_encode("/ch/05/mix/fader", 0.3)
        c.sock.sendto(b"#bundle\0" + b"\0" * 8 + struct.pack(">i", len(m)) + m, c.server)
        self.assertAlmostEqual(c.query("/ch/05/mix/fader")[1][0], 0.3, places=6)


class TestSubscriptions(ServerCase):
    server_args = {"xremote_timeout": 0.5}

    def test_xremote_echo_to_second_client_not_to_sender(self):
        a, b = self.client(), self.client()
        a.send("/xremote")
        b.send("/xremote")
        time.sleep(0.1)
        a.send("/ch/04/mix/fader", 0.6)
        got = b.drain()
        self.assertEqual([m[0] for m in got], ["/ch/04/mix/fader"])
        self.assertAlmostEqual(got[0][1][0], 0.6, places=6)
        self.assertEqual(a.drain(), [])          # the sender does not get its own change back

    def test_unsubscribed_client_gets_nothing(self):
        a, b = self.client(), self.client()
        b.send("/xremote")
        time.sleep(0.1)
        a.send("/ch/04/mix/fader", 0.6)
        self.assertEqual(self.client().drain(0.1), [])
        self.assertEqual(len(b.drain()), 1)

    def test_subscription_expires_and_renewal_keeps_it(self):
        a, setter = self.client(), self.client()
        a.send("/xremote")
        time.sleep(0.3)
        a.send("/xremote")                       # renewal
        time.sleep(0.3)                          # 0.6 s since first, only 0.3 s since renewal
        setter.send("/ch/01/mix/fader", 0.2)
        self.assertEqual(len(a.drain()), 1)
        time.sleep(0.7)                          # silent for longer than the timeout
        setter.send("/ch/01/mix/fader", 0.3)
        self.assertEqual(a.drain(), [])

    def test_renew_keeps_subscription(self):
        a, setter = self.client(), self.client()
        a.send("/xremote")
        time.sleep(0.3)
        a.send("/renew")
        time.sleep(0.3)
        setter.send("/ch/01/mix/fader", 0.2)
        self.assertEqual(len(a.drain()), 1)

    def test_eight_client_limit(self):
        clients = [self.client() for _ in range(9)]
        for c in clients:
            c.send("/xremote")
            time.sleep(0.01)
        time.sleep(0.1)
        self.server.elsewhere("/ch/01/mix/fader", [0.5])
        counts = [len(c.drain(0.1)) for c in clients]
        self.assertEqual(counts, [1] * 8 + [0])

    def test_elsewhere_and_kick(self):
        a = self.client()
        a.send("/xremote")
        time.sleep(0.1)
        self.assertIn("pushed", self.server.command("elsewhere ch/03/mix/fader 0.5"))
        got = a.drain()
        self.assertEqual(got[0][0], "/ch/03/mix/fader")
        self.assertAlmostEqual(got[0][1][0], 0.5, places=6)
        self.server.command("kick")
        self.server.command("elsewhere ch/03/mix/fader 0.7")
        self.assertEqual(a.drain(), [])
        self.assertAlmostEqual(a.query("/ch/03/mix/fader")[1][0], 0.7, places=6)   # value still changed


class TestMeters(ServerCase):
    server_args = {"xremote_timeout": 0.5}

    def blob_of(self, msg):
        address, args = msg
        self.assertIsInstance(args[0], bytes)
        count = struct.unpack_from("<i", args[0], 0)[0]
        return count, args[0]

    def test_meter_1_and_6_blob_sizes(self):
        c = self.client()
        c.send("/meters", "/meters/1")
        c.send("/meters", "/meters/6")
        seen = {}
        for msg in c.drain(0.4):
            seen.setdefault(msg[0], []).append(msg)
        self.assertGreaterEqual(len(seen["/meters/1"]), 4)          # ~50 ms frames
        self.assertGreaterEqual(len(seen["/meters/6"]), 4)
        count, blob = self.blob_of(seen["/meters/1"][0])
        self.assertEqual((count, len(blob)), (40, 4 + 40 * 2))
        count, blob = self.blob_of(seen["/meters/6"][0])
        self.assertEqual((count, len(blob)), (39, 4 + 39 * 2))
        # levels move between frames, and a gated, compressed vocal channel shows reduction
        first = struct.unpack_from("<16h", seen["/meters/1"][0][1][0], 4)
        last = struct.unpack_from("<16h", seen["/meters/1"][-1][1][0], 4)
        self.assertNotEqual(first, last)
        self.assertTrue(all(-128 * 256 <= v <= 0 for v in first))

    def test_other_meter_sizes(self):
        c = self.client()
        for n, size in fx.METER_SIZES.items():
            c.send("/meters", f"/meters/{n}")
        sizes = {}
        for address, args in c.drain(0.2):
            sizes[address] = struct.unpack_from("<i", args[0], 0)[0]
        self.assertEqual(sizes, {f"/meters/{n}": s for n, s in fx.METER_SIZES.items()})

    def test_meters_expire_unless_renewed(self):
        c = self.client()
        c.send("/meters", "/meters/1")
        self.assertTrue(c.drain(0.2))
        time.sleep(0.5)
        c.drain(0.05)
        self.assertEqual(c.drain(0.2), [])

    def test_quiet_and_loud(self):
        c = self.client()
        c.send("/meters", "/meters/1")
        def last_frame():
            c.send("/renew")
            return struct.unpack_from("<16h", c.drain(0.15)[-1][1][0], 4)
        self.server.command("quiet")
        c.drain(0.1)
        self.assertLessEqual(max(last_frame()), -80 * 256)
        self.server.command("loud")
        c.drain(0.1)
        self.assertGreater(max(last_frame()), -3 * 256)


class TestFaults(ServerCase):
    def test_loss_flag(self):
        c = self.client(timeout=0.2)
        self.server.command("loss 100")
        self.assertIsNone(c.query("/xinfo"))
        self.server.command("loss 0")
        self.assertIsNotNone(c.query("/xinfo"))

    def test_latency_flag(self):
        c = self.client(timeout=1)
        self.server.command("latency 300")
        start = time.monotonic()
        self.assertIsNotNone(c.query("/xinfo"))
        self.assertGreaterEqual(time.monotonic() - start, 0.28)
        self.server.command("latency 0")
        start = time.monotonic()
        c.query("/xinfo")
        self.assertLess(time.monotonic() - start, 0.15)

    def test_freeze_applies_changes_but_does_not_reply_drop_ignores_them(self):
        c = self.client(timeout=0.2)
        self.server.command("freeze")
        self.assertIsNone(c.query("/xinfo"))
        c.send("/ch/09/mix/fader", 0.11)
        time.sleep(0.1)
        self.server.command("resume")
        self.assertAlmostEqual(c.query("/ch/09/mix/fader")[1][0], 0.11, places=6)
        self.server.command("drop on")
        c.send("/ch/09/mix/fader", 0.99)
        time.sleep(0.15)
        self.server.command("drop off")
        self.assertAlmostEqual(c.query("/ch/09/mix/fader")[1][0], 0.11, places=6)

    def test_jitter_command_and_status(self):
        self.assertIn("jitter 40 ms", self.server.command("jitter 40"))
        self.assertIn("jitter 40 ms", self.server.command("status"))

    def test_changeip(self):
        c = self.client()
        before = c.query("/xinfo")[1][0]
        self.server.command("changeip")
        self.assertNotEqual(c.query("/xinfo")[1][0], before)

    def test_powercycle_resets_to_factory_and_forgets_subscribers(self):
        c, other = self.client(), self.client()
        c.send("/ch/01/mix/fader", 0.2)
        c.send("/ch/01/config/name", "Changed")
        c.send("/snap/name", "Keep me")
        c.send("/snap/save", 9)
        other.send("/xremote")
        other.send("/meters", "/meters/1")
        time.sleep(0.1)
        other.drain(0.1)
        self.server.command("powercycle")
        self.assertEqual(c.query("/ch/01/config/name")[1], [""])
        self.assertAlmostEqual(c.query("/ch/01/mix/fader")[1][0], fx.fader_from_db(0), places=5)
        self.assertEqual(c.query("/ch/03/mix/fader")[1][0], c.query("/ch/01/mix/fader")[1][0])
        self.assertEqual(c.query("/bus/1/config/name")[1], [""])
        # subscribers are gone: no push, no meters
        c.send("/ch/02/mix/fader", 0.3)
        self.assertEqual(other.drain(0.2), [])
        # snapshots live in flash and survive
        self.assertEqual(c.query("/snap/09/name")[1], ["Keep me"])

    def test_powercycle_with_downtime_is_silent_then_back(self):
        c = self.client(timeout=0.15)
        self.server.command("powercycle 0.5")
        self.assertIsNone(c.query("/xinfo"))
        time.sleep(0.5)
        self.assertEqual(c.query("/xinfo")[0], "/xinfo")


class TestSnapshots(ServerCase):
    def test_save_change_load_round_trip(self):
        c, watcher = self.client(), self.client()
        watcher.send("/xremote")
        c.send("/ch/03/mix/fader", 0.33)
        c.send("/ch/03/config/name", "Original")
        c.send("/snap/name", "Test scene")
        c.send("/snap/save", 7)
        self.assertEqual(c.query("/snap/07/name")[1], ["Test scene"])
        self.assertEqual(c.query("/snap/index")[1], [7])
        c.send("/ch/03/mix/fader", 0.9)
        c.send("/ch/03/config/name", "Changed")
        time.sleep(0.1)
        watcher.drain(0.1)
        c.send("/snap/load", 7)
        time.sleep(0.2)
        self.assertAlmostEqual(c.query("/ch/03/mix/fader")[1][0], 0.33, places=6)
        self.assertEqual(c.query("/ch/03/config/name")[1], ["Original"])
        pushed = {m[0] for m in watcher.drain(0.3)}
        self.assertIn("/ch/03/mix/fader", pushed)            # recall is pushed to /xremote clients
        self.assertIn("/ch/03/config/name", pushed)

    def test_rename_delete_and_empty_load(self):
        c = self.client()
        c.send("/snap/12/name", "Renamed")
        self.assertEqual(c.query("/snap/12/name")[1], ["Renamed"])
        c.send("/snap/name", "Gone soon")
        c.send("/snap/save", 13)
        c.send("/snap/delete", 13)
        self.assertEqual(c.query("/snap/13/name")[1], [""])
        c.send("/ch/01/mix/fader", 0.1)
        c.send("/snap/load", 13)                              # empty slot: nothing happens
        self.assertAlmostEqual(c.query("/ch/01/mix/fader")[1][0], 0.1, places=6)
        c.send("/snap/name", "x" * 40)
        self.assertEqual(len(c.query("/snap/name")[1][0]), 31)

    def test_console_snapshot(self):
        c = self.client()
        self.server.command("snapshot 20 From console")
        self.assertEqual(c.query("/snap/20/name")[1], ["From console"])

    def test_dash_snap_prefix_option(self):
        server = fx.FakeXAir("127.0.0.1", 0, log=lambda t: None, snap_prefix="/-snap").start()
        self.addCleanup(server.stop)
        c = Client(server)
        self.addCleanup(c.close)
        self.assertEqual(c.query("/-snap/01/name")[1], ["Domingo AM"])
        c.sock.settimeout(0.2)
        self.assertIsNone(c.query("/snap/01/name"))


class TestScenarios(unittest.TestCase):
    def make(self, scenario):
        server = fx.FakeXAir("127.0.0.1", 0, scenario=scenario, log=lambda t: None, seed=3).start()
        self.addCleanup(server.stop)
        c = Client(server, timeout=0.3)
        self.addCleanup(c.close)
        return server, c

    def test_all_scenarios_exist(self):
        self.assertEqual(set(fx.SCENARIOS), {"normal", "flaky-wifi", "slow", "no-xremote",
                                             "powercycle-after-60s", "wrong-firmware", "unreachable"})

    def test_unreachable_never_answers(self):
        server, c = self.make("unreachable")
        self.assertIsNone(c.query("/xinfo"))
        server.command("resume")
        self.assertIsNotNone(c.query("/xinfo"))

    def test_no_xremote_ignores_subscription(self):
        server, c = self.make("no-xremote")
        c.send("/xremote")
        time.sleep(0.1)
        server.elsewhere("/ch/01/mix/fader", [0.4])
        self.assertEqual(c.drain(0.2), [])
        self.assertIsNotNone(c.query("/ch/01/mix/fader"))

    def test_wrong_firmware(self):
        server, c = self.make("wrong-firmware")
        self.assertEqual(c.query("/xinfo")[1][3], "1.08")
        self.assertIsNone(c.query("/snap/01/name"))
        c.send("/meters", "/meters/6")
        c.send("/meters", "/meters/1")
        self.assertEqual({m[0] for m in c.drain(0.3)}, {"/meters/1"})

    def test_slow_and_flaky_parameters(self):
        slow, _ = self.make("slow")
        self.assertEqual(slow.latency_ms, 400)
        flaky, _ = self.make("flaky-wifi")
        self.assertEqual((flaky.loss, flaky.jitter_ms), (15, 80))

    def test_powercycle_after_60s_is_scheduled(self):
        server, _ = self.make("powercycle-after-60s")
        self.assertEqual(len(server._timers), 1)
        self.assertEqual(server._timers[0].interval, 60)

    def test_cli_flags_override_scenario(self):
        import subprocess
        out = subprocess.run([sys.executable, os.path.join(os.path.dirname(fx.__file__), "fake_xair.py"),
                              "--scenario", "bogus"], capture_output=True, text=True)
        self.assertNotEqual(out.returncode, 0)


if __name__ == "__main__":
    unittest.main()
