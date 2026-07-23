import 'isupport.dart';
import 'message.dart';

enum ChanModeUpdateKind { add, remove }

enum _ChanModeType { a, b, c, d }

class ChanModeUpdate {
	final String mode;
	final ChanModeUpdateKind kind;
	final String? arg;

	const ChanModeUpdate({ required this.mode, required this.kind, this.arg });

	static List<ChanModeUpdate> parse(IrcMessage msg, IrcIsupportRegistry isupport) {
		Map<String, _ChanModeType> typeByMode = {};

		for (var i = 0; i < _ChanModeType.values.length; i++) {
			var type = _ChanModeType.values[i];
			for (var mode in isupport.chanModes[i].split('')) {
				typeByMode[mode] = type;
			}
		}

		for (var membership in isupport.memberships) {
			typeByMode[membership.mode] = _ChanModeType.b;
		}

		assert(msg.cmd == 'MODE');
		var change = msg.params[1];
		var args = msg.params.sublist(2);

		List<ChanModeUpdate> updates = [];
		ChanModeUpdateKind? kind;
		var j = 0;
		for (var i = 0; i < change.length; i++) {
			if (change[i] == '+') {
				kind = ChanModeUpdateKind.add;
				continue;
			} else if (change[i] == '-') {
				kind = ChanModeUpdateKind.remove;
				continue;
			} else if (kind == null) {
				throw FormatException('Malformed MODE string: missing plus/minus');
			}

			var mode = change[i];
			var type = typeByMode[mode];
			if (type == null) {
				throw FormatException('Malformed MODE string: mode "$mode" missing from CHANMODES and PREFIX');
			}

			String? arg;
			if (_chanModeTypeHasArg(type, kind)) {
				arg = args[j];
				j++;
			}

			updates.add(ChanModeUpdate(mode: mode, kind: kind, arg: arg));
		}

		return updates;
	}
}

bool _chanModeTypeHasArg(_ChanModeType type, ChanModeUpdateKind kind) {
	switch (type) {
	case _ChanModeType.a:
	case _ChanModeType.b:
		return true;
	case _ChanModeType.c:
		return kind == ChanModeUpdateKind.add;
	case _ChanModeType.d:
		return false;
	}
}

String updateIrcMembership(String str, ChanModeUpdate update, IrcIsupportRegistry isupport) {
	var updateMemberships = isupport.memberships.where((m) => m.mode == update.mode).toList();
	if (updateMemberships.length != 1) {
		return str;
	}
	var membership = updateMemberships[0];

	switch (update.kind) {
	case ChanModeUpdateKind.add:
		if (str.contains(membership.prefix)) {
			return str;
		}
		str = str + membership.prefix;
		var l = str.split('');
		l.sort((a, b) {
			var i = _membershipIndexByPrefix(isupport.memberships, a);
			var j = _membershipIndexByPrefix(isupport.memberships, b);
			return i - j;
		});
		return l.join('');
	case ChanModeUpdateKind.remove:
		return str.replaceAll(membership.prefix, '');
	}
}

int _membershipIndexByPrefix(List<IrcIsupportMembership> memberships, String prefix) {
	for (var i = 0; i < memberships.length; i++) {
		if (memberships[i].prefix == prefix) {
			return i;
		}
	}
	throw Exception('Unknown membership prefix "$prefix"');
}

abstract class UserMode {
	static const invisible = 'i';
	static const op = 'o';
	static const localOp = 'O';
}

abstract class ChannelMode {
	static const ban = 'b';
	static const clientLimit = 'l';
	static const inviteOnly = 'i';
	static const key = 'k';
	static const moderated = 'm';
	static const secret = 's';
	static const protectedTopic = 't';
	static const noExternalMessages = 'n';
}
