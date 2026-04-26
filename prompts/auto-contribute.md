---
description: Find a quick-win contribution in a GitHub repo and open a PR end-to-end using the auto-github-contributor Codex skill.
argument-hint: "[repo-url-or-owner/name]"
---

You are entering the `auto-github-contributor` Codex flow.

User input (may be empty): `$ARGUMENTS`

## What to do right now

1. Load the `auto-github-contributor` skill and follow its playbook.
2. If `$ARGUMENTS` looks like `owner/name` or `https://github.com/owner/name`, treat it as `TARGET_REPO` and skip the repo question.
3. Always run the prerequisite check first.
4. Always present discovered candidates and wait for explicit user confirmation before making code changes or opening a PR.
5. At the end, print the PR URL on its own line.
