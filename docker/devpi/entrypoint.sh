#!/bin/sh

set -eu

SERVERDIR=${DEVPI_SERVERDIR:-/data/server}
HOST=${DEVPI_HOST:-0.0.0.0}
PORT=${DEVPI_PORT:-3141}
INIT_ARGS=${DEVPI_INIT_ARGS:-}

mkdir -p "$SERVERDIR"

if [ ! -f "$SERVERDIR/.serverversion" ]; then
  devpi-init --serverdir "$SERVERDIR" $INIT_ARGS
fi

exec devpi-server --serverdir "$SERVERDIR" --host "$HOST" --port "$PORT"
