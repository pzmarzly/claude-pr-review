#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--force] <owner/repo> <pr-number>"
    echo ""
    echo "Snapshot PR data for local review testing."
    echo ""
    echo "Options:"
    echo "  --force    Overwrite existing snapshot without prompting"
    echo ""
    echo "Example: $0 facebook/bpfilter 464"
    exit 1
}

FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --help|-h) usage ;;
        *) break ;;
    esac
done

[[ $# -eq 2 ]] || usage

REPO="$1"
PR_NUMBER="$2"

[[ "$REPO" == */* ]] || { echo "ERROR: repo must be in owner/repo format"; exit 1; }
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "ERROR: PR number must be a positive integer"; exit 1; }

if ! gh auth status &>/dev/null; then
    echo "ERROR: gh is not authenticated. Run: gh auth login"
    exit 1
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots/$OWNER/$REPO_NAME/$PR_NUMBER"

if [[ -d "$SNAPSHOT_DIR" ]] && [[ "$FORCE" != true ]]; then
    echo "Snapshot already exists at $SNAPSHOT_DIR"
    read -rp "Overwrite? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "Aborted."; exit 0; }
fi

mkdir -p "$SNAPSHOT_DIR"

echo "[1/6] Fetching PR metadata..."
gh api "repos/$REPO/pulls/$PR_NUMBER" > "$SNAPSHOT_DIR/metadata.json"

echo "[2/6] Fetching diff..."
gh pr diff "$PR_NUMBER" --repo "$REPO" --patch > "$SNAPSHOT_DIR/diff.patch"

echo "[3/6] Fetching changed files list..."
gh api "repos/$REPO/pulls/$PR_NUMBER/files" --paginate > "$SNAPSHOT_DIR/files.json"

echo "[4/6] Fetching reviews..."
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate > "$SNAPSHOT_DIR/reviews.json"

echo "[5/6] Fetching inline review comments..."
gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate > "$SNAPSHOT_DIR/review_comments.json"

echo "[6/6] Fetching issue comments..."
gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate > "$SNAPSHOT_DIR/issue_comments.json"

HEAD_SHA="$(jq -r '.head.sha' "$SNAPSHOT_DIR/metadata.json")"
cat > "$SNAPSHOT_DIR/snapshot_info.json" <<EOF
{
  "repo": "$REPO",
  "pr_number": $PR_NUMBER,
  "head_sha": "$HEAD_SHA",
  "snapshot_time": "$(date -Iseconds)",
  "gh_version": "$(gh --version | head -1)"
}
EOF

echo ""
echo "Snapshot saved to $SNAPSHOT_DIR"
echo "  HEAD SHA: $HEAD_SHA"
echo "  Files:"
ls -lh "$SNAPSHOT_DIR"/ | tail -n +2
