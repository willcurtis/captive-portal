# The Tech Shed UniFi Captive Portal

A secure, self-hosted external captive portal for UniFi Network. It uses the official Network Integration API and API-key authentication, with a branded mobile-first interface and a Docker-based installer.

## Features

- Official `AUTHORIZE_GUEST_ACCESS` workflow
- Short-lived signed transactions and CSRF protection
- MAC address, guest state, SSID and optional source-IP validation
- Idempotent handling for captive-browser duplicate submissions
- Configurable authorization, data and bandwidth limits
- Strict controller TLS validation with private CA or pinned-certificate support
- HTTPS through public ACME, Mail-in-a-Box DNS-01, or supplied certificates
- Read-only container filesystem, dropped Linux capabilities and no-new-privileges
- Local assets, structured redacted logs, health checks, tests and CI

## Deployment architecture

```text
Guest device (Guest VLAN / Hotspot zone)
        |
        | HTTP captive redirect
        v
Caddy :80/:443  --->  Portal container :3000
        |                   |
        | ACME/certificate  | HTTPS + dedicated API key
        v                   v
Authoritative DNS      UniFi Integration API
```

The portal should be on a stable internal address. Guest devices reach only TCP 80/443 on that address before authorization. The guest SSID belongs on a dedicated routed VLAN in UniFi's Hotspot firewall zone—not on the portal server's native LAN.

## Supported host

- A current Debian or Ubuntu server with a static IPv4 address
- Docker Engine and Docker Compose v2 already installed and running
- Git, curl, OpenSSL and Python 3
- Inbound TCP 80/443 to the portal address
- Outbound HTTPS from the portal to the UniFi Console
- A UniFi Network release exposing **Control Plane → Integrations**

The installer does not install Docker or alter the host firewall. Those are host-level security decisions and should remain explicit.

## Quick installation

Clone directly into the intended production location:

```bash
sudo git clone https://github.com/willcurtis/captive-portal.git /opt/unifi-captive-portal
cd /opt/unifi-captive-portal
sudo ./install.sh
```

The interactive installer:

1. Validates dependencies and the Docker daemon.
2. Collects the portal address, UniFi API endpoint, SSID and certificate mode.
3. Validates the controller certificate before sending the API key.
4. Discovers the site UUID automatically when the controller has one site.
5. Checks that the API key can read clients for that site.
6. Creates root-protected runtime configuration and container-readable secrets.
7. Builds, starts and smoke-tests the HTTPS deployment.

Run it again to change configuration. Existing `.env`, `secrets/` and `runtime/` content is copied into a timestamped, root-only `backups/` directory first.

## Certificate modes

### `public-acme`

Caddy obtains a certificate using normal ACME HTTP-01/TLS-ALPN validation.

Use when:

- The portal hostname resolves publicly to an address forwarded to the portal.
- The certificate authority can reach TCP 80 or 443 from the internet.

This is the simplest mode but is usually unsuitable when the DNS record points only to an RFC 1918 address.

### `mailinabox-dns01`

Caddy uses a dedicated Mail-in-a-Box automation account to create DNS-01 challenge records. The password is stored only in `secrets/miab-password`, never in `.env` or Git.

Use when:

- The portal uses a publicly registered name with a private/internal address.
- Mail-in-a-Box is authoritative for the zone.
- A restricted automation account is available.

Restrict the account and API path as far as Mail-in-a-Box permits. Do not use a personal mailbox administrator credential.

### `manual`

The installer copies a supplied full-chain certificate and private key into protected Docker secrets. It validates certificate parsing, hostname coverage and public-key matching before deployment.

Use when:

- Certificates come from an internal public key infrastructure (PKI), enterprise ACME client, or separate automation system.
- All guest devices trust the issuing certificate authority.

Renewal is external in this mode. Re-run the installer after replacing the source certificate, or atomically replace the two secret files and recreate Caddy.

Never deploy a self-signed leaf certificate to unmanaged guest devices; captive network assistants will reject it.

## Controller certificate trust

For a publicly trusted UniFi certificate, leave the controller certificate path blank.

For a private controller certificate, supply either:

- the private CA certificate or chain, preferably; or
- the exact controller leaf certificate as a deliberate pin.

The installer uses OpenSSL hostname verification and partial-chain validation before making authenticated API requests. The application does not provide an option to disable TLS verification.

## UniFi configuration

Create a dedicated Integration API key in **Network → Control Plane → Integrations**. Store it in a temporary root-readable file for installation or paste it at the hidden prompt. Delete the temporary source after installation.

Recommended controller configuration:

- Dedicated guest VLAN and DHCP scope
- Network assigned to the built-in **Hotspot** firewall zone
- SSID security set appropriately for the venue
- **Hotspot Portal → Captive Portal** enabled
- Client isolation enabled
- External portal server set to the portal server IPv4 address
- Pre-authorization access limited to the portal IPv4 address and hostname

The resulting external path is:

```text
https://wifi.example.com/guest/s/default/
```

The API site UUID and external portal site slug are separate values. The UUID is discovered from `/integration/v1/sites`; the slug is usually `default`.

## Runtime files and permissions

The following are intentionally excluded from Git:

```text
.env                         root:root 0600
runtime/Caddyfile            root:root 0444
secrets/unifi-api-key        10001:10001 0400
secrets/cookie-secret        10001:10001 0400
secrets/unifi-ca.pem         10001:10001 0444
secrets/miab-password        root:root 0400
secrets/tls-cert.pem         root:root 0444
secrets/tls-key.pem          root:root 0400
```

Docker Compose mounts them through its secrets mechanism. Do not copy secrets into images, commit them, place them in shell history, or pass them as command-line arguments.

## Verification

```bash
cd /opt/unifi-captive-portal
sudo ./scripts/verify.sh
sudo docker compose logs --since=10m portal caddy
```

Then verify with a real device:

1. Join the guest SSID and receive an address from the guest VLAN.
2. Open an HTTP site to trigger captive detection.
3. Accept the terms and connect.
4. Confirm the success page and general DNS/HTTPS browsing.
5. Confirm the client becomes `GUEST` and `authorized: true` in UniFi.
6. Confirm guest-to-guest and guest-to-internal access remain blocked.

Test current iOS, Android, macOS and Windows captive network assistants before production launch.

## Updating and rollback

```bash
cd /opt/unifi-captive-portal
sudo ./scripts/update.sh
```

The update script refuses to overwrite tracked local changes, uses `git pull --ff-only`, rebuilds the images and waits for health. If the new portal does not become healthy, it retags the previous portal and Caddy images and recreates the prior containers.

Configuration backups are under `backups/`. They contain secrets and must remain root-only. Include `.env`, `runtime/`, `secrets/` and the Caddy data Docker volume in an encrypted operational backup. Test restoration periodically.

## Deployment checklist

Before release:

- [ ] CI, type-check, tests, production build and dependency audit pass
- [ ] Terms of Use and Privacy Notice are approved for the venue
- [ ] Dedicated API key has only the required scope
- [ ] Controller and portal certificate chains validate with correct hostnames
- [ ] DNS resolves consistently from guest and management networks
- [ ] Guest VLAN, DHCP, DNS, NTP, NAT and Hotspot policies are verified
- [ ] Pre-authorization rules expose only the portal and required infrastructure
- [ ] API-key and certificate rotation have been tested
- [ ] Encrypted backup and rollback procedure have been tested

Rollback triggers include failed authorization, HTTPS errors, loss of guest internet access, unexpected access to internal networks, or a sustained unhealthy container state.

## Local development

```bash
npm ci
npm run typecheck
npm test
npm run build
```

Unit tests do not contact a controller. Use an isolated SSID and test hostname for end-to-end testing.

## Health and logging

- `GET /health/live` verifies the process is serving.
- `GET /health/ready` verifies initialization without querying UniFi on every probe.
- Authorization logs contain a client ID, SSID and only the final two MAC octets.
- Cookies and CSRF tokens are redacted.
- Caddy access logging is disabled to avoid recording redirect query strings containing client MAC addresses.

Forward container logs to a protected log platform with an appropriate retention policy. Never enable broad request logging without redacting captive redirect parameters.

## License

[MIT](LICENSE)
