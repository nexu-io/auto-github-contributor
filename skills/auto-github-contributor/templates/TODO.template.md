# TODO — Issue #{{ISSUE_NUMBER}}

> Each item pairs a **failing test** with the **minimal implementation** that makes it pass (TDD).

## Setup

- [ ] Read full issue body + linked discussions
- [ ] Run `dev-loop-check.sh --phase green` once on clean `main` to confirm baseline is green
- [ ] Identify the module(s) that need changes (record in SPEC.md)

## TDD loop

- [ ] **Red 1** — Write failing test for `<behavior>`: …
  - [ ] **Green 1** — Minimal implementation passes the test
  - [ ] **Refactor 1** — Tidy without breaking green

- [ ] **Red 2** — …
  - [ ] **Green 2** — …
  - [ ] **Refactor 2** — …

## Verification

- [ ] `dev-loop-check.sh --phase green` → 0
- [ ] `browser-verify.sh` screenshots captured (or stub noted) for each visual acceptance item
- [ ] Self-review diff: no debug prints, no commented-out code, no unrelated changes

## Wrap-up

- [ ] `dev-loop-check.sh --phase final` → 0
- [ ] `create-pr.sh` to push + open PR
- [ ] Paste PR URL into recap memo
