#!/bin/sh
# Bring the prescriptive proxy stack (compose.yaml) up or down for hard-mode
# testing, and map the four corporate hostnames at 127.0.0.1 so the machine
# under test resolves them exactly as it would with corporate DNS.
#
#   sh tests/hard/stack.sh up      # .env + compose up + wait for readiness
#   sh tests/hard/stack.sh wait    # poll readiness only
#   sh tests/hard/stack.sh logs    # per-vhost nginx access logs (routing evidence)
#   sh tests/hard/stack.sh down    # compose down -v + remove the hosts entries
#
# Port 80 is deliberate, not cosmetic: nginx forwards `Host $host`, which
# carries no port, so verdaccio and devpi would mint absolute URLs without it
# and every tarball fetch would 404. Adding hosts entries needs root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

PROJECT=supply-gate-hard
PORT=80
HOSTS_MARKER="# supply-gate hard-mode test"
PROXY_HOSTS="npm-proxy.corp.example pypi-proxy.corp.example go-proxy.corp.example cargo-proxy.corp.example"

compose() {
  # --env-file is explicit so a developer's own .env never leaks into the run.
  (cd "$REPO_ROOT" && docker compose -p "$PROJECT" --env-file "$REPO_ROOT/.env.hard-test" "$@")
}

write_env() {
  cat >"$REPO_ROOT/.env.hard-test" <<ENVEOF
NGINX_HTTP_PORT=$PORT

NGINX_IMAGE=nginx:1.27-alpine
VERDACCIO_IMAGE=verdaccio/verdaccio:6
ATHENS_IMAGE=gomods/athens:latest
KELLNR_IMAGE=ghcr.io/kellnr/kellnr:5

NPM_PROXY_HOSTNAME=npm-proxy.corp.example
PYPI_PROXY_HOSTNAME=pypi-proxy.corp.example
GO_PROXY_HOSTNAME=go-proxy.corp.example
CARGO_PROXY_HOSTNAME=cargo-proxy.corp.example

# ATHENS_GLOBAL_ENDPOINT is deliberately NOT set here: the lane should exercise
# the endpoint compose.yaml ships with, not one only the test gets right.
KELLNR_HOSTNAME=cargo-proxy.corp.example
ENVEOF
}

require_port_free() {
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|[:.])$PORT\$"; then
      echo "ERROR: port $PORT is already in use; the stack needs it (see the header comment)" >&2
      return 1
    fi
  fi
  return 0
}

add_hosts() {
  remove_hosts
  for h in $PROXY_HOSTS; do
    printf '127.0.0.1 %s %s\n' "$h" "$HOSTS_MARKER" >>/etc/hosts
  done
  printf 'hosts entries added:\n'
  grep -F "$HOSTS_MARKER" /etc/hosts | sed 's/^/  /'
}

remove_hosts() {
  [ -w /etc/hosts ] || return 0
  grep -vF "$HOSTS_MARKER" /etc/hosts >/etc/hosts.sg-tmp 2>/dev/null && \
    cat /etc/hosts.sg-tmp >/etc/hosts
  rm -f /etc/hosts.sg-tmp
  return 0
}

# Ready = nginx routed us to the right upstream and the upstream answered at
# all. A 4xx from a live registry is still proof of routing; 502/504 is not.
probe() {
  curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$1$2" 2>/dev/null || echo 000
}

wait_ready() {
  printf 'waiting for the proxy stack (up to 240s)\n'
  i=0
  while [ "$i" -lt 80 ]; do
    npm_code=$(probe npm-proxy.corp.example /-/ping)
    pypi_code=$(probe pypi-proxy.corp.example /root/pypi/+simple/)
    go_code=$(probe go-proxy.corp.example /healthz)
    cargo_code=$(probe cargo-proxy.corp.example /)
    ok=1
    for c in "$npm_code" "$pypi_code" "$go_code" "$cargo_code"; do
      case "$c" in
        2*|3*|4*) ;;
        *) ok=0 ;;
      esac
    done
    if [ "$ok" = "1" ]; then
      printf 'stack ready  npm=%s pypi=%s go=%s cargo=%s\n' \
        "$npm_code" "$pypi_code" "$go_code" "$cargo_code"
      return 0
    fi
    # A crash-looping backend never becomes ready, and nginx refuses to load
    # its whole config when any one upstream name does not resolve -- so one
    # bad service takes all four vhosts down. Say so after a minute instead of
    # burning the full timeout on a stack that cannot recover.
    if [ "$i" -gt 20 ] && \
       compose ps --format '{{.Name}} {{.State}}' 2>/dev/null | grep -qi 'restarting'; then
      printf 'a container is not staying up:\n' >&2
      compose ps >&2
      compose logs --tail 40 >&2
      return 1
    fi
    i=$((i + 1))
    sleep 3
  done
  printf 'STACK NOT READY  npm=%s pypi=%s go=%s cargo=%s\n' \
    "$npm_code" "$pypi_code" "$go_code" "$cargo_code" >&2
  compose ps >&2 || true
  compose logs --tail 60 >&2 || true
  return 1
}

case "${1:-}" in
  up)
    require_port_free || exit 1
    write_env
    add_hosts
    compose up -d --build || exit 1
    wait_ready || exit 1
    compose ps
    ;;
  wait)
    wait_ready || exit 1
    ;;
  logs)
    for f in npm-proxy pypi-proxy go-proxy cargo-proxy; do
      printf '\n---- /var/log/nginx/%s.access.log ----\n' "$f"
      compose exec -T nginx sh -c "cat /var/log/nginx/$f.access.log 2>/dev/null" || true
    done
    ;;
  log)
    # One vhost's access log on stdout, nothing else: the assertions in
    # scenario.sh grep this to prove which requests nginx actually routed.
    compose exec -T nginx sh -c "cat /var/log/nginx/${2:-npm-proxy}.access.log 2>/dev/null" || true
    ;;
  down)
    compose down -v --remove-orphans 2>/dev/null || true
    remove_hosts
    rm -f "$REPO_ROOT/.env.hard-test"
    ;;
  *)
    echo "usage: sh tests/hard/stack.sh up|wait|logs|log <vhost>|down" >&2
    exit 2
    ;;
esac
