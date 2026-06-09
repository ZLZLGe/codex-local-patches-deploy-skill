---
name: codex-local-patches-deploy
description: Re-deploy local Codex Desktop patches after app updates, including third-party API config, forced Fast mode, forced Goal support, optional Remote Control credential validation, and optional Remote Control patching from /Users/leviviya/Documents/codex-local-patches.
metadata:
  short-description: Reapply Codex Fast/Goal/Remote patches
---

# Codex Local Patches Deploy

Use this skill when the user wants Codex Desktop to keep working with a third-party API provider after Codex updates, especially requests mentioning:

- 强制开 Fast / fast mode
- 强制开 Goal / goal mode
- 第三方 API / custom provider / base_url
- Remote Control / remote.json
- `/Users/leviviya/Documents/codex-local-patches`
- Codex 更新后重新部署补丁

## Default Action

Run the bundled deployment script instead of rewriting patch commands by hand:

```bash
/Users/leviviya/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
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
/Users/leviviya/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh
```

Set or update the third-party API base URL:

```bash
/Users/leviviya/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --base-url "https://example.com/v1" \
  --model "gpt-5.4"
```

Install and validate a Remote Control credential file, but do not patch Remote:

```bash
/Users/leviviya/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
  --remote-json "/path/to/chatgpt-remote.json"
```

Also attempt Remote Control patching through the maintained patch package:

```bash
/Users/leviviya/.codex/skills/codex-local-patches-deploy/scripts/deploy_codex_local_patches.sh \
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
