# Android permissions

IRC Mobile uses Android permissions for the following enabled features:

- `INTERNET`: connect to IRC and the official API.
- `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`: observe connectivity and reconnect when appropriate.
- `POST_NOTIFICATIONS`, `VIBRATE`: show IRC message and connection notifications.
- `RECORD_AUDIO`: record a voice message only after the user starts recording.
- `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
  `FOREGROUND_SERVICE_REMOTE_MESSAGING`, `RECEIVE_BOOT_COMPLETED`: support the
  configured background IRC and notification behavior.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: request background reliability only
  through an explicit user-facing flow where required.

Voice and video calling are disabled in this release.

The current release manifest must be reduced before Google Play submission so
that permissions for unavailable calling, camera, full-screen intent, or
payment functionality are not shipped. See `PLAY_CONSOLE_RELEASE_GUIDE.md` for
the audited blockers.
