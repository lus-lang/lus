#!/usr/bin/env python3
"""Focused tests for documentation prose and fence validation."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


VALIDATOR_PATH = Path(__file__).with_name("validate-docs.py")
SPEC = importlib.util.spec_from_file_location("validate_docs", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_docs = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validate_docs
SPEC.loader.exec_module(validate_docs)


class DocumentationValidatorTests(unittest.TestCase):
    def fixture(self, content: str) -> tuple[tempfile.TemporaryDirectory, Path]:
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "fixture.md"
        path.write_text(content, encoding="utf-8")
        return directory, path

    def test_prose_rules_ignore_frontmatter_signatures_and_code(self) -> None:
        directory, path = self.fixture(
            """---
name: fixture
signature: "There is no tolist method; \u2014"
---

```lus
There is no tolist method; \u2014
```

The query iterator is the complete evaluation surface.
"""
        )
        self.addCleanup(directory.cleanup)

        messages = []
        for _, line in validate_docs.prose_lines(path):
            messages.extend(
                validate_docs.prose_style_messages(
                    validate_docs.strip_inline_code(line)
                )
            )
        self.assertEqual(messages, [])

    def test_rejected_alternative_phrase_is_reported_in_prose(self) -> None:
        messages = validate_docs.prose_style_messages(
            "There is no tolist method on a query."
        )
        self.assertIn("rejected alternative phrasing", messages)

    def test_lus_snippet_requires_lus_fence(self) -> None:
        directory, path = self.fixture("```lua\nprint('Lus')\n```\n")
        self.addCleanup(directory.cleanup)

        findings = validate_docs.fence_language_findings(path, allow_lua=False)
        self.assertEqual(len(findings), 1)
        self.assertIn("```lus", findings[0].message)

    def test_lus_fence_and_explicit_lua_exception_pass(self) -> None:
        lus_directory, lus_path = self.fixture("```lus\nprint('Lus')\n```\n")
        lua_directory, lua_path = self.fixture("```lua\nvim.cmd('set number')\n```\n")
        self.addCleanup(lus_directory.cleanup)
        self.addCleanup(lua_directory.cleanup)

        self.assertEqual(
            validate_docs.fence_language_findings(lus_path, allow_lua=False), []
        )
        self.assertEqual(
            validate_docs.fence_language_findings(lua_path, allow_lua=True), []
        )


if __name__ == "__main__":
    unittest.main()
