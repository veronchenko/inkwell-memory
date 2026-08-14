import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Ports plugins/inkwell-hooks' six Claude Code hooks to pi's extension API.
 *
 * Confirmed-portable 1:1:
 * - session-start search reminder  -> pi.on("session_start", ...)
 * - search-before-remember gate    -> pi.on("tool_call", ...) (blockable, per docs)
 *
 * NOT 1:1 — pi has no event that can block the agent from ending its turn
 * (Claude Code's "Stop" hook has no pi equivalent; `agent_settled` fires at
 * the same moment but handler return values are ignored there). The
 * change-counter / self-report reminders below are therefore a soft nudge:
 * they queue a message on `agent_settled` and inject it via
 * `before_agent_start` at the START of the NEXT turn, not a block on the
 * current one ending. A user who stops the session entirely after the
 * threshold fires will never see the reminder.
 *
 * Not ported: inkwell_cost_tracker.py (no session-scoped cost/token fields
 * confirmed on pi's event payloads) and the statusline (plugin `settings.json`
 * statusLine equivalent not investigated for pi).
 */

const SEARCH_TOOLS = new Set(["search", "recall"]);
const REMEMBER_TOOL = "remember";
const EDIT_TOOLS = new Set(["edit", "write"]);

const CHANGE_THRESHOLD = Number(process.env.INKWELL_CHANGE_THRESHOLD ?? 15);
const STOP_INTERVAL = Number(process.env.INKWELL_STOP_INTERVAL ?? 5);
const SESSION_START_DISABLE = process.env.INKWELL_SESSION_START_DISABLE === "1";

const DENY_REASON =
  "No search or recall call has happened yet this session. Search or " +
  "recall first, then call remember — writing a memory without checking " +
  "what's already known risks duplicate or contradicting entries.";

const SELF_REPORT_REMINDER =
  "[inkwell-pi] Review the recent turns in this session against the " +
  '"When to write to Inkwell" rule in INKWELL_SPEC.md. If it applies and ' +
  "remember was NOT called for it, call remember now. If you already " +
  "judged there is nothing worth remembering, ignore this.";

function changeCounterReminder(count: number): string {
  return (
    `[inkwell-pi] ${count} file-editing tool calls (edit/write/git commit) ` +
    "happened since the last remember call. If any of that is worth " +
    "keeping in Inkwell, call remember for it now. If you already judged " +
    "there's nothing worth remembering, ignore this."
  );
}

export default function (pi: ExtensionAPI) {
  // One extension instance per session (pi reloads/rebinds extensions on
  // session_start), so plain module-scope state is session-scoped — no
  // per-session file like the Python hooks needed.
  let searched = false;
  let changeCount = 0;
  let turnsSincePrompt = 0;
  let pendingReminder: string | null = null;

  pi.on("session_start", async (_event, ctx) => {
    if (SESSION_START_DISABLE) return;
    ctx.ui.notify(
      "Search Inkwell (search/recall) before the first substantive action this session.",
      "info",
    );
  });

  pi.on("tool_call", async (event) => {
    const name = event.toolName;

    if (SEARCH_TOOLS.has(name)) {
      searched = true;
      return;
    }

    if (name === REMEMBER_TOOL) {
      if (!searched) {
        return { block: true, reason: DENY_REASON };
      }
      changeCount = 0;
      turnsSincePrompt = 0;
      pendingReminder = null;
      return;
    }

    if (EDIT_TOOLS.has(name)) {
      changeCount += 1;
      return;
    }

    if (name === "bash" && /\bgit\s+commit\b/.test(String(event.input?.command ?? ""))) {
      changeCount += 1;
    }
  });

  pi.on("agent_settled", async () => {
    if (changeCount >= CHANGE_THRESHOLD) {
      pendingReminder = changeCounterReminder(changeCount);
      changeCount = 0;
      turnsSincePrompt = 0;
      return;
    }

    turnsSincePrompt += 1;
    if (turnsSincePrompt >= STOP_INTERVAL) {
      pendingReminder = SELF_REPORT_REMINDER;
      changeCount = 0;
      turnsSincePrompt = 0;
    }
  });

  pi.on("before_agent_start", async (_event) => {
    if (!pendingReminder) return;
    const content = pendingReminder;
    pendingReminder = null;
    return {
      message: {
        customType: "inkwell-nudge",
        content,
        display: true,
      },
    };
  });
}
