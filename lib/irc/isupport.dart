import 'dart:collection';

final defaultCaseMapping = _caseMappingByName('rfc1459')!;

final _defaultMemberships = [
	IrcIsupportMembership('q', '~'),
	IrcIsupportMembership('a', '&'),
	IrcIsupportMembership('o', '@'),
	IrcIsupportMembership('h', '%'),
	IrcIsupportMembership('v', '+'),
];

final _defaultChanModes = ['beI', 'k', 'l', 'imnst'];

// TODO: don't return these when the server indicates no limit
const _defaultUsernameLen = 20;
const _defaultHostnameLen = 63;
const _defaultLineLen = 512;

String _unescapeIsupportValue(String value) {
	return value
		.replaceAll('\\x20', ' ')
		.replaceAll('\\x5C', '\\')
		.replaceAll('\\x3D', '=');
}

class IrcIsupportRegistry {
	Map<String, String?> _raw = {};
	CaseMapping? _caseMapping;
	List<IrcIsupportMembership>? _memberships;
	int? _monitor;
	int? _topicLen, _nickLen, _realnameLen, _usernameLen, _hostnameLen, _lineLen;
	int? _chathistoryLimit;
	List<String>? _chanModes;
	IrcIsupportElist? _elist;

	String? get network => _raw['NETWORK'];
	String get chanTypes => _raw['CHANTYPES'] ?? '#&+!';
	CaseMapping get caseMapping => _caseMapping ?? defaultCaseMapping;
	String? get bouncerNetId => _raw['BOUNCER_NETID'];
	UnmodifiableListView<IrcIsupportMembership> get memberships => UnmodifiableListView(_memberships ?? _defaultMemberships);
	int? get monitor => _monitor;
	String? get botMode => _raw['BOT'];
	bool get whox => _raw.containsKey('WHOX');
	int? get topicLen => _topicLen;
	int? get nickLen => _nickLen;
	int? get realnameLen => _realnameLen;
	int get usernameLen => _usernameLen ?? _defaultUsernameLen;
	int get hostnameLen => _hostnameLen ?? _defaultHostnameLen;
	int get lineLen => _lineLen ?? _defaultLineLen;
	int get chathistoryLimit => _chathistoryLimit ?? (throw StateError('CHATHISTORY ISUPPORT was not given'));
	List<String> get chanModes => UnmodifiableListView(_chanModes ?? _defaultChanModes);
	IrcIsupportElist? get elist => _elist;
	String? get vapid => _raw['VAPID'];
	String? get filehost => _raw['soju.im/FILEHOST'];
	String get statusMsg => _raw['STATUSMSG'] ?? '';
	String? get icon => _raw['draft/ICON'];
	bool get accountRequired => _raw.containsKey('draft/ACCOUNTREQUIRED');

	void parse(List<String> tokens) {
		for (var tok in tokens) {
			if (tok.startsWith('-')) {
				var k = tok.substring(1).toUpperCase();
				_raw.remove(k);
				switch (k) {
				case 'CASEMAPPING':
					_caseMapping = null;
					break;
				case 'CHANMODES':
					_chanModes = null;
					break;
				case 'ELIST':
					_elist = null;
					break;
				case 'HOSTLEN':
					_hostnameLen = null;
					break;
				case 'LINELEN':
					_lineLen = null;
					break;
				case 'MONITOR':
					_monitor = null;
					break;
				case 'NAMELEN':
					_realnameLen = null;
					break;
				case 'NICKLEN':
					_nickLen = null;
					break;
				case 'PREFIX':
					_memberships = null;
					break;
				case 'TOPIC':
				case 'TOPICLEN':
					_topicLen = null;
					break;
				case 'USERLEN':
					_usernameLen = null;
					break;
				case 'CHATHISTORY':
					_chathistoryLimit = null;
					break;
				}
				continue;
			}

			var append = false;
			var i = tok.indexOf('+=');
			if (i >= 0) {
				append = true;
			} else {
				i = tok.indexOf('=');
			}
			var k = tok;
			String? v;
			if (i >= 0) {
				k = tok.substring(0, i);
				v = tok.substring(i + (append ? 2 : 1));
				v = _unescapeIsupportValue(v);
				if (append) {
					v = (_raw[k] ?? '') + v;
				}
			}

			_raw[k] = v;

			switch (k.toUpperCase()) {
			case 'CASEMAPPING':
				_caseMapping = _caseMappingByName(v ?? '');
				break;
			case 'CHANMODES':
				var l = (v ?? '').split(',');
				if (l.length < 4) {
					throw FormatException('Malformed ISUPPORT CHANMODES value: $v');
				}
				_chanModes = l;
				break;
			case 'ELIST':
				_elist = IrcIsupportElist.parse(v ?? '');
				break;
			case 'HOSTLEN':
				if (v == null || v == '') {
					_hostnameLen = null;
				} else {
					_hostnameLen = int.parse(v);
				}
				break;
			case 'LINELEN':
				if (v == null) {
					throw FormatException('Malformed ISUPPORT LINELEN: no value');
				}
				_lineLen = int.parse(v);
				break;
			case 'MONITOR':
				_monitor = int.parse(v ?? '0');
				break;
			case 'NAMELEN':
				if (v == null || v == '') {
					_realnameLen = null;
				} else {
					_realnameLen = int.parse(v);
				}
				break;
			case 'NICKLEN':
				if (v == null || v == '') {
					_nickLen = null;
				} else {
					_nickLen = int.parse(v);
				}
				break;
			case 'PREFIX':
				if (v == null || v == '') {
					_memberships = null;
					break;
				}
				var i = v.indexOf(')');
				if (!v.startsWith('(') || i < 0) {
					throw FormatException('Malformed ISUPPORT PREFIX value (expected parentheses): $v');
				}
				var modes = v.substring(1, i);
				var prefixes = v.substring(i + 1);
				if (modes.length != prefixes.length) {
					throw FormatException('Malformed ISUPPORT PREFIX value (modes and prefixes count mismatch): $v');
				}
				List<IrcIsupportMembership> memberships = [];
				for (var i = 0; i < modes.length; i++) {
					memberships.add(IrcIsupportMembership(modes[i], prefixes[i]));
				}
				_memberships = memberships;
				break;
			case 'TOPICLEN':
				if (v == null || v == '') {
					_topicLen = null;
				} else {
					_topicLen = int.parse(v);
				}
				break;
			case 'USERLEN':
				if (v == null || v == '') {
					_usernameLen = null;
				} else {
					_usernameLen = int.parse(v);
				}
				break;
			case 'CHATHISTORY':
				if (v == null || v == '') {
					_chathistoryLimit = null;
				} else {
					_chathistoryLimit = int.parse(v);
				}
				break;
			}
		}
	}

	void clear() {
		_raw = {};
		_caseMapping = null;
		_memberships = null;
		_monitor = null;
		_topicLen = null;
		_nickLen = null;
		_realnameLen = null;
		_usernameLen = null;
		_hostnameLen = null;
		_lineLen = null;
		_elist = null;
		_chathistoryLimit = null;
	}

	List<String> format() {
		List<String> l = [];
		for (var entry in _raw.entries) {
			if (entry.value == null) {
				l.add(entry.key);
			} else {
				// Note, clients are expected to handle '=' correctly
				var v = entry.value!.replaceAll('\\', '\\x5C').replaceAll(' ', '\\x20');
				l.add('${entry.key}=$v');
			}
		}
		return l;
	}

	bool isClientTagAllowed(String name) {
		var clientTagDeny = _raw['CLIENTTAGDENY'] ?? '';
		var defaultAllowed = true;
		for (var entry in clientTagDeny.split(',')) {
			if (entry == name) {
				return false;
			} else if (entry == '-' + name) {
				return true;
			} else if (entry == '*') {
				defaultAllowed = false;
			}
		}
		return defaultAllowed;
	}

	bool isChannel(String name) {
		return name.length > 0 && chanTypes.contains(name[0]);
	}
}

class IrcIsupportMembership {
	final String mode;
	final String prefix;

	const IrcIsupportMembership(this.mode, this.prefix);

	static const founder = IrcIsupportMembership('q', '~');
	static const protected = IrcIsupportMembership('a', '&');
	static const op = IrcIsupportMembership('o', '@');
	static const halfop = IrcIsupportMembership('h', '%');
	static const voice = IrcIsupportMembership('v', '+');
}

class IrcIsupportElist {
	final bool creationTime;
	final bool mask;
	final bool negativeMask;
	final bool topicTime;
	final bool userCount;

	const IrcIsupportElist({
		this.creationTime = false,
		this.mask = false,
		this.negativeMask = false,
		this.topicTime = false,
		this.userCount = false,
	});

	factory IrcIsupportElist.parse(String str) {
		str = str.toUpperCase();
		return IrcIsupportElist(
			creationTime: str.contains('C'),
			mask: str.contains('M'),
			negativeMask: str.contains('N'),
			topicTime: str.contains('T'),
			userCount: str.contains('U'),
		);
	}
}

class CaseMapping {
	final String Function(String s) canonicalize;

	const CaseMapping._(this.canonicalize);

	bool equals(String a, String b) {
		// Fast path in case both strings are identical
		return a == b || canonicalize(a) == canonicalize(b);
	}
}

CaseMapping? _caseMappingByName(String s) {
	String Function(String s) caseMapChar;
	switch (s) {
	case 'ascii':
		caseMapChar = _caseMapCharAscii;
		break;
	case 'rfc1459':
		caseMapChar = _caseMapCharRfc1459;
		break;
	case 'rfc1459-strict':
		caseMapChar = _caseMapCharRfc1459Strict;
		break;
	default:
		return null;
	}
	return CaseMapping._((String s) => s.split('').map(caseMapChar).join(''));
}

String _caseMapCharRfc1459(String ch) {
	if (ch == '~') {
		return '^';
	}
	return _caseMapCharRfc1459Strict(ch);
}

String _caseMapCharRfc1459Strict(String ch) {
	switch (ch) {
	case '{':
		return '[';
	case '}':
		return ']';
	case '\\':
		return '|';
	default:
		return _caseMapCharAscii(ch);
	}
}

String _caseMapCharAscii(String ch) {
	if ('A'.codeUnits.first <= ch.codeUnits.first && ch.codeUnits.first <= 'Z'.codeUnits.first) {
		return ch.toLowerCase();
	}
	return ch;
}

class IrcNameMap<V> extends MapBase<String, V> {
	CaseMapping _cm;
	Map<String, _IrcNameMapEntry<V>> _m = {};

	IrcNameMap(CaseMapping cm) : _cm = cm;

	@override
	V? operator [](Object? key) {
		return _m[_cm.canonicalize(key as String)]?.value;
	}

	@override
	void operator []=(String key, V value) {
		_m[_cm.canonicalize(key)] = _IrcNameMapEntry(key, value);
	}

	@override
	void clear() {
		_m.clear();
	}

	@override
	Iterable<String> get keys {
		return _m.values.map((entry) => entry.name);
	}

	@override
	V? remove(Object? key) {
		return _m.remove(_cm.canonicalize(key as String))?.value;
	}

	@override
	bool containsKey(Object? key) {
		return _m.containsKey(_cm.canonicalize(key as String));
	}

	void setCaseMapping(CaseMapping cm) {
		_m = Map.fromIterables(_m.values.map((entry) => cm.canonicalize(entry.name)), _m.values);
		_cm = cm;
	}
}

class _IrcNameMapEntry<V> {
	final String name;
	final V value;

	_IrcNameMapEntry(this.name, this.value);
}

int parseTargetPrefix(String raw, String prefixes) {
	var i = 0;
	while (i < raw.length && prefixes.contains(raw[i])) {
		i++;
	}
	return i;
}

// See https://modern.ircdocs.horse/#clients
String? validateNickname(String nickname, IrcIsupportRegistry isupport) {
	if (nickname.isEmpty) {
		return 'Cannot be empty';
	}
	for (var ch in const [' ', ',', '*', '?', '!', '@']) {
		if (nickname.contains(ch)) {
			return 'Cannot contain "$ch"';
		}
	}
	for (var ch in ['\$', ':', ...isupport.chanTypes.split('')]) {
		if (nickname.startsWith(ch)) {
			return 'Cannot start with "$ch"';
		}
	}
	return null;
}

// See https://modern.ircdocs.horse/#channels
String? validateChannel(String channel, IrcIsupportRegistry isupport) {
	if (isupport.chanTypes.isEmpty) {
		return 'Channels are disabled on this server';
	}

	for (var ch in const [' ', ',', '\x07']) {
		if (channel.contains(ch)) {
			return 'Cannot contain "$ch"';
		}
	}

	var chanTypes = isupport.chanTypes.split('');
	bool found = false;
	for (var ch in chanTypes) {
		if (channel.startsWith(ch)) {
			found = true;
			break;
		}
	}
	if (!found) {
		return 'Must start with any of "${chanTypes.join('", "')}"';
	}

	return null;
}
