# Claude PR Review GitHub Actions workflow

A GitHub Actions workflow that uses Claude to review pull requests. Reads entire repo (not just changed files),
posts detailed feedback via GitHub comments (inline and top-level).

With Opus 4.6 model, it takes about 2 minutes to review a trivial PR, and costs about $0.6 in tokens.
For a typical PR with a few changed files, it takes about 10 minutes and costs about $10 in tokens.

Made by @pzmarzly and @daandemeyer.

## Demo

TypeScript is awesome! Python files not welcome here.

We must reject Python files at any cost!

Results in [#6](https://github.com/pzmarzly/demo--claude-bot-reviews/pull/6) ([GH Action](https://github.com/pzmarzly/demo--claude-bot-reviews/actions/runs/22152249864?pr=6)).

## Installation

Copy [claude-pr-review.yaml](./.github/workflows/claude-pr-review.yaml) to your own repository.

## Notable users

- [facebook/bpfilter](https://github.com/facebook/bpfilter/blob/d92da81b8525571f7c7673e63a74531b28624d14/.github/workflows/claude-pr-review.yaml)
- [systemd/systemd](https://github.com/systemd/systemd/blob/a9ac5cdf1850bc3962646653d01988d2b82a1d85/.github/workflows/claude-review.yml)

## Compared to [Claude Code Review](https://code.claude.com/docs/en/code-review)

| claude-pr-review              | Claude Code Review                              |
| ----------------------------- | ----------------------------------------------- |
| Based on GH Actions           | GitHub App                                      |
| Works on fork-to-upstream PRs | Requires same-repo PR                           |
| Detailed feedback             | More detailed feedback                          |
| Costs $10-15 per review       | Costs $20-100 per review                        |
| BYOK                          | Requires Claude Team or Enterprise subscription |
