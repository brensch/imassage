#!/usr/bin/env bash
# Writes everything the stack needs that isn't in git: .env and data/ (secrets, generated
# configs, Synapse's signing key). Safe to re-run: secrets and tokens are only created when
# missing, and the bridge config patch below is re-applied every time.
set -euo pipefail
cd "$(dirname "$0")"

SERVER_NAME=matrix.brensch.com
ADMIN_USER="@brensch:${SERVER_NAME}"

rand() { python3 -c 'import secrets; print(secrets.token_urlsafe(32))'; }

# ── .env ──────────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
	umask 077
	cat >.env <<EOF
UID=$(id -u)
GID=$(id -g)
POSTGRES_PASSWORD=$(rand)
EOF
	umask 022
	echo "wrote .env"
fi
# Not sourced: bash keeps UID read-only.
export POSTGRES_PASSWORD="$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)"

mkdir -p data/postgres data/synapse data/bridge data/bridge-state
chmod 700 data

# ── Synapse secrets ───────────────────────────────────────────────────────────
if [ ! -f data/synapse/secrets.yaml ]; then
	umask 077
	cat >data/synapse/secrets.yaml <<EOF
database:
  name: psycopg2
  args:
    user: matrix
    password: "${POSTGRES_PASSWORD}"
    dbname: synapse
    host: postgres
    cp_min: 2
    cp_max: 10
macaroon_secret_key: "$(rand)"
form_secret: "$(rand)"
registration_shared_secret: "$(rand)"
EOF
	umask 022
	echo "wrote data/synapse/secrets.yaml"
fi

# Lets the bridge post messages you send from other Apple devices as your own Matrix user
# instead of a ghost of you.
if [ ! -f data/synapse/doublepuppet.yaml ]; then
	umask 077
	cat >data/synapse/doublepuppet.yaml <<EOF
id: doublepuppet
url: null
as_token: "$(rand)"
hs_token: "$(rand)"
sender_localpart: "$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
rate_limited: false
namespaces:
  users:
    - regex: '@.*:${SERVER_NAME//./\\.}'
      exclusive: false
EOF
	umask 022
	echo "wrote data/synapse/doublepuppet.yaml"
fi

# ── Bridge config ─────────────────────────────────────────────────────────────
if [ ! -f data/bridge/config.yaml ]; then
	docker compose run --rm --no-deps bridge -c /data/config.yaml -e
fi

python3 - "$SERVER_NAME" "$ADMIN_USER" <<'PY'
import os, sys, yaml

server_name, admin = sys.argv[1], sys.argv[2]
path = "data/bridge/config.yaml"
cfg = yaml.safe_load(open(path))
dp = yaml.safe_load(open("data/synapse/doublepuppet.yaml"))

cfg["homeserver"]["address"] = "http://synapse:8008"
cfg["homeserver"]["domain"] = server_name

cfg["appservice"]["address"] = "http://bridge:29332"
cfg["appservice"]["hostname"] = "0.0.0.0"
cfg["appservice"]["public_address"] = None

cfg["database"]["type"] = "postgres"
cfg["database"]["uri"] = (
    f"postgres://matrix:{os.environ['POSTGRES_PASSWORD']}@postgres/imessage?sslmode=disable"
)

cfg["bridge"]["permissions"] = {server_name: "user", admin: "admin"}
cfg["matrix"]["federate_rooms"] = False

cfg["double_puppet"]["servers"] = {}
cfg["double_puppet"]["secrets"] = {server_name: "as_token:" + dp["as_token"]}

# The image ships ffmpeg and libheif: convert Apple formats so every Matrix client can show them.
cfg["network"]["heic_conversion"] = True
cfg["network"]["video_transcoding"] = True

# Docker keeps the logs (bounded by the compose logging options); no second copy on disk.
cfg["logging"] = {
    "min_level": "info",
    "writers": [{"type": "stdout", "format": "pretty"}],
}

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
os.chmod(path, 0o600)
PY
echo "patched data/bridge/config.yaml"

if [ ! -f data/bridge/registration.yaml ]; then
	docker compose run --rm --no-deps bridge -c /data/config.yaml -g -r /data/registration.yaml
	echo "wrote data/bridge/registration.yaml"
fi

# ── Synapse signing key ───────────────────────────────────────────────────────
if [ ! -f data/synapse/signing.key ]; then
	docker compose run --rm --no-deps synapse run \
		--config-path=/config/homeserver.yaml --config-path=/data/secrets.yaml --generate-keys
fi

echo
echo "setup done. next: docker compose up -d, then create your Matrix user (README)."
