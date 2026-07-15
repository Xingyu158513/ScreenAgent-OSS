# Privacy

ScreenAgent runs locally. The project does not operate a server and does not collect telemetry.

When cloud mode is enabled, recording files are sent directly from the user's computer to the WebDAV destination configured in rclone. The maintainer does not receive those files or credentials.

ScreenAgent stores its dedicated rclone configuration at `%USERPROFILE%\ScreenAgent\config\rclone.conf` and restricts the file to the current Windows user. This file still contains reversible credential material and must remain private.

Local logs may contain recording titles, categories, timestamps, local paths, remote paths, file sizes, and error messages. Review and redact logs before attaching them to a GitHub Issue. Never publish:

- rclone configuration files;
- WebDAV usernames or application passwords;
- private recording files;
- personal names embedded in titles or paths;
- private server URLs or access tokens.

Uninstalling ScreenAgent preserves recordings, logs, sessions, and configuration so that user data is not lost unexpectedly.
