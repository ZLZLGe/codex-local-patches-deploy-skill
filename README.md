# Codex 本地补丁重新部署 Skill

这个 Skill 用来在 Codex Desktop 更新后，重新部署本地补丁。

主要能力：

- 配置第三方 API provider。
- 强制开启 Fast mode。
- 强制开启 Goal。
- 可选安装并校验 Remote Control 使用的 `remote.json`。
- 可选调用本地 `/Users/leviviya/Documents/codex-local-patches` 里的 Remote Control 补丁。

## 推荐版本

当前已测试版本：

```text
Codex Desktop: 26.602.71036
Build: 3685
Codex CLI: codex-cli 0.137.0-alpha.4
系统: macOS / Apple Silicon
```

Fast/Goal 补丁是通过匹配 `app.asar` 里的前端 bundle 结构实现的。只要 Codex 更新后相关 JS 结构没有大改，通常可以继续使用。

Remote Control 不一样。Remote 依赖 `/Users/leviviya/Documents/codex-local-patches` 里的原始补丁包，而且对 Codex CLI 二进制 hash 很敏感。如果 Codex CLI hash 变了，Remote 部分可能需要更新原补丁包里的 diff 或匹配逻辑。

## 安装方式

克隆到 Codex 的 skills 目录：

```bash
mkdir -p ~/.codex/skills
git clone git@github.com:ZLZLGe/codex-local-patches-deploy-skill.git \
  ~/.codex/skills/codex-local-patches-deploy
```

确认脚本有执行权限：

```bash
chmod +x ~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

## 基础用法

使用当前 `~/.codex/config.toml` 里的第三方 API 配置，并重新部署 Fast/Goal：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

指定第三方 API 地址和模型：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --base-url "https://your-api.example.com/v1" \
  --model "gpt-5.5"
```

只配置第三方 API，不修改 `app.asar`：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --base-url "https://your-api.example.com/v1" \
  --model "gpt-5.5" \
  --skip-fast-goal
```

部署完成后重启 Codex.app。

## Remote Control 用法

只安装并校验 Remote 凭据：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --remote-json "/path/to/remote.json" \
  --skip-fast-goal
```

安装 Remote 凭据，并尝试应用 Remote Control 补丁：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --remote-json "/path/to/remote.json" \
  --enable-remote
```

Remote 凭据要求：

- 固定安装到 `~/.codex/remote.json`。
- 不能使用 `~/.codex/auth.json`。
- 不能使用 OpenAI API key。
- `access_token` 必须是 ChatGPT OAuth JWT。
- token 需要包含 ChatGPT auth claims、account id、account user id。
- token 不能过期。
- 如果要真正完成 Remote enrollment，通常还需要 Remote Control 相关 scope。

## Codex 更新后怎么用

Codex Desktop 更新后，重新运行：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

如果还要带 Remote：

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --enable-remote \
  --remote-json "/path/to/remote.json"
```

如果 Remote 失败但 Fast/Goal 成功，可以先继续使用 Fast/Goal。Remote 多半是 CLI hash 不匹配，需要更新原始补丁包。

## 脚本具体做什么

脚本会执行这些步骤：

- 更新或保留 `~/.codex/config.toml` 的 custom provider 配置。
- 解包 `/Applications/Codex.app/Contents/Resources/app.asar`。
- 修改 Fast mode 的两个 gate。
- 修改 Goal gate。
- 重新打包 `app.asar`。
- 更新 `Info.plist` 里的 `ElectronAsarIntegrity` hash。
- 使用 ad-hoc 签名重新签 `/Applications/Codex.app`。
- 使用 `codesign --verify --deep --strict` 验证签名。
- 重新解包当前 app 的 `app.asar`，确认 Fast/Goal 已经生效。

## 注意事项

这个仓库不包含任何 API key、access token、refresh token 或 `remote.json`。

脚本会修改 `/Applications/Codex.app`。如果系统权限不足，需要先给当前用户写入权限，或者用管理员权限处理应用目录。

重新签名后，Codex.app 不再是官方原始签名状态。如果 macOS 拦截启动，需要在系统设置里允许打开，或者重新执行签名流程。

如果 Fast/Goal 匹配失败，说明 Codex 新版本前端 bundle 结构变化了，需要更新 `scripts/deploy_codex_local_patches.sh` 里的正则匹配。

如果 Remote patch 失败但 Fast/Goal 成功，通常是 Codex CLI 二进制 hash 不匹配。此时 Fast/Goal 可以继续用，Remote 需要更新 `/Users/leviviya/Documents/codex-local-patches` 的补丁包。
