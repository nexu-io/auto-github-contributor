$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$scriptsRoot = Join-Path $repoRoot "skills/auto-github-contributor/scripts"

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) {
    $script:failures.Add($Message)
  }
}

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Needle,
    [string]$Message
  )
  Assert-True ($Text.Contains($Needle)) $Message
}

function Read-File {
  param([string]$Path)
  Assert-True (Test-Path -LiteralPath $Path) "Missing file: $Path"
  if (Test-Path -LiteralPath $Path) {
    return Get-Content -LiteralPath $Path -Raw
  }
  return ""
}

Write-Host "[smoke] shell workflow regression checks"
Write-Host "[smoke] repo root: $repoRoot"

$scriptNames = @(
  "browser-verify.sh",
  "config.sh",
  "check-prereqs.sh",
  "dev-loop-check.sh",
  "setup-workspace.sh",
  "scan-quick-wins.sh",
  "fetch-issues.sh",
  "create-pr.sh"
)

$scriptText = @{}
foreach ($name in $scriptNames) {
  $path = Join-Path $scriptsRoot $name
  $text = Read-File -Path $path
  $scriptText[$name] = $text
  Assert-Contains $text "#!/usr/bin/env bash" "$name must keep bash shebang."
}

# config.sh invariants
$config = $scriptText["config.sh"]
Assert-Contains $config "set -euo pipefail" "config.sh should enforce strict shell mode."
Assert-Contains $config ': "${AGC_BASE_BRANCH:=main}"' "config.sh should default AGC_BASE_BRANCH=main."
Assert-Contains $config "agc::require_repo() {" "config.sh should define agc::require_repo."
Assert-Contains $config "TARGET_REPO must be in <owner>/<name> form" "config.sh should validate TARGET_REPO format."
Assert-Contains $config "agc::fork_repo() {" "config.sh should define fork repo helper."

# check-prereqs.sh invariants
$prereqs = $scriptText["check-prereqs.sh"]
Assert-Contains $prereqs "set -uo pipefail" "check-prereqs.sh should avoid immediate -e exit."
Assert-Contains $prereqs "check_bin gh" "check-prereqs.sh must verify gh."
Assert-Contains $prereqs "check_bin git" "check-prereqs.sh must verify git."
Assert-Contains $prereqs "check_bin jq" "check-prereqs.sh must verify jq."
Assert-Contains $prereqs "gh auth status" "check-prereqs.sh must check gh authentication."
Assert-Contains $prereqs "printf 'GH_USER=%s\n'" "check-prereqs.sh should emit GH_USER=..."
Assert-Contains $prereqs "printf 'READY=1\n'" "check-prereqs.sh should emit READY=1."

# browser-verify.sh invariants
$browserVerify = $scriptText["browser-verify.sh"]
Assert-Contains $browserVerify "playwright@latest screenshot" "browser-verify.sh should attempt Playwright first."
Assert-Contains $browserVerify "falling back to stub" "browser-verify.sh should log when it falls back to stub mode."
Assert-Contains $browserVerify ".stub.txt" "browser-verify.sh should preserve stub artifact output."

# dev-loop-check.sh invariants
$devLoop = $scriptText["dev-loop-check.sh"]
Assert-Contains $devLoop "set -euo pipefail" "dev-loop-check.sh should enforce strict shell mode."
Assert-Contains $devLoop "red|green|final" "dev-loop-check.sh should support red/green/final phases."
Assert-Contains $devLoop "is_docs_only_change()" "dev-loop-check.sh should include docs-only detection."
Assert-Contains $devLoop "git diff --check" "dev-loop-check.sh docs-only checks should include unstaged diff validation."
Assert-Contains $devLoop "git diff --cached --check" "dev-loop-check.sh docs-only checks should include staged diff validation."
Assert-Contains $devLoop "pnpm-lock.yaml" "dev-loop-check.sh should detect pnpm lockfile."
Assert-Contains $devLoop "package-lock.json" "dev-loop-check.sh should detect npm lockfile."
Assert-Contains $devLoop "AGC_INSTALL_CMD" "dev-loop-check.sh should keep install fallback override."

# setup-workspace.sh invariants
$setup = $scriptText["setup-workspace.sh"]
Assert-Contains $setup "agc::require_repo" "setup-workspace.sh must require TARGET_REPO."
Assert-Contains $setup "agc::require gh" "setup-workspace.sh must require gh."
Assert-Contains $setup "agc::require git" "setup-workspace.sh must require git."
Assert-Contains $setup "refusing to operate on path outside AGC_WORK_ROOT" "setup-workspace.sh must keep AGC_WORK_ROOT safety guard."
Assert-Contains $setup ".git/info/exclude" "setup-workspace.sh should write .git/info/exclude."
Assert-Contains $setup ".auto-pr/" "setup-workspace.sh should ignore .auto-pr metadata."

# scan-quick-wins.sh invariants
$scan = $scriptText["scan-quick-wins.sh"]
Assert-Contains $scan "set +e" "scan-quick-wins.sh should remain best-effort (set +e)."
Assert-Contains $scan 'kind: "typo"' "scan-quick-wins.sh should emit typo quick-wins."
Assert-Contains $scan 'kind: "missing-test"' "scan-quick-wins.sh should emit missing-test quick-wins."
Assert-Contains $scan 'kind: "i18n"' "scan-quick-wins.sh should emit i18n quick-wins."
Assert-Contains $scan 'kind: "todo"' "scan-quick-wins.sh should emit todo quick-wins."
Assert-Contains $scan "!.auto-pr" "scan-quick-wins.sh should continue excluding .auto-pr metadata."

# fetch-issues.sh invariants
$fetch = $scriptText["fetch-issues.sh"]
Assert-Contains $fetch "gh issue list" "fetch-issues.sh must use gh issue list."
Assert-Contains $fetch "unique_by(.number)" "fetch-issues.sh should de-dupe issues by number."
Assert-Contains $fetch "score:" "fetch-issues.sh should produce ranked scores."

# create-pr.sh invariants
$createPr = $scriptText["create-pr.sh"]
Assert-Contains $createPr "main|master|develop" "create-pr.sh must keep branch safety guard."
Assert-Contains $createPr "git reset --quiet -- .auto-pr" "create-pr.sh should avoid committing .auto-pr metadata."
Assert-Contains $createPr "gh pr create" "create-pr.sh should open PR via gh."
Assert-Contains $createPr "printf 'PR_URL=%s\n'" "create-pr.sh should emit PR_URL=..."
Assert-Contains $createPr "*.stub.txt" "create-pr.sh should surface browser stub artifacts."

# PR body template invariants
$prBodyTemplatePath = Join-Path $repoRoot "skills/auto-github-contributor/templates/PR-BODY.template.md"
$prBodyTemplate = Read-File -Path $prBodyTemplatePath
Assert-Contains $prBodyTemplate "Visual verification (screenshots / stubs)" "PR body template should mention both screenshots and stubs."
Assert-Contains $prBodyTemplate "visual artifacts" "PR body template should direct reviewers to visual artifacts."

# Keep this harness deterministic in constrained local environments.
$warnings.Add("Skipped runtime bash -n checks; this harness validates script workflow invariants only.")

if ($warnings.Count -gt 0) {
  foreach ($warning in $warnings) {
    Write-Warning $warning
  }
}

if ($failures.Count -gt 0) {
  Write-Host ""
  Write-Host "[smoke] FAILED ($($failures.Count) checks)"
  foreach ($failure in $failures) {
    Write-Host " - $failure"
  }
  exit 1
}

Write-Host ""
Write-Host "[smoke] PASS ($($scriptNames.Count) scripts validated)"
exit 0
