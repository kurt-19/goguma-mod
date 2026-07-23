# IRC Mobile — Google Play Console buraxılış bələdçisi

Son audit tarixi: 2026-07-22

Bu sənəd `com.ircmobile.app` paketinin ilk Google Play buraxılışını hazırlamaq üçün praktik checklist, Play Console cavabları və hazır ingiliscə mətnlər verir. Heç bir mətn Google təsdiqinə zəmanət vermir. Yalnız tətbiqin real davranışına uyğun cavab verilməlidir.

## 1. Auditin təsdiqlədiyi faktlar

- Tətbiq orijinal Goguma layihəsinin dəyişdirilmiş ilk versiyası üzərində qurulub.
- Mobil client AGPLv3 lisenziyası altındadır; upstream müəlliflər bu dəyişdirilmiş buraxılışa görə məsul deyil.
- Dəyişdirilmiş client mənbə kodu: `https://github.com/kurt-19/goguma-mod`
- Hazırkı uyğun release tag: `https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0`
- Tətbiq IRC messaging client-dir və `api.european.az` API sistemindən istifadə edir.
- Xidmət infrastrukturu dəyişdirilmiş InspIRCd 4.11.0 serveri üzərində işləyir.
- Voice/video call bu release-də aktiv deyil: kodda `callsEnabled => false`.
- Mikrofon yalnız istifadəçinin başladığı səsli mesaj yazılması və həmin audio faylın API-yə yüklənməsi üçün istifadə olunur.
- Bildirişlər IRC mesajları və background connection/push davranışı üçün istifadə olunur.
- APK-nın target SDK səviyyəsi 36-dır.
- Version code hazırda `1`-dir və bu sənəd çərçivəsində dəyişdirilməyib.
- Statik analiz son yoxlamada təmiz keçib.

## 2. Play-ə göndərməzdən əvvəl bloklayıcı məsələlər

Bu bölmədəki məsələlər həll edilmədən Production review-a göndərmək məsləhət deyil.

### 2.1. Permission uyğunsuzluğu

Məqsəd yalnız microphone və notification üçün istifadəçi icazəsi istəməkdir. Lakin son release APK auditində aşağıdakılar da mövcuddur:

- `android.permission.CAMERA`
- `android.permission.USE_FULL_SCREEN_INTENT`
- `com.android.vending.BILLING`
- `android.permission.MODIFY_AUDIO_SETTINGS`
- `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
- `android.permission.FOREGROUND_SERVICE_DATA_SYNC`
- `android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING`
- `android.permission.RECEIVE_BOOT_COMPLETED`

Qərar checklist-i:

- [ ] Voice/video call olmadığı üçün `CAMERA` permission release manifestindən çıxarılıb.
- [ ] Alarm və incoming call olmadığı üçün `USE_FULL_SCREEN_INTENT` çıxarılıb. Bu permission saxlanılarsa ayrıca Play declaration tələb olunur və tətbiqin əsas funksiyası uyğun gəlməyə bilər.
- [ ] Ödəniş və in-app purchase yoxdursa `BILLING` permission-un hansı dependency-dən gəldiyi müəyyən edilib və çıxarılıb.
- [ ] `MODIFY_AUDIO_SETTINGS` yalnız real səsli mesaj funksiyası tələb edirsə saxlanılıb; tələb etmirsə çıxarılıb.
- [ ] Foreground service tipləri real background IRC/push davranışına tam uyğundur.
- [ ] Battery optimization istəyi istifadəçiyə aydın izahla, yalnız lazım olduqda göstərilir.
- [ ] Yeni AAB yaradıldıqdan sonra merged manifest yenidən yoxlanılıb.

Google-a “yalnız microphone və notification var” yazmaq, APK-də əlavə həssas permission-lar qalırsa düzgün deyil.

### 2.2. UGC — IRC mesajları

IRC kanalları və private messages user-generated content (UGC) sayılır. Hazırkı auditdə nick ignore/block funksiyası tapılıb, lakin ayrıca və aydın `REPORT USER` / `REPORT MESSAGE` mexanizmi və ilk istifadədə məcburi Terms of Use razılığı təsdiqlənməyib.

Production-dan əvvəl:

- [ ] İstifadəçi mesaj göndərməzdən əvvəl Terms of Use / Community Rules qəbul edir.
- [ ] Terms mətnində harassment, hate, sexual exploitation, illegal content, spam və child endangerment qadağandır.
- [ ] Private user üçün aydın `BLOCK` və ya `IGNORE` funksiyası var.
- [ ] Mesaj və istifadəçi üçün ayrıca, aydın `REPORT` funksiyası var.
- [ ] Report backend/support sisteminə çatır və moderator tərəfindən nəzərdən keçirilir.
- [ ] Reportların cavablandırılması və qanunsuz məzmunun idarəsi üçün real proses var.
- [ ] Child Safety Standards və əlaqə nöqtəsi hazırlanıb.
- [ ] Tətbiq uşaqlara yönəldilmir.

Google Play UGC policy report və block funksiyalarının tətbiqin daxilində aydın görünməsini tələb edə bilər. Sadəcə IRC server operatoruna güvənmək review riskini tam aradan qaldırmır.

### 2.3. Privacy Policy və data deletion

- [ ] Public HTTPS privacy policy URL mövcuddur.
- [ ] URL login tələb etmir və mobil brauzerdə açılır.
- [ ] Eyni privacy policy tətbiqin içindən də açılır.
- [ ] Policy developer/app adı, əlaqə emaili, data növləri, retention və deletion qaydasını göstərir.
- [ ] API, IRC server, Firebase/push və media upload məlumat axınları açıqlanır.
- [ ] Əgər tətbiqdən IRC/service account yaratmaq mümkündürsə, in-app account deletion yolu mövcuddur.
- [ ] Account creation varsa, Play Console-a ayrıca public account-deletion URL verilir.

IRC nickname sadəcə müvəqqəti sessiya identifikatorudursa və tətbiq account yaratmırsa, Data deletion cavabında bunu dürüst izah et. Lakin app daxilində `REGISTER` və ya sizin API-də persistent profile/account yaradılırsa account deletion tələbi tətbiq oluna bilər.

### 2.4. Lisenziya sənədlərinin real funksiyaya uyğunluğu

Hazırkı `NOTICE.md`, `MODIFICATIONS.md` və README mətnlərində voice/video call “əlavə edilmiş funksiya” kimi göstərilir. Bu release-də call deaktiv olduğuna görə release-dən əvvəl hüquqi qeydlər həqiqi vəziyyətə uyğunlaşdırılmalıdır.

- [ ] “Call code may exist but voice/video calling is disabled and not offered in this release” kimi dəqiq qeyd istifadə olunub.
- [ ] Store listing call funksiyası vəd etmir.
- [ ] `README.md`-nin istinad etdiyi, amma audit zamanı tapılmayan `LICENSE.md` problemi düzəldilib və ya istinad korrekt fayla dəyişdirilib.
- [ ] `LICENSE`, `NOTICE.md`, `UPSTREAM_NOTICE.md`, `SOURCE_CODE_OFFER.md` və modification notice release paketində/repository-də saxlanılıb.
- [ ] Mənbə release tag-ı Play-ə yüklənən binary ilə tam uyğun commit-i göstərir.
- [ ] Release tag source archive, build instructions və bütün AGPL-covered dəyişiklikləri ehtiva edir.
- [ ] Tətbiq daxilində Open-source licenses / Legal notices bölməsi mövcuddur.
- [ ] Goguma upstream müəlliflərinin dəyişdirilmiş tətbiqə sponsorluq və ya dəstək verdiyi iddia edilmir.

API/backend və dəyişdirilmiş InspIRCd serveri mobil client-dən ayrıca sistem kimi təsvir edilə bilər. Lakin server modifikasiyalarının öz lisenziya öhdəlikləri ayrıca server repository və istifadə olunan InspIRCd lisenziyası üzrə yoxlanmalıdır. API key, signing key, `.env`, database və istifadəçi məlumatları public source release-ə daxil edilməməlidir.

## 3. Play Console hesabı və test tələbləri

- [ ] Developer identity, email və telefon təsdiqlənib.
- [ ] Public developer email işləyir.
- [ ] Developer website və privacy policy domeni işləyir.
- [ ] Yeni personal developer account-dursa real Android device verification tamamlanıb.
- [ ] Personal account 13 noyabr 2023-dən sonra yaradılıbsa Closed testing aparılıb.
- [ ] Tələb tətbiq olunursa minimum 12 tester 14 gün fasiləsiz opt-in vəziyyətində qalıb.
- [ ] Test feedback-i saxlanılıb və Production access suallarında real nəticələr yazılıb.

İlk mərhələdə Internal testing, sonra Closed testing, daha sonra Production istifadə et.

## 4. Play Console-da app yaradılması

Tövsiyə edilən seçimlər:

- App name: `IRC Mobile`
- Default language: English
- App or game: App
- Free or paid: Free
- Category: Communication
- Contains ads: No — yalnız tətbiq həqiqətən reklam göstərmirsə
- Package name: `com.ircmobile.app`
- Target audience: `18 and over` tövsiyə olunur
- Designed for children: No

IRC açıq və ya anonim söhbətlərə çıxış verdiyi üçün uşaqları target audience-a daxil etmək əlavə Families və child-safety riskləri yaradır. Play Console cavabı real marketinq və istifadəçi axını ilə uyğun olmalıdır.

## 5. Main Store Listing üçün hazır mətnlər

### App name — 30 simvoldan az

```text
IRC Mobile
```

### Short description — 80 simvoldan az

```text
A modern IRC client for channels, private messages and voice messages.
```

### Full description

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

Open-source notice:
IRC Mobile is an independent modified client based on the Goguma project. It must not be represented as the original Goguma application, and the upstream Goguma authors are not responsible for this modified version.

The corresponding source code for this release is available under GNU AGPLv3 at:
https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0
```

Store description-da aşağıdakıları yazma:

- “official Goguma app”;
- end-to-end encrypted — tətbiqdə ayrıca E2EE təsdiqlənməyib;
- voice/video calls;
- “100% anonymous” və ya “no data collected”;
- Google/Play tərəfindən təsdiqlənmə iddiası;
- moderasiya olunmayan məzmunun təhlükəsiz olduğu iddiası.

### First release notes

```text
Initial Google Play release of IRC Mobile.

• IRC channels and private messaging
• Background connection and message notifications
• User-initiated voice messages
• Profile and media features
• IRCv3 compatibility and stability improvements
```

## 6. App Access — reviewer üçün hazır mətn

Əgər login/IRC credentials tələb olunursa Google-a işlək test hesabı və addım-addım giriş verilməlidir. Placeholder-ləri real məlumatla dəyiş:

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

The reviewer account does not require payment, OTP, QR code, location restrictions or an invitation from support.
Voice and video calling are not available in this release.
```

Reviewer hesabı review müddətində işlək qalmalı, geo/IP blokuna düşməməli və test channel mövcud olmalıdır. Production admin credential vermə.

## 7. App Content formaları

### Ads

`No` seç — yalnız heç bir reklam SDK-sı və reklam görünüşü yoxdursa.

### Content rating

Formanın versiyasına görə suallar dəyişə bilər. Dürüst əsas cavablar:

- App category/purpose: Communication / IRC client
- Users communicate with each other: Yes
- User-generated content: Yes
- Public channels or group chat: Yes
- Private one-to-one messaging: Yes
- Media or voice message sharing: Yes, funksiyalar aktivdirsə
- Moderation/reporting: yalnız real in-app report sistemi olduqdan sonra Yes
- Blocking/ignoring users: Yes, real ignore funksiyasına görə
- Gambling: No
- Purchases: No — yalnız həqiqətən monetization yoxdursa
- Location sharing: No
- Voice/video calling: No

IRC content server istifadəçiləri tərəfindən yaradıldığı üçün aşağı rating almaq üçün UGC suallarına yanlış `No` cavabı vermə.

### Target audience

Tövsiyə:

```text
18 and over
```

App-ı children/families üçün təqdim etmə. Anonymous/random chat qaydaları və UGC riski ayrıca nəzərə alınmalıdır.

### News, health, financial, government və dating declarations

Tətbiqin real məqsədi dəyişmirsə hamısı `No`.

## 8. Data Safety — ilkin data xəritəsi

Bu cədvəl hazır cavab deyil; backend logları və real retention ilə təsdiqlənməlidir.

| Data type | Ehtimal olunan vəziyyət | Məqsəd | Qeyd |
|---|---|---|---|
| User IDs | Collected | App functionality | IRC nickname/account və profile əlaqəsi |
| Messages | Collected/transmitted | App functionality | IRC serverə göndərilən channel/private messages |
| Voice or sound recordings | Optional, collected | App functionality | Yalnız istifadəçi record edib göndərəndə API-yə upload |
| Photos/videos/files | Optional, collected | App functionality | Profile/media upload aktivdirsə |
| Device or other IDs | Collected | App functionality | Firebase/push token istifadə olunursa |
| Crash logs | Conditional | Analytics / app functionality | Yalnız release-də Sentry DSN və error upload aktivdirsə |
| App interactions | Conditional | Analytics | Analytics deaktivdirsə `No`; SDK davranışını yoxla |
| Precise/approximate location | Not collected | — | Manifestdə location permission audit zamanı yox idi |
| Contacts | Not collected | — | Contacts permission audit zamanı yox idi |
| Financial info | Not collected | — | Ödəniş yoxdursa; `BILLING` permission ayrıca çıxarılmalıdır |

Hər collected data type üçün Play Console-da bunları ayrıca cavablandır:

- required, yoxsa optional;
- istifadəçi tərəfindən başladılan transferdir, yoxsa background collection;
- temporary/ephemeral processingdir, yoxsa serverdə saxlanılır;
- developer və ya third party ilə paylaşılır;
- purpose: App functionality, Developer communications, Analytics və s.;
- retention və deletion yolu;
- transit encryption.

`Data is encrypted in transit` yalnız bütün həssas API və IRC bağlantıları TLS ilə məcburi qorunursa seçilməlidir. Plain IRC bağlantısı mümkündürsə ümumi `Yes` cavabını hüquqi/privacy audit olmadan vermə.

Firebase Analytics manifestdə deaktiv görünür, amma Firebase Messaging mövcuddur. Push token və Firebase SDK data handling-i Data Safety cavabına daxil edilməlidir.

## 9. Microphone permission üçün disclosure

Permission sorğusundan dərhal əvvəl tətbiq daxilində göstərilə bilən mətn:

```text
Microphone access

IRC Mobile uses the microphone only when you choose to record a voice message. The recording is uploaded to our service and shared in the selected IRC conversation after you send it. Microphone access is not used for voice or video calls and is not active in the background.

You can continue using text messaging without granting this permission.
```

Buttons:

```text
NOT NOW
CONTINUE
```

Permission yalnız istifadəçi record düyməsinə basdıqdan sonra istənməlidir. App startup-da microphone permission istəmə.

## 10. Notification permission üçün disclosure

```text
Message notifications

Allow IRC Mobile to show notifications for new IRC messages and connection status updates. You can change this permission later in Android settings.
```

Notification permission rədd ediləndə tətbiq text messaging funksiyasını işlətməyə davam etməlidir.

## 11. Foreground Service declaration üçün mətn

Yalnız Play Console bu declaration-u göstərirsə və build-də həmin funksiyalar realdırsa istifadə et.

### Data sync

```text
IRC Mobile uses a data-sync foreground service to maintain a user-initiated IRC connection and synchronize messages while the user expects the connection to remain active. A persistent notification informs the user when the service is running, and the user can explicitly disconnect or stop the service.
```

### Remote messaging

```text
IRC Mobile uses remote messaging to receive and process IRC message notifications through the configured push provider. The service is used only for messaging functionality and does not perform advertising, tracking or location collection.
```

Full-screen intent declaration vermə; call/alarm funksiyası olmadığı üçün permission çıxarılmalıdır.

## 12. Privacy Policy üçün ingiliscə şablon

Placeholder-ləri real hüquqi məlumat və retention müddətləri ilə dəyiş. Public HTTPS səhifədə yerləşdir.

```text
Privacy Policy for IRC Mobile

Effective date: [DATE]

IRC Mobile is operated by [DEVELOPER OR COMPANY NAME]. This policy explains how IRC Mobile processes information when you use the app.

Information processed

IRC Mobile processes the connection settings and identifiers needed to connect you to the configured IRC service, including your server address, nickname and authentication information. IRC messages that you send are transmitted to the IRC service and may be visible to channel members or message recipients.

If you choose to record and send a voice message, the app accesses the microphone only during the recording action. The resulting audio file is uploaded to our API service and shared with the conversation selected by you. Voice recordings are not used for voice or video calls.

If you choose to upload a profile picture or other media, the selected file and related IRC identifier may be transmitted to our API service. The app may store a deletion token locally so that media can be removed where supported.

The app may process a push notification token through Firebase Cloud Messaging or another configured push provider to deliver message notifications. Firebase Analytics and advertising ID collection are not used by the app build unless separately disclosed here.

Purpose of processing

We process this information to provide IRC connectivity, messaging, notifications, profile features, user-initiated media uploads, abuse prevention, security and technical support.

Service providers and recipients

Information may be processed by the IRC service, our API infrastructure, the configured push notification provider and infrastructure providers required to operate the service. Messages sent to public IRC channels are visible to other channel participants.

Data retention

[DESCRIBE EXACT MESSAGE, PROFILE, MEDIA, LOG AND PUSH TOKEN RETENTION PERIODS.] Data is deleted or anonymized when it is no longer required, subject to security, abuse-prevention and legal obligations.

Security

We use reasonable technical and organizational safeguards. HTTPS is used for the application API. IRC transport security depends on the connection configuration and server support. IRC messages are not end-to-end encrypted by IRC Mobile unless a separate, explicitly identified feature provides such protection.

User choices and deletion

You can deny microphone and notification permissions. You can remove uploaded profile content where the app provides that option. To request deletion of your service account or associated data, use [IN-APP PATH] or visit [PUBLIC DELETION URL]. You may also contact [SUPPORT EMAIL].

Children

IRC Mobile is not directed to children. Users must meet the minimum age required by the applicable Terms of Use and local law.

Open-source software

IRC Mobile is an independent modified client based on Goguma. The corresponding source code for the mobile client is available under GNU AGPLv3 at https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0. The upstream Goguma authors are not responsible for this modified service.

Contact

[DEVELOPER OR COMPANY NAME]
[POSTAL OR BUSINESS ADDRESS IF REQUIRED]
[SUPPORT EMAIL]
[WEBSITE]
```

## 13. Terms of Use / UGC rules üçün minimum məzmun

Privacy Policy-dən ayrı public Terms səhifəsi hazırla. Minimum olaraq:

- minimum age;
- illegal content qadağası;
- child sexual abuse/exploitation üçün sıfır tolerantlıq;
- harassment, threats, hate speech və bullying qadağası;
- spam, scams, malware və impersonation qadağası;
- non-consensual intimate content qadağası;
- report və block yolları;
- moderation və removal hüququ;
- account suspension/termination;
- law-enforcement və qanuni sorğulara münasibət;
- support və abuse email;
- istifadəçinin IRC channel məzmununun third-party serverlərdə görünə biləcəyi barədə xəbərdarlıq.

İstifadəçi ilk dəfə mesaj göndərməzdən əvvəl Terms-i aktiv şəkildə qəbul etməlidir. Sadəcə Settings-də link kifayət etməyə bilər.

## 14. Child Safety Standards

Communication/UGC tətbiqi olaraq public child-safety səhifəsi hazırlamaq təhlükəsiz yanaşmadır:

- CSAM və child exploitation qəti qadağandır;
- in-app reporting yolu;
- abuse report email;
- reportların nəzərdən keçirilməsi prosesi;
- təsdiqlənmiş materialın aidiyyəti orqanlara bildirilməsi;
- child-safety əlaqə şəxsi;
- uşaqların target audience olmadığının açıqlanması.

Play Console soruşarsa həmin public URL-i təqdim et.

## 15. Screenshot və store asset checklist-i

- [ ] App icon: 512×512 PNG
- [ ] Feature graphic: 1024×500
- [ ] Minimum iki real phone screenshot
- [ ] Screenshotlarda real UI göstərilir
- [ ] Voice/video call göstərilmir
- [ ] Şəxsi nickname, IP, password, token və private message görünmür
- [ ] Screenshot üçün istifadə olunan channel/test user icazəlidir
- [ ] App name və branding hüquqları sizə məxsusdur
- [ ] Screenshot və description eyni funksiyaları göstərir

Tövsiyə edilən screenshot sırası:

1. Channel list və Status paneli
2. IRC channel conversation
3. Private conversation və reply
4. Voice message recording UI
5. Notification/settings ekranı

## 16. Release və source checklist-i

- [ ] Version name və version code Play Console-da qəbul olunur
- [ ] Mövcud Play release varsa version code ondan böyükdür
- [ ] AAB upload key ilə imzalanıb
- [ ] Upload keystore və parollar təhlükəsiz backup edilib
- [ ] AAB SHA-256 saxlanılıb
- [ ] `mapping.txt` və native debug symbols arxivlənib
- [ ] Matching source tag binary ilə eyni commit-dən hazırlanıb
- [ ] Source release-də build instructions mövcuddur
- [ ] Privacy, Terms, deletion və child-safety URL-ləri işləyir
- [ ] Test reviewer credentials işləyir
- [ ] Internal test keçib
- [ ] Closed test tələbi tətbiq olunursa tamamlanıb
- [ ] Pre-launch report-da crash, ANR və security warning nəzərdən keçirilib

## 17. Production access sualları üçün nümunə cavablar

Yalnız real test nəticələrinə uyğunlaşdır.

### How did you recruit testers?

```text
We recruited testers who regularly use Android messaging applications and IRC services. Testers joined through the official Google Play closed-testing opt-in link and used the app on physical Android devices.
```

### What engagement did you receive?

```text
Testers connected to the review IRC service, joined channels, exchanged channel and private messages, tested background reconnection, notifications, voice messages, channel controls and app lifecycle behavior. Feedback was collected directly and used to verify stability and usability.
```

### What did you change based on feedback?

```text
We improved channel state handling, message reply behavior, IRC synchronization compatibility, notification behavior and release stability. We also reviewed permission use, store disclosures and open-source notices before production submission.
```

### Why is the app ready for production?

```text
The release has been statically analyzed, built as a signed Android App Bundle, smoke-tested on a physical Android device and exercised through the core IRC messaging flows. Reviewer access, privacy disclosures, user safety controls and matching source-code availability are provided for the production release.
```

UGC report/Terms və permission bloklayıcıları həll edilməyibsə “ready” cavabını göndərmə.

## 18. Final submission ardıcıllığı

1. Permission bloklayıcılarını həll et.
2. UGC Terms acceptance, report və block sistemini təsdiqlə.
3. Privacy Policy, Terms, account deletion və child-safety səhifələrini publish et.
4. Lisenziya/NOTICE sənədlərini call-disabled release ilə uyğunlaşdır.
5. Matching source tag-ı publish et.
6. Play Console App content formalarını doldur.
7. Store listing və screenshotları əlavə et.
8. Reviewer credentials əlavə et.
9. AAB-ni Internal testing-ə yüklə.
10. Pre-launch report-u yoxla.
11. Tələb olunursa 12 tester / 14 günlük Closed test-i tamamla.
12. Production access üçün real test cavablarını göndər.
13. Staged rollout istifadə et və crash/ANR dashboard-u izlə.

## 19. Rəsmi Google mənbələri

- Play Console requirements: https://support.google.com/googleplay/android-developer/answer/10788890
- Prepare app for review: https://support.google.com/googleplay/android-developer/answer/9859455
- Store listing setup and limits: https://support.google.com/googleplay/android-developer/answer/9859152
- Data Safety: https://support.google.com/googleplay/android-developer/answer/10787469
- User Data and account deletion policy: https://support.google.com/googleplay/android-developer/answer/10144311
- Account deletion details: https://support.google.com/googleplay/android-developer/answer/13327111
- UGC policy: https://support.google.com/googleplay/android-developer/answer/9876937
- UGC moderation guidance: https://support.google.com/googleplay/android-developer/answer/12923286
- Foreground service and full-screen intent: https://support.google.com/googleplay/android-developer/answer/13392821
- Target API requirements: https://support.google.com/googleplay/android-developer/answer/11926878
- New personal account testing: https://support.google.com/googleplay/android-developer/answer/14151465
- Testing tracks: https://support.google.com/googleplay/android-developer/answer/9845334
- Developer contact verification: https://support.google.com/googleplay/android-developer/answer/10840893

Google policy-ləri dəyişə bilər. Submission günü Play Console-da göstərilən ən son formalar və rəsmi policy mətni bu sənəddən üstündür.
