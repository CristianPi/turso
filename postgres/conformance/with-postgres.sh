#!/usr/bin/env bash
# Runs a command with PG_DSN set to the URL of a PostgreSQL server.
#
#   ./with-postgres.sh sh -c 'echo "$PG_DSN"'
#
# If PG_DSN is already set, the command uses that server. Otherwise this
# script starts a throwaway PostgreSQL container with Docker, runs the
# command, and removes the container.
#
# The default is PostgreSQL 18.7, a release of the major version in
# postgres/version. The tag names the minor release because the tag "18"
# moves with each 18.x release and the mirror can serve an older 18.x, and
# the tests expect 18.7 behavior: 18.7 checks the row an INSERT ... ON
# CONFLICT DO UPDATE conflicts with against row policies before the DO
# UPDATE WHERE. To try another version locally, set POSTGRES_VERSION to a
# tag of the postgres Docker image, for example POSTGRES_VERSION=17.
set -euo pipefail

POSTGRES_VERSION="${POSTGRES_VERSION:-18.7}"
if [[ -z "${POSTGRES_IMAGE:-}" ]]; then
    POSTGRES_IMAGE="mirror.gcr.io/library/postgres:$POSTGRES_VERSION"
    # The mirror holds only the tags someone pulled through it recently.
    if [[ -z "${PG_DSN:-}" ]] && ! docker pull --quiet "$POSTGRES_IMAGE" >/dev/null 2>&1; then
        POSTGRES_IMAGE="docker.io/library/postgres:$POSTGRES_VERSION"
    fi
fi

if [[ -n "${PG_DSN:-}" ]]; then
    exec "$@"
fi

if ! docker info >/dev/null 2>&1; then
    echo "error: PG_DSN is not set and Docker is not running." >&2
    echo "Start Docker, or set PG_DSN to a PostgreSQL server, for example" >&2
    echo "PG_DSN=postgres://postgres@127.0.0.1:5432/postgres." >&2
    exit 2
fi

container=$(docker run --detach \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --env PGDATA=/pgdata/data \
    --tmpfs /pgdata \
    --publish 127.0.0.1::5432 \
    "$POSTGRES_IMAGE" \
    -c fsync=off \
    -c synchronous_commit=off \
    -c full_page_writes=off \
    -c wal_level=minimal \
    -c max_wal_senders=0 \
    -c autovacuum=off \
    -c jit=off \
    -c max_connections=500)
trap 'docker rm --force --volumes "$container" >/dev/null' EXIT

for _ in $(seq 1 300); do
    if docker exec "$container" pg_isready --host 127.0.0.1 --username postgres >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if ! docker exec "$container" pg_isready --host 127.0.0.1 --username postgres >/dev/null 2>&1; then
    echo "error: PostgreSQL in container $container did not start:" >&2
    docker logs "$container" >&2
    exit 1
fi

port=$(docker port "$container" 5432/tcp | head -n 1 | sed 's/.*://')
export PG_DSN="postgres://postgres@127.0.0.1:${port}/postgres"
echo "Using $POSTGRES_IMAGE at $PG_DSN" >&2
"$@"
