# Remote Control indicator archaeology (Claude Code 2.1.293 / 2.1.294 / 2.1.295)

Date: 2026-10-08. Read-only research. Every claim is tagged [VERIFIED] (seen in the bundle, a file or a web page during this session) or [INFERENCE].

## 0. Corrections to the brief

1. [VERIFIED] 2.1.292 is NOT on disk. `~/.local/share/claude/versions/` holds 2.1.293, 2.1.294 and 2.1.295 only. I compared those three instead.
2. [VERIFIED] The running build is 2.1.295, not 2.1.294. `~/.claude/sessions/8630.json` (the lead's session) says `"version":"2.1.295"`.
3. [VERIFIED] The bundle is big and the minified names are chunk-local, so function names (`PUe`, `DFe`, `LFe`) differ between builds. Offsets in 2.1.294 are used below.

## 1. Does the indicator still exist? YES [VERIFIED]

It is the "rc pill". It was moved and restyled across releases, not removed.

Status table and picker, 2.1.294 (offset ~228776735):

```js
var m={label:"/rc failed",color:"error"},
    d={label:"/rc reconnecting",color:"warning"},
    f={label:"/rc active",color:"success"},
    p={label:"/rc connecting…",color:"warning"};
function PUe({error:t,connected:e,sessionActive:r,reconnecting:n}){
  if(t)return m; if(n)return d; if(r||e)return f; return p }
```

Gate for the footer pill (function `DFe`, offset ~232331433):

```js
var Drn=60;
function DFe(l){ let {columns:u}=ke(), m = l && u>=Drn;
  h = (v)=> m && !v.replBridgeOutboundOnly
        && (v.replBridgeEnabled || v.replBridgeError!==void 0)
        ? PUe({error:v.replBridgeError, connected:v.replBridgeConnected,
               sessionActive:v.replBridgeSessionActive, reconnecting:v.replBridgeReconnecting})
        : null;
  R = V(h);  k = R!==null && cC() ? R : null;  return k }
```

Eligibility check `cC` and `mnt` (offset ~210597005):

```js
function cC(){if(u())return!0;if(fj())return!1;return!kH()&&mnt()}
function mnt(){return PG()&&c()&&(T("tengu_ccr_bridge",!1)||g())}
```

The pill is shown only when ALL of these hold:
- the terminal is at least 60 columns wide (`Drn=60`);
- the session is not `replBridgeOutboundOnly`;
- `replBridgeEnabled` is true, or `replBridgeError` is set;
- `cC()` is true. In short: not a cloud session, not managed-disabled, first-party, claude.ai subscription login, and the `tengu_ccr_bridge` flag (or equivalent `g()` check) is on.

Render component `LFe` (offset ~232332394):
- It renders `<Text color={status.color} wrap="truncate">` and wraps the label in a hyperlink to `replBridgeSessionUrl` (`Yc()` adds `?from=cli`).
- `highlighted` swaps the colour to `"background"` with `inverse`.
- Compact mode or no-colour (`ge.level===0`) shortens the label to `rc`.
- First-run behaviour: the label `/rc active` is shown only while the `rc-active-badge` counter in `seenNotifications` is below 5 (`XR=5`). After that `Go()` maps `/rc active` to `/rc`. The impression is recorded by `Xc()`.
- LFe call sites at 2.1.294 offsets 232349414, 234175054, 234178372. I read the first (fullscreen header). I did not trace the other two.

## 2. Colour and placement

Colour [VERIFIED]:
- The pill uses the theme token `success`, not a hard-coded colour.
- Theme tables in 2.1.294 contain `success:"rgb(78,186,101)"` (light green, matches Phil's memory; the dark-theme value), `success:"rgb(44,122,57)"` (darker green, light theme), `success:"ansi:green"` and `success:"ansi:greenBright"`.
- Not verified: the mapping of each value to a named theme (I only matched the values), and which theme Phil runs. [INFERENCE] Dark theme gives `rgb(78,186,101)`.
- `warning` colours "reconnecting" and "connecting", `error` colours "failed". These are theme tokens too.

Placement [VERIFIED unless marked]:
- 2.1.162: a persistent footer pill under the prompt replaced the startup message (changelog).
- 2.1.268 changelog: "Improved the prompt footer: an editor or `/diff` selection now shows inside the prompt input, and fullscreen mode shows Remote Control status in the header instead of the footer".
- In the bundle (offset ~232349414), the fullscreen header component renders "Claude Code" bold, the version dim, the model and cwd lines, then `<Eu status={ie}>` after `Ve + " · "`. That is the status pill sitting in the header.
- [INFERENCE] If Phil uses fullscreen mode, the pill moved to the top header and is no longer near "bypass permissions on". Terminals under 60 columns hide it. I did not confirm Phil's mode or width.

## 3. Differences across 293, 294, 295 [VERIFIED]

- 293 vs 294: the `PUe` status block (520-900 byte window) and the `DFe` region (1500-byte window) are byte-identical (matching hashes). Offsets and minified names differ.
- 295: same logic with different minified names (`lje`, `C$t` etc. replace `PUe`, `LDt`). Window hashes differ only because of renaming. [INFERENCE] No behavioural change.
- Conclusion: the change is older than all three builds. On-disk evidence cannot date it; the changelog can (below).

## 4. State an external observer can read (the most important part)

### 4a. In-memory state (NOT externally visible) [VERIFIED]

AppState fields: `replBridgeEnabled`, `replBridgeExplicit`, `replBridgeOutboundOnly`, `replBridgeConnected`, `replBridgeSessionActive`, `replBridgeReconnecting`, `replBridgeError`, `replBridgeErrorKind`, `replBridgeSessionUrl`, `replBridgeEnvironmentId`, `replBridgeSessionId`, `replBridgeSessionGroupingId`.

State machine (`handleStateChange`, offset ~234877152):
- `ready`: connected=true, sessionActive=false.
- `connected`: connected=true, sessionActive=true.
- `reconnecting`: reconnecting=true, sessionActive=false.
- `failed`: connected=false (in outbound-only/mirror mode).
- `policy_disabled`: the reason string is stored.

I found no file, env var or socket that publishes these fields.

### 4b. Signal 1: session registry file [VERIFIED]

- Path: `~/.claude/sessions/<pid>.json`, field `bridgeSessionId`.
- Live example: `~/.claude/sessions/8630.json` contains `"bridgeSessionId":"session_01GhswoBDn5gnTGc58EmJCc7"`, next to `pid`, `sessionId`, `cwd`, `version`, `kind`, `entrypoint`, `tmux`, `messagingSocketPath`, `name`, `status`, `waitingFor`, `updatedAt`.
- Writer in the bundle: `async function F0n(e,n){await yn({bridgeSessionId:e},n)}`, called as `F0n(i??null, r)` when the REPL handle is attached or cleared.
- Meaning: present means a bridge session is attached; null or absent means not attached.
- Limits:
  - It is a flag only. It cannot distinguish connecting, reconnecting, failed or active.
  - Older session files (for example 2.1.126, pid 100988) have no such field.
  - [INFERENCE] A crash could leave a stale file, so check that the pid is alive and that `procStart` matches.
  - I did not check how fast the field clears on detach.

### 4c. Signal 2: environment variable [VERIFIED]

- `CLAUDE_CODE_BRIDGE_SESSION_ID`. The bundle (offset ~222502857 region) does:
  `if(i!==void 0) process.env.CLAUDE_CODE_BRIDGE_SESSION_ID = i; else delete process.env.CLAUDE_CODE_BRIDGE_SESSION_ID;`
- It is set in the shell I used: `session_01K2vFWsLxqerF4x3ty8BH9q`.
- Limit [INFERENCE from standard process semantics]: only children spawned after attach inherit it, and a long-lived child will never see a change. A status line command that runs fresh each refresh gets the current value. Note it differs from the id in the lead's session file (they are different sessions).

### 4d. Other things checked

- Other env var NAMES found in the bundle (counts in 2.1.294): `CLAUDE_CODE_REMOTE` (210), `CLAUDE_CODE_REMOTE_SESSION_ID` (81), `CLAUDE_BRIDGE_REATTACH_SESSION/_SEQ/_OWNER_ORG/_OWNER_ACCT/_OUTBOUND_ONLY/_NO_BACKFILL/_GROUPING`, `CLAUDE_CODE_BRIDGE_CHILD_ARTIFACT/_AUTO_DEFAULT/_MACHINE_SETTINGS`, `CLAUDE_CODE_BRIDGE_MCP_CARRIER`, `CLAUDE_CODE_BRIDGE_PROMPT_SHA256`, `CLAUDE_CODE_BRIDGE_OWNER_ORG_UUID/_ACCOUNT_UUID`, `CLAUDE_CODE_BRIDGE_SOURCE_DIR`, `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX`, `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE`, `CLAUDE_CODE_REMOTE_SETTINGS_PATH`, `CLAUDE_CODE_REMOTE_SEND_KEEPALIVES`, `CLAUDE_REMOTE_TOOLS_BRIDGE_URL`, `CLAUDE_CODE_CCR_EARLY_REMOTE_CONNECT`. Their purposes were NOT verified. [INFERENCE] They look like inputs for cloud/child/reattach sessions, not a live "active" flag.
- `~/.claude/settings.json` line 406: `"remoteControlAtStartup": true`. This is configuration, not live state. Other `settings.json*` backups mention remote control the same way.
- `/run/user/1000/cc-socks/*.sock` are per-pid cross-session messaging sockets (the session file points to its own via `messagingSocketPath`). I did NOT connect to any socket, so I cannot say whether they report RC state. Could not determine.
- Plugin API `.d.ts` (`nerdflair-band/.claude-plugin/types/claude-code/index.d.ts`): no field represents "this session is remote-controlled". Remote Control appears only as an origin tag, for example `kind: 'bridge'` on inbound prompts (lines 1976, 8880, 11384), `/config` changes arriving over the bridge (line 1973), and prose about SDK/RC model changes (lines 7814, 7900). So a plugin can learn that a message came through the bridge, not whether RC is currently on. Line 844 references `StatusLineCommandInput` but I found no definition of it in the file, so whether the status line stdin JSON carries a remote field: could not determine.
- Nothing else under `~/.claude` (excluding `projects/`) records live state; `rg -l` hits were settings backups and `cache/changelog.md`.

### 4e. Recommendation for our own indicator [INFERENCE]

- Cheapest signal for a status line command: read `bridgeSessionId` from `~/.claude/sessions/<claude pid>.json` (or check the env var). Present means RC attached.
- It gives on/off only. To show connecting, reconnecting or failed, there is no external signal; that needs the in-process state, which only the engine or a plugin with engine hooks could read.
- Check the status line stdin JSON schema first (could not determine), because it may already carry session id or similar fields that avoid file reads.

## 5. Changelog and web evidence

Local `~/.claude/cache/changelog.md` [VERIFIED]:

| Version | Entry |
|---|---|
| 2.1.69 | "Fixed inconsistent color for 'Remote Control active' status indicator" |
| 2.1.128 | "Fixed stale 'remote-control is active' status lines from prior sessions appearing after `--resume`/`--continue`" |
| 2.1.162 | "Remote Control now shows as a persistent footer pill (with a link to the session) instead of a startup message" |
| 2.1.172 | "Shortened the Remote Control footer indicator to '/rc active' and hid it on narrow terminals" |
| 2.1.178 | "connection failures now show a persistent red '/rc failed' indicator in the footer ..." |
| 2.1.224 | "connection failures now show a persistent failure indicator with details and a reconnect shortcut, instead of only an 8-second toast" |
| 2.1.251 | "[VSCode] Changed the Remote Control banner to a footer pill (shown while Remote Control is on or has failed)..." |
| 2.1.268 | "...fullscreen mode shows Remote Control status in the header instead of the footer" |

Web search (standard mode) found no release note announcing the indicator was removed. Sources [VERIFIED as search results; contents not fetched by me]:
- Official docs, Italian page describing the `/rc active` footer indicator: https://code.claude.com/docs/it/remote-control
- Issue 67242, English docs still use the old "Remote Control active" wording: https://claudeissues.com/issue/67242-docs-remote-control-page-still-describes-footer-indicator-as-remote-control-acti
- Issue 65184, docs still describe a startup banner: https://claudeissues.com/issue/65184-docs-remote-control-docs-still-describe-a-startup-message-banner-instead-of-the
- Issue 56175, `remoteControlAtStartup: true` did not trigger the footer indicator (closed Jun 2, 2026): https://claudeissues.com/issue/56175-bug-remotecontrolatstartup-true-does-not-trigger-the-remote-control-active-foote
- Third-party reference: https://clauderemotecontrol.com/rc-command/
- Changelog mirror: https://www.claudelog.com/claude-code-changelog/

## 6. Could not determine

- Which theme Phil uses, and whether he runs fullscreen mode.
- Whether the status line stdin JSON has a remote field.
- What the cc-socks sockets say about RC (not probed).
- Why Phil's pill is not visible right now. Candidates: fullscreen header, width under 60, or the `rc-active-badge` counter (after 5 views the label becomes `/rc`, not `/rc active`, so a search for "active" text would miss it). His `settings.json` has `remoteControlAtStartup: true` and his session file has a `bridgeSessionId`, so RC is connected.
