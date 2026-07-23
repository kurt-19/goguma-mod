enum IrcUriEntityType { user, channel }

class IrcUriEntity {
	final String name;
	final IrcUriEntityType type;

	const IrcUriEntity(this.name, this.type);
}

class IrcUriAuth {
	final String username;
	final String? password;

	const IrcUriAuth(this.username, [this.password]);
}

/// An IRC URI.
///
/// IRC URIs are defined in:
/// https://datatracker.ietf.org/doc/html/draft-butcher-irc-url-04
class IrcUri {
	final String? host;
	final int? port;
	final IrcUriAuth? auth;
	final IrcUriEntity? entity;

	const IrcUri({ this.host, this.port, this.auth, this.entity });

	static IrcUri parse(String s) {
		if (!s.startsWith('irc://') && !s.startsWith('ircs://')) {
			throw FormatException('Invalid IRC URI "$s": unsupported scheme');
		}
		s = s.substring(s.indexOf(':') + '://'.length);

		String loc;
		var i = s.indexOf('/');
		if (i >= 0) {
			loc = s.substring(0, i);
			s = s.substring(i + 1);
		} else {
			loc = s;
			s = '';
		}

		var host = loc;
		IrcUriAuth? auth;
		i = loc.indexOf('@');
		if (i >= 0) {
			var rawAuth = loc.substring(0, i);
			host = loc.substring(i + 1);

			var username = rawAuth;
			String? password;
			i = rawAuth.indexOf(':');
			if (i >= 0) {
				username = rawAuth.substring(0, i);
				password = Uri.decodeComponent(rawAuth.substring(i + 1));
			}

			username = Uri.decodeComponent(username);
			auth = IrcUriAuth(username, password);
		}

		int? port;
		i = host.indexOf(':');
		if (i >= 0) {
			port = int.parse(host.substring(i + 1));
			host = host.substring(0, i);
		}

		i = s.indexOf('?');
		if (i >= 0) {
			s = s.substring(0, i);
			// TODO: parse options
		}

		IrcUriEntityType? type;
		i = s.indexOf(',');
		if (i >= 0) {
			var flags = s.substring(i + 1).split(',');
			s = s.substring(0, i);

			if (flags.contains('isuser')) {
				type = IrcUriEntityType.user;
			} else if (flags.contains('ischannel')) {
				type = IrcUriEntityType.channel;
			}

			// TODO: parse hosttype
		}

		IrcUriEntity? entity;
		if (s != '') {
			// TODO: consider using PREFIX ISUPPORT here, if available
			var name = Uri.decodeComponent(s);
			type ??= name.startsWith('#') ? IrcUriEntityType.channel : IrcUriEntityType.user;
			entity = IrcUriEntity(name, type);
		}

		return IrcUri(
			host: host,
			port: port,
			auth: auth,
			entity: entity,
		);
	}

	@override
	String toString() {
		var s = 'ircs://';
		if (auth != null) {
			s += Uri.encodeComponent(auth!.username);
			if (auth!.password != null) {
				s += ':' + Uri.encodeComponent(auth!.password!);
			}
			s += '@';
		}
		if (host != null) {
			s += host!;
		}
		s += '/';
		if (port != null && port != 6697) {
			s += ':$port';
		}
		if (entity != null) {
			s += Uri.encodeComponent(entity!.name);
			if (entity!.type == IrcUriEntityType.user) {
				s += ',isuser';
			}
		}
		return s;
	}
}

Uri parseServerUri(String rawUri) {
	if (!rawUri.contains('://')) {
		rawUri = 'ircs://' + rawUri;
	}

	var uri = Uri.parse(rawUri);
	if (uri.host == '') {
		throw FormatException('Host is required in URI');
	}
	switch (uri.scheme) {
	case 'ircs':
	case 'irc+insecure':
		break; // supported
	default:
		throw FormatException('Unsupported URI scheme: ' + uri.scheme);
	}

	return uri;
}
