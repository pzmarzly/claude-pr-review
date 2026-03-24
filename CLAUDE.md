# claude-pr-review

GitHub Actions workflow for Claude-powered PR reviews. The workflow lives in
`.github/workflows/claude-pr-review.yaml` and has three jobs: **setup** (tracking
comment), **review** (Claude produces structured JSON), and **post** (posts comments).

## Local testing

The `test/` directory provides a harness for running the review step locally,
so you can iterate on the prompt and config without round-tripping through CI.

### Workflow

```
# 1. Snapshot a PR's data (diff, metadata, comments, reviews)
./test/snapshot.sh <owner/repo> <pr-number>

# 2. Run the review locally
./test/run-review.sh <owner/repo> <pr-number> [--model sonnet] [--max-budget-usd 15] [--effort high]

# 2b. Run as if no prior reviews exist (tests inline comment emission)
./test/run-review.sh <owner/repo> <pr-number> --fresh

# 3. Compare two runs
./test/diff-results.sh <result-dir-1> <result-dir-2>

# 3b. Analyze CI review comment batches from a snapshot
./test/diff-results.sh --analyze-snapshot <snapshot-dir>
```

### Files

- `test/schema.json` — the `REVIEW_SCHEMA` shared between the workflow and the local harness
- `test/prompt-template.txt` — modified review prompt that reads pre-fetched snapshot files instead of MCP tools. Phase 1 (gather context) is replaced; Phases 2-3 (review logic) are identical to the workflow.
- `test/snapshot.sh` — fetches PR data via `gh` CLI into `test/snapshots/<owner>/<repo>/<pr>/`
- `test/run-review.sh` — clones/updates the target repo, renders the prompt, runs `claude -p` with the same allowed tools (minus MCP), saves results to `test/results/.../<timestamp>/`
- `test/diff-results.sh` — diffs summary, comments, and run metadata between two result dirs

### Notes

- Results are saved as timestamped directories with a `latest` symlink.
- `test/snapshots/`, `test/repos/`, `test/results/` are gitignored.
- The `--output-format json` produces a message array; structured review JSON is extracted from the `StructuredOutput` tool_use block.
- `--dangerously-skip-permissions` doesn't work as root. The harness relies on `--allowedTools` to restrict to read-only tools instead.

## Rules

<!-- demo: this repo also serves as a CLAUDE.md demo/template -->
Make sure the repo doesn't contain any Python files.
