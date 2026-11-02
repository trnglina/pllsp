"""Formatter regressions through the LSP: nix develop --command python3 -m unittest discover -s tests.

Each case in fmt_cases/<category>/<name>.in.pl is formatted with the options
in <name>.options.json (FormattingOptions keys) and must produce <name>.out.pl
once the returned edits are applied. The expected output must then format to
no edits at all.
"""

import json
from pathlib import Path
import re
import subprocess
import unittest

from test_lsp import FINISH, ROOT, RUNTIMES, call, frame, replies

CASES = Path(__file__).resolve().parent / "fmt_cases"


def notify(method, **params):
    return dict(jsonrpc="2.0", method=method, params=params)


def initialize(encodings=None):
    capabilities = {}
    if encodings:
        capabilities["general"] = {"positionEncodings": encodings}
    return call("initialize", id=0, params=dict(processId=None, rootUri=None,
                                                capabilities=capabilities))


def did_open(uri, text):
    return notify("textDocument/didOpen",
                  textDocument=dict(uri=uri, languageId="prolog", version=1, text=text))


def formatting(id, uri, **options):
    return call("textDocument/formatting", id=id,
                params=dict(textDocument=dict(uri=uri),
                            options=dict(dict(tabSize=4, insertSpaces=True), **options)))


def range_formatting(id, uri, start, end):
    return call("textDocument/rangeFormatting", id=id,
                params=dict(textDocument=dict(uri=uri),
                            range=dict(start=dict(line=start[0], character=start[1]),
                                       end=dict(line=end[0], character=end[1])),
                            options=dict(tabSize=4, insertSpaces=True)))


def offset(text, position, encoding):
    lines = re.split(r"\r\n|\r|\n", text)
    line, units = position["line"], position["character"]
    if line >= len(lines):
        return len(text)
    endings = list(re.finditer(r"\r\n|\r|\n", text))
    base = endings[line - 1].end() if line else 0
    current = lines[line]
    if encoding == "utf-16":
        count = 0
        for i, ch in enumerate(current):
            if count >= units:
                return base + i
            count += 2 if ord(ch) > 0xFFFF else 1
        return base + len(current)
    return base + min(units, len(current))


def apply_edits(text, edits, encoding):
    spans = [(offset(text, e["range"]["start"], encoding),
              offset(text, e["range"]["end"], encoding), e["newText"]) for e in edits]
    for start, end, new in sorted(spans, reverse=True):
        text = text[:start] + new + text[end:]
    return text


def session(command, messages):
    data = frame(initialize()) + b"".join(frame(m) for m in messages) + FINISH
    proc = subprocess.run(command, cwd=ROOT / "src", input=data,
                          capture_output=True, timeout=120)
    assert proc.returncode == 0, proc.stderr.decode(errors="replace")
    assert proc.stderr == b"", proc.stderr.decode(errors="replace")
    return {r["id"]: r for r in replies(proc.stdout)}


def read(path):
    return path.read_bytes().decode()


class FormatterTests(unittest.TestCase):
    def test_golden(self):
        cases = sorted(CASES.glob("*/*.in.pl"))
        self.assertGreater(len(cases), 80)
        messages = []
        for i, case in enumerate(cases):
            options_file = case.with_name(case.name.replace(".in.pl", ".options.json"))
            options = json.loads(read(options_file)) if options_file.exists() else {}
            expected = read(case.with_name(case.name.replace(".in.pl", ".out.pl")))
            messages += [did_open(f"file:///in/{i}", read(case)),
                         formatting(1000 + 2 * i, f"file:///in/{i}", **options),
                         did_open(f"file:///out/{i}", expected),
                         formatting(1001 + 2 * i, f"file:///out/{i}", **options)]
        for command in RUNTIMES:
            output = session(command, messages)
            for i, case in enumerate(cases):
                name = str(case.relative_to(CASES))
                with self.subTest(runtime=command[0], case=name):
                    expected = read(case.with_name(case.name.replace(".in.pl", ".out.pl")))
                    edits = output[1000 + 2 * i]["result"]
                    self.assertEqual(apply_edits(read(case), edits, "utf-16"), expected)
                    self.assertEqual(output[1001 + 2 * i]["result"], [])

    def test_edits_touch_only_layout(self):
        text = "x( a ,b ):-c.\n"
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output = session(command, [did_open("file:///a.pl", text),
                                           formatting(1, "file:///a.pl")])
                edits = output[1]["result"]
                self.assertEqual(apply_edits(text, edits, "utf-16"), "x(a, b) :- c.\n")
                for e in edits:
                    self.assertTrue(text[offset(text, e["range"]["start"], "utf-16"):
                                         offset(text, e["range"]["end"], "utf-16")].isspace()
                                    or e["range"]["start"] == e["range"]["end"])

    def test_position_encodings(self):
        text = "x('😀😀',a ,b).\n"
        expected = "x('😀😀', a, b).\n"
        for command in RUNTIMES:
            for encodings, name in ((None, "utf-16"), (["utf-32", "utf-16"], "utf-32")):
                with self.subTest(runtime=command[0], encoding=name):
                    data = (frame(initialize(encodings)) + frame(did_open("file:///a.pl", text))
                            + frame(formatting(1, "file:///a.pl")) + FINISH)
                    proc = subprocess.run(command, cwd=ROOT / "src", input=data,
                                          capture_output=True, timeout=30)
                    output = {r["id"]: r for r in replies(proc.stdout)}
                    self.assertEqual(output[0]["result"]["capabilities"]["positionEncoding"], name)
                    self.assertEqual(apply_edits(text, output[1]["result"], name), expected)

    def test_range_formats_whole_clauses(self):
        text = "a:-b.\nc:-d,\n  e.\nf:-g.\n"
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output = session(command, [did_open("file:///a.pl", text),
                                           range_formatting(1, "file:///a.pl", (2, 1), (2, 1)),
                                           range_formatting(2, "file:///a.pl", (0, 0), (3, 0))])
                self.assertEqual(apply_edits(text, output[1]["result"], "utf-16"),
                                 "a:-b.\nc :- d,\n    e.\nf:-g.\n")
                self.assertEqual(apply_edits(text, output[2]["result"], "utf-16"),
                                 "a :- b.\nc :- d,\n    e.\nf:-g.\n")

    def test_range_boundaries(self):
        uri = "file:///a.pl"
        text = "a:-b.\nc:-d.\n"
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output = session(command, [did_open(uri, text),
                                           range_formatting(1, uri, (0, 0), (1, 0)),
                                           range_formatting(2, uri, (1, 0), (1, 0)),
                                           range_formatting(3, uri, (1, 0), (0, 0))])
                self.assertEqual(apply_edits(text, output[1]["result"], "utf-16"),
                                 "a :- b.\nc:-d.\n")
                self.assertEqual(apply_edits(text, output[2]["result"], "utf-16"),
                                 "a:-b.\nc :- d.\n")
                self.assertEqual(output[3]["error"]["code"], -32602)

    def test_line_endings(self):
        uri = "file:///a.pl"
        for command in RUNTIMES:
            for ending in ("\r", "\r\n", "\n"):
                with self.subTest(runtime=command[0], ending=repr(ending)):
                    text = ending.join(["a:-b. % comment", "c('😀',X):-", "q(X).", ""])
                    output = session(command, [did_open(uri, text), formatting(1, uri),
                                               range_formatting(2, uri, (2, 0), (2, 0)),
                                               range_formatting(3, uri, (1, 100), (1, 100))])
                    self.assertEqual(apply_edits(text, output[1]["result"], "utf-16"),
                                     "a :- b. % comment\nc('😀', X) :-\n    q(X).\n")
                    self.assertEqual(apply_edits(text, output[2]["result"], "utf-16"),
                                     "a:-b. % comment" + ending + "c('😀', X) :-\n    q(X).\n")
                    # A character beyond the line clamps before its terminator.
                    self.assertEqual(output[3]["result"], output[2]["result"])

    def test_document_sync(self):
        uri = "file:///a.pl"
        change = notify("textDocument/didChange", textDocument=dict(uri=uri, version=2),
                        contentChanges=[dict(text="p:-q.\n")])
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output = session(command, [did_open(uri, "a.\n"), change,
                                           formatting(1, uri),
                                           notify("textDocument/didClose", textDocument=dict(uri=uri)),
                                           formatting(2, uri)])
                self.assertEqual(apply_edits("p:-q.\n", output[1]["result"], "utf-16"),
                                 "p :- q.\n")
                self.assertEqual(output[2]["error"]["code"], -32602)

    def test_unparseable_text_is_left_alone(self):
        text = "a:-b.\nc:-'oops.\nd :-   e.\n"
        for command in RUNTIMES:
            with self.subTest(runtime=command[0]):
                output = session(command, [did_open("file:///a.pl", text),
                                           formatting(1, "file:///a.pl")])
                self.assertEqual(apply_edits(text, output[1]["result"], "utf-16"),
                                 "a :- b.\nc:-'oops.\nd :-   e.\n")

    def test_multiline_token_whitespace_is_preserved(self):
        texts = ["a:-b.\np(\"one  \ntwo\").\n",
                 "a:-b.\np('one  \ntwo').\n",
                 "a:-b.\nc:-'oops  \nd :-   e.\n"]
        for command in RUNTIMES:
            for text in texts:
                with self.subTest(runtime=command[0], text=text):
                    output = session(command, [did_open("file:///a.pl", text),
                                               formatting(1, "file:///a.pl")])
                    self.assertEqual(apply_edits(text, output[1]["result"], "utf-16"),
                                     text.replace("a:-b.", "a :- b."))


if __name__ == "__main__":
    unittest.main()
