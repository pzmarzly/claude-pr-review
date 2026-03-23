#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <result-dir-1> <result-dir-2>"
    echo "       $0 --analyze-snapshot <snapshot-dir>"
    echo ""
    echo "Compare two review runs or analyze CI comment batches."
    echo ""
    echo "Compare mode:"
    echo "  $0 test/results/.../20260322-120000 test/results/.../20260322-130000"
    echo ""
    echo "Snapshot analysis mode:"
    echo "  $0 --analyze-snapshot test/snapshots/facebook/bpfilter/464"
    exit 1
}

# --- Snapshot batch analysis mode ---
if [[ "${1:-}" == "--analyze-snapshot" ]]; then
    [[ $# -eq 2 ]] || usage
    SNAP_DIR="$(realpath "$2")"
    RC_FILE="$SNAP_DIR/review_comments.json"

    [[ -f "$RC_FILE" ]] || { echo "ERROR: No review_comments.json in $SNAP_DIR"; exit 1; }

    echo "=== CI Review Comment Batch Analysis ==="
    echo "    Snapshot: $SNAP_DIR"
    echo ""

    # Cluster comments by creation timestamp. Comments within 5 seconds
    # of each other are considered the same batch (bot posting in rapid succession).
    jq -r '
        [.[] | {
            created: .created_at,
            epoch: (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
            file: .path,
            line: (.line // .original_line // "?"),
            body: (.body | split("\n") | first | .[0:80])
        }] | sort_by(.epoch) |

        # Assign batch IDs: new batch when gap > 5 seconds
        reduce .[] as $c (
            {batches: [], current: [], last_epoch: 0};
            if (.last_epoch == 0 or ($c.epoch - .last_epoch) <= 5)
            then .current += [$c] | .last_epoch = $c.epoch
            else .batches += [.current] | .current = [$c] | .last_epoch = $c.epoch
            end
        ) | .batches + [.current] | map(select(length > 0)) |

        to_entries[] |
        "Batch \(.key + 1) (\(.value | length) comments, \(.value[0].created) — \(.value[-1].created)):\n" +
        (.value[] | "  \(.file):\(.line) — \(.body)") + "\n"
    ' "$RC_FILE"

    TOTAL="$(jq 'length' "$RC_FILE")"
    echo "Total: $TOTAL inline review comments"
    exit 0
fi

# --- Compare mode ---
[[ $# -eq 2 ]] || usage

DIR1="$(realpath "$1")"
DIR2="$(realpath "$2")"

for dir in "$DIR1" "$DIR2"; do
    [[ -d "$dir" ]] || { echo "ERROR: Not a directory: $dir"; exit 1; }
    [[ -f "$dir/run_info.json" ]] || { echo "ERROR: No run_info.json in $dir"; exit 1; }
done

echo "=== Run Info ==="
for i in 1 2; do
    DIR_VAR="DIR$i"
    DIR="${!DIR_VAR}"
    INFO="$DIR/run_info.json"
    echo "  Run $i: $(jq -r '.model' "$INFO") | $(jq '.duration_seconds' "$INFO")s | \$$(jq '.cost_usd' "$INFO") | $(jq '.comment_count' "$INFO") comments | $(jq -r '.stop_reason' "$INFO") | $(jq -r '.timestamp' "$INFO")"
done
echo ""

# --- Severity breakdown ---
echo "=== Severity Breakdown ==="
for i in 1 2; do
    DIR_VAR="DIR$i"
    DIR="${!DIR_VAR}"
    CF="$DIR/comments.json"
    if [[ -f "$CF" ]]; then
        MUST_FIX="$(jq '[.[] | select(.severity == "must-fix")] | length' "$CF")"
        SUGGESTION="$(jq '[.[] | select(.severity == "suggestion")] | length' "$CF")"
        NIT="$(jq '[.[] | select(.severity == "nit")] | length' "$CF")"
        TOTAL="$(jq 'length' "$CF")"
        echo "  Run $i: $TOTAL total — $MUST_FIX must-fix, $SUGGESTION suggestion, $NIT nit"
    else
        echo "  Run $i: (no comments.json)"
    fi
done
echo ""

# --- Per-file issue counts ---
echo "=== Per-File Issue Counts ==="
if [[ -f "$DIR1/comments.json" ]] && [[ -f "$DIR2/comments.json" ]]; then
    # Build a combined list of all files, show counts from each run
    jq -r '[.[] | .file] | sort | unique | .[]' "$DIR1/comments.json" "$DIR2/comments.json" 2>/dev/null | sort -u | while read -r file; do
        C1="$(jq --arg f "$file" '[.[] | select(.file == $f)] | length' "$DIR1/comments.json")"
        C2="$(jq --arg f "$file" '[.[] | select(.file == $f)] | length' "$DIR2/comments.json")"
        printf "  %-60s  run1: %d  run2: %d" "$file" "$C1" "$C2"
        if [[ "$C1" -ne "$C2" ]]; then
            printf "  (%+d)" $((C2 - C1))
        fi
        echo ""
    done
else
    echo "  (one or both comments files missing)"
fi
echo ""

# --- Unique vs shared issues ---
echo "=== Issue Coverage ==="
if [[ -f "$DIR1/comments.json" ]] && [[ -f "$DIR2/comments.json" ]]; then
    # For matching, we use file + line (within 3 lines) + similar body.
    # Simplified: match on file + exact line for now.
    ONLY_1="$(jq -r --slurpfile c2 "$DIR2/comments.json" '
        [.[] | . as $c |
            if ($c2[0] | map(select(.file == $c.file and
                (if .line and $c.line then ((.line - $c.line) | fabs) <= 3 else .file == $c.file and (.line == null) and ($c.line == null) end)
            )) | length) == 0
            then $c else empty end
        ] | length
    ' "$DIR1/comments.json")"

    ONLY_2="$(jq -r --slurpfile c1 "$DIR1/comments.json" '
        [.[] | . as $c |
            if ($c1[0] | map(select(.file == $c.file and
                (if .line and $c.line then ((.line - $c.line) | fabs) <= 3 else .file == $c.file and (.line == null) and ($c.line == null) end)
            )) | length) == 0
            then $c else empty end
        ] | length
    ' "$DIR2/comments.json")"

    TOTAL_1="$(jq 'length' "$DIR1/comments.json")"
    TOTAL_2="$(jq 'length' "$DIR2/comments.json")"
    SHARED_1=$((TOTAL_1 - ONLY_1))

    echo "  Run 1: $TOTAL_1 total, $ONLY_1 unique (not in run 2)"
    echo "  Run 2: $TOTAL_2 total, $ONLY_2 unique (not in run 1)"
    echo "  Shared (same file, line within 3): ~$SHARED_1"

    if [[ "$ONLY_2" -gt 0 ]]; then
        echo ""
        echo "  Issues unique to run 2:"
        jq -r --slurpfile c1 "$DIR1/comments.json" '
            .[] | . as $c |
            if ($c1[0] | map(select(.file == $c.file and
                (if .line and $c.line then ((.line - $c.line) | fabs) <= 3 else .file == $c.file and (.line == null) and ($c.line == null) end)
            )) | length) == 0
            then "    [\(.severity)] \(.file):\(.line // "?") — \(.body | split("\n") | first | .[0:80])"
            else empty end
        ' "$DIR2/comments.json"
    fi

    if [[ "$ONLY_1" -gt 0 ]]; then
        echo ""
        echo "  Issues unique to run 1:"
        jq -r --slurpfile c2 "$DIR2/comments.json" '
            .[] | . as $c |
            if ($c2[0] | map(select(.file == $c.file and
                (if .line and $c.line then ((.line - $c.line) | fabs) <= 3 else .file == $c.file and (.line == null) and ($c.line == null) end)
            )) | length) == 0
            then "    [\(.severity)] \(.file):\(.line // "?") — \(.body | split("\n") | first | .[0:80])"
            else empty end
        ' "$DIR1/comments.json"
    fi
else
    echo "  (one or both comments files missing)"
fi
echo ""

# --- Summary diff ---
echo "=== Summary Diff ==="
if [[ -f "$DIR1/summary.md" ]] && [[ -f "$DIR2/summary.md" ]]; then
    diff --color=always -u "$DIR1/summary.md" "$DIR2/summary.md" || true
else
    echo "  (one or both summaries missing)"
fi
echo ""

# --- Raw comments diff ---
echo "=== Comments JSON Diff ==="
if [[ -f "$DIR1/comments.json" ]] && [[ -f "$DIR2/comments.json" ]]; then
    diff --color=always -u \
        <(jq -S 'sort_by(.file, .line // 0)' "$DIR1/comments.json") \
        <(jq -S 'sort_by(.file, .line // 0)' "$DIR2/comments.json") || true
else
    echo "  (one or both comments files missing)"
fi
