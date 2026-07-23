import 'isupport.dart';
import 'message.dart';

bool matchesIgnoreMask(String rawMask, IrcSource source, CaseMapping cm) {
	var mask = rawMask.trim();
	if (mask.isEmpty) {
		return false;
	}

	if (source.user == null || source.host == null) {
		return _matchesBareNickMask(mask, source.name, cm);
	}

	var expandedMask = _expandIgnoreMask(mask, cm);
	if (expandedMask == null) {
		return false;
	}

	var usermask = _normalizeCase(
		'${source.name}!${source.user}@${source.host}'.replaceAll('!~', '!'),
		cm,
	);
	return _globRegExp(expandedMask).hasMatch(usermask);
}

bool _matchesBareNickMask(String mask, String nickname, CaseMapping cm) {
	if (mask.contains('!') || mask.contains('@')) {
		return false;
	}

	var normalizedMask = _normalizeCase(mask, cm);
	if (_isAllWildcardMask(normalizedMask)) {
		return false;
	}

	return _globRegExp(normalizedMask).hasMatch(_normalizeCase(nickname, cm));
}

String? _expandIgnoreMask(String mask, CaseMapping cm) {
	mask = _normalizeCase(mask.replaceAll('!~', '!'), cm);

	if (!mask.contains('!')) {
		if (mask.contains('@')) {
			mask = '*!' + mask;
		} else {
			mask += '!*';
		}
	}
	if (!mask.contains('@')) {
		if (mask.contains('!')) {
			mask = mask.replaceFirst('!', '!*@');
		} else {
			mask += '@*';
		}
	}

	if (_isAllWildcardMask(mask)) {
		return null;
	}
	return mask;
}

bool _isAllWildcardMask(String mask) {
	for (var ch in mask.split('')) {
		if (ch != '*' && ch != '!' && ch != '@') {
			return false;
		}
	}
	return true;
}

String _normalizeCase(String value, CaseMapping cm) {
	return cm.canonicalize(value).toLowerCase();
}

RegExp _globRegExp(String pattern) {
	var out = StringBuffer('^');
	for (var ch in pattern.split('')) {
		if (ch == '*') {
			out.write('.*');
		} else {
			out.write(RegExp.escape(ch));
		}
	}
	out.write(r'$');
	return RegExp(out.toString());
}
