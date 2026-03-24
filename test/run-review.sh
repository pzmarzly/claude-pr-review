#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <owner/repo> <pr-number> [options]"
    echo ""
    echo "Run Claude PR review locally against a snapshotted PR."
    echo ""
    echo "Options:"
    echo "  --model <model>          Model alias or ID (default: claude-sonnet-4-6)"
    echo "  --max-budget-usd <n>     Max budget in USD (default: 15)"
    echo "  --prompt <file>          Prompt template file (default: prompt-template.txt)"
    echo "  --effort <level>         Effort level: low, medium, high, max (default: high)"
    echo "  --fresh                  Simulate first review (hide existing comments)"
    echo ""
    echo "Example: $0 facebook/bpfilter 464 --model sonnet"
    exit 1
}

# Defaults
MODEL="claude-sonnet-4-6"
BUDGET="15"
PROMPT_FILE=""
EFFORT="high"
FRESH=false

# Parse args
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --max-budget-usd) BUDGET="$2"; shift 2 ;;
        --prompt) PROMPT_FILE="$2"; shift 2 ;;
        --effort) EFFORT="$2"; shift 2 ;;
        --fresh) FRESH=true; shift ;;
        --help|-h) usage ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"
[[ $# -eq 2 ]] || usage

REPO="$1"
PR_NUMBER="$2"

[[ "$REPO" == */* ]] || { echo "ERROR: repo must be in owner/repo format"; exit 1; }

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots/$OWNER/$REPO_NAME/$PR_NUMBER"
REPO_DIR="$SCRIPT_DIR/repos/$OWNER/$REPO_NAME"
SCHEMA_PATH="$SCRIPT_DIR/schema.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SCRIPT_DIR/results/$OWNER/$REPO_NAME/$PR_NUMBER/$TIMESTAMP"

# --- Validation ---
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found in PATH"
    exit 1
fi

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
    echo "ERROR: No snapshot found at $SNAPSHOT_DIR"
    echo "Run first: bash test/snapshot.sh $REPO $PR_NUMBER"
    exit 1
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "ERROR: Schema not found at $SCHEMA_PATH"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found in PATH"
    exit 1
fi

# --- Fresh mode: create a clean snapshot copy without existing comments ---
if [[ "$FRESH" == true ]]; then
    FRESH_DIR="$RESULT_DIR/fresh-snapshot"
    mkdir -p "$FRESH_DIR"
    cp "$SNAPSHOT_DIR/metadata.json" "$SNAPSHOT_DIR/diff.patch" "$SNAPSHOT_DIR/files.json" "$FRESH_DIR/"
    echo '[]' > "$FRESH_DIR/review_comments.json"
    echo '[]' > "$FRESH_DIR/issue_comments.json"
    echo '[]' > "$FRESH_DIR/reviews.json"
    cp "$SNAPSHOT_DIR/snapshot_info.json" "$FRESH_DIR/"
    SNAPSHOT_DIR="$FRESH_DIR"
    echo "==> Fresh mode: using clean snapshot (no existing comments)"
fi

# --- Extract PR info from snapshot ---
HEAD_SHA="$(jq -r '.head.sha' "$SNAPSHOT_DIR/metadata.json")"
BASE_REF="$(jq -r '.base.ref' "$SNAPSHOT_DIR/metadata.json")"

# --- Clone or update target repo ---
echo "==> Preparing target repo: $REPO"
if [[ -d "$REPO_DIR/.git" ]]; then
    echo "    Updating existing clone..."
    git -C "$REPO_DIR" fetch origin --quiet
else
    echo "    Cloning $REPO (shallow)..."
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --depth=100 "https://github.com/$REPO.git" "$REPO_DIR"
fi

echo "    Checking out base branch: $BASE_REF"
git -C "$REPO_DIR" checkout "origin/$BASE_REF" --quiet 2>/dev/null || \
    git -C "$REPO_DIR" checkout "$BASE_REF" --quiet

# --- Build prompt ---
PROMPT_TEMPLATE="${PROMPT_FILE:-$SCRIPT_DIR/prompt-template.txt}"
[[ -f "$PROMPT_TEMPLATE" ]] || { echo "ERROR: Prompt template not found: $PROMPT_TEMPLATE"; exit 1; }
echo "==> Building prompt from $(basename "$PROMPT_TEMPLATE")..."
PROMPT="$(sed \
    -e "s|{{REPO}}|$REPO|g" \
    -e "s|{{PR_NUMBER}}|$PR_NUMBER|g" \
    -e "s|{{HEAD_SHA}}|$HEAD_SHA|g" \
    -e "s|{{SNAPSHOT_DIR}}|$SNAPSHOT_DIR|g" \
    -e "s|{{SCHEMA_PATH}}|$SCHEMA_PATH|g" \
    "$PROMPT_TEMPLATE")"

# --- Prepare result directory ---
mkdir -p "$RESULT_DIR"
echo "$PROMPT" > "$RESULT_DIR/prompt.txt"

# --- Build allowed tools list ---
ALLOWED_TOOLS="Read,LS,Grep,Glob,Task"
ALLOWED_TOOLS+=",Bash(cat:*),Bash(test:*),Bash(printf:*),Bash(jq:*),Bash(head:*),Bash(tail:*)"
ALLOWED_TOOLS+=",Bash(git:*),Bash(grep:*),Bash(find:*),Bash(ls:*),Bash(wc:*)"
ALLOWED_TOOLS+=",Bash(diff:*),Bash(sed:*),Bash(awk:*),Bash(sort:*),Bash(uniq:*)"

SCHEMA="$(cat "$SCHEMA_PATH")"

# --- Run Claude ---
echo "==> Running Claude review..."
echo "    Model:    $MODEL"
echo "    Effort:   $EFFORT"
echo "    Budget:   \$$BUDGET"
echo "    Repo:     $REPO_DIR"
echo "    Snapshot: $SNAPSHOT_DIR"
echo "    Results:  $RESULT_DIR"
echo ""

START_TIME="$(date +%s)"
EXIT_CODE=0

cd "$REPO_DIR"
echo "$PROMPT" | claude -p \
    --model "$MODEL" \
    --max-budget-usd "$BUDGET" \
    --effort "$EFFORT" \
    --output-format json \
    --json-schema "$SCHEMA" \
    --verbose \
    --allowedTools "$ALLOWED_TOOLS" \
    --add-dir "$SNAPSHOT_DIR" \
    > "$RESULT_DIR/raw_output.json" \
    2> "$RESULT_DIR/stderr.log" || EXIT_CODE=$?

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "WARNING: Claude exited with code $EXIT_CODE (see $RESULT_DIR/stderr.log)"
fi

# --- Post-process results ---
echo "==> Processing results..."

COMMENT_COUNT=0
COST_USD="0"
STOP_REASON="unknown"
NUM_TURNS=0

if [[ -s "$RESULT_DIR/raw_output.json" ]]; then
    # --output-format json produces a JSON array of messages.
    # Extract metadata from the "result" type message.
    COST_USD="$(jq '[.[] | select(.type == "result") | .total_cost_usd] | last // 0' "$RESULT_DIR/raw_output.json" 2>/dev/null || echo 0)"
    STOP_REASON="$(jq -r '[.[] | select(.type == "result") | .subtype] | last // "unknown"' "$RESULT_DIR/raw_output.json" 2>/dev/null || echo unknown)"
    NUM_TURNS="$(jq '[.[] | select(.type == "result") | .num_turns] | last // 0' "$RESULT_DIR/raw_output.json" 2>/dev/null || echo 0)"

    # With --json-schema, the structured output is delivered as a tool_use
    # block with name "StructuredOutput". Fall back to checking the last
    # text block in case the format changes.
    REVIEW_JSON="$(jq '
        [.[] | select(.type == "assistant") | .message.content[]
         | select(.type == "tool_use" and .name == "StructuredOutput")
         | .input] | last // empty
    ' "$RESULT_DIR/raw_output.json" 2>/dev/null)"

    if [[ -z "$REVIEW_JSON" ]] || [[ "$REVIEW_JSON" == "null" ]]; then
        # Fallback: check last text block for raw JSON
        REVIEW_JSON="$(jq -r '
            [.[] | select(.type == "assistant") | .message.content[]
             | select(.type == "text") | .text] | last // empty
        ' "$RESULT_DIR/raw_output.json" 2>/dev/null)"
    fi

    if [[ -n "$REVIEW_JSON" ]] && [[ "$REVIEW_JSON" != "null" ]]; then
        if echo "$REVIEW_JSON" | jq -e '.comments and .summary' &>/dev/null; then
            echo "$REVIEW_JSON" | jq '.' > "$RESULT_DIR/review.json"
        else
            echo "$REVIEW_JSON" > "$RESULT_DIR/last_response.txt"
            echo "    Note: Last response was not valid review JSON (budget may have run out)"
        fi
    fi

    if [[ -f "$RESULT_DIR/review.json" ]]; then
        jq -r '.summary // "No summary"' "$RESULT_DIR/review.json" > "$RESULT_DIR/summary.md"
        jq '.comments // []' "$RESULT_DIR/review.json" > "$RESULT_DIR/comments.json"
        COMMENT_COUNT="$(jq 'length' "$RESULT_DIR/comments.json")"
    fi
else
    echo "WARNING: No output from Claude"
fi

# --- Save run metadata ---
cat > "$RESULT_DIR/run_info.json" <<RUNEOF
{
  "repo": "$REPO",
  "pr_number": $PR_NUMBER,
  "head_sha": "$HEAD_SHA",
  "model": "$MODEL",
  "max_budget_usd": $BUDGET,
  "timestamp": "$TIMESTAMP",
  "duration_seconds": $DURATION,
  "cost_usd": $COST_USD,
  "stop_reason": "$STOP_REASON",
  "num_turns": $NUM_TURNS,
  "comment_count": $COMMENT_COUNT,
  "exit_code": $EXIT_CODE
}
RUNEOF

# --- Symlink latest ---
LATEST_LINK="$SCRIPT_DIR/results/$OWNER/$REPO_NAME/$PR_NUMBER/latest"
rm -f "$LATEST_LINK"
ln -s "$RESULT_DIR" "$LATEST_LINK"

echo ""
echo "==> Done!"
echo "    Duration: ${DURATION}s | Cost: \$${COST_USD} | Turns: $NUM_TURNS | Stop: $STOP_REASON"
echo "    Comments: $COMMENT_COUNT"
echo "    Results:  $RESULT_DIR/"
