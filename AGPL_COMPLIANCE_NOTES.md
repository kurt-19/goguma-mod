# AGPL compliance notes

This file summarizes practical compliance steps for the modified Goguma-based mobile client release.

## Current release

- App name: IRC mobile app
- App version: 1.0.0+1
- Release tag: v1.0.0
- Modified source repository: https://github.com/kurt-19/goguma-mod
- Matching source release/tag: https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0
- Upstream project: https://codeberg.org/emersion/goguma

## Before publishing to Google Play

- Ensure the repository is public.
- Ensure the release tag matching the Play version exists.
- Ensure the README points to the exact matching source release/tag.
- Keep the full AGPLv3 license text in `LICENSE`.
- Keep upstream attribution notices.
- Keep modification notices.
- Do not include production secrets.
- Do not include keystore files or signing credentials.
- Do not use the original Goguma name/logo in a confusing way.

## Release matching

The Play Store release should identify or link to the matching source code release/tag:

```text
https://github.com/kurt-19/goguma-mod/releases/tag/v1.0.0
```

## Backend separation

A private backend can remain separate if it is not based on AGPL-covered code and is not itself distributed as part of this AGPL-covered client source release.

Client-side integration code that is part of the mobile app should be included if it is required to build the distributed client.
