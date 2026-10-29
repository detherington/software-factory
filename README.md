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
- **To-dos.** Each project has your own to-do list, apart from Claude's plans, for things you notice or think of to tackle there:
  - **Project page:** a To do card. Type and press Return to add; click the circle to tick one off; double-click to edit. On hover, **Start in Claude** opens a new Claude Desktop session in that folder with the to-do in its message box (`claude://code/new?folder=…&q=…`, not sent).
  - **Board:** cards show "3 to do", and the sidebar shows the count.
  - **Quick capture:** "Add To-Do…" in any card's menu, the field in the menu bar panel, or `factory todo "…"` in Terminal. That includes Claude, when you ask it to note something.
  - **Sync:** the list syncs between Macs. The latest change to each item wins, and deletions are kept 30 days so they reach every Mac.
- **Saved prompts.** Prompts you send often, like "Ship a build to TestFlight", each a click from a new Claude Desktop chat in the project's folder with the prompt typed in (not sent).
  - **Project page:** a Prompts card lists the project's own prompts, then those for every project. Click one to start it; **+** adds one; hover to edit.
  - **Menus:** card and sidebar menus have "Start Prompt".
  - **To start with:** three prompts for every project (Commit and push, Tidy loose ends, What's next?). Change or delete them as you like.
  - **Sync:** prompts sync between Macs. The latest change to each wins.
- **The palette.** ⌘K in the board window, or ⌥⌘K from any app (Settings › General turns that off). Type a project's code or name, then Tab or a space for what you can do there: open it, open its chat, show it in Finder or Terminal, or start one of its prompts. Keep typing to narrow the prompts. Words that match nothing become a to-do or a new chat: `emn todo fix the page turn` adds a to-do to Emanata, and `emn why does the reader stutter?` starts a chat with that question typed in.
- **Morning digest.** One notification a day, at 9:00 unless you pick another time: "Yesterday: 6.5 hours, 31 commits, 3 TestFlight builds. Waiting on you: Emanata and Rounds." It comes the first time you use a Mac after that time, and only one of your Macs sends it. Click it for **Today** (⌘2), which has the same numbers and a list of what's been left, each with what to do about it. See [Morning digest](#morning-digest).
- **Activity.** Every project's timeline, merged (⌘3).
- **Passport.** Your week in numbers (⌘4): the hours Claude worked, sessions, commits, TestFlight builds, releases and tokens. Each day is a bar, each project a row, and milestones get stamps: a release, a new project, the busiest day, the longest turn, days in a row. Switch between this week, last week and the last 30 days. See [Passport](#passport).
- **Notifications.** It tells you when something changes instead of waiting for you to look. Each kind can be switched off in Settings › Notifications:
  - **Needs you, Your call, Blocked:** when a session enters one, with its message. These make a sound.
  - **Background work finished:** a background command or agent.
  - **Shipped:** a release.
  - **TestFlight build ready:** a build has finished processing and can be tested.
  - **Turn finished:** a turn that ended without a question. Off by default.
  - **A reminder after an hour:** the same notice again, with a sound, when something has waited on you for an hour. Off by default.

  Clicking one opens the session's Claude Desktop chat when it has one, and the board otherwise; **Open Chat** and **Show on Board** do the same from the notification. Notifications are grouped by project, several arriving together come as one, and a "needs you" leaves Notification Center once it's answered. Sessions on other Macs notify too, labeled with the Mac (switch that off in Settings). Only what happened in the last two minutes notifies, so opening the app, or a synced board catching up, doesn't replay old news.
- **TestFlight and the App Store.** With an App Store Connect API key, each app's card shows its latest build and App Store version: "1.0 · In testing", "1.0 · Waiting for review", "1.1 · On the App Store". Its project page lists recent builds for each platform. A build that fails processing or a rejected version turns the card Blocked, and a version going live counts as Shipped. See [App Store Connect](#app-store-connect).
- **On your iPhone.** The Factory app shows the board, with widgets for the Home Screen and Lock Screen, and alerts you when something needs you while you're away from your Macs. See [iPhone](#iphone).
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

## Updating

Settings › Updates shows the version (with the commit it was built from) and whether GitHub has anything newer. **Update and Restart** installs it. The sidebar shows "Update available" when there is.

- **How it works:** each build records the clone it was built from and its commit. The app runs `git fetch` in that clone at launch and every six hours, and lists the new commits. To update, it runs what you'd type in that clone: `git pull --ff-only`, then `scripts/install.sh`, which builds the new version, replaces the app in `~/Applications`, and reopens it.
- **What it needs:** a clone of this repository, installed with `scripts/install.sh`, plus Xcode and XcodeGen on that Mac.
- **Logs and status:** if an update stops (a local change in the way, a failed build), the app carries on and says so, with the log at `~/Library/Logs/Software Factory/update.log`. `GET /api/health` reports the build's `commit` and the `updates` waiting.

## Design: Switchyard

Switchyard is Rounds' Signal and Sojourny's Wayfinding, applied to a board of projects. The tokens are in [SoftwareFactory/Design/Theme.swift](SoftwareFactory/Design/Theme.swift) and the components in [SoftwareFactory/Design/Components.swift](SoftwareFactory/Design/Components.swift), adapted from Emanata's.

- **Dark first.** Surfaces are `#0B0B0D`, `#151518` and `#1E1E23`. Text is warm off-white `#F5F2EC` at 100%, 62% and 54%. Dark ink sits on every swatch.
- **Color means state, everywhere:**

  | State | Swatch | Glyph |
  |---|---|---|
  | Needs you | Amber `#FFC43D` | `hand.raised.fill` |
  | Blocked, or stopped on an error | Ember `#FF5533` | `exclamationmark.triangle.fill` |
  | Your call: finished with a question for you | Tangerine `#FF8C1A` | `questionmark.bubble.fill` |
  | Working (also the tint) | Violet `#9466FF` | `bolt.fill` |
  | Background: waiting on work it started | Sky `#45AEFF` | `hourglass` |
  | Shipped | Mint `#3EDB98` | `checkmark` |
  | Idle | Slate `#8C95A8` | `moon.fill` |

  Commits in the timeline are sky too.
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

1. If any session is waiting on you (a permission prompt, a question, a plan to review, or a next-step box that says it's blocked on your answer), it **needs you**.
2. Otherwise, if a report says it's **blocked**, or a session stopped on an error, it's blocked: until a later report, or the session's next turn.
3. Otherwise, if a session finished its turn with a question for you in Claude Desktop's next-step box, it's **your call**.
4. Otherwise, if any session is **working**, it's working.
5. Otherwise, if a session finished its turn but is waiting on work it started, it's in the **background**.
6. Otherwise it's whatever the last report said.

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
| `PreToolUse` (AskUserQuestion, ExitPlanMode, Bash) | Needs you: the question, or "A plan is ready for your review". For Bash, what's about to run, while it runs |
| `PostToolUse` | Working, with what it just did: "Editing Theme.swift", or a Bash command's description. TodoWrite, the desktop app's `update_plan`, and TaskCreate/TaskUpdate become the session's steps |
| `Notification` (permission prompt) | Needs you, with Claude's message |
| `PreCompact`, `PostCompact` | Working · Compacting, until the compaction is done |
| `Stop` | Blocked if the turn ended on an API error; Your call (or Needs you) if Claude Desktop's next-step box asked a question; Background while work the session started hasn't reported back; otherwise Idle. Logs "Finished after 12 m" |
| `StopFailure` | The turn ended on an API error: Blocked, with the error in words |
| `SessionEnd` | Removes the session |

**Questions and errors.** Claude Desktop's next-step box (`wrap_up`) is how a turn ends with a question for you. Its `ask` becomes the card's headline: Your call, or Needs you when the box says it's `blocked` on your answer. A turn can also stop without finishing: on an API error (no connection, out of usage credits) or because you interrupted it. Then Claude Code may not run the Stop hook, which would leave the card saying Working. So when a session on this Mac has been quiet for a minute while marked working, the board reads the last exchange in its transcript. An error turns the card Blocked, with the error in words; an interruption makes it idle.

**Background work.** A session that finishes its turn with work still running is shown as **Background** (sky), with what it's waiting on. That covers:
- a background command (`backgroundTaskId`), an async agent (`agentId`) or a monitor (`taskId`), from the tool's result in `PostToolUse`;
- a scheduled wake-up (`scheduledFor`).

Each ends when its `<task-notification>` arrives with a final status (`completed`, `failed`, `stopped`), when `TaskStop` stops it, or when a monitor expires or a wake-up fires. The transcript has what the hooks miss, so when a turn ends, and at launch and every three minutes for sessions that look idle, the board checks the end of the session's transcript. That catches work started while the board wasn't running (or was an older version), and notifications that never reached it. Anything left counts for six hours at most.

**What working means right now.** A working card's chip says more when it can, with the matching glyph:
- **Planning:** the session is in plan mode (`permission_mode`).
- **Testing, Building, Shipping:** what the Bash command under way is for, from its description or the command itself. Tests, smoke runs and checks count as Testing; builds and archives as Building; TestFlight, deploys and uploads as Shipping.
- **Compacting:** the conversation is being compacted.

**Loose ends.** Discovery runs `git status --porcelain=v2 --branch` in each project's folder. Uncommitted files and commits not yet pushed show as chips on resting cards and the project page, like "± 4 changed" and "↑ 1 unpushed". On a synced board they're labeled with the Mac: "on Ratatoskr".

**Keeping the hooks current.** When a new version listens to more events, the app updates the hooks it installed at launch, keeping the command they run. It backs your settings up first and leaves everything else as it was.

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

- **Files.** Each board writes its own Mac's projects to `iCloud Drive/Software Factory/Boards/<this Mac's id>.json`, at most every five seconds, and reads the other Macs' files every five seconds. A Mac only ever writes its own file, so the two never conflict. Saved prompts (`Prompts/`), the Passport's numbers (`Stats/`), the digest's sends and snoozes (`Digest/`) and when you last used each Mac (`Presence/`) are shared the same way, in folders beside `Boards/`. No Apple Developer account or iCloud entitlement is involved: iCloud Drive is just a folder to the app.
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

## App Store Connect

Settings › App Store Connect takes an App Store Connect API key: its key ID, issuer ID and `.p8` file. **Fill In from ~/.zshrc** copies them from `export ASC_KEY_ID=…`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` lines, the ones upload scripts use. The key file stays where it is; only its path is kept.

- **Matching.** Apps are matched to projects by bundle ID, which the board reads from the project's `project.yml` or Xcode project: of the IDs there, the shortest that isn't a test target's.
- **Checking.** Every ten minutes, and every two while a build is processing. It reads each app's latest builds (two per platform), their TestFlight state, and each platform's newest App Store version, plus the one on the App Store if that's older. It only reads.
- **What it reports.** The first check only learns what's there. After that, a build ready to test goes in the timeline and notifies; a build needing export compliance goes in the timeline; a failed build or a rejection is a Blocked report; a version on the App Store is a Shipped report. A build or version on iOS and Mac at once is one piece of news.
- **Other Macs.** Only one Mac needs the key: the status syncs with the rest of the board.

## Passport

The numbers come from what's already on this Mac:

- **Hours, sessions and tokens:** from Claude Code's transcripts in `~/.claude/projects`, subagents' included.
  - **Hours:** the time Claude spent on your turns, from your message to its last reply, taken from the timestamps of everything in between. Waiting for you doesn't count: not before your message, and not while a question or plan waits for your answer. No single step counts for more than 30 minutes, so a permission prompt left overnight isn't work. Sessions running at once each count, so a day can come to more than 24 hours.
  - **Tokens:** every token each reply used, read from the cache included, which is most of them. Hover over the number for the split.
- **Commits:** from each project's git history, on every branch.
- **Builds:** TestFlight uploads, from [App Store Connect](#app-store-connect). A build number counts once, whatever its platforms.
- **Shipped:** Shipped reports (`factory done`, or an app going live).

How it reads:

- **Fast after the first time.** The first read goes through every transcript, a few seconds per gigabyte. After that it reads only what's been added, every ten minutes and when the Passport opens.
- **Kept for good.** Claude Code deletes transcripts after 30 days (`cleanupPeriodDays`), but what they added up to stays in `passport.json`. Comparisons with an earlier period appear once the record reaches back that far.
- **Both Macs.** With Sync on, each Mac shares its numbers in `iCloud Drive/Software Factory/Stats/<this Mac's id>.json`, and the Passport adds up every Mac's. A repository cloned on both counts its commits once.

## Morning digest

Settings › Morning Digest sets the time and the days (every day, or weekdays), or turns it off.

- **What it covers.** The days since the last digest, through yesterday, for a week at most. Monday's includes the weekend, and a digest after a few days away covers them all. The numbers are the [Passport](#passport)'s, read again first so last night's work counts.
- **What's been left.**
  - **Waiting on you:** questions, permission prompts and plans waiting for an answer, and blocked projects. A question older than a day stays on the list until the project moves on or its chat is archived.
  - **Loose ends:** uncommitted or unpushed work in a project nobody has touched for a day. On this Mac, **Tidy loose ends** starts that prompt there.
  - **Old to-dos:** to-dos nobody has touched for a week. Tick them off, or start one in Claude.
- **Snoozing.** The moon button on each item snoozes it for a day or a week, on every Mac. **Wake Them**, at the foot of Today, brings back everything snoozed.
- **When it comes.** At the time you set, it waits until you've used the Mac in the last two minutes, so it arrives when you sit down. With nothing worked on and nothing left, it doesn't come.
- **One Mac sends it.** With Sync on, each Mac shares when it last sent a digest, and what's snoozed, in `iCloud Drive/Software Factory/Digest/<this Mac's id>.json`. Once one Mac has sent today's digest, the others don't.

## iPhone

The iPhone app, Factory, shows the board your Macs keep. It reads; the Macs write.

- **The board.** Counts, what needs you and what's under way as cards in their state's color, and every other project. Tap one for what's happening, its progress, sessions, to-dos and timeline. Pull to refresh.
- **Widgets.** *Board* (small, medium, large): what needs you, what's working and the latest of the rest. *Needs You* (Lock Screen): how many projects need you, and which. Tap a project to open it.
- **Alerts.** When something has needed you for two minutes (a question, a permission, your call, a block) and nobody has used any of your Macs for five, the iPhone gets a notification with Claude's message. Each Mac shares when you last used it in `iCloud Drive/Software Factory/Presence/`. Settings › iPhone turns alerts off.
- **How the board gets there.** Each Mac with Settings › iPhone on saves every project, a few seconds after it changes, to your private CloudKit database (container `iCloud.com.darrell.softwarefactory`, zone `Board`), without folder paths and with its latest 25 events. Alerts are records too, which a subscription shows on the iPhone as notifications. The Mac makes that subscription when it's missing: iCloud has refused the iPhone's own save of it while taking the Mac's, and a subscription belongs to the iCloud account, not the device that made it. If the iPhone can't set up alerts, its board says why. Only a copy signed with the team can do this: `scripts/install.sh` signs with it when Xcode can, and otherwise signs locally, without iCloud.
- **Two environments.** Debug builds use the container's development environment and Release builds (installed, TestFlight) production, so testing never touches the real board.

Setting it up, once:

1. **Set up signing in Xcode.** With the developer account in Xcode › Settings › Accounts, open `SoftwareFactory.xcodeproj` and build the SoftwareFactory scheme for My Mac, then the SoftwareFactoryPhone scheme for Any iOS Device. Xcode makes the iCloud container, the app group and the profiles, and links them to the app IDs. Only Xcode, or the developer website, can link them; after that, command-line builds and the App Store Connect API key can make and renew profiles.
2. **Install the Mac app** with `scripts/install.sh`.
3. **Deploy the CloudKit schema.** A Debug build sending the board and an alert creates the record types in the development environment, and making the alerts subscription there creates the hidden fields its title, sound and project need. Then in [CloudKit Console](https://icloud.developer.apple.com), deploy the schema to production, even when it lists no changes: the subscription's fields go with it unlisted. Until they do, production refuses the subscription ("Cannot create or modify field 'notif_sound_name'").
4. **Make the app in App Store Connect** (iOS, bundle ID `com.darrell.softwarefactory.ios`). `scripts/testflight.sh` builds it and uploads it for TestFlight; install it from there.

## The `factory` command

```bash
factory working "Building the settings screen"     # the message is the task
factory waiting "Need your call on the icon"
factory blocked "Tests fail on iOS 27"
factory done "Shipped 0.3 to TestFlight"
factory idle
factory note "Moved sync to CKSyncEngine"
factory todo "Rename the export button"   # your to-do list for the project
factory todos                       # lists it, numbered
factory todo done 2                 # ticks off number 2
factory progress 40 --milestone "TestFlight 0.3"
factory steps --done "Design" --active "Build" --todo "Test" "Ship"
factory advance                     # the step under way is done; start the next
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
| GET | `/api/projects/{id}/todos` | Your to-do list: `open` and `done` |
| POST | `/api/projects/{id}/todos` | Adds one: `{"text": "…"}` |
| PATCH | `/api/projects/{id}/todos/{todo}` | Ticks or rewords one: `{"done": true}`, `{"text": "…"}`. `{todo}` is its `id`, or its number in the open list |
| DELETE | `/api/projects/{id}/todos/{todo}` | Deletes one |
| POST | `/api/todos` | Adds one to the project a folder belongs to: `{"path": "…", "text": "…"}` (or `"project"`) |
| POST | `/api/hooks/claude` | A Claude Code hook's input, unchanged |
| GET | `/api/prompts` | Saved prompts: `project` is a project's id, or missing for every project |
| POST | `/api/prompts` | Saves one: `{"title": "…", "text": "…", "project": "…"}`, without `project` for every project |
| GET | `/api/passport` | The Passport's numbers: `?period=this-week` (the default), `last-week` or `month` |
| GET | `/api/digest` | Today's digest: the one sent today, or the one that's coming, with its numbers and what's been left |
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

- **`state`**: `working`, `waiting`, `yourCall`, `background`, `blocked`, `done` or `idle`. Aliases work too: `needs_input`, `review`, `error`, `failing`, `shipped`, `paused` and others.
- **`task`**: what's under way. For working, the board shows it as the headline.
- **`note`**: a line for the timeline. For blocked, the board shows it as the headline.
- **`progress`**: 0–1, or a percentage (`40`, `"40%"`). Without it, progress is counted from `steps`.
- **`advance`**: `true` finishes the step under way, or the first still to do, and starts the next, without sending the list again.
- **`steps`**: replace the checklist. Each step is a string, or an object with `title` (or `content`) and `status`: `todo`, `active` or `done`, or a todo list's `pending`, `in_progress` or `completed`. `"done": true` also works. Steps that turn done are logged.
- **Which checklist shows:** whichever list changed last. That's either the checklist reports set, or a session's own to-do list, which the hooks read from TodoWrite and Claude Desktop's task list. Reporting `done` ticks off a checklist set before it, and Claude Desktop's wrap-up ticks off the step under way.
- **`kind`**: `ios`, `mac`, `apple`, `game`, `web`, `site`, `cloud`, `tool`, `library` or `other`. It picks the project's symbol, and `symbol` sets any SF Symbol instead.
- **`clear`**: empties fields: `task`, `note`, `milestone`, `progress`, `steps`, `summary` or `version`.

The reply is the project as the board shows it: `state` and `label` ("Needs you"), `since`, `headline`, `steps`, `sessions`, `mode` (planning, testing, building, shipping or compacting, while it's working), `looseEnds` (`changes` and `unpushed`, per Mac), `chat` (the Claude Desktop chat to open: `title` and its `claude://` `url`) and the last five events. Errors come back as `{"error": "…"}` with a 400 or 404.

## Data

The board lives in `~/Library/Application Support/Software Factory/projects.json`, the Passport's record in `passport.json`, saved prompts in `prompts.json` the digest's last send and snoozes in `digest.json` and the alerts sent to the iPhone in `phone.json` beside it. Each project keeps its last 200 events and up to 12 sessions. Sessions nobody has heard from in three days are dropped.

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

`POST /api/debug/phone?out=<file>` reads the board back from iCloud and lists the subscriptions; `&alert=1` also saves a test alert, and `&forget=<record>` deletes one. A Debug build uses the development environment; build it with `FACTORY_CLOUDKIT_ENVIRONMENT=Production` and launch it with `-FactoryPhone NO` to look at production without sending a test board to your iPhone.

- **`SoftwareFactory/`** is the app:
  - `App/`: scenes, navigation, snapshots.
  - `Design/`: Switchyard.
  - `Model/`: projects, reports, hooks, path resolution.
  - `Store/`: the board and discovery.
  - `Server/`: the HTTP server and API.
  - `Views/`: the screens.
- **`Factory/`** is the `factory` command. It's embedded at `Contents/MacOS/factory`.
- **`Shared/`** holds what the app and the command share: `ClaudeSetup.swift` installs the hooks, and `ProjectPath.swift` finds a folder's repository.
- **`Phone/`** is the iPhone app and **`PhoneWidgets/`** its widgets. They share the Mac app's model and design files, and **`PhoneKit/`**: `CloudBoard.swift` (the board's records, also in the Mac app) and `BoardCache.swift` (the board the app leaves for its widgets). In the Simulator, a Debug build takes `-FactorySampleBoard <file>` (a JSON array of projects) in place of iCloud, and `-FactoryWidgetGallery YES` draws every widget.
- **`Config/`**: entitlements, and the TestFlight export options.
- **`scripts/`**: `install.sh`; `testflight.sh`, which uploads the iPhone app; and `make-icon.swift`, which renders both apps' icons.
