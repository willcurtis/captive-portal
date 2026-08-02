#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${SCRIPT_DIR}"
[[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo ./scripts/update.sh" >&2; exit 1; }
[[ -f .env && -f runtime/Caddyfile ]] || { echo "Run sudo ./install.sh first" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Tracked files have local changes; update aborted" >&2; exit 1; }
OLD_PORTAL_CONTAINER="$(docker compose ps -q portal)"
OLD_CADDY_CONTAINER="$(docker compose ps -q caddy)"
OLD_PORTAL_IMAGE="$(docker inspect -f '{{.Image}}' "${OLD_PORTAL_CONTAINER}" 2>/dev/null || true)"
OLD_CADDY_IMAGE="$(docker inspect -f '{{.Image}}' "${OLD_CADDY_CONTAINER}" 2>/dev/null || true)"
OLD_PORTAL_TAG="$(docker inspect -f '{{.Config.Image}}' "${OLD_PORTAL_CONTAINER}" 2>/dev/null || true)"
OLD_CADDY_TAG="$(docker inspect -f '{{.Config.Image}}' "${OLD_CADDY_CONTAINER}" 2>/dev/null || true)"
git pull --ff-only
docker compose config --quiet
docker compose build --pull
docker compose up -d --remove-orphans
for attempt in {1..30}; do
  PORTAL_CONTAINER="$(docker compose ps -q portal)"
  [[ -n ${PORTAL_CONTAINER} && $(docker inspect -f '{{.State.Health.Status}}' "${PORTAL_CONTAINER}" 2>/dev/null || true) == healthy ]] && exit 0
  sleep 2
done
echo "Updated container did not become healthy; attempting image rollback" >&2
if [[ -n ${OLD_PORTAL_IMAGE} && -n ${OLD_CADDY_IMAGE} && -n ${OLD_PORTAL_TAG} && -n ${OLD_CADDY_TAG} ]]; then
  docker image tag "${OLD_PORTAL_IMAGE}" "${OLD_PORTAL_TAG}"
  docker image tag "${OLD_CADDY_IMAGE}" "${OLD_CADDY_TAG}"
  docker compose up -d --force-recreate
fi
echo "Inspect docker compose logs and verify rollback health" >&2
exit 1
