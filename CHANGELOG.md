# Changelog

## 1.1.0 - Unreleased

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
- MIT license, contribution guide, privacy policy, security policy, support policy, and community templates.

### Changed

- Renamed the background worker to `auto_archive.ps1` to reflect non-destructive behavior.

## 1.0.0 - 2026-06-27

- Initial private Windows delivery package.
