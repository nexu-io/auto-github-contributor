---
name: auto-github-contributor
description: Interactively pick a quick-win contribution in any GitHub repo, run a TDD dev-loop, open a PR via gh, and return the PR URL. Use when the user wants Codex to auto-contribute to an open-source project end-to-end. Trigger words: auto-contribute, open a PR for me, find a good first issue, contribute to <repo>.
---

# auto-github-contributor for Codex

This is a Codex skill. The shell scripts do the real work; your job is to orchestrate them safely, ask for missing inputs in plain chat, and stop at the required confirmation points.

One command, full pipeline, any repo:

1. Check prerequisites (`gh`, `git`, `jq`, gh auth).
2. Resolve the target repo (`owner/name` or GitHub URL).
3. Discover candidates from labeled issues and repo-scan quick wins.
4. Present a ranked picklist with estimated time and cost.
5. Wait for explicit user confirmation before touching code.
6. Run the TDD dev-loop until lint, typecheck, and tests pass.
7. Push and open a PR via `gh`, then print the PR URL on its own line.

## Codex-specific operating notes

- Codex does not use Claude's `AskUserQuestion`, `TaskCreate`, or `TaskUpdate`. Ask the user directly in plain text when you need input.
- Keep Codex's plan tracker aligned when useful, but `.auto-pr/TODO.md` is the durable task list inside the workdir.
- Use shell commands to run the scripts. On Windows, prefer `bash` if it resolves. If it does not, use the Git Bash executable directly. On this machine, the known path is `E:\poke\Git\bin\bash.exe`.
- Any `gh` command that talks to GitHub should be run with escalated network access when needed.
- Do not weaken the original safety rails. Keep the explicit confirmation step before any code changes or PR creation.

Scripts live next to this file under `scripts/`. Each script emits machine-readable `KEY=VAL` lines on stdout and logs to stderr.

## Execution steps

### Step 1 - Prerequisite check

Run:

```bash
bash "$SKILL_DIR/scripts/check-prereqs.sh"
```

Capture `GH_USER=...` from stdout and use it as the default fork owner.

- Exit code `0`: continue.
- Exit code `2`: show the printed install or auth hint verbatim to the user and stop.

### Step 2 - Resolve the target repo

Priority order:

1. If the invoking prompt passed `$ARGUMENTS`, normalize and use it as `TARGET_REPO`.
2. Otherwise, ask the user directly for `owner/name` or a GitHub URL.
3. Default `TARGET_FORK` to `GH_USER` when that is sensible. If the user explicitly wants no fork, leave it empty and warn that pushes will go to origin.

Validate with:

```bash
gh repo view "$TARGET_REPO"
```

If validation fails, surface the `gh` error and stop.

### Step 3 - Discover candidates in parallel

#### 3a. Labeled issues

```bash
bash "$SKILL_DIR/scripts/fetch-issues.sh" > /tmp/agc-issues.json
```

#### 3b. Repo quick-win scan

Use a shallow scratch clone:

```bash
SCRATCH="$AGC_WORK_ROOT/$(echo "$TARGET_REPO" | tr / -)/_scratch"
if [[ ! -d "$SCRATCH/.git" ]]; then
  git clone --depth 1 "https://github.com/$TARGET_REPO.git" "$SCRATCH"
fi
bash "$SKILL_DIR/scripts/scan-quick-wins.sh" --workdir "$SCRATCH" > /tmp/agc-quickwins.json
```

### Step 4 - Present the picklist

Render one merged markdown table for the user.

Cost heuristics:

- typo or tiny doc fix: about `$0.30`
- i18n or small test add: about `$1.50`
- non-trivial missing test: about `$3`
- TODO resolution or labeled issue: about `$5-$8`
- UI-affecting issue that needs visual verification: add about `$2`

Ask the user to pick one item explicitly. Accept:

- a numbered quick win
- a lettered issue
- `Other` with an issue number or slug
- `Cancel`

If the user cancels, stop cleanly.

### Step 5 - Isolate the workdir

For an issue:

```bash
bash "$SKILL_DIR/scripts/setup-workspace.sh" <ISSUE_NUMBER>
```

For a quick win:

```bash
bash "$SKILL_DIR/scripts/setup-workspace.sh" <SLUG> --title "<short title>"
```

Capture `WORKDIR=...`, `BRANCH=...`, and `ISSUE_TITLE=...`.

### Step 6 - Write the spec

Create `$WORKDIR/.auto-pr/SPEC.md` from `templates/SPEC.template.md` with:

- problem
- acceptance criteria
- approach
- likely touched files
- risk or blast radius
- test plan

Keep it short for trivial fixes.

### Step 7 - Generate TODO breakdown

Create `$WORKDIR/.auto-pr/TODO.md` from `templates/TODO.template.md`.

Prefer atomic triples:

- failing test
- minimal implementation
- refactor

### Step 8 - TDD dev-loop

For each todo:

1. Red: write or update the failing test.
2. Run:

```bash
bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase red --workdir "$WORKDIR"
```

3. Green: implement the minimal fix.
4. Run:

```bash
bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase green --workdir "$WORKDIR"
```

5. Refactor if needed, then rerun green.
6. For UI-affecting work, run:

```bash
bash "$SKILL_DIR/scripts/browser-verify.sh" --url "$AGC_DEV_URL" --out "$WORKDIR/.auto-pr/screenshots/<todo-slug>.png"
```

If visual verification is still stubbed, keep going and note that in the PR body.

Cap the loop at 20 iterations per todo. On cap, write the blocker to `$WORKDIR/.auto-pr/BLOCKERS.md` and continue. The PR should then be draft.

### Step 9 - Final verification

Run:

```bash
bash "$SKILL_DIR/scripts/dev-loop-check.sh" --phase final --workdir "$WORKDIR"
```

This must pass before opening the PR.

### Step 10 - Commit, push, open PR

Issue-driven:

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <ISSUE_NUMBER>
```

Quick win:

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <SLUG> --title "<short title>"
```

`create-pr.sh` commits, pushes, renders the PR body, and runs `gh pr create`.

Print the PR URL on its own line, for example:

```text
PR opened: https://github.com/owner/name/pull/456
```

### Step 11 - Wrap up

Print a one-line recap: what was picked, the PR URL, and any stubbed checks still pending.

## Flow variations

- If the user supplied a repo argument in the invoking prompt, skip the repo question.
- If the user picks `Other`, accept either `#<issue>` or a quick-win slug.
- If discovery returns zero candidates, explain that the repo looks clean for the current heuristics and offer broader labels or a manual issue number.

## Stub policy

If a script has a stubbed section, surface that visibly. Never silently pretend the verification happened.

## Safety rails

- Never force-push.
- Never commit or push directly from `main`, `master`, or `develop`.
- Never `rm -rf` outside `$AGC_WORK_ROOT`.
- Never write to external systems the user did not ask for.
- If `gh auth status` fails mid-flow, stop and ask the user to re-authenticate.
