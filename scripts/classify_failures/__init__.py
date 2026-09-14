"""Fixture-masked-green failure classifier.

Detects tests that newly pass only because a diff edited the test/fixture/
baseline — not the production code. See ``.claude/skills/classify-failures``.
"""
