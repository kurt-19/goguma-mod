import 'dart:async';
import 'dart:collection';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'irc/irc.dart';

// This file contains models. Models are data structures which are can be
// listened to by UI elements so that the UI is updated whenever they change.

class NetworkListModel extends ChangeNotifier {
  final List<NetworkModel> _networks = [];

  UnmodifiableListView<NetworkModel> get networks =>
      UnmodifiableListView(_networks);

  void add(NetworkModel network) {
    _networks.add(network);
    notifyListeners();
  }

  void remove(NetworkModel network) {
    _networks.remove(network);
    notifyListeners();
  }

  void clear() {
    _networks.clear();
    notifyListeners();
  }

  NetworkModel? byId(int id) {
    for (var network in networks) {
      if (network.networkEntry.id == id) {
        return network;
      }
    }
    return null;
  }
}

enum NetworkState { offline, connecting, registering, synchronizing, online }

/// A model representing an IRC network.
///
/// It's constructed from two database types: [ServerEntry] and [NetworkEntry].
class NetworkModel extends ChangeNotifier {
  final ServerEntry serverEntry;
  final NetworkEntry networkEntry;

  NetworkState _state = NetworkState.offline;
  String? _upstreamName;
  BouncerNetworkModel? _bouncerNetwork;
  String _nickname;
  String _realname;
  String? _account;
  String? _connectError;
  bool _isIrcOperator = false;
  List<String> _ignoredNicks = [];

  final UserListModel _users = UserListModel(defaultCaseMapping);

  NetworkModel(
      this.serverEntry, this.networkEntry, String nickname, String realname)
      : _nickname = nickname,
        _realname = realname {
    assert(serverEntry.id != null);
    assert(networkEntry.id != null);
    _upstreamName = networkEntry.isupport.network;
  }

  int get serverId => serverEntry.id!;
  int get networkId => networkEntry.id!;

  NetworkState get state => _state;
  String? get upstreamName => _upstreamName;
  BouncerNetworkModel? get bouncerNetwork => _bouncerNetwork;
  String get nickname => _nickname;
  String get realname => _realname;
  String? get account => _account;
  String? get connectError => _connectError;
  bool get isIrcOperator => _isIrcOperator;
  UnmodifiableListView<String> get ignoredNicks =>
      UnmodifiableListView(_ignoredNicks);
  UserListModel get users => _users;

  String get displayName {
    // If the user has set a custom bouncer network name, use that
    var bouncerNetworkName = bouncerNetwork?.name ?? networkEntry.bouncerName;
    var bouncerNetworkHost = bouncerNetwork?.host;
    if (bouncerNetworkName != null &&
        bouncerNetworkName != bouncerNetworkHost) {
      return bouncerNetworkName;
    }
    return _upstreamName ?? bouncerNetwork?.host ?? serverEntry.host;
  }

  String get serverDisplayName {
    var bouncerHost = bouncerNetwork?.host?.trim();
    if (bouncerHost != null && bouncerHost.isNotEmpty) {
      return bouncerHost;
    }
    return serverEntry.host;
  }

  set state(NetworkState state) {
    if (state == _state) {
      return;
    }
    _state = state;
    notifyListeners();
  }

  set upstreamName(String? name) {
    if (name == _upstreamName) {
      return;
    }
    _upstreamName = name;
    notifyListeners();
  }

  set bouncerNetwork(BouncerNetworkModel? network) {
    _bouncerNetwork = network;
    notifyListeners();
  }

  set nickname(String nickname) {
    _nickname = nickname;
    notifyListeners();
  }

  set realname(String realname) {
    _realname = realname;
    notifyListeners();
  }

  set account(String? account) {
    _account = account;
    notifyListeners();
  }

  set connectError(String? error) {
    _connectError = error;
    notifyListeners();
  }

  set isIrcOperator(bool value) {
    if (value == _isIrcOperator) {
      return;
    }
    _isIrcOperator = value;
    notifyListeners();
  }

  bool isIgnored(String nick) {
    return isIgnoredSource(IrcSource(nick));
  }

  bool isIgnoredSource(IrcSource source) {
    var cm = networkEntry.isupport.caseMapping;
    return _ignoredNicks.any((ignored) {
      return matchesIgnoreMask(ignored, source, cm);
    });
  }

  void setIgnoredNicks(Iterable<String> nicks) {
    var normalized = _normalizeIgnoredNicks(nicks);
    if (listEquals(_ignoredNicks, normalized)) {
      return;
    }
    _ignoredNicks = normalized;
    notifyListeners();
  }

  void ignoreNick(String nick) {
    var clean = nick.trim();
    if (clean.isEmpty || isIgnored(clean)) {
      return;
    }
    setIgnoredNicks([..._ignoredNicks, clean]);
  }

  void unignoreNick(String nick) {
    var cm = networkEntry.isupport.caseMapping;
    var next = _ignoredNicks.where((ignored) => !cm.equals(ignored, nick));
    setIgnoredNicks(next);
  }

  IrcUri get uri {
    return networkEntry.bouncerUri ??
        IrcUri(
          host: serverEntry.host,
          port: serverEntry.port,
        );
  }

  String? get icon {
    var icon = networkEntry.isupport.icon;
    if (icon == null || !icon.startsWith('https://')) {
      return null;
    }
    return icon;
  }
}

List<String> _normalizeIgnoredNicks(Iterable<String> nicks) {
  var byLower = <String, String>{};
  for (var nick in nicks) {
    var clean = nick.trim();
    if (clean.isNotEmpty) {
      byLower[clean.toLowerCase()] = clean;
    }
  }
  var normalized = byLower.values.toList();
  normalized.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return normalized;
}

class BouncerNetworkListModel extends ChangeNotifier {
  final Map<String, BouncerNetworkModel> _networks = {};

  UnmodifiableMapView<String, BouncerNetworkModel> get networks =>
      UnmodifiableMapView(_networks);

  void add(BouncerNetworkModel network) {
    _networks[network.id] = network;
    notifyListeners();
  }

  void remove(String netId) {
    _networks.remove(netId);
    notifyListeners();
  }

  void clear() {
    _networks.clear();
    notifyListeners();
  }
}

enum BouncerNetworkState { connected, connecting, disconnected }

BouncerNetworkState _parseBouncerNetworkState(String s) {
  switch (s) {
    case 'connected':
      return BouncerNetworkState.connected;
    case 'connecting':
      return BouncerNetworkState.connecting;
    case 'disconnected':
      return BouncerNetworkState.disconnected;
    default:
      throw FormatException('Unknown bouncer network state: ' + s);
  }
}

/// A model representing an IRC network from the point-of-view of the bouncer.
///
/// This is different from [NetworkModel] which provides data from the
/// point-of-view of the client. For instance, the client may be connected to
/// the bouncer while the bouncer is disconnected from the upstream network.
class BouncerNetworkModel extends ChangeNotifier {
  final String id;
  String? _name;
  String? _host;
  int? _port;
  bool? _tls;
  String? _nickname;
  String? _username;
  String? _realname;
  String? _pass;
  BouncerNetworkState _state = BouncerNetworkState.disconnected;
  String? _error;

  BouncerNetworkModel(this.id, Map<String, String?> attrs) {
    setAttrs(attrs);
  }

  String? get name => _name;
  String? get host => _host;
  int? get port => _port;
  bool? get tls => _tls;
  String? get nickname => _nickname;
  String? get username => _username;
  String? get realname => _realname;
  String? get pass => _pass;
  BouncerNetworkState get state => _state;
  String? get error => _error;

  void setAttrs(Map<String, String?> attrs) {
    for (var kv in attrs.entries) {
      switch (kv.key) {
        case 'name':
          _name = kv.value;
          break;
        case 'host':
          _host = kv.value;
          break;
        case 'state':
          _state = _parseBouncerNetworkState(kv.value!);
          break;
        case 'error':
          _error = kv.value;
          break;
        case 'port':
          _port = kv.value != null ? int.tryParse(kv.value!) : null;
          break;
        case 'tls':
          _tls = kv.value == '1';
          break;
        case 'nickname':
          _nickname = kv.value;
          break;
        case 'username':
          _username = kv.value;
          break;
        case 'realname':
          _realname = kv.value;
          break;
        case 'pass':
          _pass = kv.value;
          break;
      }
    }
    notifyListeners();
  }
}

class BufferKey {
  final String name;
  final NetworkModel network;

  BufferKey(String name, this.network, CaseMapping cm)
      : name = cm.canonicalize(name);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is BufferKey && name == other.name && network == other.network;
  }

  @override
  int get hashCode {
    return Object.hash(name, network);
  }
}

class BufferListModel extends ChangeNotifier {
  Map<BufferKey, BufferModel> _buffers = {};
  List<BufferModel> _sorted = [];
  final Map<NetworkModel, CaseMapping> _cm = {};

  UnmodifiableListView<BufferModel> get buffers =>
      UnmodifiableListView(_sorted);

  @override
  void dispose() {
    for (var buf in _buffers.values) {
      buf.dispose();
    }
    super.dispose();
  }

  void add(BufferModel buf) {
    _buffers[_getBufferKey(buf.name, buf.network)] = buf;
    _rebuildSorted();
    notifyListeners();
  }

  void remove(BufferModel buf) {
    _buffers.remove(_getBufferKey(buf.name, buf.network));
    _rebuildSorted();
    notifyListeners();
  }

  void removeByNetwork(NetworkModel network) {
    _buffers.removeWhere((_, buf) => buf.network == network);
    _cm.remove(network);
    _rebuildSorted();
    notifyListeners();
  }

  void clear() {
    _buffers.clear();
    _sorted.clear();
    _cm.clear();
    notifyListeners();
  }

  BufferModel? byId(int id) {
    for (var buffer in buffers) {
      if (buffer.id == id) {
        return buffer;
      }
    }
    return null;
  }

  BufferModel? get(String name, NetworkModel network) {
    return _buffers[_getBufferKey(name, network)];
  }

  void bumpLastDeliveredTime(BufferModel buf, String t) {
    if (buf._bumpLastDeliveredTime(t)) {
      _rebuildSorted();
      notifyListeners();
    }
  }

  void setPinned(BufferModel buf, bool pinned) {
    buf.pinned = pinned;
    _rebuildSorted();
    notifyListeners();
  }

  void setMuted(BufferModel buf, bool muted) {
    buf.muted = muted;
    _rebuildSorted();
    notifyListeners();
  }

  void setArchived(BufferModel buf, bool archived) {
    buf.archived = archived;
    _rebuildSorted();
    notifyListeners();
  }

  void _rebuildSorted() {
    var l = [..._buffers.values];
    l.sort((a, b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.muted != b.muted) {
        return a.muted ? 1 : -1;
      }
      if (a.archived != b.archived) {
        return a.archived ? 1 : -1;
      }
      if (a.lastDeliveredTime != b.lastDeliveredTime) {
        if (a.lastDeliveredTime == null) {
          return 1;
        }
        if (b.lastDeliveredTime == null) {
          return -1;
        }
        return b.lastDeliveredTime!.compareTo(a.lastDeliveredTime!);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _sorted = l;
  }

  BufferKey _getBufferKey(String name, NetworkModel network) {
    return BufferKey(name, network, _cm[network] ?? defaultCaseMapping);
  }

  void _setCaseMapping(NetworkModel network, CaseMapping cm) {
    if (cm == _cm[network]) {
      return;
    }
    _cm[network] = cm;
    _buffers = Map.fromIterables(
      _buffers.values
          .map((buffer) => _getBufferKey(buffer.name, buffer.network)),
      _buffers.values,
    );
  }
}

class Draft {
  final String text;
  final int? replyTo;

  const Draft({required this.text, this.replyTo});
}

/// A model representing a "buffer".
///
/// A buffer holds a list of IRC messages. It's often called a "conversation".
/// A buffer's target can be a channel, a nickname or a server name.
class BufferModel extends ChangeNotifier {
  final BufferEntry entry;
  final NetworkModel network;
  int _unreadCount = 0;
  String? _lastDeliveredTime;
  bool _messageHistoryLoaded = false;
  List<MessageModel> _messages = [];
  final Map<String, MessageModel> _messagesByNetworkMsgid = {};
  final Map<String, Timer> _typing = {};

  // Kept in sync by BufferPageState
  bool focused = false;

  // For channels only
  bool _joining = false;
  bool _joined = false;
  MemberListModel? _members;

  // For users only
  bool? _online;
  bool? _away;
  String? _backendAvatar;
  bool _hasBackendAvatarValue = false;

  UnmodifiableListView<MessageModel> get messages =>
      UnmodifiableListView(_messages);

  BufferModel({required this.entry, required this.network}) {
    assert(entry.id != null);
  }

  int get id => entry.id!;
  String get name => entry.name;
  int get unreadCount => _unreadCount;
  String? get lastDeliveredTime => _lastDeliveredTime;
  bool get messageHistoryLoaded => _messageHistoryLoaded;
  bool get pinned => entry.pinned;
  bool get muted => entry.muted;
  bool get archived => entry.archived;
  Draft? get draft => entry.draftText != null
      ? Draft(text: entry.draftText!, replyTo: entry.draftReplyTo)
      : null;

  String? get topic => entry.topic;
  bool get joining => _joining;
  bool get joined => _joined;
  MemberListModel? get members => _members;

  bool? get online => _online;
  bool? get away => _away;

  String? get realname {
    if (entry.realname == null || isStubRealname(entry.realname!, name)) {
      return null;
    }
    return entry.realname!;
  }

  String? get avatar {
    if (_hasBackendAvatarValue) {
      return _backendAvatar;
    }
    var avatar = entry.avatar;
    if (avatar == null || !avatar.startsWith('https://')) {
      return null;
    }
    return avatar;
  }

  bool get hasBackendAvatarValue => _hasBackendAvatarValue;

  set topic(String? topic) {
    entry.topic = topic;
    notifyListeners();
  }

  set joining(bool joining) {
    _joining = joining;
    notifyListeners();
  }

  set joined(bool joined) {
    _joined = joined;
    notifyListeners();
  }

  set unreadCount(int n) {
    _unreadCount = n;
    notifyListeners();
  }

  set pinned(bool pinned) {
    entry.pinned = pinned;
    notifyListeners();
  }

  set muted(bool muted) {
    entry.muted = muted;
    notifyListeners();
  }

  set archived(bool archived) {
    entry.archived = archived;
    notifyListeners();
  }

  set draft(Draft? draft) {
    entry.draftText = draft?.text;
    entry.draftReplyTo = draft?.replyTo;
    notifyListeners();
  }

  set avatar(String? avatar) {
    entry.avatar = avatar;
    notifyListeners();
  }

  void setBackendAvatar(String? avatar) {
    if (_hasBackendAvatarValue && _backendAvatar == avatar) {
      return;
    }
    _hasBackendAvatarValue = true;
    _backendAvatar = avatar;
    notifyListeners();
  }

  set members(MemberListModel? members) {
    _members = members;
    notifyListeners();
  }

  set realname(String? realname) {
    entry.realname = realname;
    notifyListeners();
  }

  set online(bool? online) {
    _online = online;
    notifyListeners();
  }

  set away(bool? away) {
    _away = away;
    notifyListeners();
  }

  void _populateMessagesById(List<MessageModel> msgs) {
    for (var msg in msgs) {
      if (msg.entry.networkMsgid != null) {
        _messagesByNetworkMsgid[msg.entry.networkMsgid!] = msg;
      }
    }
  }

  void _appendMessages(List<MessageModel> msgs) {
    var visibleMsgs = msgs.where((msg) => !msg.entry.redacted).toList();
    _messages.addAll(visibleMsgs);
    _populateMessagesById(visibleMsgs);
  }

  void _prependMessages(List<MessageModel> msgs) {
    var visibleMsgs = msgs.where((msg) => !msg.entry.redacted).toList();
    if (visibleMsgs.isEmpty) {
      return;
    }
    assert(_messages.isEmpty ||
        visibleMsgs.last.entry.time.compareTo(_messages.first.entry.time) <= 0);
    _messages = [...visibleMsgs, ..._messages];
    _populateMessagesById(visibleMsgs);
  }

  void addMessages(List<MessageModel> msgs, {bool append = false}) {
    assert(messageHistoryLoaded);
    if (msgs.isEmpty) {
      return;
    }

    if (append) {
      _appendMessages(msgs);
    } else {
      // TODO: optimize this case
      _appendMessages(msgs);
      _messages.sort(_compareMessageModels);
    }

    notifyListeners();
  }

  void addReactions(List<ReactionEntry> reacts) {
    assert(messageHistoryLoaded);
    if (reacts.isEmpty) {
      return;
    }

    for (var reaction in reacts) {
      _messagesByNetworkMsgid[reaction.replyNetworkMsgid]
          ?._addReaction(reaction);
    }

    notifyListeners();
  }

  void replaceMessage(int messageId, MessageEntry replacement) {
    var index = _messages.indexWhere((msg) => msg.id == messageId);
    if (index < 0) {
      return;
    }

    var previous = _messages[index];
    if (previous.entry.networkMsgid != null) {
      _messagesByNetworkMsgid.remove(previous.entry.networkMsgid);
    }

    var updated = MessageModel(
      entry: replacement,
      replyTo: previous.replyTo,
      reactions: previous._reactions,
    );
    _messages[index] = updated;
    if (replacement.networkMsgid != null) {
      _messagesByNetworkMsgid[replacement.networkMsgid!] = updated;
    }
    _messages.sort(_compareMessageModels);
    notifyListeners();
  }

  void redactMessage(String msgid) {
    var msg = _messagesByNetworkMsgid.remove(msgid);
    if (msg == null) {
      return;
    }

    msg.entry.redacted = true;
    _messages.remove(msg);
    notifyListeners();
  }

  void removeMessages(Iterable<int> messageIds) {
    var ids = messageIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    var removed = _messages.where((message) => ids.contains(message.id)).toList();
    if (removed.isEmpty) {
      return;
    }
    for (var message in removed) {
      var networkMsgid = message.entry.networkMsgid;
      if (networkMsgid != null) {
        _messagesByNetworkMsgid.remove(networkMsgid);
      }
    }
    _messages.removeWhere((message) => ids.contains(message.id));
    notifyListeners();
  }

  void removeReactions(Iterable<int> reactionIds) {
    var ids = reactionIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    var changed = false;
    for (var message in _messages) {
      var previousLength = message._reactions.length;
      message._reactions.removeWhere((reaction) => ids.contains(reaction.id));
      changed = changed || message._reactions.length != previousLength;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void redactReaction(ReactionEntry reaction) {
    var msg = _messagesByNetworkMsgid[reaction.replyNetworkMsgid];
    if (msg == null) {
      return;
    }

    var msgReactions = msg._reactions.where((r) => r.id == reaction.id);
    if (msgReactions.isEmpty) {
      return;
    }

    msgReactions.first.redacted = true;
    notifyListeners();
  }

  void populateMessageHistory(List<MessageModel> l) {
    // The messages passed here must be already sorted by the caller, and
    // must always come before the existing messages
    if (!_messageHistoryLoaded) {
      assert(_messages.isEmpty);
      _appendMessages(l);
      _messageHistoryLoaded = true;
    } else if (!l.isEmpty) {
      _prependMessages(l);
    }
    notifyListeners();
  }

  void clearMessages() {
    _messages.clear();
    _messagesByNetworkMsgid.clear();
    for (var timer in _typing.values) {
      timer.cancel();
    }
    _typing.clear();
    _unreadCount = 0;
    _lastDeliveredTime = null;
    notifyListeners();
  }

  bool _bumpLastDeliveredTime(String t) {
    if (_lastDeliveredTime != null && _lastDeliveredTime!.compareTo(t) >= 0) {
      return false;
    }
    _lastDeliveredTime = t;
    notifyListeners();
    return true;
  }

  List<String> get typing {
    var typing = _typing.keys.toList();
    typing.sort();
    return typing;
  }

  void setTyping(String member, bool typing) {
    _typing[member]?.cancel();
    if (typing) {
      _typing[member] = Timer(Duration(seconds: 3), () {
        _typing.remove(member);
        notifyListeners();
      });
    } else {
      _typing.remove(member);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (var timer in _typing.values) {
      timer.cancel();
    }
    _typing.clear();
    super.dispose();
  }
}

int _compareMessageModels(MessageModel a, MessageModel b) {
  if (a.entry.time != b.entry.time) {
    return a.entry.time.compareTo(b.entry.time);
  }
  return a.id.compareTo(b.id);
}

class MessageModel {
  final MessageEntry entry;
  final MessageEntry? replyTo;

  final List<ReactionEntry> _reactions;

  MessageModel({
    required this.entry,
    this.replyTo,
    Iterable<ReactionEntry>? reactions,
  })  :
        // Our reaction list needs to be mutable. This is why we spread
        // instead of taking a list and storing it.
        _reactions = [...?reactions?.where(_validateReaction)],
        assert(entry.id != null);

  void _addReaction(ReactionEntry reaction) {
    if (!_validateReaction(reaction)) {
      return;
    }
    _reactions.add(reaction);
  }

  int get id => entry.id!;
  IrcMessage get msg => entry.msg;

  Map<String, Set<String>> get reactionsByText {
    Map<String, Set<String>> reactionsByText = {};
    for (var entry in _reactions) {
      if (entry.redacted) {
        continue;
      }
      var nick = entry.msg.source!.name;
      var reactionNicks = reactionsByText.putIfAbsent(entry.text, () => {});
      if (entry.unreact) {
        reactionNicks.remove(nick);
      } else {
        reactionNicks.add(nick);
      }
      if (reactionNicks.isEmpty) {
        reactionsByText.remove(entry.text);
      }
    }

    reactionsByText.updateAll((_, set) => UnmodifiableSetView(set));
    return UnmodifiableMapView(reactionsByText);
  }

  Map<String, Set<String>> get reactionsByNickname {
    var reactionsByNickname = <String, Set<String>>{};
    for (var entry in _reactions) {
      if (entry.redacted) {
        continue;
      }
      var nick = entry.msg.source!.name;
      var reactionTexts = reactionsByNickname.putIfAbsent(nick, () => {});
      if (entry.unreact) {
        reactionTexts.remove(entry.text);
      } else {
        reactionTexts.add(entry.text);
      }
      if (reactionTexts.isEmpty) {
        reactionsByNickname.remove(nick);
      }
    }

    reactionsByNickname.updateAll((_, set) => UnmodifiableSetView(set));
    return UnmodifiableMapView(reactionsByNickname);
  }
}

bool _validateReaction(ReactionEntry reaction) {
  // only allow a single grapheme cluster
  return Characters(reaction.text).length == 1;
}

class MemberListModel extends ChangeNotifier {
  final IrcNameMap<String> _members;
  final IrcNameMap<String> _avatars;
  final IrcNameMap<bool> _avatarValues;

  MemberListModel(CaseMapping cm)
      : _members = IrcNameMap(cm),
        _avatars = IrcNameMap(cm),
        _avatarValues = IrcNameMap(cm);

  UnmodifiableMapView<String, String> get members =>
      UnmodifiableMapView(_members);

  String? avatar(String nick) => _avatars[nick];

  bool hasAvatarValue(String nick) => _avatarValues[nick] == true;

  void set(String nick, String prefix) {
    _members[nick] = prefix;
    notifyListeners();
  }

  void setAvatar(String nick, String? avatarUrl) {
    var hadValue = _avatarValues[nick] == true;
    var previous = _avatars[nick];
    _avatarValues[nick] = true;
    if (avatarUrl == null) {
      _avatars.remove(nick);
    } else {
      _avatars[nick] = avatarUrl;
    }
    if (hadValue && previous == avatarUrl) {
      return;
    }
    notifyListeners();
  }

  void setAvatars(Map<String, String> avatars) {
    var changed = false;
    for (var entry in avatars.entries) {
      var hadValue = _avatarValues[entry.key] == true;
      _avatarValues[entry.key] = true;
      if (hadValue && _avatars[entry.key] == entry.value) {
        continue;
      }
      _avatars[entry.key] = entry.value;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void syncAvatars(Iterable<String> nicks, Map<String, String> avatars) {
    var changed = false;
    for (var nick in nicks) {
      var avatarUrl = avatars[nick.toLowerCase()];
      var hadValue = _avatarValues[nick] == true;
      var previous = _avatars[nick];
      _avatarValues[nick] = true;
      if (avatarUrl == null) {
        _avatars.remove(nick);
      } else {
        _avatars[nick] = avatarUrl;
      }
      changed = !hadValue || previous != avatarUrl || changed;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void remove(String nick) {
    var removedMember = _members.remove(nick) != null;
    var removedAvatar = _avatars.remove(nick) != null;
    var removedAvatarValue = _avatarValues.remove(nick) != null;
    if (removedMember || removedAvatar || removedAvatarValue) {
      notifyListeners();
    }
  }
}

class UserListModel extends ChangeNotifier {
  final IrcNameMap<UserModel> _map;

  UserListModel(CaseMapping cm) : _map = IrcNameMap(cm);

  UnmodifiableMapView<String, UserModel> get map => UnmodifiableMapView(_map);

  void updateUser(UserModel updatedUser) {
    var user = _map[updatedUser.nickname];
    if (user == null) {
      _map[updatedUser.nickname] = updatedUser;
      notifyListeners();
      return;
    }
    var changed = false;
    if (updatedUser.realname != null && updatedUser.realname != user.realname) {
      user.realname = updatedUser.realname;
      changed = true;
    }
    if (updatedUser.username != null && updatedUser.username != user.username) {
      user.username = updatedUser.username;
      changed = true;
    }
    if (updatedUser.host != null && updatedUser.host != user.host) {
      user.host = updatedUser.host;
      changed = true;
    }
    if (updatedUser.account != null && updatedUser.account != user.account) {
      user.account = updatedUser.account;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void updateAccount(String nickname, String? account) {
    var user = _map[nickname];
    if (user == null) {
      if (account == null) {
        return;
      }
      _map[nickname] = UserModel(nickname: nickname, account: account);
      notifyListeners();
      return;
    }
    if (user.account == account) {
      return;
    }
    user.account = account;
    notifyListeners();
  }

  void updateHost(String nickname, {String? username, String? host}) {
    var user = _map[nickname];
    if (user == null) {
      if (username == null && host == null) {
        return;
      }
      _map[nickname] = UserModel(
        nickname: nickname,
        username: username,
        host: host,
      );
      notifyListeners();
      return;
    }
    var changed = false;
    if (username != null && username != user.username) {
      user.username = username;
      changed = true;
    }
    if (host != null && host != user.host) {
      user.host = host;
      changed = true;
    }
    if (!changed) {
      return;
    }
    notifyListeners();
  }

  void updateNickname(String oldNickname, String newNickname) {
    var user = _map[oldNickname];
    if (user == null) {
      return;
    }
    _map[newNickname] = user;
    user._nickname = newNickname;
    _map.remove(oldNickname);
    user.notifyListeners();
    notifyListeners();
  }

  void removeUser(String nickname) {
    _map.remove(nickname);
    notifyListeners();
  }
}

class UserModel extends ChangeNotifier {
  String _nickname;
  String? _realname;
  String? _username;
  String? _host;
  String? _account;

  UserModel({
    required String nickname,
    String? realname,
    String? username,
    String? host,
    String? account,
  })  : _nickname = nickname,
        _realname = realname,
        _username = username,
        _host = host,
        _account = account;

  String get nickname => _nickname;
  String? get realname => _realname;
  String? get username => _username;
  String? get host => _host;
  String? get account => _account;

  set realname(String? realname) {
    _realname = realname;
    notifyListeners();
  }

  set username(String? username) {
    _username = username;
    notifyListeners();
  }

  set host(String? host) {
    _host = host;
    notifyListeners();
  }

  set account(String? account) {
    _account = account;
    notifyListeners();
  }
}

String networkStateDescription(NetworkState state) {
  switch (state) {
    case NetworkState.offline:
      return 'Disconnected';
    case NetworkState.connecting:
      return 'Connecting…';
    case NetworkState.registering:
      return 'Logging in…';
    case NetworkState.synchronizing:
      return 'Synchronizing…';
    case NetworkState.online:
      return 'Connected';
  }
}

String bouncerNetworkStateDescription(BouncerNetworkState state) {
  switch (state) {
    case BouncerNetworkState.disconnected:
      return 'Bouncer disconnected from network';
    case BouncerNetworkState.connecting:
      return 'Bouncer connecting to network…';
    case BouncerNetworkState.connected:
      return 'Connected';
  }
}

void setCaseMapping(
    BufferListModel bufferList, NetworkModel network, CaseMapping cm) {
  bufferList._setCaseMapping(network, cm);
  network._users._map.setCaseMapping(cm);
}

bool canSendMessageToBuffer(BufferModel buffer, NetworkModel network) {
  if (network.state != NetworkState.synchronizing &&
      network.state != NetworkState.online) {
    return false;
  }
  if (buffer.archived) {
    return false;
  }
  if (network.networkEntry.isupport.isChannel(buffer.name)) {
    return buffer.joined;
  } else {
    return true;
  }
}
