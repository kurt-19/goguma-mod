import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:workmanager/workmanager.dart';

import 'additional_server_subscription.dart';
import 'client.dart';
import 'database.dart';
import 'irc/irc.dart';
import 'logging.dart';
import 'models.dart';
import 'native_foreground.dart';
import 'native_radio.dart';
import 'notification_controller.dart';
import 'prefs.dart';
import 'profile_backend.dart';
import 'push.dart';
import 'webpush.dart';

const _metadataSubs = ['avatar', 'soju.im/pinned', 'soju.im/muted'];
const statusBufferName = 'Status';
const statusDisplayName = 'STATUS';
const _selfEchoWindow = Duration(seconds: 20);
const _channelEventRetention = Duration(hours: 24);
const _messageRetention = Duration(days: 30);
const _retentionBatchSize = 500;
const _retainedChannelEventCommands = {
  'JOIN',
  'PART',
  'QUIT',
  'KICK',
  'NICK',
  'MODE',
};
const defaultChatChannelName = '#chat';
const _protectedDefaultChannels = {defaultChatChannelName, '#help', '#trivia'};

final List<_PendingSelfEcho> _pendingSelfEchoes = [];

void rememberOptimisticSelfEcho(
    NetworkModel network, String target, String text, int messageId) {
  var now = DateTime.now();
  _pendingSelfEchoes
      .removeWhere((echo) => now.difference(echo.createdAt) > _selfEchoWindow);
  _pendingSelfEchoes.add(_PendingSelfEcho(
    networkId: network.networkId,
    target: network.networkEntry.isupport.caseMapping.canonicalize(target),
    text: text,
    messageId: messageId,
    createdAt: now,
  ));
}

Future<void> appendLocalStatusMessage({
  required DB db,
  required BufferListModel bufferList,
  required NetworkModel network,
  required String text,
  String source = statusDisplayName,
}) async {
  var clean = text.trim();
  if (clean.isEmpty) {
    return;
  }

  var buffer = bufferList.get(statusBufferName, network);
  if (buffer == null) {
    return;
  }

  var msg = IrcMessage('NOTICE', [statusBufferName, clean],
      source: IrcSource(source));
  var entry = MessageEntry(msg, buffer.id);
  await db.storeMessages([entry]);
  if (buffer.messageHistoryLoaded) {
    var models = await buildMessageModelList(db, [entry]);
    buffer.addMessages(models, append: true);
  }
  bufferList.bumpLastDeliveredTime(buffer, entry.time);
}

_PendingSelfEcho? _takeOptimisticSelfEcho(
    NetworkModel network, String target, String text) {
  var now = DateTime.now();
  var canonicalTarget =
      network.networkEntry.isupport.caseMapping.canonicalize(target);
  _pendingSelfEchoes
      .removeWhere((echo) => now.difference(echo.createdAt) > _selfEchoWindow);
  var index = _pendingSelfEchoes.indexWhere((echo) {
    return echo.networkId == network.networkId &&
        echo.target == canonicalTarget &&
        echo.text == text;
  });
  if (index < 0) {
    return null;
  }
  return _pendingSelfEchoes.removeAt(index);
}

bool _isSaslAuthFailureMessage(IrcMessage msg) {
  switch (msg.cmd) {
    case ERR_SASLFAIL:
    case ERR_SASLTOOLONG:
    case ERR_SASLABORTED:
    case ERR_SASLALREADY:
      return true;
    default:
      return false;
  }
}

class _PendingSelfEcho {
  final int networkId;
  final String target;
  final String text;
  final int messageId;
  final DateTime createdAt;

  const _PendingSelfEcho({
    required this.networkId,
    required this.target,
    required this.text,
    required this.messageId,
    required this.createdAt,
  });
}

ConnectParams connectParamsFromServerEntry(ServerEntry entry, Prefs prefs) {
  var nick = entry.nick ?? prefs.nickname;

  SaslPlainCredentials? saslPlain;
  if (entry.saslPlainPassword != null) {
    saslPlain = SaslPlainCredentials(
        entry.saslPlainUsername ?? nick, entry.saslPlainPassword!);
  }

  return ConnectParams(
      host: entry.host,
      port: entry.port ?? (entry.tls ? 6697 : 6667),
      tls: entry.tls,
      nick: nick,
      realname: prefs.realname ?? 'IRC mobile - app',
      pass: entry.pass,
      saslPlain: saslPlain,
      pinnedCertSHA1: entry.pinnedCertSHA1);
}

class ClientException extends IrcException {
  final Client client;
  final NetworkModel network;

  ClientException(IrcException base, this.client, this.network)
      : super(base.msg);
}

class ClientNotice {
  final List<ClientMessage> msgs;
  final String target;
  final Client client;
  final NetworkModel network;

  const ClientNotice(this.msgs, this.target, this.client, this.network);
}

bool isServerBufferName(String name) {
  return name.toLowerCase() == statusBufferName.toLowerCase() ||
      name == '*' ||
      name.startsWith(r'$');
}

String normalizeServerBufferName(String name) {
  return isServerBufferName(name) ? statusBufferName : name;
}

bool isProtectedDefaultChannel(String name) {
  return _protectedDefaultChannels.contains(name.toLowerCase());
}

bool isProtectedDefaultChannelAlias(String name) {
  var lower = name.toLowerCase();
  return !lower.startsWith('#') && isProtectedDefaultChannel('#$lower');
}

bool isStatusNoticeMessage(IrcMessage msg, {String? target}) {
  if (msg.cmd != 'NOTICE') {
    return false;
  }
  var msgTarget = target ?? (msg.params.isNotEmpty ? msg.params[0] : '');
  return msg.source != null &&
      !msgTarget.startsWith('#') &&
      isProtectedDefaultChannelAlias(msg.source!.name);
}

bool _isHostnameLookupNotice(IrcMessage msg) {
  if (msg.cmd != 'NOTICE' || msg.params.length < 2) {
    return false;
  }
  var target = msg.params[0].toLowerCase();
  if (target != 'auth' && target != '*') {
    return false;
  }
  var text = msg.params[1].toLowerCase();
  return text.contains('hostname') &&
      (text.contains('resolve') ||
          text.contains('looking up') ||
          text.contains('found your'));
}

bool _profileEventMatchesNetwork(
    String eventServer, NetworkModel network, Client client) {
  var needle = eventServer.trim().toLowerCase();
  if (needle.isEmpty) {
    return false;
  }
  var candidates = <String?>[
    client.params.host,
    network.serverEntry.host,
    network.displayName,
    network.upstreamName,
    network.bouncerNetwork?.host,
    network.bouncerNetwork?.name,
    network.serverId.toString(),
    network.networkId.toString(),
  ];
  return candidates
      .whereType<String>()
      .map((value) => value.trim().toLowerCase())
      .any((value) => value.isNotEmpty && value == needle);
}

bool isServiceMessageSource(String name) {
  var lower = name.toLowerCase();
  return lower == 'nickserv' ||
      lower == 'nickserver' ||
      lower == 'chanserv' ||
      lower == 'chanserver' ||
      lower == 'operserv' ||
      lower == 'memoserv' ||
      lower == 'memoserver' ||
      lower == 'hostserv' ||
      lower == 'hostserver' ||
      lower == 'botserv' ||
      lower == 'global' ||
      lower == 'services' ||
      lower.contains('service') ||
      lower.endsWith('serv');
}

bool isServiceMessage(IrcMessage msg) {
  if (msg.cmd != 'NOTICE' && msg.cmd != 'PRIVMSG') {
    return false;
  }
  var source = msg.source;
  if (source != null) {
    if (isServiceMessageSource(source.name) ||
        (source.user != null && isServiceMessageSource(source.user!)) ||
        (source.host != null &&
            source.host!.toLowerCase().contains('services'))) {
      return true;
    }
  }
  if (msg.params.isNotEmpty && isServiceMessageSource(msg.params[0])) {
    return true;
  }
  if (msg.cmd == 'NOTICE' && msg.params.length > 1) {
    var text = msg.params[1].toLowerCase();
    return text.startsWith('-nickserv-') ||
        text.startsWith('-chanserv-') ||
        text.startsWith('[nickserv]') ||
        text.startsWith('[chanserv]') ||
        text.contains('nickserv') ||
        text.contains('chanserv') ||
        text.contains('operserv') ||
        text.contains('memoserv') ||
        text.contains('hostserv');
  }
  return false;
}

bool isServiceMessageTarget(String target) {
  return isServerBufferName(target) || isServiceMessageSource(target);
}

class BackgroundSyncStatus {
  final bool isUnavailable;
  final bool needServicePermissions;

  const BackgroundSyncStatus({
    this.isUnavailable = false,
    this.needServicePermissions = false,
  });
}

/// A data structure which keeps track of IRC clients.
class ClientProvider {
  final Map<NetworkModel, ClientController> _controllers = {};
  final StreamController<ClientException> _errorsController =
      StreamController.broadcast(sync: true);
  final StreamController<ClientNotice> _noticesController =
      StreamController.broadcast(sync: true);
  final StreamController<NetworkModel> _networkStatesController =
      StreamController.broadcast(sync: true);
  final Set<ClientAutoReconnectLock> _autoReconnectLocks = {};

  final DB _db;
  final NetworkListModel _networkList;
  final BufferListModel _bufferList;
  final BouncerNetworkListModel _bouncerNetworkList;
  final NotificationController _notifController;
  final AdditionalServerSubscription _serverSubscription;
  final bool _enableSync;
  final PushController? _pushController;

  final ValueNotifier<BackgroundSyncStatus> backgroundSyncStatus =
      ValueNotifier(BackgroundSyncStatus());
  bool _workManagerSyncEnabled = false;
  bool _shutdownForExit = false;
  ClientAutoReconnectLock? _backgroundServiceAutoReconnectLock;
  Timer? _messageCleanupTimer;
  bool _messageCleanupRunning = false;

  UnmodifiableListView<Client> get clients =>
      UnmodifiableListView(_controllers.entries
          .where((entry) => canUseNetwork(entry.key))
          .map((entry) => entry.value.client));
  Stream<ClientException> get errors => _errorsController.stream;
  Stream<ClientNotice> get notices => _noticesController.stream;
  Stream<NetworkModel> get networkStates => _networkStatesController.stream;
  bool get shutdownForExitRequested => _shutdownForExit;

  ClientProvider({
    required DB db,
    required NetworkListModel networkList,
    required BufferListModel bufferList,
    required BouncerNetworkListModel bouncerNetworkList,
    required NotificationController notifController,
    required AdditionalServerSubscription serverSubscription,
    bool enableSync = true,
    PushController? pushController,
  })  : _db = db,
        _networkList = networkList,
        _bufferList = bufferList,
        _bouncerNetworkList = bouncerNetworkList,
        _notifController = notifController,
        _serverSubscription = serverSubscription,
        _enableSync = enableSync,
        _pushController = pushController {
    _serverSubscription.addListener(_handleServerSubscriptionChanged);
    ProfileBackendClient.avatarChanges.listen(_handleProfileAvatarChange);
    _scheduleMessageCleanup(Duration.zero);
  }

  // Takes ownership of the Client.
  void add(Client client, NetworkModel network) {
    _shutdownForExit = false;
    var controller = ClientController._(this, client, network);
    _controllers[network] = controller;
    controller._syncNetworkState(client.state);
    _scheduleMessageCleanup(Duration.zero);
  }

  void _scheduleMessageCleanup(Duration delay) {
    if (_shutdownForExit) {
      return;
    }
    _messageCleanupTimer?.cancel();
    _messageCleanupTimer = Timer(delay, _runMessageCleanup);
  }

  void _scheduleNextMessageCleanup() {
    var now = DateTime.now();
    var nextCleanup = now.add(const Duration(hours: 1));
    for (var buffer in _bufferList.buffers) {
      var isChannel = buffer.network.networkEntry.isupport
          .isChannel(buffer.name);
      for (var message in buffer.messages) {
        var retention = isChannel &&
                _retainedChannelEventCommands.contains(message.msg.cmd)
            ? _channelEventRetention
            : _messageRetention;
        var expiry = message.entry.dateTime.add(retention);
        if (expiry.isBefore(nextCleanup)) {
          nextCleanup = expiry;
        }
      }
    }
    var delay = nextCleanup.difference(now);
    _scheduleMessageCleanup(delay.isNegative ? Duration.zero : delay);
  }

  Future<void> _runMessageCleanup() async {
    if (_messageCleanupRunning || _shutdownForExit) {
      return;
    }
    _messageCleanupRunning = true;
    var deletedCount = 0;
    try {
      var now = DateTime.now();
      var retainedBuffers = _bufferList.buffers.toList();
      var remainingBatch = _retentionBatchSize;

      for (var buffer in retainedBuffers) {
        if (remainingBatch == 0) {
          break;
        }
        var isChannel = buffer.network.networkEntry.isupport
            .isChannel(buffer.name);
        var expiredIds = buffer.messages.where((message) {
          var retention = isChannel &&
                  _retainedChannelEventCommands.contains(message.msg.cmd)
              ? _channelEventRetention
              : _messageRetention;
          return !message.entry.dateTime.add(retention).isAfter(now);
        }).take(remainingBatch).map((message) => message.id).toList();
        if (expiredIds.isEmpty) {
          continue;
        }
        await _db.deleteMessages(expiredIds);
        buffer.removeMessages(expiredIds);
        deletedCount += expiredIds.length;
        remainingBatch -= expiredIds.length;
      }

      var oldIdsByBuffer = remainingBatch == 0
          ? <int, List<int>>{}
          : await _db.takeMessageIdsBefore(
              retainedBuffers.map((buffer) => buffer.id),
              formatIrcTime(now.subtract(_messageRetention)),
              remainingBatch,
            );
      for (var entry in oldIdsByBuffer.entries) {
        await _db.deleteMessages(entry.value);
        _bufferList.byId(entry.key)?.removeMessages(entry.value);
        deletedCount += entry.value.length;
        remainingBatch -= entry.value.length;
      }

      var oldReactionIdsByBuffer = remainingBatch == 0
          ? <int, List<int>>{}
          : await _db.takeReactionIdsBefore(
              retainedBuffers.map((buffer) => buffer.id),
              formatIrcTime(now.subtract(_messageRetention)),
              remainingBatch,
            );
      for (var entry in oldReactionIdsByBuffer.entries) {
        await _db.deleteReactions(entry.value);
        _bufferList.byId(entry.key)?.removeReactions(entry.value);
        deletedCount += entry.value.length;
        remainingBatch -= entry.value.length;
      }
    } on Object catch (err) {
      log.print('Failed to clean up retained messages', error: err);
    } finally {
      _messageCleanupRunning = false;
    }

    if (deletedCount >= _retentionBatchSize) {
      _scheduleMessageCleanup(const Duration(seconds: 2));
    } else {
      _scheduleNextMessageCleanup();
    }
  }

  bool canUseNetwork(NetworkModel network) {
    return _serverSubscription.canUseServer(
      network.serverId,
      _networkList.networks.map((item) => item.serverId),
    );
  }

  void _handleServerSubscriptionChanged() {
    for (var entry in _controllers.entries) {
      var allowed = canUseNetwork(entry.key);
      var client = entry.value.client;
      client.autoReconnect =
          allowed && !_shutdownForExit && _autoReconnectLocks.isNotEmpty;
      if (!allowed) {
        client.disconnect();
      } else if (_autoReconnectLocks.isNotEmpty &&
          client.state == ClientState.disconnected) {
        client.connect().ignore();
      }
    }
  }

  Client get(NetworkModel network) {
    return _controllers[network]!.client;
  }

  void remove(NetworkModel network) {
    var client = get(network);
    _controllers.remove(network);
    _bufferList.removeByNetwork(network);
    _networkList.remove(network);
    client.dispose();
  }

  void clear() {
    for (var cc in _controllers.values) {
      cc.client.dispose();
    }
    _controllers.clear();
    _bufferList.clear();
    _networkList.clear();
  }

  void _handleProfileAvatarChange(ProfileAvatarChange change) {
    for (var entry in _controllers.entries) {
      var network = entry.key;
      var client = entry.value.client;
      if (network.state == NetworkState.offline ||
          !_profileEventMatchesNetwork(change.server, network, client)) {
        continue;
      }
      var cm = client.isupport.caseMapping;
      for (var buffer in _bufferList.buffers) {
        if (buffer.network != network) {
          continue;
        }
        if (buffer.members?.members.containsKey(change.nick) == true) {
          buffer.members!.setAvatar(change.nick, change.avatarUrl);
        }
        if (client.isNick(buffer.name) && cm.equals(buffer.name, change.nick)) {
          buffer.setBackendAvatar(change.avatarUrl);
        }
      }
    }
  }

  void disconnectAll() {
    if (!_autoReconnectLocks.isEmpty) {
      return;
    }
    for (var client in clients) {
      client.disconnect();
    }
  }

  Future<void> shutdownForExit() async {
    _shutdownForExit = true;
    _messageCleanupTimer?.cancel();
    _messageCleanupTimer = null;
    _autoReconnectLocks.clear();
    _backgroundServiceAutoReconnectLock = null;
    _workManagerSyncEnabled = false;
    backgroundSyncStatus.value = BackgroundSyncStatus();

    await Workmanager().cancelByUniqueName('sync');
    await Workmanager().cancelAll();
    if (Platform.isAndroid && FlutterBackground.isBackgroundExecutionEnabled) {
      await FlutterBackground.disableBackgroundExecution();
    }
    await NativeRadioPlayback.stop(updateForeground: false);
    await NativeForegroundService.stop();

    for (var client in clients) {
      client.autoReconnect = false;
      client.send(IrcMessage('QUIT', ['IRC mobile - app']));
      client.disconnect();
    }
  }

  void _setupSync() {
    if (!_enableSync || _shutdownForExit) {
      return;
    }

    var registeredClients =
        clients.where((client) => client.registered).toList();
    if (registeredClients.isEmpty) {
      return;
    }

    var hasChatHistory = registeredClients.every((client) {
      return client.caps.available.containsKey('draft/chathistory');
    });
    var hasWebPush = registeredClients.every((client) {
      return client.caps.available.containsKey('soju.im/webpush');
    });

    var useWorkManager = Platform.isAndroid && hasChatHistory;
    var usePush = _pushController != null && hasWebPush;
    _setupWorkManagerSync(useWorkManager, usePush);
    _setupBackgroundServiceSync(true);

    if (Platform.isIOS && !hasChatHistory) {
      // Background service is unavailable on iOS
      backgroundSyncStatus.value = BackgroundSyncStatus(
        isUnavailable: true,
      );
    }
  }

  void _setupWorkManagerSync(bool enable, bool lowFreq) {
    if (enable == _workManagerSyncEnabled) {
      return;
    }
    _workManagerSyncEnabled = enable;

    if (!enable) {
      log.print('Disabling sync work manager');
      Workmanager().cancelByUniqueName('sync');
      return;
    }

    var freq = Duration(minutes: 15);
    if (lowFreq) {
      freq = Duration(hours: 4);
    }

    log.print('Enabling sync work manager (frequency: $freq)');
    Workmanager().registerPeriodicTask(
      'sync',
      'sync',
      frequency: freq,
      tag: 'sync',
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      initialDelay: freq,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  void _setupBackgroundServiceSync(bool enable) async {
    if (!Platform.isAndroid) {
      return;
    }
    if (_shutdownForExit) {
      return;
    }

    if (!enable) {
      backgroundSyncStatus.value = BackgroundSyncStatus();
      _backgroundServiceAutoReconnectLock?.release();
      _backgroundServiceAutoReconnectLock = null;
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        log.print('Disabling sync background service');
        unawaited(FlutterBackground.disableBackgroundExecution());
      }
      return;
    }

    if (FlutterBackground.isBackgroundExecutionEnabled) {
      _backgroundServiceAutoReconnectLock?.release();
      _backgroundServiceAutoReconnectLock =
          ClientAutoReconnectLock.acquire(this);
      return;
    }

    var hasPermissions = await FlutterBackground.hasPermissions;
    backgroundSyncStatus.value = BackgroundSyncStatus(
      needServicePermissions: !hasPermissions,
    );
    askBackgroundServicePermissions();
  }

  void askBackgroundServicePermissions() async {
    if (_shutdownForExit) {
      return;
    }
    log.print('Enabling sync background service');

    _syncForegroundConnectionNick();

    var success = await FlutterBackground.initialize(
        androidConfig: FlutterBackgroundAndroidConfig(
      notificationTitle: NativeRadioPlayback.notificationText,
      notificationText: NativeRadioPlayback.station.name,
      notificationIcon: AndroidResource(name: 'ic_notification_irc'),
      enableWifiLock: true,
      shouldRequestBatteryOptimizationsOff: false,
    ));
    backgroundSyncStatus.value = BackgroundSyncStatus(
      needServicePermissions: !success,
    );
    if (!success) {
      log.print('Failed to obtain permissions for background service');
      return;
    }

    try {
      success = await FlutterBackground.enableBackgroundExecution();
    } on Exception catch (err) {
      log.print('Failed to enable sync background service', error: err);
      success = false;
    }
    if (success) {
      log.print('Enabled sync background service');
      _backgroundServiceAutoReconnectLock?.release();
      _backgroundServiceAutoReconnectLock =
          ClientAutoReconnectLock.acquire(this);
      NativeForegroundService.start(
        title: NativeRadioPlayback.notificationText,
        text: NativeRadioPlayback.station.name,
        radioPlaying: NativeRadioPlayback.isPlaying ||
            NativeRadioPlayback.status == 'Connecting' ||
            NativeRadioPlayback.status == 'Switching',
        radioUrl: NativeRadioPlayback.station.url,
      ).ignore();
    } else {
      log.print('Failed to enable sync background service');
    }
  }

  String? _foregroundConnectionNick() {
    for (var controller in _controllers.values) {
      var nick = controller.network.nickname.trim();
      if (controller.client.registered && nick.isNotEmpty) {
        return '${controller.network.serverDisplayName}: $nick';
      }
    }
    for (var controller in _controllers.values) {
      var nick = controller.network.nickname.trim();
      if (nick.isNotEmpty) {
        return '${controller.network.serverDisplayName}: $nick';
      }
    }
    return null;
  }

  void _syncForegroundConnectionNick({bool refreshNotification = false}) {
    var nick = _foregroundConnectionNick();
    if (NativeRadioPlayback.connectionNick == nick) {
      return;
    }

    NativeRadioPlayback.connectionNick = nick;
    if (!refreshNotification || !Platform.isAndroid) {
      return;
    }

    var radioActive = NativeRadioPlayback.isPlaying ||
        NativeRadioPlayback.status == 'Connecting' ||
        NativeRadioPlayback.status == 'Switching';
    if (!radioActive && !FlutterBackground.isBackgroundExecutionEnabled) {
      return;
    }

    NativeForegroundService.start(
      title: NativeRadioPlayback.notificationText,
      text: NativeRadioPlayback.station.name,
      radioPlaying: radioActive,
      radioUrl: NativeRadioPlayback.station.url,
    ).ignore();
  }

  Future<void> fetchBufferUser(BufferModel buffer) async {
    var client = get(buffer.network);
    List<WhoReply> replies;
    try {
      replies = await client.who(buffer.name);
    } on Exception catch (err) {
      log.print('Failed to fetch WHO ${buffer.name}', error: err);
      return;
    }

    if (replies.length == 0) {
      return; // User is offline
    } else if (replies.length != 1) {
      throw FormatException(
          'Expected a single WHO reply, got ${replies.length}');
    }

    var reply = replies[0];
    buffer.realname = reply.realname;
    buffer.away = reply.away;
    unawaited(_db.storeBuffer(buffer.entry));

    buffer.network.users.updateUser(UserModel(
      nickname: reply.nickname,
      realname: reply.realname,
      username: reply.username,
      host: reply.host,
      account: reply.account,
    ));
  }

  Future<void> fetchChatHistory(BufferModel buffer) async {
    var controller = _controllers[buffer.network]!;
    var client = controller.client;

    String? before;
    if (!buffer.messages.isEmpty) {
      before = buffer.messages.first.entry.time;
    }

    var limit = 100;
    ClientBatch batch;
    if (before != null) {
      batch = await client.fetchChatHistoryBefore(buffer.name, before, limit);
    } else {
      batch = await client.fetchChatHistoryLatest(buffer.name, null, limit);
    }

    await controller._handleChatMessages(buffer.name, batch.messages);
  }
}

/// A lock which enables automatic reconnection when enabled.
class ClientAutoReconnectLock {
  final ClientProvider _provider;

  ClientAutoReconnectLock.acquire(this._provider) {
    _provider._autoReconnectLocks.add(this);
    _updateAutoReconnect();
  }

  void release() {
    _provider._autoReconnectLocks.remove(this);
    _updateAutoReconnect();
  }

  void _updateAutoReconnect() {
    for (var entry in _provider._controllers.entries) {
      entry.value.client.autoReconnect = _provider.canUseNetwork(entry.key) &&
          !_provider._shutdownForExit &&
          !_provider._autoReconnectLocks.isEmpty;
    }
  }
}

/// A helper which integrates a [Client] with app models.
class ClientController {
  final ClientProvider _provider;

  final Client _client;
  final NetworkModel _network;

  String? _prevLastDeliveredTime;
  bool _gotInitialBouncerNetworksBatch = false;
  final Set<int> _preparingChannelUserLists = {};
  final Set<int> _preparedChannelUserLists = {};

  Client get client => _client;
  NetworkModel get network => _network;

  DB get _db => _provider._db;
  NetworkListModel get _networkList => _provider._networkList;
  BufferListModel get _bufferList => _provider._bufferList;
  BouncerNetworkListModel get _bouncerNetworkList =>
      _provider._bouncerNetworkList;
  NotificationController get _notifController => _provider._notifController;

  ClientController._(this._provider, this._client, this._network) {
    assert(client.state == ClientState.disconnected);

    client.autoReconnect = _provider.canUseNetwork(network) &&
        !_provider._autoReconnectLocks.isEmpty;

    client.states.listen(_syncNetworkState);

    late StreamSubscription<void> messagesSub;
    messagesSub = client.messages.listen((msg) {
      var future = _handleMessage(msg);
      if (future != null) {
        messagesSub.pause();
        future.whenComplete(() => messagesSub.resume());
      }
    });

    client.connectErrors.listen((err) {
      if (err is SocketException) {
        network.connectError = 'Network error: ${err.message}';
      } else {
        network.connectError = err.toString();
      }
    });

    client.isupportStream.listen((isupport) {
      network.upstreamName = isupport.network;
      if (isupport.bouncerNetId != null) {
        network.bouncerNetwork =
            _bouncerNetworkList.networks[isupport.bouncerNetId!];
      } else {
        network.bouncerNetwork = null;
      }
      setCaseMapping(_bufferList, network, isupport.caseMapping);

      network.networkEntry.isupport = isupport;
      _db.storeNetwork(network.networkEntry);
    });
  }

  void _syncNetworkState(ClientState state) {
    switch (state) {
      case ClientState.disconnected:
        network.state = NetworkState.offline;
        network.isIrcOperator = false;
        _preparingChannelUserLists.clear();
        _preparedChannelUserLists.clear();
        for (var buffer in _bufferList.buffers) {
          if (buffer.network == network) {
            buffer.joined = false;
            buffer.online = null;
            buffer.away = null;
          }
        }
        _gotInitialBouncerNetworksBatch = false;
        break;
      case ClientState.connecting:
        network.isIrcOperator = false;
        // TODO: drop _getLastDeliveredTime() in a future release
        _prevLastDeliveredTime =
            _network.networkEntry.lastDeliveredTime ?? _getLastDeliveredTime();
        network.state = NetworkState.connecting;
        break;
      case ClientState.connected:
        network.state =
            client.registered ? NetworkState.online : NetworkState.registering;
        network.connectError = null;
        break;
    }
  }

  String? _getLastDeliveredTime() {
    String? last;
    for (var buffer in _bufferList.buffers) {
      if (buffer.network != network || buffer.lastDeliveredTime == null) {
        continue;
      }
      if (last == null || last.compareTo(buffer.lastDeliveredTime!) < 0) {
        last = buffer.lastDeliveredTime;
      }
    }
    return last;
  }

  Future<void> _fetchPrivateAvatars(Iterable<String> nicks) async {
    if (!client.registered) {
      return;
    }
    var requestedNicks = nicks.toList(growable: false);
    var avatars = await const ProfileBackendClient()
        .fetchAvatarUrls(client.params.host, requestedNicks);
    for (var buffer in _bufferList.buffers) {
      if (buffer.network != network ||
          !client.isNick(buffer.name) ||
          buffer.archived) {
        continue;
      }
      var avatar = avatars[buffer.name.toLowerCase()];
      var requested = requestedNicks
          .any((nick) => client.isupport.caseMapping.equals(nick, buffer.name));
      if (!requested ||
          (buffer.hasBackendAvatarValue && buffer.avatar == avatar)) {
        continue;
      }
      buffer.setBackendAvatar(avatar);
    }
  }

  Future<void> _prepareChannelUserList(BufferModel buffer) async {
    if (!client.registered ||
        !client.isChannel(buffer.name) ||
        buffer.archived ||
        _preparedChannelUserLists.contains(buffer.id) ||
        !_preparingChannelUserLists.add(buffer.id)) {
      return;
    }

    try {
      List<WhoReply> replies;
      try {
        replies = await client.who(buffer.name);
      } on Exception catch (err) {
        log.print('Failed to prepare WHO for ${buffer.name}', error: err);
        return;
      }

      if (replies.isEmpty) {
        return;
      }
      if (!buffer.joined || buffer.archived) {
        return;
      }

      var members = MemberListModel(client.isupport.caseMapping);
      for (var reply in replies) {
        members.set(reply.nickname, reply.membershipPrefix ?? '');
        network.users.updateUser(UserModel(
          nickname: reply.nickname,
          realname: reply.realname,
          username: reply.username,
          host: reply.host,
          account: reply.account,
        ));
      }
      buffer.members = members;

      var avatarNicks =
          replies.map((reply) => reply.nickname).take(80).toList();
      var avatars = await const ProfileBackendClient()
          .fetchAvatarUrls(client.params.host, avatarNicks);
      buffer.members?.syncAvatars(avatarNicks, avatars);
      _preparedChannelUserLists.add(buffer.id);
    } finally {
      _preparingChannelUserLists.remove(buffer.id);
    }
  }

  Future<BufferModel> _ensureDefaultChatBuffer() async {
    var buffer = _bufferList.get(defaultChatChannelName, network);
    if (buffer != null) {
      if (buffer.archived) {
        buffer.archived = false;
        await _db.storeBuffer(buffer.entry);
      }
      return buffer;
    }

    var entry = await _db.storeBuffer(
        BufferEntry(name: defaultChatChannelName, network: network.networkId));
    buffer = BufferModel(entry: entry, network: network);
    _bufferList.add(buffer);
    return buffer;
  }

  Future<void> _joinChannelsAfterNickRecovery(List<String> channels) async {
    var defaultChatBuffer = await _ensureDefaultChatBuffer();
    if (!channels.any((channel) =>
        client.isupport.caseMapping.equals(channel, defaultChatBuffer.name))) {
      channels = [defaultChatBuffer.name, ...channels];
    }
    if (channels.isEmpty) {
      return;
    }
    await client.automatedNickRecoveryDone;
    if (client.state != ClientState.connected) {
      return;
    }
    await client.join(channels);
  }

  Future<void>? _handleMessage(ClientMessage msg) {
    var noSuchNickTarget = _privateNoSuchNickTarget(msg);
    if (msg.cmd == ERR_NOSUCHNICK && noSuchNickTarget == null) {
      return null;
    }
    if (msg.isError() &&
        noSuchNickTarget == null &&
        !(network.serverEntry.saslPlainPassword != null &&
            _isSaslAuthFailureMessage(msg))) {
      return appendLocalStatusMessage(
        db: _db,
        bufferList: _bufferList,
        network: network,
        text: IrcException(msg).toString(),
        source: msg.source.name,
      );
    }

    switch (msg.cmd) {
      case ERR_NOSUCHNICK:
        if (noSuchNickTarget != null) {
          return _handlePrivateNoSuchNick(msg, noSuchNickTarget);
        }
        break;
      case RPL_WELCOME:
        network.nickname = client.nick;
        network.isIrcOperator = false;
        _provider._syncForegroundConnectionNick(refreshNotification: true);
        break;
      case RPL_YOUREOPER:
        network.isIrcOperator = true;
        break;
      case 'CAP':
        switch (msg.params[1].toUpperCase()) {
          case 'LS':
          case 'NEW':
          case 'DEL':
            network.networkEntry.caps = client.caps.available;
            _db.storeNetwork(network.networkEntry);
            break;
        }
        break;
      case RPL_ENDOFMOTD:
      case ERR_NOMOTD:
        // These messages are used to indicate the end of the ISUPPORT list
        if (network.state != NetworkState.registering) {
          break;
        }

        _provider._syncForegroundConnectionNick(refreshNotification: true);
        _provider._setupSync();
        network.networkEntry.caps = client.caps.available;
        _db.storeNetwork(network.networkEntry);

        if (client.caps.available.containsKey('draft/metadata-2')) {
          client.send(IrcMessage('METADATA', ['*', 'SUB', ..._metadataSubs]));
        }

        // Send WHO commands for each recent user buffer
        var now = DateTime.now();
        var limit = const Duration(days: 5);
        List<String> nicks = [];
        for (var buffer in _bufferList.buffers) {
          if (buffer.network != network ||
              !client.isNick(buffer.name) ||
              buffer.archived) {
            continue;
          }
          var t = buffer.lastDeliveredTime;
          if (t != null && now.difference(DateTime.parse(t)) > limit) {
            continue;
          }
          _provider.fetchBufferUser(buffer);
          nicks.add(buffer.name);
        }
        if (client.isupport.monitor != null) {
          client.monitor(nicks);
        }
        if (nicks.isNotEmpty) {
          unawaited(_fetchPrivateAvatars(nicks));
        }

        List<Future<void>> syncFutures = [];

        if (client.caps.enabled.contains('soju.im/webpush')) {
          syncFutures.add(_setupPushSync());
        }

        List<String> channels = [defaultChatChannelName];

        // TODO: use a different cap, see:
        // https://github.com/ircv3/ircv3-ideas/issues/91
        if (!client.caps.enabled.contains('soju.im/bouncer-networks')) {
          for (var buffer in _bufferList.buffers) {
            if (buffer.network == network &&
                client.isChannel(buffer.name) &&
                !buffer.archived &&
                !channels.any((channel) =>
                    client.isupport.caseMapping.equals(channel, buffer.name))) {
              channels.add(buffer.name);
            }
          }
        }
        syncFutures.add(_joinChannelsAfterNickRecovery(channels));

        // Query latest read marker for user targets which have unread
        // messages (another client might have marked these as read).
        if (client.supportsReadMarker()) {
          for (var buffer in _bufferList.buffers) {
            if (buffer.network == network &&
                !client.isChannel(buffer.name) &&
                buffer.unreadCount > 0) {
              syncFutures.add(client.fetchReadMarker(buffer.name));
            }
          }
        }

        if (_prevLastDeliveredTime != null) {
          var to = msg.tags['time'] ?? formatIrcTime(DateTime.now());
          syncFutures.add(_fetchBacklog(_prevLastDeliveredTime!, to));
        }

        network.state = NetworkState.online;
        if (syncFutures.isNotEmpty) {
          () async {
            try {
              await Future.wait(syncFutures);
            } on Exception catch (err) {
              log.print('Failed to synchronize network', error: err);
            }
          }();
        }
        break;
      case 'JOIN':
        var channel = msg.params[0];
        var hideRecoveryEvent = client.consumeAutomatedNickRecoveryMessage(msg);
        network.users.updateHost(
          msg.source.name,
          username: msg.source.user,
          host: msg.source.host,
        );
        // TODO: drop the length check once this is widely deployed:
        // https://codeberg.org/emersion/soju/commit/a2a4181440824b29bf2b317cbcf77a527f54e10c
        if (client.caps.enabled.contains('extended-join') &&
            msg.params.length >= 3) {
          var account = msg.params[1] != '*' ? msg.params[1] : null;
          var realname = msg.params[2];
          network.users.updateUser(UserModel(
            nickname: msg.source.name,
            realname: realname,
          ));
          network.users.updateAccount(msg.source.name, account);
        }

        if (client.isMyNick(msg.source.name)) {
          return _createBuffer(channel).then((buffer) {
            buffer.joined = true;
            unawaited(_prepareChannelUserList(buffer));
            return hideRecoveryEvent ? null : _appendChannelEvent(buffer, msg);
          });
        } else {
          var buffer = _bufferList.get(channel, network);
          buffer?.members?.set(msg.source.name, '');
          if (buffer != null) {
            return _appendChannelEvent(buffer, msg);
          }
        }
        break;
      case 'PART':
        var channel = msg.params[0];
        var buffer = _bufferList.get(channel, network);
        if (client.isMyNick(msg.source.name)) {
          buffer?.joined = false;
          buffer?.members = null;
          if (buffer != null) {
            _preparingChannelUserLists.remove(buffer.id);
            _preparedChannelUserLists.remove(buffer.id);
          }
        } else {
          buffer?.members?.remove(msg.source.name);
        }
        return buffer != null ? _appendChannelEvent(buffer, msg) : null;
      case 'QUIT':
        List<Future<void>> quitEvents = [];
        for (var buffer in _bufferList.buffers) {
          if (buffer.network == network &&
              buffer.members?.members.containsKey(msg.source.name) == true) {
            quitEvents.add(_appendChannelEvent(buffer, msg));
            buffer.members?.remove(msg.source.name);
          }
        }

        network.users.removeUser(msg.source.name);
        if (quitEvents.isNotEmpty) {
          return Future.wait(quitEvents).then((_) {});
        }
        break;
      case 'KICK':
        var channel = msg.params[0];
        var nick = msg.params[1];
        var buffer = _bufferList.get(channel, network);
        if (client.isMyNick(nick)) {
          buffer?.joined = false;
          buffer?.members = null;
          if (buffer != null) {
            _preparingChannelUserLists.remove(buffer.id);
            _preparedChannelUserLists.remove(buffer.id);
          }
        } else {
          buffer?.members?.remove(nick);
        }
        return buffer != null ? _appendChannelEvent(buffer, msg) : null;
      case 'MODE':
        var target = msg.params[0];

        if (!client.isChannel(target)) {
          if (client.isMyNick(target)) {
            for (var param in msg.params.skip(1)) {
              var adding = true;
              for (var char in param.split('')) {
                if (char == '+') {
                  adding = true;
                } else if (char == '-') {
                  adding = false;
                } else if (char == 'o') {
                  network.isIrcOperator = adding;
                }
              }
            }
          }
          break;
        }

        var buffer = _bufferList.get(target, network);
        if (buffer == null) {
          break;
        }

        try {
          var updates = ChanModeUpdate.parse(msg, client.isupport);
          for (var update in updates) {
            _handleChanModeUpdate(buffer, update);
          }
        } on FormatException catch (err) {
          log.print('Failed to parse channel mode update', error: err);
        }
        return _appendChannelEvent(buffer, msg);
      case 'AWAY':
        var away = msg.params.length > 0;
        _bufferList.get(msg.source.name, network)?.away = away;
        break;
      case 'CHGHOST':
        network.users.updateHost(
          msg.source.name,
          username: msg.params[0],
          host: msg.params[1],
        );
        break;
      case 'ACCOUNT':
        var account = msg.params[0] != '*' ? msg.params[0] : null;
        if (client.isMyNick(msg.source.name)) {
          network.account = account;
        }
        network.users.updateAccount(msg.source.name, account);
        break;
      case 'NICK':
        var newNickname = msg.params[0];
        var hideRecoveryEvent = client.consumeAutomatedNickRecoveryMessage(msg);
        List<Future<void>> nickEvents = [];

        if (client.isupport.caseMapping
            .equals(network.nickname, msg.source.name)) {
          network.nickname = newNickname;
          _provider._syncForegroundConnectionNick(refreshNotification: true);
        }

        for (var buffer in _bufferList.buffers) {
          if (buffer.network == network &&
              buffer.members?.members.containsKey(msg.source.name) == true) {
            if (!hideRecoveryEvent) {
              nickEvents.add(_appendChannelEvent(buffer, msg));
            }
            buffer.members!
                .set(newNickname, buffer.members!.members[msg.source.name]!);
            buffer.members!.remove(msg.source.name);
          }
        }

        network.users.updateNickname(msg.source.name, newNickname);
        if (nickEvents.isNotEmpty) {
          return Future.wait(nickEvents).then((_) {});
        }
        break;
      case 'SETNAME':
        var realname = msg.params[0];

        if (client.isMyNick(msg.source.name)) {
          network.realname = realname;
        }

        var buffer = _bufferList.get(msg.source.name, network);
        if (buffer != null) {
          buffer.realname = realname;
          _db.storeBuffer(buffer.entry);
        }

        network.users.updateUser(UserModel(
          nickname: msg.source.name,
          realname: realname,
        ));
        break;
      case RPL_LOGGEDIN:
        var account = msg.params[2];
        network.account = account;
        network.users.updateAccount(network.nickname, account);
        break;
      case RPL_LOGGEDOUT:
        network.account = null;
        network.users.updateAccount(network.nickname, null);
        break;
      case RPL_TOPIC:
        var channel = msg.params[1];
        var topic = msg.params[2];
        var buffer = _bufferList.get(channel, network);
        if (buffer != null) {
          buffer.topic = topic;
          _db.storeBuffer(buffer.entry);
        }
        break;
      case RPL_NOTOPIC:
        var channel = msg.params[1];
        var buffer = _bufferList.get(channel, network);
        if (buffer != null) {
          buffer.topic = null;
          _db.storeBuffer(buffer.entry);
        }
        break;
      case 'TOPIC':
        var channel = msg.params[0];
        String? topic;
        if (msg.params[1] != '') {
          topic = msg.params[1];
        }
        var buffer = _bufferList.get(channel, network);
        if (buffer != null) {
          buffer.topic = topic;
          _db.storeBuffer(buffer.entry);
        }
        break;
      case RPL_ENDOFNAMES:
        var channel = msg.params[1];
        var endOfNames = msg as ClientEndOfNames;
        var names = endOfNames.names;
        var members = MemberListModel(client.isupport.caseMapping);
        for (var member in names.members) {
          members.set(member.nickname, member.prefix);
          network.users.updateHost(
            member.nickname,
            username: member.source.user,
            host: member.source.host,
          );
        }
        var buffer = _bufferList.get(channel, network);
        buffer?.members = members;
        if (buffer != null) {
          unawaited(_prepareChannelUserList(buffer));
        }
        break;
      case 'METADATA':
        if (msg.params.length < 4) {
          break;
        }
        var target = msg.params[0];
        var key = msg.params[1];
        var value = msg.params[3];
        var buffer = _bufferList.get(target, network);
        if (buffer != null) {
          switch (key) {
            case 'avatar':
              buffer.avatar = value;
              break;
            case 'soju.im/pinned':
              _bufferList.setPinned(buffer, value == '1');
              break;
            case 'soju.im/muted':
              _bufferList.setMuted(buffer, value == '1');
              break;
          }
          _db.storeBuffer(buffer.entry);
        }
        break;
      case 'PRIVMSG':
      case 'NOTICE':
      case 'TAGMSG':
        if (client.consumeAutomatedNickRecoveryMessage(msg)) {
          break;
        }
        var target = msg.params[0];
        if (msg.batchByType('chathistory') != null) {
          break;
        }

        if (_isHostnameLookupNotice(msg)) {
          break;
        }

        if (isStatusNoticeMessage(msg, target: target)) {
          return _handleChatMessages(statusBufferName, [msg]);
        }

        if (isServiceMessage(msg) || isServiceMessageTarget(target)) {
          return _handleChatMessages(statusBufferName, [msg]);
        }

        var i = parseTargetPrefix(target, client.isupport.statusMsg);
        if (i > 0) {
          var channel = target.substring(i);
          if (client.isChannel(channel)) {
            target = channel;
          }
        }

        if (isServerBufferName(target)) {
          return _handleChatMessages(statusBufferName, [msg]);
        }

        // target can be my own nick for direct messages, "*" for server
        // messages, "$xxx" for server-wide broadcasts
        if (!client.isChannel(target) && !client.isMyNick(msg.source.name)) {
          var channelCtx = msg.tags['+channel-context'] ??
              msg.tags['+draft/channel-context'];
          if (channelCtx != null &&
              client.isChannel(channelCtx) &&
              _bufferList.get(channelCtx, network) != null) {
            target = channelCtx;
          } else {
            target = msg.source.name;
          }
        }

        if (msg.cmd == 'TAGMSG') {
          var typing = msg.tags['+typing'];
          if (typing != null && !client.isMyNick(msg.source.name)) {
            _bufferList
                .get(target, network)
                ?.setTyping(msg.source.name, typing == 'active');
          }
        }
        return _handleChatMessages(target, [msg]);
      case 'INVITE':
        var nickname = msg.params[0];
        if (client.isMyNick(nickname)) {
          _notifController.showInvite(msg, network);
        }
        break;
      case 'BATCH':
        if (msg is ClientEndOfBatch) {
          var batch = msg.child;
          if (batch.type == 'soju.im/bouncer-networks' &&
              client.isupport.bouncerNetId == null) {
            return _handleBouncerNetworksBatch(batch);
          }
        }
        break;
      case 'BOUNCER':
        if (msg.params[0] != 'NETWORK') {
          break;
        }
        if (client.isupport.bouncerNetId != null) {
          break;
        }
        // If the message is part of a batch, we'll process it when we
        // reach the end of the batch
        if (msg.batchByType('soju.im/bouncer-networks') != null) {
          break;
        }
        return _handleBouncerNetwork(msg);
      case 'MARKREAD':
        var target = msg.params[0];
        var bound = msg.params[1];

        if (bound == '*') {
          break;
        }
        if (!bound.startsWith('timestamp=')) {
          throw FormatException('Invalid MARKREAD bound: $msg');
        }
        var time = bound.replaceFirst('timestamp=', '');

        var buffer = _bufferList.get(target, network);
        if (buffer == null) {
          break;
        }

        if (buffer.entry.lastReadTime != null &&
            time.compareTo(buffer.entry.lastReadTime!) <= 0) {
          break;
        }

        _notifController.cancelAllWithBuffer(buffer, DateTime.parse(time));

        buffer.entry.lastReadTime = time;
        return _db.storeBuffer(buffer.entry).then((_) {
          return _db.fetchBufferUnreadCount(buffer.id);
        }).then((unreadCount) {
          buffer.unreadCount = unreadCount;
        });
      case 'REDACT':
        if (msg.batchByType('chathistory') != null) {
          break;
        }

        return _handleRedactMessage(msg);
      case RPL_MONONLINE:
      case RPL_MONOFFLINE:
        var online = msg.cmd == RPL_MONONLINE;
        var targets = msg.params[1].split(',');
        for (var raw in targets) {
          var source = IrcSource.parse(raw);
          _bufferList.get(source.name, network)?.online = online;
        }
        break;
    }
    return null;
  }

  String? _privateNoSuchNickTarget(ClientMessage msg) {
    if (msg.cmd != ERR_NOSUCHNICK || msg.params.length < 2) {
      return null;
    }
    var target = msg.params[1];
    if (client.isChannel(target) || isServerBufferName(target)) {
      return null;
    }
    var buffer = _bufferList.get(target, network);
    return buffer != null && !buffer.archived ? target : null;
  }

  Future<void> _appendChannelEvent(
      BufferModel buffer, ClientMessage msg) async {
    if (buffer.archived || !client.isChannel(buffer.name)) {
      return;
    }

    var entry = MessageEntry(msg, buffer.id);
    await _db.storeMessages([entry]);
    if (buffer.messageHistoryLoaded) {
      var models = await buildMessageModelList(_db, [entry]);
      buffer.addMessages(models, append: true);
    }
    _provider._scheduleNextMessageCleanup();
  }

  Future<void> _handlePrivateNoSuchNick(
      ClientMessage msg, String target) async {
    var buffer = _bufferList.get(target, network);
    if (buffer == null) {
      return;
    }

    var notice = IrcMessage(
      'NOTICE',
      [target, msg.params.last],
      tags: {
        if (msg.tags['time'] != null) 'time': msg.tags['time'],
      },
      source: msg.source,
    );
    var entry = MessageEntry(notice, buffer.id);
    await _db.storeMessages([entry]);

    if (buffer.messageHistoryLoaded) {
      var models = await buildMessageModelList(_db, [entry]);
      buffer.addMessages(models, append: true);
    }
    _bufferList.bumpLastDeliveredTime(buffer, entry.time);
  }

  Future<void> _handleRedactMessage(ClientMessage msg) async {
    if (msg.params.length < 2) {
      return;
    }

    var target = normalizeServerBufferName(msg.params[0]);
    var msgid = msg.params[1];
    var buffer = _bufferList.get(target, network);
    if (buffer != null) {
      await _handleChatMessages(target, [msg]);
      return;
    }

    for (var candidate in _bufferList.buffers) {
      if (candidate.network != network || candidate.archived) {
        continue;
      }
      var (message, reaction) = await (
        _db.fetchMessageByNetworkMsgid(candidate.id, msgid),
        _db.fetchReactionByNetworkMsgid(candidate.id, msgid),
      ).wait;
      if (message != null || reaction != null) {
        await _handleRedact(candidate, msgid);
        return;
      }
    }

    log.print('Received REDACT for unknown msgid "$msgid"');
  }

  Future<void> _handleChatMessages(
      String target, List<ClientMessage> messages) async {
    if (messages.length == 0) {
      return;
    }

    if (!isServerBufferName(target)) {
      var notices =
          messages.where((message) => message.cmd == 'NOTICE').toList();
      if (notices.isNotEmpty) {
        await _handleChatMessages(statusBufferName, notices);
        messages =
            messages.where((message) => message.cmd != 'NOTICE').toList();
        if (messages.isEmpty) {
          return;
        }
      }
    }

    if (!isServerBufferName(target) &&
        (messages.any((msg) => isStatusNoticeMessage(msg, target: target)) ||
            isServiceMessageTarget(target) ||
            messages.any(isServiceMessage))) {
      target = statusBufferName;
    }

    var isHistory = messages.first.batchByType('chathistory') != null;

    target = normalizeServerBufferName(target);
    var serverTarget = isServerBufferName(target);
    var createNewBuffer = serverTarget;
    List<ClientMessage> notices = [];
    if (!serverTarget && !client.isChannel(target)) {
      for (var msg in messages) {
        if (msg.cmd == 'NOTICE') {
          notices.add(msg);
          continue;
        } else if (msg.cmd != 'PRIVMSG') {
          continue;
        }

        // Disregard non-/me CTCP messages
        var ctcp = CtcpMessage.parse(msg);
        if (ctcp == null || ctcp.cmd == 'ACTION') {
          createNewBuffer = true;
          break;
        }
      }
    }

    var buf = _bufferList.get(target, network);
    var isNewBuffer = false;
    if (buf == null && createNewBuffer) {
      isNewBuffer = true;
      buf = await _createBuffer(normalizeServerBufferName(target));
    }
    if (buf != null && buf.archived && !createNewBuffer) {
      buf = null;
    }
    if (buf == null) {
      if (!notices.isEmpty) {
        await _handleChatMessages(statusBufferName, notices);
        return;
      }

      // Bump last delivery time so that we don't fetch again the same
      // NOTICEs via chathistory
      bool bumped = false;
      for (var msg in notices) {
        var t = msg.tags['time'];
        if (t != null && _network.networkEntry.bumpLastDeliveredTime(t)) {
          bumped = true;
        }
      }
      if (bumped) {
        await _db.storeNetwork(_network.networkEntry);
      }
      return;
    }

    List<MessageEntry> privmsgs = [];
    List<ReactionEntry> reactions = [];
    List<String> redactedMsgids = [];
    for (var msg in messages) {
      var reply = msg.inReplyTo;
      var react = msg.tags['+draft/react'];
      var unreact = msg.tags['+draft/unreact'];
      if (reply != null && (react != null || unreact != null)) {
        reactions.add(ReactionEntry(msg, buf.id));
      } else if (msg.cmd == 'NOTICE' || msg.cmd == 'PRIVMSG') {
        if (msg.cmd == 'PRIVMSG' && client.isMyNick(msg.source.name)) {
          var pending =
              _takeOptimisticSelfEcho(network, buf.name, msg.params[1]);
          if (pending != null) {
            await _replaceOptimisticSelfEcho(buf, pending.messageId, msg);
            continue;
          }
        }
        if (msg.cmd == 'PRIVMSG' &&
            !client.isMyNick(msg.source.name) &&
            network.isIgnoredSource(msg.source)) {
          continue;
        }
        privmsgs.add(MessageEntry(msg, buf.id));
      } else if (msg.cmd == 'REDACT') {
        redactedMsgids.add(msg.params[1]);
      }
    }

    if (reactions.isNotEmpty) {
      await _db.storeReactions(reactions);
    }
    if (privmsgs.isNotEmpty) {
      await _db.storeMessages(privmsgs);
    }

    if (buf.messageHistoryLoaded) {
      var models = await buildMessageModelList(
        _db,
        privmsgs,
        knownMessages: buf.messages,
      );
      buf.addMessages(models, append: !isHistory);
      buf.addReactions(reactions);
    }

    for (var msgid in redactedMsgids) {
      await _handleRedact(buf, msgid);
    }

    // Only privmsgs affects unread count / lastReadTime
    if (privmsgs.isEmpty) {
      return;
    }

    String t = privmsgs.first.time;
    List<MessageEntry> unread = [];
    for (var entry in privmsgs) {
      if (entry.time.compareTo(t) > 0) {
        t = entry.time;
      }

      if (!client.isMyNick(entry.msg.source!.name) &&
          (buf.entry.lastReadTime == null ||
              buf.entry.lastReadTime!.compareTo(entry.time) < 0)) {
        unread.add(entry);
      }
    }

    var callInviteShown = !buf.muted &&
        await _notifController.showDirectCallInvite(unread, buf);
    if (!buf.focused) {
      buf.unreadCount += unread.length;
      if (!callInviteShown) {
        _openNotifications(buf, unread);
      }
    } else {
      if (buf.entry.lastReadTime == null ||
          buf.entry.lastReadTime!.compareTo(t) < 0) {
        buf.entry.lastReadTime = t;
        unawaited(_db.storeBuffer(buf.entry));
        client.setReadMarker(buf.name, buf.entry.lastReadTime!);
      }
    }

    _bufferList.bumpLastDeliveredTime(buf, t);
    if (_network.networkEntry.bumpLastDeliveredTime(t)) {
      await _db.storeNetwork(_network.networkEntry);
    }

    if (isNewBuffer &&
        client.isNick(buf.name) &&
        !isServerBufferName(buf.name)) {
      unawaited(_provider.fetchBufferUser(buf));
      unawaited(_fetchPrivateAvatars([buf.name]));
    }
  }

  Future<void> _replaceOptimisticSelfEcho(
      BufferModel buffer, int messageId, ClientMessage msg) async {
    var existing = await _db.fetchMessage(messageId);
    if (existing == null) {
      return;
    }

    var replacement = MessageEntry(msg, buffer.id)..id = messageId;
    await _db.storeMessages([replacement]);
    if (buffer.messageHistoryLoaded) {
      buffer.replaceMessage(messageId, replacement);
    }
  }

  Future<void> _handleRedact(BufferModel buffer, String msgid) async {
    var (msg, reaction) = await (
      _db.fetchMessageByNetworkMsgid(buffer.id, msgid),
      _db.fetchReactionByNetworkMsgid(buffer.id, msgid),
    ).wait;
    if (msg != null) {
      msg.redacted = true;
      await _db.storeMessages([msg]);
      buffer.redactMessage(msgid);
    } else if (reaction != null) {
      reaction.redacted = true;
      await _db.storeReactions([reaction]);
      buffer.redactReaction(reaction);
    } else {
      log.print('Received REDACT for unknown msgid "$msgid"');
    }
  }

  Future<void> _handleBouncerNetworksBatch(ClientBatch batch) async {
    for (var msg in batch.messages) {
      await _handleBouncerNetwork(msg);
    }

    if (_gotInitialBouncerNetworksBatch) {
      return;
    }
    _gotInitialBouncerNetworksBatch = true;

    // Delete stale child networks

    List<NetworkModel> stale = [];
    for (var childNetwork in _networkList.networks) {
      if (childNetwork.networkEntry.bouncerId == null) {
        continue;
      }
      if (childNetwork.serverEntry.id != network.serverEntry.id) {
        continue;
      }

      var bouncerNetwork =
          _bouncerNetworkList.networks[childNetwork.networkEntry.bouncerId];
      if (bouncerNetwork != null) {
        continue;
      }

      stale.add(childNetwork);
    }

    for (var childNetwork in stale) {
      _provider.remove(childNetwork);
      await _db.deleteNetwork(childNetwork.networkId);
    }
  }

  Future<void> _handleBouncerNetwork(ClientMessage msg) async {
    var bouncerNetId = msg.params[1];
    var attrs = msg.params[2] == '*' ? null : parseIrcTags(msg.params[2]);

    var bouncerNetwork = _bouncerNetworkList.networks[bouncerNetId];
    var networkMatches = _networkList.networks.where((network) {
      return network.networkEntry.bouncerId == bouncerNetId;
    });
    NetworkModel? childNetwork =
        networkMatches.isEmpty ? null : networkMatches.first;

    if (attrs == null) {
      // The bouncer network has been removed

      _bouncerNetworkList.remove(bouncerNetId);

      if (childNetwork == null) {
        return;
      }

      _provider.remove(childNetwork);

      await _db.deleteNetwork(childNetwork.networkId);
      return;
    }

    if (bouncerNetwork != null) {
      // The bouncer network has been updated
      bouncerNetwork.setAttrs(attrs);
      if (childNetwork != null) {
        childNetwork.networkEntry.bouncerName = attrs['name'];
        childNetwork.networkEntry.bouncerUri =
            _uriFromBouncerNetworkModel(bouncerNetwork);
        await _db.storeNetwork(childNetwork.networkEntry);
      }
      return;
    }

    // The bouncer network has been added

    bouncerNetwork = BouncerNetworkModel(bouncerNetId, attrs);
    _bouncerNetworkList.add(bouncerNetwork);

    if (childNetwork != null) {
      // This is the first time we see this bouncer network for this
      // session, but we've saved it in the DB
      childNetwork.bouncerNetwork = bouncerNetwork;
      childNetwork.networkEntry.bouncerUri =
          _uriFromBouncerNetworkModel(bouncerNetwork);
      await _db.storeNetwork(childNetwork.networkEntry);
      return;
    }

    var networkEntry = NetworkEntry(
      server: network.serverId,
      bouncerId: bouncerNetId,
      bouncerUri: _uriFromBouncerNetworkModel(bouncerNetwork),
    );
    networkEntry = await _db.storeNetwork(networkEntry);
    var childClient = Client(client.params.apply(bouncerNetId: bouncerNetId));
    childNetwork = NetworkModel(network.serverEntry, networkEntry,
        childClient.nick, childClient.realname);
    _networkList.add(childNetwork);
    _provider.add(childClient, childNetwork);
    childClient.connect().ignore();
  }

  void _handleChanModeUpdate(BufferModel buffer, ChanModeUpdate update) {
    if (buffer.members == null) {
      return;
    }

    var nick = update.arg;
    if (nick == null) {
      return;
    }
    var prefix = buffer.members!.members[nick];
    if (prefix == null) {
      return;
    }
    prefix = updateIrcMembership(prefix, update, client.isupport);
    buffer.members!.set(nick, prefix);
  }

  void _openNotifications(
      BufferModel buffer, List<MessageEntry> entries) async {
    if (_isPushSupported()) {
      // TODO: handle the case where push is supported but the
      // subscription failed
      return;
    }
    if (buffer.muted) {
      return;
    }

    var isChannel = client.isChannel(buffer.name);

    entries = entries.where((entry) {
      if (buffer.lastDeliveredTime != null &&
          buffer.lastDeliveredTime!.compareTo(entry.time) >= 0) {
        return false;
      }
      return _shouldNotifyMessage(entry, isChannel);
    }).toList();
    if (entries.isEmpty) {
      return;
    }

    if (isChannel) {
      await _notifController.showHighlight(entries, buffer);
    } else {
      await _notifController.showDirectMessage(entries, buffer);
    }
  }

  bool _shouldNotifyMessage(MessageEntry entry, bool isChannel) {
    if (entry.msg.cmd != 'PRIVMSG') {
      return false;
    }
    if (client.isMyNick(entry.msg.source!.name)) {
      return false;
    }
    if (isChannel &&
        findTextHighlights(entry.msg.params[1], client.nick).isEmpty) {
      return false;
    }
    var ctcp = CtcpMessage.parse(entry.msg);
    if (ctcp != null && ctcp.cmd != 'ACTION') {
      return false;
    }
    return true;
  }

  Future<BufferModel> _createBuffer(String name) async {
    name = normalizeServerBufferName(name);
    var buffer = _bufferList.get(name, network);
    if (buffer != null) {
      return buffer;
    }

    var entry = BufferEntry(name: name, network: network.networkId);
    await _db.storeBuffer(entry);
    buffer = BufferModel(entry: entry, network: network);
    _bufferList.add(buffer);
    return buffer;
  }

  Future<List<ChatHistoryTarget>> _fetchAllChatHistoryTargets(
      String t1, String t2) async {
    var chatHistoryLimit = client.isupport.chathistoryLimit;
    if (chatHistoryLimit == 0) {
      // Pick arbitrarily high value.
      chatHistoryLimit = 1000;
    }

    LinkedHashMap<String, ChatHistoryTarget> targets = LinkedHashMap();
    while (true) {
      var page = await client.fetchChatHistoryTargets(t1, t2, chatHistoryLimit);

      for (var t in page) {
        targets.putIfAbsent(t.name, () => t);
      }

      if (page.length < chatHistoryLimit) {
        // This page wasn't full, so there's nothing
        // else to fetch.
        break;
      }

      // This page *was* full.  We'll start the next page so that it
      // overlaps in the last element(s) with this one.  We do this so
      // that if a scenario like the following happens:
      //
      //   CHATHISTORY TARGETS #gentoo-dev-help 2026-02-28T08:52:45.767Z
      //   -- page break --
      //   CHATHISTORY TARGETS #gentoo-proxy-maint 2026-02-28T08:52:45.767Z
      //
      // ... the latter channel(s) are not lost.
      //
      // If, however, we hit the disaster scenario of all channels in the
      // page being of the same timestamp, we'll just use the last
      // timestamp in the page.  :-(
      var lastTs = page.last.time;
      t1 = page
          .map((m) => m.time)
          .lastWhere((ts) => ts != lastTs, orElse: () => lastTs);
    }
    return targets.values.toList();
  }

  Future<void> _fetchBacklog(String from, String to) async {
    if (!client.caps.enabled.contains('draft/chathistory')) {
      return;
    }

    var max = client.caps.available.chatHistory!;
    if (max == 0) {
      max = 1000;
    }

    var targets = await _fetchAllChatHistoryTargets(from, to);
    await Future.wait(targets.map((target) async {
      // Query read marker if this is a user (ie, we haven't received the
      // read marker as part of an auto-JOIN) and we haven't queried it
      // already (we don't have an opened buffer or the buffer has no
      // unread messages).
      Future<void>? readMarkerFuture;
      var buffer = _bufferList.get(target.name, network);
      if (client.supportsReadMarker() &&
          !client.isChannel(target.name) &&
          (buffer == null || buffer.unreadCount == 0)) {
        readMarkerFuture = client.fetchReadMarker(target.name);
      }

      var done = false;
      for (var i = 0; i < 20; i++) {
        var batch =
            await client.fetchChatHistoryBetween(target.name, from, to, max);
        await readMarkerFuture;
        await _handleChatMessages(target.name, batch.messages);
        if (batch.messages.length < max ||
            batch.tags.containsKey('draft/chathistory-end')) {
          done = true;
          break;
        }

        var bumpedFrom = false;
        for (var msg in batch.messages) {
          var t = msg.tags['time'];
          if (t != null && t.compareTo(from) > 0) {
            from = t;
            bumpedFrom = true;
          }
        }
        if (!bumpedFrom) {
          throw Exception(
              'Requested backlog between $from and $to for $target, but all returned messages were before $from');
        }
      }
      if (!done) {
        log.print('Failed to fetch all backlog for $target: limit reached');
      }
    }));
  }

  Future<void> _setupPushSync() async {
    if (!_isPushSupported()) {
      return;
    }

    log.print('Enabling push synchronization');

    var subs = await _db.listWebPushSubscriptions();
    var vapidKey = client.isupport.vapid;
    var pushController = _provider._pushController!;

    WebPushSubscriptionEntry? oldSub;
    for (var sub in subs) {
      if (sub.network == network.networkId) {
        oldSub = sub;
        break;
      }
    }

    if (oldSub != null) {
      // TODO: also unregister on Firebase token change

      if (oldSub.vapidKey == vapidKey) {
        // Refresh our subscription
        try {
          await client.webPushRegister(oldSub.endpoint, oldSub.getPublicKeys());
          log.print('Refreshed existing push subscription');
          return;
        } on IrcException catch (err) {
          // Maybe the subscription expired
          if (err.msg.cmd == 'FAIL' && err.msg.params[0] == 'WEBPUSH') {
            log.print('Failed to refresh old push subscription', error: err);
            log.print('Trying to register with a fresh subscription...');
          } else {
            rethrow;
          }
        }
      } else {
        log.print('VAPID key changed');
      }

      try {
        await pushController.deleteSubscription(
            network.networkEntry, PushSubscription.fromEntry(oldSub));
      } on Exception catch (err) {
        log.print('Failed to delete old push subscription', error: err);
      }
      await client.webPushUnregister(oldSub.endpoint);
      await _db.deleteWebPushSubscription(oldSub.id!);
    } else {
      log.print('No existing push subscription found for this network');
    }

    var details =
        await pushController.createSubscription(network.networkEntry, vapidKey);

    try {
      var webPush = await WebPush.generate();
      var config = await webPush.exportPrivateKeys();
      var newSub = WebPushSubscriptionEntry(
        network: network.networkId,
        endpoint: details.endpoint,
        tag: details.tag,
        vapidKey: vapidKey,
        p256dhPrivateKey: config.p256dhPrivateKey,
        p256dhPublicKey: config.p256dhPublicKey,
        authKey: config.authKey,
      );
      await _db.storeWebPushSubscription(newSub);

      try {
        // This may result in a Web Push notification being delivered, so
        // we need to do this last
        await client.webPushRegister(details.endpoint, config.getPublicKeys());
        log.print('Registered new push subscription successfully');
      } on Object {
        try {
          await _db.deleteWebPushSubscription(newSub.id!);
        } on Exception catch (err) {
          log.print(
              'Failed to delete Web Push subscription from DB after error',
              error: err);
        }
        rethrow;
      }
    } on Object {
      try {
        await pushController.deleteSubscription(network.networkEntry, details);
      } on Exception catch (err) {
        log.print('Failed to delete push subscription after error', error: err);
      }
      rethrow;
    }
  }

  bool _isPushSupported() {
    return client.caps.enabled.contains('soju.im/webpush') &&
        _provider._pushController != null;
  }
}

IrcUri? _uriFromBouncerNetworkModel(BouncerNetworkModel bouncerNetwork) {
  if (bouncerNetwork.host == null) {
    return null;
  }

  // TODO: also include bouncerNetwork.tls
  return IrcUri(
    host: bouncerNetwork.host!,
    port: bouncerNetwork.port,
  );
}

Future<List<MessageModel>> buildMessageModelList(
  DB db,
  List<MessageEntry> entries, {
  Iterable<MessageModel> knownMessages = const [],
}) async {
  if (entries.isEmpty) {
    return [];
  }

  List<String> parentMsgids = [];
  for (var entry in entries) {
    var parentMsgid = entry.msg.inReplyTo;
    if (parentMsgid != null) {
      parentMsgids.add(parentMsgid);
    }
  }

  var bufferId = entries.first.buffer;
  var parentMap =
      await db.fetchMessageSetByNetworkMsgid(bufferId, parentMsgids);
  for (var message in knownMessages) {
    var msgid = message.entry.networkMsgid;
    if (msgid != null && parentMsgids.contains(msgid)) {
      parentMap.putIfAbsent(msgid, () => message.entry);
    }
  }
  var reactionMap = await db.fetchReactionSetBetweenMessages(
      bufferId, entries.first, entries.last);
  return entries.map((entry) {
    MessageEntry? replyTo;
    var parentMsgid = entry.msg.inReplyTo;
    if (parentMsgid != null) {
      replyTo = parentMap[parentMsgid];
    }
    var reacts = reactionMap[entry.networkMsgid] ?? [];
    return MessageModel(entry: entry, replyTo: replyTo, reactions: reacts);
  }).toList();
}
