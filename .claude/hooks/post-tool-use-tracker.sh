#!/bin/bash

# Post-Tool-Use Context Tracker
# Auto-detects project structure and tracks file changes for context management

# This hook runs after every tool use to maintain context awareness
# Requires minimal customization - works across all projects

# Customize: Add your shared library paths here
SHARED_LIB_PATTERNS="${SHARED_LIB_PATTERNS:-shared/|lib/common/|shared-lib/}"
DOCS_PATTERNS="${DOCS_PATTERNS:-docs/.*\.md}"
# Customize: Command to run shared library tests
SHARED_LIB_TEST_CMD="${SHARED_LIB_TEST_CMD:-echo 'No shared lib test command configured'}"

# Track which files were modified in the last tool use
MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null || echo "")

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
    for file in $MODIFIED_FILES; do
        if [ -f "$file" ]; then
            LINES=$(wc -l < "$file")
            if [ "$LINES" -gt 700 ]; then
                echo "Warning: $file has $LINES lines (target: <700)"
                echo "   Consider splitting into sub-modules for AI-friendly context"
            fi
        fi
    done
fi

# If working on tests, check if corresponding code exists
if echo "$MODIFIED_FILES" | grep -q "test_.*\.py\|.*\.test\.\(ts\|js\)"; then
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

# If investigation/debug files modified but no test files, warn
DEBUG_MODIFIED=$(git diff --name-only HEAD 2>/dev/null | grep -E "debug|investigate|analysis" | head -1)
TEST_MODIFIED=$(git diff --name-only HEAD 2>/dev/null | grep -E "test_" | head -1)
if [ -n "$DEBUG_MODIFIED" ] && [ -z "$TEST_MODIFIED" ]; then
    echo "Investigation file modified but no test file."
    echo "   Write a regression test for the root cause."
fi

# If deployment scripts modified, remind about gates
if git diff --name-only HEAD 2>/dev/null | grep -q "deploy\|workflow"; then
    echo "Deployment config modified. Before deploying:"
    echo "   - All agents must complete review"
    echo "   - All findings must be addressed"
    echo "   - Post-deploy verification plan ready"
fi

# Track context for next interaction
echo "$MODIFIED_FILES" > /tmp/claude_modified_files.txt
