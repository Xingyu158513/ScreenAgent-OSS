# Repository guidance

- Preserve Windows PowerShell 5.1 compatibility.
- Keep the default workflow non-destructive.
- Never add automatic permanent deletion.
- Never put plaintext passwords, tokens, private URLs, recordings, rclone configs, or real user logs in the repository.
- Remote verification must fail closed and retain the local file.
- File movement must remain inside the configured ScreenAgent roots and reject reparse points.
- Update tests and security documentation for changes to credentials, uploads, paths, scheduled tasks, install, or uninstall behavior.
- Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run_tests.ps1` before committing.
