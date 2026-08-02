#!/bin/sh
set -eu

MIAB_PASSWORD="$(cat /run/secrets/miab_password)"
export MIAB_PASSWORD
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
