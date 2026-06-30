#!/usr/bin/env bash
# autofix.sh — apply common ARM64 patches to failed TB2 tasks and retry builds
# Usage: ./autofix.sh [path/to/terminal-bench-2]
# Requires: triage.sh to have been run first

set -euo pipefail

REPO="${1:-.}"
RESULTS_DIR="arm_triage_results"
FAIL_LOG="$RESULTS_DIR/failed.txt"
FIXED_LOG="$RESULTS_DIR/fixed.txt"
MANUAL_LOG="$RESULTS_DIR/needs_manual.txt"
PATCH_LOG="$RESULTS_DIR/patches_applied.md"

if [ ! -f "$FAIL_LOG" ]; then
    echo "ERROR: $FAIL_LOG not found. Run triage.sh first."
    exit 1
fi

mkdir -p "$RESULTS_DIR/logs_fixed"
> "$FIXED_LOG"; > "$MANUAL_LOG"

declare -A PATCH_NOTES

patch_from_platform() {
    local df="$1"
    sed -i 's/^FROM \([^-]\)/FROM --platform=linux\/arm64 \1/g' "$df"
}

patch_binary_urls() {
    local df="$1"
    sed -i 's|uv-x86_64-unknown-linux-musl.tar.gz|uv-aarch64-unknown-linux-musl.tar.gz|g' "$df"
    sed -i 's|x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu|g' "$df"
    sed -i 's|x86_64-unknown-linux-musl|aarch64-unknown-linux-musl|g' "$df"
    sed -i 's|/releases/download/\([^/]*\)/\([^/]*\)_x86_64\([^/]*\)|/releases/download/\1/\2_aarch64\3|g' "$df"
    sed -i 's|/releases/download/\([^/]*\)/\([^/]*\)-x86_64\([^/]*\)|/releases/download/\1/\2-aarch64\3|g' "$df"
    sed -i 's|/releases/download/\([^/]*\)/\([^/]*\)_amd64\([^/]*\)|/releases/download/\1/\2_arm64\3|g' "$df"
}

patch_base_images() {
    local df="$1"
    sed -i 's|amd64/ubuntu|arm64v8/ubuntu|g' "$df"
    sed -i 's|amd64/debian|arm64v8/debian|g' "$df"
    sed -i 's|amd64/python|arm64v8/python|g' "$df"
}

patch_unavailable_packages() {
    local df="$1"
    sed -i 's/intel-mkl[^ ]* \?//g' "$df"
    sed -i 's/intel-opencl-icd \?//g' "$df"
    sed -i 's/libc6-i386 \?//g' "$df"
    sed -i 's/lib32[^ ]* \?//g' "$df"
}

while IFS='|' read -r task_name reason; do
    [ -z "$task_name" ] && continue

    task_env=$(find "$REPO" -path "*/${task_name}/environment" -type d | head -1)
    if [ -z "$task_env" ]; then
        echo "$task_name|directory_not_found" >> "$MANUAL_LOG"
        continue
    fi

    df="$task_env/Dockerfile"
    [ -f "$df" ] || continue

    cp "$df" "${df}.orig"
    patches_applied=()

    case "$reason" in
        binary_arch|missing_package_or_url)
            patch_binary_urls "$df"
            patch_unavailable_packages "$df"
            patches_applied+=("binary_url_rewrite" "remove_x86_packages")
            ;&
        base_image_no_arm|unknown)
            patch_from_platform "$df"
            patch_base_images "$df"
            patches_applied+=("from_platform" "base_image_swap")
            ;;
        qemu_issue)
            patch_from_platform "$df"
            patches_applied+=("from_platform")
            ;;
    esac

    printf "%-50s patching... " "$task_name"

    log_file="$RESULTS_DIR/logs_fixed/${task_name}.log"
    if docker buildx build \
        --platform linux/arm64 \
        --no-cache \
        --progress=plain \
        "$task_env" \
        > "$log_file" 2>&1; then
        echo "FIXED"
        echo "$task_name" >> "$FIXED_LOG"
        PATCH_NOTES["$task_name"]="${patches_applied[*]}"
    else
        echo "STILL FAILING — needs manual fix"
        echo "$task_name|$reason" >> "$MANUAL_LOG"
        cp "${df}.orig" "$df"
    fi

    rm -f "${df}.orig"

done < "$FAIL_LOG"

FIXED=$(wc -l < "$FIXED_LOG")
MANUAL=$(wc -l < "$MANUAL_LOG")

echo ""
echo "=== Autofix complete: $FIXED fixed, $MANUAL need manual attention ==="

cat > "$PATCH_LOG" << EOF
# ARM64 Auto-Patch Summary

## Auto-fixed ($FIXED)
| Task | Patches applied |
|------|----------------|
$(for t in "${!PATCH_NOTES[@]}"; do echo "| $t | ${PATCH_NOTES[$t]} |"; done)

## Still needs manual fix ($MANUAL)
| Task | Last known failure reason |
|------|--------------------------|
$(awk -F'|' '{print "| " $1 " | " $2 " |"}' "$MANUAL_LOG")
EOF

echo "Patch summary written to $PATCH_LOG"
echo ""
echo "Next: run harbor against your patched local tasks:"
echo "  harbor run --path ./terminal-bench-2 --agent oracle --n-concurrent 4"
