# Security

This repository supplies source code, not credentials or a hosted service.
Use personal tracking without a backend, or configure infrastructure you own.

## Reporting

Do not post credentials, user records, photos, database exports or personal
identifiers in public issues. Use GitHub's private vulnerability reporting if
it is enabled for the repository. Otherwise, open a minimal issue requesting a
private contact channel without including sensitive details.

## Before Publishing

- Review the exact staged tree and all history being pushed.
- Exclude local configuration, signing assets, device registries, private data,
  model outputs, backups, collaboration messages and diagnostic screenshots.
- Use synthetic fixtures and reserved example endpoints.
- Run the release guard and a redacting secret scanner. No automated scan can
  establish that arbitrary text or images contain no personal information.
- Review PR text, Actions logs, releases, artifacts and repository metadata too
  when changing the visibility of an existing repository.
- If a real credential has been exposed, revoke or rotate it at the provider;
  deleting its current file does not invalidate that credential.

## Runtime Boundaries

Goals and records are private by default. Sharing and AI operations require the
application's existing explicit consent and confirmation flows. Keep backend
authorization checks; hiding a UI element is not access control. Do not send
photos, other identities' content or unrelated history to model services.

Keep server configuration owner-readable only. Use distinct, revocable device
credentials. A public client endpoint is not a model API key: never embed model
secrets in the app. Keep user data and pending operations isolated by identity.
Test restore procedures against new, isolated paths rather than live data.
