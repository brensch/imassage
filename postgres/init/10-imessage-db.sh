#!/bin/sh
# Runs once, when the data directory is first initialised. Synapse gets the default database;
# the bridge gets its own, owned by the same role.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
	-c "CREATE DATABASE imessage OWNER $POSTGRES_USER;"
