import 'dart:collection';

import 'message.dart';

String _capName(String cap) {
	var i = cap.indexOf('=');
	if (i >= 0) {
		cap = cap.substring(0, i);
	}
	return cap.toLowerCase();
}

class IrcAvailableCapRegistry {
	final Map<String, String?> _raw = {};

	void parse(String caps) {
		if (caps == '') {
			return;
		}
		for (var s in caps.split(' ')) {
			var i = s.indexOf('=');
			String k = s;
			String? v;
			if (i >= 0) {
				k = s.substring(0, i);
				v = s.substring(i + 1);
			}
			_raw[_capName(k)] = v;
		}
	}

	@override
	String toString() {
		return _raw.entries.map((entry) {
			if (entry.value == null) {
				return entry.key;
			}
			return '${entry.key}=${entry.value}';
		}).join(' ');
	}

	void clear() {
		_raw.clear();
	}

	bool containsKey(String name) {
		return _raw.containsKey(name.toLowerCase());
	}

	int? get chatHistory {
		if (!_raw.containsKey('draft/chathistory')) {
			return null;
		}
		var v = _raw['draft/chathistory'] ?? '0';
		return int.parse(v);
	}

	bool containsSasl(String mech) {
		if (!_raw.containsKey('sasl')) {
			return false;
		}
		var v = _raw['sasl'];
		if (v == null) {
			// SASL is supported, but we don't know which mechanisms are
			// supported
			return true;
		}
		return v.toUpperCase().split(',').contains(mech.toUpperCase());
	}

	bool get accountRequired => containsKey('soju.im/account-required');
}

class IrcCapRegistry {
	final IrcAvailableCapRegistry available;
	final Set<String> _enabled;

	IrcCapRegistry({ IrcAvailableCapRegistry? available, Set<String>? enabled }) :
		available = available ?? IrcAvailableCapRegistry(),
		_enabled = enabled != null ? { ...enabled } : {};

	UnmodifiableSetView<String> get enabled => UnmodifiableSetView(_enabled);

	void parse(IrcMessage msg) {
		assert(msg.cmd == 'CAP');

		var subcommand = msg.params[1].toUpperCase();
		var capList = msg.params.last;
		switch (subcommand) {
		case 'LS':
			available.parse(capList);
			break;
		case 'NEW':
			available.parse(capList);
			break;
		case 'DEL':
			for (var cap in capList.split(' ')) {
				cap = _capName(cap);
				available._raw.remove(cap);
				_enabled.remove(cap);
			}
			break;
		case 'ACK':
			for (var cap in capList.split(' ')) {
				if (cap.startsWith('-')) {
					_enabled.remove(_capName(cap.substring(1)));
				} else {
					_enabled.add(_capName(cap));
				}
			}
			break;
		case 'NAK':
			break; // nothing to do
		default:
			throw FormatException('Unknown CAP subcommand: ' + subcommand);
		}
	}
}
