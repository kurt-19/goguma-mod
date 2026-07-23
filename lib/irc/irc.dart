import 'dart:collection';

import 'isupport.dart';
import 'message.dart';
import 'numerics.dart';

export 'caps.dart';
export 'ctcp.dart';
export 'ignore.dart';
export 'isupport.dart';
export 'message.dart';
export 'mode.dart';
export 'numerics.dart';
export 'uri.dart';
export 'who.dart';

final _alphaNumRegExp = RegExp(r'^[\p{L}0-9]$', unicode: true);
final _spaceRegExp = RegExp(r'\s');

bool _isWordBoundary(String ch) {
  switch (ch) {
    case '-':
    case '_':
    case '|':
      return false;
    default:
      return !_alphaNumRegExp.hasMatch(ch);
  }
}

bool _isUriPrefix(String text) {
  var i = text.lastIndexOf(_spaceRegExp);
  if (i >= 0) {
    text = text.substring(i);
  }

  i = text.indexOf('://');
  if (i <= 0) {
    return false;
  }

  // See RFC 3986 section 3
  var ch = text[i - 1];
  switch (ch) {
    case '+':
    case '-':
    case '.':
      return true;
    default:
      return _alphaNumRegExp.hasMatch(ch);
  }
}

List<int> findTextHighlights(String text, String nick) {
  nick = nick.toLowerCase();
  text = text.toLowerCase();

  List<int> positions = [];
  while (true) {
    var i = text.indexOf(nick);
    if (i < 0) {
      break;
    }

    // TODO: proper unicode handling
    var left = '\x00';
    var right = '\x00';
    if (i > 0) {
      left = text[i - 1];
    }
    if (i + nick.length < text.length) {
      right = text[i + nick.length];
    }
    if (_isWordBoundary(left) &&
        _isWordBoundary(right) &&
        !_isUriPrefix(text.substring(0, i))) {
      positions.add(i);
    }

    text = text.substring(i + nick.length);
  }

  return positions;
}

/// Checks whether a realname is worth displaying.
bool isStubRealname(String realname, String nickname) {
  if (realname.toLowerCase() == nickname.toLowerCase()) {
    return true;
  }

  // Since the realname is mandatory, many clients set a meaningless one.
  switch (realname.toLowerCase()) {
    case 'realname':
    case 'unknown':
    case 'fullname':
      return true;
  }

  return false;
}

class ListReply {
  final String channel;
  final int clients;
  final String topic;

  const ListReply(
      {required this.channel, required this.clients, required this.topic});

  factory ListReply.parse(IrcMessage msg) {
    assert(msg.cmd == RPL_LIST);

    return ListReply(
      channel: msg.params[1],
      clients: int.parse(msg.params[2]),
      topic: msg.params[3],
    );
  }
}

enum ChannelStatus { public, secret, private }

class NamesReply {
  final String channel;
  final ChannelStatus status;
  final UnmodifiableListView<NamesReplyMember> members;

  NamesReply(
      {required this.channel,
      required this.status,
      required List<NamesReplyMember> members})
      : members = UnmodifiableListView(members);

  NamesReply.empty(this.channel)
      : status = ChannelStatus.public,
        members = UnmodifiableListView(const <NamesReplyMember>[]);

  factory NamesReply.parse(
      List<IrcMessage> replies, IrcIsupportRegistry isupport) {
    assert(replies.first.cmd == RPL_NAMREPLY);
    var symbol = replies.first.params[1];
    var channel = replies.first.params[2];

    ChannelStatus status;
    switch (symbol) {
      case '=':
        status = ChannelStatus.public;
        break;
      case '@':
        status = ChannelStatus.secret;
        break;
      case '*':
        status = ChannelStatus.private;
        break;
      default:
        throw FormatException('Unknown channel status symbol: $symbol');
    }

    var allPrefixes = '!${isupport.memberships.map((m) => m.prefix).join('')}';
    List<NamesReplyMember> members = [];
    for (var reply in replies) {
      assert(reply.cmd == RPL_NAMREPLY);
      for (var raw in reply.params[3].split(' ')) {
        if (raw == '') {
          continue;
        }
        var i = parseTargetPrefix(raw, allPrefixes);
        var prefix = raw.substring(0, i);
        var source = IrcSource.parse(raw.substring(i));
        members.add(NamesReplyMember(
          nickname: source.name,
          prefix: prefix,
          source: source,
        ));
      }
    }

    return NamesReply(
      channel: channel,
      status: status,
      members: members,
    );
  }
}

class NamesReplyMember {
  final String prefix;
  final String nickname;
  final IrcSource source;

  const NamesReplyMember({
    required this.nickname,
    this.prefix = '',
    required this.source,
  });
}
