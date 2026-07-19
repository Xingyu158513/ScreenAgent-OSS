# Changelog

## 1.1.0-rc2 - 2026-07-19

### Security

- Removed automatic permanent deletion from the public build.
- Legacy delete mode now fails closed to verified move.
- WebDAV passwords are passed to `rclone obscure -` through standard input instead of plaintext command-line arguments.
- Added a dedicated, current-user-only rclone configuration and HTTPS-only generic WebDAV validation.
- Added tested raw-directory and reparse-point boundaries.
- Uninstaller no longer offers recursive deletion of recordings, logs, or configuration.

### Added

- Dependency-free PowerShell safety tests.
- Windows CI.
- A deterministic temporary-profile acceptance harness for install, failed upload retention, verified move, and uninstall data preservation.
- A network-disabled Windows Sandbox runner for the same packaged-artifact acceptance flow.
- MIT license, contribution guide, privacy policy, security policy, support policy, and community templates.

### Changed

- Split the previous all-purpose worker into a bounded `session_worker.ps1`, an explicit one-shot `recover_pending.ps1`, and a shared archive module.
- Isolated legacy scheduled-task migration from runtime security helpers.
- Removed `RunMode`, `current_session.json`, and runtime `task_name` configuration.
- Acceptance-only overrides are restricted to an explicit root under the Windows temporary directory.
- Removed the login-triggered permanent scanner. Recording now starts a hidden, bounded session worker that exits after processing, timeout, or a fatal configuration error.
- Upgrades safely stop and unregister known legacy ScreenAgent tasks and quarantine the old `auto_upload_delete.ps1` without touching recordings, configuration, logs, or sessions.

## 1.0.0 - 2026-06-27

- Initial private Windows delivery package.
