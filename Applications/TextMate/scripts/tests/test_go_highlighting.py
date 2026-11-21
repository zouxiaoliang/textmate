"""Check the built-in Go grammar's visible scopes on representative code."""

import plistlib
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_builtin_bundle import main


with tempfile.TemporaryDirectory() as directory:
    main(Path(directory))
    path = Path(directory) / "Bundles/Built-in.tmbundle/Syntaxes/Go.tmLanguage"
    with path.open("rb") as file:
        GO = plistlib.load(file)


def scope_at(line, token, last=False):
    position = line.rindex(token) if last else line.index(token)
    for pattern in GO["patterns"]:
        if "match" not in pattern:
            continue
        for result in re.finditer(pattern["match"], line):
            if not result.start() <= position < result.end():
                continue
            for group, capture in pattern.get("captures", {}).items():
                if result.start(int(group)) <= position < result.end(int(group)):
                    return capture["name"]
            return pattern.get("name")
    return None


class GoHighlightingTest(unittest.TestCase):
    def test_declaration_and_types(self):
        self.assertEqual(scope_at("func newRootCommand() *cobra.Command {", "newRootCommand"), "entity.name.function")
        self.assertEqual(scope_at("func newRootCommand() *cobra.Command {", "Command", last=True), "entity.name.type")
        self.assertEqual(scope_at("var configPath string", "string"), "storage.type")

    def test_calls_and_fields(self):
        self.assertEqual(scope_at("signal.NotifyContext(ctx)", "NotifyContext"), "entity.name.function")
        self.assertEqual(scope_at("root.PersistentFlags().StringVarP(&path)", "StringVarP"), "entity.name.function")
        self.assertEqual(scope_at("cobra.Command{Short: title}", "Short"), "variable.other.property")
        self.assertEqual(scope_at("aiclicmd.Options{ConfigPath: path}", "ConfigPath"), "variable.other.property")

    def test_go_constants(self):
        self.assertEqual(scope_at("if ready == true {", "true"), "constant.language")


if __name__ == "__main__":
    unittest.main()
