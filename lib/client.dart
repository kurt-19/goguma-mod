import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hex/hex.dart';

import 'irc/irc.dart';
import 'logging.dart';

class SaslPlainCredentials {
  final String username;
  final String password;

  const SaslPlainCredentials(this.username, this.password);
}

class ConnectParams {
  final String host;
  final int port;
  final bool tls;
  final String nick;
  final String realname;
  final String? pass;
  final SaslPlainCredentials? saslPlain;
  final String? bouncerNetId;
  final String? away;
  final String? pinnedCertSHA1;

  const ConnectParams({
    required this.host,
    this.port = 6697,
    this.tls = true,
    required this.nick,
    String? realname,
    this.pass,
    this.saslPlain,
    this.bouncerNetId,
    this.away,
    this.pinnedCertSHA1,
  }) : realname = realname ?? nick;

  ConnectParams apply({
    String? bouncerNetId,
    String? nick,
    String? realname,
    SaslPlainCredentials? saslPlain,
    String? away,
  }) {
    return ConnectParams(
      host: host,
      port: port,
      tls: tls,
      nick: nick ?? this.nick,
      realname: realname ?? this.realname,
      pass: pass,
      saslPlain: saslPlain ?? this.saslPlain,
      bouncerNetId: bouncerNetId ?? this.bouncerNetId,
      away: away ?? this.away,
      pinnedCertSHA1: pinnedCertSHA1,
    );
  }

  ConnectParams _mergeRegistration(ConnectParams regParams) {
    return ConnectParams(
      host: host,
      port: port,
      tls: tls,
      nick: regParams.nick,
      realname: regParams.realname,
      pass: regParams.pass,
      saslPlain: regParams.saslPlain,
      bouncerNetId: regParams.bouncerNetId,
      away: regParams.away,
      pinnedCertSHA1: pinnedCertSHA1,
    );
  }
}

class BadCertException implements Exception {
  final X509Certificate badCert;
  BadCertException(this.badCert);

  @override
  String toString() {
    return 'Bad certificate. Issued by ' +
        badCert.issuer +
        '. SHA1 Fingerprint ' +
        HEX.encode(badCert.sha1) +
        '. Valid from: ' +
        badCert.startValidity.toString() +
        ' until ' +
        badCert.endValidity.toString();
  }
}

class _DisconnectedException extends IOException {
  _DisconnectedException();

  @override
  String toString() {
    return 'Disconnected from server';
  }
}

bool _isSaslAuthFailure(Object err) {
  if (err is! IrcException) {
    return false;
  }
  switch (err.msg.cmd) {
    case ERR_SASLFAIL:
    case ERR_SASLTOOLONG:
    case ERR_SASLABORTED:
    case ERR_SASLALREADY:
      return true;
    case 'FAIL':
      return err.msg.params.contains('SASL_UNAVAILABLE');
    default:
      return false;
  }
}

String _fallbackRegistrationNick(String nick, int attempt) {
  var suffix = '_$attempt';
  var maxBaseLength = _fallbackRegistrationNickMaxLength - suffix.length;
  var base = nick;
  if (base.length > maxBaseLength) {
    base = base.substring(0, maxBaseLength);
  }
  if (base.isEmpty) {
    base = 'irc';
  }
  return '$base$suffix';
}

bool _isUnavailableRegistrationNick(IrcMessage msg, String nick) {
  if (msg.params.length < 2) {
    return true;
  }

  var target = msg.params[1];
  return target == '*' || target.toLowerCase() == nick.toLowerCase();
}

Set<String> _getDefaultCaps(ConnectParams params) {
  var caps = {
    'away-notify',
    'account-notify',
    'account-tag',
    'batch',
    'chghost',
    'echo-message',
    'extended-join',
    'extended-monitor',
    'labeled-response',
    'message-tags',
    'multi-prefix',
    'no-implicit-names',
    'sasl',
    'server-time',
    'setname',
    'userhost-in-names',
    'channel-context',
    'draft/chathistory',
    'draft/channel-context',
    'draft/event-playback',
    'draft/extended-isupport',
    'draft/extended-isupport-0.2',
    'draft/extended-monitor',
    'draft/message-redaction',
    'draft/pre-away',
    'draft/typing',
    'draft/metadata-2',
    'draft/no-implicit-names',
    'draft/read-marker',
    'invite-notify',
    'unrealircd.org/json-log',
    'soju.im/bouncer-networks',
    'soju.im/no-implicit-names',
    'soju.im/webpush',
  };

  if (params.bouncerNetId == null) {
    caps.add('soju.im/bouncer-networks-notify');
  }

  return caps;
}

bool _capListContains(String caps, String cap) {
  var needle = cap.toLowerCase();
  for (var item in caps.split(' ')) {
    var i = item.indexOf('=');
    var name = i >= 0 ? item.substring(0, i) : item;
    if (name.toLowerCase() == needle) {
      return true;
    }
  }
  return false;
}

enum ClientState { disconnected, connecting, connected }

const _autoReconnectDelay = Duration(seconds: 10);
const _maxRegistrationNickRetries = 3;
const _fallbackRegistrationNickMaxLength = 30;
const _reclaimNickDelay = Duration(seconds: 2);

var _nextClientId = 0;
var _nextPingSerial = 0;
const _maxIrcWireLineBytes = 510;

class Client {
  final int _id;
  final Set<String> _requestCaps;
  ConnectParams _params;
  ConnectionTask<Socket>? _connectionTask;
  Socket? _socket;
  String _nick;
  String _realname;
  String? _hiddenRecoveryCommandPrefix;
  Completer<void>? _automatedNickRecoveryCompleter;
  final String? _pinnedCertSHA1;
  IrcSource? _serverSource;
  ClientState _state = ClientState.disconnected;
  bool _registered = false;
  final StreamController<ClientMessage> _messagesController =
      StreamController.broadcast(sync: true);
  final StreamController<ClientState> _statesController =
      StreamController.broadcast(sync: true);
  final StreamController<Exception> _connectErrorsController =
      StreamController.broadcast(sync: true);
  final StreamController<IrcIsupportRegistry> _isupportStreamController =
      StreamController.broadcast(sync: true);
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;
  int _connectSerial = 0;
  bool _autoReconnect;
  DateTime? _lastConnectTime;
  final Map<String, ClientBatch> _batches = {};
  final Map<String, List<ClientMessage>> _pendingNames = {};
  final Map<String, int> _pendingTextMsgs = {};
  IrcCapRegistry _caps;
  IrcIsupportRegistry _isupport;
  IrcIsupportRegistry _pendingIsupport = IrcIsupportRegistry();
  final Set<String> _metadataSubs = {};
  Future<void> _lastWhoFuture = Future.value(null);
  Future<void> _lastListFuture = Future.value(null);
  final IrcNameMap<void> _monitored = IrcNameMap(defaultCaseMapping);
  int _lastLabel = 0;

  ConnectParams get params => _params;
  String get nick => _nick;
  String get realname => _realname;
  IrcSource? get serverSource => _serverSource;
  String? get pinnedCertSHA1 => _pinnedCertSHA1;
  ClientState get state => _state;
  bool get registered => _registered;
  IrcCapRegistry get caps => _caps;
  IrcIsupportRegistry get isupport => _isupport;
  Stream<ClientMessage> get messages => _messagesController.stream;
  Stream<ClientState> get states => _statesController.stream;
  Stream<Exception> get connectErrors => _connectErrorsController.stream;
  Stream<IrcIsupportRegistry> get isupportStream =>
      _isupportStreamController.stream;
  bool get autoReconnect => _autoReconnect;
  bool get hasPendingReconnect => _reconnectTimer != null;
  Future<void> get automatedNickRecoveryDone =>
      _automatedNickRecoveryCompleter?.future ?? Future.value();
  Set<String> get metadataSubs => Set.unmodifiable(_metadataSubs);

  Client(
    ConnectParams params, {
    bool autoReconnect = true,
    Set<String>? requestCaps,
    IrcIsupportRegistry? lastIsupport,
    IrcAvailableCapRegistry? lastAvailableCaps,
  })  : _id = _nextClientId++,
        _params = params,
        _requestCaps = requestCaps ?? _getDefaultCaps(params),
        _nick = params.nick,
        _realname = params.realname,
        _pinnedCertSHA1 = params.pinnedCertSHA1,
        _autoReconnect = autoReconnect,
        _isupport = lastIsupport ?? IrcIsupportRegistry(),
        _caps = IrcCapRegistry(available: lastAvailableCaps);

  Future<void> connect({bool register = true, ConnectParams? params}) async {
    if (_messagesController.isClosed) {
      throw StateError('connect() called after dispose()');
    }
    if (params != null && !register) {
      throw ArgumentError('connect() called with params and register = false');
    }
    if (params == null && register && _connectFuture != null) {
      return _connectFuture!;
    }

    late Future<void> future;
    future = _connect(register: register, params: params).whenComplete(() {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    });
    _connectFuture = future;
    return future;
  }

  Future<void> _connect({required bool register, ConnectParams? params}) async {
    var connectSerial = ++_connectSerial;

    // Always switch to the disconnected state, because users reset their
    // state when handling that transition.
    _reconnectTimer?.cancel();
    _setState(ClientState.disconnected);
    _setState(ClientState.connecting);
    _lastConnectTime = DateTime.now();

    await _socket?.close();
    _connectionTask?.cancel();

    params ??= _params;
    _log('Connecting to ${params.host}...');

    Future<ConnectionTask<Socket>> connectionTaskFuture;
    if (params.tls) {
      connectionTaskFuture = SecureSocket.startConnect(
        params.host,
        params.port,
        onBadCertificate: (X509Certificate cert) {
          if (params?.pinnedCertSHA1 == HEX.encode(cert.sha1)) {
            return true;
          }
          throw BadCertException(cert);
        },
        supportedProtocols: ['irc'],
      );
    } else {
      connectionTaskFuture = Socket.startConnect(
        params.host,
        params.port,
      );
    }

    const connectTimeout = Duration(seconds: 15);
    ConnectionTask<Socket>? connectionTask;
    Socket socket;
    try {
      connectionTask = await connectionTaskFuture;
      if (connectSerial != _connectSerial) {
        connectionTask.cancel();
        return;
      }
      _connectionTask = connectionTask;

      socket =
          await connectionTask.socket.timeout(connectTimeout, onTimeout: () {
        throw TimeoutException('Connection timed out');
      });
      if (identical(_connectionTask, connectionTask)) {
        _connectionTask = null;
      }
      if (connectSerial != _connectSerial) {
        socket.destroy();
        return;
      }
    } on Exception catch (err) {
      connectionTask?.cancel();
      if (identical(_connectionTask, connectionTask)) {
        _connectionTask = null;
      }
      if (connectSerial != _connectSerial) {
        return;
      }
      _log('Connection failed', error: err);
      if (!_connectErrorsController.isClosed) {
        _connectErrorsController.add(err);
      }
      _setState(ClientState.disconnected);
      _tryAutoReconnect();
      rethrow;
    }

    _log('Connection opened');
    _socket = socket;
    _setState(ClientState.connected);
    _monitorSocket(socket);

    var lines = socket.transform(_IrcLineDecoder());

    lines.listen((l) {
      if (!identical(_socket, socket)) {
        return;
      }
      var msg = IrcMessage.parse(l);
      _handleMessage(msg);
    }, onDone: () {
      // This callback is invoked when the incoming side of the
      // bi-directional connection is closed. We close the outgoing side
      // here.
      if (identical(_socket, socket)) {
        _socket?.close().ignore();
      }
    }, onError: (Object err, StackTrace stack) {
      if (!identical(_socket, socket)) {
        return;
      }
      _log('Connection error', error: err);
      if (!_connectErrorsController.isClosed && err is Exception) {
        _connectErrorsController.add(err);
      }
    });

    if (register) {
      try {
        await this.register(params);
      } on Exception {
        _socket?.close().ignore();
        rethrow;
      }
    }
  }

  void _monitorSocket(Socket socket) async {
    // socket.done is resolved when socket.close() is called. It's not
    // called when only the incoming side of the bi-directional connection
    // is closed. See the onDone callback above in lines.listen().
    try {
      await socket.done;
    } on Exception catch (err) {
      _log('Connection error', error: err);
      if (!_connectErrorsController.isClosed) {
        _connectErrorsController.add(err);
      }
    } finally {
      if (identical(_socket, socket)) {
        _log('Connection closed');

        _socket = null;
        _registered = false;
        _caps = IrcCapRegistry(available: caps.available);
        _batches.clear();
        _pendingNames.clear();
        _pendingIsupport.clear();
        _monitored.clear();
        _completeAutomatedNickRecovery();
        _hiddenRecoveryCommandPrefix = null;

        // Don't mutate our state or try to auto-reconnect if we're already
        // connecting.
        if (_state != ClientState.connecting) {
          _setState(ClientState.disconnected);
          _tryAutoReconnect();
        }
      }
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionTask?.cancel();
    _socket?.destroy();
  }

  void _log(String s, {Object? error}) {
    log.print('[$_id] $s', error: error);
  }

  void _setState(ClientState state) {
    if (_state == state) {
      return;
    }

    _state = state;

    if (!_statesController.isClosed) {
      _statesController.add(state);
    }
  }

  set autoReconnect(bool autoReconnect) {
    if (_autoReconnect == autoReconnect) {
      return;
    }

    _autoReconnect = autoReconnect;
    _tryAutoReconnect();
  }

  void _tryAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (!_autoReconnect || state != ClientState.disconnected) {
      return;
    }

    Duration d;
    if (_lastConnectTime == null ||
        DateTime.now().difference(_lastConnectTime!) > _autoReconnectDelay) {
      _log('Reconnecting immediately');
      d = Duration.zero;
    } else {
      _log('Reconnecting in $_autoReconnectDelay');
      d = _autoReconnectDelay;
    }

    _reconnectTimer = Timer(d, () async {
      try {
        await connect();
      } on Exception catch (err) {
        _log('Failed to reconnect', error: err);
      }
    });
  }

  Future<ClientMessage> _waitMessage(
    bool Function(ClientMessage msg) test, {
    Duration? timeout,
    FutureOr<ClientMessage> Function()? onTimeout,
  }) {
    if (state != ClientState.connected) {
      return Future.error(_DisconnectedException());
    }

    // We need to manually track the Future completion state, because the
    // cancel() calls below are asynchronous, so multiple listen()
    // callbacks may be invoked before the Stream subscriptions are
    // cancelled.
    var completed = false;
    Completer<ClientMessage> completer = Completer();

    var statesSub = states.listen((state) {
      if (state == ClientState.disconnected && !completed) {
        completer.completeError(_DisconnectedException());
        completed = true;
      }
    });

    var messagesSub = messages.listen((msg) {
      if (completed) {
        return;
      }

      bool done;
      try {
        done = test(msg);
      } on Object catch (err, stackTrace) {
        completer.completeError(err, stackTrace);
        completed = true;
        return;
      }
      if (done) {
        completer.complete(msg);
        completed = true;
      }
    });

    const defaultTimeout = Duration(seconds: 30);
    return completer.future
        .timeout(timeout ?? defaultTimeout, onTimeout: onTimeout)
        .whenComplete(() {
      statesSub.cancel();
      messagesSub.cancel();
    });
  }

  Future<ClientMessage> _roundtripMessage(
    IrcMessage msg,
    bool Function(ClientMessage msg) test, {
    Duration? timeout,
  }) {
    if (state != ClientState.connected || _socket == null) {
      return Future.error(_DisconnectedException());
    }

    String? cmdLabel;
    if (caps.enabled.contains('labeled-response')) {
      _lastLabel++;
      cmdLabel = '$_lastLabel';
      msg = msg.copyWith(tags: {...msg.tags, 'label': cmdLabel});
    }

    var cmd = msg.cmd;
    send(msg);

    return _waitMessage(
        (msg) {
          // Note: a reply to a command with a label may be completely
          // missing the label. But if a reply has a label, it's guaranteed
          // to match the command's.
          var label = msg.label;
          if (label != null && label != cmdLabel) {
            return false;
          }

          var endOfLabeledResponse = false;
          if (label != null && label == cmdLabel) {
            if (msg.cmd == 'BATCH') {
              endOfLabeledResponse = msg is ClientEndOfBatch;
            } else {
              endOfLabeledResponse = msg.tags['label'] != null;
            }
          }

          bool isError = false;
          switch (msg.cmd) {
            case 'FAIL':
              isError = msg.params[0] == cmd;
              break;
            case ERR_UNKNOWNERROR:
            case ERR_UNKNOWNCOMMAND:
            case ERR_NEEDMOREPARAMS:
            case RPL_TRYAGAIN:
              isError = msg.params[1] == cmd;
          }
          if (isError) {
            throw IrcException(msg);
          }

          var done = test(msg);
          if (!done && endOfLabeledResponse) {
            throw Exception(
                'Received end of labeled response, but not done handling messages for $cmd');
          }
          return done;
        },
        timeout: timeout,
        onTimeout: () {
          throw TimeoutException('Timed out waiting for $cmd reply');
        });
  }

  Future<ClientBatch> _roundtripBatch(
      IrcMessage msg, bool Function(ClientBatch batch) test) async {
    var endMsg = await _roundtripMessage(msg, (msg) {
      if (!(msg is ClientEndOfBatch)) {
        return false;
      }
      return test(msg.child);
    });
    var endOfBatch = endMsg as ClientEndOfBatch;
    return endOfBatch.child;
  }

  Future<void> register([ConnectParams? params]) async {
    params ??= _params;

    _nick = params.nick;
    _realname = params.realname;
    _completeAutomatedNickRecovery();
    _hiddenRecoveryCommandPrefix = null;
    var registrationNick = params.nick;
    var unavailableNickRetries = 0;
    var registrationFailed = false;
    String? unavailableNick;
    var unavailableNickNeedsRelease = false;

    // Here we're trying to minimize the number of roundtrips as much as
    // possible, because (1) we'll reconnect very regularly and (2) mobile
    // networks can be pretty spotty. So we send in bulk all of the
    // messages required to register the connection. We blindly request all
    // caps we support to avoid waiting for the CAP LS reply.

    var capLsFuture = fetchAvailableCaps();
    if (params.pass != null) {
      send(IrcMessage('PASS', [params.pass!]));
    }
    send(IrcMessage('NICK', [registrationNick]));
    send(IrcMessage('USER', [params.nick, '0', '*', params.realname]));
    Map<String, Future<bool>> capReqFutures = {};
    for (var cap in _requestCaps) {
      bool req = caps.available.containsKey(cap);
      switch (cap) {
        case 'sasl':
          req = req || params.saslPlain != null;
          break;
        case 'soju.im/bouncer-networks':
          req = req || params.bouncerNetId != null;
          break;
        case 'draft/pre-away':
          req = req || params.away != null;
          break;
      }

      if (req) {
        capReqFutures[cap] = _requestCap(cap);
      }
    }
    if (params.bouncerNetId != null) {
      send(IrcMessage('BOUNCER', ['BIND', params.bouncerNetId!]));
    }
    if (params.away != null && _requestCaps.contains('draft/pre-away')) {
      // We cannot check for the pre-away cap here, because we haven't
      // received the list of available server caps yet
      setAway(params.away).ignore();
    }
    var welcomeFuture = _waitMessage((msg) {
      switch (msg.cmd) {
        case RPL_WELCOME:
          return true;
        case 'ERROR':
        case 'FAIL':
        case ERR_NICKLOCKED:
        case ERR_PASSWDMISMATCH:
        case ERR_ERRONEUSNICKNAME:
        case ERR_NOPERMFORHOST:
        case ERR_YOUREBANNEDCREEP:
          throw IrcException(msg);
        case ERR_NICKNAMEINUSE:
        case ERR_NICKCOLLISION:
        case ERR_UNAVAILRESOURCE:
          if (params!.saslPlain != null &&
              unavailableNickRetries < _maxRegistrationNickRetries &&
              (_isUnavailableRegistrationNick(msg, registrationNick) ||
                  _isUnavailableRegistrationNick(msg, params.nick))) {
            unavailableNick ??= params.nick;
            unavailableNickNeedsRelease |= msg.cmd == ERR_UNAVAILRESOURCE;
            unavailableNickRetries++;
            registrationNick =
                _fallbackRegistrationNick(params.nick, unavailableNickRetries);
            _nick = registrationNick;
            _automatedNickRecoveryCompleter ??= Completer<void>();
            _log(
                'Nickname unavailable during registration, trying temporary nick $registrationNick');
            send(IrcMessage('NICK', [registrationNick]));
            return false;
          }
          throw IrcException(msg);
      }
      return false;
    }, onTimeout: () {
      throw TimeoutException('Connection registration timed out');
    }).catchError((Object err, StackTrace stackTrace) {
      registrationFailed = true;
      Error.throwWithStackTrace(err, stackTrace);
    });

    var shouldIdentifyWithNickServ = false;
    var capsFuture = () async {
      IrcAvailableCapRegistry available;
      try {
        available = await capLsFuture;
      } on Exception {
        return;
      }
      if (registrationFailed || state != ClientState.connected) {
        return;
      }
      _caps = IrcCapRegistry(available: available, enabled: caps.enabled);

      var saslAck = true;
      try {
        await Future.wait(capReqFutures.entries.map((entry) async {
          var ok = await entry.value;
          if (entry.key == 'sasl') {
            saslAck = ok;
          }
        }), eagerError: true);
      } on Exception {
        saslAck = false;
      }
      if (registrationFailed || state != ClientState.connected) {
        return;
      }

      if (params!.saslPlain != null) {
        if (!saslAck) {
          _log('SASL PLAIN unavailable, falling back to NickServ IDENTIFY');
          shouldIdentifyWithNickServ = true;
        } else {
          var creds = params.saslPlain!;
          _log('Starting SASL PLAIN authentication');
          try {
            await authWithPlain(creds.username, creds.password);
          } on Exception catch (err) {
            if (!_isSaslAuthFailure(err)) {
              rethrow;
            }
            _log(
                'SASL PLAIN authentication failed, falling back to NickServ IDENTIFY');
            shouldIdentifyWithNickServ = true;
          }
        }
      }

      for (var cap in _requestCaps) {
        if (caps.available.containsKey(cap) &&
            !capReqFutures.containsKey(cap)) {
          _requestCap(cap).ignore();
        }
      }

      if (!registrationFailed && state == ClientState.connected) {
        send(IrcMessage('CAP', ['END']));
      }
    }();

    await Future.wait([
      capsFuture,
      welcomeFuture,
    ], eagerError: true);

    if (shouldIdentifyWithNickServ &&
        !registrationFailed &&
        state == ClientState.connected) {
      var creds = params.saslPlain!;
      send(IrcMessage('PRIVMSG',
          ['NickServ', 'IDENTIFY ${creds.username} ${creds.password}']));
    }

    _params = _params._mergeRegistration(params);
    if (unavailableNick != null &&
        params.saslPlain != null &&
        state == ClientState.connected &&
        !isMyNick(unavailableNick!)) {
      _scheduleUnavailableNickRecovery(unavailableNick!, params.saslPlain!,
          release: unavailableNickNeedsRelease);
    }
  }

  void _scheduleUnavailableNickRecovery(String nick, SaslPlainCredentials creds,
      {required bool release}) {
    _automatedNickRecoveryCompleter ??= Completer<void>();
    var command = release ? 'RELEASE' : 'GHOST';
    _hiddenRecoveryCommandPrefix = '$command $nick ';
    _log('Trying to reclaim nickname $nick via NickServ $command');
    send(IrcMessage(
        'PRIVMSG', ['NickServ', '$command $nick ${creds.password}']));

    Timer(_reclaimNickDelay, () {
      unawaited(() async {
        if (state != ClientState.connected || _socket == null) {
          _completeAutomatedNickRecovery();
          return;
        }
        if (isMyNick(nick)) {
          _completeAutomatedNickRecovery();
          return;
        }
        try {
          await setNickname(nick);
        } on Exception catch (err) {
          _log('Failed to reclaim nickname $nick', error: err);
        } finally {
          _completeAutomatedNickRecovery();
        }
      }());
    });
  }

  void _completeAutomatedNickRecovery() {
    var completer = _automatedNickRecoveryCompleter;
    _automatedNickRecoveryCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  bool consumeAutomatedNickRecoveryMessage(ClientMessage msg) {
    var commandPrefix = _hiddenRecoveryCommandPrefix;
    if (msg.cmd == 'PRIVMSG' &&
        commandPrefix != null &&
        msg.params.length >= 2 &&
        isupport.caseMapping.equals(msg.params[0], 'NickServ') &&
        msg.params[1].startsWith(commandPrefix)) {
      _hiddenRecoveryCommandPrefix = null;
      return true;
    }
    return false;
  }

  void _handleMessage(IrcMessage msg) {
    if (kDebugMode) {
      _log('<- ' + msg.toString());
    }

    if (msg.source == null) {
      var source = _serverSource ?? IrcSource('*');
      msg = IrcMessage(msg.cmd, msg.params, tags: msg.tags, source: source);
    }

    ClientBatch? msgBatch;
    if (msg.tags.containsKey('batch')) {
      msgBatch = _batches[msg.tags['batch']];
    }

    ClientMessage clientMsg;
    switch (msg.cmd) {
      case RPL_ENDOFNAMES:
        var channel = msg.params[1];
        var names = _pendingNames.remove(channel) ?? [];
        clientMsg = ClientEndOfNames._(msg, names, isupport, batch: msgBatch);
        break;
      case 'BATCH':
        if (msg.params[0].startsWith('-')) {
          var ref = msg.params[0].substring(1);
          var child = _batches[ref];
          if (child == null) {
            throw FormatException('Unknown BATCH reference: $ref');
          }
          clientMsg = ClientEndOfBatch._(msg, child, batch: msgBatch);
        } else {
          clientMsg = ClientMessage._(msg, batch: msgBatch);
        }
        break;
      default:
        clientMsg = ClientMessage._(msg, batch: msgBatch);
    }

    msgBatch?._messages.add(clientMsg);

    switch (msg.cmd) {
      case 'CAP':
        var subcommand = msg.params[1].toUpperCase();

        caps.parse(msg);

        if (subcommand != 'NEW') {
          break;
        }

        for (var cap in _requestCaps) {
          if (caps.available.containsKey(cap) && !caps.enabled.contains(cap)) {
            _requestCap(cap).ignore();
          }
        }
        break;
      case RPL_WELCOME:
        _serverSource = msg.source;
        _nick = msg.params[0];
        isupport.clear();
        break;
      case RPL_ISUPPORT:
        var tokens = msg.params.sublist(1, msg.params.length - 1);
        if (_registered) {
          isupport.parse(tokens);
          _monitored.setCaseMapping(isupport.caseMapping);
          if (!_isupportStreamController.isClosed) {
            _isupportStreamController.add(isupport);
          }
        } else {
          _pendingIsupport.parse(tokens);
        }
        break;
      case RPL_ENDOFMOTD:
      case ERR_NOMOTD:
        if (_registered) {
          break;
        }
        _log('Registration complete');
        _registered = true;
        _isupport = _pendingIsupport;
        _pendingIsupport = IrcIsupportRegistry();
        if (!_isupportStreamController.isClosed) {
          _isupportStreamController.add(isupport);
        }
        if (params.away != null && !caps.enabled.contains('draft/pre-away')) {
          setAway(params.away);
        }
        break;
      case RPL_METADATASUBOK:
        for (var sub in msg.params.sublist(1)) {
          _metadataSubs.add(sub);
        }
        break;
      case 'NICK':
        if (isMyNick(msg.source!.name)) {
          _nick = msg.params[0];
        }
        break;
      case 'SETNAME':
        if (isMyNick(msg.source!.name)) {
          _realname = msg.params[0];
        }
        break;
      case 'PING':
        send(IrcMessage('PONG', msg.params));
        break;
      case 'BATCH':
        var kind = msg.params[0][0];
        var ref = msg.params[0].substring(1);

        switch (kind) {
          case '+':
            var type = msg.params[1];
            var params = msg.params.sublist(2);
            if (_batches.containsKey(ref)) {
              throw FormatException('Duplicate BATCH reference: $ref');
            }
            var batch = ClientBatch._(type, params, msgBatch, msg.tags);
            _batches[ref] = batch;
            break;
          case '-':
            _batches.remove(ref);
            break;
          default:
            throw FormatException('Invalid BATCH message: $msg');
        }
        break;
      case RPL_NAMREPLY:
        var channel = msg.params[2];
        _pendingNames.putIfAbsent(channel, () => []).add(clientMsg);
        break;
      case ERR_MONLISTFULL:
        var targets = msg.params[2].split(',');
        for (var name in targets) {
          _monitored.remove(name);
        }
        break;
    }

    if (!_messagesController.isClosed) {
      _messagesController.add(clientMsg);
    }
  }

  void dispose() {
    if (_messagesController.isClosed) {
      throw StateError('dispose() called twice');
    }
    _log('Destroying client');
    _autoReconnect = false;
    disconnect();
    _messagesController.close();
    _statesController.close();
    _connectErrorsController.close();
    _isupportStreamController.close();
  }

  void send(IrcMessage msg) {
    if (_socket == null) {
      // TODO: throw SocketException.closed()
      _log('Warning: tried to send message while connection is closed: $msg');
      return;
    }
    if (kDebugMode) {
      _log('-> ' + msg.toString());
    }
    _socket!.write(_limitIrcWireLineLength(msg.toString()) + '\r\n');
  }

  String _limitIrcWireLineLength(String line) {
    if (utf8.encode(line).length <= _maxIrcWireLineBytes) {
      return line;
    }

    var buffer = StringBuffer();
    var used = 0;
    for (var rune in line.runes) {
      var char = String.fromCharCode(rune);
      var length = utf8.encode(char).length;
      if (used + length > _maxIrcWireLineBytes) {
        break;
      }
      buffer.write(char);
      used += length;
    }
    return buffer.toString();
  }

  bool isChannel(String name) {
    return isupport.isChannel(name);
  }

  bool isMyNick(String name) {
    return isupport.caseMapping.equals(name, nick);
  }

  bool isNick(String name) {
    if (_serverSource != null &&
        isupport.caseMapping.equals(name, _serverSource!.name)) {
      return false;
    }
    // A dollar is used for server-wide broadcasts. Dots usually indicate
    // server names.
    return !name.startsWith('\$') &&
        !name.contains('.') &&
        !isChannel(name) &&
        name != '*';
  }

  Future<void> _roundtripSasl(String mechanism, List<int> payload) async {
    await _roundtripMessage(IrcMessage('AUTHENTICATE', [mechanism]), (reply) {
      if (reply.cmd == 'AUTHENTICATE' && reply.params[0] == '+') {
        return true;
      }
      switch (reply.cmd) {
        case ERR_SASLFAIL:
        case ERR_SASLTOOLONG:
        case ERR_SASLABORTED:
        case ERR_SASLALREADY:
          throw IrcException(reply);
        default:
          return false;
      }
    });
    await _roundtripMessage(
        IrcMessage('AUTHENTICATE', [base64.encode(payload)]), (reply) {
      switch (reply.cmd) {
        case RPL_SASLSUCCESS:
          return true;
        case ERR_SASLFAIL:
        case ERR_SASLTOOLONG:
        case ERR_SASLABORTED:
        case ERR_SASLALREADY:
          throw IrcException(reply);
        default:
          return false;
      }
    });
  }

  Future<void> authWithPlain(String username, String password) async {
    var payload = [0, ...utf8.encode(username), 0, ...utf8.encode(password)];
    await _roundtripSasl('PLAIN', payload);
  }

  Future<void> authWithAnonymous(String trace) async {
    var payload = utf8.encode(trace);
    await _roundtripSasl('ANONYMOUS', payload);
  }

  Future<IrcAvailableCapRegistry> fetchAvailableCaps() async {
    var cmd = IrcMessage('CAP', ['LS', '302']);
    var caps = IrcAvailableCapRegistry();
    await _roundtripMessage(cmd, (reply) {
      if (reply.cmd != 'CAP' ||
          reply.params.length < 3 ||
          reply.params[1].toUpperCase() != 'LS') {
        return false;
      }
      caps.parse(reply.params[reply.params.length - 1]);
      return reply.params.length < 4 || reply.params[2] != '*';
    });
    return caps;
  }

  Future<bool> _requestCap(String cap) async {
    var cmd = IrcMessage('CAP', ['REQ', cap]);
    var ok = false;
    await _roundtripMessage(cmd, (reply) {
      if (reply.cmd != 'CAP' ||
          reply.params.length < 3 ||
          !_capListContains(reply.params.last, cap)) {
        return false;
      }
      switch (reply.params[1].toUpperCase()) {
        case 'ACK':
          ok = true;
          return true;
        case 'NAK':
          return true;
        default:
          return false;
      }
    });
    return ok;
  }

  Future<IrcIsupportRegistry> fetchIsupport() async {
    var cmd = IrcMessage('ISUPPORT', []);
    var batch = await _roundtripBatch(cmd, (batch) {
      return batch.type == 'draft/isupport';
    });

    var registry = IrcIsupportRegistry();
    for (var msg in batch.messages) {
      registry.parse(msg.params.sublist(1, msg.params.length - 1));
    }
    return registry;
  }

  Future<List<ChatHistoryTarget>> fetchChatHistoryTargets(
      String t1, String t2, int limit) async {
    var msg = IrcMessage(
      'CHATHISTORY',
      ['TARGETS', 'timestamp=' + t1, 'timestamp=' + t2, '$limit'],
    );

    var batch = await _roundtripBatch(msg, (batch) {
      return batch.type == 'draft/chathistory-targets';
    });
    return batch.messages.map((msg) {
      if (msg.cmd != 'CHATHISTORY' || msg.params[0] != 'TARGETS') {
        throw FormatException('Expected CHATHISTORY TARGET message, got: $msg');
      }
      return ChatHistoryTarget._(msg.params[1], msg.params[2]);
    }).toList();
  }

  Future<ClientBatch> _fetchChatHistory(
      String subcmd, String target, List<String> params) {
    var msg = IrcMessage('CHATHISTORY', [subcmd, target, ...params]);

    return _roundtripBatch(msg, (batch) {
      return batch.type == 'chathistory' &&
          isupport.caseMapping.equals(batch.params[0], target);
    });
  }

  Future<ClientBatch> fetchChatHistoryBetween(
      String target, String t1, String t2, int limit) {
    var params = ['timestamp=' + t1, 'timestamp=' + t2, '$limit'];
    return _fetchChatHistory('BETWEEN', target, params);
  }

  Future<ClientBatch> fetchChatHistoryBefore(
      String target, String t, int limit) {
    var params = ['timestamp=' + t, '$limit'];
    return _fetchChatHistory('BEFORE', target, params);
  }

  Future<ClientBatch> fetchChatHistoryLatest(
      String target, String? t, int limit) {
    var bound = t == null ? '*' : 'timestamp=' + t;
    var params = [bound, '$limit'];
    return _fetchChatHistory('LATEST', target, params);
  }

  Future<void> ping() async {
    var token = 'goguma-$_nextPingSerial';
    var msg = IrcMessage('PING', [token]);
    _nextPingSerial++;

    try {
      await _roundtripMessage(msg, (msg) {
        return msg.cmd == 'PONG' && msg.params[1] == token;
      }, timeout: const Duration(seconds: 15));
    } on Exception {
      _socket?.close().ignore();
      rethrow;
    }
  }

  /// Send a PRIVMSG, NOTICE or TAGMSG.
  ///
  /// If the server doesn't support echo-message, it's emulated.
  Future<IrcMessage> sendTextMessage(IrcMessage req) async {
    assert(req.cmd == 'PRIVMSG' || req.cmd == 'NOTICE' || req.cmd == 'TAGMSG');
    assert(req.params.length >= 1);

    if (caps.enabled.contains('echo-message')) {
      // Assume the first echo-message we get is the one we're waiting
      // for. Rely on labeled-response to improve this assumption's
      // robustness. If labeled-response is not available, keep track of
      // the number of messages we've sent for that target.

      var cm = isupport.caseMapping;
      var target = req.params[0];

      String? pendingKey;
      var skip = 0;
      if (!caps.enabled.contains('labeled-response')) {
        pendingKey = req.cmd + ' ' + cm.canonicalize(target);
        skip = _pendingTextMsgs[pendingKey] ?? 0;
        _pendingTextMsgs[pendingKey] = skip + 1;
      }

      IrcMessage? echo;
      try {
        await _roundtripMessage(req, (reply) {
          bool match;
          switch (reply.cmd) {
            case ERR_NOSUCHNICK:
            case ERR_CANNOTSENDTOCHAN:
              match = cm.equals(reply.params[1], target);
              break;
            case ERR_NOTEXTTOSEND:
              match = true;
              break;
            default:
              match =
                  reply.cmd == req.cmd && cm.equals(reply.params[0], target);
              break;
          }
          if (!match) {
            return false;
          }

          if (skip > 0) {
            skip--;
            return false;
          }

          if (reply.cmd != req.cmd) {
            throw IrcException(reply);
          } else {
            echo = reply;
            return true;
          }
        });
      } finally {
        if (pendingKey != null) {
          var n = _pendingTextMsgs[pendingKey]! - 1;
          if (n == 0) {
            _pendingTextMsgs.remove(pendingKey);
          } else {
            _pendingTextMsgs[pendingKey] = n;
          }
        }
      }

      return echo!;
    } else {
      // Best-effort: assume a PING is enough.
      // TODO: catch errors
      send(req);
      await ping();

      // Simulate echo-message to simplify message handling
      var emulatedEcho = req.copyWith(source: IrcSource(nick));
      if (!_messagesController.isClosed) {
        _messagesController.add(ClientMessage._(emulatedEcho));
      }

      return emulatedEcho;
    }
  }

  bool supportsReadMarker() {
    return caps.enabled.contains('draft/read-marker');
  }

  Future<void> fetchReadMarker(String target) {
    var msg = IrcMessage('MARKREAD', [target]);
    return _roundtripMessage(msg, (msg) {
      return msg.cmd == 'MARKREAD' &&
          isupport.caseMapping.equals(msg.params[0], target);
    }, timeout: Duration(seconds: 15));
  }

  void setReadMarker(String target, String t) {
    if (!caps.enabled.contains('server-time') || !supportsReadMarker()) {
      return;
    }
    send(IrcMessage('MARKREAD', [target, 'timestamp=' + t]));
  }

  Future<NamesReply> names(String channel) async {
    var msg = IrcMessage('NAMES', [channel]);
    var endMsg = await _roundtripMessage(msg, (msg) {
      return msg.cmd == RPL_ENDOFNAMES &&
          isupport.caseMapping.equals(msg.params[1], channel);
    });
    var endOfNames = endMsg as ClientEndOfNames;
    return endOfNames.names;
  }

  Future<List<WhoReply>> _who(String mask, Set<WhoxField> whoxFields) async {
    whoxFields = {...whoxFields};
    whoxFields.addAll([
      WhoxField.channel,
      WhoxField.username,
      WhoxField.host,
      WhoxField.nickname,
      WhoxField.flags,
      WhoxField.account,
      WhoxField.realname,
    ]);

    var msg = IrcMessage(
        'WHO', isupport.whox ? [mask, formatWhoxParam(whoxFields)] : [mask]);

    List<WhoReply> replies = [];
    await _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case RPL_WHOREPLY:
          replies.add(WhoReply.parse(msg, isupport));
          break;
        case RPL_WHOSPCRPL:
          replies.add(WhoReply.parseWhox(msg, whoxFields, isupport));
          break;
        case RPL_ENDOFWHO:
          return isupport.caseMapping.equals(msg.params[1], mask);
      }
      return false;
    });

    return replies;
  }

  Future<List<WhoReply>> who(String mask,
      {Set<WhoxField> whoxFields = const {}}) {
    var future = _lastWhoFuture.then((_) => _who(mask, whoxFields));

    // Create a new Future which never errors out, always succeeds when the
    // previous WHO command completes
    var completer = Completer<void>();
    _lastWhoFuture = completer.future;
    return future.whenComplete(() {
      completer.complete(null);
    });
  }

  Future<Whois> whois(String nick) async {
    var msg = IrcMessage('WHOIS', [nick]);
    List<ClientMessage> replies = [];
    var endMsg = await _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case ERR_NOSUCHNICK:
        case ERR_NOSUCHSERVER:
          throw IrcException(msg);
        case RPL_WHOISCERTFP:
        case RPL_WHOISREGNICK:
        case RPL_WHOISUSER:
        case RPL_WHOISSERVER:
        case RPL_WHOISOPERATOR:
        case RPL_WHOISIDLE:
        case RPL_WHOISCHANNELS:
        case RPL_WHOISSPECIAL:
        case RPL_WHOISACCOUNT:
        case RPL_WHOISACTUALLY:
        case RPL_WHOISHOST:
        case RPL_WHOISMODES:
        case RPL_WHOISSECURE:
        case RPL_AWAY:
        case RPL_WHOISBOT:
          if (isupport.caseMapping.equals(msg.params[1], nick)) {
            replies.add(msg);
          }
          break;
        case RPL_ENDOFWHOIS:
          return isupport.caseMapping.equals(msg.params[1], nick);
      }
      return false;
    });
    var prefixes = isupport.memberships.map((m) => m.prefix).join('');
    return Whois.parse(endMsg.params[1], replies, prefixes);
  }

  Future<List<ListReply>> _list(String mask) async {
    var msg = IrcMessage('LIST', [mask]);
    List<ListReply> replies = [];
    await _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case RPL_LIST:
          replies.add(ListReply.parse(msg));
          break;
        case RPL_LISTEND:
          return true;
      }
      return false;
    });
    return replies;
  }

  Future<List<ListReply>> list(String mask) {
    var future = _lastListFuture.then((_) => _list(mask));

    // Create a new Future which never errors out, always succeeds when the
    // previous LIST command completes
    var completer = Completer<void>();
    _lastListFuture = completer.future;
    return future.whenComplete(() {
      completer.complete(null);
    });
  }

  Future<String?> motd() async {
    var msg = IrcMessage('MOTD', []);
    String? motd;
    await _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case RPL_MOTD:
          var line = msg.params[1];
          if (line.startsWith('- ')) {
            line = line.substring(2);
          }
          if (motd == null) {
            motd = line;
          } else {
            motd = motd! + '\n' + line;
          }
          break;
        case RPL_ENDOFMOTD:
        case ERR_NOMOTD:
          return true;
      }
      return false;
    });
    return motd;
  }

  void monitor(Iterable<String> targets) {
    var l = targets.where((name) => !_monitored.containsKey(name)).toList();
    var limit = isupport.monitor;
    if (limit == null) {
      return;
    } else if (_monitored.length + l.length > limit) {
      l = l.sublist(0, limit - _monitored.length);
    }

    if (l.isEmpty) {
      return;
    }

    send(IrcMessage('MONITOR', ['+', l.join(',')]));
    for (var name in l) {
      _monitored[name] = null;
    }
  }

  void unmonitor(Iterable<String> targets) {
    var l = targets.where((name) => _monitored.containsKey(name)).toList();
    if (l.isEmpty) {
      return;
    }

    send(IrcMessage('MONITOR', ['-', l.join(',')]));
    for (var name in l) {
      _monitored.remove(name);
    }
  }

  Future<void> setAway(String? msg) async {
    List<String> params = [];
    if (msg != null) {
      params.add(msg == '' ? '*' : msg);
    }
    var cmd = IrcMessage('AWAY', params);
    await _roundtripMessage(cmd, (reply) {
      switch (reply.cmd) {
        case RPL_NOWAWAY:
        case RPL_UNAWAY:
          return true;
      }
      return false;
    });
    _params = _params.apply(away: msg);
  }

  Future<void> join(List<String> names, {List<String>? keys}) async {
    if (names.isEmpty) {
      return;
    }

    var cm = isupport.caseMapping;
    // TODO: split into multiple JOIN messages if too long
    var reqParams = [names.join(',')];
    if (keys != null && keys.any((key) => key.isNotEmpty)) {
      reqParams.add(keys.join(','));
    }
    var req = IrcMessage('JOIN', reqParams);
    Set<String> outstanding = {...names.map(cm.canonicalize)};
    await _roundtripMessage(req, (reply) {
      switch (reply.cmd) {
        case ERR_NOSUCHCHANNEL:
        case ERR_TOOMANYCHANNELS:
        case ERR_BADCHANNELKEY:
        case ERR_BANNEDFROMCHAN:
        case ERR_CHANNELISFULL:
        case ERR_INVITEONLYCHAN:
        case ERR_BADCHANMASK:
          if (!outstanding.contains(cm.canonicalize(reply.params[1]))) {
            break;
          }
          throw IrcException(reply);
        case 'JOIN':
          if (!isMyNick(reply.source.name)) {
            break;
          }
          outstanding.remove(cm.canonicalize(reply.params[0]));
          return outstanding.isEmpty;
        case RPL_ENDOFNAMES:
          var channel = cm.canonicalize(reply.params[1]);
          if (!outstanding.contains(channel)) {
            break;
          }
          outstanding.remove(channel);
          return outstanding.isEmpty;
      }
      return false;
    });
  }

  Future<void> setTopic(String channel, String? topic) {
    var msg = IrcMessage('TOPIC', [channel, topic ?? '']);
    return _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case ERR_NOSUCHCHANNEL:
        case ERR_NOTONCHANNEL:
        case ERR_CHANOPRIVSNEEDED:
          if (isupport.caseMapping.equals(msg.params[1], channel)) {
            throw IrcException(msg);
          }
          break;
        case 'TOPIC':
          return isupport.caseMapping.equals(msg.params[0], channel);
      }
      return false;
    });
  }

  Future<void> setMetadata(String channel, String key, String value) async {
    var msg = IrcMessage('METADATA', [channel, 'SET', key, value]);
    await _roundtripMessage(msg, (msg) {
      return msg.cmd == RPL_KEYVALUE &&
          msg.params[1] == channel &&
          msg.params[2] == key;
    });
  }

  Future<IrcMessage> fetchMode(String target) {
    assert(isChannel(target)); // TODO: support for fetching user modes
    var msg = IrcMessage('MODE', [target]);
    return _roundtripMessage(msg, (msg) {
      switch (msg.cmd) {
        case ERR_NOSUCHCHANNEL:
          if (isupport.caseMapping.equals(msg.params[1], target)) {
            throw IrcException(msg);
          }
          break;
        case RPL_CHANNELMODEIS:
          return isupport.caseMapping.equals(msg.params[1], target);
      }
      return false;
    });
  }

  Future<void> setNickname(String nick) async {
    var msg = IrcMessage('NICK', [nick]);
    var oldNick = this.nick;
    await _roundtripMessage(msg, (msg) {
      return msg.cmd == 'NICK' &&
          isupport.caseMapping.equals(msg.source.name, oldNick);
    });
    _params = _params.apply(nick: nick);
  }

  Future<void> setRealname(String realname) async {
    var msg = IrcMessage('SETNAME', [realname]);
    await _roundtripMessage(msg, (msg) {
      return msg.cmd == 'SETNAME' && isMyNick(msg.source.name);
    });
    _params = _params.apply(realname: realname);
  }

  Future<void> webPushRegister(String endpoint, Map<String, List<int>> keys) {
    Map<String, String> encodedKeys = Map.fromEntries(keys.entries.map((kv) {
      return MapEntry(kv.key, base64Url.encode(kv.value));
    }));
    var msg = IrcMessage(
        'WEBPUSH', ['REGISTER', endpoint, formatIrcTags(encodedKeys)]);
    return _roundtripMessage(msg, (msg) {
      return msg.cmd == 'WEBPUSH' &&
          msg.params[0] == 'REGISTER' &&
          msg.params[1] == endpoint;
    });
  }

  Future<void> webPushUnregister(String endpoint) {
    var msg = IrcMessage('WEBPUSH', ['UNREGISTER', endpoint]);
    return _roundtripMessage(msg, (msg) {
      return msg.cmd == 'WEBPUSH' &&
          msg.params[0] == 'UNREGISTER' &&
          msg.params[1] == endpoint;
    });
  }

  Future<String> addBouncerNetwork(Map<String, String?> attrs) async {
    var cmd = IrcMessage('BOUNCER', ['ADDNETWORK', formatIrcTags(attrs)]);
    var reply = await _roundtripMessage(cmd, (reply) {
      return reply.cmd == 'BOUNCER' && reply.params[0] == 'ADDNETWORK';
    });
    return reply.params[1];
  }

  Future<void> changeBouncerNetwork(
      String id, Map<String, String?> attrs) async {
    var cmd =
        IrcMessage('BOUNCER', ['CHANGENETWORK', id, formatIrcTags(attrs)]);
    await _roundtripMessage(cmd, (reply) {
      return reply.cmd == 'BOUNCER' &&
          reply.params[0] == 'CHANGENETWORK' &&
          reply.params[1] == id;
    });
  }

  Future<void> deleteBouncerNetwork(String id) async {
    var cmd = IrcMessage('BOUNCER', ['DELNETWORK', id]);
    await _roundtripMessage(cmd, (reply) {
      return reply.cmd == 'BOUNCER' &&
          reply.params[0] == 'DELNETWORK' &&
          reply.params[1] == id;
    });
  }

  bool get canReply =>
      caps.enabled.contains('message-tags') &&
      (isupport.isClientTagAllowed('draft/reply') ||
          isupport.isClientTagAllowed('reply'));

  bool get canReact => canReply && isupport.isClientTagAllowed('draft/react');

  bool get canRedact => caps.enabled.contains('draft/message-redaction');
}

class ClientMessage extends IrcMessage {
  final ClientBatch? batch;

  ClientMessage._(IrcMessage msg, {this.batch})
      : super(msg.cmd, msg.params, tags: msg.tags, source: msg.source);

  @override
  IrcSource get source => super.source!;

  ClientBatch? batchByType(String type) {
    ClientBatch? batch = this.batch;
    while (batch != null) {
      if (batch.type == type) {
        return batch;
      }
      batch = batch.parent;
    }
    return null;
  }

  String? get label {
    if (tags.containsKey('label')) {
      return tags['label'];
    }

    var batch = batchByType('labeled-response');
    if (batch != null) {
      return batch.tags['label'];
    }

    return null;
  }
}

class _IrcLineDecoder extends StreamTransformerBase<Uint8List, String> {
  static const _maxLineBytes = 32 * 1024;

  const _IrcLineDecoder();

  @override
  Stream<String> bind(Stream<Uint8List> stream) async* {
    var bytes = <int>[];
    var discardCurrentLine = false;
    await for (var chunk in stream) {
      for (var byte in chunk) {
        if (byte == 10) {
          if (!discardCurrentLine) {
            yield _decodeLine(bytes);
          }
          bytes = <int>[];
          discardCurrentLine = false;
        } else if (byte != 13) {
          if (discardCurrentLine) {
            continue;
          }
          if (bytes.length < _maxLineBytes) {
            bytes.add(byte);
          } else {
            bytes = <int>[];
            discardCurrentLine = true;
          }
        }
      }
    }
    if (!discardCurrentLine && bytes.isNotEmpty) {
      yield _decodeLine(bytes);
    }
  }

  String _decodeLine(List<int> bytes) {
    if (bytes.isEmpty) {
      return '';
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return _decodeWindows1254(bytes);
    }
  }

  String _decodeWindows1254(List<int> bytes) {
    return String.fromCharCodes(bytes.map((byte) {
      return _windows1254CodePoint(byte);
    }));
  }

  int _windows1254CodePoint(int byte) {
    switch (byte) {
      case 0x80:
        return 0x20AC;
      case 0x82:
        return 0x201A;
      case 0x83:
        return 0x0192;
      case 0x84:
        return 0x201E;
      case 0x85:
        return 0x2026;
      case 0x86:
        return 0x2020;
      case 0x87:
        return 0x2021;
      case 0x88:
        return 0x02C6;
      case 0x89:
        return 0x2030;
      case 0x8A:
        return 0x0160;
      case 0x8B:
        return 0x2039;
      case 0x8C:
        return 0x0152;
      case 0x91:
        return 0x2018;
      case 0x92:
        return 0x2019;
      case 0x93:
        return 0x201C;
      case 0x94:
        return 0x201D;
      case 0x95:
        return 0x2022;
      case 0x96:
        return 0x2013;
      case 0x97:
        return 0x2014;
      case 0x98:
        return 0x02DC;
      case 0x99:
        return 0x2122;
      case 0x9A:
        return 0x0161;
      case 0x9B:
        return 0x203A;
      case 0x9C:
        return 0x0153;
      case 0x9F:
        return 0x0178;
      case 0xD0:
        return 0x011E;
      case 0xDD:
        return 0x0130;
      case 0xDE:
        return 0x015E;
      case 0xF0:
        return 0x011F;
      case 0xFD:
        return 0x0131;
      case 0xFE:
        return 0x015F;
      default:
        return byte;
    }
  }
}

class ClientEndOfNames extends ClientMessage {
  final NamesReply names;

  ClientEndOfNames._(
      super.msg, List<ClientMessage> names, IrcIsupportRegistry isupport,
      {super.batch})
      : names = names.isEmpty
            ? NamesReply.empty(msg.params[1])
            : NamesReply.parse(names, isupport),
        super._();
}

class ClientEndOfBatch extends ClientMessage {
  final ClientBatch child;

  ClientEndOfBatch._(super.msg, this.child, {super.batch}) : super._();
}

class ClientBatch {
  final String type;
  final UnmodifiableListView<String> params;
  final ClientBatch? parent;
  final UnmodifiableMapView<String, String?> tags;

  final List<ClientMessage> _messages = [];

  UnmodifiableListView<ClientMessage> get messages =>
      UnmodifiableListView(_messages);

  ClientBatch._(
      this.type, List<String> params, this.parent, Map<String, String?> tags)
      : params = UnmodifiableListView(params),
        tags = UnmodifiableMapView(tags);
}

class ChatHistoryTarget {
  final String name;
  final String time;

  const ChatHistoryTarget._(this.name, this.time);

  @override
  String toString() {
    return 'CHATHISTORY TARGETS $name $time';
  }
}
