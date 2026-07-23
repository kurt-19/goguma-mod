import 'dart:collection';

import 'numerics.dart';

String formatIrcTime(DateTime dt) {
	dt = dt.toUtc();
	// toIso8601String omits the microseconds if zero
	return DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.millisecond).toIso8601String();
}

class IrcParamList extends UnmodifiableListView<String> {
	final String _cmd;

	IrcParamList._(super.source, this._cmd);

	@override
	String operator [](int index) {
		try {
			return super[index];
		} on RangeError {
			throw FormatException('Invalid $_cmd message: missing parameter at index $index');
		}
	}
}

class IrcMessage {
	final UnmodifiableMapView<String, String?> tags;
	final IrcSource? source;
	final String cmd;
	final IrcParamList params;

	IrcMessage(this.cmd, List<String> params, {
		Map<String, String?> tags = const {},
		this.source,
	}) :
		tags = UnmodifiableMapView(tags),
		params = IrcParamList._(params, cmd);

	static IrcMessage parse(String s) {
		while (s.endsWith('\n') || s.endsWith('\r')) {
			s = s.substring(0, s.length - 1);
		}

		Map<String, String?> tags;
		if (s.startsWith('@')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after tags');
			}
			tags = parseIrcTags(s.substring(1, i));
			s = s.substring(i + 1);
		} else {
			tags = const {};
		}

		IrcSource? source;
		if (s.startsWith(':')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after source');
			}
			source = IrcSource.parse(s.substring(1, i));
			s = s.substring(i + 1);
		}

		String cmd;
		List<String> params = [];
		var i = s.indexOf(' ');
		if (i < 0) {
			cmd = s;
		} else {
			cmd = s.substring(0, i);
			s = s.substring(i + 1);

			while (true) {
				if (s.startsWith(':')) {
					params.add(s.substring(1));
					break;
				}

				var i = s.indexOf(' ');
				if (i < 0) {
					params.add(s);
					break;
				}

				params.add(s.substring(0, i));
				s = s.substring(i + 1);
			}
		}

		return IrcMessage(cmd.toUpperCase(), params, tags: tags, source: source);
	}

	@override
	String toString() {
		var s = '';
		if (tags.length > 0) {
			s += '@' + formatIrcTags(tags) + ' ';
		}
		if (source != null) {
			s += ':' + source!.toString() + ' ';
		}
		s += cmd;
		if (params.length > 0) {
			if (params.length > 1) {
				s += ' ' + params.getRange(0, params.length - 1).join(' ');
			}

			if (params.last.length == 0 || params.last.startsWith(':') || params.last.contains(' ')) {
				s += ' :' + params.last;
			} else {
				s += ' ' + params.last;
			}
		}
		return s;
	}

	bool isError() {
		switch (cmd) {
		case 'ERROR':
		case 'FAIL':
		case ERR_NICKLOCKED:
		case ERR_SASLFAIL:
		case ERR_SASLTOOLONG:
		case ERR_SASLABORTED:
		case ERR_SASLALREADY:
			return true;
		case ERR_NOMOTD:
			return false;
		default:
			return cmd.compareTo('400') >= 0 && cmd.compareTo('568') <= 0;
		}
	}

	String? get inReplyTo => tags['+reply'] ?? tags['+draft/reply'];

	set inReplyTo(String? reply) => tags['+reply'] = tags['+draft/reply'] = reply;

	IrcMessage copyWith({
		IrcSource? source,
		Map<String, String?>? tags,
	}) {
		return IrcMessage(
			cmd,
			params,
			source: source ?? this.source,
			tags: tags ?? this.tags,
		);
	}
}

Map<String, String?> parseIrcTags(String s) {
	return Map.fromEntries(s.split(';').map((s) {
		if (s.length == 0) {
			throw FormatException('Empty tag entries are invalid');
		}

		String k = s;
		String? v;
		var i = s.indexOf('=');
		if (i >= 0) {
			k = s.substring(0, i);
			v = _unescapeTag(s.substring(i + 1));
		}

		return MapEntry(k, v);
	}));
}

String formatIrcTags(Map<String, String?> tags) {
	return tags.entries.map((entry) {
		if (entry.value == null) {
			return entry.key;
		}
		return entry.key + '=' + _escapeTag(entry.value!);
	}).join(';');
}

String _escapeTag(String s) {
	return s.split('').map((ch) {
		switch (ch) {
		case ';':
			return '\\:';
		case ' ':
			return '\\s';
		case '\\':
			return '\\\\';
		case '\r':
			return '\\r';
		case '\n':
			return '\\n';
		default:
			return ch;
		}
	}).join('');
}

String _unescapeTag(String s) {
	var chars = s.split('');
	StringBuffer out = StringBuffer();
	for (var i = 0; i < chars.length; i++) {
		var ch = chars[i];
		if (ch != '\\' || i + 1 >= chars.length) {
			out.write(ch);
			continue;
		}

		i++;
		ch = chars[i];
		out.write(_unescapeChar(ch));
	}
	return out.toString();
}

String _unescapeChar(String ch) {
	switch (ch) {
	case ':':
		return ';';
	case 's':
		return ' ';
	case 'r':
		return '\r';
	case 'n':
		return '\n';
	default:
		return ch;
	}
}

class IrcSource {
	final String name;
	final String? user;
	final String? host;

	const IrcSource(this.name, { this.user, this.host });

	static IrcSource parse(String s) {
		String? user, host;

		var i = s.indexOf('@');
		if (i >= 0) {
			host = s.substring(i + 1);
			s = s.substring(0, i);
		}

		i = s.indexOf('!');
		if (i >= 0) {
			user = s.substring(i + 1);
			s = s.substring(0, i);
		}

		return IrcSource(s, user: user, host: host);
	}

	@override
	String toString() {
		if (host == null) {
			return name;
		}
		if (user == null) {
			return name + '@' + host!;
		}
		return name + '!' + user! + '@' + host!;
	}
}

class IrcException implements Exception {
	final IrcMessage msg;

	IrcException(this.msg) {
		assert(msg.isError() || msg.cmd == RPL_TRYAGAIN);
	}

	@override
	String toString() {
		if (msg.params.length > 0) {
			return msg.params.last;
		}
		return msg.toString();
	}
}
