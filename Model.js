.pragma library

// Reading `mutagen sync list` cheaply, and deciding what the bar should say.
//
// Mutagen has no JSON output switch, but it does render Go templates, so the
// fields this widget needs are asked for directly. The daemon answers the list
// call in about ten milliseconds, and this compact form keeps the poll at
// ~1.6 kB for thirty sessions instead of the ~170 kB of `{{json .}}`.
// Capitalised names are the Go field names of Mutagen's session struct. The two
// endpoint guards are load bearing: ScanProblems lives on an embedded struct
// that is nil until the endpoint reports in, and a template that dereferences it
// anyway fails the whole command (the session is then silently missing from the
// bar instead of shown as connecting).
var LIST_TEMPLATE = '{{range .}}{{.Name}}{{"\\t"}}{{.Status}}{{"\\t"}}{{len .Conflicts}}'
  + '{{"\\t"}}{{if .Alpha.Connected}}{{len .Alpha.ScanProblems}}{{else}}-{{end}}'
  + '{{"\\t"}}{{if .Beta.Connected}}{{len .Beta.ScanProblems}}{{else}}-{{end}}'
  + '{{"\\t"}}{{.Paused}}{{"\\n"}}{{end}}'

// Poll cadence. The bar on its own is cheap, so it polls slowly; an open popup
// is what the user is looking at, so it polls quickly. One poll is in flight at
// a time either way.
var POLL_INTERVAL_MS = 5000
var POLL_INTERVAL_OPEN_MS = 1500

// When `mutagen` is not installed, or the daemon has been failing, polling at
// the normal cadence only fills the journal: Quickshell logs "Process failed to
// start" for a binary that is not there, every time. The slow cadence still
// notices an installation or a recovered daemon within a minute.
var IDLE_INTERVAL_MS = 60000

// Consecutive failures before the widget stops asking quickly.
var FAILURE_BACKOFF_AFTER = 3

// A healthy `mutagen sync list` never takes this long; a poll that does has lost
// its exit event or is stuck behind a wedged daemon, and is killed.
var POLL_TIMEOUT_MS = 10000

// Rows shown before the list scrolls.
var MAX_ROWS = 12

function listCommand() {
  return ["mutagen", "sync", "list", "--template", LIST_TEMPLATE]
}

// Asked before the first poll: invoking a binary that is not installed makes
// Quickshell log a warning on every attempt, and a missing mutagen is not an
// error to shout about — it is a fact to report once.
function presenceCommand() {
  return ["sh", "-c", "command -v mutagen >/dev/null 2>&1"]
}

function flushCommand(name) {
  return ["mutagen", "sync", "flush", name]
}

function emptyTotals() {
  return {
    total: 0,
    watching: 0,
    attention: 0,
    paused: 0,
    conflicts: 0,
    problems: 0,
    healthy: true
  }
}

function intOf(value) {
  var n = parseInt(value, 10)
  return isNaN(n) ? 0 : n
}

// "omarchy-setup--config-hypr" reads better as "config-hypr". A name without a
// separator is returned untouched, so the widget works for any naming scheme.
function shortName(name) {
  var at = String(name).lastIndexOf("--")
  return at > 0 ? String(name).substring(at + 2) : String(name)
}

function parseSessions(output) {
  var sessions = []
  var lines = String(output || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    var fields = lines[i].split("\t")
    if (fields.length < 6) continue

    // A dash is the template's marker for an endpoint that has not reported
    // in yet: it has no scan problems because it has no state at all.
    var alphaProblems = fields[3] === "-" ? -1 : intOf(fields[3])
    var betaProblems = fields[4] === "-" ? -1 : intOf(fields[4])
    var ended = alphaProblems < 0 || betaProblems < 0
    var paused = fields[5] === "true"
    var conflicts = intOf(fields[2])
    var watching = fields[1] === "Watching"

    sessions.push({
      name: fields[0],
      short: shortName(fields[0]),
      status: fields[1],
      paused: paused,
      conflicts: conflicts,
      problems: Math.max(alphaProblems, 0) + Math.max(betaProblems, 0),
      connected: !ended,
      // Healthy is what keeps the bar quiet: both endpoints present, session
      // watching, nothing paused, no conflicts. Scan problems are not part of
      // it — Mutagen refuses absolute symlinks by design, and a repository that
      // carries them in a file instead (Omarchy's setup does) would otherwise
      // wear a warning forever.
      healthy: !ended && watching && !paused && conflicts === 0
    })
  }

  // Sessions that want a look come first; the rest are alphabetical.
  sessions.sort(function (a, b) {
    if (a.healthy !== b.healthy) return a.healthy ? 1 : -1
    return a.short < b.short ? -1 : (a.short > b.short ? 1 : 0)
  })
  return sessions
}

function summarize(sessions) {
  var totals = emptyTotals()
  totals.total = sessions.length

  for (var i = 0; i < sessions.length; i++) {
    var session = sessions[i]
    if (session.status === "Watching") totals.watching++
    if (session.paused) totals.paused++
    totals.conflicts += session.conflicts
    totals.problems += session.problems
    if (!session.healthy) totals.attention++
  }

  totals.healthy = totals.attention === 0 && totals.conflicts === 0
  return totals
}

// Mutagen statuses are PascalCase machine names; the popup reads better with
// the words Omarchy panels use.
function statusLabel(session) {
  if (!session) return ""
  if (session.paused) return "paused"
  if (!session.connected) return "disconnected"

  var labels = {
    "Watching": "watching",
    "Scanning": "scanning",
    "Reconciling": "syncing",
    "StagingAlpha": "staging",
    "StagingBeta": "staging",
    "Transitioning": "transitioning",
    "ConnectingAlpha": "connecting",
    "ConnectingBeta": "connecting",
    "WaitingForRescan": "waiting",
    "HaltedOnRootEmptied": "halted",
    "HaltedOnRootDeletion": "halted",
    "HaltedOnRootTypeChange": "halted"
  }
  if (labels[session.status] !== undefined) return labels[session.status]
  if (session.status === "") return "idle"
  return String(session.status).toLowerCase()
}
