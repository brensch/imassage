# imassage

iMessage on Linux, without a Mac running. A Matrix homeserver (Synapse) plus the
[rustpush Matrix bridge](https://github.com/jasonlaguidice/imessage), which talks to Apple's
iMessage servers directly using a hardware key pulled once from a real Intel Mac.

Runs on snek3 (`~/imassage`), reached at `https://matrix.brensch.com` from the LAN and the
WireGuard VPN only. Clients: Element (desktop, Android, iOS).

```
Element ──https──▶ homelab Caddy ──▶ imessage-synapse ◀──appservice──▶ imessage-bridge ──▶ Apple (APNs/IDS)
 (LAN/VPN)          (~/home)          └──────────── imessage-postgres ────────────┘
```

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | postgres, synapse, bridge. Synapse joins the external `home_default` network so Caddy can reach it; nothing publishes a host port. |
| `synapse/` | Non-secret Synapse config. Federation and registration are off. |
| `postgres/init/` | Creates the bridge's database next to Synapse's. |
| `caddy/matrix.caddyfile` | The site block, copied into `~/home/config/caddy/Caddyfile`. |
| `setup.sh` | Writes `.env` and `data/` (secrets, bridge config + registration, signing key). Idempotent. |
| `data/` (gitignored) | Everything stateful. Back up `data/bridge-state` + `data/postgres` and you have it all. |

## From scratch

```sh
git clone https://github.com/brensch/imassage.git ~/imassage && cd ~/imassage
./setup.sh
docker compose up -d
docker exec -it imessage-synapse register_new_matrix_user -c /data/secrets.yaml -a http://localhost:8008
```

Plus, once per domain:
- DNS: `matrix.brensch.com A 192.168.1.8` in Cloudflare, DNS-only. Private IP on purpose: only
  LAN and WireGuard clients can use it.
- Caddy: paste `caddy/matrix.caddyfile` into the homelab Caddyfile, then
  `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.

The Matrix login on snek3 is in `~/.config/imessage/matrix_login`.

## Hardware key (one time)

On the Intel Mac (macOS 13+ for the CLI; otherwise build `tools/extract-key-app`):

```sh
git clone https://github.com/jasonlaguidice/imessage.git && cd imessage
go run tools/extract-key/main.go
```

It prints a base64 key. Treat it like a password: anyone holding it can register iMessage as
that Mac, and abuse gets the hardware banned. Keep the Mac in a drawer, not the bin, in case a
re-extraction is ever needed.

Before logging in, turn off **Contact Key Verification** (and Advanced Data Protection) on the
Apple ID.

## Logging in to iMessage

1. In Element, sign in to `matrix.brensch.com` as `@brensch:matrix.brensch.com`.
2. Start a DM with `@imessagebot:matrix.brensch.com` and send `login`.
3. Choose **Apple ID (External Key)**, paste the key, then Apple ID, password, 2FA code, and
   the handle to send from.

Then `start-chat +15551234567` (or an email) in the bot DM opens a conversation. Incoming
iMessages create their rooms on their own.

## Operating

```sh
docker compose logs -f bridge          # the thing most likely to need a look
docker compose pull && docker compose up -d   # after bumping an image pin
```

The bridge image is pinned by digest. To update it: `docker pull ghcr.io/jasonlaguidice/imessage:latest`,
read the upstream commits since the current pin, put the new digest in `docker-compose.yml`, `up -d`.
Apple-side breakage gets fixed upstream (OpenBubbles' rustpush first, then this bridge), so a
sudden failure across the board usually means waiting for and pulling a new image.

Limits worth knowing:
- Messages send from the Apple ID's email (or whatever handle Apple offers), not a phone number:
  a Mac key can't register a number.
- Apple throttles heavy senders (contacts turn green). Don't spam from it.
- History backfill from iCloud (`cloudkit_backfill` in `data/bridge/config.yaml`) is off; turning
  it on needs the device passcode at login to join the iCloud Keychain.
- Bridged rooms aren't end-to-end encrypted on the Matrix side; messages sit in Postgres on snek3.
