# IRC Mobile — GitHub və Google Play sənəd paketi

Son yenilənmə: 2026-07-22

Bu fayldakı mətnlər GitHub repository və Google Play Console üçün kopyala-yapışdır şablonlarıdır. `[PLACEHOLDER]` hissələrini real məlumatla dəyiş. Tətbiqin real davranışına uyğun olmayan heç bir iddia yazma.

## 1. Tövsiyə edilən GitHub faylları

Repository kökündə bunlar olmalıdır:

```text
README.md
LICENSE
NOTICE.md
UPSTREAM_NOTICE.md
MODIFICATIONS.md
SOURCE_CODE_OFFER.md
PRIVACY.md
TERMS.md
ACCOUNT_DELETION.md
CHILD_SAFETY.md
SECURITY.md
SUPPORT.md
```

Mövcud `LICENSE` faylındakı AGPLv3 mətnini dəyişmə və ya qısaltma. Upstream Goguma notice və tətbiq mağazası ilə bağlı əlavə şərtlər yalnız həqiqətən tətbiq edilirsə və onların orijinal mətnləri qorunursa saxlanmalıdır.

## 2. Hazır `README.md` mətni

```markdown
# IRC Mobile

IRC Mobile is an independent modified mobile IRC client based on the original [Goguma](https://codeberg.org/emersion/goguma) project.

This repository contains the corresponding source code for the modified Android client distributed as IRC Mobile. It must not be represented as the original Goguma application. The upstream Goguma authors are not responsible for this modified application, hosted service or production infrastructure.

## Features

- IRC channels and private messages
- Background IRC connection support
- Message notifications
- User-initiated voice message recording
- Profile pictures and media sharing where available
- Channel member and moderation tools
- IRCv3 and bouncer-related functionality
- TLS transport support where enabled by the server

Voice and video calling are disabled and are not offered in this release.

## Service architecture

The official hosted service uses:

- the IRC Mobile Android client in this repository;
- the official IRC Mobile API service;
- an IRC service based on a modified InspIRCd 4.11.0 deployment;
- configured notification and media infrastructure.

The production API, IRC server deployment and private infrastructure are separate from the mobile client unless their source code is explicitly included in this repository. Production credentials, signing keys, API secrets, database credentials and private user data are not included.

## Source code and releases

Repository:

https://github.com/kurt-19/goguma-mod

Matching source release for version 1.0.0:

https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0

Each Google Play binary must have a matching source tag containing the exact client source used to create that release.

## License

The Goguma-based mobile client is distributed under GNU Affero General Public License version 3 (AGPLv3), subject to the preserved upstream notices and any applicable upstream additional terms included in this repository.

See:

- `LICENSE`
- `NOTICE.md`
- `UPSTREAM_NOTICE.md`
- `MODIFICATIONS.md`
- `SOURCE_CODE_OFFER.md`

Third-party components remain subject to their respective licenses.

## Privacy and user safety

- Privacy Policy: [PUBLIC PRIVACY URL]
- Terms of Use: [PUBLIC TERMS URL]
- Account/Data Deletion: [PUBLIC DELETION URL]
- Child Safety Standards: [PUBLIC CHILD SAFETY URL]
- Support: [SUPPORT EMAIL OR URL]
- Abuse reports: [ABUSE EMAIL OR URL]

## Build

This is a Flutter Android project. Use a compatible Flutter SDK and Android toolchain. Do not commit production signing files or secrets.

Before creating a release, configure your own Android upload keystore outside version control and verify that all runtime permissions match the enabled features.

## No warranty

This software is provided without warranty to the extent permitted by applicable law.
```

## 3. Hazır `NOTICE.md` mətni

```markdown
# Notice

IRC Mobile is an independent modified mobile IRC client based on the original Goguma project.

Original upstream project:

https://codeberg.org/emersion/goguma

Modified source repository:

https://github.com/kurt-19/goguma-mod

Matching source release:

https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0

This release includes user-interface changes, notification and background behavior, profile and media integrations, voice messages, IRCv3/bouncer-related support, channel controls, stability fixes and other modifications documented in `MODIFICATIONS.md`.

Voice and video calling are disabled and are not offered in this release. Call-related code that may remain in the source is not presented as an available application feature.

The upstream Goguma authors are not responsible for IRC Mobile, its modifications, hosted API, IRC service, user content or production infrastructure.

The Goguma-based client source is distributed under GNU AGPLv3 with preserved upstream notices and applicable upstream additional terms. Third-party components remain under their own licenses.
```

## 4. Hazır `UPSTREAM_NOTICE.md` mətni

```markdown
# Upstream notice

IRC Mobile is based on the original Goguma project:

https://codeberg.org/emersion/goguma

This repository is a modified version maintained independently at:

https://github.com/kurt-19/goguma-mod

The modified application must not be represented as the original Goguma application. The upstream project and its authors do not operate, endorse or provide support for IRC Mobile unless they explicitly state otherwise.

Upstream copyright notices, license notices and applicable additional terms must remain intact.
```

## 5. Hazır `MODIFICATIONS.md` mətni

```markdown
# Modification notice — IRC Mobile 1.0.0

- Application: IRC Mobile
- Version: 1.0.0
- Source tag: v1.0.0
- Modification notice date: [RELEASE DATE]
- Upstream: https://codeberg.org/emersion/goguma
- Modified repository: https://github.com/kurt-19/goguma-mod

## Main modifications

- Changed the Android application identity and IRC Mobile branding.
- Changed application navigation, entry flow and visual presentation.
- Added and changed notification and background connection behavior.
- Added profile picture and media integration with the official API service.
- Added user-initiated voice message recording and upload.
- Added channel, private-message and moderation-related controls.
- Added a separate Status area and routing for server information.
- Added IRCv3 and bouncer-related compatibility work.
- Added message reply input behavior without requiring IRC reply capabilities.
- Added channel disable/enable behavior without closing the IRC channel.
- Added time-based hiding of channel events.
- Added IRC synchronization compatibility and stability fixes.
- Added general UI, keyboard, performance and lifecycle improvements.

## Disabled features

Voice and video calling are disabled and are not available in this release.

## Hosted service integration

The client integrates with the official IRC Mobile API and an IRC service based on a modified InspIRCd 4.11.0 deployment. Production backend/server implementation, infrastructure credentials, signing material and private data are not included unless explicitly stated.

## License reminder

The modified Goguma-based client remains subject to GNU AGPLv3, preserved upstream notices and applicable upstream additional terms. Corresponding source for the distributed client binary is provided through the matching release tag.
```

Yalnız həqiqətən release-də mövcud dəyişiklikləri saxla. Təsdiqlənməmiş funksiyanı modification list-ə əlavə etmə.

## 6. Hazır `SOURCE_CODE_OFFER.md` mətni

```markdown
# Corresponding source code offer

IRC Mobile is an independent modified client based on Goguma and is distributed under GNU AGPLv3.

The corresponding source code for the IRC Mobile 1.0.0 Google Play release is available at no charge from:

https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0

Repository:

https://github.com/kurt-19/goguma-mod

The matching source release includes the preferred form of the covered mobile client source needed to understand and rebuild the released version, subject to documented toolchain requirements.

Production signing keys, API secrets, database credentials, private infrastructure credentials and user data are not part of corresponding source code.

For source-code availability questions, contact:

[LEGAL OR SUPPORT EMAIL]
```

## 7. Hazır GitHub Release mətni

Release title:

```text
IRC Mobile 1.0.0 — Initial Google Play Release
```

Tag:

```text
v1.0.0
```

Release description:

```markdown
# IRC Mobile 1.0.0

This is the matching source release for the initial IRC Mobile Google Play version.

## Included functionality

- IRC channels and private messages
- Background connection and message notifications
- User-initiated voice messages
- Profile and media features
- Channel controls
- IRCv3 and bouncer-related compatibility
- Stability and synchronization fixes

Voice and video calling are disabled and are not included as available features in this release.

## Source and license

IRC Mobile is an independent modified client based on Goguma. The mobile client source is provided under GNU AGPLv3 with preserved upstream notices and applicable additional terms.

Upstream: https://codeberg.org/emersion/goguma

See `LICENSE`, `NOTICE.md`, `UPSTREAM_NOTICE.md`, `MODIFICATIONS.md` and `SOURCE_CODE_OFFER.md`.

## Verification

- Version name: 1.0.0
- Version code: 1
- Package: com.ircmobile.app
- Source commit: [FULL COMMIT SHA]
- AAB SHA-256: [AAB SHA-256]
- APK SHA-256: [APK SHA-256]

## Security

Do not publish or attach production keystores, password files, API secrets, database credentials or private user data.
```

## 8. Hazır `PRIVACY.md` mətni

Bu mətni repository-də saxla və eyni məzmunu public HTTPS səhifədə yerləşdir. Retention və hüquqi məlumat placeholder-lərini doldurmadan publish etmə.

```markdown
# Privacy Policy for IRC Mobile

Effective date: [DATE]

IRC Mobile is operated by [DEVELOPER OR COMPANY NAME]. This policy explains how IRC Mobile processes information.

## Information processed

IRC Mobile processes connection information required to connect to the configured IRC service, including server address, nickname and authentication information. Messages sent by users are transmitted to the IRC service and may be visible to channel members or private-message recipients.

When a user chooses to record a voice message, IRC Mobile accesses the microphone only during that user-initiated recording. The resulting audio file is uploaded to the official API service and shared with the selected IRC conversation after the user sends it. The microphone is not used for voice or video calls and is not intended to record in the background.

When a user chooses to upload a profile picture or media file, the selected content and related IRC identifier may be transmitted to the official API. The app may store a media deletion token locally where deletion is supported.

The app may process a push notification token through Firebase Cloud Messaging or another configured push provider to deliver IRC message notifications.

## Purposes

Information is processed to provide IRC connectivity, messaging, notifications, profile functionality, user-initiated media uploads, abuse prevention, security and technical support.

## Recipients and service providers

Information may be processed by the configured IRC service, the official IRC Mobile API, the configured push provider and infrastructure providers needed to operate these services. Content sent to public IRC channels is visible to channel participants.

## Retention

[DESCRIBE MESSAGE, PROFILE, MEDIA, LOG, REPORT AND PUSH TOKEN RETENTION PERIODS.]

Information is deleted or anonymized when no longer required, subject to security, abuse-prevention and legal obligations.

## Security

HTTPS is used for the official API. IRC transport security depends on server support and connection configuration. IRC messages are not end-to-end encrypted by IRC Mobile unless a separate feature explicitly states otherwise.

## User choices and deletion

Users may deny microphone and notification permissions. Text messaging remains available without microphone permission. Users may remove uploaded profile content where supported.

Account or data deletion requests can be submitted through [IN-APP PATH], [PUBLIC DELETION URL] or [SUPPORT EMAIL].

## Children

IRC Mobile is not directed to children. Users must meet the minimum age required by the Terms of Use and applicable law.

## Open-source software

IRC Mobile is an independent modified client based on Goguma. Corresponding mobile client source is available under GNU AGPLv3 at https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0. The upstream Goguma authors are not responsible for this modified application or service.

## Contact

[DEVELOPER OR COMPANY NAME]
[ADDRESS IF REQUIRED]
[PRIVACY EMAIL]
[WEBSITE]
```

## 9. Hazır `TERMS.md` mətni

Bu yalnız başlanğıc şablondur; hüquqi tələblərə görə yerli hüquqşünas yoxlaması məqsədəuyğundur.

```markdown
# IRC Mobile Terms of Use

Effective date: [DATE]

By using IRC Mobile and the official hosted service, you agree to these Terms and the Privacy Policy.

## Eligibility

IRC Mobile is not intended for children. You must be at least 18 years old, or the minimum legal age required in your jurisdiction if higher, to use the official hosted service.

## User-generated content

You are responsible for messages, files, profile content and other material you submit. You must not submit or distribute:

- child sexual abuse or exploitation material;
- illegal sexual content or non-consensual intimate content;
- harassment, threats, bullying or hate speech;
- scams, fraud, spam, malware or phishing;
- content that infringes copyright, privacy or other rights;
- instructions or material intended to facilitate illegal activity;
- impersonation or deceptive identity claims.

## Reports and blocking

Users can block or ignore users through the app and can report users or messages through [IN-APP REPORT PATH]. Abuse reports may also be sent to [ABUSE EMAIL OR URL].

## Moderation

We may investigate reports, remove content, restrict access, suspend accounts or cooperate with lawful requests where appropriate. We do not guarantee that every IRC channel is monitored in real time.

## Third-party IRC networks

When users connect to a third-party IRC network, that network may apply separate rules, logging, moderation and privacy practices. Users must comply with the rules of the connected network.

## Service availability

The service is provided without a guarantee of uninterrupted availability. Features may change for security, compatibility or operational reasons.

## Open-source client

The mobile client is open-source software subject to its repository license. The hosted service, branding, credentials and private infrastructure are separate unless explicitly stated.

## Contact

[SUPPORT EMAIL]
[ABUSE EMAIL]
[WEBSITE]
```

İlk mesaj göndərilməzdən əvvəl tətbiq daxilində Terms acceptance məcburi olmalıdır; GitHub-da faylın olması təkbaşına kifayət etmir.

## 10. Hazır `ACCOUNT_DELETION.md` mətni

```markdown
# IRC Mobile account and data deletion

Users can request deletion of an IRC Mobile service account and associated data.

## In the app

Open:

Settings → Account → Delete account

Follow the confirmation steps shown in the app.

## Without the app

Send a deletion request to [DELETION EMAIL] or use [DELETION FORM URL]. Include the IRC nickname and server identifier needed to locate the account. Do not send a password by email.

We may request reasonable verification before processing a deletion request.

## Data covered

The deletion process covers account/profile information and associated data controlled by the official IRC Mobile service. Content already delivered to public IRC channels, third-party networks, recipients, security backups or legally required records may be subject to separate retention. Exact retention rules are described in the Privacy Policy.

## Contact

[DELETION EMAIL]
```

Əgər tətbiq daxilində account deletion hələ yoxdursa `Settings → Account → Delete account` yazısını istifadə etmə. Əvvəl real funksiya hazırlanmalıdır.

## 11. Hazır `CHILD_SAFETY.md` mətni

```markdown
# IRC Mobile Child Safety Standards

IRC Mobile prohibits child sexual abuse and exploitation in all forms.

Users must not create, upload, request, distribute or link to child sexual abuse material or content that facilitates the exploitation, grooming or abuse of minors.

## Reporting

Users can report a message or user through [IN-APP REPORT PATH]. Urgent child-safety reports can also be sent to [CHILD SAFETY EMAIL OR URL].

Reports are reviewed and appropriate action may include content restriction, account suspension, preservation of relevant evidence and reporting to the appropriate authorities as required by law.

## Audience

The official IRC Mobile service is not directed to children and is intended for users aged 18 and over.

## Child-safety contact

[RESPONSIBLE CONTACT NAME OR TEAM]
[CHILD SAFETY EMAIL]
```

## 12. Hazır `SECURITY.md` mətni

```markdown
# Security Policy

## Reporting a vulnerability

Do not disclose an unpatched security issue through a public GitHub issue.

Send vulnerability reports to [SECURITY EMAIL]. Include affected version, reproduction steps, impact and any proposed mitigation. Do not include real user credentials, private messages, signing keys or production secrets.

We will acknowledge reports within [NUMBER] business days and provide status updates where practical.

## Supported releases

Security fixes are provided for the latest Google Play release and current source branch unless otherwise announced.

## Secrets

Production signing keys, `.env` files, API secrets, database credentials, Firebase private keys and user data must never be committed to this repository.
```

## 13. Hazır `SUPPORT.md` mətni

```markdown
# Support

- General support: [SUPPORT EMAIL OR URL]
- Abuse reports: [ABUSE EMAIL OR URL]
- Privacy requests: [PRIVACY EMAIL]
- Account/data deletion: [DELETION EMAIL OR URL]
- Security reports: [SECURITY EMAIL]
- Child-safety reports: [CHILD SAFETY EMAIL]

When reporting an application issue, include the app version, Android version, device model and reproduction steps. Never publish passwords, authentication tokens or private messages in a public GitHub issue.
```

## 14. GitHub repository settings checklist-i

- [ ] Repository description: `Independent modified Goguma-based IRC client for Android.`
- [ ] Website: public product/support URL
- [ ] Topics: `irc`, `android`, `flutter`, `ircv3`, `goguma`, `open-source`
- [ ] Default branch protected
- [ ] Secret scanning aktivdir
- [ ] Private vulnerability reporting aktivdir
- [ ] Issues üçün bug və security templates ayrıdır
- [ ] Releases bölməsində matching source tag var
- [ ] `LICENSE` GitHub tərəfindən AGPL-3.0 kimi tanınır
- [ ] Keystore və secret faylları `.gitignore` daxilindədir
- [ ] Git history-də real secret yoxdur
- [ ] GitHub Actions loglarında secret çap edilmir
- [ ] Release source archive build-də istifadə olunan commit-lə eynidir

Tövsiyə edilən `.gitignore` nümunələri:

```gitignore
android/keystore.properties
android/key.properties
*.jks
*.keystore
.env
.env.*
google-services.json
**/service-account*.json
```

Əgər `google-services.json` build üçün public client configuration kimi saxlanılacaqsa bunu ayrıca security audit ilə qərarlaşdır; private service-account key ilə qarışdırma.

## 15. Google Play Console üçün hazır əsas mətnlər

App name:

```text
IRC Mobile
```

Short description:

```text
A modern IRC client for channels, private messages and voice messages.
```

Full description:

```text
IRC Mobile is a modern mobile client for Internet Relay Chat.

Connect to the supported IRC service, join channels, exchange private messages, receive notifications and stay connected while the app is in the background. You can also record and send voice messages when you choose to use the microphone.

Key features:
• IRC channels and private conversations
• Background connection support
• Message notifications
• User-initiated voice message recording
• Profile pictures and media sharing where available
• Channel member and moderation tools
• IRCv3 and bouncer-related functionality
• TLS connection support where enabled by the server

Voice and video calling are not included in this release.

IRC Mobile uses the official service API and an IRC service based on a modified InspIRCd 4.11.0 deployment.

IRC Mobile is an independent modified client based on Goguma. The upstream Goguma authors are not responsible for this modified version.

Corresponding source code for this release is available under GNU AGPLv3 at:
https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0
```

Release notes:

```text
Initial Google Play release of IRC Mobile.

• IRC channels and private messaging
• Background connection and notifications
• User-initiated voice messages
• Profile and media features
• IRCv3 compatibility and stability improvements
```

## 16. Reviewer access mətni

```text
The app requires access to our IRC service for full review.

Review steps:
1. Open IRC Mobile.
2. Enter the provided server, nickname and password.
3. Connect to the service.
4. Open the test channel named [TEST CHANNEL].
5. Send a test message and open a private conversation with [TEST NICK].
6. Notification and microphone permissions are optional and are requested only when the related feature is used.

Server: [IRC SERVER HOSTNAME]
Port: [TLS PORT]
TLS: Enabled
Nickname: [REVIEW NICK]
Password: [REVIEW PASSWORD]

The reviewer account does not require payment, OTP or support intervention.
Voice and video calling are not available in this release.
```

## 17. Data Safety üçün yoxlama cədvəli

Play Console cavablarını backend log/retention siyasəti ilə təsdiqlə:

| Data type | İlkin ehtimal | Səbəb |
|---|---|---|
| User IDs | Collected | IRC nickname/account və profile |
| Messages | Collected/transmitted | IRC channel/private messages |
| Voice recordings | Optional, collected | User-initiated voice message upload |
| Photos/files | Optional, collected | Profile/media upload |
| Device IDs | Collected | Firebase/push token aktivdirsə |
| Crash logs | Conditional | Sentry/error upload release-də aktivdirsə |
| Location | Not collected | Mövcud auditdə location permission yox idi |
| Contacts | Not collected | Mövcud auditdə contacts permission yox idi |
| Financial info | Not collected | Payment yoxdursa |

Backendə göndərilən məlumat, third-party push SDK-ları, retention, encryption və deletion barədə cavablar real olmalıdır. `No data collected` seçmək uyğun deyil.

## 18. Permission bloklayıcıları

Funksional məqsəd microphone və notification olsa da son APK auditində bunlar da mövcud idi:

- `CAMERA`
- `USE_FULL_SCREEN_INTENT`
- `BILLING`
- `MODIFY_AUDIO_SETTINGS`
- foreground-service permission-ları
- battery-optimization permission

Production-dan əvvəl:

- [ ] Call olmadığı üçün `CAMERA` çıxarılıb
- [ ] Call/alarm olmadığı üçün `USE_FULL_SCREEN_INTENT` çıxarılıb
- [ ] Payment olmadığı üçün `BILLING` çıxarılıb
- [ ] Qalan permission-lar real background IRC, notification və voice-message funksiyasına əsaslandırılıb
- [ ] Microphone yalnız record düyməsindən sonra istənir
- [ ] Notification rədd ediləndə əsas messaging işləyir
- [ ] Merged release manifest yenidən audit edilir

Google-a APK-dən fərqli declaration vermə.

## 19. UGC və review bloklayıcıları

IRC UGC-dir. Production-dan əvvəl:

- [ ] İlk mesajdan əvvəl Terms acceptance
- [ ] Aydın `BLOCK/IGNORE USER`
- [ ] Aydın `REPORT USER`
- [ ] Aydın `REPORT MESSAGE`
- [ ] Report backend/support axını
- [ ] Moderator cavab prosesi
- [ ] Public Terms və Child Safety URL
- [ ] 18+ target audience
- [ ] Reviewer üçün işlək test hesabı

GitHub sənədləri real in-app report və Terms acceptance funksiyasını əvəz etmir.

## 20. GitHub yeniləməsindən sonra ardıcıllıq

1. `[PLACEHOLDER]` sahələrini doldur.
2. Sənədləri hüquqi və faktiki davranışla müqayisə et.
3. Voice/video call iddialarını köhnə README/NOTICE fayllarından çıxar.
4. Source commit-i sabitlə.
5. `v1.0.0` tag yarat.
6. GitHub Release yarat və full commit SHA əlavə et.
7. Public Privacy, Terms, Deletion və Child Safety URL-lərini publish et.
8. Permission və UGC bloklayıcılarını həll et.
9. Yalnız bundan sonra matching AAB hazırla.
10. AAB/APK hash-lərini GitHub Release mətni ilə tamamla.
11. Internal testing və Play pre-launch report-u yoxla.
12. Tələb olunursa 12 tester / 14 günlük Closed test apar.
13. Production access üçün real test nəticələrini yaz.

## 21. Publish etməzdən əvvəl son yoxlama

- [ ] Bütün URL-lər açılır
- [ ] Bütün support email-ləri işləyir
- [ ] Repository public source offer-i yerinə yetirir
- [ ] Tag binary ilə eynidir
- [ ] Store listing call və E2EE vəd etmir
- [ ] Privacy real backend davranışını göstərir
- [ ] Data Safety real SDK və server axınını göstərir
- [ ] Account creation varsa deletion işləyir
- [ ] UGC report/block/Terms işləyir
- [ ] Permission-lar enabled features ilə məhduddur
- [ ] Secret və keystore GitHub-a yüklənməyib
- [ ] Version code yalnız növbəti real build zamanı qərarlaşdırılır

Ətraflı Play Console addımları üçün `doc/PLAY_CONSOLE_RELEASE_GUIDE.md` sənədinə də bax.
