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
| egress SNI / hostname (`*.ngrok-free.app`) | the network path | only by using your own domain on a named tunnel. That is not disguise, it is hosting — see below. |
| tunnel-side HTTP/WS shape (`/websocket`, asset paths) | ngrok / Cloudflare edge, not Google | no reason to care |
| runtime behaviour: idle GPU VM, session length, zero executed cells, memory/CPU profile | Google, account level | **no** — and this is the layer that gets actioned |
| account / session count / IP reputation | Google | no |

So the two layers a wrapper *can* touch are the two nobody enforces on, and the
one that matters is untouched by any script. What this tooling does instead is
address the underlying complaints properly:

* **rotating URL** → named Cloudflare tunnel on your own domain, stable across
  restarts (`CF_TOKEN` + `CF_TUNNEL_URL`), no interstitial page
* **blank page on ngrok** → reserved ngrok domain (`NGROK_DOMAIN`)
* **VM held open for hours for nothing** → `supervise.sh` idle and max-runtime
  watchdogs. This is also the honest fix for "less noticeable": a GPU VM idling
  with no interactive traffic is the actual pattern that gets throttled, and
  releasing it costs nothing.

Traffic or process respoofing is deliberately not implemented.

## Quick start

```bash
export NGROK_TOKEN=...        # dashboard.ngrok.com/get-started/your-authtoken
bash colab/install.sh
bash colab/serve.sh
```

## Flow and logs

```
install.sh                   slow: 1–3 min on a fresh runtime
  apt runtime libs → code-server tarball (~100 MB) → ngrok → cloudflared

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
| `$CS_STATE_DIR/ngrok.log` | JSON; look for `ERR_NGROK_4018`, `ERR_NGROK_108` |
| `$CS_STATE_DIR/credentials.txt` | `url=` / `password=` / `tunnel=` |

Health and tunnel waits emit a heartbeat every 10–15 s (`waiting for ... (30s)`),
so a slow start is distinguishable from a hung one. If `serve.sh` stops making
progress, the last line of `supervise.out` names the stage.

First run is slow for reasons that are not code-server: `apt-get` on a fresh
image, ~150 MB of downloads, and tunnel registration. `auto` picks ngrok when it
has a token (fast) and cloudflared otherwise (no account, slower to register).

## Tunnels

### ngrok (default)

```bash
bash colab/serve.sh                                      # auto-selects a tunnel
CS_TUNNEL=ngrok bash colab/serve.sh
NGROK_DOMAIN=my-dev.ngrok-free.app bash colab/serve.sh   # reserved, stable
NGROK_BASIC_AUTH='user:pass' bash colab/serve.sh         # gate at the edge
```

Free tier shows a "You are about to visit" page on the first browser hit. Click
through it before the editor loads, otherwise the JS assets are served as HTML
and you get a blank page. Free tier also allows one agent session and rotates
the hostname unless you reserve a domain.

### cloudflared (no interstitial, supports a real domain)

```bash
WITH_CLOUDFLARED=1 bash colab/install.sh
bash colab/serve.sh --tunnel=cloudflared            # https://<rand>.trycloudflare.com
```

Named tunnel, stable hostname, no warning page:

```bash
cloudflared tunnel login
cloudflared tunnel create colab
cloudflared tunnel route dns colab code.example.com
# then, per session:
CF_TOKEN=<tunnel-token> CF_TUNNEL_URL=https://code.example.com \
  bash colab/serve.sh --tunnel=cloudflared
```

This is the durable option. Nothing is being hidden: the traffic is a normal
TLS connection to a domain you control.

### Tailscale Funnel (fixed URL off a free account)

Funnel gives you a **stable** `https://<machine>.<tailnet>.ts.net` hostname
instead of a new one per start. It is available on **all plans, including free**
(currently beta), and only the edge ports `443`, `8443` and `10000` are public —
the local port stays whatever `serve.sh` picked.

### Getting an auth key

One-time setup, in the Tailscale admin console:

1. **DNS** — <https://login.tailscale.com/admin/dns> → enable **MagicDNS** and
   **HTTPS Certificates**. Funnel needs a real certificate for `*.ts.net`, and
   the toggle is easy to miss.
2. **Keys** — <https://login.tailscale.com/admin/settings/keys> →
   **Generate auth key…** with:

   | setting | value | why |
   |---|---|---|
   | Reusable | **on** | a single-use key is consumed by the first runtime, and the next one cannot rejoin under the same name |
   | Ephemeral | **off** | an ephemeral node is deleted on disconnect, so the `*.ts.net` name would be reassigned |
   | Tags | none | tagged nodes need extra ACL work for Funnel; a user-owned node just works |
   | Expiry | as long as allowed (90 d) | you re-generate when it lapses; a revocable key beats a permanent one |

3. Copy it — it looks like `tskey-auth-k...-...` and is shown **once**.

### Setting it

Three places, in precedence order. First non-empty wins:

1. the notebook config cell (`TS_AUTHKEY = "tskey-auth-..."`)
2. a real environment variable — `%env TS_AUTHKEY=tskey-auth-...`, or
   `export TS_AUTHKEY=...` before `bash colab/serve.sh`
3. a **Colab Secret** named `TS_AUTHKEY`

Note that (3) is *not* an environment variable. Colab Secrets are only reachable
through `userdata.get('TS_AUTHKEY')`; they are never exported into `os.environ`,
so a script that reads `$TS_AUTHKEY` will not see one. That is why the config
cell resolves secrets explicitly and then exports the result:

```python
tskey = _resolve(TS_AUTHKEY, "TS_AUTHKEY")   # cell -> env -> userdata.get
if tskey:
    os.environ["TS_AUTHKEY"] = tskey
```

The write-back is conditional on purpose: assigning unconditionally would
overwrite a key that came from a real environment variable with an empty string.

Failure modes the helper reports instead of silently returning empty:

| what you see | meaning |
|---|---|
| `[secret] 'TS_AUTHKEY' exists but notebook access is off` | the secret is there, the toggle isn't — Secrets panel → grant access |
| `tailscale key: none`, no message | the secret does not exist under that exact name |
| `tailscale key: tskey-auth-k1…(63 chars)` | resolved; run the next cell |

Prefer the environment variable or a **Colab Secret** (🔑 in the left sidebar → add secret named
`TS_AUTHKEY` → enable notebook access). The config cell reads it automatically
and never prints it in full:

```
ngrok token: none | tailscale key: tskey-auth-k1…(63 chars)
```

Alternatives:

```python
# config cell, if you accept a credential in the notebook file
TS_AUTHKEY = "tskey-auth-..."
```

```bash
# shell
export TS_AUTHKEY=tskey-auth-...
bash colab/serve.sh --tunnel=tailscale
```

Then set `TUNNEL = "tailscale"` (or leave `auto` — `auto` picks Tailscale when a
key is present) and `TS_HOSTNAME = "colab-dev"`. Keep `TS_HOSTNAME` constant: it
*is* the URL.

Treat the key as a password: a reusable one lets anyone holding it join your
tailnet. Revoke it on the same Keys page when you are done, and never commit it.

```bash
WITH_TAILSCALE=1 bash colab/install.sh
TS_AUTHKEY=tskey-auth-... TS_HOSTNAME=colab-dev bash colab/serve.sh --tunnel=tailscale
```

Or in the notebook: `TUNNEL = "tailscale"`, `TS_AUTHKEY = "tskey-auth-..."`,
`TS_HOSTNAME = "colab-dev"`. The URL is reported per run and is the same every
time, so `https://colab-dev.<tailnet>.ts.net` becomes a bookmark.

How it works on Colab: there is no `/dev/net/tun`, so `tailscaled` runs with
`--tun=userspace-networking`, and Funnel/Serve still function because tailscaled
dials `127.0.0.1:<port>` itself. `stop.sh` runs `tailscale funnel reset`,
otherwise the hostname keeps advertising a dead port.

Costs of the fixed URL, so nobody is surprised: traffic is relayed through
Tailscale rather than direct, so latency is higher than ngrok/cloudflared; the
hostname is stable but only *serves* while a runtime is up (a dead runtime gets a
connection error, not a 404); and Funnel is still a public endpoint, so it is the
same exposure as any other tunnel.

### Not an option: Colab's own port proxy

`google.colab.output.serve_kernel_port_as_window()` can expose a port, but the
proxy is built around Jupyter kernel channels and does not reliably carry the
long-lived bidirectional WebSocket the VS Code web client needs. The editor may
load and then lose its terminal. That is why every working setup uses a tunnel.

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
| `NGROK_TOKEN` | — | ngrok authtoken, or add it once with `ngrok config add-authtoken` |
| `NGROK_DOMAIN` | — | reserved domain → stable hostname, no rotation |
| `NGROK_BASIC_AUTH` | — | `user:pass`, rejects scanners at ngrok's edge |
| `CF_TOKEN` | — | Cloudflare named-tunnel token |
| `CF_TUNNEL_URL` | — | public hostname to report for a named tunnel |
| `TS_AUTHKEY` | — | Tailscale auth key; set it and `auto` prefers Funnel. Make it **reusable** |
| `TS_HOSTNAME` | `colab-code-server` | node name, and therefore the `*.ts.net` hostname — keep it fixed |
| `TS_TUNNEL_URL` | — | override the reported URL instead of reading it from `tailscale status` |
| `WITH_TAILSCALE` | `0` | `install.sh` also installs `tailscale` + `tailscaled` |
| `CS_TUNNEL` | `auto` | `auto` \| `ngrok` \| `cloudflared` \| `tailscale` \| `none`. `auto` = ngrok when it has credentials, else a cloudflared quick tunnel (no account needed) |
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
| blank page, no editor | ngrok warning page not clicked through |
| `ERR_NGROK_4018` | no authtoken: `ngrok config add-authtoken <token>` |
| `ERR_NGROK_108` | free tier allows one agent session; `bash colab/stop.sh` first |
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
