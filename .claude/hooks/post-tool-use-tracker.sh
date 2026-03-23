#!/usr/bin/env bash
set -u

# Post-Tool-Use Context Tracker
# Auto-detects project structure and tracks file changes for context management

# This hook runs after every tool use to maintain context awareness
# Requires minimal customization - works across all projects

# Customize: Add your shared library paths here
SHARED_LIB_PATTERNS="${SHARED_LIB_PATTERNS:-shared/|lib/common/|shared-lib/}"
DOCS_PATTERNS="${DOCS_PATTERNS:-docs/.*\.md}"
# Customize: Command to run shared library tests
SHARED_LIB_TEST_CMD="${SHARED_LIB_TEST_CMD:-echo 'No shared lib test command configured'}"

# Track which files were modified — handle repos with no commits yet
MODIFIED_FILES=""
if git rev-parse HEAD >/dev/null 2>&1; then
    MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
else
    # New repo with no commits — check staged files instead
    MODIFIED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
fi

# Exit early if nothing modified
[ -z "$MODIFIED_FILES" ] && exit 0

# If working on database migrations, remind about safety checks
if echo "$MODIFIED_FILES" | grep -q "database/migrations/\|migrations/"; then
    echo "Reminder: Database migration modified. Don't forget:"
    echo "   - Write rollback procedure"
    echo "   - Add verification queries"
    echo "   - Update deployment gates checklist"
fi

# If working on shared libraries, remind about test coverage
if echo "$MODIFIED_FILES" | grep -qE "$SHARED_LIB_PATTERNS"; then
    echo "Reminder: Shared library modified. Required:"
    echo "   - Write tests FIRST (TDD)"
    echo "   - Run: $SHARED_LIB_TEST_CMD"
    echo "   - All dependent modules must be tested"
fi

# If working on deployment scripts, remind about safety gates
if echo "$MODIFIED_FILES" | grep -q "deploy.*\.sh\|\.github/workflows/"; then
    echo "Reminder: Deployment config modified. Verify:"
    echo "   - All deployment gates defined"
    echo "   - Rollback procedures documented"
    echo "   - No '|| true' workarounds"
fi

# If working on documentation, check file size
if echo "$MODIFIED_FILES" | grep -qE "$DOCS_PATTERNS"; then
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            LINES=$(wc -l < "$file")
            if [ "$LINES" -gt 700 ]; then
                echo "Warning: $file has $LINES lines (target: <500, max: 700)"
                echo "   Consider splitting into sub-modules for AI-friendly context"
            fi
        fi
    done <<< "$(echo "$MODIFIED_FILES" | grep -E "$DOCS_PATTERNS")"
fi

# If working on tests, check if corresponding code exists
# Covers: Python (test_*.py, *_test.py), TS/JS (*.test.ts/js), Go (*_test.go), Rust, Java
if echo "$MODIFIED_FILES" | grep -qE "test_.*\.py|_test\.(py|go)|\.test\.\(ts|js\)|\.spec\.\(ts|js\)|Test\.java|_spec\.rb"; then
    echo "Good: Tests being written (TDD compliant)"
fi

# ===== VERIFICATION REMINDERS =====

# If this looks like a bug fix commit, remind about verification
if git log -1 --oneline 2>/dev/null | grep -qi "fix\|bug\|resolve"; then
    echo "Bug fix detected. Before marking done:"
    echo "   - Verify original symptom is resolved (not just deployed)"
    echo "   - Run reproduction steps"
    echo "   - Check for regressions"
    echo "   - Would you bet \$100 the bug is actually fixed?"
fi

# Reuse MODIFIED_FILES for remaining checks (no repeated git diff calls)
DEBUG_MODIFIED=$(echo "$MODIFIED_FILES" | grep -E "debug|investigate|analysis" | head -1 || true)
TEST_MODIFIED=$(echo "$MODIFIED_FILES" | grep -E "test_|_test\." | head -1 || true)
if [ -n "$DEBUG_MODIFIED" ] && [ -z "$TEST_MODIFIED" ]; then
    echo "Investigation file modified but no test file."
    echo "   Write a regression test for the root cause."
fi

# If deployment scripts modified, remind about gates
if echo "$MODIFIED_FILES" | grep -q "deploy\|workflow"; then
    echo "Deployment config modified. Before deploying:"
    echo "   - All agents must complete review"
    echo "   - All findings must be addressed"
    echo "   - Post-deploy verification plan ready"
fi
