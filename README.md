# Agent Island

A Dynamic-Island-style overlay that wraps the MacBook notch and shows what your coding agents
are doing: Claude Code, Codex, Gemini CLI, Copilot CLI, Cursor Agent, OpenCode, Aider, Amp,
Qwen Code, Goose, or anything you add.

- **Folded**: a black pill around the notch. The left wing shows activity (bouncing dots while
  an agent works, a bell when one needs you, a check when it's done). The right wing shows how many agents are active.
  **The wings never cover menus.** The island reads where the frontmost app's menus and every
  status icon sit (Accessibility API) and sizes each wing to the free space, keeping an 8pt gap.
  If only one side has room, that side shows everything. If neither has room, or Accessibility
  isn't allowed, the island stays inside the notch and shows a small strip below it instead.
- **Unfolded**: click the island to see one row per agent session with its project folder,
  current action, state and a live timer (working/waiting only; done shows when it finished). Click the header/chevron or anywhere outside to fold.
- **Click to navigate**: click a row (or the alert banner) to jump to that agent. It brings
  the hosting app to the front (Claude, ChatGPT/Codex, VS Code, …). In Terminal and iTerm2 it
  selects the exact tab running the agent; macOS asks once for Automation permission. In VS Code,
  Cursor, Windsurf and Zed it focuses the window for that project. Agents with no GUI parent
  (tmux over ssh, launchd) reveal their folder in Finder. Right-click a row for more options.
- **Alerts**: when an agent finishes or asks for permission, the island briefly drops a banner
  (with an optional sound).
- Menu bar item (capsule icon): fold/unfold, unfold on hover, hide idle agents, sounds,
  install Claude Code hooks, quit.

On Macs without a notch it hangs from the centre of the menu bar.

Accessibility permission is only used to read menu-bar item positions. macOS asks on first launch,
or use menu → **Allow Wings Beside the Notch…**. `build-app.sh` signs the app with a stable
identity (bundle id `local.agent-island`), so the permission survives rebuilds.

## Build & run

Needs only the Xcode Command Line Tools (Swift 5.10+), macOS 14+.

```bash
./build-app.sh --install
```

This builds the app and installs it as `/Applications/AgentIsland.app`, then starts it.

To start it at login, add `AgentIsland.app` in System Settings → General → Login Items.

## How status is detected

Three sources, merged per session (the newest report wins):

1. **The agents' own session logs (no setup).** Claude Code writes `~/.claude/projects/*/<session>.jsonl`
   and Codex writes `~/.codex/sessions/**/rollout-*.jsonl` while they run, for the CLIs and the desktop
   apps alike. The island reads only the newly appended bytes. From them it knows when a turn **starts**,
   what tool or step is running, the final message, and Esc/Ctrl-C interruptions. This is what makes Codex
   accurate, because Codex's `notify` hook only ever reports a turn's end.
2. **Hooks (instant, and the only source of "needs you").** Agents report events through the bundled
   `island` CLI, which writes `~/.agent-island/sessions/*.json`. Permission prompts only show up this way.
3. **Process scan (fallback).** Finds agent processes and treats sustained CPU as **Working**. Used for
   idle sessions that have no recent log activity. App-embedded helpers (e.g. the Codex server inside
   ChatGPT.app) are never listed as sessions.

A session that shows **Working** with no log or hook activity for 5 minutes drops to Idle.

## Performance

Nothing polls. Hook files and the agents' logs are watched with FSEvents (change → island update in
about 15 ms); the process list is rescanned every 5 s. The bouncing dots, spinner and bell are Core
Animation layers (drawn by the system, no per-frame work in the app). The notch strip has its own
small window that reports pointer enter/exit, so the pointer is only tracked globally while the
popup or list is open. The main window is only large while the list is open. On a Mac with a few
active agents this idles at about 0.2% CPU, under 1 wakeup per second, and about 16 MB.
