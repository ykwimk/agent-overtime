# Agent Overtime

English · [한국어](README.ko.md)

**Your agents' office, lights on all night.** A small macOS app that shows your Claude Code sessions and their subagents at work in a pixel office: who is working, who is waiting for your answer, who is resting, and who has gone home.

Works with Claude Code. Not affiliated with Anthropic.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/office-dark.png">
  <img alt="The office window: each session at its own island of four desks with its subagents, and one session's side panel open with its state, what it is doing, its tasks, edited lines and latest steps" src="docs/images/office-light.png">
</picture>

| State | What it means | What you see |
|---|---|---|
| Working | Producing an answer | Sitting at the desk, laptop on, `…` bubble |
| Waiting · n min | Needs your permission or answer | Still sitting, a `!` bubble hopping over the head |
| Resting | Done, waiting for your next instruction | Nodding off in the chair, `z` bubble |
| Quiet | Running, but no news from it yet (opened before the app) | Sitting up at the desk, laptop on, no bubble |
| Off duty | The session ended | Walks out the door with its subagents; once the last one is out, the island goes |

- Each session gets its own island of four facing desks, nearest the door first: the session in the corner seat, its subagents in the other three. From the fourth subagent on, the session's name tag shows "+n". The default window fits four sessions; a fifth scrolls. A session's name tag is its folder's name ("~" for your home folder); a second session in the same folder is "name 2", at an island of its own.
- Zoom the office like a map: pinch or ⌘-scroll over it, and it settles on the nearest sharp size (50 to 150 %) when you let go; ⌘+, ⌘− and ⌘0 (View menu), or − and + beside Start Work, step through those sizes. The islands stay where they are; zoomed in, the room scrolls both ways. When islands are out of sight, a line in the corner says how many ("1 more team below ↓"); click it to scroll there.
- Subagents walk in and sit at their session's island. The caller walks over to hand out the work, and a subagent that finishes walks over to report before it leaves. When a session hands work to two or more subagents and waits, they meet in the glass meeting room; a subagent whose caller keeps working puts on headphones and skips meetings.
- Click a character or its name tag for a side panel: the state on a badge and for how long, what it is doing now, and with Show Details on (the default) the file it works on, its task list or subagents done, the lines it changed, its latest steps and the model; then the subagents. The pencil button next to the name gives a nickname, kept on this Mac.
- The menu bar icon turns into `! 2` while sessions wait for you, and its window shows the app's version. Session data stays on this Mac; the only thing the app asks the internet is whether a new version exists, and you can turn that off.

## Start here

### 1. Install

```
brew install --cask ykwimk/tap/agent-overtime
```

Or download the `.dmg` from [Releases](https://github.com/ykwimk/agent-overtime/releases) and drag `AgentOvertime.app` into **Applications**. Keep its name: the plugin looks for `/Applications/AgentOvertime.app` or `~/Applications/AgentOvertime.app`.

### 2. First launch

The first launch is blocked because the app is not notarized by Apple. Open **System Settings > Privacy & Security**, click **Open Anyway** at the bottom, then **Open**. On macOS 13 and 14, right-click > **Open** in Finder also works; from macOS 15 the System Settings route is the only one.

### 3. Connect

Click **Copy Connect Commands** in the app's first window and paste the two lines into Claude Code:

```
/plugin marketplace add ykwimk/agent-overtime#v0.5.0
/plugin install agent-overtime@agent-overtime
```

When Claude Code asks, choose **Install for you (user scope)** so it applies to every project on this Mac. Sessions that were already open need `/reload-plugins` once.

### 4. One-minute check

Sessions already open sit at their islands as Quiet. Send Claude Code one message: its character gets to work at the desk named after your folder (for `~/my-project`, the desk says `my-project`); a session started after the app walks in through the office door. Nothing after 30 seconds? See the first question below.

## FAQ

**Homebrew says "untrusted tap".**
Run the install command again with the full name: `brew install --cask ykwimk/tap/agent-overtime`. With the full name, Homebrew trusts only this app, not the whole tap, and installs it.

**My character doesn't show up.**
Is agent-overtime turned on in Claude Code's `/plugin` list? Was the session already open (type `/reload-plugins` in it once)? Is the app in the Applications folder? Did you send Claude Code a message after installing?

**A session I opened earlier isn't in the office.**
With Find Sessions Without the Plugin on (Settings > Connection, the default), it shows as Quiet within a few seconds. If it doesn't, type `/reload-plugins` in it once: it then appears the next time it moves.

**Why does macOS block the app? Is it safe to open?**
Notarization needs Apple's paid developer program, which this project doesn't use yet. The code is public, and you can check that your download matches the release (see [Verify the download](#verify-the-download)).

**I allowed a permission, but it still says Waiting.**
Claude Code sends no separate "allowed" event, so the state changes at the session's next event (a few minutes for a long command).

**Does it work with other agents?**
Not yet. Only Claude Code for now; other agents are on the [roadmap](#roadmap).

**How do I turn it off or remove it?**
Turn off or remove `agent-overtime` with `/plugin` in Claude Code. Then `brew uninstall --cask agent-overtime` or move the app to the Trash; its data is in `~/Library/Application Support/AgentOvertime`.

## Similar apps

| | What it shows | Where it runs | Install | How it knows the state | Network | License |
|---|---|---|---|---|---|---|
| Agent Overtime | Claude Code sessions and subagents you already started, in four states; waiting count in the menu bar | Mac app (office window and menu bar), macOS 13+ | Homebrew cask or `.dmg`, then two plugin lines | Plugin hooks send to a socket on your Mac | Update check only (when the app opens and once a day, can be turned off); no ports opened | MIT (art: OGA-BY 3.0 and CC0) |
| [Pixel Agents](https://github.com/pixel-agents-hq/pixel-agents) | Coding agents in your terminals as pixel characters in a small office; subagents and teammates as their own characters; bubbles when waiting for input or permission. Launches Claude Code from the office | VS Code extension, or a standalone CLI that serves the office to your browser. Windows, Linux, macOS | VS Code Marketplace or Open VSX, or `npx pixel-agents` (Node.js 20+) | Hooks; reads session transcripts when hooks are unavailable and for details not in an event. Also picks up sessions started outside it | Standalone CLI: local server on a free port, `127.0.0.1` by default | MIT |
| [Outworked](https://github.com/outworked/outworked) | Claude as a team of AI employees: hire agents, describe a goal, and watch them write code, use the web, send messages and run scheduled tasks in an office | Desktop app (Electron), macOS first; release builds for Apple Silicon | Its own Homebrew tap, or `.dmg`; needs Claude Code installed and signed in | Runs its own agents through the Claude Code SDK. Showing sessions started elsewhere: — | Yes, for its features: auto-updates; tunnels (downloads cloudflared on first use), webhook triggers, a built-in browser, Slack and iMessage | GPL-3.0 |

From each project's README, November 2026. If something here is wrong, please open an issue.

- Another app fits better if you want the office inside VS Code, on Windows or Linux, or want to launch agents from it (Pixel Agents), or want an app that runs a team of agents toward a goal for you (Outworked).
- What this app can't do: it works with Claude Code only and on macOS only, it isn't notarized yet, and it never starts agents or gives them work. It only shows the sessions you run.

## How it works

1. The plugin adds hooks for ten Claude Code events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SubagentStart`, `SubagentStop`, `PostModelSwitch`, `SessionEnd`; see [`plugin/hooks/hooks.json`](plugin/hooks/hooks.json)). Each one runs a small helper inside the app, `agent-overtime-hook`.
2. The helper keeps only: event name, session id, folder path, subagent id and name, notification type, whether the tool is AskUserQuestion or SendMessage, the recipient of a SendMessage (its `to` field only), a tool kind (one of a fixed list, such as reading files, searching code, running a command, or other), and the Claude Code process id. With Show Details on (Settings > Side Panel, on by default) it also keeps: the file a Read, Write, Edit, MultiEdit or NotebookEdit call works on, shortened inside the helper (inside the session's folder at most its last two parts, such as `…/ui/button.css`; outside it, only the file name; never the full path), how many lines an edit adds and removes (counted inside the helper, the text itself is dropped), the title, status and id of tasks in Claude's task list, and the model name. Commands, search patterns, web addresses, file contents, the text of edits, prompts, the message itself and transcripts are dropped right after parsing; they are never stored or sent. Tool names become a kind inside the helper; MCP tools and any tool it does not know count as "other", so MCP server names never leave the helper. The recipient is only matched against teammates already at a desk, then dropped. The app keeps these values in memory only and forgets them when the session or teammate ends. With Show Details off, the helper does not read or send any of them. The transcript file is never opened.
3. The helper hands the values to the app over a unix socket only your user can open (folder 0700, file 0600). It prints nothing and always exits within 0.5 s.
4. The app only changes the picture, and nothing in an event is ever run. The office, its side panel and the menu show states, names (folder names, subagent names, your nicknames) and a tool kind (for example "Editing files"). File names, task titles and the model appear only in a person's side panel and in what VoiceOver reads from it, never on the office floor, in tooltips, the menu or notifications. Commands and full file paths are never shown. Full folder paths show only in Start Work and Settings, next to the start command you set up. Anyone who can see your screen, for example while you share it, can read an open side panel; turn off Show Details to leave file names, task titles and the model out.
5. Finding sessions without the plugin (Settings > Connection, on by default): every 5 seconds the app lists your own user's processes and picks out Claude Code by its program name or path. For each one it reads only the process id, parent process id, program name and path, start time, working folder and CPU time. These are standard macOS process calls that need no extra permission. It never reads command lines, environment variables or other users' processes, and never sends a process a signal. A session found this way shows under its folder's last name as "Quiet", or "Working" while it uses CPU. Nothing about it is stored, logged or sent anywhere, and its folder is not added to recent folders. Once the session sends a hook event, the two are joined by process id, and from then on its folder is remembered like any other session's. Turn this off and only sessions that send hook events appear.
6. Update check (Settings > Updates, on by default): the app sends one `GET` to GitHub's releases API and reads only the version number from the answer. It never reads the release notes and never runs anything in the answer.

- Meetings are a picture of a session handing out work: when it has two or more subagents out and does nothing of its own for 10 seconds, they meet in the meeting room. The app never knows what anyone says, so speech bubbles stay empty.
- Network: no ports, no analytics, no crash reports. The app makes one kind of request on its own: with Check for Updates on (Settings > Updates, on by default), it asks GitHub for the latest release number when it opens and once a day (`GET https://api.github.com/repos/ykwimk/agent-overtime/releases/latest`). The request carries the app's name and version (User-Agent) and standard headers, with no cookies or install id. As with any web request, GitHub sees your IP address. Turn it off and the app makes no requests. Nothing is downloaded until you click Update.
- On disk: `~/Library/Application Support/AgentOvertime/config.json` (0600) with recent folders (folder paths), your start command, and the nicknames you give sessions (by folder path) and teammates (by name). The app's preferences (whether it has connected, the fingerprint of the start command you approved, Show Details, Find Sessions Without the Plugin, the zoom level, the update check setting, the last check time and the last version run) are in its macOS preferences file, `~/Library/Preferences/io.github.ykwimk.AgentOvertime.plist`. Nicknames stay on this Mac: they never go to the hook helper, a log or a notification. Clear them in Settings > Nicknames, and recent folders in Settings > Recent Folders. Side panel details are kept in memory only. Sessions found without the plugin are kept in memory only.

## Verify the download

Each release note lists the SHA-256 of its `.dmg`. Compare it with:

```
shasum -a 256 ~/Downloads/AgentOvertime*.dmg
```

Homebrew checks the same value from the cask on its own.

## Updates

- When the app opens and once a day, it asks GitHub for the latest version number (turn this off in Settings > Updates). If a newer version exists, the office bar and the menu say so. Nothing is downloaded or installed until you click **Update**.
- Homebrew: **Update** opens Terminal and runs `brew update` and `brew upgrade --cask ykwimk/tap/agent-overtime` in plain view. Homebrew checks the download against the SHA-256 in the cask. The new version can need the same approval in System Settings as a first install. Until you allow it, the app stays closed and sessions won't show in the office. Once you allow it, sessions already open use the new helper from their next event.
- `.dmg`: **Update** asks for the latest number once more before it downloads. It then downloads the new `.dmg` from this repository's Releases and checks its signature against a public key built into the app. The private key is not stored on GitHub, so a release changed through a stolen GitHub account fails this check. The app then replaces itself and reopens. If the download or a check fails, the installed app stays as it is. If the new version doesn't open within 30 seconds, the old one comes back. Updating also replaces the helper inside the app. Claude Code sessions already open use the new helper from their next event, without a restart. Sessions keep running while the app reopens.
- Because the app, not your browser, downloads the file, macOS may not show its first-launch approval for the new version. The signature check above stands in for it. To keep that approval step, turn off the update check and download from Releases yourself.
- Each release pins its own tag in the connect commands. To move the plugin to the new tag, run these in Claude Code in this order (`vX.Y.Z` is the new tag; the updated app's **Update Connection Too** and Settings > **Copy Connection Update Commands** copy all three lines with it filled in), then restart the Claude Code sessions you have open:

```
/plugin marketplace remove agent-overtime
/plugin marketplace add ykwimk/agent-overtime#vX.Y.Z
/plugin install agent-overtime@agent-overtime
```

`remove` also uninstalls the plugins installed from that marketplace; the last line installs agent-overtime again.

## Start Work

An optional button that runs one command you register (for example `claude`) in a folder you choose, in a new Terminal window.

- The setup sheet is the confirmation: the folder and each argument on their own line, never truncated, hidden characters spelled out (e.g. `⟨U+200B⟩`).
- The approved fingerprint lives outside the config file. If `config.json` changes outside the app, the next start shows the command again for confirmation.
- The command is written as a single-quoted `.command` file (0700, deletes itself first) and opened by Terminal. The app never adds options to your command.
- If a session is already running in that folder (or below it), the app asks before starting one more.

## Build it yourself

Xcode 16 or later, macOS 13 or later.

```
swift format lint --recursive App AppTests Helper Sources Tests tools Package.swift
swift test
xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -configuration Release -derivedDataPath build build
xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -derivedDataPath build test   # app tests, screenshots in captures/
swift run fake-events   # sends made-up events to the running app, no Claude Code needed
```

Move `build/Build/Products/Release/AgentOvertime.app` into **Applications** (or `~/Applications`), then continue from [3. Connect](#3-connect).

## Roadmap

- Jump from a character's side panel to that session's terminal
- A small always-on-top window
- Other agents such as Codex, once enough people ask in issues

## License

- Code: MIT (see [LICENSE](LICENSE)).
- Art (`App/Art/`): not MIT. Full credits: [`App/Art/CREDITS.txt`](App/Art/CREDITS.txt).
  - The room and furniture: LPC Revised by Eliza Wyatt and contributors (Lanea "Sharm" Zimmerman and others), OGA-BY 3.0. Cropped by Agent Overtime contributors.
  - The people (`App/Art/MetroCity/`): MetroCity Free Top Down Character Pack by JIK-A-4, CC0 1.0 (no attribution required, credited anyway). Layered, cut and slightly recoloured while drawing by Agent Overtime contributors.
