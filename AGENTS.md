MƏN TƏSDİQ ETMƏDƏN KOD YAZMA VƏ HEÇ BİR DƏYİŞİKLİK ETMƏ DIRNAQ İÇİNDƏ "TƏSDİQ EDİRƏM" cümləsin oxumadan kod yazma - sən.!

# Goguma — Agent Reference

Native Android IRC mobile application.

**Stack:** Kotlin + Jetpack Compose + Material 3 + Coroutines + StateFlow + native TLS sockets.

Goguma is not a React, Flutter, WebView, Tauri, or browser-based application. Keep all new application code native Android unless the task explicitly says otherwise.

---

## Agent Working Rules

* Read only files directly related to the task.
* Use targeted search such as `rg` before opening large files.
* Do not scan the entire repository without a clear reason.
* Make the smallest possible change.
* Do not perform unrelated refactors.
* Do not add dependencies unless explicitly required.
* Do not change UI layout, keyboard behavior, message order, reconnect behavior, or notification behavior unless the task specifically concerns them.
* Do not replace working native code with a new architecture.
* Do not edit bundled code under `third_party/` unless the task explicitly targets it.
* Do not claim a problem is fixed without verifying the affected code path.

### Wiki policy

Do not create or update wiki notes automatically.

Only write to the wiki when the user says exactly:

> Həll olundu, wikiyə qeyd et

When writing a wiki note, record only:

* exact affected file paths;
* confirmed root cause;
* minimal implemented fix;
* related source and target components;
* verification performed.

---

## Commands

Do not run build, install, or device commands automatically.

Forbidden unless explicitly requested:

```powershell
.\gradlew.bat assembleDebug
.\gradlew.bat build
.\gradlew.bat installDebug
.\gradlew.bat connectedAndroidTest
```

When verification is requested, use the narrowest relevant command:

```powershell
.\gradlew.bat test
.\gradlew.bat lint
```

Prefer a targeted test task or static inspection instead of running every Gradle task.

Never delete Gradle caches, regenerate the wrapper, upgrade Gradle, upgrade Kotlin, or change Android SDK versions as an attempted fix unless the task specifically requires it.

---

## Main Project Layout

```text
app/
  build.gradle.kts

  src/main/
    AndroidManifest.xml

    java/az/ircmobileaz/app/
      MainActivity.kt
      IrcForegroundService.kt
      AppVisibility.kt

      data/
        NativeIrcClient.kt
        NativeIrcSession.kt
        IrcParser.kt

      model/
        # Connection status, IRC targets, messages and UI state

      ui/
        IrcMobileApp.kt
        # Compose UI, chat screen, panels, dialogs and media UI

    res/
      drawable/
      mipmap-*/
      values/

  src/test/
    # Local JVM tests

  src/androidTest/
    # Android/device tests

third_party/
  # Bundled external code; do not modify by default
```

### Main files

* `MainActivity.kt` — Android activity, app startup, notification permission and IRC URI handling.
* `IrcForegroundService.kt` — keeps the IRC session alive and manages foreground notifications.
* `NativeIrcSession.kt` — application-level access to the active native IRC client.
* `NativeIrcClient.kt` — socket connection, IRC protocol handling, commands and state updates.
* `IrcParser.kt` — parses raw IRC protocol lines into structured values.
* `IrcMobileApp.kt` — main Jetpack Compose UI and user interactions.

Large files such as `NativeIrcClient.kt` and `IrcMobileApp.kt` must be searched before reading. Do not repeatedly load the full file.

---

## IRC Event Flow

Goguma currently uses a native state-driven flow:

```text
TLS socket
  → raw IRC line
  → IrcParser
  → NativeIrcClient protocol handling
  → immutable state update
  → StateFlow
  → ViewModel/UI collection
  → Jetpack Compose recomposition
```

### Protocol parsing

`IrcParser.kt` is responsible for parsing:

* IRCv3 message tags;
* optional prefix;
* command or numeric;
* middle parameters;
* trailing parameter.

The parser should not contain UI behavior or Android-specific logic.

### Protocol handling

`NativeIrcClient.kt` owns protocol behavior such as:

* socket connection and disconnection;
* TLS setup;
* IRC registration;
* CAP negotiation;
* SASL authentication;
* JOIN, PART, QUIT and KICK;
* PRIVMSG and NOTICE;
* NICK changes;
* channel topics;
* WHO, WHOIS and NAMES;
* ISUPPORT values;
* reconnect state;
* slash commands;
* message and channel state.

To add support for an IRC command:

1. Confirm that `IrcParser` already parses the raw line correctly.
2. Add handling in the relevant protocol section of `NativeIrcClient`.
3. Update the existing immutable state model.
4. Add or update a focused parser/protocol test.
5. Change Compose UI only when the command requires visible behavior.

Do not introduce a second IRC client, parser, socket, or duplicate state source.

---

## State Management

IRC and UI state are exposed through Kotlin flows.

Preserve the existing immutable update pattern:

```kotlin
_state.update { current ->
  current.copy(
    statusText = newStatus,
  )
}
```

Do not mutate lists or nested state objects in place when Compose depends on them.

Avoid patterns such as:

```kotlin
state.messages.add(message)
```

Instead, create a new collection:

```kotlin
state.copy(
  messages = state.messages + message,
)
```

### State rules

* Keep one authoritative IRC session.
* Do not create client instances inside Composables.
* Do not store activity or view references in the IRC client.
* Do not perform socket work on the main thread.
* Use structured coroutines with cancellation.
* Preserve the selected channel or private chat during unrelated state updates.
* Avoid emitting identical state repeatedly.
* Preserve stable IDs for conversations and messages.

---

## IRC Protocol Correctness

IRC handling must remain server-driven rather than hardcoded.

### ISUPPORT

Respect values announced by the server, including:

* `CHANTYPES`;
* `PREFIX`;
* `CASEMAPPING`;
* `CHANMODES`;
* nickname and channel length limits where supported.

Do not assume that every channel begins with `#`.

Do not hardcode only `@` and `+` as user prefixes. Use the server-provided `PREFIX` mapping.

### CAP and SASL

Preserve the correct negotiation order:

```text
CAP LS
→ CAP REQ
→ optional AUTHENTICATE/SASL
→ CAP END
→ normal registration completion
```

Rules:

* Do not send `CAP END` while SASL is still active.
* Handle multi-line capability listings.
* Respect IRC's line-length limit.
* Do not log passwords or SASL payloads.
* Keep SASL failure behavior explicit.
* Do not silently mark the connection authenticated after an error.

### Messages

* Preserve incoming message order.
* Do not insert duplicate messages after reconnect.
* Keep channel messages and private messages separated.
* Handle self-sent messages consistently.
* Preserve ACTION/CTCP formatting.
* Do not reorder history when adding new messages.
* Do not clear messages during unrelated nickname or topic updates.

### Reconnect

Reconnect changes must preserve:

* the latest active nickname;
* saved connection settings;
* selected conversation where possible;
* joined-channel intent;
* notification and foreground-service state.

Do not create parallel reconnect loops.

---

## Foreground Service and Notifications

`IrcForegroundService.kt` keeps the IRC session active while the application is backgrounded.

Critical rules:

* Do not start a second IRC client from the service.
* Use the client supplied by `NativeIrcSession`.
* Keep foreground notification updates lightweight.
* Do not recreate the notification for unchanged state.
* Preserve notification permission handling for supported Android versions.
* Do not stop the IRC session merely because `MainActivity` is recreated.
* Respect explicit disconnect or stop actions.
* Keep notification target IDs stable.
* Do not expose message contents in notifications when the related privacy setting disables them.

Changes to connection status, unread counts, mentions, private messages or selected targets may affect notifications and must be checked together with the foreground service.

---

## Jetpack Compose Rules

### Side effects

Use the correct API for the effect:

* `LaunchedEffect` for suspend work tied to composition;
* `DisposableEffect` for registration requiring cleanup;
* `rememberCoroutineScope` for user-triggered operations;
* lifecycle-aware flow collection for screen state.

Do not launch network operations directly during composition.

Bad:

```kotlin
@Composable
fun Screen() {
  client.connect()
}
```

Correct:

```kotlin
LaunchedEffect(connectionKey) {
  client.connect()
}
```

Every listener, observer, player, socket callback or nested coroutine created by a screen must have a cleanup path.

### Stable list identity

For message, member and channel lists, use stable keys:

```kotlin
items(
  items = messages,
  key = { it.id },
) { message ->
  MessageItem(message)
}
```

Do not use the list index as a key when items can be inserted, removed or reordered.

### Keyboard and scrolling

Keyboard, composer and history behavior are sensitive.

Do not change these during unrelated tasks:

* `windowSoftInputMode`;
* IME padding;
* composer height;
* focus behavior;
* automatic scrolling;
* message ordering;
* history insertion position;
* dialog positioning.

When fixing a keyboard issue, verify that:

* the composer remains visible;
* sending a message does not dismiss focus unexpectedly;
* opening panels does not reorder messages;
* returning from the background does not jump the history position;
* dialogs are not incorrectly pushed by IME animation.

---

## External URLs and Media Safety

Never make automatic HTTP requests to arbitrary URLs posted in IRC messages.

Opening or probing an arbitrary URL can expose the user's IP address.

Before loading remote media, avatars, previews or metadata:

1. Reuse the existing trust, cache or approved-origin logic.
2. Prefer already cached content.
3. Do not bypass safety checks with a direct HTTP request.
4. Fall back to a plain link when the origin is not trusted.

Do not introduce direct network calls from Composables.

### External links

A URL posted by another IRC user must not be opened without user confirmation.

Do not directly launch a browser intent from a clickable chat message.

The UI should:

1. display the destination URL;
2. request confirmation;
3. open the URL only after explicit approval;
4. allow cancellation without side effects.

IRC, `javascript:`, `file:`, `content:` and other non-HTTP schemes must be validated separately. Do not pass an arbitrary scheme directly to Android intents.

---

## Media and Playback

Media components must respect Android lifecycle and resource cleanup.

* Release `MediaPlayer` and similar resources.
* Stop playback when explicitly requested.
* Avoid creating multiple players for the same stream.
* Do not block the main thread while probing media.
* Preserve cached-only behavior where it prevents unexpected external requests.
* Do not restart playback on every recomposition.
* Handle invalid URLs without crashing the chat screen.

Media fixes must not alter message order, composer behavior or IRC connectivity.

---

## Testing

Tests should focus on the smallest affected layer.

### Parser tests

Add parser tests for:

* IRCv3 tags;
* prefix parsing;
* numeric replies;
* missing trailing values;
* malformed lines;
* Unicode;
* empty parameters.

### Protocol tests

Add protocol tests for:

* CAP negotiation;
* SASL success and failure;
* dynamic `CHANTYPES`;
* dynamic `PREFIX`;
* JOIN, PART, QUIT and KICK;
* nickname changes;
* reconnect nickname preservation;
* message deduplication;
* channel and private-message routing.

### UI tests

Add Compose or Android tests only when behavior cannot be verified at the parser or state level.

Do not replace a focused unit test with a full device test.

When a test fails:

* identify whether it is an existing failure or caused by the current change;
* do not weaken assertions merely to make the test pass;
* do not remove tests without an explicit reason;
* report tests that were not run.

---

## Android Manifest and Permissions

Do not add permissions without a concrete feature requirement.

Sensitive areas include:

* `INTERNET`;
* `POST_NOTIFICATIONS`;
* foreground-service permissions;
* storage or media permissions;
* exported activities and services;
* URL intent filters.

Rules:

* keep services non-exported unless external access is required;
* avoid broad storage permissions;
* do not enable cleartext traffic for new hosts without an explicit requirement;
* validate incoming `irc:`, `ircs:` and `irc+ssl:` URI data;
* do not include credentials in deep links or logs.

---

## Gradle and Dependencies

* Keep dependency versions unchanged during unrelated tasks.
* Do not migrate build scripts.
* Do not regenerate Gradle wrapper files.
* Do not upgrade Compose BOM, Kotlin, AGP or Android SDK as a generic fix.
* Do not add a library when the Android/Kotlin standard APIs already solve the task.
* Do not edit generated build output.
* Never commit files from `.gradle/`, `build/` or `app/build/`.

---

## Comments

Comments should explain why a non-obvious constraint exists, not restate the code.

Good:

```kotlin
// Preserve the server-provided prefix because IRC networks use different mode mappings.
```

Bad:

```kotlin
// Set the prefix.
```

Keep comments short and understandable without knowledge of the current task or previous implementation.

Do not leave comments such as:

* “fixed by agent”;
* “temporary AI change”;
* “old version”;
* “new logic”;
* “changed because user asked”.

---

## Definition of Done

A task is complete only when:

* the root cause is identified;
* the smallest relevant code path is changed;
* unrelated behavior is preserved;
* IRC protocol rules remain valid;
* state updates remain immutable and lifecycle-safe;
* no arbitrary external URL is automatically requested or opened;
* relevant tests or static checks are completed when permitted;
* commands not run are reported honestly;
* no build is run unless explicitly requested;
* the wiki is untouched unless the explicit wiki phrase was provided.
