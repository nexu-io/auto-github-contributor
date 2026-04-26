[English](./README.md) · [简体中文](./README.zh-CN.md)

# auto-github-contributor

![auto-github-contributor](./assets/cover_en.png)

A Claude Code skill + slash command that takes any GitHub repo and drives a full OSS contribution pipeline end-to-end: discover a quick-win candidate (labeled issues + repo scan), run a TDD dev-loop until lint/typecheck/tests all pass, then open a PR via `gh` and print the URL.

One slash command, full pipeline, any repo.

---

## Overview

When you invoke `/auto-contribute` inside Claude Code, the skill runs an 11-step interactive playbook:

1. **Prereqs** — verify `gh`, `git`, `jq` are installed and `gh auth status` is green.
2. **Target repo** — accept `owner/name` or a GitHub URL (or ask interactively).
3. **Discover candidates in parallel**:
   - Labeled issues (`good first issue`, `help wanted`, `documentation`, …)
   - Repo-scan quick wins: typos, missing tests, i18n gaps, actionable TODOs
4. **Ranked picklist** with estimated time + LLM cost per item.
5. **Wait for explicit user confirmation** before touching anything.
6. **Isolate** a workdir + feature branch under `$AGC_WORK_ROOT`.
7. **Write SPEC.md + TODO.md** from templates.
8. **TDD dev-loop** per todo (red → green → refactor), capped at 20 iterations.
9. **Final verification**: clean install + lint + typecheck + tests + build.
10. **Commit, push, open PR** via `gh pr create`. Prefers `TARGET_FORK` over upstream.
11. **Print the PR URL** on its own line.

Safety rails: never force-push, never commit to `main`/`master`/`develop`, never `rm -rf` outside `$AGC_WORK_ROOT`, never post to external systems unasked.

## Requirements

- `gh` (GitHub CLI) — authenticated (`gh auth login`, `repo` scope)
- `git`
- `jq`
- Claude Code

Optional but nice to have:

- `rg` (ripgrep) — the scanner falls back to `grep` when absent
- `pnpm` / `yarn` / `npm` / `bun` — autodetected from the target repo's lockfile
- `python3` — used by `create-pr.sh` to render the PR body template

## Installation

This repo ships the slash command (`commands/auto-contribute.md`) and the skill (`skills/auto-github-contributor/`) as plain files — no plugin manifest, no marketplace registration. Drop them into Claude Code's user or project directory and they're live.

**A. User-level (recommended — available in every project)**

```bash
git clone https://github.com/nexu-io/auto-github-contributor.git /tmp/auto-github-contributor
mkdir -p ~/.claude/commands ~/.claude/skills
cp    /tmp/auto-github-contributor/commands/auto-contribute.md  ~/.claude/commands/
cp -R /tmp/auto-github-contributor/skills/auto-github-contributor ~/.claude/skills/
```

Restart Claude Code. `/auto-contribute` appears as a slash command, and Claude can also invoke the `auto-github-contributor` skill by name.

**B. Project-level (scoped to one repo)**

From the target repo's root:

```bash
git clone https://github.com/nexu-io/auto-github-contributor.git /tmp/auto-github-contributor
mkdir -p .claude/commands .claude/skills
cp    /tmp/auto-github-contributor/commands/auto-contribute.md  .claude/commands/
cp -R /tmp/auto-github-contributor/skills/auto-github-contributor .claude/skills/
```

The command and skill are then available only inside that project.

**C. Skill-only (no slash command)**

If you don't want the `/auto-contribute` command — just the skill — drop `skills/auto-github-contributor/` into `~/.claude/skills/` (or `.claude/skills/`) alone. Invoke it by asking Claude to "auto-contribute to `<repo>`" or similar; the description in `SKILL.md` handles trigger words.

## Usage

```text
/auto-contribute                               # skill will ask for the repo
/auto-contribute cli/cli                       # owner/name form
/auto-contribute https://github.com/cli/cli    # URL form
```

Override defaults via env vars before launching Claude Code (or export them in your shell profile):

| Variable | Default | Purpose |
|---|---|---|
| `TARGET_REPO` | _(prompted)_ | `owner/name` of the upstream |
| `TARGET_FORK` | _(empty → push to origin)_ | Where to push the feature branch |
| `AGC_BASE_BRANCH` | `main` | Base branch for the PR |
| `AGC_WORK_ROOT` | `$HOME/auto-gh-contrib-work` | Where workdirs get cloned |
| `AGC_LABELS` | `good first issue,help wanted,documentation,good-first-issue` | Issue labels to search |
| `AGC_ISSUE_LIMIT` | `30` | Max issues per label |
| `AGC_INSTALL_CMD` / `AGC_LINT_CMD` / `AGC_TYPECHECK_CMD` / `AGC_TEST_CMD` / `AGC_BUILD_CMD` | pnpm-flavored | Fallback dev-loop commands (overridden by lockfile detection) |
| `AGC_DEV_URL` | `http://localhost:5173` | URL for browser-verify stub |

## How to test

The skill has three testable layers. Start with Layer 1 — it's cheap, deterministic, and covers most of the real surface area.

### Layer 1 — Script smoke tests (read-only, safe)

All scripts live in `skills/auto-github-contributor/scripts/` and emit `KEY=VAL` lines or JSON. You can drive each one directly.

```bash
SKILL_DIR=skills/auto-github-contributor/scripts

# 1. Prerequisites
bash "$SKILL_DIR/check-prereqs.sh"
# expect: ✓ gh / ✓ git / ✓ jq / ✓ gh authed as <you>; exit 0

# 2. Issue discovery against a real repo
TARGET_REPO=cli/cli AGC_ISSUE_LIMIT=3 bash "$SKILL_DIR/fetch-issues.sh" \
  | jq '.[] | {number, title, score, labels}'
# expect: ranked array of open issues matching the configured labels

# 3. Quick-win scanner against any clone
SCRATCH=/tmp/agc-smoke && rm -rf "$SCRATCH" \
  && git clone --depth 1 https://github.com/expressjs/express.git "$SCRATCH"
bash "$SKILL_DIR/scan-quick-wins.sh" --workdir "$SCRATCH" --max 20 \
  | jq 'group_by(.kind) | map({kind: .[0].kind, count: length})'
# expect: an array with some of {typo, missing-test, i18n, todo}

# 4. Parse-check the scripts that mutate state
bash -n "$SKILL_DIR/setup-workspace.sh"
bash -n "$SKILL_DIR/dev-loop-check.sh"
bash -n "$SKILL_DIR/create-pr.sh"
bash -n "$SKILL_DIR/browser-verify.sh"
```

### Layer 2 — Slash command + skill loading

In a Claude Code session at the repo root, type `/auto-contribute` and verify:

- the slash command autocompletes (proves `commands/auto-contribute.md` is registered),
- Claude immediately invokes the `auto-github-contributor` skill,
- it runs `check-prereqs.sh` first,
- it asks for the target repo via `AskUserQuestion`,
- it fetches issues and scans quick-wins in parallel,
- it renders a picklist with time/cost estimates and **stops for confirmation**.

You can cancel at the picklist — no workdir is created beyond a `_scratch` shallow clone.

### Layer 3 — End-to-end on a sandbox repo

Create a throwaway repo you own (e.g. `your-handle/agc-sandbox`) with a known quick-win seeded — for instance, write `# Teh setup guide` (note `Teh`) in `README.md`. Then:

```text
/auto-contribute your-handle/agc-sandbox
```

Pick the typo from the list, approve, and let the skill drive through to a real PR. Close the PR once you've verified the flow.

Tip: set `TARGET_FORK=your-handle/agc-sandbox` so it pushes to the same repo (branch) instead of prompting about origin.

## How it works

```
commands/auto-contribute.md         # /auto-contribute slash command (thin wrapper)
skills/auto-github-contributor/
  SKILL.md                          # orchestration playbook Claude reads
  scripts/
    config.sh                       # shared env + helpers
    check-prereqs.sh                # gh/git/jq + auth check
    fetch-issues.sh                 # label-based issue discovery + ranking
    scan-quick-wins.sh              # typo / missing-test / i18n / TODO scanner (ignores local .auto-pr metadata)
    setup-workspace.sh              # clone + feature branch
    dev-loop-check.sh               # red/green/final phases, lockfile-aware, docs-only fallback
    browser-verify.sh               # visual-verification stub
    create-pr.sh                    # commit, push, open PR, render body
  templates/
    SPEC.template.md                # problem / acceptance / approach / risk
    TODO.template.md                # atomic todos mirrored to TaskCreate
    PR-BODY.template.md             # rendered into .auto-pr/PR-BODY.md
```

The skill file (`SKILL.md`) is the contract Claude follows. The scripts do the real work; Claude only orchestrates, reads their output, and makes decisions at the branching points.

## How to contribute

Contributions welcome. The most valuable additions right now:

1. **New quick-win kinds** — extend `scan-quick-wins.sh`. Good targets:
   - broken markdown links
   - unused exports (ts-prune-style)
   - missing JSDoc on public APIs
   - outdated dependency pins in a package.json section
2. **Browser-verify backend** — `browser-verify.sh` is a deliberate stub. Wire up a Playwright / Puppeteer / chrome-devtools MCP backend so UI changes get screenshotted before the PR.
3. **Language/framework dev-loops** — `dev-loop-check.sh` currently detects JS package managers. Add Python (`uv`/`poetry`/`pip`), Go, Rust, etc.
4. **Cost estimator** — the picklist cost numbers are hand-waved rules of thumb. A smarter estimator (token-weighted file size × action kind) would help users pick more confidently.

### Guidelines

- **Scripts emit machine-readable output.** Stdout is `KEY=VAL` lines or JSON. Human logs go to stderr via `agc::log` / `agc::err`. Don't mix them.
- **No silent stubs.** If a feature isn't wired up yet, print `stub: <reason>` so the PR body can surface the caveat.
- **Safety rails stay on.** Never force-push, never commit to `main`/`master`/`develop`, never `rm -rf` outside `$AGC_WORK_ROOT`. If you add a new mutation path, add the guard too.
- **Config via env vars.** New tunables go into `config.sh` with a sensible default and an entry in the README table above.
- **Shell style.** `set -euo pipefail` (relax only where explicitly justified, as in `scan-quick-wins.sh`). Prefer `$(...)` over backticks. Quote expansions.

### Local dev loop

```bash
# parse-check all scripts
for f in skills/auto-github-contributor/scripts/*.sh; do bash -n "$f" || exit 1; done

# smoke the scanner against a local clone
bash skills/auto-github-contributor/scripts/scan-quick-wins.sh --workdir /path/to/some/repo | jq .

# run shellcheck if you have it installed
shellcheck skills/auto-github-contributor/scripts/*.sh
```

### Filing issues

- Include the Claude Code version, OS, and `gh --version`.
- Paste the stderr log from the failing script (the `[auto-gh]` lines are the useful ones).
- If the issue is in discovery, include `TARGET_REPO` — different repos expose very different label sets.

### PR checklist

- [ ] `bash -n` passes for every touched script
- [ ] Script output still follows the stdout-is-data / stderr-is-log split
- [ ] New env vars documented in `README.md` and defaulted in `config.sh`
- [ ] Safety rails not weakened
- [ ] If you touched `SKILL.md`, re-read it end-to-end — Claude follows it literally

## License

MIT — see [LICENSE](LICENSE).
