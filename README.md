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

The official hosted service uses the IRC Mobile Android client, the official IRC Mobile API and an IRC service based on a modified InspIRCd 4.11.0 deployment.

The production API, IRC server deployment and private infrastructure are separate from the mobile client unless their source code is explicitly included in this repository. Production credentials, signing keys, API secrets, database credentials and private user data are not included.

## Source code and releases

- Repository: https://github.com/kurt-19/goguma-mod
- Matching source release for version 1.0.0: https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0

Each distributed Google Play binary must have a matching source tag containing the exact client source used to create that release.

## License

The Goguma-based mobile client is distributed under GNU Affero General Public License version 3 (AGPLv3), subject to preserved upstream notices and any applicable upstream additional terms included in this repository.

See:

- `LICENSE` — full AGPLv3 text
- `NOTICE.md`
- `UPSTREAM_NOTICE.md`
- `MODIFICATIONS.md`
- `SOURCE_CODE_OFFER.md`
- `ADDITIONAL_TERMS_AGPL7.md`
- `THIRD_PARTY_NOTICES.md`

Third-party components remain subject to their respective licenses.

## Privacy, safety and support

Public production URLs must be supplied before Google Play submission:

- Privacy Policy: `[PUBLIC PRIVACY URL]`
- Terms of Use: `[PUBLIC TERMS URL]`
- Account/Data Deletion: `[PUBLIC DELETION URL]`
- Child Safety Standards: `[PUBLIC CHILD SAFETY URL]`
- Support: `[SUPPORT EMAIL OR URL]`
- Abuse reports: `[ABUSE EMAIL OR URL]`

Templates and release instructions are available in:

- `doc/GITHUB_AND_PLAY_DOCUMENTATION_PACK.md`
- `doc/PLAY_CONSOLE_RELEASE_GUIDE.md`

## Build and secrets

This is a Flutter Android project. Use a compatible Flutter SDK and Android toolchain. Configure the Android upload keystore outside version control.

Never commit production signing keys, password files, `.env` files, API secrets, database credentials, Firebase private keys or private user data.

## No warranty

This software is provided without warranty to the extent permitted by applicable law.
