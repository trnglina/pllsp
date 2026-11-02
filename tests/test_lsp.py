"""Protocol regressions: nix develop --command python3 -m unittest discover -s tests."""

import json
from pathlib import Path
import select
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIMES = (
    ("tpl", "-q", "-f", "main.pl", "-g", "main"),
    ("scryer-prolog", "-f", "main.pl", "-g", "main"),
)


def frame(value, *, ascii=False):
    body = json.dumps(value, ensure_ascii=ascii, separators=(",", ":")).encode()
    return raw_frame(body)


def raw_frame(body):
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def call(method, id=1, **extra):
    return dict(jsonrpc="2.0", id=id, method=method, **extra)


def notify(method):
    return dict(jsonrpc="2.0", method=method)


INITIALIZE = call("initialize", params=dict(processId=None, rootUri=None, capabilities={}))
FINISH = frame(call("shutdown", id=99)) + frame(notify("exit"))


def replies(data):
    result = []
    while data:
        header, data = data.split(b"\r\n\r\n", 1)
        key, value = header.split(b":", 1)
        assert key == b"Content-Length", header
        length = int(value)
        body, data = data[:length], data[length:]
        assert len(body) == length
        reply = json.loads(body)
        assert reply["jsonrpc"] == "2.0"
        result.append(reply)
    return result


class ProtocolTests(unittest.TestCase):
    def run_server(self, command, data, code=0):
        proc = subprocess.run(command, cwd=ROOT / "src", input=data,
                              capture_output=True, timeout=15)
        self.assertEqual(proc.returncode, code, proc.stderr.decode(errors="replace"))
        return replies(proc.stdout), proc.stderr

    def test_lifecycle(self):
        data = (frame(notify("initialized")) + frame(call("unknown", id=0))
                + frame(INITIALIZE) + frame(call("initialize", id=2))
                + frame(notify("unknown")) + frame(call("unknown", id=3))
                + frame(call("shutdown", id=4)) + frame(call("unknown", id=5))
                + frame(notify("exit")))
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output, stderr = self.run_server(command, data)
                self.assertEqual([r["id"] for r in output], [0, 1, 2, 3, 4, 5])
                self.assertEqual(output[0]["error"]["code"], -32002)
                self.assertTrue(output[1]["result"]["capabilities"]["documentFormattingProvider"])
                self.assertEqual(output[2]["error"]["code"], -32600)
                self.assertEqual(output[3]["error"]["code"], -32601)
                self.assertIsNone(output[4]["result"])
                self.assertEqual(output[5]["error"]["code"], -32600)
                self.assertEqual(stderr, b"")

    def test_invalid_envelopes(self):
        invalid = [[], 1, {}, {"method": "initialize", "id": 7},
                   dict(call("initialize"), jsonrpc="1.0"),
                   call(123), call("initialize", id=True),
                   call("initialize", id=1.5), call("initialize", id=None),
                   call("initialize", params=42)]
        for command in RUNTIMES:
            for message in invalid:
                with self.subTest(runtime=command[0], message=message):
                    output, _ = self.run_server(command, frame(message) + frame(INITIALIZE) + FINISH)
                    self.assertEqual(output[0]["error"]["code"], -32600)
                    self.assertIn("result", output[1])

    def test_bad_json_and_utf8_are_recoverable(self):
        invalid = [b"", b"{", b"[1,]", b'"\\ud800"', b'"\\udc00"',
                   b'"\\ud800\\u0041"', b'"\xff"', b'"\xc0\xaf"',
                   b'"\xed\xa0\x80"', b'"\xf4\x90\x80\x80"',
                   b'"\xe2\x82"', b'"\x01"', b"01", b"1e", b"true false"]
        for command in RUNTIMES:
            for body in invalid:
                with self.subTest(runtime=command[0], body=body):
                    output, _ = self.run_server(command, raw_frame(body) + frame(INITIALIZE) + FINISH)
                    self.assertEqual(output[0]["error"]["code"], -32700)
                    self.assertIsNone(output[0]["id"])
                    self.assertIn("result", output[1])

    def test_unicode_ids(self):
        for command in RUNTIMES:
            for ascii in (True, False):
                with self.subTest(runtime=command[0], ascii=ascii):
                    message = dict(INITIALIZE, id="日本語 😀\n\t\"\\")
                    output, _ = self.run_server(command, frame(message, ascii=ascii) + FINISH)
                    self.assertEqual(output[0]["id"], message["id"])

    def test_framing_errors_are_fatal(self):
        invalid = [b"X-Test: ignored\r\n\r\n{}",
                   b"Content-Length: -1\r\n\r\n",
                   b"Content-Length: 1.5\r\n\r\n",
                   b"Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
                   b"Content-Length: 2\r\nbroken\r\n\r\n{}",
                   b"Content-Length: 10\r\n\r\n{}",
                   b"Content-Length: 2\r\n", b"Content-Length:"]
        for command in RUNTIMES:
            for data in invalid:
                with self.subTest(runtime=command[0], data=data):
                    output, stderr = self.run_server(command, data, code=1)
                    self.assertEqual(output, [])
                    self.assertIn(b"transport_error", stderr)

    def test_eof_and_exit_codes(self):
        for command in RUNTIMES:
            for data, code in [(b"", 1), (frame(notify("exit")), 1),
                               (frame(INITIALIZE), 1),
                               (frame(INITIALIZE) + frame(call("shutdown")), 0)]:
                with self.subTest(runtime=command[0], data=data):
                    self.run_server(command, data, code=code)

    def test_lifecycle_params_do_not_change_state_on_error(self):
        data = (frame(call("initialize", params={})) + frame(INITIALIZE)
                + frame(call("shutdown", id=2, params={}))
                + frame(call("unknown", id=3)) + FINISH)
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output, _ = self.run_server(command, data)
                self.assertEqual(output[0]["error"]["code"], -32602)
                self.assertIn("result", output[1])
                self.assertEqual(output[2]["error"]["code"], -32602)
                self.assertEqual(output[3]["error"]["code"], -32601)

    def test_truncation_after_shutdown_is_not_clean_eof(self):
        for command in RUNTIMES:
            for tail in (b"Content-Length:", b"Content-Length: 10\r\n\r\n{}"):
                with self.subTest(runtime=command[0], tail=tail):
                    self.run_server(command, frame(INITIALIZE)
                                    + frame(call("shutdown")) + tail, code=1)

    def test_content_type_and_header_case(self):
        for command in RUNTIMES:
            for charset in (b"utf-8", b"utf8", b'"UTF-8"', b"iso-8859-1"):
                with self.subTest(runtime=command[0], charset=charset):
                    data = frame(INITIALIZE).replace(b"Content-Length", b"content-LENGTH", 1)
                    data = data.replace(b"\r\n\r\n", b"\r\nContent-Type: application/vscode-jsonrpc; charset="
                                        + charset + b"\r\nX-Test: ignored\r\n\r\n", 1)
                    if charset == b"iso-8859-1":
                        data += frame(INITIALIZE)
                    output, _ = self.run_server(command, data + FINISH)
                    if charset == b"iso-8859-1":
                        self.assertEqual(output.pop(0)["error"]["code"], -32700)
                    self.assertIn("result", output[0])

    def test_large_message(self):
        data = (frame(INITIALIZE)
                + frame(dict(notify("textDocument/didOpen"), params={"text": "文" * 20000}))
                + FINISH)
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output, _ = self.run_server(command, data)
                self.assertEqual(len(output), 2)

    def test_responses_and_notifications_are_ignored(self):
        messages = [notify("unknown"), dict(jsonrpc="2.0", id=42, result={}),
                    dict(jsonrpc="2.0", id=None, error=dict(code=-32600, message="Invalid request"))]
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output, _ = self.run_server(command, frame(INITIALIZE)
                                            + b"".join(frame(m) for m in messages) + FINISH)
                self.assertEqual(len(output), 2)

    def test_reply_without_newline_or_eof(self):
        # A client waits for initialize before sending anything else.
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                proc = subprocess.Popen(command, cwd=ROOT / "src", stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    proc.stdin.write(frame(INITIALIZE))
                    proc.stdin.flush()
                    self.assertTrue(select.select([proc.stdout], [], [], 5)[0], "initialize blocked")
                    # communicate closes stdin and checks the remaining lifecycle.
                    output, stderr = proc.communicate(FINISH, timeout=10)
                    self.assertEqual(proc.returncode, 0, stderr)
                    self.assertEqual(len(replies(output)), 2)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                    proc.communicate()


if __name__ == "__main__":
    unittest.main()
