import 'package:unicode_emojis/unicode_emojis.dart';

var _emojiIndex = <String>{};

/// Whether a grapheme cluster is an emoji.
bool isEmoji(String cluster) {
	if (_emojiIndex.isEmpty) {
		var emojis = UnicodeEmojis.allEmojis.map((emoji) => emoji.emoji);
		_emojiIndex = Set.of(emojis);
	}
	return _emojiIndex.contains(cluster);
}
