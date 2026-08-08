import json

from quiz_harness.service import escape_json_string_controls


def test_escapes_literal_newline_inside_json_string() -> None:
    malformed = '{"prompt": "first line\nsecond line", "count": 2}'
    normalized, count = escape_json_string_controls(malformed)
    assert count == 1
    assert json.loads(normalized) == {
        "prompt": "first line\nsecond line",
        "count": 2,
    }


def test_preserves_legal_json_whitespace_and_escapes() -> None:
    source = '{\n  "prompt": "line one\\nline two",\n  "count": 2\n}\n'
    normalized, count = escape_json_string_controls(source)
    assert count == 0
    assert normalized == source
