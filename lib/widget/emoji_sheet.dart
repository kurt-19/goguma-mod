import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:unicode_emojis/unicode_emojis.dart';

import '../prefs.dart';

const _gridItemSize = 60.0;
const _primaryEmojiTexts = [
  '😀',
  '😁',
  '😂',
  '🤣',
  '😊',
  '😉',
  '😍',
  '😘',
  '😎',
  '🙂',
  '😇',
  '😋',
  '😅',
  '😜',
  '🤔',
  '🤩',
  '🥳',
  '😴',
  '😱',
  '😢',
  '😭',
  '😡',
  '👍',
  '👎',
  '🙏',
  '🤝',
  '🙌',
  '💪',
  '👋',
  '❤️',
  '💔',
  '🤍',
  '🔥',
  '✨',
  '💯',
  '👀',
  '🎉',
  '⭐',
  '✅',
  '❌',
  '⚠️',
  '📌',
  '🔒',
  '🔑',
  '📷',
  '🎵',
  '☕',
  '🍺',
  '🌙',
  '☀️',
  '💬',
  '📡',
  '🤐',
  '🙃',
  '😏',
  '😬',
  '😶',
  '😮‍💨',
  '🥲',
  '🫡',
  '🤝',
  '👌',
  '✌️',
  '🤘',
  '🫶',
  '🧠',
  '👑',
  '💎',
  '🚀',
  '🛠️',
  '🧯',
  '🧊',
  '🌐',
  '🛰️',
  '🔔',
  '🕯️',
  '😄',
  '😆',
  '😌',
  '😔',
  '😤',
  '😳',
  '🥺',
  '😵‍💫',
  '🤯',
  '🤗',
  '🤭',
  '🤫',
  '😈',
  '👻',
  '💀',
  '💫',
  '💥',
  '💭',
  '🫠',
  '🫥',
  '🤌',
  '👏',
  '👐',
  '🙋',
  '💅',
  '🕊️',
  '🌹',
  '🍀',
  '🍿',
  '🎧',
  '🏆',
  '🎯',
];

class EmojiSheet extends StatefulWidget {
  const EmojiSheet({super.key});

  @override
  State<EmojiSheet> createState() => _EmojiSheetState();

  static Future<String?> open(BuildContext context) {
    return showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) => EmojiSheet(),
    );
  }
}

class _EmojiSheetState extends State<EmojiSheet> {
  late final List<Emoji> _primaryEmojis =
      _primaryEmojiTexts.map(_findEmoji).whereType<Emoji>().toList();
  late final List<Emoji> _recentEmojis;

  List<Emoji>? _filteredEmojis;

  @override
  void initState() {
    super.initState();

    var prefs = context.read<Prefs>();

    _recentEmojis = [];
    for (var reaction in prefs.recentReactions) {
      var emoji = _findEmoji(reaction);
      if (emoji != null) {
        _recentEmojis.add(emoji);
      }
    }
  }

  void _search(String query) {
    List<Emoji>? filtered;
    if (!query.isEmpty) {
      filtered = UnicodeEmojis.search(query).take(80).toList();
    }

    setState(() {
      _filteredEmojis = filtered;
    });
  }

  @override
  Widget build(BuildContext context) {
    var mediaQuery = MediaQuery.of(context);

    // Padding to ensure the user can scroll past the system UI at the end
    // of the list. Use padding instead of viewPadding because we don't want
    // additional padding when the keyboard is up.
    var bottomPadding =
        SliverToBoxAdapter(child: Container(height: mediaQuery.padding.bottom));

    List<Widget> slivers;
    if (_filteredEmojis != null) {
      slivers = [
        _EmojiGrid(_filteredEmojis!),
        bottomPadding,
      ];
    } else {
      slivers = [
        _EmojiGrid(_primaryEmojis),
        bottomPadding,
      ];

      if (!_recentEmojis.isEmpty) {
        slivers = [
          _EmojiHeader('Recent'),
          _EmojiGrid(_recentEmojis),
          ...slivers,
        ];
      }
    }

    // Padding ensures the full list is visible when the OSK is open
    return Padding(
      padding: mediaQuery.viewInsets,
      child: DraggableScrollableSheet(
        expand: false,
        snap: true,
        minChildSize: 0.42,
        maxChildSize: 0.62,
        builder: (context, scrollController) => Column(children: [
          Container(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search emoji',
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
              child: CustomScrollView(
                  slivers: slivers, controller: scrollController)),
        ]),
      ),
    );
  }
}

class _EmojiHeader extends StatelessWidget {
  final String title;

  const _EmojiHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return SliverList.list(children: [
      Container(
        padding: EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ]);
  }
}

class _EmojiGrid extends StatelessWidget {
  final List<Emoji> emojis;

  const _EmojiGrid(this.emojis);

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _gridItemSize,
        mainAxisExtent: _gridItemSize,
      ),
      itemBuilder: (context, index) {
        return _EmojiItem(emojis[index]);
      },
      itemCount: emojis.length,
    );
  }
}

class _EmojiItem extends StatelessWidget {
  final Emoji emoji;

  const _EmojiItem(this.emoji);

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      width: _gridItemSize,
      height: _gridItemSize,
      child: IconButton(
        tooltip: emoji.name,
        onPressed: () {
          var prefs = context.read<Prefs>();
          prefs.addRecentReaction(emoji.emoji);

          Navigator.pop(context, emoji.emoji);
        },
        icon: Container(
          alignment: Alignment.center,
          width: 40,
          height: 40,
          child: Text(emoji.emoji, style: TextStyle(fontSize: 30)),
        ),
      ),
    );
  }
}

Emoji? _findEmoji(String text) {
  for (var emoji in UnicodeEmojis.allEmojis) {
    if (emoji.emoji == text) {
      return emoji;
    }
  }
  return null;
}
