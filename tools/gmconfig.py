#!/usr/bin/env python3
"""gmconfig.py — set up a Great Migration digitization appointment.

Replaces the legacy `gmconfig` (Pashua-based, no longer functional) and
`makegm` (bash, tightly coupled to gmconfig) pair. Captures session details
via an HTML form in the browser (or CLI fallback), writes session.json
inside the new session directory, and creates the per-format
ACCESS/PRESERVATION/notes structure.

Modes:
    gmconfig.py                          open form, save config, create dirs
    gmconfig.py --config-only            open form, save config, skip dirs
    gmconfig.py --from-config PATH       skip form, read session.json, create dirs
    gmconfig.py --cli                    terminal prompts fallback (no browser)
"""
from __future__ import annotations

import argparse
import http.server
import json
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap  # noqa: E402

log = get_logger()


# --- Constants -----------------------------------------------------------------

SCHEMA_VERSION = 1
ET = ZoneInfo("America/New_York")


@dataclass(frozen=True)
class Format:
    """One archival format the team digitizes. The legacy makegm script defined
    these inline; we keep the same folder names and notes-file slugs for output
    compatibility with anything that already references the old structure."""
    id: str            # canonical identifier (stable across versions)
    label: str         # human-readable name shown in the form
    folder: str        # subdirectory created under the session dir
    slug: str          # used in the notes filename (folder != slug for V8 only)
    media_type: str    # "film" or "tape" — drives template verb choice
    description: str   # used in the notes-file template (e.g. "35mm films")


FORMATS: list[Format] = [
    Format("35mm",                       "35mm",                                  "35mm",                "35mm",                "film", "35mm films"),
    Format("16mm",                       "16mm",                                  "16mm",                "16mm",                "film", "16mm films"),
    Format("R8",                         "Regular 8mm (R8)",                      "Regular8mm",          "Regular8mm",          "film", "Regular 8mm films"),
    Format("S8",                         "Super 8 (S8)",                          "Super8",              "Super8",              "film", "Super 8 films"),
    Format("VHS",                        "VHS",                                   "VHS",                 "VHS",                 "tape", "VHS tapes"),
    Format("MiniDV",                     "MiniDV",                                "MiniDV",              "MiniDV",              "tape", "MiniDV tapes"),
    Format("V8",                         "Video8 (V8)",                           "Video8",              "V8",                  "tape", "Video8 tapes"),
    Format("Hi8",                        "Hi8",                                   "Hi8",                 "Hi8",                 "tape", "Hi8 tapes"),
    Format("D8",                         "Digital8 (D8)",                         "Digital8",            "Digital8",            "tape", "Digital8 tapes"),
    Format("U-matic",                    "U-matic",                               "Umatic",              "Umatic",              "tape", "U-matic tapes"),
    Format("Betacam",                    "Betacam (Beta)",                        "Betacam",             "Betacam",             "tape", "Betacam tapes"),
    Format("BetacamSP",                  "BetacamSP (BetaSP)",                    "BetacamSP",           "BetacamSP",           "tape", "BetacamSP tapes"),
    Format("DigiBeta",                   "Digital Betacam (DigiBeta)",            "DigiBeta",            "DigiBeta",            "tape", "Digital Betacam tapes"),
    Format("OneInchVideo",               '1" Video (TypeC)',                      "OneInchVideo",        "OneInchVideo",        "tape", "1-inch Video tapes"),
    Format("HalfInchVideo",              '1/2" Open-Reel Video (EIAJ)',           "HalfInchVideo",       "HalfInchVideo",       "tape", "1/2-inch Video tapes"),
    Format("CompactAudioCassette",       "Compact Audio Cassette (CAC)",          "AudioCassette",       "AudioCassette",       "tape", "Compact Audio Cassette tapes"),
    Format("QuarterInchOpenReelAudio",   '1/4" Reel-To-Reel Audio (QinA)',        "QuarterInchOpenReel", "QuarterInchOpenReel", "tape", "1/4-inch open reel tapes"),
]

FORMATS_BY_ID: dict[str, Format] = {f.id: f for f in FORMATS}

# Notes templates — match the wording of the legacy makegm script so the
# resulting text is the same as what the team was producing before.
GENERAL_NOTES_TEMPLATE = (
    "These are general notes concerning the appointment of {first} {last} on {date}. "
    "They were written by the TBM preservationist, {operator}, and contain observations about the "
    "appointment and information relayed by {first} {last}.\n"
)

FORMAT_NOTES_TEMPLATE = (
    "These are notes concerning the {description} of {first} {last} which were "
    "{verb_past} on {date} by the TBM preservationist {operator}. They cover technical and "
    "preservation concerns of the {medium}, noted by the TBM preservationist at the time of "
    "initial inspection and {verb_noun}, not content of the {medium}.\n"
)

VERB_PAST = {"film": "scanned", "tape": "digitized"}
VERB_NOUN = {"film": "scanning", "tape": "digitization"}
MEDIUM    = {"film": "films",   "tape": "tapes"}


# --- Session data + filesystem actions -----------------------------------------

def now_local_iso() -> str:
    """ISO-8601 timestamp in the local (ET) zone with offset."""
    return datetime.now(ET).isoformat(timespec="seconds")


def date_iso() -> str:
    """YYYYMMDD — matches the legacy DATE_ISO from makegm."""
    return datetime.now(ET).strftime("%Y%m%d")


def date_hyphen() -> str:
    """YYYY-MM-DD — matches the legacy DATE_HYPHEN from makegm."""
    return datetime.now(ET).strftime("%Y-%m-%d")


def session_dir_name(last: str, first: str) -> str:
    """Folder name for a session, e.g. '20260513_Smith_Jane'."""
    return f"{date_iso()}_{last}_{first}"


def build_session(form: dict) -> dict:
    """Assemble the session.json structure from form data."""
    gm_dir = Path(form["gm_dir"]).expanduser().resolve()
    sub = session_dir_name(form["last"], form["first"])
    session_dir = gm_dir / sub
    selected = [FORMATS_BY_ID[fid] for fid in form["formats"]]
    return {
        "schema_version": SCHEMA_VERSION,
        "created": now_local_iso(),
        "operator": form["operator"],
        "profile": {
            "first": form["first"],
            "last": form["last"],
        },
        "study_collection_number": form["study_collection_number"],
        "inventory_number": form.get("inventory_number", ""),
        "formats": [{"id": f.id, "folder": f.folder} for f in selected],
        "gm_dir": str(gm_dir),
        "session_dir": str(session_dir),
    }


def write_session_json(session: dict) -> Path:
    """Write session.json inside the session dir. Creates session dir if missing."""
    session_dir = Path(session["session_dir"])
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / "session.json"
    path.write_text(json.dumps(session, indent=2) + "\n")
    return path


def create_session_dirs(session: dict) -> list[Path]:
    """Create per-format ACCESS/PRESERVATION subdirs + notes files.
    Returns list of paths that were created (for terminal reporting)."""
    session_dir = Path(session["session_dir"])
    profile = session["profile"]
    first, last = profile["first"], profile["last"]
    operator = session["operator"]
    d_hyphen = date_hyphen()
    d_iso = date_iso()
    created: list[Path] = []

    # General notes file for the whole appointment.
    general_notes = session_dir / f"{d_iso}_{last}_{first}_generalNotes.txt"
    if not general_notes.exists():
        general_notes.write_text(GENERAL_NOTES_TEMPLATE.format(
            first=first, last=last, date=d_hyphen, operator=operator,
        ))
        created.append(general_notes)

    # Per-format subdirectories + notes.
    for f_entry in session["formats"]:
        fmt = FORMATS_BY_ID[f_entry["id"]]
        fdir = session_dir / fmt.folder
        access = fdir / "ACCESS"
        preservation = fdir / "PRESERVATION"
        for d in (access, preservation):
            if not d.exists():
                d.mkdir(parents=True)
                created.append(d)
        notes = fdir / f"{d_iso}_{last}_{first}_{fmt.slug}_Notes.txt"
        if not notes.exists():
            notes.write_text(FORMAT_NOTES_TEMPLATE.format(
                description=fmt.description,
                first=first, last=last,
                verb_past=VERB_PAST[fmt.media_type],
                verb_noun=VERB_NOUN[fmt.media_type],
                date=d_hyphen,
                operator=operator,
                medium=MEDIUM[fmt.media_type],
            ))
            created.append(notes)
    return created


# --- Validation ----------------------------------------------------------------

def validate(form: dict) -> list[str]:
    """Return a list of error messages; empty list means form is valid."""
    errors: list[str] = []
    for required in ("first", "last", "operator", "study_collection_number", "gm_dir"):
        if not form.get(required, "").strip():
            errors.append(f"{required} is required.")
    fmts = form.get("formats", [])
    if not fmts:
        errors.append("At least one format must be selected.")
    else:
        unknown = [fid for fid in fmts if fid not in FORMATS_BY_ID]
        if unknown:
            errors.append(f"Unknown format ids: {', '.join(unknown)}")
    gd = form.get("gm_dir", "").strip()
    if gd:
        p = Path(gd).expanduser()
        if not p.exists():
            errors.append(f"GM_DIR does not exist: {p}")
        elif not p.is_dir():
            errors.append(f"GM_DIR is not a directory: {p}")
    return errors


# --- HTML form -----------------------------------------------------------------

# CSS + form HTML. Doubled braces escape Python's str.format substitution.
FORM_HTML = """\
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Great Migration appointment setup</title>
<style>
:root {{
  --fg: #222; --muted: #666; --bg: #fafafa; --card: #fff;
  --border: #ccc; --accent: #2466b8; --err: #c0392b; --errbg: #fdecea;
}}
body {{
  font-family: -apple-system, system-ui, "Helvetica Neue", sans-serif;
  color: var(--fg); background: var(--bg);
  max-width: 760px; margin: 2em auto; padding: 0 1em; line-height: 1.4;
}}
h1 {{ margin-top: 0; }}
fieldset {{
  margin: 1em 0; padding: 1em 1.2em; border: 1px solid var(--border);
  border-radius: 6px; background: var(--card);
}}
legend {{ font-weight: bold; padding: 0 0.5em; color: var(--accent); }}
label {{ display: block; margin: 0.6em 0; }}
label > span {{ display: block; margin-bottom: 0.2em; }}
input[type=text] {{
  width: 100%; padding: 0.45em 0.6em; border: 1px solid var(--border);
  border-radius: 4px; box-sizing: border-box; font: inherit;
}}
.row {{ display: flex; gap: 0.6em; align-items: stretch; }}
.row > input {{ flex: 1; }}
.row > button {{ flex: 0 0 auto; }}
.formats {{ display: grid; grid-template-columns: 1fr 1fr; gap: 0.4em 1.2em; }}
.formats label {{ display: flex; align-items: center; gap: 0.5em; margin: 0; cursor: pointer; }}
.helptext {{ color: var(--muted); font-size: 0.88em; margin-top: 0.3em; }}
.errors {{
  background: var(--errbg); border: 1px solid var(--err);
  color: var(--err); padding: 0.6em 0.9em; border-radius: 4px;
  margin-bottom: 1em;
}}
.errors ul {{ margin: 0.3em 0 0 1.2em; }}
button {{
  padding: 0.6em 1.4em; font-size: 1em; border-radius: 4px; border: 0;
  cursor: pointer; background: var(--accent); color: white;
}}
button.browse {{ padding: 0.45em 0.9em; background: #eee; color: var(--fg); border: 1px solid var(--border); }}
button:hover {{ opacity: 0.9; }}
.namecheck {{ font-family: ui-monospace, monospace; color: var(--muted); font-size: 0.88em; margin-top: 0.3em; }}
</style>
</head>
<body>
<h1>Great Migration appointment</h1>
<p>Fill out the fields below to set up a new digitization session. A new directory
will be created under your selected output location, named after today's date and the
profile's last and first names.</p>

{errors_html}

<form method="POST" action="/submit">

  <fieldset>
    <legend>Appointment</legend>
    <label><span>Last name of Great Migration appointment *</span><input type="text" name="last" value="{last}" required></label>
    <label><span>First name of Great Migration appointment *</span><input type="text" name="first" value="{first}" required></label>
    <label><span>Name of the TBM preservationist running the appointment *</span><input type="text" name="operator" value="{operator}" required></label>
    <label>
      <span>Study collection number *</span>
      <input type="text" name="study_collection_number" value="{scn}" placeholder="SC.0001" required>
      <div class="helptext">Format like <code>SC.0001</code>. The dot is converted to an underscore in filenames (e.g. <code>SC_0001</code>).</div>
    </label>
    <label>
      <span>Inventory number</span>
      <input type="text" name="inventory_number" value="{inv}" placeholder="optional">
      <div class="helptext">Optional. Leave blank if not applicable; downstream tools will skip it.</div>
    </label>
  </fieldset>

  <fieldset>
    <legend>Output directory</legend>
    <label>
      <span>Great Migration root directory *</span>
      <div class="row">
        <input type="text" name="gm_dir" id="gm_dir" value="{gm_dir}" required placeholder="/Volumes/...">
        <button type="button" class="browse" onclick="browseDir()">Browse…</button>
      </div>
      <div class="helptext">A subdirectory <code>{today}_LastName_FirstName/</code> will be created here.</div>
    </label>
  </fieldset>

  <fieldset>
    <legend>Formats to digitize this session *</legend>
    <div class="formats">
      {format_checkboxes}
    </div>
    <div class="helptext">Each selected format gets an <code>ACCESS/</code> + <code>PRESERVATION/</code>
    pair and a pre-filled <code>&lt;format&gt;_Notes.txt</code> for the operator.</div>
  </fieldset>

  <button type="submit">Create session</button>
</form>

<script>
async function browseDir() {{
  try {{
    const r = await fetch('/pick_dir');
    if (!r.ok) throw new Error('server returned ' + r.status);
    const j = await r.json();
    if (j.path) document.getElementById('gm_dir').value = j.path;
  }} catch (e) {{
    alert('Browse failed: ' + e + '\\nType or paste the directory path instead.');
  }}
}}
</script>

</body>
</html>
"""


SUCCESS_HTML = """\
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Session created</title>
<style>
body {{ font-family: -apple-system, system-ui, sans-serif; max-width: 760px;
       margin: 2em auto; padding: 0 1em; }}
.ok {{ background: #e7f6ec; border: 1px solid #2e8b57; padding: 1em;
      border-radius: 6px; color: #1d5a37; }}
code {{ font-family: ui-monospace, monospace; background: #f3f3f3; padding: 1px 4px;
       border-radius: 3px; }}
pre {{ background: #f3f3f3; padding: 1em; border-radius: 4px; overflow-x: auto; }}
</style>
</head>
<body>
<div class="ok">
<h1>Session created</h1>
<p>Created session for <strong>{first} {last}</strong> at:</p>
<p><code>{session_dir}</code></p>
<p>You can close this tab and return to the terminal.</p>
</div>
<h3>session.json:</h3>
<pre>{session_json}</pre>
</body>
</html>
"""


def render_form(defaults: dict, errors: list[str] | None = None) -> str:
    """Render the HTML form, optionally with errors shown above it."""
    errors_html = ""
    if errors:
        items = "".join(f"<li>{e}</li>" for e in errors)
        errors_html = f'<div class="errors"><strong>Please fix:</strong><ul>{items}</ul></div>'

    selected = set(defaults.get("formats", []))
    checkboxes = []
    for f in FORMATS:
        checked = " checked" if f.id in selected else ""
        checkboxes.append(
            f'<label><input type="checkbox" name="fmt_{f.id}" value="1"{checked}>'
            f'<span>{f.label}</span></label>'
        )
    format_checkboxes = "\n".join(checkboxes)

    return FORM_HTML.format(
        errors_html=errors_html,
        last=defaults.get("last", ""),
        first=defaults.get("first", ""),
        operator=defaults.get("operator", ""),
        scn=defaults.get("study_collection_number", ""),
        inv=defaults.get("inventory_number", ""),
        gm_dir=defaults.get("gm_dir", ""),
        today=date_iso(),
        format_checkboxes=format_checkboxes,
    )


def render_success(session: dict) -> str:
    return SUCCESS_HTML.format(
        first=session["profile"]["first"],
        last=session["profile"]["last"],
        session_dir=session["session_dir"],
        session_json=json.dumps(session, indent=2),
    )


# --- HTTP server ---------------------------------------------------------------

class _FormHandler(http.server.BaseHTTPRequestHandler):
    """Serves the form, handles directory-picker bridge, captures submission."""

    # Class-level shared state — set by run_form_server() before serving.
    submitted_session: dict | None = None
    submission_event: threading.Event | None = None

    def log_message(self, format, *args):  # noqa: A002 — match BaseHTTPRequestHandler signature
        # Quiet — don't spam stderr with one line per request.
        pass

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 — http.server naming
        if self.path == "/" or self.path.startswith("/?"):
            html = render_form(defaults={})
            self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))
        elif self.path == "/pick_dir":
            self._handle_pick_dir()
        else:
            self._send(404, "text/plain", b"not found\n")

    def do_POST(self):  # noqa: N802
        if self.path != "/submit":
            self._send(404, "text/plain", b"not found\n")
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        raw = urllib.parse.parse_qs(body, keep_blank_values=True)
        form = {
            "first": raw.get("first", [""])[0].strip(),
            "last": raw.get("last", [""])[0].strip(),
            "operator": raw.get("operator", [""])[0].strip(),
            "study_collection_number": raw.get("study_collection_number", [""])[0].strip(),
            "inventory_number": raw.get("inventory_number", [""])[0].strip(),
            "gm_dir": raw.get("gm_dir", [""])[0].strip(),
            "formats": [f.id for f in FORMATS if f"fmt_{f.id}" in raw],
        }
        errors = validate(form)
        if errors:
            html = render_form(defaults=form, errors=errors)
            self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))
            return

        session = build_session(form)
        # Send success page first so the browser can show it before we tear down.
        html = render_success(session)
        self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))

        # Hand the validated session back to the main thread and signal it.
        _FormHandler.submitted_session = session
        if _FormHandler.submission_event is not None:
            _FormHandler.submission_event.set()

    def _handle_pick_dir(self):
        """Bridge to a native macOS folder-picker via osascript."""
        cmd = ["osascript", "-e",
               'POSIX path of (choose folder with prompt "Select Great Migration directory:")']
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            self._send(500, "application/json",
                       json.dumps({"error": str(e)}).encode("utf-8"))
            return
        if result.returncode != 0:
            # User cancelled the dialog — return empty path, no error.
            self._send(200, "application/json",
                       json.dumps({"path": ""}).encode("utf-8"))
            return
        path = result.stdout.strip().rstrip("/")
        self._send(200, "application/json",
                   json.dumps({"path": path}).encode("utf-8"))


def run_form_server() -> dict:
    """Start the form server, open a browser, block until the form is submitted.
    Returns the validated session dict."""
    _FormHandler.submitted_session = None
    _FormHandler.submission_event = threading.Event()
    server = http.server.HTTPServer(("127.0.0.1", 0), _FormHandler)
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info(f"Form open at {url}")
    webbrowser.open(url)
    try:
        _FormHandler.submission_event.wait()
    except KeyboardInterrupt:
        log.warning("Cancelled — no session created.")
        server.shutdown()
        sys.exit(130)
    # Give the browser a moment to finish receiving the success page.
    time.sleep(0.5)
    server.shutdown()
    return _FormHandler.submitted_session  # type: ignore[return-value]


# --- CLI fallback --------------------------------------------------------------

def _ask(prompt: str, *, default: str = "", required: bool = False) -> str:
    """Prompt with optional default + required-enforcement."""
    while True:
        suffix = f" [{default}]" if default else ""
        val = input(f"{prompt}{suffix}: ").strip()
        if not val and default:
            return default
        if not val and required:
            log.error("This field is required.")
            continue
        return val


def _ask_yn(prompt: str, *, default: bool = False) -> bool:
    d = "Y/n" if default else "y/N"
    while True:
        v = input(f"{prompt} [{d}]: ").strip().lower()
        if not v:
            return default
        if v in ("y", "yes"):
            return True
        if v in ("n", "no"):
            return False
        print("Please answer y or n.")


def run_cli_form() -> dict:
    """Terminal walkthrough of the same form."""
    print("\nGreat Migration appointment setup\n" + "=" * 35 + "\n")
    last = _ask("Last name of Great Migration appointment", required=True)
    first = _ask("First name of Great Migration appointment", required=True)
    operator = _ask("Name of the TBM preservationist running the appointment", required=True)
    scn = _ask("Study collection number (e.g. SC.0001)", required=True)
    inv = _ask("Inventory number (optional, blank to skip)")
    gm_dir = _ask("Great Migration root directory path", required=True)

    print("\nFormats to digitize this session (mark each y/N):")
    selected: list[str] = []
    for f in FORMATS:
        if _ask_yn(f"  {f.label}", default=False):
            selected.append(f.id)
    if not selected:
        log.error("At least one format must be selected. Restart and try again.")
        sys.exit(2)

    form = {
        "first": first, "last": last, "operator": operator,
        "study_collection_number": scn, "inventory_number": inv,
        "gm_dir": gm_dir, "formats": selected,
    }
    errors = validate(form)
    if errors:
        log.error("Form has errors:")
        for e in errors:
            log.error(f"  - {e}")
        sys.exit(2)
    return build_session(form)


# --- Top-level actions ---------------------------------------------------------

def do_session_creation(session: dict, *, create_dirs: bool) -> int:
    """Write session.json (always); create per-format dirs (if requested).
    Logs what was done; returns 0 on success."""
    session_dir = Path(session["session_dir"])
    if session_dir.exists() and any(session_dir.iterdir()):
        log.warning(f"Session dir already exists with content: {session_dir}")

    json_path = write_session_json(session)
    log.info(f"Wrote {json_path}")

    if create_dirs:
        created = create_session_dirs(session)
        for c in created:
            log.info(f"Created {c}")
        log.info(f"Done. Session ready at {session_dir}")
    else:
        log.info(f"Skipped dir creation (--config-only). Session.json at {json_path}")
    return 0


def load_session(path: Path) -> dict:
    """Load and minimally validate an existing session.json."""
    if not path.exists():
        log.error(f"Config not found: {path}")
        sys.exit(2)
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        log.error(f"Could not parse {path}: {e}")
        sys.exit(2)
    if data.get("schema_version") != SCHEMA_VERSION:
        log.warning(f"Schema version mismatch in {path} "
                    f"(file={data.get('schema_version')}, code={SCHEMA_VERSION})")
    # Sanity check the required keys.
    for k in ("operator", "profile", "formats", "session_dir"):
        if k not in data:
            log.error(f"Missing key in session.json: {k}")
            sys.exit(2)
    return data


# --- main ----------------------------------------------------------------------

def main() -> int:
    install_sigterm_trap()
    p = argparse.ArgumentParser(
        prog="gmconfig.py",
        description="Set up a Great Migration digitization appointment.",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--config-only", action="store_true",
                      help="Open form, save session.json, but don't create the directory structure.")
    mode.add_argument("--from-config", type=Path, metavar="PATH",
                      help="Skip the form. Read an existing session.json and create its dirs.")
    mode.add_argument("--cli", action="store_true",
                      help="Use terminal prompts instead of the browser form.")
    args = p.parse_args()

    if args.from_config:
        session = load_session(args.from_config)
        return do_session_creation(session, create_dirs=True)

    if args.cli:
        session = run_cli_form()
    else:
        session = run_form_server()

    return do_session_creation(session, create_dirs=not args.config_only)


if __name__ == "__main__":
    sys.exit(main())
