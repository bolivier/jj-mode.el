#!/bin/bash
# Test runner for jj-mode.el
# This script runs tests and handles dependency installation if needed

set -e

echo "Running jj-mode tests..."
echo ""

# Function to run tests
run_tests() {
    emacs --batch \
        --eval "(package-initialize)" \
        -l jj-mode.el \
        -l jj-mode-test.el \
        -f ert-run-tests-batch-and-exit 2>&1
}

# Try to run tests
if run_tests; then
    echo ""
    echo "All tests passed!"
    exit 0
else
    EXIT_CODE=$?

    # Check if it was a dependency error
    if [ $EXIT_CODE -eq 255 ]; then
        echo ""
        echo "Dependency error detected. Installing test dependencies..."
        echo ""

        if emacs --batch -l test-setup.el 2>&1; then
            echo ""
            echo "Dependencies installed. Retrying tests..."
            echo ""

            if run_tests; then
                echo ""
                echo "All tests passed!"
                exit 0
            else
                EXIT_CODE=$?
            fi
        fi
    fi

    echo ""
    echo "Some tests failed (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
fi
