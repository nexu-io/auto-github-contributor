---
name: auto-github-contributor
description: Interactively pick a quick-win contribution in any GitHub repo — either a labeled issue ("good first issue", "help wanted", docs) or a repo-scan candidate (typo, missing tests, i18n gap, actionable TODO). Runs a TDD dev-loop, opens a PR via gh, and returns the PR URL. Use when the user wants to auto-contribute to an open-source project end-to-end. Trigger words: auto-contribute, open a PR for me, find a good first issue, contribute to <repo>.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - TaskCreate
  - TaskUpdate
  - WebFetch
---

# auto-github-contributor — interactive OSS PR agent

One command, full pipeline, any repo:

1. **Check prerequisites** (`gh`, `git`, `jq`, gh auth) — guide the user to fix anything missing.
2. **Ask for the target repo** (`owner/name` or GitHub URL). Default fork to the authed `gh` user.
3. **Discover candidates** from two sources in parallel:
   - Labeled issues (`good first issue`, `help wanted`, `documentation`, etc.)
   - Repo scan for quick wins (typos, missing tests, i18n gaps, actionable TODOs)
4. **Present a ranked picklist** with estimated time + LLM cost per item.
5. **Wait for explicit user confirmation** before touching anything.
6. **Run the TDD dev-loop** (red → green → refactor) until lint / typecheck / tests all pass.
7. **Push + open PR** via `gh`. **Print the PR URL on its own line** so the user can click.

Scripts live next to this file under `scripts/`. Each script emits machine-readable `KEY=VAL` lines on stdout and logs to stderr. Source the shared helpers from every script:

```bash
source "$(dirname "$0")/config.sh"
```

Override config via env vars on invocation:

```bash
TARGET_REPO=owner/name TARGET_FORK=me/name bash <script>
```

## Execution steps — follow in order

### Step 1 — Prerequisite check (always first)

```bash
bash "$SKILL_DIR/scripts/check-prereqs.sh"
```

Reads `GH_USER=...` from stdout — capture it as the default fork owner.

- Exit code **0**: continue.
- Exit code **2**: surface the printed install / auth hint **verbatim** to the user and stop. Do **not** attempt token workarounds, `sudo` installs, or other shortcuts. The user runs the fix and restarts the flow.

### Step 2 — Resolve the target repo

Priority order:

1. If the slash command passed `TARGET_REPO` via `$ARGUMENTS`, normalize and use it.
2. Otherwise, ask the user via **AskUserQuestion** with one free-text prompt titled "Target repo" and hint `owner/name or https://github.com/owner/name`. If the user gives a URL, strip the protocol + trailing `.git`.
3. Ask for fork owner (optional) — default to `$GH_USER`. If the user confirms no fork, `TARGET_FORK` stays empty and we push to origin (create-pr.sh will warn 3s before doing so).

Validate: `gh repo view "$TARGET_REPO"` must succeed. If the repo doesn't exist or the user lacks access, stop and surface the gh error.

Export `TARGET_REPO` and `TARGET_FORK` for the rest of the session.

### Step 3 — Discover candidates (parallel)

**3a. Labeled issues**

```bash
bash "$SKILL_DIR/scripts/fetch-issues.sh" > /tmp/agc-issues.json
```

This queries each label in `$AGC_LABELS` (default: `good first issue, help wanted, documentation, good-first-issue`), merges, de-dupes, and ranks by a score that weights label specificity + freshness + body clarity. Top of the list = easiest high-quality pick.

**3b. Repo quick-win scan**

We need a shallow clone first so scan-quick-wins.sh has files to read. Use a scratch clone rather than the per-issue workdir (no branch yet):

```bash
SCRATCH="$AGC_WORK_ROOT/$(echo $TARGET_REPO | tr / -)/_scratch"
if [[ ! -d "$SCRATCH/.git" ]]; then
  git clone --depth 1 "https://github.com/$TARGET_REPO.git" "$SCRATCH"
fi
bash "$SKILL_DIR/scripts/scan-quick-wins.sh" --workdir "$SCRATCH" > /tmp/agc-quickwins.json
```

Returns an array of `{kind, title, summary, file, line, estimated_minutes, slug}`. Kinds: `typo`, `missing-test`, `i18n`, `todo`.

### Step 4 — Present the picklist

Render a single merged table. For each entry compute:

- **Estimated time** — issues: flat 60min (we'll refine after reading the body); quick-wins: `estimated_minutes` from the scanner.
- **Estimated cost** — use this rule of thumb, cheap and transparent:
  - typo, tiny doc fix: **~$0.30**
  - i18n, small test add: **~$1.50**
  - missing-test for a non-trivial module: **~$3**
  - TODO resolution or labeled issue: **~$5–8** depending on scope
  - UI-affecting issue that needs visual verification: **+$2**
  The point isn't precision — it's letting the user pick a ceiling.

Format as markdown so the user can scan quickly:

```
Discovered candidates in owner/name:

Quick wins (repo scan)
  1. [typo]         Fix "teh" → "the" in docs/intro.md:42           ~5 min  ~$0.30
  2. [missing-test] Add tests for src/utils/parse.ts                 ~30 min ~$1.50
  3. [i18n]         Fill 12 missing keys in locales/zh-CN.json       ~45 min ~$2.00
  ...

Issues (labeled)
  a. #124  Clarify CONTRIBUTING steps for monorepo setup             ~60 min ~$3.00
     labels: documentation · good first issue
  b. #131  Add --json flag to `cli list` command                     ~90 min ~$6.00
     labels: good first issue · help wanted
  ...
```

Then call **AskUserQuestion** titled "Pick one" with options: top quick-wins (numbered) + top issues (lettered) + "Other: paste issue # or slug" fallback + "Cancel".

If the user picks "Cancel", stop cleanly. No work, no clones beyond `_scratch`.

### Step 5 — Isolate the workdir

```bash
# For issue pick:
bash "$SKILL_DIR/scripts/setup-workspace.sh <ISSUE_NUMBER>"

# For quick-win pick:
bash "$SKILL_DIR/scripts/setup-workspace.sh <SLUG> --title "<short title>"
```

Capture `WORKDIR=...`, `BRANCH=...`, `ISSUE_TITLE=...` from stdout.

### Step 6 — Write the spec

Fill `templates/SPEC.template.md` → `$WORKDIR/.auto-pr/SPEC.md`:

- **Problem**: restate in your own words.
- **Acceptance criteria**: testable bullets.
- **Approach**: concrete change plan.
- **Files likely touched**: from a quick `rg`/`find` pass against the target repo.
- **Risk / blast radius**.
- **Test plan**: unit + integration + visual.

For quick-win picks, the spec can be minimal (1–2 acceptance criteria). Don't over-invest for a typo fix.

### Step 7 — Generate TODO breakdown + mirror to TaskCreate

Fill `templates/TODO.template.md` → `$WORKDIR/.auto-pr/TODO.md`, then create one TaskCreate entry per atomic todo. Prefer `failing test → minimal implementation → refactor` triples. Mark each TaskUpdate `in_progress` before starting, `completed` when dev-loop green.

### Step 8 — TDD dev-loop (per todo)

1. **Red**: write/update the failing test.
2. ```bash
   bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase red --workdir "$WORKDIR"
   ```
   Must exit 0 (tests fail as expected).
3. **Green**: minimal implementation.
4. ```bash
   bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase green --workdir "$WORKDIR"
   ```
   Runs install + lint + typecheck + test. Fail → diagnose → fix → re-run. **Do not mark the todo complete until this exits 0.**
5. **Refactor** if warranted — re-run step 4.
6. **Visual verification** (UI-affecting only):
   ```bash
   bash "$SKILL_DIR/scripts/browser-verify.sh" --url "$AGC_DEV_URL" --out "$WORKDIR/.auto-pr/screenshots/<todo-slug>.png"
   ```
   If the script is still a stub, continue — note `visual verify: stub — manual check pending` in the PR body.

Iteration cap: **20 loops per todo**. On exceed, write the blocker to `$WORKDIR/.auto-pr/BLOCKERS.md` and move on; the PR will be marked draft and call out the blocker.

### Step 9 — Final verification

```bash
bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase final --workdir "$WORKDIR"
```

Clean install + lint + typecheck + full tests + build. Must exit 0.

### Step 10 — Commit, push, open PR

```bash
# Issue-driven:
bash "$SKILL_DIR/scripts/create-pr.sh <ISSUE_NUMBER>"

# Quick-win:
bash "$SKILL_DIR/scripts/create-pr.sh <SLUG> --title "<short title>"
```

`create-pr.sh` commits, pushes to `$TARGET_FORK` (falls back to origin with a 3s abort window), renders the PR body from `SPEC.md` + `TODO.md` + screenshots + blockers, and opens the PR via `gh pr create`.

**Print the PR URL on its own line** to the user, e.g.:

```
PR opened: https://github.com/owner/name/pull/456
```

### Step 11 — Wrap up

Print a one-line recap: what was picked, PR URL, any stub hooks still pending. No extra summary files unless the user asks.

## Flow variations

- **User passes repo URL via slash command**: skip the "Ask for repo" prompt in Step 2.
- **User picks "Other" in Step 4**: fall back to a free-text prompt; accept either `#<issue>` or a slug. If `#<issue>`, route through the issue branch; otherwise treat as a quick-win slug and ask for a one-line title.
- **Discovery returns zero candidates**: tell the user the repo looks "clean" for the configured labels and scan heuristics. Offer to broaden labels (`AGC_LABELS`) or accept a manual issue number.

## Stub policy

Every script accepts `--dry-run` where it makes sense. Stub sections are marked:

```
# TODO(auto-gh): <what's missing>
```

Never silently skip verification — always emit a visible `stub: <reason>` line so the PR body includes the caveat.

## Safety rails

- **Never force-push.** `create-pr.sh` uses plain `git push -u <remote> <branch>`.
- **Never commit to upstream base branch.** Hard-coded guard: if the current branch is `main`/`master`/`develop`, abort.
- **Never `rm -rf`** outside `$AGC_WORK_ROOT`. Workdir paths are validated before any cleanup.
- **Never write to shared systems** (Slack, email, external services) unless the user explicitly asks.
- If `gh auth status` fails mid-flow, surface the error and stop — no token workarounds.
- Ask before doing anything destructive the user didn't explicitly request (force-push, branch deletion, rebase onto a shifted base).
