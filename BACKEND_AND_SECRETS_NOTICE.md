# Backend and secrets notice

The AGPL-covered source release in this repository is for the modified mobile client based on Goguma.

The production backend/server system used by the official IRC mobile app service is separate from the AGPL-covered mobile client source code unless specific backend code is included in this repository.

## Not included

Do not publish the following in this repository:

- production `.env` files;
- API keys;
- database usernames or passwords;
- TURN/STUN usernames or passwords;
- private server credentials;
- Google Play signing keys;
- Android keystore files;
- `key.properties`;
- Firebase/service private keys;
- private user data;
- internal production deployment secrets.

## Backend status

The official API, media service, profile image service, modified InspIRCd 4.11.0 deployment, push infrastructure, and related hosted systems are separate services unless their source code is explicitly included in this repository.

Voice and video calling are disabled and are not offered in this mobile release.

The public mobile client source may contain API integration code, endpoint examples, interfaces, or non-secret configuration examples needed to understand or build the mobile client.

## Safe examples

Use example files such as `.env.example` or documented placeholder values when documentation is needed.

Never commit real production secrets.
