"""Protocol/client tests use private Unix sockets, never the user's Feather session."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("feather_agent", Path(__file__).with_name("feather-agent.py"))
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


@contextlib.contextmanager
def mock_bridge(response):
    with tempfile.TemporaryDirectory(prefix="feather-protocol-") as directory:
        os.chmod(directory, 0o700)
        path = str(Path(directory) / "test.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(1)
        received = []
        def serve():
            with server:
                client, _ = server.accept()
                with client:
                    data = bytearray()
                    while b"\n" not in data:
                        data.extend(client.recv(4096))
                    received.append(json.loads(data))
                    encoded = (json.dumps(response) + "\n").encode()
                    for index in range(0, len(encoded), 117):
                        client.sendall(encoded[index:index + 117])
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        yield path, received
        worker.join(2)
        if worker.is_alive():
            raise AssertionError("Mock server did not complete")


class BridgeTests(unittest.TestCase):
    def test_fragmented_large_response_and_request_arguments(self):
        payload = {"text": "A" * 150_000, "title": "Feather"}
        with mock_bridge({"id": 1, "result": payload}) as (path, received):
            self.assertEqual(agent.request("page.snapshot", {"tabID": "test"}, path), payload)
        self.assertEqual(received[0]["params"], {"tabID": "test"})

    def test_operation_error_is_actionable(self):
        with mock_bridge({"id": 1, "error": {"code": "stale", "message": "Take a new snapshot"}}) as (path, _):
            with self.assertRaisesRegex(agent.BridgeError, "stale: Take a new snapshot"):
                agent.request("page.click", {"ref": "old"}, path)

    def test_response_id_must_match(self):
        with mock_bridge({"id": 2, "result": {}}) as (path, _):
            with self.assertRaisesRegex(agent.BridgeError, "Invalid bridge response"):
                agent.request("browser.info", path=path)

    def test_request_limits_are_checked_before_connection(self):
        with self.assertRaisesRegex(agent.BridgeError, "64 KiB"):
            agent.request("page.fill", {"value": "X" * 65536}, "/not/a/socket")
        with self.assertRaisesRegex(agent.BridgeError, "params must"):
            agent.request("tabs.list", [], "/not/a/socket")

    def test_private_socket_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "unsafe.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o666)
                with self.assertRaisesRegex(agent.BridgeError, "private"):
                    agent.request("browser.info", path=path)

    def test_missing_socket_gives_opt_in_instructions(self):
        with self.assertRaisesRegex(agent.BridgeError, "Enable Develop"):
            agent.request("browser.info", path="/tmp/feather-nonexistent-unit-test.sock")


class MCPTests(unittest.TestCase):
    def rpc(self, method, params=None):
        return agent.mcp_response({"jsonrpc": "2.0", "id": 10, "method": method, "params": params or {}}, "/unused")

    def test_initialize_and_notification(self):
        result = self.rpc("initialize", {"protocolVersion": "2025-06-18"})["result"]
        self.assertEqual(result["protocolVersion"], "2025-06-18")
        self.assertEqual(result["capabilities"], {"tools": {}})
        self.assertIsNone(agent.mcp_response({"jsonrpc": "2.0", "method": "notifications/initialized"}, "/unused"))

    def test_malformed_initialize_keeps_stdio_alive(self):
        for malformed in ({"unexpected": "object"}, ["unexpected", "array"]):
            messages = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": malformed}},
                {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            ]
            process = subprocess.run([sys.executable, str(Path(__file__).with_name("feather-agent.py")), "--mcp"],
                                     input="".join(json.dumps(message) + "\n" for message in messages),
                                     text=True, capture_output=True, timeout=5)
            self.assertEqual(process.returncode, 0, process.stderr)
            responses = [json.loads(line) for line in process.stdout.splitlines()]
            self.assertEqual(responses[0]["result"]["protocolVersion"], "2024-11-05")
            self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_tools_expose_strict_target_schema(self):
        tools = self.rpc("tools/list")["result"]["tools"]
        names = {tool["name"] for tool in tools}
        self.assertEqual(len(names), 16)
        self.assertNotIn("feather_page_evaluate", names)
        fill = next(tool for tool in tools if tool["name"] == "feather_page_fill")
        self.assertEqual(fill["inputSchema"]["required"], ["value"])
        self.assertIn("oneOf", fill["inputSchema"])

    def test_screenshot_becomes_mcp_image(self):
        with patch.object(agent, "request", return_value={"mimeType": "image/png", "data": "cG5n"}):
            result = self.rpc("tools/call", {"name": "feather_page_screenshot"})["result"]
            self.assertEqual(result["content"], [{"type": "image", "mimeType": "image/png", "data": "cG5n"}])

    def test_bridge_failure_is_tool_error(self):
        with patch.object(agent, "request", side_effect=agent.BridgeError("access is off")):
            result = self.rpc("tools/call", {"name": "feather_tabs_list"})["result"]
            self.assertTrue(result["isError"])
            self.assertIn("access is off", result["content"][0]["text"])

    def test_unknown_rpc_and_tool(self):
        self.assertEqual(self.rpc("not/a/method")["error"]["code"], -32601)
        self.assertTrue(self.rpc("tools/call", {"name": "missing"})["result"]["isError"])


if __name__ == "__main__":
    unittest.main()
