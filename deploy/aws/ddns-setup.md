# Namecheap Dynamic DNS — one-time setup (`strim.example.com`)

`strim.example.com` is kept pointed at the instance's public IP by the
`strim-ddns` systemd service (a container run through `ctr` that performs an
HTTPS GET to Namecheap's Dynamic DNS endpoint), on a `strim-ddns.timer`
running every 6h. This is a one-time, manual setup that must happen before the
first `deploy/aws/setup_strimserver` run; `deploy.sh` fails loudly if it
cannot find the DDNS password.

## 1. Create the Dynamic DNS host on Namecheap

1. Log in to your Namecheap account and open **Domain List → `example.com` →
   Advanced DNS**.
2. In the **Dynamic DNS** section, set the host to **`strim`**.
3. Set a **dedicated** Dynamic DNS password (any strong value; it is the
   update-token, not a credential of yours). Use a value separate from the
   `git` host's password — a per-host token keeps the blast radius of a leak
   contained to a single record.
4. Save. Namecheap now serves `strim.example.com` through
   `dynamicdns.park-your-domain.com`.

> The host must match the `DDNS_HOST` operator setting (default `strim`); the
> domain is `DDNS_DOMAIN`. Namecheap DDNS records expire if not refreshed
> (~30d), which is why `strim-ddns.timer` refreshes every 6h
> (`Persistent=true`).

## 2. Supply the password and settings at deploy time

The password is an operator secret, injected at deploy time like the Twitch
stream key — it is never baked into the deployment bundle. The three Dynamic
DNS settings are non-secret operator settings, propagated the same way. Put
them in `deploy/aws/.env`:

```sh
DDNS_PASSWORD="the-namecheap-ddns-password"
# or point at a file containing only the password
# (overridden by the inline value above if both are set):
DDNS_PASSWORD_FILE="$HOME/.config/strimserver/ddns-password"

ENABLE_DDNS="true"          # toggle; the redistributable bundle ships false
DDNS_HOST="strim"           # Namecheap DDNS host label
DDNS_DOMAIN="example.com"   # the domain the record lives under
```

`setup_strimserver` transfers the password to the instance over scp as a `0600`
file at `/mnt/nvme/ddns-password`, and the settings as a `0600` file at
`/mnt/nvme/ddns-config`; `deploy.sh` installs the password to
`/etc/strim-ddns/password` (root:root `0600`), merges the settings into the
on-box `strimserver.env`, and scrubs both transfer files. No password →
`deploy.sh` exits loudly and `strim.example.com` is not registered. With no
settings transferred, the bundled defaults (DDNS disabled) stay in effect.

## 3. How deploy.sh wires it up

`deploy.sh` does all DDNS setup **before** it prints the M1 milestone; the
post-M1 DDNS block contains only the two bounded unit starts below.

1. Installs the transferred password to `/etc/strim-ddns/password` (root:root
   `0600`) and scrubs the scp'd `/mnt/nvme/ddns-password`.
2. Installs the `strim-ddns.service` and `strim-ddns.timer` units
   (`install -D -m 644`), renders `strim-ddns-verify.service` from its template
   with the expected public IP substituted, disables any old async verify
   enablement (`sudo timeout -k 5 10 systemctl disable
   strim-ddns-verify.service`), then `systemctl enable --now strim-ddns.timer`
   (6h, `Persistent=true`, `RandomizedDelaySec=300`).
3. Imports `strim-ddns-container.tar` into the `strimserver` containerd
   namespace as part of the parallel image-import barrier (before M1).
4. **Refresh (blocking).** Runs
   `sudo timeout -k 5 40 systemctl start strim-ddns.service`.
   `strim-ddns.service` sets `TimeoutStartSec=30`, so systemd bounds the refresh
   first; `timeout -k 5 40` is the backstop for a genuinely wedged start. By
   default `DDNS_IP` is empty, so the update sends **no `ip=` parameter** and
   Namecheap records the requester's IPv4; the client pins IPv4 egress
   (`CURLOPT_IPRESOLVE=CURL_IPRESOLVE_V4`). An explicit `DDNS_IP` still works if
   an operator sets one.
5. **Verify (blocking).** Runs
   `sudo timeout -k 5 150 systemctl start strim-ddns-verify.service`.
   `systemctl start` on a `Type=oneshot` unit blocks until it exits and
   propagates its status. The unit owns retry semantics —
   `TimeoutStartSec=140` is the primary overall bound, each check attempt is
   wrapped in `timeout 30`, `sleep 5` separates attempts, and there is **no
   fixed attempt count** — and logs `attempt N: observed <ip|none> expected
   <ip>` per failed attempt and `verified after N attempts (<Xs>)` on success.
   The `check` binary does not count attempts.

   Each check runs **inside** the `strim-ddns` container via its `check`
   subcommand, a direct authoritative query to the domain's nameservers (via
   the container's c-ares DNS client) — ground truth, immune to the box's local
   resolver cache, and needing no bind-utils/dnsutils on the box. The check is
   **per-nameserver**: each discovered NS hostname is queried separately through
   its own IPv4 (A-record) addresses, per-phase concurrent in one c-ares event
   loop, and it passes only when **every** NS returns the expected IP via at
   least one of its own IPs. One unreachable or disagreeing NS means "not yet".
   The c-ares budget is 4000 ms × 2 tries per channel, so each phase is ≤8 s and
   the worst case is ≈24 s < the per-attempt `timeout 30`. The binary prints one
   line per NS on stderr (`check <fqdn> ns <host> -> <ip|none>`) and the single
   agreed IPv4 on stdout.

**Exit codes.** `deploy.sh` maps the stages onto its taxonomy: `0` only when M2
is reached (every NS agreed, or DDNS disabled); `3` when a stage failed (the
message names refresh `strim-ddns.service` versus verify
`strim-ddns-verify.service`); `4` when the outer wrapper returned `124` or `137`
(backstop timeout — `deploy.sh` stops the unit and, if that stop also fails,
warns that the unit may still be running); `5` when another deploy holds the
lock; `129`/`130`/`143` when the deploy was signalled (HUP/INT/TERM) and any
in-flight DDNS unit was stopped; `255` when `setup_strimserver` lost its ssh
connection (remote state unknown). Every `systemctl` start/stop here is wrapped
as `sudo timeout -k 5 <n> systemctl …`, so `timeout` runs inside `sudo` and can
signal the root-owned client.

Subsequent timer runs keep `ip=` omitted — the `strim-ddns` client then lets
Namecheap use the requester IP (the instance's auto-assigned public IP):

```
https://dynamicdns.park-your-domain.com/update?host=strim&domain=example.com&password=...&ip=<optional>
```

A `Good <ip>`, `No change` (IP unchanged), or an XML `<interface-response>`
with `<ErrCount>0</ErrCount>` is a success; anything else fails loudly
(fail-fast). Note Namecheap returns HTTP 200 for both success and error, so
the client checks the response body rather than trusting the HTTP status.

## 4. Bootstrapping and post-deploy access

Before `deploy.sh` registers the record, the box is reached by its raw public
IP (SSH bootstrap; `launch --wait` prints it). After deploy completes, all
access uses the hostname:

- SSH — `ssh ec2-user@strim.example.com`
- Local encoder — `STRIMSERVER_HOST=strim.example.com` (see
  `tools/local-encoder/local-encoder.env.example`)
- Stream Deck control plugin — `http://strim.example.com:4000`

## 5. Verify after deploy

From the operator's own machine, as a sanity check that the record is live:

```sh
host strim.example.com          # -> should return the box's public IP
```

That is an operator-side check only — `deploy.sh`'s own verification runs
**inside** the `strim-ddns` container via its `check` subcommand, which queries
**each** discovered nameserver separately through its own IPv4 A-record
addresses (the container's c-ares DNS client) and passes only when every NS
returns the expected IP. Being in-container and direct to the authoritative
nameservers, it is ground truth and immune to the box's local resolver cache —
the box needs no bind-utils/dnsutils installed. The expected IPv4 is required
(third argument or `DDNS_EXPECTED_IP`); on the box you can confirm the same
check directly, substituting the box's public IP:

```sh
sudo ctr -n strimserver run --rm --net-host \
  --mount type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro \
  --mount type=bind,src=/etc/hosts,dst=/etc/hosts,options=rbind:ro \
  docker.io/library/strim-ddns:latest strim-ddns /strim-ddns check strim example.com <expected-ip>
```

The check prints one line per NS on stderr (`check <fqdn> ns <host> -> <ip|none>`)
and the single agreed IPv4 on stdout; it exits `0` only when every NS agrees and
`1` when any is unreachable or disagrees.

The DDNS timer and service remain the ongoing health signals:

```sh
systemctl status strim-ddns.timer    # active (waiting), next refresh in ~6h
journalctl -u strim-ddns.service     # "Good <ip>" / "No change" on success
```

`deploy.sh` already performs the resolution check once at deploy time; if the
hostname stops resolving later, check the timer (`systemctl list-timers
strim-ddns.timer`) and the last service output
(`journalctl -u strim-ddns.service -e`).