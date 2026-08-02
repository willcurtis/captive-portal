# Security Policy

## Reporting a vulnerability

Do not open a public issue containing credentials, client identifiers, certificates, private network details or an unpatched vulnerability. Contact the repository owner privately with reproduction steps and affected versions.

## Supported version

Only the current `main` branch and latest published release receive security fixes.

## Deployment responsibilities

Operators must:

- use a dedicated, least-privilege UniFi Integration API key;
- validate and rotate controller and portal certificates;
- keep `.env`, `secrets/`, `runtime/` and `backups/` out of Git;
- isolate guest networks and restrict pre-authorization access;
- keep Docker, the host operating system and portal images patched;
- replace the example legal text before public use; and
- avoid logging captive redirect URLs or unredacted client identifiers.

The application deliberately has no setting to disable TLS certificate verification.
