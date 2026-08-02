#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${SCRIPT_DIR}"
[[ -f .env ]] || { echo "Missing .env; run the installer first" >&2; exit 1; }
set -a; source ./.env; set +a
docker compose config --quiet
docker compose ps
docker compose exec -T portal node -e "fetch('http://127.0.0.1:3000/health/live').then(r=>{if(!r.ok)process.exit(1);return r.text()}).then(console.log)"
if [[ ${TLS_MODE-} == manual ]]; then CURL_TLS=(--insecure); else CURL_TLS=(); fi
curl --fail --silent --show-error "${CURL_TLS[@]}" --resolve "${PORTAL_DOMAIN}:443:${PORTAL_BIND_IP}" "https://${PORTAL_DOMAIN}/health/live"
printf '\nVerification passed for https://%s\n' "${PORTAL_DOMAIN}"
