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

> The host must be exactly `strim` — it matches the `DDNS_HOST` baked into the
> `strim-ddns` unit (domain is `example.com` = `DDNS_DOMAIN`). Namecheap DDNS
> records expire if not refreshed (~30d), which is why `strim-ddns.timer`
> refreshes every 6h (`Persistent=true`).

## 2. Supply the password at deploy time

The password is an operator secret, injected at deploy time like the Twitch
stream key — it is never baked into the deployment bundle. Put it in
`deploy/aws/.env`:

```sh
DDNS_PASSWORD="the-namecheap-ddns-password"
# or point at a file containing only the password
# (overridden by the inline value above if both are set):
DDNS_PASSWORD_FILE="$HOME/.config/strimserver/ddns-password"
```

`setup_strimserver` transfers it to the instance over scp as a `0600` file at
`/mnt/nvme/ddns-password`; `deploy.sh` installs it to
`/etc/strim-ddns/password` (root:root `0600`) and scrubs the transfer file. No
password → `deploy.sh` exits loudly and `strim.example.com` is not registered.

## 3. How deploy.sh wires it up

At the end of the deploy run `deploy.sh`:

1. Installs the transferred password to `/etc/strim-ddns/password` (root:root
   `0600`) and scrubs the scp'd `/mnt/nvme/ddns-password`.
2. Installs the `strim-ddns.service` and `strim-ddns.timer` units
   (`install -D -m 644`), then `systemctl enable --now strim-ddns.timer` (6h,
   `Persistent=true`, `RandomizedDelaySec=300`).
3. Imports `strim-ddns-container.tar` into the `strimserver` containerd
   namespace.
4. Runs a one-shot refresh passing `ip=$PUBLIC_IP` explicitly (`DDNS_IP=` via a
   temporary EnvironmentFile), so the record points at this box immediately;
   the env file is removed after the run.
5. Verifies — up to 120s, ~24×5s retries — that `strim.example.com` resolves to
   the box's public IP. On mismatch it fails loudly (`exit 1`).

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

```sh
host strim.example.com          # -> should return the box's public IP
getent ahostsv4 strim.example.com

systemctl status strim-ddns.timer    # active (waiting), next refresh in ~6h
journalctl -u strim-ddns.service     # "Good <ip>" / "No change" on success
```

`deploy.sh` already performs the resolution check once at deploy time; if the
hostname stops resolving later, check the timer (`systemctl list-timers
strim-ddns.timer`) and the last service output
(`journalctl -u strim-ddns.service -e`).