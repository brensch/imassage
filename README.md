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
./bridge/build.sh
./setup.sh      # then add the ANISETTE_MAC_* lines to .env (below)
docker compose up -d
docker exec -it imessage-synapse register_new_matrix_user -c /data/secrets.yaml -a http://localhost:8008
```

Plus, once per domain:
- DNS: `matrix.brensch.com A 192.168.1.8` in Cloudflare, DNS-only. Private IP on purpose: only
  LAN and WireGuard clients can use it.
- Caddy: paste `caddy/matrix.caddyfile` into the homelab Caddyfile, then
  `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.

The Matrix login on snek3 is in `~/.config/imessage/matrix_login`.

## Anisette from the Mac mini

Apple ID logins need "anisette" headers that prove a real Apple device. Since Oct 12 2026 Apple
rejects the ones from the public remote servers the bridge uses (`-80045`, before the password is
even checked; it broke AltStore/SideStore/iLoader too). Headers from a real Mac still work. So
the Mac mini (192.168.1.11, a DHCP reservation on the router) runs `mac-anisette/anisette_server.py`,
a launchd agent serving its AOSKit headers on port 6969 behind a bearer token. `bridge/mac-anisette.patch`
makes the bridge fetch from there when `ANISETTE_MAC_URL` is set.

Plain iMessage traffic (APNs/IDS) doesn't use anisette. Login, 2FA and the iCloud token refreshes
(contacts, CloudKit) do, so the Mac has to be reachable for those.

Mac side (Catalina's stock `/usr/bin/python` 2.7 + PyObjC, nothing to install):

```sh
mkdir -p ~/imassage-anisette && cp mac-anisette/anisette_server.py ~/imassage-anisette/
python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > ~/.imassage-anisette-token   # (any random string)
sed "s#__HOME__#$HOME#g" mac-anisette/com.brensch.imassage-anisette.plist > ~/Library/LaunchAgents/com.brensch.imassage-anisette.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.brensch.imassage-anisette.plist
```

snek3 side: `ANISETTE_MAC_URL=http://192.168.1.11:6969/` and `ANISETTE_MAC_TOKEN=<same token>` in `.env`,
and the image built by `bridge/build.sh` (upstream at a pinned commit plus `bridge/*.patch`).

## Hardware key (one time)

On the Intel Mac (macOS 13+ for the CLI; otherwise build `tools/extract-key-app`):

```sh
git clone https://github.com/jasonlaguidice/imessage.git && cd imessage
go run tools/extract-key/main.go
```

(The mini is stuck on Catalina with no Xcode tools, so this key was instead built from stock
`ioreg -a -c IOPlatformExpertDevice`, `nvram -x <GUID>:ROM/MLB`, `diskutil info -plist /`,
`sysctl`/`sw_vers`/`ifconfig` output, in the same JSON the Go tool emits. Catalina doesn't
expose the five `_enc` IOKit properties; the bridge computes them on Linux.)

It prints a base64 key, stored on snek3 at `~/.config/imessage/hardware_key`. Treat it like a password: anyone holding it can register iMessage as
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

The bridge image is built locally. To update it: read the upstream commits since `COMMIT` in
`bridge/build.sh`, bump it (check the patch still applies), run `bridge/build.sh`, put the new tag
in `docker-compose.yml`, `up -d`.
Apple-side breakage gets fixed upstream (OpenBubbles' rustpush first, then this bridge), so a
sudden failure across the board usually means waiting for and pulling a new image.

Limits worth knowing:
- Messages send from the Apple ID's email (or whatever handle Apple offers), not a phone number:
  a Mac key can't register a number.
- Apple throttles heavy senders (contacts turn green). Don't spam from it.
- History backfill from iCloud (`cloudkit_backfill` in `data/bridge/config.yaml`) is off; turning
  it on needs the device passcode at login to join the iCloud Keychain.
- Bridged rooms aren't end-to-end encrypted on the Matrix side; messages sit in Postgres on snek3.
