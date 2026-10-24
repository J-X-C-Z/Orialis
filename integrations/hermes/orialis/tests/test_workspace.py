import asyncio
import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from ..workspace import WorkspaceService, configured_workspaces, FILE_LIMIT, TEXT_LIMIT


class WorkspaceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.root = Path(self.temp.name)
        self.service = WorkspaceService(configured_workspaces([{"path": str(self.root), "name": "test", "terminal": True}]))

    async def asyncTearDown(self):
        await self.service.close()
        self.temp.cleanup()

    async def request(self, op, **values):
        return await self.service.handle("chat", {"op": op, "workspaceId": "w0", "_clientId": "mobile1", **values})

    async def test_no_implicit_workspace_and_no_absolute_path_disclosure(self):
        result = await WorkspaceService().handle("chat", {"op": "capabilities"})
        self.assertEqual(result["data"]["workspaces"], [])
        result = await self.request("capabilities")
        self.assertEqual(result["data"]["workspaces"][0]["name"], "test")
        self.assertNotIn(str(self.root), str(result))

    async def test_upload_list_preview_download_preserve_original(self):
        raw = "真实工作区 😀".encode()
        uploaded = await self.request("upload", path="note.txt", base64=base64.b64encode(raw).decode())
        self.assertTrue(uploaded["ok"])
        self.assertEqual(self.root.joinpath("note.txt").read_bytes(), raw)
        self.assertEqual((await self.request("list"))["data"]["entries"][0]["path"], "note.txt")
        self.assertEqual((await self.request("read", path="note.txt"))["data"]["text"], raw.decode())
        self.assertEqual(base64.b64decode((await self.request("download", path="note.txt"))["data"]["base64"]), raw)
        self.assertFalse((await self.request("upload", path="note.txt", base64=""))["ok"])
        self.assertEqual(self.root.joinpath("note.txt").read_bytes(), raw)

    async def test_path_traversal_and_device_paths_rejected(self):
        for path in ("../secret", "/etc/passwd", "C:/Windows/win.ini", "folder/../../outside", "\\\\server\\share", "name:stream", "bad\x00path"):
            with self.subTest(path=path):
                result = await self.request("read", path=path)
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["code"], "invalid_path")

    async def test_limits_and_binary_preview(self):
        self.root.joinpath("large").write_bytes(b"x" * (FILE_LIMIT + 1))
        self.root.joinpath("binary").write_bytes(b"\x00\xff")
        self.root.joinpath("text").write_bytes(b"x" * (TEXT_LIMIT + 1))
        self.assertEqual((await self.request("read", path="binary"))["error"]["code"], "binary_file")
        self.assertEqual((await self.request("read", path="text"))["error"]["code"], "file_too_large")
        self.assertEqual((await self.request("download", path="large"))["error"]["code"], "file_too_large")
        self.assertFalse((await self.request("upload", path="new", base64="!notbase64!"))["ok"])
        self.assertFalse(self.root.joinpath("new").exists())

    async def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as other:
            outside = Path(other)
            outside.joinpath("secret").write_text("private")
            try:
                self.root.joinpath("escape").symlink_to(outside, target_is_directory=True)
            except OSError:
                if os.name != "nt":
                    raise
                subprocess.run(["cmd", "/D", "/c", "mklink", "/J", str(self.root / "escape"), other], check=True, capture_output=True)
            self.assertEqual((await self.request("read", path="escape/secret"))["error"]["code"], "invalid_path")
            self.assertFalse((await self.request("upload", path="escape/leak", base64="YWJj"))["ok"])
            self.assertFalse(outside.joinpath("leak").exists())
            self.assertEqual((await self.request("list"))["data"]["entries"], [])

    async def test_git_diff_reads_actual_repository(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, timeout=10)
        self.root.joinpath("file.txt").write_text("before\n")
        subprocess.run(["git", "-C", str(self.root), "add", "file.txt"], check=True, timeout=10)
        subprocess.run(["git", "-C", str(self.root), "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "initial"], check=True, timeout=10)
        self.root.joinpath("file.txt").write_text("after\n")
        result = await self.request("diff")
        self.assertTrue(result["ok"], result)
        self.assertIn("-before", result["data"]["text"])
        self.assertIn("+after", result["data"]["text"])

    async def test_terminal_requires_explicit_permission(self):
        service = WorkspaceService(configured_workspaces([{"path": str(self.root)}]))
        result = await service.handle("chat", {"op": "terminal.open", "workspaceId": "w0"})
        self.assertEqual(result["error"]["code"], "terminal_unavailable")

    async def test_real_pty_write_read_resize_ownership_and_cleanup(self):
        if os.name == "nt" and importlib.util.find_spec("winpty") is None:
            self.skipTest("pywinpty not installed")
        result = await self.request("terminal.open", columns=90, rows=30)
        self.assertTrue(result["ok"], result)
        key = result["data"]["terminalId"]
        terminal = self.service.terminals[key]
        command = "echo ORIALIS_REAL_PTY\r\n" if os.name == "nt" else "printf 'ORIALIS_REAL_PTY\\n'\n"
        self.assertTrue((await self.request("terminal.write", terminalId=key, input=command))["ok"])
        output = ""
        for _ in range(60):
            output += (await self.request("terminal.read", terminalId=key))["data"]["output"]
            if output.count("ORIALIS_REAL_PTY") >= 2:
                break
            await asyncio.sleep(0.05)
        self.assertGreaterEqual(output.count("ORIALIS_REAL_PTY"), 2, output)
        self.assertTrue((await self.request("terminal.resize", terminalId=key, columns=100, rows=40))["ok"])
        if os.name == "nt":
            self.assertEqual(terminal.process.getwinsize(), (40, 100))
        stolen = await self.service.handle("different-chat", {"op": "terminal.read", "terminalId": key, "_clientId": "mobile1"})
        self.assertFalse(stolen["ok"])
        stolen = await self.request("terminal.read", terminalId=key, _clientId="mobile2")
        self.assertFalse(stolen["ok"])
        closed = await self.service.handle("_connection", {"op": "terminal.close_client", "_clientId": "mobile1"})
        self.assertTrue(closed["ok"], closed)
        self.assertNotIn(key, self.service.terminals)
        self.assertFalse(terminal.alive())
        self.assertFalse(terminal.process.isalive() if os.name == "nt" else terminal.process.poll() is None)
        self.assertTrue(terminal.reader.done())


if __name__ == "__main__":
    unittest.main()
