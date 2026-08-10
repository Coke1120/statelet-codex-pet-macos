# Security policy

Statelet is a local macOS lifecycle companion for Codex. Security reports are
welcome for the current `main` branch and the latest published release.

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** flow for this repository.
Please do not open a public issue for an unpatched vulnerability.

Include the affected version or commit, macOS version, impact, reproduction
steps, and any proposed mitigation. Remove access tokens, private file paths,
personal animation media, and other sensitive data from reports and logs.

Maintainers will acknowledge a complete report as soon as practical, assess
severity, coordinate a fix and disclosure timeline, and credit reporters who
want attribution. Please allow a reasonable remediation period before public
disclosure.

## Scope notes

Statelet reads local Codex lifecycle state, manages files under the current
user's Application Support directory, and installs user-level launch agents.
Reports involving path validation, unsafe replacement or removal, hook merging,
process execution, media parsing, or sensitive-data disclosure are especially
useful.

Ad-hoc signing is intended for personal local builds. It is not equivalent to
Developer ID signing or notarization and should not be reported as a signing
bypass by itself.
