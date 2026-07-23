import 'isupport.dart';
import 'message.dart';
import 'numerics.dart';

class Whois {
  final String nickname;
  final bool loggedIn;
  final IrcSource? source;
  final String? realname;
  final String? server;
  final bool op;
  final Map<String, String> channels;
  final String? account;
  final bool secureConnection;
  final String? away;
  final bool bot;

  const Whois({
    required this.nickname,
    this.loggedIn = false,
    this.source,
    this.realname,
    this.server,
    this.op = false,
    this.channels = const {},
    this.account,
    this.secureConnection = false,
    this.away,
    this.bot = false,
  });

  factory Whois.parse(
      String nickname, List<IrcMessage> replies, String prefixes) {
    var loggedIn = false;
    IrcSource? source;
    String? realname;
    String? server;
    bool op = false;
    Map<String, String> channels = {};
    String? account;
    bool secureConnection = false;
    String? away;
    bool bot = false;

    for (var msg in replies) {
      switch (msg.cmd) {
        case RPL_WHOISREGNICK:
          loggedIn = true;
          break;
        case RPL_WHOISUSER:
          source =
              IrcSource(nickname, user: msg.params[2], host: msg.params[3]);
          realname = msg.params[5];
          break;
        case RPL_WHOISSERVER:
          server = msg.params[2];
          break;
        case RPL_WHOISOPERATOR:
          op = true;
          break;
        case RPL_WHOISCHANNELS:
          for (var raw in msg.params[2].split(' ')) {
            if (raw == '') {
              continue;
            }
            var i = parseTargetPrefix(raw, prefixes);
            var prefix = raw.substring(0, i);
            var channel = raw.substring(i);
            channels[channel] = prefix;
          }
          break;
        case RPL_WHOISACCOUNT:
          account = msg.params[2];
          break;
        case RPL_WHOISSECURE:
          secureConnection = true;
          break;
        case RPL_AWAY:
          away = msg.params[2];
          break;
        case RPL_WHOISBOT:
          bot = true;
          break;
        case RPL_WHOISCERTFP:
        case RPL_WHOISIDLE:
        case RPL_WHOISSPECIAL:
        case RPL_WHOISACTUALLY:
        case RPL_WHOISHOST:
        case RPL_WHOISMODES:
          break; // not yet implemented
        case RPL_ENDOFWHOIS:
          break;
        default:
          throw Exception('Not a WHOIS reply: ${msg.cmd}');
      }
    }

    return Whois(
      nickname: nickname,
      loggedIn: loggedIn,
      source: source,
      realname: realname,
      server: server,
      op: op,
      channels: channels,
      account: account,
      secureConnection: secureConnection,
      away: away,
      bot: bot,
    );
  }
}

class WhoReply {
  final String nickname;
  final bool away;
  final bool op;
  final String realname;
  final String? username;
  final String? host;
  final String? channel;
  final String? membershipPrefix;
  final String? account;

  const WhoReply({
    required this.nickname,
    this.away = false,
    this.op = false,
    required this.realname,
    this.username,
    this.host,
    this.channel,
    this.membershipPrefix,
    this.account,
  });

  factory WhoReply.parse(IrcMessage msg, IrcIsupportRegistry isupport) {
    if (msg.cmd != RPL_WHOREPLY) {
      throw Exception('Not a WHO reply: ${msg.cmd}');
    }

    var channel = msg.params[1];
    var username = msg.params[2];
    var host = msg.params[3];
    var nickname = msg.params[5];
    var rawFlags = msg.params[6];
    var trailing = msg.params[7];

    var flags = _WhoFlags.parse(rawFlags, isupport);

    var i = trailing.indexOf(' ');
    if (i < 0) {
      throw FormatException(
          'RPL_WHOREPLY trailing parameter must contain a space');
    }
    var realname = trailing.substring(i + 1);

    return WhoReply(
      nickname: nickname,
      away: flags.away,
      op: flags.op,
      realname: realname,
      username: username,
      host: host,
      channel: channel != '*' ? channel : null,
      membershipPrefix: channel != '*' ? flags.membershipPrefix : null,
    );
  }

  factory WhoReply.parseWhox(
      IrcMessage msg, Set<WhoxField> fields, IrcIsupportRegistry isupport) {
    assert(msg.cmd == RPL_WHOSPCRPL);

    String? channel, nickname, account, realname, username, host;
    _WhoFlags? flags;
    var i = 1;
    for (var field in fields.toList()) {
      var v = msg.params[i];
      i++;

      switch (field) {
        case WhoxField.channel:
          channel = v;
          break;
        case WhoxField.nickname:
          nickname = v;
          break;
        case WhoxField.flags:
          flags = _WhoFlags.parse(v, isupport);
          break;
        case WhoxField.account:
          if (v != '0') {
            account = v;
          }
          break;
        case WhoxField.username:
          username = v;
          break;
        case WhoxField.host:
          host = v;
          break;
        case WhoxField.realname:
          realname = v;
          break;
      }
    }

    return WhoReply(
      nickname: nickname!,
      away: flags!.away,
      op: flags.op,
      realname: realname!,
      username: username,
      host: host,
      channel: channel != '*' ? channel : null,
      membershipPrefix: channel != '*' ? flags.membershipPrefix : null,
      account: account,
    );
  }
}

class _WhoFlags {
  final bool away;
  final bool op;
  final String membershipPrefix;

  const _WhoFlags({
    this.away = false,
    this.op = false,
    this.membershipPrefix = '',
  });

  factory _WhoFlags.parse(String flags, IrcIsupportRegistry isupport) {
    var away = flags.contains('G');
    var op = flags.contains('*');

    var prefixes = '!${isupport.memberships.map((m) => m.prefix).join('')}';
    var membershipPrefix =
        flags.split('').where((flag) => prefixes.contains(flag)).join('');

    return _WhoFlags(
      away: away,
      op: op,
      membershipPrefix: membershipPrefix,
    );
  }
}

class WhoxField {
  final String _letter;

  const WhoxField._(this._letter);

  @override
  String toString() {
    return _letter;
  }

  static const channel = WhoxField._('c');
  static const username = WhoxField._('u');
  static const nickname = WhoxField._('n');
  static const flags = WhoxField._('f');
  static const account = WhoxField._('a');
  static const host = WhoxField._('h');
  static const realname = WhoxField._('r');
}

String formatWhoxParam(Set<WhoxField> fields) {
  return '%' + fields.toList().map((field) => field._letter).join('');
}
