#!/usr/bin/env python3
"""Regenerate colab/code-server.ipynb from the scripts in this directory.

The notebook embeds every file as plain text, so it can be uploaded to Colab and
run with no clone, no Drive and no credentials — and the embedded copies stay
readable in the notebook itself. Because they are generated, edit the real
scripts and re-run this; never hand-edit the notebook.

    python3 colab/build-notebook.py
"""

import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "code-server.ipynb"

KIT = [
    "lib/common.sh",
    "install.sh",
    "serve.sh",
    "supervise.sh",
    "stop.sh",
    "doctor.sh",
    "README.md",
]


def md(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(True)}


def code(text):
    return {
        "cell_type": "code",
        "metadata": {},
        "execution_count": None,
        "outputs": [],
        "source": text.strip("\n").splitlines(True),
    }


def files_cell():
    """One Python cell holding every script verbatim, as raw triple-quoted text.

    Raw strings keep the bash backslashes literal, which is why `r'''` is used:
    the scripts contain things like tr '\0' ' ' and line continuations.
    """
    lines = [
        "import pathlib, stat",
        "",
        "# These are the real scripts, verbatim — the same files live in the repo at",
        "# colab/. Written to disk so they can be read, edited and re-run.",
        "FILES = {",
    ]
    for rel in KIT:
        text = (HERE / rel).read_text()
        if "'''" in text or text.rstrip("\n").endswith("\\"):
            raise SystemExit(f"{rel} cannot be embedded in a raw triple-quoted string")
        lines.append(f"    {rel!r}: r'''{text}''',")
    lines += [
        "}",
        "",
        '(BASE / "lib").mkdir(parents=True, exist_ok=True)',
        "for rel, text in FILES.items():",
        "    f = BASE / rel",
        "    f.write_text(text)",
        '    if f.suffix == ".sh":',
        "        f.chmod(f.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)",
        "",
        'print(f"wrote {len(FILES)} files to {BASE}")',
        "for rel in sorted(FILES):",
        '    print(f"   {rel:16s} {(BASE / rel).stat().st_size:6d} bytes")',
    ]
    return code("\n".join(lines))


CELLS = [
    md("""
# code-server on Colab — plug and play

**Runtime → Run all.** No clone, no Drive, no patches to code-server. The only
optional input is an ngrok token; without one it falls back to a Cloudflare quick
tunnel that needs no account.

Nothing here renames processes or spoofs traffic — that layer is not what Colab
enforces on. See `README.md` (written to disk by cell 4) for the layer-by-layer
breakdown. What this does fix: rotating URLs, blank pages, and VMs left idle.

Colab's FAQ does not list remote-IDE use as supported. It works; the runtime is
ephemeral and account-level throttling is always possible.
"""),
    md("""
## Flow, and where the logs are

```
install.sh                     (cell 5, slow: 1–3 min first run)
  apt-get runtime libs  →  code-server tarball  →  ngrok  →  cloudflared

supervise.sh                   (cell 6, returns immediately)
  └─ serve.sh                  (cell 7 watches this live)
       clear stale pidfiles
       port check
       code-server start  →  poll /healthz           (5–90 s)
       tunnel start       →  poll for public URL     (10–60 s)
       write credentials.txt  →  print URL + password
  └─ then: restart on crash, stop when idle
```

Every stage appends to one log:

| File | Contents |
|---|---|
| `/content/.code-server/supervise.out` | **the progress log** — one line per stage |
| `/content/.code-server/code-server.log` | editor server; startup failures land here |
| `/content/.code-server/cloudflared.log` | tunnel registration and the public URL |
| `/content/.code-server/ngrok.log` | JSON; errors like `ERR_NGROK_4018` |
| `/content/.code-server/credentials.txt` | final `url=` / `password=` |

If cell 7 seems stuck, read `supervise.out`: the last line names the stage.
"""),
    md("## 1. Environment"),
    code("""
import os, sys, platform, pathlib, shutil

IN_COLAB = "google.colab" in sys.modules or pathlib.Path("/content").is_dir()
BASE = pathlib.Path("/content/colab-cs")

print("colab      :", IN_COLAB)
print("platform   :", platform.platform())
print("machine    :", platform.machine())
print("python     :", platform.python_version())
try:
    print("free disk  :", shutil.disk_usage("/content").free // 2**30, "GiB")
except OSError:
    pass
print("install to :", BASE)
"""),
    md("""
## 2. Configuration

Every value is optional. `TUNNEL` stays `auto` unless you force one:

* `auto` — ngrok if it has credentials, else cloudflared (no account needed)
* `ngrok` — needs `NGROK_TOKEN` (or a Colab Secret of that name); fastest
* `cloudflared` — no account, slightly slower to register, URL changes per run
* `none` — loopback only, for debugging

And the rest of the knobs, all with working defaults:

| Variable | Default | Notes |
|---|---|---|
| `CS_PORT` | auto | first free of `8080`/`8090`/`8443`/`9000`/`13337`. Pin one, e.g. `"9090"`. 8080 is not safe on Colab, where `datalab/web/app.js` sometimes owns it |
| `NGROK_DOMAIN` | — | reserved ngrok domain, so the URL survives restarts |
| `NGROK_AUTH` | — | `user:pass` gate at ngrok's edge, rejects scanners |
| `IDLE_TIMEOUT` | `1800` | shut down after this many seconds with no connections |
| `MAX_RUNTIME` | `39600` | hard stop at 11 h |
| `STATE_ON_DRIVE` | `False` | keep extensions and settings between runtimes |

The resolved port is recorded in `$CS_STATE_DIR/port`, so `stop.sh`, the idle
watchdog and `doctor.sh` always operate on the port actually in use.
"""),
    code("""
import os

# ── edit here if you want ─────────────────────────────────────────────────────
NGROK_TOKEN    = ""        # or add a Colab Secret named NGROK_TOKEN
TUNNEL         = ""        # "" = auto | "ngrok" | "cloudflared" | "none"
NGROK_DOMAIN   = ""        # reserved domain => stable URL, e.g. "me.ngrok-free.app"
CS_PORT        = ""        # "" = auto (first free port), or pin one, e.g. 9090
NGROK_AUTH     = ""        # optional edge gate "user:pass" (rejects scanners)
IDLE_TIMEOUT   = 1800      # seconds with zero connections before shutdown
MAX_RUNTIME    = 39600     # seconds before forced shutdown (11 h)
STATE_ON_DRIVE = False     # keep extensions and settings between runtimes
CS_EXTENSIONS  = ""        # comma-separated IDs, installed once
# ─────────────────────────────────────────────────────────────────────────────

token = NGROK_TOKEN.strip()
token_source = "config cell" if token else ""
if not token:
    try:
        from google.colab import userdata
        token = (userdata.get("NGROK_TOKEN") or "").strip()
        token_source = "Colab secret" if token else ""
    except Exception:
        pass

os.environ["NGROK_TOKEN"] = token
os.environ["CS_TUNNEL"] = TUNNEL
os.environ["CS_PORT"] = str(CS_PORT)
os.environ["CS_IDLE_TIMEOUT"] = str(IDLE_TIMEOUT)
os.environ["CS_MAX_RUNTIME"] = str(MAX_RUNTIME)
if NGROK_DOMAIN: os.environ["NGROK_DOMAIN"] = NGROK_DOMAIN
if NGROK_AUTH:   os.environ["NGROK_BASIC_AUTH"] = NGROK_AUTH
if CS_EXTENSIONS: os.environ["CS_EXTENSIONS"] = CS_EXTENSIONS

if STATE_ON_DRIVE:
    from google.colab import drive
    drive.mount("/content/drive")
    os.environ["CS_STATE_DIR"] = "/content/drive/MyDrive/.code-server"
    os.environ["CS_CACHE_DIR"] = "/content/drive/MyDrive/.code-server/cache"

print("tunnel      :", TUNNEL or "auto")
print("port        :", CS_PORT or "auto")
print("ngrok token :", f"yes ({token_source})" if token else "no -> cloudflared fallback")
print("state dir   :", os.environ.get("CS_STATE_DIR", "/content/.code-server"))
"""),
    md("""
## 3. Write the toolkit

The scripts are embedded in the next cell **as plain text**, so you can read and
review exactly what will run — no encoded blobs. The cell just writes them to
`/content/colab-cs` and sets the executable bit; it downloads nothing and
executes nothing.

Prefer the repo? Skip this cell and point `BASE` at a clone:

```bash
git clone --depth 1 https://github.com/recursive-factory/code-server.git /content/cs
```

```python
BASE = pathlib.Path("/content/cs/colab")
```
"""),
    files_cell(),
    md("""
## 4. Install

Slow on purpose — this is where the 1–3 minutes go on a fresh runtime:
`apt-get` for the VS Code web client libraries, then the code-server tarball
(~100 MB), then both tunnel agents. Output streams live.

Re-running it is cheap: the tarball is cached in `CS_CACHE_DIR`, and apt is
skipped when the version already matches.
"""),
    code("""
import os, subprocess

env = dict(os.environ, WITH_CLOUDFLARED="1")  # cloudflared is the no-account fallback
subprocess.run(["bash", str(BASE / "install.sh")], check=True, env=env)
"""),
    md("""
## 5. Start

Returns in about two seconds — the supervisor runs detached, so this cell does
not block and you are free to run the next one immediately.
"""),
    code("""
import os, signal, time, pathlib, subprocess

STATE = pathlib.Path(os.environ.get("CS_STATE_DIR", "/content/.code-server"))
STATE.mkdir(parents=True, exist_ok=True)

# Re-running must restart cleanly: retire the previous supervisor (it holds a
# lock), then let stop.sh release the port.
pid_file = STATE / "supervise.pid"
if pid_file.exists():
    try:
        pid = int(pid_file.read_text().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        print("stopped previous supervisor", pid)
        for _ in range(20):
            time.sleep(0.5)
            os.kill(pid, 0)
    except (ValueError, ProcessLookupError, PermissionError):
        pass
    pid_file.unlink(missing_ok=True)
subprocess.run(["bash", str(BASE / "stop.sh")], check=False,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

creds = STATE / "credentials.txt"
creds.unlink(missing_ok=True)          # only accept a fresh write

log_path = STATE / "supervise.out"
fh = open(log_path, "w")
proc = subprocess.Popen(
    ["bash", str(BASE / "supervise.sh")],
    stdout=fh, stderr=subprocess.STDOUT,
    start_new_session=True,            # own process group, so stop can kill it cleanly
)
pid_file.write_text(str(proc.pid))

print(f"supervisor started (pid {proc.pid}), detached")
print(f"progress log : {log_path}")
print("next         : run the cell below for live progress and the URL")
"""),
    md("""
## 6. Wait for the URL (live progress)

Streams the tail of `supervise.out` while the tunnel comes up, so a slow start is
visible instead of looking hung. Typical first run: health ~10 s, then 10–60 s
for the tunnel depending on provider.
"""),
    code("""
import os, time, pathlib
from IPython.display import display, clear_output, HTML

STATE = pathlib.Path(os.environ.get("CS_STATE_DIR", "/content/.code-server"))
creds = STATE / "credentials.txt"
log_path = STATE / "supervise.out"
pid_file = STATE / "supervise.pid"

BUDGET = 300
url = pw = None
reason = "timed out"

for elapsed in range(BUDGET):
    info = {}
    if creds.exists():
        raw = creds.read_text().strip()
        if "url=" in raw:
            info = dict(l.split("=", 1) for l in raw.splitlines() if "=" in l)
            if info.get("url"):
                url, pw, reason = info["url"], info.get("password"), "ok"
                break

    tail = ""
    if log_path.exists():
        tail = "\\n".join(log_path.read_text().splitlines()[-10:])

    alive = True
    if pid_file.exists():
        try:
            os.kill(int(pid_file.read_text().strip()), 0)
        except (ValueError, ProcessLookupError, PermissionError):
            alive = False

    clear_output(wait=True)
    if not alive and not url:
        reason = "supervisor exited"
        break
    print(f"waiting {elapsed}s …  (log: {log_path})")
    print("─" * 60)
    print(tail or "(no output yet)")

    time.sleep(1)

clear_output(wait=True)
if url:
    display(HTML(
        f'<p style="font-size:17px;margin:8px 0"><b>code-server</b> &nbsp;'
        f'<a href="{url}" target="_blank">{url}</a></p>'
        f'<p style="margin:4px 0"><b>password</b> &nbsp;'
        f'<code style="font-size:15px">{pw}</code></p>'
    ))
    print(f"tunnel : {info.get('tunnel')}")
    print(f"state  : {STATE}")
    if info.get("tunnel") == "ngrok":
        print()
        print("ngrok free tier: click through the warning page before the editor loads.")
else:
    print(f"no URL yet ({reason}). Full progress log:\\n")
    print(log_path.read_text() if log_path.exists() else "(no log)")
    print("\\nNext: cell 8 (Status) for diagnostics, or cell 9 (Stop) then cell 6 again.")
"""),
    md("## 7. Status"),
    code("""
import pathlib
STATE = pathlib.Path(os.environ.get("CS_STATE_DIR", "/content/.code-server"))
supervise_log = STATE / "supervise.out"

if supervise_log.exists():
    print("── supervisor ─────────────────────────────────────────────")
    print("\\n".join(supervise_log.read_text().splitlines()[-12:]))
    print()

!bash "{BASE}/doctor.sh"
"""),
    md("## 8. Stop"),
    code("""
import os, pathlib, signal

STATE = pathlib.Path(os.environ.get("CS_STATE_DIR", "/content/.code-server"))
pid_file = STATE / "supervise.pid"
if pid_file.exists():
    try:
        pid = int(pid_file.read_text().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)   # supervisor was started detached
        print("stopped supervisor", pid)
    except (ValueError, ProcessLookupError, PermissionError):
        pass
    pid_file.unlink(missing_ok=True)

!bash "{BASE}/stop.sh"
"""),
    md("""
## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| cell 7 sits on "waiting for cloudflared URL" | Cloudflare quick-tunnel registration is slow or rate-limited; set `NGROK_TOKEN` for the faster path |
| stuck at `waiting for http://127.0.0.1:8080/healthz` | startup crash — read `code-server.log` |
| `port 8080 in use` | orphaned process: cell 9, then cell 6 |
| blank page after opening the URL | ngrok interstitial not clicked through, or set `TUNNEL = "cloudflared"` |
| URL 404s / changes | free ngrok rotates hostnames; set `NGROK_DOMAIN`, or use a named cloudflared tunnel |
| extensions missing | `rm -rf /content/.code-server/.extensions-*`, restart |

Useful from a shell cell:

```bash
tail -n 60 /content/.code-server/supervise.out
tail -n 60 /content/.code-server/code-server.log
bash /content/colab-cs/doctor.sh
```

The readable sources live in the repo at `colab/`; this notebook is generated
from them by `colab/build-notebook.py`, so prefer editing there.
"""),
]


def main():
    nb = {
        "cells": CELLS,
        "metadata": {
            "colab": {"provenance": [], "toc_visible": True, "name": "code-server.ipynb"},
            "kernelspec": {"display_name": "Python 3", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 0,
    }
    OUT.write_text(json.dumps(nb, indent=1) + "\n")
    print(f"wrote {OUT} ({len(CELLS)} cells, {OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
