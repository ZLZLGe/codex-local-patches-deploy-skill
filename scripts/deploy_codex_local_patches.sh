#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Codex.app"
PATCH_DIR="/Users/leviviya/Documents/codex-local-patches"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"
REMOTE_PATH="$CODEX_HOME/remote.json"

BASE_URL=""
MODEL=""
MODEL_PROVIDER="custom"
REMOTE_JSON=""
ENABLE_REMOTE=0
SKIP_FAST_GOAL=0
SKIP_CONFIG=0

log() {
  printf '[codex-local-patches] %s\n' "$*" >&2
}

die() {
  printf '[codex-local-patches] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  deploy_codex_local_patches.sh [options]

Options:
  --app PATH             Codex.app path. Default: /Applications/Codex.app
  --patch-dir PATH       Existing codex-local-patches directory.
  --base-url URL         Third-party API base URL, for example https://host/v1.
  --model NAME           Model name to set in ~/.codex/config.toml.
  --provider NAME        Model provider name. Default: custom.
  --remote-json PATH     Validate and install this file as ~/.codex/remote.json.
  --enable-remote        Run remote-control-only patch from --patch-dir.
  --skip-fast-goal       Only configure provider/remote.
  --skip-config          Do not edit ~/.codex/config.toml.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:?missing --app value}"
      shift 2
      ;;
    --patch-dir)
      PATCH_DIR="${2:?missing --patch-dir value}"
      shift 2
      ;;
    --base-url)
      BASE_URL="${2:?missing --base-url value}"
      shift 2
      ;;
    --model)
      MODEL="${2:?missing --model value}"
      shift 2
      ;;
    --provider)
      MODEL_PROVIDER="${2:?missing --provider value}"
      shift 2
      ;;
    --remote-json)
      REMOTE_JSON="${2:?missing --remote-json value}"
      shift 2
      ;;
    --enable-remote)
      ENABLE_REMOTE=1
      shift
      ;;
    --skip-fast-goal)
      SKIP_FAST_GOAL=1
      shift
      ;;
    --skip-config)
      SKIP_CONFIG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd node
require_cmd npx
require_cmd codesign
require_cmd defaults

[[ -d "$APP_PATH" ]] || die "Codex.app not found: $APP_PATH"
[[ -f "$APP_PATH/Contents/Resources/app.asar" ]] || die "app.asar not found under $APP_PATH"
mkdir -p "$CODEX_HOME"

configure_third_party_api() {
  [[ "$SKIP_CONFIG" == "0" ]] || return 0

  node - "$CONFIG_PATH" "$MODEL_PROVIDER" "$BASE_URL" "$MODEL" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const [configPath, provider, baseUrlArg, modelArg] = process.argv.slice(2);
let text = '';
try {
  text = fs.readFileSync(configPath, 'utf8');
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

function getTopLevelString(key) {
  const re = new RegExp(`^${key}\\s*=\\s*"([^"]*)"`, 'm');
  return text.match(re)?.[1] ?? '';
}

function getProviderBaseUrl(name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`\\[model_providers\\.${escaped}\\]([\\s\\S]*?)(?=\\n\\[|$)`);
  const body = text.match(re)?.[1] ?? '';
  return body.match(/^base_url\s*=\s*"([^"]*)"/m)?.[1] ?? '';
}

const baseUrl = baseUrlArg || getProviderBaseUrl(provider) || getTopLevelString('openai_base_url');
const model = modelArg || getTopLevelString('model') || 'gpt-5.4';
if (!baseUrl) {
  throw new Error('missing base URL; pass --base-url or keep an existing provider base_url in config.toml');
}

function setTopLevelString(input, key, value) {
  const line = `${key} = ${JSON.stringify(value)}`;
  const re = new RegExp(`^${key}\\s*=.*$`, 'm');
  return re.test(input) ? input.replace(re, line) : `${line}\n${input}`;
}

function ensureSection(input, header, bodyLines) {
  const escaped = header.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`\\n?\\[${escaped}\\][\\s\\S]*?(?=\\n\\[|$)`);
  const section = `[${header}]\n${bodyLines.join('\n')}\n`;
  if (re.test(input)) {
    return input.replace(re, `\n${section}`);
  }
  const trimmed = input.endsWith('\n') ? input : `${input}\n`;
  return `${trimmed}\n${section}`;
}

let next = text;
next = setTopLevelString(next, 'model_provider', provider);
next = setTopLevelString(next, 'model', model);
next = setTopLevelString(next, 'openai_base_url', baseUrl);
if (!/\[model_providers\]/.test(next)) {
  next += `${next.endsWith('\n') ? '' : '\n'}\n[model_providers]\n`;
}
next = ensureSection(next, `model_providers.${provider}`, [
  `name = ${JSON.stringify(provider)}`,
  'wire_api = "responses"',
  'requires_openai_auth = true',
  `base_url = ${JSON.stringify(baseUrl)}`,
]);

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, next.replace(/\n{3,}/g, '\n\n'));
console.log(JSON.stringify({ configPath, provider, baseUrl, model }, null, 2));
NODE
}

validate_and_install_remote_json() {
  [[ -n "$REMOTE_JSON" ]] || return 0
  [[ -f "$REMOTE_JSON" ]] || die "remote JSON not found: $REMOTE_JSON"
  [[ "$REMOTE_JSON" != "$CODEX_HOME/auth.json" ]] || die "remote JSON must not be ~/.codex/auth.json"

  node - "$REMOTE_JSON" "$REMOTE_PATH" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const [inputPath, outputPath] = process.argv.slice(2);
const raw = fs.readFileSync(inputPath, 'utf8');
const auth = JSON.parse(raw);
const token = auth?.tokens?.access_token
  ?? auth?.access_token
  ?? auth?.entries?.step_up_token_exchange_stored_isolated?.response?.access_token
  ?? auth?.step_up_token_exchange_stored_isolated?.response?.access_token;

if (typeof token !== 'string' || token.trim() === '') {
  throw new Error('remote JSON is missing access_token');
}

const parts = token.trim().split('.');
if (parts.length !== 3) {
  throw new Error('remote access_token is not a JWT');
}

const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
const claims = payload['https://api.openai.com/auth'];
if (claims == null || typeof claims !== 'object') {
  throw new Error('remote access_token is missing ChatGPT auth claims');
}

const accountId = claims.chatgpt_account_id ?? claims.account_id;
const accountUserId = claims.chatgpt_account_user_id ?? claims.account_user_id ?? claims.chatgpt_user_id ?? claims.user_id;
if (typeof accountId !== 'string' || accountId.trim() === '') {
  throw new Error('remote access_token is missing ChatGPT account id');
}
if (typeof accountUserId !== 'string' || accountUserId.trim() === '') {
  throw new Error('remote access_token is missing ChatGPT account user id');
}

const now = Math.floor(Date.now() / 1000);
if (typeof payload.exp !== 'number' || payload.exp <= now + 60) {
  throw new Error('remote access_token is expired or too close to expiry');
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(auth, null, 2) + '\n', { mode: 0o600 });
fs.chmodSync(outputPath, 0o600);
console.log(JSON.stringify({
  remotePath: outputPath,
  expiresAt: new Date(payload.exp * 1000).toISOString(),
  hasRemoteScope: Array.isArray(payload.scp) && payload.scp.includes('codex.remote_control.enroll'),
  hasRefreshToken: typeof (auth?.tokens?.refresh_token ?? auth?.refresh_token) === 'string',
}, null, 2));
NODE
}

patch_fast_goal() {
  [[ "$SKIP_FAST_GOAL" == "0" ]] || return 0

  local resources="$APP_PATH/Contents/Resources"
  local asar_path="$resources/app.asar"
  local info_plist="$APP_PATH/Contents/Info.plist"
  local tmp_root app_dir new_asar backup hash entitlements

  tmp_root="$(mktemp -d /tmp/codex-fast-goal-deploy.XXXXXX)"
  app_dir="$tmp_root/app"
  new_asar="$tmp_root/app.asar"

  log "extracting app.asar"
  npx --yes @electron/asar extract "$asar_path" "$app_dir" >/dev/null

  log "patching Fast and Goal gates"
  node - "$app_dir/webview/assets" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];

const gate1OriginalRe = /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)&&(!([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)!=null&&\5\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1)/;
const gate1PatchedRe = /=!([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)!=null&&\2\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1/;
const gate2OriginalRe = /return ([A-Za-z_$][\w$]*)===`chatgpt`\?\(await ([A-Za-z_$][\w$]*)\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:\1,hostId:([A-Za-z_$][\w$]*)\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1:!1\}/;
const gate2PatchedRe = /return \(await ([A-Za-z_$][\w$]*)\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:([A-Za-z_$][\w$]*),hostId:([A-Za-z_$][\w$]*)\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const goalPatchedRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`,(\w+)=([^,]+),/;
const legacyGoalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)\(`3074100722`\)&&([A-Za-z_$][\w$]*)\((\w+)\?\.config,`goals`\)===!0&&(\w+)!==`cloud`(?:&&[^,]+)*,(\w+)=([^,]+),/;
const localUiGoalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`&&[^,]+,(\w+)=([^,]+!=null\|\|[^,]+!=null),/;

let result = {
  fastGate1: null,
  fastGate1File: null,
  fastGate2: null,
  fastGate2File: null,
  goal: null,
  goalFile: null,
};

for (const name of fs.readdirSync(dir)) {
  if (!name.endsWith('.js')) continue;
  const file = path.join(dir, name);
  let text = fs.readFileSync(file, 'utf8');
  let changed = false;

  if (result.fastGate1 == null) {
    if (gate1OriginalRe.test(text)) {
      text = text.replace(gate1OriginalRe, (_m, f, _a, rest) => `${f}=${rest}`);
      result.fastGate1 = 'patched';
      result.fastGate1File = name;
      changed = true;
    } else if (/isServiceTierAllowed/.test(text) && gate1PatchedRe.test(text)) {
      result.fastGate1 = 'already-patched';
      result.fastGate1File = name;
    }
  }

  if (result.fastGate2 == null) {
    if (gate2OriginalRe.test(text)) {
      text = text.replace(gate2OriginalRe, (_m, n, e, c, t) =>
        `return (await ${e}.query.fetch(${c},{authMethod:${n},hostId:${t}})).requirements?.featureRequirements?.fast_mode!==!1}`);
      result.fastGate2 = 'patched';
      result.fastGate2File = name;
      changed = true;
    } else if (gate2PatchedRe.test(text)) {
      result.fastGate2 = 'already-patched';
      result.fastGate2File = name;
    }
  }

  if (result.goal == null && /set-thread-goal-status|3074100722.*`goals`|threadGoalObjective/.test(text)) {
    if (legacyGoalOriginalRe.test(text)) {
      text = text.replace(
        legacyGoalOriginalRe,
        (_match, goalGateVar, _statsigFn, _configAccessFn, _configVar, modeVar, hasGoalVar, hasGoalExpr) =>
          `${goalGateVar}=${modeVar}!==\`cloud\`,${hasGoalVar}=${hasGoalExpr},`,
      );
      result.goal = 'patched';
      result.goalFile = name;
      changed = true;
    } else if (localUiGoalOriginalRe.test(text)) {
      text = text.replace(
        localUiGoalOriginalRe,
        (_match, goalGateVar, modeVar, hasGoalVar, hasGoalExpr) =>
          `${goalGateVar}=${modeVar}!==\`cloud\`,${hasGoalVar}=${hasGoalExpr},`,
      );
      result.goal = 'patched';
      result.goalFile = name;
      changed = true;
    } else if (goalPatchedRe.test(text)) {
      result.goal = 'already-patched';
      result.goalFile = name;
    }
  }

  if (changed) fs.writeFileSync(file, text);
}

if (result.fastGate1 == null) throw new Error('fast gate1 target not found');
if (result.fastGate2 == null) throw new Error('fast gate2 target not found');
if (result.goal == null) throw new Error('goal target not found');
console.log(JSON.stringify(result, null, 2));
NODE

  log "repacking app.asar"
  npx --yes @electron/asar pack "$app_dir" "$new_asar" >/dev/null

  hash="$(node - "$new_asar" <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const file = process.argv[2];
const fd = fs.openSync(file, 'r');
try {
  const sizeBuf = Buffer.alloc(8);
  if (fs.readSync(fd, sizeBuf, 0, 8, 0) !== 8) throw new Error('could not read asar size pickle');
  const headerSize = sizeBuf.readUInt32LE(4);
  const headerBuf = Buffer.alloc(headerSize);
  if (fs.readSync(fd, headerBuf, 0, headerSize, 8) !== headerSize) throw new Error('could not read asar header');
  const stringLength = headerBuf.readUInt32LE(4);
  const headerStringBytes = headerBuf.subarray(8, 8 + stringLength);
  process.stdout.write(crypto.createHash('sha256').update(headerStringBytes).digest('hex'));
} finally {
  fs.closeSync(fd);
}
NODE
)"

  backup="$asar_path.before-fast-goal-$(date +%Y%m%d%H%M%S)"
  cp "$asar_path" "$backup"
  cp "$new_asar" "$asar_path"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$info_plist"
  log "app.asar backup: $backup"
  log "ElectronAsarIntegrity hash: $hash"

  entitlements="$(mktemp /tmp/codex-app-entitlements.XXXXXX)"
  cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
PLIST

  log "re-signing Codex.app"
  codesign --force --sign - --entitlements "$entitlements" "$APP_PATH" >/dev/null
  codesign --verify --deep --strict --verbose=4 "$APP_PATH" >/dev/null

  log "verifying patched app.asar"
  local verify_dir
  verify_dir="$(mktemp -d /tmp/codex-fast-goal-verify.XXXXXX)"
  npx --yes @electron/asar extract "$asar_path" "$verify_dir/app" >/dev/null
  node - "$verify_dir/app/webview/assets" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
const gate1OriginalRe = /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)&&(!([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)!=null&&\5\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1)/;
const gate1PatchedRe = /=!([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)!=null&&\2\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1/;
const gate2OriginalRe = /return ([A-Za-z_$][\w$]*)===`chatgpt`\?\(await ([A-Za-z_$][\w$]*)\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:\1,hostId:([A-Za-z_$][\w$]*)\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1:!1\}/;
const gate2PatchedRe = /return \(await ([A-Za-z_$][\w$]*)\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:([A-Za-z_$][\w$]*),hostId:([A-Za-z_$][\w$]*)\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const goalPatchedRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`,(\w+)=([^,]+),/;
const legacyGoalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)\(`3074100722`\)&&([A-Za-z_$][\w$]*)\((\w+)\?\.config,`goals`\)===!0&&(\w+)!==`cloud`(?:&&[^,]+)*,(\w+)=([^,]+),/;
const localUiGoalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`&&[^,]+,(\w+)=([^,]+!=null\|\|[^,]+!=null),/;
const result = { fastGate1: null, fastGate2: null, goal: null, originalsLeft: [] };
for (const name of fs.readdirSync(dir)) {
  if (!name.endsWith('.js')) continue;
  const text = fs.readFileSync(path.join(dir, name), 'utf8');
  if (gate1OriginalRe.test(text)) result.originalsLeft.push(`fastGate1:${name}`);
  if (gate2OriginalRe.test(text)) result.originalsLeft.push(`fastGate2:${name}`);
  if (legacyGoalOriginalRe.test(text) || localUiGoalOriginalRe.test(text)) result.originalsLeft.push(`goal:${name}`);
  if (result.fastGate1 == null && /isServiceTierAllowed/.test(text) && gate1PatchedRe.test(text)) result.fastGate1 = name;
  if (result.fastGate2 == null && gate2PatchedRe.test(text)) result.fastGate2 = name;
  if (result.goal == null && /set-thread-goal-status|3074100722.*`goals`|threadGoalObjective/.test(text) && goalPatchedRe.test(text)) result.goal = name;
}
result.ok = !!result.fastGate1 && !!result.fastGate2 && !!result.goal && result.originalsLeft.length === 0;
console.log(JSON.stringify(result, null, 2));
if (!result.ok) process.exit(2);
NODE
}

patch_remote_control() {
  [[ "$ENABLE_REMOTE" == "1" ]] || return 0
  [[ -f "$REMOTE_PATH" ]] || die "--enable-remote requires a valid $REMOTE_PATH; pass --remote-json first"
  [[ -x "$PATCH_DIR/patch_codex_local_features.sh" ]] || die "patch script not executable: $PATCH_DIR/patch_codex_local_features.sh"

  log "running remote-control-only patch through $PATCH_DIR"
  (
    cd "$PATCH_DIR"
    PATCH_SCOPE=remote-control-only SKIP_QUIT=1 ./patch_codex_local_features.sh "$APP_PATH"
  )
}

main() {
  local version build
  version="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  build="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion 2>/dev/null || true)"
  log "target app: $APP_PATH"
  log "version/build: ${version:-unknown} / ${build:-unknown}"

  configure_third_party_api
  validate_and_install_remote_json
  patch_fast_goal
  patch_remote_control

  log "deployment complete; restart Codex.app to load the patched app.asar"
}

main "$@"
