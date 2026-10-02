"""Real HTTP round-trip tests against an isolated local protocol responder.

These exercise the SDK transport and credential headers, not Orialis server
authorization or a deployed multi-device service.
"""

import json
import os
import threading
import tempfile
import contextlib
import io
import signal
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from integrations.orialis_sdk.http import HttpTransport
from integrations.orialis_sdk.multidevice import MultiDeviceClient


DEVICE = {
    "protocolVersion": "1", "deviceId": "node-local", "accountId": "acct-local",
    "status": "online", "createdAt": "2026-10-02T00:00:00Z",
    "lastSeenAt": "2026-10-02T00:00:10Z", "observedAt": "2026-10-02T00:00:10Z",
    "revocationVersion": 0, "capabilities": [],
}


class Handler(BaseHTTPRequestHandler):
    records = []

    def log_message(self, *_args):
        pass

    def _respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.records.append((self.command, self.path, self.headers.get("Authorization")))
        if self.path == "/api/v1/capabilities":
            return self._respond({"service": "orialis", "api_version": "v1", "capabilities": ["multidevice.v1"]})
        if self.path == "/api/v1/nodes":
            return self._respond({"protocolVersion": "1", "nodes": [DEVICE], "nextCursor": None})
        if self.path == "/error":
            return self._respond({"error": "UNAUTHENTICATED", "message": "node-secret was rejected", "retryable": False}, 401)
        if self.path == "/evil-error":
            return self._respond({"error": "NODE-SECRET", "message": "ignored", "retryable": False}, 401)
        return self._respond({"error": "NOT_FOUND", "message": "not found", "retryable": False}, 404)

    def do_POST(self):
        self.records.append((self.command, self.path, self.headers.get("Authorization")))
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/v1/nodes/pairings":
            self._respond({"protocolVersion": "1", "pairingId": "pair-1", "pairingSecret": "s" * 40,
                           "confirmationCode": "123456", "targetNode": body["nodeIdentity"],
                           "expiresAt": "2026-10-02T00:05:00Z"})
        elif self.path == "/api/v1/nodes/pairings/pair-1/confirm":
            self._respond({"protocolVersion": "1", "pairingId": "pair-1", "status": "confirmed",
                           "accountId": "acct-local", "expiresAt": "2026-10-02T00:05:00Z"})
        elif self.path == "/api/v1/nodes/pairings/pair-1/complete":
            self._respond({"protocolVersion": "1", "deviceId": "node-local", "accountId": "acct-local",
                           "deviceCredential": "d" * 40})
        elif self.path == "/api/v1/nodes/node-local/heartbeat":
            self._respond(DEVICE)
        else:
            self._respond({"error": "NOT_FOUND", "message": "not found", "retryable": False}, 404)


class HttpIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        Handler.records = []
        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_http_pairing_confirm_complete_heartbeat_and_account_list(self):
        identity = {"displayName": "Test Node", "platform": "linux", "nodeVersion": "1.0.0"}
        public_client = MultiDeviceClient(HttpTransport(self.base_url))
        started = public_client.start_pairing(identity)
        self.assertEqual(started["targetNode"], identity)

        account_client = MultiDeviceClient(HttpTransport(self.base_url, token="session-secret", auth_scheme="Session"))
        confirmed = account_client.confirm_pairing("pair-1", "123456", "confirm")
        self.assertEqual(confirmed["status"], "confirmed")
        completed = public_client.complete_pairing("pair-1", started["pairingSecret"], identity)
        self.assertEqual(completed["deviceId"], "node-local")

        node_client = MultiDeviceClient(HttpTransport(self.base_url, token="node-secret", auth_scheme="Node"))
        pulse = node_client.heartbeat("node-local")
        self.assertEqual(pulse["status"], "online")
        self.assertEqual(account_client.list_devices()["nodes"][0]["deviceId"], "node-local")

        auth = {(method, path): header for method, path, header in Handler.records}
        self.assertEqual(auth[("POST", "/api/v1/nodes/pairings")], None)
        self.assertEqual(auth[("POST", "/api/v1/nodes/pairings/pair-1/confirm")], "Session session-secret")
        self.assertEqual(auth[("POST", "/api/v1/nodes/node-local/heartbeat")], "Node node-secret")
        self.assertEqual(auth[("GET", "/api/v1/nodes")], "Session session-secret")

    def test_server_error_text_cannot_echo_a_credential_to_cli(self):
        from integrations.orialis_sdk.http import HttpTransportError
        transport = HttpTransport(self.base_url, token="node-secret", auth_scheme="Node")
        with self.assertRaises(HttpTransportError) as raised:
            transport("GET", "/error")
        self.assertEqual(raised.exception.code, "UNAUTHENTICATED")
        self.assertNotIn("node-secret", str(raised.exception))
        self.assertNotIn("node-secret", str(raised.exception.__dict__))
        with self.assertRaises(HttpTransportError) as raised:
            transport("GET", "/evil-error")
        self.assertEqual(raised.exception.code, "HTTP_ERROR")
        self.assertNotIn("NODE-SECRET", str(raised.exception))

    def test_credential_store_does_not_change_permissions_on_existing_directories(self):
        from integrations.orialis_sdk.cli import CredentialStore
        with tempfile.TemporaryDirectory() as temp_dir:
            os.chmod(temp_dir, 0o755)
            store = CredentialStore(Path(temp_dir) / "node.json")
            with self.assertRaises(RuntimeError):
                store.write({"deviceCredential": "d" * 40})
            self.assertEqual(os.stat(temp_dir).st_mode & 0o777, 0o755)

    @unittest.skipIf(os.name == "nt", "POSIX ownership and symlink checks")
    def test_credential_store_rejects_symlink_parent_on_read(self):
        from integrations.orialis_sdk.cli import CredentialStore
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            private_dir = root / "private"
            private_dir.mkdir(mode=0o700)
            target = private_dir / "node.json"
            CredentialStore(target).write({"deviceCredential": "d" * 40})
            alias = root / "alias"
            alias.symlink_to(private_dir, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "non-symlink directory"):
                CredentialStore(alias / "node.json").read()

    def test_cli_credentials_without_pinned_service_url_fail_closed(self):
        from integrations.orialis_sdk.cli import CredentialStore, main
        Handler.records = []
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "node.json"
            CredentialStore(store_path).write({
                "deviceId": "node-local", "deviceCredential": "d" * 40,
            })
            env_before = os.environ.get("ORIALIS_BASE_URL")
            os.environ["ORIALIS_BASE_URL"] = self.base_url
            try:
                error_output = io.StringIO()
                with contextlib.redirect_stderr(error_output):
                    self.assertEqual(main(["--store", str(store_path), "heartbeat"]), 2)
                self.assertIn("missing its pinned service URL", error_output.getvalue())
                self.assertEqual(Handler.records, [])
            finally:
                if env_before is None:
                    os.environ.pop("ORIALIS_BASE_URL", None)
                else:
                    os.environ["ORIALIS_BASE_URL"] = env_before

    def test_cli_run_retries_transient_offline_and_keeps_ten_second_cadence(self):
        from integrations.orialis_sdk.cli import build_parser, run
        from integrations.orialis_sdk.http import HttpTransportError

        clock = [0.0]
        handlers = {}
        calls_at = []
        class FakeStore:
            def read(self):
                return {"deviceId": "node-local", "deviceCredential": "d" * 40,
                        "baseUrl": self.base_url}

        class FakeClient:
            def heartbeat(self, device_id):
                calls_at.append(clock[0])
                if len(calls_at) == 1:
                    raise HttpTransportError(None, "NETWORK_ERROR", "service could not be reached", True)
                handlers[signal.SIGINT](signal.SIGINT, None)
                return {"deviceId": device_id, "status": "online", "observedAt": "2026-10-02T00:00:10Z"}

        args = build_parser().parse_args(["run"])
        args.timeout = 8.0
        fake_store = FakeStore()
        fake_store.base_url = self.base_url
        output = io.StringIO()
        with patch("integrations.orialis_sdk.cli._node_store", return_value=fake_store), \
             patch("integrations.orialis_sdk.cli._pinned_client", return_value=FakeClient()), \
             patch("integrations.orialis_sdk.cli.signal.signal",
                   side_effect=lambda signum, handler: handlers.__setitem__(signum, handler)), \
             patch("integrations.orialis_sdk.cli.time.monotonic", side_effect=lambda: clock[0]), \
             patch("integrations.orialis_sdk.cli.time.sleep",
                   side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), \
             contextlib.redirect_stdout(output):
            self.assertEqual(run(args), 0)
        self.assertEqual(calls_at, [0.0, 10.0])
        self.assertIn('"status":"retrying"', output.getvalue())
        self.assertNotIn("d" * 40, output.getvalue())

    def test_cli_pairing_persists_secrets_privately_and_never_prints_them(self):
        from integrations.orialis_sdk.cli import CredentialStore, main
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = f"{temp_dir}/node.json"
            env_before = os.environ.get("ORIALIS_SESSION_TOKEN")
            os.environ["ORIALIS_SESSION_TOKEN"] = "session-secret"
            try:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(main(["--base-url", self.base_url, "--store", store_path,
                                           "pair-start", "--name", "Test Node", "--platform", "linux"]), 0)
                self.assertNotIn("s" * 40, output.getvalue())
                self.assertNotIn("d" * 40, output.getvalue())
                pending = CredentialStore(Path(store_path)).read()
                self.assertEqual(pending["pairingSecret"], "s" * 40)
                if os.name != "nt":
                    self.assertEqual(os.stat(store_path).st_mode & 0o777, 0o600)
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(main(["--base-url", self.base_url, "--store", store_path,
                                           "pair-confirm", "pair-1", "--code", "123456", "--decision", "confirm"]), 0)
                    self.assertEqual(main(["--base-url", self.base_url, "--store", store_path,
                                           "pair-complete"]), 0)
                paired = CredentialStore(Path(store_path)).read()
                self.assertEqual(paired["deviceCredential"], "d" * 40)
                self.assertNotIn("pairingSecret", paired)

                class OtherHandler(Handler):
                    records = []
                other = HTTPServer(("127.0.0.1", 0), OtherHandler)
                other_thread = threading.Thread(target=other.serve_forever, daemon=True)
                other_thread.start()
                try:
                    error_output = io.StringIO()
                    with contextlib.redirect_stderr(error_output):
                        self.assertEqual(main(["--base-url", f"http://127.0.0.1:{other.server_port}",
                                               "--store", store_path, "heartbeat"]), 2)
                    self.assertEqual(OtherHandler.records, [])
                    self.assertNotIn("d" * 40, error_output.getvalue())
                finally:
                    other.shutdown()
                    other.server_close()
                    other_thread.join(timeout=2)
            finally:
                if env_before is None:
                    os.environ.pop("ORIALIS_SESSION_TOKEN", None)
                else:
                    os.environ["ORIALIS_SESSION_TOKEN"] = env_before


if __name__ == "__main__":
    unittest.main()
