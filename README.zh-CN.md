[English](./README.md) · [简体中文](./README.zh-CN.md)

# auto-github-contributor

一个 Claude Code 插件：对任意 GitHub 仓库端到端跑通一次开源贡献流程 —— 自动发现 quick-win 候选（带标签的 issue + 仓库扫描），按 TDD 走 red/green/refactor 直到 lint/typecheck/tests 全绿，然后通过 `gh` 开 PR 并输出链接。

一条 slash 命令，覆盖完整流水线，适用于任何仓库。

---

## 简介

在 Claude Code 中调用 `/auto-contribute` 后，skill 会按 11 步交互式 playbook 执行：

1. **环境检查** —— 确认 `gh` / `git` / `jq` 已安装，`gh auth status` 正常。
2. **锁定目标仓库** —— 接受 `owner/name` 或 GitHub URL（缺参时交互式询问）。
3. **并行发现候选**：
   - 带标签的 issue（`good first issue`、`help wanted`、`documentation` 等）
   - 仓库扫描的 quick-win：拼写错误、缺测试、i18n 缺 key、可执行的 TODO
4. **排序挑选列表**，每一项都带时间和 LLM 成本估算。
5. **等待用户明确确认** 后才动手改代码。
6. **隔离工作区**：在 `$AGC_WORK_ROOT` 下建独立目录和功能分支。
7. **写 SPEC.md + TODO.md**，用模板生成。
8. **TDD 开发循环**（red → green → refactor），每个 todo 最多 20 轮。
9. **最终验证**：clean install + lint + typecheck + tests + build。
10. **提交、推送、开 PR**（`gh pr create`），优先推到 `TARGET_FORK`，否则推到 upstream。
11. **单独一行输出 PR URL**，方便用户点击。

安全约束：绝不 force-push；绝不提交到 `main`/`master`/`develop`；绝不在 `$AGC_WORK_ROOT` 外 `rm -rf`；未经授权绝不向外部系统（Slack、邮件等）发消息。

## 环境要求

- `gh`（GitHub CLI）—— 已登录（`gh auth login`，需要 `repo` scope）
- `git`
- `jq`
- Claude Code（本项目是 Claude Code 插件）

可选但推荐：

- `rg`（ripgrep）—— 没有时扫描脚本会回退到 `grep`
- `pnpm` / `yarn` / `npm` / `bun` —— 根据目标仓库的 lockfile 自动识别
- `python3` —— `create-pr.sh` 渲染 PR 正文模板时用到

## 安装

本仓库同时是一个 Claude Code 插件（`.claude-plugin/plugin.json`）。两种安装方式：

**A. 作为插件安装（推荐）**

克隆本仓库到 Claude Code 插件目录：

```bash
git clone https://github.com/nexu-io/auto-github-contributor.git ~/.claude/plugins/auto-github-contributor
```

重启 Claude Code。之后 `/auto-contribute` slash 命令应当出现，`auto-github-contributor` skill 也可被 Claude 按需调用。

**B. 仅安装 skill**

如果只想要 skill、不要 slash 命令，把 `skills/auto-github-contributor/` 拷到 `~/.claude/skills/`：

```bash
cp -R skills/auto-github-contributor ~/.claude/skills/
```

之后用自然语言触发即可（比如 "auto-contribute to `<repo>`"）——`SKILL.md` 里的 description 字段会匹配这些关键词。

## 使用

```text
/auto-contribute                               # 不带参数，会交互式问仓库
/auto-contribute cli/cli                       # owner/name 形式
/auto-contribute https://github.com/cli/cli    # URL 形式
```

在启动 Claude Code 前通过环境变量覆盖默认值（也可以放进 shell profile）：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `TARGET_REPO` | _（运行时询问）_ | upstream 的 `owner/name` |
| `TARGET_FORK` | _（空即推到 origin）_ | 功能分支推往哪个 fork |
| `AGC_BASE_BRANCH` | `main` | PR 的 base 分支 |
| `AGC_WORK_ROOT` | `$HOME/auto-gh-contrib-work` | 克隆工作区根目录 |
| `AGC_LABELS` | `good first issue,help wanted,documentation,good-first-issue` | 搜索 issue 用的标签 |
| `AGC_ISSUE_LIMIT` | `30` | 每个标签最多拉多少条 |
| `AGC_INSTALL_CMD` / `AGC_LINT_CMD` / `AGC_TYPECHECK_CMD` / `AGC_TEST_CMD` / `AGC_BUILD_CMD` | pnpm 风格 | dev-loop 兜底命令（lockfile 识别会覆盖它们） |
| `AGC_DEV_URL` | `http://localhost:5173` | 浏览器可视化校验的 URL |

## 如何测试

整个 skill 可以分三层来测。建议从 Layer 1 起 —— 成本最低、确定性最强，覆盖真正容易出问题的代码路径。

### Layer 1 —— 脚本冒烟测试（只读、安全）

所有脚本都在 `skills/auto-github-contributor/scripts/` 下，输出都是 `KEY=VAL` 或 JSON，可独立调用：

```bash
SKILL_DIR=skills/auto-github-contributor/scripts

# 1. 环境检查
bash "$SKILL_DIR/check-prereqs.sh"
# 预期: ✓ gh / ✓ git / ✓ jq / ✓ gh authed as <你的用户名>；exit 0

# 2. 用真实仓库跑 issue 发现
TARGET_REPO=cli/cli AGC_ISSUE_LIMIT=3 bash "$SKILL_DIR/fetch-issues.sh" \
  | jq '.[] | {number, title, score, labels}'
# 预期: 按 score 排序的 open issue 数组

# 3. 对任意克隆跑 quick-win 扫描
SCRATCH=/tmp/agc-smoke && rm -rf "$SCRATCH" \
  && git clone --depth 1 https://github.com/expressjs/express.git "$SCRATCH"
bash "$SKILL_DIR/scan-quick-wins.sh" --workdir "$SCRATCH" --max 20 \
  | jq 'group_by(.kind) | map({kind: .[0].kind, count: length})'
# 预期: 数组里包含 {typo, missing-test, i18n, todo} 中的若干种

# 4. 对会改状态的脚本做语法检查
bash -n "$SKILL_DIR/setup-workspace.sh"
bash -n "$SKILL_DIR/dev-loop-check.sh"
bash -n "$SKILL_DIR/create-pr.sh"
bash -n "$SKILL_DIR/browser-verify.sh"
```

### Layer 2 —— slash 命令 + skill 装载

在本仓库根目录启动 Claude Code，输入 `/auto-contribute`，检查：

- slash 命令能自动补全（说明 `commands/auto-contribute.md` 被识别）
- Claude 立即通过 Skill 工具加载 `auto-github-contributor`
- 先跑 `check-prereqs.sh`
- 通过 `AskUserQuestion` 交互式问目标仓库
- 并行拉 issue 与扫描 quick-win
- 展示带时间/成本估算的挑选列表，**然后停下来等确认**

在挑选列表处直接取消即可，不会产生 `_scratch` 之外的任何副作用。

### Layer 3 —— 真实端到端

建一个你自己的实验仓库（例如 `your-handle/agc-sandbox`），刻意埋一个 quick-win —— 比如在 `README.md` 里写 `# Teh setup guide`（注意 `Teh` 是错的）。然后：

```text
/auto-contribute your-handle/agc-sandbox
```

从挑选列表里选中这个 typo、同意继续，让 skill 走完完整流水线开出一个真 PR。验证完关掉 PR 就行。

小技巧：同时设 `TARGET_FORK=your-handle/agc-sandbox`，这样会直接推到同仓库的分支，不会提示推 origin 的确认。

## 工作原理

```
.claude-plugin/plugin.json          # 插件清单
commands/auto-contribute.md         # /auto-contribute slash 命令（薄壳）
skills/auto-github-contributor/
  SKILL.md                          # Claude 要读的 orchestration playbook
  scripts/
    config.sh                       # 共享环境变量 + 工具函数
    check-prereqs.sh                # gh/git/jq + 登录态检查
    fetch-issues.sh                 # 按标签发现 + 排序 issue
    scan-quick-wins.sh              # typo / 缺测试 / i18n / TODO 扫描
    setup-workspace.sh              # 克隆 + 创建功能分支
    dev-loop-check.sh               # red/green/final 阶段，识别 lockfile
    browser-verify.sh               # 浏览器可视化验证（stub）
    create-pr.sh                    # commit/push/开 PR/渲染正文
  templates/
    SPEC.template.md                # 问题/验收标准/方案/风险
    TODO.template.md                # 会镜像到 TaskCreate 的原子 todo
    PR-BODY.template.md             # 渲染到 .auto-pr/PR-BODY.md
```

`SKILL.md` 是 Claude 要遵守的契约；真正干活的是 scripts/。Claude 只做编排 —— 读脚本输出、在分支点做决定。

## 如何贡献

欢迎 PR。目前最有价值的方向：

1. **新增 quick-win 类型** —— 扩展 `scan-quick-wins.sh`，候选：
   - markdown 死链检查
   - 未使用的 export（ts-prune 风格）
   - 缺 JSDoc 的 public API
   - package.json 里过时的依赖版本 pin
2. **浏览器验证后端** —— `browser-verify.sh` 目前是有意保留的 stub。接上 Playwright / Puppeteer / chrome-devtools MCP 后端，让 UI 改动在开 PR 前先截一张图。
3. **多语言/框架 dev-loop** —— `dev-loop-check.sh` 当前只识别 JS 包管理器。欢迎加 Python（`uv` / `poetry` / `pip`）、Go、Rust 等。
4. **成本估算器** —— 挑选列表里的成本数字目前只是经验拍的。更靠谱的算法（按 token 加权的文件大小 × 动作类型）能帮用户更有信心地选。

### 贡献约定

- **脚本输出是机器可读的。** stdout 只写 `KEY=VAL` 或 JSON；人类日志走 stderr，通过 `agc::log` / `agc::err`。别混。
- **不允许静默 stub。** 新功能没接完就打印 `stub: <原因>`，让 PR 正文能把 caveat 带出来。
- **安全约束保持开启。** 绝不 force-push、绝不提交到 `main`/`master`/`develop`、绝不在 `$AGC_WORK_ROOT` 外 `rm -rf`。新加会改状态的代码路径必须顺手加 guard。
- **配置通过环境变量。** 新的可调项统一进 `config.sh`，给个合理默认值，并在本文件的环境变量表里补上一行。
- **Shell 风格。** 默认 `set -euo pipefail`（只在有明确理由时放宽，如 `scan-quick-wins.sh`）。用 `$(...)` 代替反引号，注意对扩展加引号。

### 本地开发循环

```bash
# 对全部脚本做语法检查
for f in skills/auto-github-contributor/scripts/*.sh; do bash -n "$f" || exit 1; done

# 对本地任意克隆跑扫描器
bash skills/auto-github-contributor/scripts/scan-quick-wins.sh --workdir /path/to/some/repo | jq .

# 装了 shellcheck 的话
shellcheck skills/auto-github-contributor/scripts/*.sh
```

### 提 issue

- 附上 Claude Code 版本、操作系统、`gh --version`。
- 粘出失败脚本的 stderr 日志（特别是 `[auto-gh]` 开头的那些行，信息量最大）。
- 如果是发现阶段的问题，把 `TARGET_REPO` 写进来 —— 不同仓库的标签集差异很大。

### PR checklist

- [ ] 所有改动过的脚本 `bash -n` 通过
- [ ] 输出仍然遵守「stdout 是数据 / stderr 是日志」的分工
- [ ] 新环境变量在 `README.md` 里有文档、在 `config.sh` 里有默认值
- [ ] 安全约束没有被削弱
- [ ] 改过 `SKILL.md` 的话，从头到尾读一遍 —— Claude 是严格按它执行的

## 许可证

MIT —— 详见 [LICENSE](LICENSE)。
