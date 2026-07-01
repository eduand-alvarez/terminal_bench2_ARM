#!/usr/bin/env bash
# triage.sh — attempt linux/arm64 build for every TB2 task
# Usage: ./triage.sh [path/to/terminal-bench-2]

set -euo pipefail

REPO="${1:-.}"
RESULTS_DIR="arm_triage_results"
PASS_LOG="$RESULTS_DIR/passed.txt"
FAIL_LOG="$RESULTS_DIR/failed.txt"
SKIP_LOG="$RESULTS_DIR/skipped.txt"
REPORT="$RESULTS_DIR/report.md"

mkdir -p "$RESULTS_DIR/logs"
> "$PASS_LOG"; > "$FAIL_LOG"; > "$SKIP_LOG"

if ! docker buildx inspect 2>/dev/null | grep -q "linux/arm64"; then
    echo "ERROR: No ARM64 buildx builder found."
    echo "Run: docker buildx create --name armbuilder --use && docker buildx inspect --bootstrap"
    exit 1
fi

TASKS=()
while IFS= read -r -d '' df; do
    TASKS+=("$(dirname "$df")")
done < <(find "$REPO" -path "*/environment/Dockerfile" -print0 | sort -z)

TOTAL=${#TASKS[@]}
PASS=0; FAIL=0; SKIP=0
echo "Found $TOTAL tasks. Starting ARM64 triage..."
echo ""

for task_env in "${TASKS[@]}"; do
    task_dir=$(dirname "$task_env")
    task_name=$(basename "$task_dir")
    log_file="$RESULTS_DIR/logs/${task_name}.log"

    printf "%-50s " "$task_name"

    if [ ! -f "$task_env/Dockerfile" ]; then
        echo "SKIP (no Dockerfile)"
        echo "$task_name" >> "$SKIP_LOG"
        ((SKIP++)) || true
        continue
    fi

    if docker buildx build \
        --platform linux/arm64 \
        --no-cache \
        --progress=plain \
        "$task_env" \
        > "$log_file" 2>&1; then
        echo "PASS"
        echo "$task_name" >> "$PASS_LOG"
        ((PASS++)) || true
    else
        reason="unknown"
        if grep -qi "exec format error\|cannot execute binary\|no match for platform" "$log_file"; then
            reason="binary_arch"
        elif grep -qi "does not exist\|not found\|404" "$log_file"; then
            reason="missing_package_or_url"
        elif grep -qi "FROM.*--platform" "$log_file"; then
            reason="base_image_no_arm"
        elif grep -qi "qemu\|multiarch" "$log_file"; then
            reason="qemu_issue"
        fi
        echo "FAIL ($reason)"
        echo "$task_name|$reason" >> "$FAIL_LOG"
        ((FAIL++)) || true
    fi
done

echo ""
echo "=== Triage complete: $PASS passed, $FAIL failed, $SKIP skipped of $TOTAL ==="

cat > "$REPORT" << EOF
# TB2 ARM64 Triage Report

Generated: $(date)
Total tasks: $TOTAL | Passed: $PASS | Failed: $FAIL | Skipped: $SKIP

## Passed ($PASS)
$(cat "$PASS_LOG" | sed 's/^/- /')

## Failed ($FAIL)
| Task | Failure reason |
|------|---------------|
$(awk -F'|' '{print "| " $1 " | " $2 " |"}' "$FAIL_LOG")

## Skipped ($SKIP)
$(cat "$SKIP_LOG" | sed 's/^/- /')

## Next step
Run \`./autofix.sh\` to attempt automatic patches on failed tasks.
Per-task build logs are in \`arm_triage_results/logs/\`.
EOF

echo "Report written to $REPORT"
