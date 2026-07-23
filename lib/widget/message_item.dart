import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../emoji.dart';
import '../irc/irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../prefs.dart';
import '../widget/link_preview.dart';
import '../widget/message_sheet.dart';
import '../widget/reactions_sheet.dart';

class RegularMessageItem extends StatelessWidget {
  final MessageModel msg;
  final MessageModel? prevMsg, nextMsg;
  final String? unreadMarkerTime;
  final VoidCallback? onReply;
  final void Function(int)? onMsgRefTap;

  const RegularMessageItem({
    super.key,
    required this.msg,
    this.prevMsg,
    this.nextMsg,
    this.unreadMarkerTime,
    this.onReply,
    this.onMsgRefTap,
  });

  @override
  Widget build(BuildContext context) {
    var client = context.read<Client>();
    var prefs = context.read<Prefs>();
    var network = context.read<NetworkModel>();
    var buffer = context.read<BufferModel>();

    var ircMsg = msg.msg;
    var entry = msg.entry;
    var isStatusBuffer = isServerBufferName(buffer.name);
    var localDateTime = entry.dateTime.toLocal();
    var eventText = formatChannelEvent(ircMsg, client);
    if (eventText != null) {
      return _ChannelEventMessageItem(
        msg: msg,
        prevMsg: prevMsg,
        unreadMarkerTime: unreadMarkerTime,
        text: eventText,
      );
    }

    var sender = ircMsg.source!.name;
    var ctcp = CtcpMessage.parse(ircMsg);
    var hasChannelContext = ircMsg.tags['+channel-context'] != null ||
        ircMsg.tags['+draft/channel-context'] != null;
    var isFromMe = client.isMyNick(sender);
    assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

    var body = isStatusBuffer
        ? stripAnsiFormatting(ircMsg.params[1])
        : ircMsg.params[1];
    const maxEmotesForBigFont = 5;
    // use .take to avoid processing the entire string
    var bigEmotes = !entry.redacted &&
        body.isNotEmpty &&
        body.characters.take(maxEmotesForBigFont + 1).length <=
            maxEmotesForBigFont &&
        body.characters.every(isEmoji);

    var target = ircMsg.params[0];
    var i = parseTargetPrefix(target, client.isupport.statusMsg);
    var statusMsgPrefix = target.substring(0, i);

    var prevEntry = prevMsg?.entry;

    var isAction = ctcp != null && ctcp.cmd == 'ACTION';
    var showUnreadMarker = prevEntry != null &&
        unreadMarkerTime != null &&
        unreadMarkerTime!.compareTo(entry.time) < 0 &&
        unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
    var showDateMarker = prevEntry == null ||
        !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());
    var colorScheme = Theme.of(context).colorScheme;
    var unreadMarkerColor = colorScheme.secondary;
    var eventColor =
        DefaultTextStyle.of(context).style.color!.withValues(alpha: 0.5);
    var isLongMessage = false;

    var boxColor = Color(0xFF122238);
    var boxAlignment = Alignment.centerLeft;
    var textColor = colorScheme.onSurface;
    var senderNickColor = isStatusBuffer
        ? textColor
        : _getNickColor(sender, colorScheme.brightness);

    if (isFromMe && !isStatusBuffer) {
      boxColor = Color(0xFF122238);
      // Actions are displayed as if they were told by an external
      // narrator. To preserve this effect, always show actions on the
      // left side.
      textColor = Color(0xFFEFF4FA);
      senderNickColor = Color(0xFF8FC7FF);
    }

    const margin = 6.0;
    var senderTextSpan = TextSpan(
      text: sender,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: isAction ? textColor : senderNickColor,
      ),
    );
    if (hasChannelContext) {
      senderTextSpan = TextSpan(children: [
        senderTextSpan,
        TextSpan(
            text: ' (only visible to you)',
            style: TextStyle(color: textColor.withValues(alpha: 0.5))),
      ]);
    } else if (statusMsgPrefix != '') {
      senderTextSpan = TextSpan(children: [
        senderTextSpan,
        TextSpan(
            text: ' (only visible to $statusMsgPrefix)',
            style: TextStyle(color: textColor.withValues(alpha: 0.5))),
      ]);
    }

    var linkStyle = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: textColor,
    );

    List<InlineSpan> content;
    Widget? linkPreview;
    if (isAction) {
      content = [
        WidgetSpan(
          child: Container(
            width: 8.0,
            height: 8.0,
            margin: EdgeInsets.all(3.0),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: senderNickColor,
            ),
          ),
        ),
        senderTextSpan,
        TextSpan(text: ' '),
        _formatText(
          context,
          isStatusBuffer
              ? stripAnsiFormatting(ctcp.param ?? '')
              : ctcp.param ?? '',
          nick: network.nickname,
          linkStyle: linkStyle,
          backgroundColor: colorScheme.surface,
          isFromMe: isFromMe,
          linkifyText: !isStatusBuffer,
        ),
      ];
    } else if (bigEmotes) {
      content = [
        _formatText(
          context,
          body,
          nick: network.nickname,
          linkStyle: linkStyle,
          backgroundColor: boxColor,
          isFromMe: isFromMe,
          linkifyText: !isStatusBuffer,
        ),
      ];
    } else {
      WidgetSpan? replyChip;
      if (!isStatusBuffer &&
          msg.replyTo != null &&
          msg.replyTo!.msg.source != null) {
        var replyNickname = msg.replyTo!.msg.source!.name;

        var replyPrefix = '$replyNickname: ';
        if (body.startsWith(replyPrefix)) {
          body = body.replaceFirst(replyPrefix, '');
        }

        replyChip = WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF253247),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
            child: ActionChip(
              label: Text(replyNickname),
              labelPadding: EdgeInsets.only(right: 4),
              backgroundColor: Colors.transparent,
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              labelStyle: const TextStyle(
                color: Color(0xFFF3F7FF),
                fontWeight: FontWeight.w600,
              ),
              visualDensity: VisualDensity(vertical: -4),
              onPressed: () {
                if (onMsgRefTap != null) {
                  onMsgRefTap!(msg.replyTo!.id!);
                }
              },
            ),
          ),
        );
      }

      var standaloneMediaUrl = _isStandaloneMediaUrl(body);
      var hideStandaloneMediaText = _isDirectMediaUrl(body);
      var hideCallLinkPreview = containsCallLink(body);
      isLongMessage =
          !entry.redacted && !standaloneMediaUrl && _isLongMessageBody(body);
      TextSpan? bodyTextSpan;
      if (entry.redacted) {
        bodyTextSpan = TextSpan(
          text: 'This message has been deleted.',
          style: TextStyle(fontStyle: FontStyle.italic),
        );
      } else if (!hideStandaloneMediaText) {
        bodyTextSpan = _formatText(
          context,
          body,
          nick: network.nickname,
          linkStyle: linkStyle,
          backgroundColor: boxColor,
          isFromMe: isFromMe,
          linkifyText: !isStatusBuffer,
        );
      }

      content = [
        if (replyChip != null) replyChip,
        if (replyChip != null) WidgetSpan(child: SizedBox(width: 5, height: 5)),
        if (bodyTextSpan != null) bodyTextSpan,
      ];

      if (!entry.redacted &&
          (prefs.linkPreview || standaloneMediaUrl) &&
          !hideCallLinkPreview) {
        linkPreview = LinkPreview(
          text: body,
          builder: (context, child) {
            return Align(
                alignment: boxAlignment,
                child: Container(
                  margin: EdgeInsets.only(top: 5),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: child,
                  ),
                ));
          },
        );
      }
      if (linkPreview != null) {
        var preview = linkPreview;
        linkPreview = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () => MessageSheet.open(context, buffer, msg, onReply),
          child: preview,
        );
      }
    }

    Widget inner = Text.rich(TextSpan(children: content));
    if (isLongMessage) {
      inner = _ExpandableMessageText(
        key: ValueKey('message-text-${msg.id}'),
        content: TextSpan(children: content),
      );
    }

    var hh = localDateTime.hour.toString().padLeft(2, '0');
    var mm = localDateTime.minute.toString().padLeft(2, '0');
    var time = '$hh:$mm';

    inner = DefaultTextStyle.merge(
        style: TextStyle(color: textColor), child: inner);

    Widget decoratedMessage;
    if (isAction) {
      decoratedMessage = inner;
    } else {
      var hasReactions = !msg.reactionsByText.isEmpty;
      decoratedMessage = Stack(children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: boxColor,
          ),
          margin: hasReactions ? EdgeInsets.only(bottom: 25) : null,
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(
                  sender,
                  style: TextStyle(
                    color: isStatusBuffer ? textColor : Color(0xFF8FC7FF),
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
                Text(
                  time,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Color(0xFF7F8CA1)),
                ),
              ]),
              SizedBox(height: 2),
              inner,
            ],
          ),
        ),
        if (hasReactions)
          Positioned(
            bottom: 4,
            right: 10,
            child: _ReactionsRow(msg),
          ),
      ]);
    }

    decoratedMessage =
        Align(alignment: Alignment.center, child: decoratedMessage);

    decoratedMessage = GestureDetector(
      onLongPress: () {
        var buffer = context.read<BufferModel>();
        MessageSheet.open(context, buffer, msg, onReply);
      },
      child: decoratedMessage,
    );

    return Column(children: [
      if (showUnreadMarker)
        Container(
          margin: EdgeInsets.only(top: margin),
          child: Row(children: [
            Expanded(child: Divider(color: unreadMarkerColor)),
            SizedBox(width: 10),
            Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
            SizedBox(width: 10),
            Expanded(child: Divider(color: unreadMarkerColor)),
          ]),
        ),
      if (showDateMarker)
        Container(
          margin: EdgeInsets.symmetric(vertical: 8),
          child: Center(
              child: Text(_formatDate(localDateTime),
                  style: TextStyle(color: eventColor))),
        ),
      Container(
        margin: EdgeInsets.only(left: 2, right: 6, top: 3, bottom: 3),
        child: Column(children: [
          decoratedMessage,
          if (linkPreview != null) linkPreview,
        ]),
      ),
    ]);
  }
}

bool _isStandaloneMediaUrl(String text) {
  var uri = _standaloneUrl(text);
  if (uri == null) {
    return false;
  }
  var path = uri.path.toLowerCase();
  return _hasMediaFileExtension(uri) || path.contains('/media/');
}

bool _isDirectMediaUrl(String text) {
  var uri = _standaloneUrl(text);
  return uri != null && _hasMediaFileExtension(uri);
}

Uri? _standaloneUrl(String text) {
  var trimmed = text.trim();
  var uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasAbsolutePath ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  if (trimmed.contains(RegExp(r'\s'))) {
    return null;
  }
  return uri;
}

bool _hasMediaFileExtension(Uri uri) {
  var path = uri.path.toLowerCase();
  return path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.png') ||
      path.endsWith('.gif') ||
      path.endsWith('.webp') ||
      path.endsWith('.mp4') ||
      path.endsWith('.mov') ||
      path.endsWith('.webm') ||
      path.endsWith('.m4a') ||
      path.endsWith('.mp3') ||
      path.endsWith('.ogg') ||
      path.endsWith('.oga') ||
      path.endsWith('.wav') ||
      path.endsWith('.aac') ||
      path.endsWith('.opus');
}

bool _isLongMessageBody(String text) {
  var plain = stripAnsiFormatting(text);
  var lineBreaks = 0;
  for (var codeUnit in plain.codeUnits) {
    if (codeUnit == 10) {
      lineBreaks++;
    }
  }
  return plain.length > 240 || lineBreaks > 3;
}

class _ExpandableMessageText extends StatefulWidget {
  final TextSpan content;

  const _ExpandableMessageText({
    super.key,
    required this.content,
  });

  @override
  State<_ExpandableMessageText> createState() => _ExpandableMessageTextState();
}

class _ExpandableMessageTextState extends State<_ExpandableMessageText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Text.rich(
            widget.content,
            maxLines: _expanded ? null : 5,
            overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: EdgeInsets.only(top: 5, bottom: 1),
            child: Row(children: [
              Expanded(
                child: Divider(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: Color(0xFF88A9D6),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _ReactionsRow extends StatelessWidget {
  final MessageModel message;

  late final List<MapEntry<String, int>> _reactions;
  late final int _overflow;

  _ReactionsRow(this.message) {
    var map = message.reactionsByText;
    var entries = message.reactionsByText.entries
        .map((entry) => MapEntry(entry.key, entry.value.length))
        .toList();
    if (entries.length > 3) {
      entries.sort((a, b) => a.value.compareTo(b.value));
      entries = entries.take(2).toList();
    }
    _reactions = entries;
    _overflow = map.length - entries.length;
  }

  @override
  Widget build(BuildContext context) {
    MapEntry<String, int>? overflowEntry;
    if (_overflow > 0) {
      overflowEntry = MapEntry('+$_overflow', 0);
    }

    var reactions = _reactions.followedBy([
      if (overflowEntry != null) overflowEntry,
    ]).map((reactionEntry) {
      return _ReactionChip(
        text: reactionEntry.key,
        count: reactionEntry.value,
        message: message,
      );
    }).toList();

    return Row(spacing: 2, children: reactions);
  }
}

class _ReactionChip extends StatelessWidget {
  final String text;
  final int count;
  final MessageModel message;
  final Color? borderColor;
  final Color? backgroundColor;

  const _ReactionChip({
    required this.text,
    required this.count,
    required this.message,
    this.borderColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    var content = text;
    if (count > 1) {
      content = '$text $count';
    }

    var fg = Theme.of(context).colorScheme.secondaryContainer;
    var bg = Theme.of(context).colorScheme.surface;
    return GestureDetector(
      onTap: () {
        var buffer = context.read<BufferModel>();
        ReactionsSheet.open(context, buffer, message);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 2, horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            width: 1,
            color: borderColor ?? bg,
          ),
          borderRadius: BorderRadius.circular(100),
          color: backgroundColor ?? fg,
        ),
        child: Text(content),
      ),
    );
  }
}

class CompactMessageItem extends StatelessWidget {
  final MessageModel msg;
  final MessageModel? prevMsg;
  final String? unreadMarkerTime;
  final VoidCallback? onReply;
  final bool last;

  const CompactMessageItem({
    super.key,
    required this.msg,
    this.prevMsg,
    this.unreadMarkerTime,
    this.onReply,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    var client = context.read<Client>();
    var prefs = context.read<Prefs>();
    var buffer = context.read<BufferModel>();
    var ircMsg = msg.msg;
    var entry = msg.entry;
    var isStatusBuffer = isServerBufferName(buffer.name);
    var localDateTime = entry.dateTime.toLocal();
    var eventText = formatChannelEvent(ircMsg, client);
    if (eventText != null) {
      return _ChannelEventMessageItem(
        msg: msg,
        prevMsg: prevMsg,
        unreadMarkerTime: unreadMarkerTime,
        text: eventText,
      );
    }

    var sender = ircMsg.source!.name;
    var ctcp = CtcpMessage.parse(ircMsg);
    assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

    var prevIrcMsg = prevMsg?.msg;
    var prevEntry = prevMsg?.entry;
    var prevMsgSameSender = prevIrcMsg != null &&
        (prevIrcMsg.cmd == 'PRIVMSG' || prevIrcMsg.cmd == 'NOTICE') &&
        ircMsg.source!.name == prevIrcMsg.source!.name;
    var showUnreadMarker = prevEntry != null &&
        unreadMarkerTime != null &&
        unreadMarkerTime!.compareTo(entry.time) < 0 &&
        unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
    var showDateMarker = prevEntry == null ||
        !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());

    var unreadMarkerColor = Theme.of(context).colorScheme.secondary;
    var textStyle =
        TextStyle(color: Theme.of(context).textTheme.bodyLarge!.color);

    String? text;
    List<TextSpan> textSpans;
    if (ctcp != null) {
      textStyle = textStyle.apply(fontStyle: FontStyle.italic);

      if (ctcp.cmd == 'ACTION') {
        text =
            isStatusBuffer ? stripAnsiFormatting(ctcp.param ?? '') : ctcp.param;
        textSpans = applyAnsiFormatting(text ?? '', textStyle);
      } else {
        textSpans = [
          TextSpan(
              text: 'has sent a CTCP "${ctcp.cmd}" command', style: textStyle)
        ];
      }
    } else if (entry.redacted) {
      textSpans = [
        TextSpan(
          text: 'This message has been deleted.',
          style: TextStyle(fontStyle: FontStyle.italic),
        )
      ];
    } else {
      text = isStatusBuffer
          ? stripAnsiFormatting(ircMsg.params[1])
          : ircMsg.params[1];
      textSpans = applyAnsiFormatting(text, textStyle);
    }

    var hideStandaloneMediaText = text != null &&
        !entry.redacted &&
        !isStatusBuffer &&
        _isDirectMediaUrl(stripAnsiFormatting(text));
    if (hideStandaloneMediaText) {
      textSpans = [];
    } else {
      textSpans = textSpans.map((span) {
        if (isStatusBuffer) {
          return TextSpan(text: span.text, style: span.style);
        }
        var linkSpan = linkify(context, span.text!,
            linkStyle: TextStyle(decoration: TextDecoration.underline));
        return TextSpan(style: span.style, children: [linkSpan]);
      }).toList();
    }
    var isLongMessage = text != null &&
        !entry.redacted &&
        !hideStandaloneMediaText &&
        _isLongMessageBody(text);

    List<Widget> stack = [];
    List<InlineSpan> content = [];

    if (!prevMsgSameSender) {
      var senderStyle = TextStyle(
        color: isStatusBuffer
            ? textStyle.color
            : _getNickColor(sender, Theme.of(context).colorScheme.brightness),
        fontWeight: FontWeight.bold,
      );
      stack.add(Positioned(
        top: 0,
        left: 0,
        child: Text(sender, style: senderStyle),
      ));
      content.add(WidgetSpan(
        alignment: PlaceholderAlignment.top,
        child: SelectionContainer.disabled(
          child: Text(
            sender,
            style: senderStyle.apply(color: Color(0x00000000)),
            semanticsLabel: '', // Make screen reader quiet
            textScaler: TextScaler.noScaling,
          ),
        ),
      ));
    }

    content.addAll(textSpans);

    if (!prevMsgSameSender ||
        prevEntry == null ||
        entry.dateTime.difference(prevEntry.dateTime) > Duration(minutes: 2)) {
      var hh = localDateTime.hour.toString().padLeft(2, '0');
      var mm = localDateTime.minute.toString().padLeft(2, '0');
      var timeText = '\u00A0[$hh:$mm]';
      var timeStyle =
          TextStyle(color: Theme.of(context).textTheme.bodySmall!.color);
      stack.add(Positioned(
        bottom: 0,
        right: 0,
        child: Text(timeText, style: timeStyle),
      ));
      content.add(WidgetSpan(
        alignment: PlaceholderAlignment.top,
        child: SelectionContainer.disabled(
          child: Text(
            timeText,
            style: timeStyle.apply(color: Color(0x00000000)),
            semanticsLabel: '', // Make screen reader quiet
            textScaler: TextScaler.noScaling,
          ),
        ),
      ));
    }

    var fg = Theme.of(context).colorScheme.secondaryContainer;
    var reactions = msg.reactionsByText.entries.map((reactionEntry) {
      return _ReactionChip(
        text: reactionEntry.key,
        count: reactionEntry.value.length,
        message: msg,
        borderColor: fg,
        backgroundColor: fg.withAlpha(30),
      );
    }).toList();
    var messageTextSpan = TextSpan(children: content);
    Widget messageText = Text.rich(messageTextSpan);
    if (isLongMessage) {
      messageText = _ExpandableMessageText(
        key: ValueKey('compact-message-text-${msg.id}'),
        content: messageTextSpan,
      );
    }

    stack.add(Container(
      margin: EdgeInsets.only(left: 4),
      child: Stack(children: [
        Container(
          margin: reactions.isEmpty ? null : EdgeInsets.only(bottom: 30),
          child: GestureDetector(
            onLongPress: () {
              var buffer = context.read<BufferModel>();
              MessageSheet.open(context, buffer, msg, onReply);
            },
            child: messageText,
          ),
        ),
        if (!reactions.isEmpty)
          Positioned(bottom: 4, child: Row(spacing: 2, children: reactions)),
      ]),
    ));

    Widget? linkPreview;
    if (text != null) {
      var body = stripAnsiFormatting(text);
      if (!entry.redacted &&
          (prefs.linkPreview || _isStandaloneMediaUrl(body))) {
        linkPreview = LinkPreview(
          text: body,
          builder: (context, child) {
            return Align(
                alignment: Alignment.center,
                child: Container(
                  margin: EdgeInsets.symmetric(vertical: 5),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: child,
                  ),
                ));
          },
        );
      }
      if (linkPreview != null) {
        var preview = linkPreview;
        linkPreview = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () => MessageSheet.open(context, buffer, msg, onReply),
          child: preview,
        );
      }
    }

    return Column(children: [
      if (showUnreadMarker)
        Row(children: [
          Expanded(child: Divider(color: unreadMarkerColor)),
          SizedBox(width: 10),
          Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
          SizedBox(width: 10),
          Expanded(child: Divider(color: unreadMarkerColor)),
        ]),
      if (showDateMarker)
        Container(
          margin: EdgeInsets.only(top: 2.5),
          alignment: Alignment.center,
          child: Text(_formatDate(localDateTime), style: textStyle),
        ),
      Container(
        margin: EdgeInsets.only(
            top: prevMsgSameSender ? 0 : 2.5,
            bottom: last ? 10 : 0,
            left: 4,
            right: 5),
        child: DefaultTextStyle.merge(
          style: TextStyle(height: 1.15),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Stack(children: stack),
            if (linkPreview != null) linkPreview,
          ]),
        ),
      ),
    ]);
  }
}

class _ChannelEventMessageItem extends StatelessWidget {
  final MessageModel msg;
  final MessageModel? prevMsg;
  final String? unreadMarkerTime;
  final String text;

  const _ChannelEventMessageItem({
    required this.msg,
    required this.prevMsg,
    required this.unreadMarkerTime,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    var entry = msg.entry;
    var localDateTime = entry.dateTime.toLocal();
    var prevEntry = prevMsg?.entry;
    var showUnreadMarker = prevEntry != null &&
        unreadMarkerTime != null &&
        unreadMarkerTime!.compareTo(entry.time) < 0 &&
        unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
    var showDateMarker = prevEntry == null ||
        !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());

    var colorScheme = Theme.of(context).colorScheme;
    var textColor =
        Theme.of(context).textTheme.bodySmall?.color ?? colorScheme.onSurface;
    var eventColor = textColor.withValues(alpha: 0.62);
    var unreadMarkerColor = colorScheme.secondary;

    return Column(children: [
      if (showUnreadMarker)
        Container(
          margin: EdgeInsets.only(top: 6),
          child: Row(children: [
            Expanded(child: Divider(color: unreadMarkerColor)),
            SizedBox(width: 10),
            Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
            SizedBox(width: 10),
            Expanded(child: Divider(color: unreadMarkerColor)),
          ]),
        ),
      if (showDateMarker)
        Container(
          margin: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Text(_formatDate(localDateTime),
                style: TextStyle(color: eventColor)),
          ),
        ),
      Container(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        alignment: Alignment.centerLeft,
        child: Text(
          '* $text',
          textAlign: TextAlign.left,
          style: TextStyle(
            color: eventColor,
            fontSize: 13,
            fontStyle: FontStyle.italic,
            height: 1.25,
          ),
        ),
      ),
    ]);
  }
}

String? formatChannelEvent(IrcMessage msg, Client client) {
  var source = msg.source?.name ?? 'server';
  switch (msg.cmd) {
    case 'JOIN':
      if (msg.params.isEmpty) return null;
      return '$source joined ${msg.params[0]}';
    case 'PART':
      if (msg.params.isEmpty) return null;
      var reason = msg.params.length > 1 && msg.params[1].isNotEmpty
          ? ' (${msg.params[1]})'
          : '';
      return '$source left ${msg.params[0]}$reason';
    case 'QUIT':
      var reason = msg.params.isNotEmpty && msg.params[0].isNotEmpty
          ? ' (${msg.params[0]})'
          : '';
      return '$source quit$reason';
    case 'KICK':
      if (msg.params.length < 2) return null;
      var reason = msg.params.length > 2 && msg.params[2].isNotEmpty
          ? ' (${msg.params[2]})'
          : '';
      return '${msg.params[1]} was kicked by $source$reason';
    case 'NICK':
      if (msg.params.isEmpty) return null;
      return '$source is now known as ${msg.params[0]}';
    case 'MODE':
      return _formatModeEvent(msg, client, source);
    default:
      return null;
  }
}

String? _formatModeEvent(IrcMessage msg, Client client, String source) {
  if (msg.params.length < 2 || !client.isChannel(msg.params[0])) {
    return null;
  }

  var fallback = '$source sets mode ${msg.params.skip(1).join(' ')}';
  List<ChanModeUpdate> updates;
  try {
    updates = ChanModeUpdate.parse(msg, client.isupport);
  } on FormatException {
    return fallback;
  }
  if (updates.isEmpty) {
    return fallback;
  }

  var parts = updates.map((update) {
    return _formatModeUpdate(update, client) ??
        _formatRawModeUpdate(update.mode, update.kind, update.arg);
  }).toList();
  return '$source ${parts.join(', ')}';
}

String? _formatModeUpdate(ChanModeUpdate update, Client client) {
  var arg = update.arg;
  if (arg == null) {
    return null;
  }

  if (update.mode == ChannelMode.ban) {
    return update.kind == ChanModeUpdateKind.add ? 'bans $arg' : 'unbans $arg';
  }

  var membership = _membershipForMode(update.mode, client);
  if (membership == null) {
    return null;
  }
  var label = _membershipLabel(membership.mode);
  return update.kind == ChanModeUpdateKind.add
      ? 'gives $label to $arg'
      : 'removes $label from $arg';
}

IrcIsupportMembership? _membershipForMode(String mode, Client client) {
  for (var membership in client.isupport.memberships) {
    if (membership.mode == mode) {
      return membership;
    }
  }
  return null;
}

String _membershipLabel(String mode) {
  switch (mode) {
    case 'q':
      return 'owner';
    case 'a':
      return 'admin';
    case 'o':
      return 'op';
    case 'h':
      return 'half-op';
    case 'v':
      return 'voice';
    default:
      return 'mode $mode';
  }
}

String _formatRawModeUpdate(String mode, ChanModeUpdateKind kind, String? arg) {
  var sign = kind == ChanModeUpdateKind.add ? '+' : '-';
  return 'sets mode $sign$mode${arg != null ? ' $arg' : ''}';
}

bool _isSameDate(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
  var yyyy = dt.year.toString().padLeft(4, '0');
  var mm = dt.month.toString().padLeft(2, '0');
  var dd = dt.day.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd';
}

TextSpan _formatText(
  BuildContext context,
  String text, {
  required String nick,
  required TextStyle linkStyle,
  required Color backgroundColor,
  required bool isFromMe,
  bool linkifyText = true,
}) {
  const baseStyle = TextStyle();
  var spans = applyAnsiFormatting(text, baseStyle);
  return TextSpan(
    children: spans.map((span) {
      var spanText = span.text;
      if (spanText == null || spanText.isEmpty) {
        return TextSpan(style: span.style);
      }
      var spanLinkStyle = linkStyle;
      var spanColor = span.style?.color;
      if (spanColor != null) {
        spanLinkStyle = linkStyle.copyWith(decorationColor: spanColor);
      }
      if (!linkifyText) {
        return TextSpan(text: spanText, style: span.style);
      }
      return TextSpan(
        style: span.style,
        children: [linkify(context, spanText, linkStyle: spanLinkStyle)],
      );
    }).toList(),
  );
}

// _getNickColor returns a color for the given nickname. The same nickname will always get the same color. The color is chosen from the primary colors of the current theme. The brightness parameter is used to choose a lighter or darker shade of the color.
Color _getNickColor(String nickname, Brightness brightness) {
  var colorSwatch =
      Colors.primaries[nickname.hashCode % Colors.primaries.length];
  return brightness == Brightness.dark
      ? colorSwatch.shade400
      : colorSwatch.shade800;
}
