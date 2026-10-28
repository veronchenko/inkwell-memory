# Inkwell usage hooks

A self-contained plugin, installable in both **Claude Code** and **Codex**,
that mechanically nudges an agent to use the Inkwell MCP memory server,
instead of relying on it remembering an INKWELL_SPEC.md instruction every
turn. The search-reminder prompt (`inkwell_session_start.py`) mirrors the
"When to search"/"Project hygiene" rules in `~/.claude/INKWELL_SPEC.md` —
update both together when that file changes.

One plugin serves both agents: Codex's plugin loader discovers
`.claude-plugin/plugin.json` as a documented OOTB-compatibility fallback (it
checks `.codex-plugin/plugin.json`, then `.claude-plugin/plugin.json`, then
`.cursor-plugin/plugin.json`, first match wins) and sets both `PLUGIN_ROOT`
and `CLAUDE_PLUGIN_ROOT` when running hook commands, so the same manifest and
`hooks.json` work unmodified under either client — no `.codex-plugin/`
duplicate needed.

## Plugin layout

```
plugins/
├── marketplace.json                  <- Codex marketplace (repo-relative source)
└── inkwell-hooks/                     <- plugin root (this folder)
    ├── .claude-plugin/
    │   └── plugin.json               <- shared manifest (Claude Code + Codex)
    ├── hooks/
    │   ├── hooks.json                <- event → command wiring
    │   ├── inkwell_remember_gate.py
    │   ├── inkwell_session_start.py
    │   ├── inkwell_cost_tracker.py
    │   ├── inkwell_session_end_cleanup.py
    │   └── _hooklog.py               <- shared debug-logging helper
    ├── agents/
    │   ├── inkwell-project-onboarder.md       <- Claude Code subagent (loaded via the plugin)
    │   └── inkwell-project-onboarder.codex.toml  <- same subagent, Codex format (see below)
    ├── INKWELL_SPEC.md                <- reference copy, see below
    ├── INKWELL_TEMPLATES.md           <- reference copy, see below
    └── README.md                     <- this file
```

The repo root also has `.claude-plugin/marketplace.json` (Claude Code
marketplace), which lists `plugins/inkwell-hooks/` as the `inkwell-hooks`
plugin under the `inkwell-memory` marketplace. `plugins/marketplace.json`
does the equivalent for Codex, using Codex's own marketplace schema
(`source: {"source": "local", "path": "./inkwell-hooks"}`, `policy`,
`category` — Codex requires these fields, unlike Claude's simpler
bare-string `source`). Both marketplaces point at the same plugin directory.

`agents/inkwell-project-onboarder.md` doesn't carry over to Codex through the
plugin install: Codex's `plugin.json` schema has no `agents` field (only
`name`, `version`, `description`, `keywords`, `skills`, `mcpServers`, `apps`,
`hooks`, `interface` are recognized), and Codex subagents aren't
plugin-bundled at all — they're standalone TOML files under `~/.codex/agents/`
(personal) or `.codex/agents/` (project-scoped), each requiring `name`,
`description`, `developer_instructions`, with optional `mcp_servers` etc.
`agents/inkwell-project-onboarder.codex.toml` in this folder is that same
subagent's body ported to Codex's TOML shape (`mcp_servers = ["inkwell"]`,
same procedure as the `.md` version, referencing `AGENTS.md` instead of
`CLAUDE.md`). It isn't installed by `codex plugin add` — `scripts/install.{ps1,sh}`
copies it to `~/.codex/agents/inkwell-project-onboarder.toml` as a separate
step after the plugin install (see "Install" below). Installing by hand
without the script: copy that file to `~/.codex/agents/inkwell-project-onboarder.toml`
(or `.codex/agents/` for a project-scoped agent) yourself.

## Reference copies in this folder

- **`INKWELL_SPEC.md`** — verbatim copy of `~/.claude/INKWELL_SPEC.md`, the
  global instructions file that defines the "when to search"/"when to write"
  rules the hooks below mechanically enforce. Kept here so the hook
  logic and the policy it's enforcing sit side by side for reading.
  **The live file is `~/.claude/INKWELL_SPEC.md`** — this copy is read-only
  reference. It pulls in `@INKWELL_TEMPLATES.md` for the entry-type table and
  the 9 strict templates.
- **`INKWELL_TEMPLATES.md`** — verbatim copy of `~/.claude/INKWELL_TEMPLATES.md`,
  the entry-type table and strict templates `INKWELL_SPEC.md` imports. Split
  out from the spec because it's pure vocabulary/wording — not enforced by
  the server (`entry_type` is any non-empty string) — so it's the part meant
  to be edited/replaced per user, unlike `INKWELL_SPEC.md`.

  **Sync rule for both files above:** on install or update, hard-copy
  (overwrite) whichever direction is stale — never hand-merge or diff the
  two sides. These are the single exception to the general "review before
  applying" habit: copy the file wholesale and move on.

`agents/inkwell-project-onboarder.md` needs no such reference-copy dance —
as a Claude Code plugin agent it loads directly from here, so there's only
one live copy.

## The four hooks

Defined in `hooks/hooks.json`:

- **`PreToolUse`** (`inkwell_remember_gate.py`, matcher
  `mcp__inkwell__search|mcp__inkwell__recall|mcp__inkwell__remember`) — enforces
  "search before remember" mechanically instead of relying on the model to
  self-police it. On `search`/`recall` it sets `searched: true` in the
  per-session state (see below); on `remember` it checks that flag and denies
  the call (`permissionDecision: "deny"`) if it's not set, telling the model
  to search first. Session-level gate — any prior search/recall in the
  session satisfies it, regardless of topic. On a successful `remember` it
  also increments `remembers_count` / `last_remember_ts`, which
  `inkwell_statusline.py` displays.
- **`SessionStart`** (`inkwell_session_start.py`) — fires once per new
  session, unconditionally reminds to search Inkwell
  (`mcp__inkwell__search`/`recall`) before starting work, per the "When to
  search Inkwell" rule (mandatory, every request, not conditional on
  relevance).
- **`PostToolUse`** (`inkwell_cost_tracker.py`, no matcher — every tool call)
  — accumulates `tokens_in`/`tokens_out`/`cost_usd` into the per-session
  state whenever a PostToolUse payload carries `total_cost_usd`/
  `usage.input_tokens`/`usage.output_tokens` (currently only Agent-tool
  subagent calls report these; the hook is a no-op otherwise). Local-only in
  v1 — no join with Inkwell's own `query_log`, no network call. Not surfaced
  in the statusline (see below) — the data is written for later local
  inspection, not shown live.
- **`SessionEnd`** (`inkwell_session_end_cleanup.py`) — fires when the
  session actually ends (not on every Stop) and deletes that session's
  state file (see below), so the temp dir doesn't accumulate stale files per
  session forever. No decision control on this event (can't block exit,
  can't message Claude) — purely cleanup.
  **Codex-only gap:** Codex's hook event set (`PreToolUse`,
  `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`,
  `SessionStart`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`)
  has no `SessionEnd` equivalent, so this entry is silently ignored there
  (unknown hook-event keys don't fail parsing) and the temp state files
  simply accumulate one set per Codex session instead of being swept — not
  worth a workaround, since they're tiny and the OS temp dir clears
  periodically anyway.

All four hooks are plain Python command scripts (`type: "command"`), not
`type: "prompt"` hooks — `SessionStart` and `SessionEnd` aren't in Claude
Code's prompt-hook-supported event list, and `PreToolUse`/`PostToolUse`
need persisted state (the searched flag, the cost totals) that a stateless
prompt hook can't keep. These hooks share that state through
`_session_state.py`: one JSON file per session under the system temp dir
(`inkwell_session_<session_id>.json`, holding `searched`, `remembers_count`,
`last_remember_ts`, `tokens_in`, `tokens_out`, `cost_usd`), since each hook
invocation is a fresh process with no memory of prior calls. Skip the
SessionStart reminder only with `INKWELL_SESSION_START_DISABLE=1` — it does
not silence the other three hooks.

## Status line

`hooks/inkwell_statusline.py` renders this workflow's live state in Claude
Code's status bar: model, git branch, context-window usage (`used_percentage`
plus a token count from `context_window`), and the `remembers_count` field
the gate hook maintains — e.g.
`[Sonnet 5] | 🌿 main | 34% · 68k/200k tok | 💾 2 remembers`.
`inkwell_cost_tracker.py`'s `tokens_in`/`tokens_out`/`cost_usd` fields are
written to the same state file but deliberately not shown here.

Plugin `settings.json` only supports the `agent` and `subagentStatusLine`
keys, not the main `statusLine` — a plugin cannot auto-register it — so wire
it into your own `~/.claude/settings.json` by hand:

```json
{
  "statusLine": {
    "type": "command",
    "command": "python \"<absolute-path-to-this-repo>/plugins/inkwell-hooks/hooks/inkwell_statusline.py\""
  }
}
```

It only reads the shared session state (never writes it) and the stdin
payload Claude Code provides, so it works whether or not the plugin itself
is installed — the state file just won't exist yet for a session with no
Inkwell tool calls, and every field falls back to its default (`0`/`false`/
`null`).

`${CLAUDE_PLUGIN_ROOT}` in `hooks/hooks.json` resolves to this plugin's
installed/cached directory at runtime under either client (Codex sets it as
an alias of its own `PLUGIN_ROOT` specifically for OOTB compatibility with
existing Claude Code plugins), so the commands work no matter where the
plugin is cached after install — that's why the scripts live under a nested
`hooks/` (the plugin-root-relative directory both clients expect hook
scripts under), not flattened into the plugin root.

## Install

The fastest path is `scripts/install.{ps1,sh}` from the repo root — it
detects whichever of `claude`/`codex` is on PATH and does everything below
(MCP server, plugin, global instructions) for each one automatically. See
"Setup" further down for exactly what it does and what's still manual.

To do it by hand, or to understand what the script automates:

### Claude Code

From any directory, inside a Claude Code session:

```
/plugin marketplace add <path-or-url-to-this-repo>
/plugin install inkwell-hooks@inkwell-memory
/reload-plugins
```

- Local development / testing this repo directly: `/plugin marketplace add
  C:/Users/<user>/Desktop/projects/My/inkwell_memory` (or wherever you cloned
  it), or skip the marketplace entirely and run
  `claude --plugin-dir ./plugins/inkwell-hooks` to load it for one session
  without installing.
- Shared/remote install: point `/plugin marketplace add` at this repo's git
  URL or `owner/repo` GitHub shorthand instead of a local path — the
  `inkwell-hooks` entry in the repo's `.claude-plugin/marketplace.json`
  resolves the same way.
- `/plugin install` opens a scope picker (user/project/local); pick `user`
  to have the hooks active in every project.

This replaces hand-copying this folder into `~/.claude/hooks/` and merging
`hooks.json` into `~/.claude/settings.json` — Claude Code now manages the
plugin's cache location and wires `hooks/hooks.json` in automatically once
installed and enabled.

### Codex

From the repo root:

```
codex plugin marketplace add ./plugins
codex plugin add inkwell-hooks@inkwell-memory
cp plugins/inkwell-hooks/agents/inkwell-project-onboarder.codex.toml ~/.codex/agents/inkwell-project-onboarder.toml
```

(or `codex plugin marketplace add <repo>/plugins` from elsewhere, and
`owner/repo` / a git URL for a shared/remote install, same as Claude Code).
Codex's `hooks` feature (`CodexHooks`) is stable and enabled by default, so
no `config.toml` feature flag is needed — installing and enabling the plugin
is enough. The `inkwell-project-onboarder` agent doesn't ship with the plugin
(see above) — the `cp` step is what actually places it, and `scripts/install.{ps1,sh}`
does it automatically.

## Setup (fresh machine / new global config)

`scripts/install.ps1` (Windows) / `scripts/install.sh` (macOS/Linux) run all
of this in one pass, best-effort (a failing step warns and the script keeps
going rather than aborting):

1. **Detect** which of `claude` / `codex` are on PATH — everything below
   only happens for the CLI(s) actually present.
2. **Knowledge base directory.** Shared across both clients at
   `~/.inkwell/knowledge` (client-agnostic — Inkwell itself isn't tied to one
   agent). If an older `~/.claude/inkwell/knowledge` exists from a previous
   install, the script moves it to the new location instead of creating an
   empty one.
3. **MCP server + plugin, via each CLI's own commands** — `claude mcp add`
   + `claude plugin marketplace add`/`install`, and/or `codex mcp add` +
   `codex plugin marketplace add`/`add`, pointing at the shared knowledge
   dir and this repo's marketplace(s).
4. **Global instructions**, same shape for both clients: creates an
   `inkwell/` folder under each present client's home dir
   (`~/.claude/inkwell/`, `~/.codex/inkwell/`) holding copies of
   `INKWELL_SPEC.md` + `INKWELL_TEMPLATES.md`, then wires it into that
   client's global instructions file — `@inkwell/INKWELL_SPEC.md` import line
   in `~/.claude/CLAUDE.md` for Claude Code; for Codex, which has no
   `@`-import in `AGENTS.md`, the two files' resolved content (with the
   `@INKWELL_TEMPLATES.md` reference expanded inline) is written into
   `~/.codex/AGENTS.md` between `<!-- BEGIN/END inkwell-memory -->` markers,
   replaced in place on re-run rather than duplicated.

One thing stays manual regardless — a plugin/script can't do this safely on
its own:

- **Disable Claude Code's own built-in auto memory** (`MEMORY.md` under
  `~/.claude/projects/<project>/memory/`) — a separate system from Inkwell;
  running both means two systems writing overlapping notes. Set in
  `settings.json` (any scope):

  ```json
  { "autoMemoryEnabled": false }
  ```

  or via environment variable, which takes precedence over both the
  setting and the `/memory` toggle: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`.

Only Claude Code and Codex are supported so far.

Sanity check after installing: start a session and confirm
`hooks/logs/debug.log` (next to the scripts, inside the installed plugin's
cache directory) gets a `session_start` line; call `remember` before ever
calling `search`/`recall` and confirm it's denied; call `search` and retry
`remember` and confirm it now succeeds; end the
session and confirm `inkwell_session_<session_id>.json` in the system temp
dir is gone afterward (Claude Code only — see the Codex gap above).
