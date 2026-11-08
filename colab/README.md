# code-server on Google Colab

Runs code-server in a Colab VM and exposes it over a tunnel.

**No patches to code-server.** It is a plain Node HTTP server; nothing in `src/`
or `patches/` needs to change. These scripts only pick flags appropriate to an
ephemeral Colab VM, install the runtime libraries, and manage the tunnel.

```
colab/
├── install.sh       # libraries + code-server tarball (cached) + tunnel agent
├── serve.sh         # start code-server, wait for health, open tunnel, report
├── supervise.sh     # restart with backoff + idle / max-runtime watchdog
├── stop.sh          # stop everything
├── doctor.sh        # read-only diagnostics
├── lib/common.sh    # shared helpers (logging, locks, pidfiles, probes)
└── code-server-min.ipynb    # 14 cells, ~110 lines: fetches the scripts
```

## What a "trace" actually is, and what a wrapper can do about it

Worth reading before asking for process renaming, because the layers are not
equally reachable:

| Layer | Observed by | Changeable by a wrapper? |
|---|---|---|
| `/proc/<pid>/cmdline`, process name | anything inside the VM | yes, trivially — and it does not matter: Colab's enforcement is not a per-process scanner. code-server's own children (`node`, extension hosts, every terminal you open) keep the real names, so a renamed parent is *inconsistent*, which is a worse signal than an honest one. |
| filesystem writes | the VM itself | yes, pointless — the disk is wiped per runtime |
| egress SNI / hostname (`*.shares.zrok.io`, `*.trycloudflare.com`) | the network path | only by using your own domain on a named tunnel. That is not disguise, it is hosting. |
| tunnel-side HTTP/WS shape (`/websocket`, asset paths) | the tunnel provider's edge, not Google | no reason to care |
| runtime behaviour: idle GPU VM, session length, zero executed cells, memory/CPU profile | Google, account level | **no** — and this is the layer that gets actioned |
| account / session count / IP reputation | Google | no |

So the two layers a wrapper *can* touch are the two nobody enforces on, and the
one that matters is untouched by any script. What this tooling does instead is
address the underlying complaints properly:

* **rotating URL** → named Cloudflare tunnel on your own domain, stable across
  restarts (`CF_TOKEN` + `CF_TUNNEL_URL`), no interstitial page
* **blank page on a cloudflared quick tunnel** → click the interstitial, or use zrok
* **VM held open for hours for nothing** → `supervise.sh` idle and max-runtime
  watchdogs. This is also the honest fix for "less noticeable": a GPU VM idling
  with no interactive traffic is the actual pattern that gets throttled, and
  releasing it costs nothing.

Traffic or process respoofing is deliberately not implemented.

## Quick start

```bash
export ZROK_TOKEN=... ZROK_NAME=codesrv   # fixed https://codesrv.shares.zrok.io
bash colab/install.sh
bash colab/serve.sh
```

## Flow and logs

```
install.sh                   slow: 1–3 min on a fresh runtime
  apt runtime libs → code-server tarball (~100 MB) → zrok2 + cloudflared

supervise.sh                 returns immediately, runs detached
  └─ serve.sh
       clear stale pidfiles
       port check
       code-server → poll /healthz            5–90 s
       tunnel      → poll for public URL     10–60 s
       write credentials.txt → print URL + password
  └─ restart on crash, stop on idle / max runtime
```

| File | Contents |
|---|---|
| `$CS_STATE_DIR/supervise.out` | **progress log**, one line per stage |
| `$CS_STATE_DIR/code-server.log` | editor server; startup crashes land here |
| `$CS_STATE_DIR/cloudflared.log` | tunnel registration, public URL |
| `$CS_STATE_DIR/credentials.txt` | `url=` / `password=` / `tunnel=` |

Health and tunnel waits emit a heartbeat every 10–15 s (`waiting for ... (30s)`),
so a slow start is distinguishable from a hung one. If `serve.sh` stops making
progress, the last line of `supervise.out` names the stage.

First run is slow for reasons that are not code-server: `apt-get` on a fresh
image, ~150 MB of downloads, and tunnel registration. `auto` picks zrok when it
has a token (fast) and cloudflared otherwise (no account, slower to register).

## Tunnels

Two providers. `auto` picks zrok when a token and a name are present, otherwise
cloudflared.

### zrok — fixed URL (preferred)

The URL is derived from a **reserved name**, not from machine identity, so a new
Colab runtime gets the same address:

```
https://<ZROK_NAME>.shares.zrok.io
```

```bash
ZROK_TOKEN=... ZROK_NAME=codesrv bash colab/serve.sh
```

Per run it does:

```bash
zrok2 enable "$ZROK_TOKEN" --headless        # --headless is required, there is no TTY
zrok2 create name -n public "$ZROK_NAME"     # skipped when it already exists
zrok2 share public 127.0.0.1:<port> -n "public:$ZROK_NAME" --headless
```

Things that bite:

* **`--headless` is mandatory** — without it `zrok2 enable` dies with
  `open /dev/tty: no such device`. "already have an enabled environment" counts
  as success.
* **Public names are global.** `409 conflict` from `create name` means another
  zrok user owns it, not that you already reserved it. `code` is taken;
  `codesrv` was free.
* The domain is **`shares`**.zrok.io (plural), and v2.0.9 logs the endpoint with
  no scheme, so the script matches the bare host and prefixes `https://`.

### cloudflared — fallback, no account

Used automatically when no zrok credentials are configured. Needs nothing, but
the quick-tunnel hostname is per process, so it changes every start:

```bash
bash colab/serve.sh --tunnel=cloudflared     # https://<random>.trycloudflare.com
```

A named tunnel gives a stable hostname instead:

```bash
CF_TOKEN=<tunnel-token> CF_TUNNEL_URL=https://code.example.com bash colab/serve.sh
```

The free quick tunnel shows a "You are about to visit" interstitial; click
through it before the editor loads, or the JS assets come back as HTML.

## Supervision

```bash
bash colab/supervise.sh
```

* restarts `serve.sh` with exponential backoff (2 s → 60 s) after a crash
* resets the backoff once the stack has been up for `CS_HEALTHY_AFTER` seconds
* shuts down after `CS_IDLE_TIMEOUT` seconds with zero established connections
* shuts down after `CS_MAX_RUNTIME` seconds, ahead of Colab's own hard cap

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CF_TOKEN` | — | Cloudflare named-tunnel token |
| `CF_TUNNEL_URL` | — | public hostname to report for a named tunnel |
| `CS_TUNNEL` | `auto` | `auto` \| `zrok` \| `cloudflared` \| `none`. `auto` = zrok when `ZROK_TOKEN` and `ZROK_NAME` are set, else cloudflared |
| `CS_PORT` | auto | pin a port, or leave empty to scan `CS_PORT_RANGE` and take the first free one. The tunnel always maps to the chosen port |
| `CS_PORT_RANGE` | `3000-5000` | scan range when `CS_PORT` is empty. Avoids 8080, which `datalab/web/app.js` owns on some Colab runtimes. The choice is recorded in `$CS_STATE_DIR/port` |
| `CS_PASSWORD` | generated | fixed password; otherwise persisted to the state dir |
| `CS_STATE_DIR` | `/content/.code-server` | data, extensions, logs, pidfiles, password |
| `CS_CACHE_DIR` | `$CS_STATE_DIR/cache` | release tarball cache — point at Drive to skip re-downloads |
| `CS_VERSION` | latest | pin a code-server version |
| `CS_PREFIX` | `/usr/local` | install prefix |
| `CS_EXTENSIONS` | — | comma-separated extension IDs, installed once |
| `CS_IDLE_TIMEOUT` | `1800` | supervise: idle seconds before shutdown; `0` disables the idle watchdog |
| `CS_MAX_RUNTIME` | `39600` | supervise: total seconds before shutdown |
| `CS_MAX_RESTARTS` | `20` | supervise: consecutive failures before giving up |
| `CS_ALLOW_INSECURE` | `0` | must be `1` to accept `--no-auth` |
| `CS_STATE_DIR` on Drive | — | `CS_STATE_DIR=/content/drive/MyDrive/.cs` keeps extensions across runtimes at some FS latency cost |

## Diagnostics

```bash
bash colab/doctor.sh
```

Reports architecture, OS, memory, `/content` free space, code-server version,
tunnel credentials, live processes, port state, established connections,
`/healthz`, log sizes. Read-only. The password is hidden in its output; read
`$CS_STATE_DIR/credentials.txt` (mode 0600) if you need it.

## Why these flags

| Flag | Reason |
|---|---|
| `--bind-addr 127.0.0.1:PORT` | the tunnel agent is in the same VM; nothing needs a public bind |
| `--auth password` | tunnel hostnames get probed within minutes — never `--auth none` |
| `--disable-telemetry` / `--disable-update-check` | noise, plus writes to an ephemeral disk |
| `--disable-workspace-trust` | otherwise the trust modal eats the first click |
| `--user-data-dir` / `--extensions-dir` | keeps state in one persistable directory |
| `--trusted-origins '*'` | only if a proxy **rewrites** `Host` (`--host-header=rewrite`, Caddy `header_up Host`). That is the one case that looks like it needs a patch and does not. |

## Troubleshooting

| Symptom | Cause |
|---|---|
| blank page, no editor | quick-tunnel interstitial not clicked through |
| URL died within seconds of appearing | `Runtime → Run all` also runs the Stop cell. It is now opt-in (`STOP = True`), but any older copy will still tear the stack down right after printing the URL |
| Cloudflare **error 1033** | the tunnel hostname resolves but no connector is attached — cloudflared died, or you are using a hostname from a previous run. Quick tunnels get a new hostname per start, so always take the URL from `credentials.txt`; `doctor.sh` now probes it and names 1033 |
| stale 404 URL | previous runtime's URL; re-run `serve.sh` |
| editor loads, terminal dies | WebSocket not carried by the path in use |
| `port 8080 is busy` | an orphan from an earlier run; `serve.sh` reclaims it automatically when it looks like ours. If it cannot, the pid and argv are printed — free it or use `--port=<n>` |
| restart loop, never reaching a URL | a previous supervisor is still alive relaunching the stack. `stop.sh` kills the supervisor *first*, then reclaims the port |
| stuck on `waiting for cloudflared URL` | quick-tunnel registration is slow or rate-limited; set `NGROK_TOKEN` |
| stuck on `waiting for .../healthz` | startup crash — read `code-server.log` |
| `extensions already installed` but missing | delete `$CS_STATE_DIR/.extensions-*` and restart |

## Hardening notes

* The password file is `0600`; `credentials.txt` is `0600` and holds the
  plaintext. For a stronger setup use code-server's `HASHED_PASSWORD`
  (argon2id) in `~/.config/code-server/config.yaml` and set `CS_PASSWORD` to
  nothing, accepting that the password is then not recoverable from disk.
* `NGROK_BASIC_AUTH` puts a second credential in front of code-server so port
  scanners never reach it. Cheap and worth it on a free hostname.
* Never combine a public tunnel with `--no-auth`, and never bind `0.0.0.0` on a
  host with a public interface.

## On the Colab terms

Colab's FAQ does not list remote-desktop or remote-IDE use as supported. This
works, but the runtime is ephemeral, the URL changes on restart unless you use a
named tunnel, and account-level throttling is always possible regardless of how
the process is named or wrapped.
