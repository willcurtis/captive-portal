#!/usr/bin/env bash
set -Eeuo pipefail

readonly PORTAL_UID=10001
readonly PORTAL_GID=10001
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly SECRETS_DIR="${SCRIPT_DIR}/secrets"
readonly RUNTIME_DIR="${SCRIPT_DIR}/runtime"

log() { printf '[captive-portal] %s\n' "$*"; }
fail() { printf '[captive-portal] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run this installer as root: sudo ./install.sh"
fi

for command in docker curl openssl python3 install; do
  command -v "${command}" >/dev/null 2>&1 || fail "Required command not found: ${command}"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
docker info >/dev/null 2>&1 || fail "Docker is not running"
[[ -f "${SCRIPT_DIR}/compose.yaml" && -f "${SCRIPT_DIR}/package.json" ]] || fail "Run the installer from a complete repository clone"

prompt() {
  local variable_name=$1 label=$2 default_value=${3-} value
  if [[ -n ${!variable_name-} ]]; then return; fi
  if [[ -n ${default_value} ]]; then
    read -r -p "${label} [${default_value}]: " value </dev/tty
    printf -v "${variable_name}" '%s' "${value:-${default_value}}"
  else
    read -r -p "${label}: " value </dev/tty
    printf -v "${variable_name}" '%s' "${value}"
  fi
}

prompt_secret() {
  local variable_name=$1 label=$2 value
  if [[ -n ${!variable_name-} ]]; then return; fi
  read -r -s -p "${label}: " value </dev/tty
  printf '\n' >/dev/tty
  printf -v "${variable_name}" '%s' "${value}"
}

require_safe_value() {
  local label=$1 value=$2
  [[ -n ${value} ]] || fail "${label} cannot be empty"
  [[ ${value} != *$'\n'* && ${value} != *$'\r'* && ${value} != *'"'* ]] || fail "${label} contains unsupported characters"
}

write_env() { printf '%s="%s"\n' "$1" "$2" >>"${ENV_FILE}"; }

log "Collecting deployment configuration"
prompt PORTAL_DOMAIN "Portal DNS name" "wifi.example.com"
prompt PORTAL_BIND_IP "Static portal server IPv4 address" ""
prompt UNIFI_API_BASE_URL "UniFi Integration API base URL" "https://gateway.example.lan/proxy/network/integration/v1"
prompt UNIFI_SITE_SLUG "UniFi external portal site slug" "default"
prompt ALLOWED_SSIDS "Allowed SSID names (comma separated)" "Guest Network"
prompt AUTHORIZATION_MINUTES "Guest authorization duration in minutes" "480"
prompt TLS_MODE "Certificate mode: public-acme, mailinabox-dns01, or manual" "public-acme"

[[ ${PORTAL_DOMAIN} =~ ^[A-Za-z0-9.-]+$ ]] || fail "Portal DNS name is invalid"
[[ ${PORTAL_BIND_IP} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "Portal bind address must be IPv4"
[[ ${UNIFI_API_BASE_URL} == https://* ]] || fail "UniFi API URL must use HTTPS"
[[ ${UNIFI_SITE_SLUG} =~ ^[A-Za-z0-9_-]+$ ]] || fail "UniFi site slug is invalid"
[[ ${AUTHORIZATION_MINUTES} =~ ^[0-9]+$ ]] && (( AUTHORIZATION_MINUTES >= 1 && AUTHORIZATION_MINUTES <= 10080 )) || fail "Authorization duration must be 1-10080 minutes"
for pair in "Portal domain:${PORTAL_DOMAIN}" "UniFi URL:${UNIFI_API_BASE_URL}" "SSID:${ALLOWED_SSIDS}"; do
  require_safe_value "${pair%%:*}" "${pair#*:}"
done

prompt UNIFI_API_KEY_SOURCE "Path to a file containing the UniFi API key (leave blank to enter securely)" ""
if [[ -n ${UNIFI_API_KEY_SOURCE} ]]; then
  [[ -f ${UNIFI_API_KEY_SOURCE} ]] || fail "UniFi API key file does not exist"
  UNIFI_API_KEY="$(<"${UNIFI_API_KEY_SOURCE}")"
else
  prompt_secret UNIFI_API_KEY "UniFi API key"
fi
UNIFI_API_KEY="${UNIFI_API_KEY//$'\n'/}"
UNIFI_API_KEY="${UNIFI_API_KEY//$'\r'/}"
(( ${#UNIFI_API_KEY} >= 16 )) || fail "UniFi API key is too short"

prompt UNIFI_CA_SOURCE "Private CA/controller certificate PEM path (blank for public/system trust)" ""
CONTROLLER_CURL=(curl --fail --silent --show-error --connect-timeout 10 --max-time 20)
if [[ -n ${UNIFI_CA_SOURCE} ]]; then
  [[ -f ${UNIFI_CA_SOURCE} ]] || fail "Controller CA file does not exist"
  openssl x509 -in "${UNIFI_CA_SOURCE}" -noout >/dev/null 2>&1 || fail "Controller CA file is not a valid PEM certificate"
  read -r CONTROLLER_HOST CONTROLLER_PORT < <(python3 -c 'import sys,urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(u.hostname, u.port or 443)' "${UNIFI_API_BASE_URL}")
  openssl s_client -connect "${CONTROLLER_HOST}:${CONTROLLER_PORT}" -servername "${CONTROLLER_HOST}" \
    -CAfile "${UNIFI_CA_SOURCE}" -partial_chain -verify_hostname "${CONTROLLER_HOST}" -verify_return_error </dev/null >/dev/null 2>&1 \
    || fail "Controller certificate does not validate against the supplied PEM file"
  # curl lacks OpenSSL's partial-chain option; verification was completed explicitly above.
  CONTROLLER_CURL+=(--insecure)
fi

log "Validating the controller certificate, API key, and site list"
"${CONTROLLER_CURL[@]}" -H "X-API-Key: ${UNIFI_API_KEY}" "${UNIFI_API_BASE_URL}/info" >/dev/null || fail "Unable to authenticate to the UniFi Integration API"
SITES_JSON="$("${CONTROLLER_CURL[@]}" -H "X-API-Key: ${UNIFI_API_KEY}" "${UNIFI_API_BASE_URL}/sites")" || fail "Unable to retrieve UniFi sites"
if [[ -z ${UNIFI_SITE_ID-} ]]; then
  UNIFI_SITE_ID="$(python3 -c 'import json,sys; p=json.load(sys.stdin); d=p.get("data",p if isinstance(p,list) else []); print(d[0]["id"] if len(d)==1 else "")' <<<"${SITES_JSON}")"
fi
if [[ -z ${UNIFI_SITE_ID} ]]; then
  prompt UNIFI_SITE_ID "UniFi site UUID" ""
fi
[[ ${UNIFI_SITE_ID} =~ ^[0-9a-fA-F-]{36}$ ]] || fail "UniFi site UUID is invalid"
"${CONTROLLER_CURL[@]}" -H "X-API-Key: ${UNIFI_API_KEY}" "${UNIFI_API_BASE_URL}/sites/${UNIFI_SITE_ID}/clients?offset=0&limit=1" >/dev/null || fail "API key cannot read clients for the selected site"

MIAB_API_URL=""; MIAB_EMAIL=""; MIAB_PASSWORD=""; ACME_DNS_RESOLVER="1.1.1.1:53"
TLS_CERT_SOURCE=""; TLS_KEY_SOURCE=""
case ${TLS_MODE} in
  public-acme)
    CADDY_TEMPLATE="${SCRIPT_DIR}/deploy/caddy/public-acme.Caddyfile"
    ;;
  mailinabox-dns01)
    prompt MIAB_API_URL "Mail-in-a-Box API URL" "https://box.example.com/admin/dns/custom"
    prompt MIAB_EMAIL "Mail-in-a-Box automation account" ""
    prompt_secret MIAB_PASSWORD "Mail-in-a-Box automation account password"
    prompt ACME_DNS_RESOLVER "Authoritative DNS resolver (IP:port)" "1.1.1.1:53"
    [[ ${MIAB_API_URL} == https://* ]] || fail "Mail-in-a-Box API URL must use HTTPS"
    CADDY_TEMPLATE="${SCRIPT_DIR}/deploy/caddy/mailinabox-dns01.Caddyfile"
    ;;
  manual)
    prompt TLS_CERT_SOURCE "Full-chain portal certificate PEM path" ""
    prompt TLS_KEY_SOURCE "Portal private key PEM path" ""
    [[ -f ${TLS_CERT_SOURCE} && -f ${TLS_KEY_SOURCE} ]] || fail "Manual certificate and key files are required"
    openssl x509 -in "${TLS_CERT_SOURCE}" -noout -checkhost "${PORTAL_DOMAIN}" >/dev/null 2>&1 || fail "Certificate is invalid or does not cover ${PORTAL_DOMAIN}"
    CERT_PUB="$(openssl x509 -in "${TLS_CERT_SOURCE}" -pubkey -noout | openssl sha256)"
    KEY_PUB="$(openssl pkey -in "${TLS_KEY_SOURCE}" -pubout 2>/dev/null | openssl sha256)"
    [[ ${CERT_PUB} == "${KEY_PUB}" ]] || fail "Portal certificate and private key do not match"
    CADDY_TEMPLATE="${SCRIPT_DIR}/deploy/caddy/manual-certificate.Caddyfile"
    ;;
  *) fail "Unknown certificate mode: ${TLS_MODE}" ;;
esac

for pair in \
  "Mail-in-a-Box URL:${MIAB_API_URL}" \
  "Mail-in-a-Box account:${MIAB_EMAIL}" \
  "ACME DNS resolver:${ACME_DNS_RESOLVER}"; do
  [[ -z ${pair#*:} ]] || require_safe_value "${pair%%:*}" "${pair#*:}"
done

if [[ -e ${ENV_FILE} || -d ${SECRETS_DIR} || -d ${RUNTIME_DIR} ]]; then
  BACKUP_DIR="${SCRIPT_DIR}/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "${BACKUP_DIR}"
  [[ -e ${ENV_FILE} ]] && cp -p "${ENV_FILE}" "${BACKUP_DIR}/"
  [[ -d ${SECRETS_DIR} ]] && cp -a "${SECRETS_DIR}" "${BACKUP_DIR}/"
  [[ -d ${RUNTIME_DIR} ]] && cp -a "${RUNTIME_DIR}" "${BACKUP_DIR}/"
  log "Existing deployment configuration backed up to ${BACKUP_DIR}"
fi

umask 077
install -d -m 0700 "${SECRETS_DIR}" "${RUNTIME_DIR}" "${SCRIPT_DIR}/backups"
printf '%s' "${UNIFI_API_KEY}" >"${SECRETS_DIR}/unifi-api-key"
openssl rand -base64 48 >"${SECRETS_DIR}/cookie-secret"
printf '%s' "${MIAB_PASSWORD}" >"${SECRETS_DIR}/miab-password"
if [[ -n ${UNIFI_CA_SOURCE} ]]; then cp "${UNIFI_CA_SOURCE}" "${SECRETS_DIR}/unifi-ca.pem"; else : >"${SECRETS_DIR}/unifi-ca.pem"; fi
if [[ ${TLS_MODE} == manual ]]; then
  cp "${TLS_CERT_SOURCE}" "${SECRETS_DIR}/tls-cert.pem"
  cp "${TLS_KEY_SOURCE}" "${SECRETS_DIR}/tls-key.pem"
else
  : >"${SECRETS_DIR}/tls-cert.pem"; : >"${SECRETS_DIR}/tls-key.pem"
fi
cp "${CADDY_TEMPLATE}" "${RUNTIME_DIR}/Caddyfile"

chown "${PORTAL_UID}:${PORTAL_GID}" "${SECRETS_DIR}/unifi-api-key" "${SECRETS_DIR}/cookie-secret" "${SECRETS_DIR}/unifi-ca.pem"
chmod 0400 "${SECRETS_DIR}/unifi-api-key" "${SECRETS_DIR}/cookie-secret"
chmod 0444 "${SECRETS_DIR}/unifi-ca.pem"
chown root:root "${SECRETS_DIR}/miab-password" "${SECRETS_DIR}/tls-cert.pem" "${SECRETS_DIR}/tls-key.pem" "${RUNTIME_DIR}/Caddyfile"
chmod 0400 "${SECRETS_DIR}/miab-password" "${SECRETS_DIR}/tls-key.pem"
chmod 0444 "${SECRETS_DIR}/tls-cert.pem" "${RUNTIME_DIR}/Caddyfile"

: >"${ENV_FILE}"
write_env NODE_ENV production
write_env HOST 0.0.0.0
write_env PORT 3000
write_env PORTAL_BIND_IP "${PORTAL_BIND_IP}"
write_env PORTAL_DOMAIN "${PORTAL_DOMAIN}"
write_env PUBLIC_ORIGIN "https://${PORTAL_DOMAIN}"
write_env UNIFI_API_BASE_URL "${UNIFI_API_BASE_URL}"
write_env UNIFI_API_KEY_FILE /run/secrets/unifi_api_key
write_env UNIFI_SITE_ID "${UNIFI_SITE_ID}"
write_env UNIFI_SITE_SLUG "${UNIFI_SITE_SLUG}"
write_env UNIFI_CA_FILE "$([[ -n ${UNIFI_CA_SOURCE} ]] && printf /run/secrets/unifi_ca)"
write_env ALLOWED_SSIDS "${ALLOWED_SSIDS}"
write_env AUTHORIZATION_MINUTES "${AUTHORIZATION_MINUTES}"
write_env DATA_LIMIT_MBYTES 0
write_env RX_RATE_LIMIT_KBPS 0
write_env TX_RATE_LIMIT_KBPS 0
write_env TRANSACTION_TTL_SECONDS 300
write_env COOKIE_SECRET_FILE /run/secrets/cookie_secret
write_env COOKIE_SECURE true
write_env TRUST_PROXY true
write_env ENFORCE_CLIENT_IP true
write_env POST_AUTH_REDIRECT_URL ""
write_env MIAB_API_URL "${MIAB_API_URL}"
write_env MIAB_EMAIL "${MIAB_EMAIL}"
write_env ACME_DNS_RESOLVER "${ACME_DNS_RESOLVER}"
write_env TLS_MODE "${TLS_MODE}"
chmod 0600 "${ENV_FILE}"

cd "${SCRIPT_DIR}"
log "Validating Compose configuration"
docker compose config --quiet
log "Building and starting the portal"
docker compose build --pull
docker compose up -d --remove-orphans

log "Waiting for application health and TLS"
for attempt in {1..30}; do
  PORTAL_CONTAINER="$(docker compose ps -q portal)"
  if [[ -n ${PORTAL_CONTAINER} && $(docker inspect -f '{{.State.Health.Status}}' "${PORTAL_CONTAINER}" 2>/dev/null || true) == healthy ]]; then break; fi
  sleep 2
done
PORTAL_CONTAINER="$(docker compose ps -q portal)"
[[ -n ${PORTAL_CONTAINER} && $(docker inspect -f '{{.State.Health.Status}}' "${PORTAL_CONTAINER}" 2>/dev/null || true) == healthy ]] || fail "Portal application did not become healthy; run docker compose logs portal"

if [[ ${TLS_MODE} == manual ]]; then CURL_TLS=(--insecure); else CURL_TLS=(); fi
for attempt in {1..30}; do
  if curl --fail --silent --show-error "${CURL_TLS[@]}" --resolve "${PORTAL_DOMAIN}:443:${PORTAL_BIND_IP}" "https://${PORTAL_DOMAIN}/health/live" >/dev/null 2>&1; then
    log "Deployment successful: https://${PORTAL_DOMAIN}/guest/s/${UNIFI_SITE_SLUG}/"
    log "Certificate mode: ${TLS_MODE}; configuration: ${ENV_FILE}; secrets: ${SECRETS_DIR}"
    exit 0
  fi
  sleep 3
done
fail "HTTPS smoke test failed; inspect: docker compose logs caddy portal"
