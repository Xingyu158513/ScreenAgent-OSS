# Contributing

Thank you for helping improve ScreenAgent.

## Before opening an Issue

- Search existing Issues.
- Remove credentials, private URLs, usernames, recording titles, and personal paths from logs.
- State the Windows, PowerShell, OBS, and rclone versions.
- Describe whether the problem occurred before upload, during remote verification, or during local movement.

## Pull requests

1. Link a real Issue or explain the user-visible problem.
2. Keep the default behavior non-destructive.
3. Add or update tests for password handling, path boundaries, remote verification, scheduled tasks, or uninstall behavior when relevant.
4. Run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run_tests.ps1
   ```

5. Update `CHANGELOG.md` for user-visible changes.

Changes that add automatic permanent deletion, silent credential export, arbitrary executable downloads, or processing outside the ScreenAgent root require a separate public design discussion and will not be enabled by default.

Maintainer response targets, Issue lifecycle, and release gates are documented in `MAINTENANCE.md`.
