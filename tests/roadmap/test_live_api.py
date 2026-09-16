from __future__ import annotations

import unittest

from .support import LiveServerMixin, json_request, multipart_body, request, session_headers, unique_id


class LiveSessionAndCapabilityTests(LiveServerMixin, unittest.TestCase):
    def test_capabilities_describe_current_non_voice_surfaces(self) -> None:
        result = request("GET", "/api/v1/capabilities")
        payload = result.json()
        self.assertEqual(result.status, 200)
        api_version = payload.get("apiVersion", payload.get("api_version"))
        self.assertEqual(api_version, "v1")
        self.assertFalse(payload["web"])
        for capability in ("auth", "messages", "attachments", "websocket"):
            self.assertIn(capability, payload["capabilities"])

    def test_session_is_usable_then_one_token_can_be_revoked(self) -> None:
        token, username = self.shared_session()
        current = json_request("GET", "/api/v1/auth/session", headers=session_headers(token))
        self.assertEqual(current.status, 200, current.body)
        self.assertEqual(current.json()["username"], username)

        login = json_request(
            "POST",
            "/api/v1/auth/login",
            {"username": self._shared_username, "password": self._shared_password},
        )
        self.assertEqual(login.status, 200, login.body)
        second_token = login.json()["accessToken"]
        logout = json_request("POST", "/api/v1/auth/logout", headers=session_headers(second_token))
        self.assertEqual(logout.status, 204, logout.body)
        revoked = json_request("GET", "/api/v1/auth/session", headers=session_headers(second_token))
        self.assertEqual(revoked.status, 401, revoked.body)

        still_valid = json_request("GET", "/api/v1/auth/session", headers=session_headers(token))
        self.assertEqual(still_valid.status, 200, still_valid.body)

    def test_attachment_upload_message_reference_and_download_round_trip(self) -> None:
        self.require_capability("attachments", "message/attachment round trip")
        token, _ = self.shared_session()
        conversation = unique_id("roadmap-conversation")
        created = json_request(
            "POST",
            "/api/v1/conversations",
            {"id": conversation, "title": "Roadmap attachment test"},
            headers=session_headers(token),
        )
        self.assertIn(created.status, (200, 201), created.body)
        content = b"roadmap attachment contract\n"
        body, content_type = multipart_body([("file", "contract.txt", "text/plain", content)])
        key = unique_id("attachment-upload")
        uploaded = request(
            "POST",
            f"/api/v1/conversations/{conversation}/attachments",
            body=body,
            headers={
                **session_headers(token),
                "Content-Type": content_type,
                "Idempotency-Key": key,
            },
        )
        if uploaded.status == 404:
            self.skipTest("message attachment upload endpoint is not available on this server")
        self.assertEqual(uploaded.status, 200, uploaded.body)
        item = uploaded.json()["items"][0]
        self.assertEqual(item["name"], "contract.txt")
        self.assertEqual(item["mimeType"], "text/plain")
        self.assertEqual(item["size"], len(content))
        self.assertIn(f"/api/v1/attachments/{item['id']}/download", item["downloadUrl"])

        replay_body, replay_type = multipart_body([("file", "ignored.txt", "text/plain", b"different")])
        replay = request(
            "POST",
            f"/api/v1/conversations/{conversation}/attachments",
            body=replay_body,
            headers={
                **session_headers(token),
                "Content-Type": replay_type,
                "Idempotency-Key": key,
            },
        )
        self.assertEqual(replay.status, 200, replay.body)
        self.assertEqual(replay.json(), uploaded.json())

        message_id = unique_id("roadmap-message")
        message = json_request(
            "POST",
            f"/api/v1/conversations/{conversation}/messages",
            {"id": message_id, "content": "", "attachments": [{"id": item["id"]}]},
            headers=session_headers(token),
        )
        self.assertEqual(message.status, 201, message.body)
        message_payload = message.json()
        self.assertEqual(message_payload["id"], message_id)
        self.assertEqual(message_payload["content"], "")
        self.assertEqual(message_payload["attachments"][0]["id"], item["id"])

        listed = json_request(
            "GET", f"/api/v1/conversations/{conversation}/messages", headers=session_headers(token)
        )
        self.assertEqual(listed.status, 200, listed.body)
        self.assertEqual([entry["id"] for entry in listed.json()], [message_id])
        downloaded = request(
            "GET", f"/api/v1/attachments/{item['id']}/download", headers=session_headers(token)
        )
        self.assertEqual(downloaded.status, 200, downloaded.body)
        self.assertEqual(downloaded.body, content)

    def test_upload_rejects_empty_message_without_attachment(self) -> None:
        token, _ = self.shared_session()
        conversation = unique_id("roadmap-conversation")
        created = json_request(
            "POST",
            "/api/v1/conversations",
            {"id": conversation, "title": "Roadmap empty message test"},
            headers=session_headers(token),
        )
        self.assertIn(created.status, (200, 201), created.body)
        result = json_request(
            "POST",
            f"/api/v1/conversations/{conversation}/messages",
            {"content": "", "attachments": []},
            headers=session_headers(token),
        )
        if result.status == 404:
            self.skipTest("conversation message endpoint is not available on this server")
        self.assertEqual(result.status, 400, result.body)


class LivePathInvariantTests(LiveServerMixin, unittest.TestCase):
    def test_macos_and_windows_filename_components_are_not_persisted(self) -> None:
        self.require_capability("attachments", "macOS/Windows path invariants")
        token, _ = self.shared_session()
        conversation = unique_id("roadmap-path-conversation")
        created = json_request(
            "POST",
            "/api/v1/conversations",
            {"id": conversation, "title": "Roadmap path test"},
            headers=session_headers(token),
        )
        self.assertIn(created.status, (200, 201), created.body)
        cases = [
            ("/Users/roadmap/contract-macos.txt", "contract-macos.txt"),
            (r"C:\Users\roadmap\contract-windows.txt", "contract-windows.txt"),
        ]
        for supplied_name, expected_name in cases:
            body, content_type = multipart_body(
                [("file", supplied_name, "text/plain", b"path invariant")]
            )
            result = request(
                "POST",
                f"/api/v1/conversations/{conversation}/attachments",
                body=body,
                headers={**session_headers(token), "Content-Type": content_type},
            )
            if result.status == 404:
                self.skipTest("message attachment upload endpoint is not available on this server")
            self.assertEqual(result.status, 200, result.body)
            name = result.json()["items"][0]["name"]
            self.assertEqual(name, expected_name)
            self.assertNotIn("/", name)
            self.assertNotIn("\\", name)
            self.assertFalse(len(name) > 1 and name[1] == ":")
