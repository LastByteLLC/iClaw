#!/bin/bash
# Run all iClaw tests: Swift (XCTest), JS extension tests
# Usage: ./scripts/test.sh [--swift] [--js] [--filter PATTERN]
#
# With no flags, runs all test suites.
# Examples:
#   ./scripts/test.sh                           # Run everything
#   ./scripts/test.sh --swift                   # Swift tests only
#   ./scripts/test.sh --js                      # JS tests only
#   ./scripts/test.sh --filter BrowserBridge    # Swift tests matching pattern

set -e
cd "$(dirname "$0")/.."

RUN_SWIFT=false
RUN_JS=false
FILTER=""

# Parse args
if [ $# -eq 0 ]; then
    RUN_SWIFT=true
    RUN_JS=true
else
    while [ $# -gt 0 ]; do
        case "$1" in
            --swift)  RUN_SWIFT=true ;;
            --js)     RUN_JS=true ;;
            --filter) FILTER="$2"; shift; RUN_SWIFT=true ;;
            *)        echo "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
fi

TOTAL_PASS=0
TOTAL_FAIL=0

# ─── Swift Tests ───
if $RUN_SWIFT; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Swift Tests (XCTest)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    SWIFT_CMD="swift test"
    if [ -n "$FILTER" ]; then
        SWIFT_CMD="swift test --filter iClawTests.$FILTER"
    fi

    if $SWIFT_CMD 2>&1; then
        echo "  ✓ Swift tests passed"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  ✗ Swift tests failed"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    echo ""
fi

# ─── JS Extension Tests ───
if $RUN_JS; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  JS Extension Tests (Node.js)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! command -v node &> /dev/null; then
        echo "  ⚠ Node.js not found — skipping JS tests"
    else
        JS_TEST_DIR="Tests/ExtensionTests"
        JS_TESTS_RUN=0
        JS_TESTS_FAIL=0

        for test_file in "$JS_TEST_DIR"/test_*.js; do
            [ -f "$test_file" ] || continue
            echo "  Running $(basename "$test_file")..."
            if node "$test_file"; then
                JS_TESTS_RUN=$((JS_TESTS_RUN + 1))
            else
                JS_TESTS_FAIL=$((JS_TESTS_FAIL + 1))
            fi
        done

        if [ $JS_TESTS_FAIL -eq 0 ]; then
            echo "  ✓ JS tests passed ($JS_TESTS_RUN suites)"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo "  ✗ JS tests failed ($JS_TESTS_FAIL/$((JS_TESTS_RUN + JS_TESTS_FAIL)) suites)"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    fi
    echo ""
fi

# ─── Summary ───
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Summary: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ $TOTAL_FAIL -eq 0 ]
