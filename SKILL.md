---
name: codex-local-patches-deploy
description: Re-deploy local Codex Desktop patches after app updates, including third-party API config, forced Fast mode, forced Goal support, optional Remote Control credential validation, and optional Remote Control patching from a user-supplied codex-local-patches directory.
metadata:
  short-description: Reapply Codex Fast/Goal/Remote patches
---

# Codex Local Patches Deploy

Use this skill when the user wants Codex Desktop to keep working with a third-party API provider after Codex updates, especially requests mentioning:

- 强制开 Fast / fast mode
- 强制开 Goal / goal mode
- 第三方 API / custom provider / base_url
- Remote Control / remote.json
- `codex-local-patches`
- `--patch-dir`
- Codex 更新后重新部署补丁

## Default Action

Run the bundled deployment script instead of rewriting patch commands by hand:

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

This default path:

- Preserves existing `~/.codex/config.toml` and ensures the selected custom provider is configured.
- Patches only Fast and Goal gates in `/Applications/Codex.app/Contents/Resources/app.asar`.
- Updates `ElectronAsarIntegrity`.
- Re-signs `/Applications/Codex.app` ad-hoc with the minimum Apple Events entitlement.
- Verifies `codesign` and re-extracts the patched asar to confirm Fast/Goal are patched.
- Does not patch Remote Control unless explicitly requested.

## Common Commands

Use the current config provider and base URL:

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

Set or update the third-party API base URL:

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --base-url "https://example.com/v1" \
  --model "gpt-5.4"
```

Install and validate a Remote Control credential file, but do not patch Remote:

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --remote-json "/path/to/chatgpt-remote.json"
```

Also attempt Remote Control patching through the maintained patch package:

```bash
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --enable-remote \
  --remote-json "/path/to/chatgpt-remote.json"
```

## Remote Rules

Remote Control is intentionally separate from the normal third-party API config.

- Remote credential path is fixed: `~/.codex/remote.json`.
- Do not copy `~/.codex/auth.json` to `remote.json`.
- A plain OpenAI API key is not valid.
- A normal ChatGPT model access token may still be invalid if it lacks Remote Control scope or account claims.
- The script validates JWT shape, expiration, ChatGPT auth claims, account user id, and account id before installing `remote.json`.
- Remote Control patching is best-effort because the bundled CLI binary patch is version/hash-sensitive.

If `--enable-remote` fails with an unsupported CLI hash, keep Fast/Goal as successful and report that Remote needs the patch package updated for the new Codex CLI hash.

## After Deployment

Tell the user to restart Codex.app after a successful run. If the script was run from inside Codex, prefer not quitting the running app automatically.

## Failure Handling

- If Fast/Goal target patterns are not found, inspect the newest `webview/assets/*.js` files and update the script patterns.
- If `codesign` fails, do not keep retrying blindly; inspect the exact signing error.
- If `remote.json` validation fails, do not install it. Ask for a real ChatGPT Remote Control OAuth JSON.
- If Remote patching fails but Fast/Goal succeeded, say that clearly and keep the Fast/Goal result.

## Bundle Drift Playbook

Use this when Codex updates and Fast/Goal matching fails.

1. Extract the current app bundle:

```bash
TMP_DIR="$(mktemp -d /tmp/codex-bundle-drift.XXXXXX)"
npx --yes @electron/asar extract /Applications/Codex.app/Contents/Resources/app.asar "$TMP_DIR/app"
ASSETS="$TMP_DIR/app/webview/assets"
```

2. Search Fast anchors:

```bash
rg -n 'fast_mode|featureRequirements|isServiceTierAllowed|read-service-tier|authMethod.*chatgpt' "$ASSETS"
```

Look for two independent Fast checks:

- UI allowance gate around `isServiceTierAllowed` and `requirements?.featureRequirements?.fast_mode`.
- Request-building gate around `authMethod`, `hostId`, and `fast_mode`.

The intended transform is still the same: remove the local `authMethod === "chatgpt"` condition, but keep the actual `fast_mode !== false` capability check.

3. Search Goal anchors:

```bash
rg -n 'set-thread-goal-status|threadGoalObjective|3074100722|`goals`|goals' "$ASSETS"
```

Look for the local gate that combines a feature flag/config check with `mode !== "cloud"`. The intended transform is to keep the non-cloud restriction but remove the feature flag/config requirement.

4. Update only the regexes in `scripts/deploy_codex_local_patches.sh`.

Keep the script idempotent:

- It must detect already-patched files.
- It must fail loudly if any required gate is missing.
- It must re-extract the final `app.asar` and verify no original Fast/Goal gate remains.

5. Validate before reporting success:

```bash
bash -n ~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
~/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh --skip-config
```

## Windows Porting Notes

The current bundled script is macOS-first. On Windows, use the same front-end patch idea, but do not run the macOS signing/hash steps.

Start by locating `app.asar` in PowerShell:

```powershell
$roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})
Get-ChildItem $roots -Filter app.asar -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match 'Codex.*resources.*app\.asar$' } |
  Select-Object -ExpandProperty FullName
```

Typical Electron layout is similar to:

```text
%LOCALAPPDATA%\Programs\Codex\resources\app.asar
```

Then extract, patch, and repack:

```powershell
$asar = "$env:LOCALAPPDATA\Programs\Codex\resources\app.asar"
$work = Join-Path $env:TEMP ("codex-asar-" + [guid]::NewGuid())
npx --yes @electron/asar extract $asar "$work\app"
# Port the same Fast/Goal regex replacement from scripts/deploy_codex_local_patches.sh to a Node script.
npx --yes @electron/asar pack "$work\app" "$work\app.asar"
Copy-Item $asar "$asar.before-fast-goal" -Force
Copy-Item "$work\app.asar" $asar -Force
```

Windows validation is still the same: re-extract the final `app.asar` and verify both Fast gates plus the Goal gate are patched. If Electron refuses to start, compare the app's packaging/integrity mechanism for that build before assuming the regex patch is wrong.
