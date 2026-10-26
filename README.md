# Software Factory

A status board for every coding project on this Mac: what's being worked on, what's waiting on you, what's broken and what shipped. A native macOS app in the family of Rounds, Sojourny and Emanata. It has a local HTTP API that Claude Code sessions (and anything else) report to.

- **The board.** Projects that need you come first, as full-bleed cards in their state's color. Every other project is a card with its three-letter code, like an airport code: TDR, EMN, LTC.
- **Project pages.** How long it's been working or waiting, the milestone and its steps, live sessions (worktrees included), and a timeline of reports, sessions and commits.
- **Open the chat in Claude.** For work done in Claude Desktop, you can jump straight to the chat:
  - **Project page:** a chat button sits beside Finder and Terminal. It opens the live session's chat, or else the project's latest chat.
  - **Sessions:** rows show the chat's title and open it when clicked. A Recent chats card lists the project's other chats.
  - **Menus:** card and sidebar menus have "Open Chat in Claude".
  - **Menu bar:** each live project has a chat button.

  It works by reading the file Claude Desktop keeps for each Code chat, in `~/Library/Application Support/Claude/claude-code-sessions`, to match a session's ID to its chat. It opens the chat with `claude://code/continue?session=local_…`. Terminal sessions and other Macs' sessions have no chat to open here.
- **Activity.** Every project's timeline, merged.
- **Menu bar and Dock.** A raised hand and a count in the menu bar when something needs you; a bolt while work is under way. The Dock icon shows how many projects need you.
- **One board on all your Macs.** Run Software Factory on each Mac and turn on Settings › Sync. Each board shares its projects through iCloud Drive and shows the others' with its own, labeled with each Mac's name.
- **Or report from a Mac that doesn't run it.** Turn on Settings › Other Macs and paste one command into Terminal on the other Mac. Its Claude Code sessions then report over the network, labeled with that Mac's name.
- **Finds projects by itself.** It finds every folder Claude Code has had a session in, from the transcripts in `~/.claude/projects`. From each folder it reads the README's first paragraph, the git branch, the last 15 commits and the kind of project. It looks again every three minutes.

## Install

Needs Xcode 27 and XcodeGen (`brew install xcodegen`).

```bash
scripts/install.sh
```

It builds a Release copy, installs it in `~/Applications/Software Factory.app` and links the `factory` command into `~/.local/bin`. It's signed to run locally, so no developer account is needed. Then, once:

- **Claude Code hooks.** In Settings › Claude Code, click Install, or run `factory install-hooks`. Every Claude Code session then reports when it's working, waiting on you or finished, with no changes to any project.
- **Open at login.** Turn it on in Settings › General.

## Design: Switchyard

Switchyard is Rounds' Signal and Sojourny's Wayfinding, applied to a board of projects. The tokens are in [SoftwareFactory/Design/Theme.swift](SoftwareFactory/Design/Theme.swift) and the components in [SoftwareFactory/Design/Components.swift](SoftwareFactory/Design/Components.swift), adapted from Emanata's.

- **Dark first.** Surfaces are `#0B0B0D`, `#151518` and `#1E1E23`. Text is warm off-white `#F5F2EC` at 100%, 62% and 54%. Dark ink sits on every swatch.
- **Color means state, everywhere:**

  | State | Swatch | Glyph |
  |---|---|---|
  | Needs you | Amber `#FFC43D` | `hand.raised.fill` |
  | Blocked | Ember `#FF5533` | `exclamationmark.triangle.fill` |
  | Working (also the tint) | Violet `#9466FF` | `bolt.fill` |
  | Shipped | Mint `#3EDB98` | `checkmark` |
  | Idle | Slate `#8C95A8` | `moon.fill` |

  Commits in the timeline are sky.
- **Type is all SF Pro:**
  - Compressed and heavy for codes, counts and times.
  - Expanded, tracked capitals for labels.
  - Condensed for project names and tasks.
  - Mono for paths, branches and hashes.
- **Components:**
  - Flood cards for live projects, each with a dark "then" bar for what it just did or what's next.
  - Trip-cover cards: a giant code with a split-flap seam.
  - Rounds' strip for steps; the step under way is dashed.
  - Passport-style counts.
  - Sojourny's itinerary for the timeline.
- **Liquid Glass is for controls only.** Content stays opaque.
- **App icon.** A dark card on a violet field, holding a board of status lights.

## How a project's state is worked out

A project's state comes from its sessions (via hooks) and from reports (via the API or `factory`):

1. If any session is waiting on you (a permission prompt, a question, a plan to review), it **needs you**.
2. Otherwise, if a report says it's **blocked**, it's blocked until a later report says otherwise.
3. Otherwise, if any session is **working**, it's working.
4. Otherwise it's whatever the last report said.

Sessions that go quiet stop counting: a working session after 20 minutes, a waiting one after 24 hours. A report of "working" lapses to idle after 45 quiet minutes or when the session's turn ends.

A path resolves to its project. Worktrees under `.claude/worktrees/` and linked git worktrees fold into their repository. A subfolder folds into the repository around it.

## Claude Code hooks

`factory install-hooks` (or Settings) adds the hooks below to `~/.claude/settings.json`. It keeps everything else there and backs the file up to `settings.before-software-factory.json` first. Each hook posts its JSON input, unchanged, to `POST /api/hooks/claude`:

```bash
curl -s -o /dev/null --connect-timeout 1 -m 3 -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:7720/api/hooks/claude || true # software-factory
```

It prints nothing and always exits 0, so a closed app never gets in a session's way.

| Event | What the board does |
|---|---|
| `SessionStart` | Adds the session (idle) |
| `UserPromptSubmit` | Working. The prompt's first line becomes the task; short replies like "yes" keep the task before them |
| `PreToolUse` (AskUserQuestion, ExitPlanMode) | Needs you: the question, or "A plan is ready for your review" |
| `PostToolUse` | Working, with what it just did: "Editing Theme.swift", or a Bash command's description. TodoWrite, the desktop app's `update_plan`, and TaskCreate/TaskUpdate become the session's steps |
| `Notification` (permission prompt) | Needs you, with Claude's message |
| `Stop` | Idle; logs "Finished after 12 m" |
| `SessionEnd` | Removes the session |

`factory uninstall-hooks` takes them out again.

To have Claude report milestones, steps and blockers too, run `factory instructions --install`. It puts a status-board section in `~/.claude/CLAUDE.md`, between `<!-- software-factory -->` markers, so running it again replaces the section instead of adding another, and the rest of the file stays as it is. On a connected Mac, the section names the board's address and that Mac's name. `factory instructions` on its own prints the section, as does Settings › Copy CLAUDE.md Section here, for pasting into a project's CLAUDE.md.

## Sync between Macs

Each Mac can run its own board, and they share through iCloud Drive:

1. **Install the app on each Mac:** clone this repository and run `scripts/install.sh`.
2. **On each Mac, in Settings:**
   - Turn on **Sync**.
   - Click Claude Code › **Install** for the hooks, and run `factory instructions --install`.
   - Give the Mac a name if its computer name isn't a good label.

How it works:

- **Files.** Each board writes its own Mac's projects to `iCloud Drive/Software Factory/Boards/<this Mac's id>.json`, at most every five seconds, and reads the other Macs' files every five seconds. A Mac only ever writes its own file, so the two never conflict. No Apple Developer account or iCloud entitlement is involved: iCloud Drive is just a folder to the app.
- **Merging.**
  - A project on several Macs (same id, repository or name) is one card, and each session and timeline entry carries its Mac's name.
  - For what was reported (state, task, note, milestone, progress, steps, version), the newest report wins, wherever it was made.
  - Commits both Macs found appear once.
- **Delays.** Changes arrive as fast as iCloud Drive syncs, usually seconds, sometimes a minute. A Mac that's asleep or away keeps its last state, and its sessions lapse as they would anyway.
- **Not syncing the network setup too.** A Mac that runs its own board should report to it, not over the network, or its sessions show twice. On that Mac, run `factory disconnect` before installing its hooks.

The sidebar shows which Macs the board is synced with and how recently, as does Settings › Sync.

## Other Macs

A Mac that doesn't run the app can still report to this board over your network:

1. **On this Mac:** in Settings › Other Macs, turn on "Accept reports from other Macs", then click Copy Setup Command.
2. **On the other Mac:** paste the command into Terminal. It downloads the `factory` command from this board into `~/.local/bin`. Then `factory connect` checks the token, saves the board's address in `~/.config/software-factory.json` (readable only by you), and installs that Mac's hooks.

The command looks like this:

```bash
mkdir -p ~/.local/bin && curl -fsS -H 'Authorization: Bearer <token>' http://My-Mac.local:7720/api/factory -o ~/.local/bin/factory && chmod +x ~/.local/bin/factory && ~/.local/bin/factory connect http://My-Mac.local:7720 --token <token>
```

How it works:

- **The Mac's name.** That Mac's sessions, reports and timeline entries carry its name: its computer name, or `--name "Home Mac"`. Settings lists each Mac and when it last reported.
- **Matching projects.** A folder at the same path as here joins the same project. One at a different path matches a project here by its folder's name, like the same repository cloned on both Macs. Otherwise it gets its own card; Finder and Terminal buttons hide for folders that aren't on this Mac.
- **The other Mac's hooks** run `factory hook`, not curl. If the board can't be reached (this Mac asleep or away), it gives up after 2 seconds and doesn't try again for a minute, so Claude Code there never slows down.
- **Security.**
  - With Other Macs off, the API listens on 127.0.0.1 only.
  - With it on, it listens on the network too, and every request from another Mac must carry the token. Requests from this Mac still need none.
  - Browsers are refused either way.
  - New Token in Settings cuts off every Mac set up with the old one; run the setup command again on each.
  - Reports cross the network unencrypted. Use a network you trust, or Tailscale with this Mac's Tailscale name in the URL.
- **Milestones and blockers.** Run `~/.local/bin/factory instructions --install` on the other Mac too, so its Claude reports milestones, steps and blockers.
- **Updating.** When this board's app gets a new version, run `factory update` on the other Mac to download its `factory` again.
- **Stopping.** `factory disconnect` on the other Mac removes its connection, its hooks and its CLAUDE.md section.

## The `factory` command

```bash
factory working "Building the settings screen"     # the message is the task
factory waiting "Need your call on the icon"
factory blocked "Tests fail on iOS 27"
factory done "Shipped 0.3 to TestFlight"
factory idle
factory note "Moved sync to CKSyncEngine"
factory progress 40 --milestone "TestFlight 0.3"
factory steps --done "Design" --active "Build" --todo "Test" "Ship"
factory report --state working --task "…" --version "0.3 (14)" --link pr=https://github.com/…
factory list
factory show [project]
factory connect http://<board>.local:7720 --token <token> [--name "Home Mac"] [--no-hooks]
factory disconnect
factory update                      # on a connected Mac: the board's latest factory
factory instructions [--install]    # the CLAUDE.md section, or put it in ~/.claude/CLAUDE.md
```

It reports for the repository around the current folder; `--project` (`-p`) names another project by id, name or code. `--json` prints the reply, `--quiet` prints nothing. It talks to `$FACTORY_URL`, else the board from `factory connect`, else `http://127.0.0.1:7720`. `$FACTORY_TOKEN` overrides the saved token.

## API

The API listens on `127.0.0.1:7720`, and only on this Mac unless Other Macs is on. The port can be changed in Settings.

- **From this Mac,** no token is needed, but a `Host` other than localhost gets a 403.
- **From another Mac,** requests need `Authorization: Bearer <token>`, or they get a 401. `X-Factory-Machine` names the Mac, percent-encoded.
- **Browsers** get a 403 either way: any request with an `Origin` is refused, so no web page can write to the board. Bodies are JSON and replies are pretty-printed JSON. `curl -s 127.0.0.1:7720` prints a summary.

| Method | Path | |
|---|---|---|
| GET | `/api/health` | `{ok, app, version, port, projects}` |
| GET | `/api/projects` | Every project on the board, in board order (`?hidden=1` includes hidden ones) |
| GET | `/api/projects/{id}` | One project and its timeline (`?events=N`, default 30). `{id}` can be an id, name or code |
| GET | `/api/project?path=/folder` | The project a folder belongs to |
| POST | `/api/report` | A report. The body says which project with `project` (id, name or code) or `path` |
| POST | `/api/projects/{id}` | A report for that project, which is made if it's new |
| DELETE | `/api/projects/{id}` | Hides it from the board (Settings can show it again) |
| POST | `/api/hooks/claude` | A Claude Code hook's input, unchanged |
| GET | `/api/factory` | The `factory` command, for setting up another Mac |

### Reports

Every field is optional; only what's sent changes.

```json
{
  "path": "/Users/you/Star Trader",
  "state": "working",
  "task": "Wiring up the trade screen",
  "note": "Frame time down to 1.7 ms on iPhone",
  "milestone": "Alpha 0.3",
  "progress": 0.4,
  "steps": [
    {"title": "Galaxy map", "status": "done"},
    {"title": "Trade screen", "status": "active"},
    "Combat tuning"
  ],
  "summary": "A space trading game",
  "kind": "game",
  "version": "0.3 (14)",
  "branch": "main",
  "repo": "https://github.com/you/star-trader",
  "links": {"pr": "https://github.com/…/pull/12", "testflight": "https://…"},
  "name": "Star Trader",
  "code": "STR",
  "clear": ["milestone"]
}
```

- **`state`**: `working`, `waiting`, `blocked`, `done` or `idle`. Aliases work too: `needs_input`, `review`, `error`, `failing`, `shipped`, `paused` and others.
- **`task`**: what's under way. For working, the board shows it as the headline.
- **`note`**: a line for the timeline. For blocked, the board shows it as the headline.
- **`progress`**: 0–1, or a percentage (`40`, `"40%"`). Without it, progress is counted from `steps`.
- **`steps`**: replace the checklist. Each step is a string, or an object with `title` (or `content`) and `status`: `todo`, `active` or `done`, or a todo list's `pending`, `in_progress` or `completed`. `"done": true` also works. Steps that turn done are logged.
- **`kind`**: `ios`, `mac`, `apple`, `game`, `web`, `site`, `cloud`, `tool`, `library` or `other`. It picks the project's symbol, and `symbol` sets any SF Symbol instead.
- **`clear`**: empties fields: `task`, `note`, `milestone`, `progress`, `steps`, `summary` or `version`.

The reply is the project as the board shows it: `state` and `label` ("Needs you"), `since`, `headline`, `steps`, `sessions`, `chat` (the Claude Desktop chat to open: `title` and its `claude://` `url`) and the last five events. Errors come back as `{"error": "…"}` with a 400 or 404.

## Data

The board lives in `~/Library/Application Support/Software Factory/projects.json`. Each project keeps its last 200 events and up to 12 sessions. Sessions nobody has heard from in three days are dropped.

## Development

```bash
xcodegen generate
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactory -derivedDataPath build/DerivedData build
```

To run a test copy beside the real one without touching your board:

```bash
"build/DerivedData/Build/Products/Debug/Software Factory.app/Contents/MacOS/Software Factory" -FactoryDataDir /tmp/board -FactoryPort 7799
```

Debug builds add `POST /api/debug/snapshot?dir=/some/folder`, which renders the board, the first three projects, Activity and the menu bar panel to PNGs. Screen capture isn't allowed from a shell here; glass controls don't show in the snapshots.

- **`SoftwareFactory/`** is the app:
  - `App/`: scenes, navigation, snapshots.
  - `Design/`: Switchyard.
  - `Model/`: projects, reports, hooks, path resolution.
  - `Store/`: the board and discovery.
  - `Server/`: the HTTP server and API.
  - `Views/`: the screens.
- **`Factory/`** is the `factory` command. It's embedded at `Contents/MacOS/factory`.
- **`Shared/`** holds what the app and the command share: `ClaudeSetup.swift` installs the hooks, and `ProjectPath.swift` finds a folder's repository.
- **`scripts/`**: `install.sh`, and `make-icon.swift`, which renders the app icon.
