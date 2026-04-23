---
description: Find a quick-win contribution in a GitHub repo and open a PR end-to-end.
argument-hint: "[repo-url-or-owner/name]"
---

You are entering the **auto-github-contributor** flow.

User input (may be empty): `$ARGUMENTS`

## What to do right now

1. **Load the skill** by invoking the `auto-github-contributor` skill via the Skill tool. The skill owns the full execution playbook — do not reimplement it inline.

2. **Pass the user input forward**:
   - If `$ARGUMENTS` looks like a repo (`https://github.com/<owner>/<name>` or `<owner>/<name>`), set it as `TARGET_REPO` and skip the "ask for repo" step in the skill.
   - Otherwise, the skill will interactively ask for the repo URL via `AskUserQuestion`.

3. **Honor the interactive contract**:
   - Always run the prerequisite check first (`gh` installed + authed). If it fails, surface the install/auth hint and stop — do not try workarounds.
   - Always present the discovered candidates (labeled issues + repo-scan quick wins) with estimated time/cost, and **wait for explicit user confirmation** before starting the dev-loop.
   - At the end, print the PR URL on its own line so the user can click through.

Begin by invoking the skill now.
