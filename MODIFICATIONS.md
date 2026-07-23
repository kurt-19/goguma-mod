# Modification notice — IRC Mobile 1.0.0

- Application: IRC Mobile
- Version: 1.0.0
- Source tag: `v1.0.0`
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
