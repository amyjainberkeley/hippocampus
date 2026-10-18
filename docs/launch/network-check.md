# Confirm Hippocampus stays on your Mac — the 24-hour runtime check

`scripts/launch/no-egress.sh` proves from the **source** that the only code
that can open a connection is the update check (to GitHub) and loopback
(the local model server, and any loopback MCP server you add). This page is
the other half: how to confirm at **runtime**, on your own Mac, over a full
day of real use, that nothing else dials out.

You run these — they watch live traffic for hours, which a build script
can't do. Each one is content-free: it records destinations and byte
counts, never what's on your screen.

What "pass" looks like for every tool below:

- **Loopback only** — remote address `127.0.0.1`, `::1`, or `localhost`.
  That is the local model server (Ollama `:11434`, LM Studio `:1234`) and
  any loopback MCP server you added. These never leave the machine.
- **GitHub, occasionally** — a connection to `github.com` /
  `objects.githubusercontent.com` when the app checks for or downloads an
  update. The feed is
  `https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml`.
- **Nothing else.** Any other remote address from a Hippocampus process is
  a finding — capture it and open an issue.

The Hippocampus processes to watch (their executables live in
`/Applications/Hippocampus.app/`): `Hippocampus`, `MCICaptureHelper`,
`hippocampus-ocr`, `mci-agent` (one per AI-tool session, plus Ask),
`hippocampus-mind`, `hippocampus-native-host`, `recall-ui`, `onboarding`.

---

## 0. Get the process list (used by the commands below)

```sh
# PIDs of every running process inside the app bundle.
HIPPO_PIDS=$(ps -axo pid=,comm= | awk '/\/Applications\/Hippocampus.app\//{print $1}' | paste -sd, -)
echo "$HIPPO_PIDS"
```

---

## 1. `lsof` — a point-in-time socket snapshot (no extra software)

Every open TCP/UDP socket held by Hippocampus, with `-nP` so no name or
port is resolved over the network:

```sh
lsof -nP -iTCP -iUDP -a -p "$HIPPO_PIDS"
```

- **LISTEN** rows: there should be none. (`scripts/launch/no-listener.sh`
  checks this for you.)
- **ESTABLISHED** rows: the remote (`->` right-hand side) must be loopback
  or a GitHub address. Anything else is a finding.

Sample it on a loop for a day and keep only the non-loopback, non-GitHub
remotes:

```sh
# every 15 s for 24 h → egress-sample.log ; records remotes only, no content
end=$(( $(date +%s) + 24*3600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  pids=$(ps -axo pid=,comm= | awk '/\/Applications\/Hippocampus.app\//{print $1}' | paste -sd, -)
  [ -n "$pids" ] && lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$pids" 2>/dev/null \
    | awk 'NR>1{print $1, $9}' \
    | grep -vE '127\.0\.0\.1|\[::1\]|->(.*\.)?github(usercontent)?\.com' >> egress-sample.log
  sleep 15
done
wc -l egress-sample.log   # 0 lines = nothing but loopback + GitHub all day
```

---

## 2. `nettop` — live per-process bytes in/out (built in, no root)

`nettop` shows each process's connections and running byte counts. Watch
the app bundle's processes and their remote addresses:

```sh
# interactive: one row per connection, remote addresses shown, no DNS
sudo nettop -nP -m tcp            # all processes; find the Hippocampus rows
# or scope to one PID (repeat per PID; nettop takes a single -p):
nettop -nP -p <PID>
```

Read it the same way: every remote under a Hippocampus process is loopback
or GitHub. `nettop -x -l 0` streams CSV you can log and filter over a day
the same way as the `lsof` loop above.

> Note: `nettop`'s per-connection view is the honest one. Activity
> Monitor's **Network** tab shows totals but not destinations, so it can't
> answer "where did the bytes go" — use `nettop` or `lsof` for that.

---

## 3. Little Snitch / LuLu — a day of allow/deny prompts (recommended)

An outbound firewall is the strongest check, because it sees every
connection attempt whether or not you were looking.

**Little Snitch**

1. Install Little Snitch and open **Little Snitch Rules**.
2. Delete or disable any existing rules for `Hippocampus` and its helpers so
   you start from prompts, not silent allows.
3. Use the Mac for a normal day. You should be prompted for, and should
   only see:
   - connections to `127.0.0.1` / `::1` (local model server, loopback MCP),
   - a connection to `github.com` when an update check runs.
4. Open **Little Snitch Network Monitor** and filter to the Hippocampus
   processes. The map and the connection list should show loopback and
   GitHub only.
5. Any prompt for a different host is a finding — **Deny**, screenshot the
   prompt, and file it.

**LuLu** (free, open source) works the same way: it prompts on each new
outbound connection; expect only loopback and GitHub.

---

## 4. If you want packet-level proof (advanced)

Capture only packets that actually leave the machine (exclude loopback),
then confirm the only external host is GitHub's:

```sh
# needs sudo; writes a pcap of NON-loopback traffic for later inspection
sudo tcpdump -n -i en0 -w hippo-egress.pcap \
  'tcp and not (dst net 127.0.0.0/8 or dst host ::1)'
# later, list the external hosts contacted during the capture:
tcpdump -n -r hippo-egress.pcap 'tcp[tcpflags] & tcp-syn != 0' | awk '{print $5}' | sort -u
```

`tcpdump` can't attribute a packet to a process, so pair it with the
`lsof`/`nettop` loop above to tie an external host back to a Hippocampus
PID. For a hard per-process boundary, prefer Little Snitch (§3).

---

## What to do with a finding

If any tool shows a Hippocampus process connecting to a host that is not
loopback and not GitHub:

1. Keep the evidence (the `egress-sample.log` line, the Little Snitch
   prompt, or the pcap).
2. Note the PID and which binary it was (`ps -o comm= -p <PID>`).
3. Open an issue at
   `https://github.com/amyjainberkeley/hippocampus/issues` with the
   destination host and the binary. This is exactly the kind of report the
   project wants before, and after, launch.
