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

## 前端 bundle 变了怎么入手

如果 Codex 更新后脚本提示 `fast gate target not found`、`goal target not found`，说明新版 `app.asar` 里的前端 bundle 结构变了。处理思路不是乱猜，而是重新找本地 gate。

先解包当前版本：

```bash
TMP_DIR="$(mktemp -d /tmp/codex-bundle-drift.XXXXXX)"
npx --yes @electron/asar extract /Applications/Codex.app/Contents/Resources/app.asar "$TMP_DIR/app"
ASSETS="$TMP_DIR/app/webview/assets"
```

搜索 Fast 相关锚点：

```bash
rg -n 'fast_mode|featureRequirements|isServiceTierAllowed|read-service-tier|authMethod.*chatgpt' "$ASSETS"
```

Fast 通常有两个 gate：

- UI gate：控制界面是否允许显示或选择 Fast。
- Request gate：控制请求构造时是否真正带上 Fast 相关参数。

要做的事情一般还是一样：去掉本地 `authMethod === "chatgpt"` 限制，但保留 `fast_mode !== false` 这类能力检查。

搜索 Goal 相关锚点：

```bash
rg -n 'set-thread-goal-status|threadGoalObjective|3074100722|`goals`|goals' "$ASSETS"
```

Goal 通常是本地 feature flag/config gate 加上 `mode !== "cloud"`。处理目标是保留 `mode !== "cloud"`，去掉本地 feature flag/config 限制。

找到新版结构后，只改：

```text
scripts/deploy_codex_local_patches.sh
```

主要改里面的 Fast/Goal 正则，不要顺手重写 Remote。Remote 是另一条链路，CLI hash 和二进制 diff 更敏感。

改完后至少跑：

```bash
bash -n ~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh --skip-config
```

脚本最后会重新解包当前 app 的 `app.asar` 做验证。只有看到 Fast 两个 gate、Goal gate 都是 patched，并且 `originalsLeft` 为空，才算成功。

## Windows 电脑怎么强开

Windows 的核心思路和 macOS 一样：改 Codex Desktop 安装目录里的 `resources/app.asar`，把前端 bundle 里的 Fast/Goal 本地 gate 改掉。

不同点是：

- Windows 没有 macOS 的 `codesign`。
- Windows 没有这个脚本里用到的 `PlistBuddy`。
- 当前仓库里的 `deploy_codex_local_patches.sh` 是 macOS 优先脚本，不能直接在 Windows 上原样跑。
- Windows 需要单独把同一套 JS 正则 patch 逻辑移植成 PowerShell/Node 脚本。

先在 PowerShell 里找 `app.asar`：

```powershell
$roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})
Get-ChildItem $roots -Filter app.asar -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match 'Codex.*resources.*app\.asar$' } |
  Select-Object -ExpandProperty FullName
```

常见 Electron 安装路径类似：

```text
%LOCALAPPDATA%\Programs\Codex\resources\app.asar
```

找到后，基本流程是：

```powershell
$asar = "$env:LOCALAPPDATA\Programs\Codex\resources\app.asar"
$work = Join-Path $env:TEMP ("codex-asar-" + [guid]::NewGuid())

npx --yes @electron/asar extract $asar "$work\app"

# 这里需要把 scripts/deploy_codex_local_patches.sh 里的 Fast/Goal 正则替换逻辑
# 移植成一个 Windows 可跑的 Node 脚本，对 "$work\app\webview\assets" 执行。

npx --yes @electron/asar pack "$work\app" "$work\app.asar"

Copy-Item $asar "$asar.before-fast-goal" -Force
Copy-Item "$work\app.asar" $asar -Force
```

Windows 上要找的 Fast/Goal 位置仍然一样：

```powershell
rg -n "fast_mode|featureRequirements|isServiceTierAllowed|read-service-tier|authMethod.*chatgpt" "$work\app\webview\assets"
rg -n "set-thread-goal-status|threadGoalObjective|3074100722|``goals``|goals" "$work\app\webview\assets"
```

Fast 仍然是两个 gate：

- UI gate：控制界面是否显示或允许选择 Fast。
- Request gate：控制请求构造时是否真正带 Fast 相关参数。

Goal 仍然是本地 feature flag/config gate 加 `mode !== "cloud"`。

Windows 上强开成功的判断也一样：重新解包最终写回的 `app.asar`，确认 Fast 两个 gate 和 Goal gate 都已经变成 patched，原始 gate 没有残留。

如果 Windows 版 Codex 启动时报完整性错误，先检查该版本是否额外校验 `app.asar` hash。不要一上来改 Remote，先把 Fast/Goal 的前端 patch 跑通。

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
