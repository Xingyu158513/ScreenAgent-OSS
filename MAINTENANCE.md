# Maintenance policy

ScreenAgent is maintained as a safety-sensitive Windows utility. Public activity should reflect real user problems and real engineering work; do not create artificial Issues, releases, downloads, or endorsements.

## Response targets

- Security contact request: acknowledge within 72 hours.
- New bug report: first triage within seven days.
- Data-loss or credential-risk report: stop normal feature work until scope and mitigation are understood.
- Feature request: accept, decline, or request evidence within fourteen days when possible.

These are best-effort targets, not a paid support commitment.

## Issue lifecycle

1. Confirm the report is redacted and reproducible.
2. Label the affected boundary: `credentials`, `upload`, `verification`, `local-files`, `scheduled-task`, `install`, or `uninstall`.
3. Record the expected safe behavior before changing code.
4. Link the fix to the Issue.
5. Add a regression test that fails before the fix and passes after it.
6. Close the Issue only after CI passes and the user-visible result is documented.

## Release gate

A release requires:

- a clean working tree;
- all dependency-free safety tests passing on Windows CI;
- no plaintext credentials, user paths, recordings, logs, or rclone configs in the repository or archive;
- an updated changelog;
- a verified SHA-256 file for the Windows archive;
- manual installation, OBS launch, scheduled-task, WebDAV upload, verification-failure, local-move, and uninstall checks on a disposable Windows account;
- confirmation that recordings and configuration survive uninstall.

Release candidates use `-rcN`. Stable tags are created only after the manual integration checklist is complete.

Before the disposable-account integration check, maintainers can run `tests/acceptance/run_acceptance.ps1` against the release archive. This deterministic harness uses a temporary profile and a fake rclone endpoint; it does not replace a separate Windows account or VM. When Windows Sandbox is available, `tests/windows-sandbox/run_windows_sandbox.ps1` repeats the packaged-artifact check in a fresh, network-disabled Windows instance and writes its evidence under `dist/windows-sandbox-output`.

## Routine maintenance

At least monthly while the project is active:

- review open Issues and stale requests;
- review OBS and rclone release notes for breaking changes;
- rerun the safety suite on supported Windows versions;
- inspect GitHub Actions permissions and pinned workflow actions;
- review privacy and security documentation against current behavior;
- record genuine fixes and release notes.

## Evidence to report

Useful public maintenance evidence includes:

- median first-response time for real Issues;
- number of reproducible bugs closed with regression tests;
- external contributors and reviewed pull requests;
- releases tied to closed Issues;
- Windows CI pass history;
- real release downloads and independent test machines;
- security reports resolved without exposing user data.

Stars may show interest, but they do not replace usage, issue triage, reviewed fixes, or release history.
