# Security policy

## Supported version

Security fixes are provided for the latest published release. Older releases should be upgraded before reporting a problem.

## Reporting a vulnerability

Do not open a public Issue for vulnerabilities involving credentials, unintended file movement, path traversal, scheduled-task replacement, recursive deletion, or exposure of private recording metadata.

Use GitHub private vulnerability reporting when it is available. If it is unavailable, open a public Issue containing only the words `Security contact requested`; do not include exploit details, credentials, logs, or private paths. The maintainer will provide a private contact channel.

Expected acknowledgement: within 72 hours. A status update should follow within seven days.

## Security boundaries

- ScreenAgent never automatically permanently deletes recordings.
- A remote upload is considered verified only when the remote listing succeeds and a same-name, same-size file exists.
- Same-name and same-size verification is not a cryptographic integrity proof because many WebDAV providers do not expose hashes.
- The local source must be a normal file inside `recordings\raw`; reparse points are rejected.
- Unsupported or legacy cleanup modes fail closed to verified move.
- The uninstaller preserves recordings, logs, sessions, and configuration.
- WebDAV credentials are managed by rclone. Obscured rclone passwords are reversible and the rclone configuration must remain private.
- ScreenAgent uses a dedicated rclone config with inherited permissions removed; generic WebDAV URLs must use HTTPS.

## Out of scope

- Security of OBS Studio, rclone, Windows Task Scheduler, or a WebDAV provider.
- Recovery of credentials or recordings deleted manually by the user.
- Guarantees against a malicious process already running as the same Windows user.
