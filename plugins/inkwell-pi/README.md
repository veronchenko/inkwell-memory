# inkwell-pi

A [pi](https://pi.dev) package porting `plugins/inkwell-hooks` (the Claude
Code / Codex plugin in this repo) to pi. pi has no native MCP client and no
subagent concept of its own, so this package **depends on two third-party pi
packages** rather than reimplementing either:

- [`pi-mcp-adapter`](https://www.npmjs.com/package/pi-mcp-adapter) — spawns
  Inkwell's existing MCP server (the same `docker run ... foreigndmitryi/inkwell`
  command `scripts/install.{ps1,sh}` registers for Claude Code/Codex) over
  stdio and exposes its tools to pi.
- [`@tintinweb/pi-subagents`](https://www.npmjs.com/package/@tintinweb/pi-subagents) —
  gives pi a Claude-Code-style `Agent`/subagent-spawning tool, which
  `inkwell-project-onboarder.md` in this package plugs into.

## Layout

```
inkwell-pi/
├── package.json              <- pi manifest: extensions + prompts, peerDeps on the two packages above
├── .mcp.json.example         <- Inkwell mcpServers entry to merge into your own .mcp.json
├── agents/
│   └── inkwell-project-onboarder.md   <- ported from plugins/inkwell-hooks/agents/, tools: "*"
├── prompts/
│   ├── INKWELL_SPEC.md         <- ported from plugins/inkwell-hooks/INKWELL_SPEC.md
│   └── INKWELL_TEMPLATES.md    <- ported from plugins/inkwell-hooks/INKWELL_TEMPLATES.md
└── extensions/
    └── index.ts               <- session-start reminder + search-before-remember gate + soft change/stop nudge
```

Keep this package's `prompts/`/`agents/` in sync with `plugins/inkwell-hooks/`
the same way that plugin's README documents for its own reference copies:
hard-copy on change, never hand-merge.

## Install

```bash
pi install npm:pi-mcp-adapter
pi install npm:@tintinweb/pi-subagents
pi install <path-or-git-url-to-this-package>   # or: pi -e ./plugins/inkwell-pi/extensions/index.ts for local dev
```

Then, per-project:

1. Merge `.mcp.json.example`'s `inkwell` entry into your project's `.mcp.json`
   (or `~/.agents/mcp.json` for a global install), substituting `${HOME}`
   with an absolute path if your shell doesn't expand it — same knowledge
   directory (`~/.inkwell/knowledge`) the Claude Code/Codex install uses, so
   entries are shared across all three clients.
2. Copy the onboarder agent into pi's subagent discovery path:
   `cp agents/inkwell-project-onboarder.md .pi/agents/inkwell-project-onboarder.md`
   (project-scoped) or `~/.pi/agent/agents/` (global) — `@tintinweb/pi-subagents`
   does not read a package's `agents/` folder automatically, unlike Claude
   Code's plugin loader.
3. Restart pi.

## Known gaps vs. the Claude Code plugin

- **No hard Stop gate.** pi has no blockable event at the point the agent
  would finish its turn (`agent_settled` fires there but "handler return
  values are ignored" per the docs). `extensions/index.ts` queues the
  change-counter/self-report reminder on `agent_settled` and injects it via
  `before_agent_start` at the start of the *next* turn instead — a nudge,
  not an enforced block. If the user ends the session right after the
  threshold fires, the reminder is never shown.
- **No cost/token tracker or statusline port** — pi's event payloads for
  per-tool cost/token fields, and its statusline configuration surface,
  weren't confirmed against the docs, so `inkwell_cost_tracker.py` and
  `inkwell_statusline.py` have no equivalent here yet.
- **Direct MCP tool names are unprefixed** (`search`, `recall`, `remember`,
  `list`, `tags`, `forget`, `rebuild`, `doctor`, per `pi-mcp-adapter`'s
  `directTools` behavior) — collision-prone against other installed MCP
  servers' tools of the same name. If that happens, drop `directTools` for
  `inkwell` in `.mcp.json` and use the adapter's proxy form
  (`mcp({ tool: "search", args: {...} })`) instead; `extensions/index.ts`'s
  `tool_call` matcher would then need `event.toolName === "mcp"` plus an
  `event.input.tool` check rather than matching on `search`/`recall`/`remember`
  directly — not implemented here since the default (unprefixed direct
  tools) doesn't need it.
- **`tools: "*"` on the onboarder agent** is a conservative choice —
  whether `@tintinweb/pi-subagents`'s per-agent `tools:` allow-list accepts
  MCP-exposed direct tool names (vs. only the seven built-ins its README
  lists) wasn't confirmed, so restricting the onboarder to a named subset
  wasn't attempted.
