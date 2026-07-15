## Problem

Link the Issue or describe the reproducible user problem.

## Change

Explain the smallest behavior change made.

## Safety checklist

- [ ] No plaintext credential is written to logs, files, or command-line arguments.
- [ ] Upload and verification failures preserve the local recording.
- [ ] No automatic permanent deletion was introduced.
- [ ] Paths remain inside ScreenAgent-owned directories and reject reparse points.
- [ ] Installer, scheduled-task, and uninstaller behavior is unchanged or covered by tests.
- [ ] `tests\run_tests.ps1` passes.
- [ ] User-visible changes are recorded in `CHANGELOG.md`.
