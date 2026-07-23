import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'database.dart';
import 'irc/irc.dart';
import 'models.dart';

typedef CommandIsAvailable = bool Function(BuildContext context);
typedef CommandExec = String? Function(BuildContext context, String? param);

class Command {
  final CommandExec _exec;
  final String usage;
  final String description;
  final CommandIsAvailable isAvailable;

  const Command(
    this._exec, {
    required this.usage,
    required this.description,
    this.isAvailable = _alwaysAvailable,
  });

  String? exec(BuildContext context, String? param) {
    if (!isAvailable(context)) {
      throw CommandException('Command unavailable in this context');
    }
    return _exec(context, param);
  }
}

bool _alwaysAvailable(BuildContext context) {
  return true;
}

bool _availableInChannels(BuildContext context) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  return client.isChannel(buffer.name);
}

bool _availableIfChannelsAreSupported(BuildContext context) {
  var client = context.read<Client>();
  return !client.isupport.chanTypes.isEmpty;
}

class CommandException implements Exception {
  final String message;
  const CommandException(this.message);
}

String _requireParam(String? param) {
  if (param == null) {
    throw CommandException('This command requires a parameter');
  }
  return param;
}

/// Remove the first parameter from a space-separated list
///
/// Each parameter may be separated by multiple spaces. Removes up to
/// the first space and returns it along with the remainder after the
/// first sequence of spaces.
///
/// The return value is either a length 2 list (param, remainder) or
/// length 1 if there is no remainder.
List<String> _chompParam(String params) {
  var i = params.indexOf(' ');
  if (i < 0) {
    return [params];
  }
  var first = params.substring(0, i);
  while (i < params.length && params[i] == ' ') {
    i += 1;
  }
  return (i >= params.length) ? [first] : [first, params.substring(i)];
}

String? _invite(BuildContext context, String? param) {
  var client = context.read<Client>();
  var parts = _requireParam(param).split(' ');
  var nick = parts[0];
  var channel = parts.length > 1 ? parts[1] : context.read<BufferModel>().name;
  client.send(IrcMessage('INVITE', [nick, channel]));
  return null;
}

String? _join(BuildContext context, String? param) {
  var client = context.read<Client>();
  client.join([_requireParam(param)]);
  return null;
}

String? _message(BuildContext context, String? param) {
  var split = _chompParam(_requireParam(param));
  if (split.length == 1) {
    throw CommandException('This command requires a target and a message');
  }
  var client = context.read<Client>();
  _rememberNickServIdentify(context, split[0], split[1]);
  client.send(IrcMessage('PRIVMSG', [split[0], split[1]]));
  return null;
}

String? _notice(BuildContext context, String? param) {
  var split = _chompParam(_requireParam(param));
  if (split.length == 1) {
    throw CommandException('This command requires a target and a message');
  }
  var client = context.read<Client>();
  client.send(IrcMessage('NOTICE', [split[0], split[1]]));
  return null;
}

String? _serviceMessage(
    BuildContext context, String? param, String serviceName) {
  var message = _requireParam(param).trimLeft();
  if (message.isEmpty) {
    throw CommandException('This command requires a parameter');
  }
  _rememberNickServIdentify(context, serviceName, message);
  var client = context.read<Client>();
  client.send(IrcMessage('PRIVMSG', [serviceName, message]));
  return null;
}

void _rememberNickServIdentify(
    BuildContext context, String serviceName, String message) {
  if (serviceName.toLowerCase() != 'nickserv') {
    return;
  }
  var split = _chompParam(message);
  var command = split[0].toUpperCase();
  if (command != 'IDENTIFY' || split.length == 1) {
    return;
  }

  var client = context.read<Client>();
  var network = context.read<NetworkModel>();
  var db = context.read<DB>();
  var params = _chompParam(split[1]);
  var username = client.nick;
  String password;
  if (params.length == 1) {
    password = params[0];
  } else {
    username = params[0];
    password = params[1];
  }
  if (password.isEmpty) {
    return;
  }

  network.serverEntry.saslPlainUsername = username;
  network.serverEntry.saslPlainPassword = password;
  unawaited(db.storeServer(network.serverEntry));
}

String? _nickServ(BuildContext context, String? param) {
  return _serviceMessage(context, param, 'NickServ');
}

String? _chanServ(BuildContext context, String? param) {
  return _serviceMessage(context, param, 'ChanServ');
}

String? _memoServ(BuildContext context, String? param) {
  return _serviceMessage(context, param, 'MemoServ');
}

String? _hostServ(BuildContext context, String? param) {
  return _serviceMessage(context, param, 'HostServ');
}

String? _nick(BuildContext context, String? param) {
  var client = context.read<Client>();
  client.send(IrcMessage('NICK', [_requireParam(param)]));
  return null;
}

String? _away(BuildContext context, String? param) {
  var client = context.read<Client>();
  client
      .send(IrcMessage('AWAY', param == null || param.isEmpty ? [] : [param]));
  return null;
}

String? _whois(BuildContext context, String? param) {
  var client = context.read<Client>();
  var target = param ?? context.read<BufferModel>().name;
  client.send(IrcMessage('WHOIS', [target]));
  return null;
}

String? _whowas(BuildContext context, String? param) {
  var client = context.read<Client>();
  client.send(IrcMessage('WHOWAS', [_requireParam(param)]));
  return null;
}

String? _kick(BuildContext context, String? param) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  var parts = _requireParam(param).split(' ');
  var nick = parts[0];
  var reason = parts.length > 1 ? [parts.sublist(1).join(' ')] : <String>[];
  client.send(IrcMessage('KICK', [buffer.name, nick, ...reason]));
  return null;
}

String? _me(BuildContext context, String? param) {
  return CtcpMessage('ACTION', param).format();
}

String? _mode(BuildContext context, String? param) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  client.send(
      IrcMessage('MODE', [buffer.name, ..._requireParam(param).split(' ')]));
  return null;
}

String? _channelMode(
    BuildContext context, String? param, String mode, String missing) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  var arg = _requireParam(param).trim();
  if (arg.isEmpty) {
    throw CommandException(missing);
  }
  client.send(IrcMessage('MODE', [buffer.name, mode, arg]));
  return null;
}

String? _op(BuildContext context, String? param) {
  return _channelMode(context, param, '+o', 'This command requires a nickname');
}

String? _deop(BuildContext context, String? param) {
  return _channelMode(context, param, '-o', 'This command requires a nickname');
}

String? _voice(BuildContext context, String? param) {
  return _channelMode(context, param, '+v', 'This command requires a nickname');
}

String? _devoice(BuildContext context, String? param) {
  return _channelMode(context, param, '-v', 'This command requires a nickname');
}

String? _ban(BuildContext context, String? param) {
  return _channelMode(context, param, '+b', 'This command requires a mask');
}

String? _unban(BuildContext context, String? param) {
  return _channelMode(context, param, '-b', 'This command requires a mask');
}

String? _names(BuildContext context, String? param) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  client.send(IrcMessage('NAMES', [param ?? buffer.name]));
  return null;
}

String? _list(BuildContext context, String? param) {
  var client = context.read<Client>();
  client
      .send(IrcMessage('LIST', param == null || param.isEmpty ? [] : [param]));
  return null;
}

String? _oper(BuildContext context, String? param) {
  var split = _chompParam(_requireParam(param));
  if (split.length == 1) {
    throw CommandException(
        'This command requires a name and a password parameter');
  }
  var client = context.read<Client>();
  var name = split[0];
  var password = split[1];
  client.send(IrcMessage('OPER', [name, password]));
  return null;
}

String? _part(BuildContext context, String? param) {
  var client = context.read<Client>();
  var bufferList = context.read<BufferListModel>();
  var buffer = context.read<BufferModel>();
  var db = context.read<DB>();
  if (param != null) {
    client.send(IrcMessage('PART', [buffer.name, param]));
  } else {
    client.send(IrcMessage('PART', [buffer.name]));
  }
  bufferList.setArchived(buffer, true);
  db.storeBuffer(buffer.entry);
  return null;
}

String? _topic(BuildContext context, String? param) {
  var client = context.read<Client>();
  var buffer = context.read<BufferModel>();
  if (param == null || param.isEmpty) {
    client.send(IrcMessage('TOPIC', [buffer.name]));
  } else {
    client.send(IrcMessage('TOPIC', [buffer.name, param]));
  }
  return null;
}

String? _quit(BuildContext context, String? param) {
  var client = context.read<Client>();
  client
      .send(IrcMessage('QUIT', param == null || param.isEmpty ? [] : [param]));
  return null;
}

String? _quote(BuildContext context, String? param) {
  var client = context.read<Client>();
  IrcMessage msg;
  try {
    msg = IrcMessage.parse(_requireParam(param));
  } on FormatException {
    throw CommandException('Invalid IRC command');
  }
  client.send(msg);
  return null;
}

const Map<String, Command> commands = {
  'away': Command(_away,
      usage: '[message]', description: 'Set or clear away status'),
  'chanserv': Command(_chanServ,
      usage: '<command> [args...]', description: 'Send a command to ChanServ'),
  'chanserver': Command(_chanServ,
      usage: '<command> [args...]', description: 'Send a command to ChanServ'),
  'cs': Command(_chanServ,
      usage: '<command> [args...]', description: 'Send a command to ChanServ'),
  'hostserv': Command(_hostServ,
      usage: '<command> [args...]', description: 'Send a command to HostServ'),
  'hostserver': Command(_hostServ,
      usage: '<command> [args...]', description: 'Send a command to HostServ'),
  'hs': Command(_hostServ,
      usage: '<command> [args...]', description: 'Send a command to HostServ'),
  'invite': Command(_invite,
      usage: '<nickname> [channel]',
      description: 'Invite a user to the channel',
      isAvailable: _availableInChannels),
  'ban': Command(_ban,
      usage: '<mask>',
      description: 'Ban a nick or mask',
      isAvailable: _availableInChannels),
  'deop': Command(_deop,
      usage: '<nickname>',
      description: 'Remove channel operator status',
      isAvailable: _availableInChannels),
  'devoice': Command(_devoice,
      usage: '<nickname>',
      description: 'Remove voice from a user',
      isAvailable: _availableInChannels),
  'join': Command(_join,
      usage: '<channel>',
      description: 'Join a channel',
      isAvailable: _availableIfChannelsAreSupported),
  'kick': Command(_kick,
      usage: '<nickname> [reason]',
      description: 'Remove another user from the channel',
      isAvailable: _availableInChannels),
  'list': Command(_list,
      usage: '[mask]', description: 'List channels on the server'),
  'me': Command(_me, usage: '<message>', description: 'Send an action message'),
  'msg': Command(_message,
      usage: '<target> <message>', description: 'Send a private message'),
  'mode': Command(_mode,
      usage: '±<mode> [args...]', description: 'Change a channel or user mode'),
  'memoserv': Command(_memoServ,
      usage: '<command> [args...]', description: 'Send a command to MemoServ'),
  'ms': Command(_memoServ,
      usage: '<command> [args...]', description: 'Send a command to MemoServ'),
  'names': Command(_names,
      usage: '[channel]', description: 'List users in a channel'),
  'nick':
      Command(_nick, usage: '<nickname>', description: 'Change your nickname'),
  'nickserv': Command(_nickServ,
      usage: '<command> [args...]', description: 'Send a command to NickServ'),
  'ns': Command(_nickServ,
      usage: '<command> [args...]', description: 'Send a command to NickServ'),
  'notice': Command(_notice,
      usage: '<target> <message>', description: 'Send a notice'),
  'oper': Command(_oper,
      usage: '<name> <password>',
      description: 'Obtain server operator privileges'),
  'op': Command(_op,
      usage: '<nickname>',
      description: 'Give channel operator status',
      isAvailable: _availableInChannels),
  'part': Command(_part,
      usage: '[reason]',
      description: 'Leave a channel',
      isAvailable: _availableInChannels),
  'query': Command(_message,
      usage: '<target> <message>', description: 'Send a private message'),
  'quit':
      Command(_quit, usage: '[message]', description: 'Disconnect from IRC'),
  'quote': Command(_quote,
      usage: '<command> [args...]', description: 'Execute a raw IRC command'),
  'topic': Command(_topic,
      usage: '[topic]',
      description: 'Show or set the channel topic',
      isAvailable: _availableInChannels),
  'unban': Command(_unban,
      usage: '<mask>',
      description: 'Remove a ban mask',
      isAvailable: _availableInChannels),
  'voice': Command(_voice,
      usage: '<nickname>',
      description: 'Give voice to a user',
      isAvailable: _availableInChannels),
  'whois': Command(_whois,
      usage: '[nickname]', description: 'Request WHOIS information'),
  'whowas': Command(_whowas,
      usage: '<nickname>', description: 'Request WHOWAS information'),
};
