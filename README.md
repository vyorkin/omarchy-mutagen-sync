# Mutagen Sync for Omarchy

Mutagen's synchronization sessions in the Omarchy bar. One glyph, a count when
something wants a look, and a popup with the per-session truth behind it.

```
󰓦          every session watching
󰓦 3        three sessions want a look
󰅖          the daemon is not reachable
```

## What the bar shows

| Bar | Meaning |
| --- | --- |
| `󰓦` | Every session watches and both endpoints are connected. Nothing to do. |
| `󰓦 3` | Three sessions are not healthy: an endpoint is not connected, the session is not watching, or it is paused. |
| `󰓦 2` in the urgent colour | Two sessions have conflicts. Conflicts are the one thing that overrides everything else, because they wait for a decision. |
| `󰅖` | `mutagen sync list` failed — usually a daemon that is not running, or a `mutagen` that is not installed. The tooltip carries the first line of the error. |

Hovering shows a one-line summary: sessions, how many are watching, conflicts,
sessions that want a look, and symlink notes.

## The popup

Click the glyph (or `SUPER+CTRL+...` summon, see below) to open it:

- one row per session, the ones that want a look first, then alphabetical;
- each row shows the session name with the common `<project>--` prefix removed
  (`omarchy-setup--config-hypr` reads as `config-hypr`), its conflicts, its
  symlink notes and its state in plain words (`watching`, `connecting`,
  `staging`, `paused`, `halted`, `disconnected`).

Actions:

| Input | Effect |
| --- | --- |
| Left click on the glyph | Toggle the popup |
| Middle click on the glyph | Poll now |
| `j` / `k`, arrows | Move between sessions |
| Enter, or a click on a row | `mutagen sync flush <session>` — sync that session now |
| `r` | Poll now |
| Escape | Close |

The popup can also be opened from anywhere Omarchy routes IPC:

```bash
omarchy-shell shell toggle io.github.vyorkin.mutagen-sync
```

Bind that to a key in `~/.config/hypr/` if you want a keyboard summon.

## Install

```bash
omarchy plugin add https://github.com/vyorkin/omarchy-mutagen-sync --enable
```

Remove it with:

```bash
omarchy plugin remove io.github.vyorkin.mutagen-sync
```

## Requirements

- `mutagen` on `PATH`, with its daemon running (the widget says so in the
  tooltip when it is not).
- Nothing else. No `jq`, no helper binary, no account, no network.

## Cost

The widget asks the daemon for one compact list per poll: every 5 s with the
popup closed, every 1.5 s while it is open. That is a single `mutagen sync list`
call, which the daemon answers in about ten milliseconds — the response for
thirty sessions is about 1.6 kB.

Details that keep it from ever hanging:

- Mutagen has no JSON output switch, so the widget hands `mutagen sync list` a Go
  template and gets one tab-separated line per session back. `{{json .}}` would
  be about a hundred times larger for the same information.
- The template guards both endpoints: `ScanProblems` lives on a struct that is
  nil until an endpoint reports in, and a template that dereferences it anyway
  fails the *whole* command — which would silently drop every session from the
  bar instead of showing one as connecting.
- One poll is in flight at a time, and each poll runs on a fresh process object.
  A reused one can lose its exit event and then report running forever, which
  would stop the widget for the rest of the session.
- A poll that outlives 10 s is killed; if it still does not report back, its
  object is dropped and the next tick starts on a new one.

## Why scan problems do not colour the bar

Mutagen refuses to synchronize absolute symlinks — it reports them as "scan
problems" and syncs everything else. A repository that stores such links in a
file and recreates them on the other machine (Omarchy's own setup does exactly
that) therefore always has a pile of them. They are worth seeing, so the popup
and the tooltip count them, but they never make the bar warn: a warning that can
never be cleared is noise.

## Configuration

There is none, on purpose. The poll intervals, the timeout and the number of
rows before the list scrolls are constants at the top of `Model.js`; edit them
there if you want a different cadence.

## Development

```bash
omarchy plugin validate .
```

`Model.js` is plain JavaScript with no QML imports, so the parsing and the
summarising can be exercised on their own:

```bash
node -e '
const fs = require("fs");
const src = fs.readFileSync("Model.js", "utf8").replace(".pragma library", "");
eval(src);
const out = require("child_process").execSync(
  "mutagen sync list --template " + JSON.stringify(LIST_TEMPLATE)).toString();
const sessions = parseSessions(out);
console.log(summarize(sessions));
console.log(sessions.slice(0, 3));
'
```

## License

MIT — see [LICENSE](LICENSE).
