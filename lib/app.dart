import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_handler/share_handler.dart';

import 'additional_server_subscription.dart';
import 'ansi.dart';
import 'client.dart';
import 'client_controller.dart';
import 'dialog/authenticate.dart';
import 'irc/irc.dart';
import 'logging.dart';
import 'models.dart';
import 'network_state_aggregator.dart';
import 'notification_controller.dart';
import 'page/buffer.dart';
import 'page/buffer_details.dart';
import 'page/buffer_list.dart';
import 'page/call.dart';
import 'page/connect.dart';
import 'page/edit_bouncer_network.dart';
import 'page/gallery.dart';
import 'page/join.dart';
import 'page/network_details.dart';
import 'page/settings.dart';
import 'page/share.dart';
import 'profile_backend.dart';
import 'widget/app_snack_bar.dart';

const _themeMode = ThemeMode.system;
const _activityChannel = MethodChannel('com.ircmobile.app/activity');

const _nativePrimary = Color(0xFF78A9FF);
const _nativeSecondary = Color(0xFF3DE0C5);
const _nativeBackground = Color(0xFF070B12);
const _nativeSurface = Color(0xFF0E1520);
const _nativeSurfaceHigh = Color(0xFF151F2D);
const _nativeText = Color(0xFFF3F7FF);
const _nativeMutedText = Color(0xFFABB8CA);

final _nativeDarkScheme = ColorScheme.fromSeed(
  seedColor: _nativePrimary,
  brightness: Brightness.dark,
).copyWith(
  primary: _nativePrimary,
  secondary: _nativeSecondary,
  surface: _nativeSurface,
  surfaceContainerLowest: _nativeBackground,
  surfaceContainerLow: _nativeSurface,
  surfaceContainer: _nativeSurfaceHigh,
  surfaceContainerHigh: Color(0xFF1C2939),
  surfaceContainerHighest: Color(0xFF26364A),
  outline: Color(0xFF52647A),
  outlineVariant: Color(0xFF314157),
  primaryContainer: Color(0xFF214E9A),
  secondaryContainer: Color(0xFF124C48),
  tertiary: Color(0xFFC0A7FF),
  tertiaryContainer: Color(0xFF463874),
  error: Color(0xFFFF6B78),
  errorContainer: Color(0xFF5B202A),
  onPrimary: Color(0xFF061A36),
  onSecondary: Color(0xFF002A24),
  onSurface: _nativeText,
  onSurfaceVariant: _nativeMutedText,
  onPrimaryContainer: Color(0xFFEAF1FF),
  onSecondaryContainer: Color(0xFFDCFFF8),
  onTertiary: Color(0xFF251A43),
  onError: Color(0xFF3B0008),
);

ThemeData _nativeTheme(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    canvasColor: scheme.surfaceContainerLowest,
    splashColor: scheme.primary.withValues(alpha: 0.12),
    highlightColor: scheme.primary.withValues(alpha: 0.08),
    dividerColor: scheme.outlineVariant,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLowest,
      foregroundColor: scheme.onSurface,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: scheme.surfaceContainerLowest,
        systemNavigationBarColor: scheme.surfaceContainerLowest,
        systemNavigationBarDividerColor: scheme.surfaceContainerLowest,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      dense: false,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.32),
      selectionHandleColor: scheme.primary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: InputBorder.none,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      shape: CircleBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
    ),
  );
}

class App extends StatefulWidget {
  final IrcUri? initialUri;
  final SharedMedia? initialSharedMedia;

  const App({super.key, this.initialUri, this.initialSharedMedia});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  late final String _initialRoute;
  Timer? _pingTimer;
  ClientAutoReconnectLock? _autoReconnectLock;
  final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey(debugLabel: 'main-navigator');
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey(debugLabel: 'main-scaffold-messenger');
  late StreamSubscription<void> _clientErrorSub;
  late StreamSubscription<void> _clientNoticeSub;
  late StreamSubscription<void> _connectivitySub;
  late StreamSubscription<void> _notifSelectionSub;
  StreamSubscription<String>? _incomingCallSub;
  StreamSubscription<void>? _appLinksSub;
  StreamSubscription<void>? _sharedMediaSub;
  String? _activeIncomingCallPayload;
  String? _endedIncomingCallPayload;
  late NetworkStateAggregator _networkStateAggregator;
  Set<ConnectivityResult>? _connectivity;
  final Map<NetworkModel, List<TopRightSnackBarController>>
      _snackBarControllers = {};
  TopRightSnackBarController? _networkStateSnackBarController;
  Set<NetworkModel> _faultyNetworks = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    var state = WidgetsBinding.instance.lifecycleState;
    _handleAppLifecycleState(state ?? AppLifecycleState.resumed);

    var notifController = context.read<NotificationController>();
    notifController.popLaunchSelection().then(_handleSelectNotification);
    _notifSelectionSub =
        notifController.selections.listen(_handleSelectNotification);
    if (callsEnabled) {
      _incomingCallSub =
          notifController.incomingCalls.listen(_handleIncomingCall);
    }

    var clientProvider = context.read<ClientProvider>();
    _clientErrorSub = clientProvider.errors.listen((err) {
      if (err.msg.cmd == ERR_NOTREGISTERED) {
        // We may send commands the server doesn't accept before
        // connection registration (e.g. AWAY), because we don't know
        // the server's available capabilities at that point.
        return;
      }
      if (err.msg.cmd == ERR_UNKNOWNCOMMAND && err.msg.params[1] == 'AWAY') {
        // Some servers may be missing AWAY support
        return;
      }
      if (err.msg.cmd == 'FAIL' &&
          err.msg.params[0] == 'METADATA' &&
          err.msg.params[1] == 'KEY_INVALID') {
        // We blindly subscribe to all metadata keys we're interested
        // in, regardless of server support
        return;
      }

      SnackBarAction? action;
      if (err.msg.cmd == ERR_SASLFAIL) {
        if (err.client.params.bouncerNetId != null) {
          // We'll get the same error on the bouncer connection
          return;
        }

        if (err.client.params.saslPlain != null) {
          // TODO: also handle FAIL ACCOUNT_REQUIRED
          action = SnackBarAction(
            label: 'UPDATE PASSWORD',
            onPressed: () {
              AuthenticateDialog.show(
                  _navigatorKey.currentState!.context, err.network);
            },
          );
        }
      }

      var snackBar = SnackBar(content: Text(err.toString()), action: action);
      _showNetworkSnackBar(snackBar, err.network);
    });
    _clientNoticeSub = clientProvider.notices.listen((notice) {
      List<String> texts = [];
      for (var msg in notice.msgs) {
        texts.add(stripAnsiFormatting(msg.params[1]));
      }
      var snackBar = SnackBar(
          content: Text.rich(TextSpan(children: [
        TextSpan(
            text: notice.target, style: TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: ': '),
        TextSpan(text: texts.join('\n')),
      ])));
      _showNetworkSnackBar(snackBar, notice.network);
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      var current = result.toSet();
      var connectivityChanged =
          _connectivity != null && !setEquals(_connectivity, current);
      _connectivity = current;
      var isConnected =
          current.isNotEmpty && !current.contains(ConnectivityResult.none);
      if (isConnected &&
          _shouldAutoReconnectInState(WidgetsBinding.instance.lifecycleState)) {
        if (connectivityChanged) {
          _reconnectAll();
        } else {
          _pingAll();
        }
      }
    });

    var networkList = context.read<NetworkListModel>();
    _networkStateAggregator = NetworkStateAggregator(networkList);
    _networkStateAggregator.addListener(_handleNetworkStateChange);
    _handleNetworkStateChange();

    if (Platform.isAndroid || Platform.isIOS) {
      // Ignore initialUri: appLinks.stringLinkStream will trigger an
      // event for that URI
      var appLinks = context.read<AppLinks>();
      _appLinksSub = appLinks.stringLinkStream.listen(_handleAppLink);

      _sharedMediaSub =
          ShareHandler.instance.sharedMediaStream.listen(_handleSharedMedia);
    }

    if (networkList.networks.isEmpty) {
      _initialRoute = ConnectPage.routeName;
    } else if (widget.initialSharedMedia != null) {
      _initialRoute = SharePage.routeName;
    } else {
      _initialRoute = BufferListPage.routeName;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingTimer?.cancel();
    _autoReconnectLock?.release();
    _clientErrorSub.cancel();
    _clientNoticeSub.cancel();
    _connectivitySub.cancel();
    _notifSelectionSub.cancel();
    _incomingCallSub?.cancel();
    _networkStateSnackBarController?.close();
    _appLinksSub?.cancel();
    _sharedMediaSub?.cancel();
    _networkStateAggregator.removeListener(_handleNetworkStateChange);
    _networkStateAggregator.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    _handleAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (Platform.isAndroid) {
        // A retained Flutter engine must re-register back handling after its
        // activity is recreated, otherwise Android exits before routes can pop.
        unawaited(SystemNavigator.setFrameworkHandlesBack(true));
      }
      // Send PINGs to make sure the connections are healthy
      _pingAll();
    }
  }

  @override
  Future<bool> didPopRoute() async {
    var navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return false;
    }
    if (await navigator.maybePop()) {
      return true;
    }
    if (Platform.isAndroid) {
      await _activityChannel.invokeMethod<void>('moveTaskToBack');
      return true;
    }
    return false;
  }

  void _handleAppLifecycleState(AppLifecycleState state) {
    context.read<NotificationController>().setAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<AdditionalServerSubscription>().refresh());
    }

    if (_shouldAutoReconnectInState(state)) {
      _enableAutoReconnect();
      _enablePingTimer();
    } else {
      _autoReconnectLock?.release();
      _autoReconnectLock = null;
      _pingTimer?.cancel();
      _pingTimer = null;
    }

    // Android can detach the Flutter view while the process/foreground work is
    // still alive. Do not send QUIT here; let the OS kill the socket if it must.
  }

  bool _shouldAutoReconnectInState(AppLifecycleState? state) {
    return !context.read<ClientProvider>().shutdownForExitRequested;
  }

  void _showNetworkSnackBar(SnackBar snackBar, NetworkModel network) {
    var overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) {
      return;
    }

    var controller =
        showTopRightSnackBar(overlay.context, snackBar, overlay: overlay);
    _snackBarControllers.putIfAbsent(network, () => []).add(controller);
    controller.closed.whenComplete(() {
      _snackBarControllers[network]!.remove(controller);
    });
  }

  void _closeNetworkSnackBars(NetworkModel network) {
    for (var controller in _snackBarControllers[network] ?? const []) {
      controller.close();
    }
  }

  void _enableAutoReconnect() {
    var clientProvider = context.read<ClientProvider>();
    if (clientProvider.shutdownForExitRequested) {
      return;
    }
    _autoReconnectLock?.release();
    _autoReconnectLock = ClientAutoReconnectLock.acquire(clientProvider);
  }

  void _enablePingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _pingAll();
    });
  }

  void _pingAll() {
    var clientProvider = context.read<ClientProvider>();
    if (clientProvider.shutdownForExitRequested) {
      return;
    }
    for (var client in clientProvider.clients) {
      unawaited(() async {
        switch (client.state) {
          case ClientState.connected:
            try {
              await client.ping();
            } on Exception catch (err) {
              log.print('PING failed', error: err);
            }
            break;
          case ClientState.disconnected:
            if (client.hasPendingReconnect) {
              return;
            }
            if (clientProvider.shutdownForExitRequested) {
              return;
            }
            try {
              await client.connect();
            } on Exception catch (err) {
              log.print('Reconnect failed', error: err);
            }
            break;
          default:
            break;
        }
      }());
    }
  }

  void _reconnectAll() {
    var clientProvider = context.read<ClientProvider>();
    if (clientProvider.shutdownForExitRequested) {
      return;
    }
    for (var client in clientProvider.clients) {
      unawaited(client.connect().catchError((Object err) {
        log.print('Network-change reconnect failed', error: err);
      }));
    }
  }

  void _handleSelectNotification(String? payload) {
    if (payload == null) {
      return;
    }
    if (payload == 'radio') {
      return;
    }
    if (!callsEnabled &&
        (payload.startsWith('call:') ||
            payload.startsWith('call-decline:') ||
            payload.startsWith('call-end:'))) {
      return;
    }
    if (payload.startsWith('call-decline:')) {
      unawaited(
          _declineIncomingCall(payload.replaceFirst('call-decline:', '')));
    } else if (payload.startsWith('call:')) {
      _handleSelectCallNotification(payload.replaceFirst('call:', ''));
    } else if (payload.startsWith('buffer:')) {
      _handleSelectBufferNotification(payload.replaceFirst('buffer:', ''));
    } else if (payload.startsWith('invite:')) {
      _handleSelectInviteNotification(payload.replaceFirst('invite:', ''));
    } else {
      throw FormatException('Invalid payload: $payload');
    }
  }

  void _handleIncomingCall(String payload) {
    if (payload.startsWith('call-end:')) {
      _handleIncomingCallEnd(payload);
      return;
    }
    if (_activeIncomingCallPayload != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _activeIncomingCallPayload == null) {
        unawaited(_showIncomingCallDialog(payload));
      }
    });
  }

  Future<void> _showIncomingCallDialog(String payload) async {
    var parts = payload.replaceFirst('call:', '').split(':');
    if (parts.length < 4) {
      return;
    }
    var video = parts[1] == '1';
    var caller = Uri.decodeComponent(parts[2]);
    var navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) {
      return;
    }

    _activeIncomingCallPayload = payload;
    var accepted = await showGeneralDialog<bool>(
      context: navigatorContext,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, __) => _IncomingCallScreen(
        caller: caller,
        video: video,
      ),
      transitionBuilder: (context, animation, _, child) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(animation),
            child: child,
          ),
        );
      },
    );
    if (!mounted) {
      return;
    }
    await context.read<NotificationController>().dismissCallInvite();
    var endedRemotely = _endedIncomingCallPayload == payload;
    if (endedRemotely) {
      _endedIncomingCallPayload = null;
    }
    _activeIncomingCallPayload = null;
    if (accepted == true && mounted) {
      _handleSelectNotification(payload);
    } else if (!endedRemotely) {
      unawaited(_declineIncomingCall(payload));
    }
  }

  void _handleIncomingCallEnd(String payload) {
    var activePayload = _activeIncomingCallPayload;
    if (activePayload == null || !_callEndMatches(payload, activePayload)) {
      return;
    }
    _endedIncomingCallPayload = activePayload;
    _navigatorKey.currentState?.pop(false);
  }

  bool _callEndMatches(String endPayload, String activePayload) {
    var endParts = endPayload.replaceFirst('call-end:', '').split(':');
    var activeParts = activePayload.replaceFirst('call:', '').split(':');
    if (endParts.length < 2 || activeParts.length < 4) {
      return false;
    }
    var endCaller = Uri.decodeComponent(endParts.sublist(1).join(':'));
    var activeCaller = Uri.decodeComponent(activeParts[2]);
    return endParts[0] == activeParts[0] &&
        endCaller.toLowerCase() == activeCaller.toLowerCase();
  }

  Future<void> _declineIncomingCall(String payload) async {
    var parts = payload.replaceFirst('call:', '').split(':');
    if (parts.length < 4) {
      return;
    }
    var bufferId = int.tryParse(parts[0]);
    var roomUrl = Uri.decodeComponent(parts.sublist(3).join(':'));
    var roomId = callRoomIdFromUrl(roomUrl);
    if (bufferId == null || roomId == null) {
      return;
    }
    var buffer = context.read<BufferListModel>().byId(bufferId);
    if (buffer == null) {
      return;
    }
    var client = context.read<ClientProvider>().get(buffer.network);
    var clientId = 'decline-${DateTime.now().microsecondsSinceEpoch}';
    var backend = const ProfileBackendClient();
    try {
      await backend.postCallEvent(
        roomId: roomId,
        clientId: clientId,
        type: 'decline',
        payload: {'nick': client.nick},
      );
      return;
    } on Exception catch (err) {
      log.print('Failed to send call decline event', error: err);
    }
    try {
      await backend.postCallEvent(
        roomId: roomId,
        clientId: clientId,
        type: 'join',
        payload: {
          'nick': client.nick,
          'role': 'member',
        },
      );
      await backend.postCallEvent(
        roomId: roomId,
        clientId: clientId,
        type: 'leave',
        payload: {'nick': client.nick},
      );
    } on Exception catch (err) {
      log.print('Failed to decline call room', error: err);
    }
  }

  void _handleSelectCallNotification(String payload) {
    var parts = payload.split(':');
    if (parts.length < 4) {
      throw FormatException('Invalid call payload: $payload');
    }
    var bufferId = int.parse(parts[0]);
    var video = parts[1] == '1';
    var caller = Uri.decodeComponent(parts[2]);
    var roomUrl = Uri.decodeComponent(parts.sublist(3).join(':'));

    var bufferList = context.read<BufferListModel>();
    var navigatorState = _navigatorKey.currentState!;
    var buffer = bufferList.byId(bufferId);
    if (buffer == null) {
      return;
    }
    var client = context.read<ClientProvider>().get(buffer.network);
    var roomUri = Uri.tryParse(roomUrl);
    var channelTarget = roomUri?.queryParameters['channel'] ?? '';
    var role = buffer.network.isIrcOperator ? 'irc_operator' : 'member';
    var channelMembers = const <String>[];
    var channelMemberPrefixes = const <String, String>{};
    var returnBuffer = buffer;
    if (channelTarget.isNotEmpty) {
      var channelBuffer = bufferList.get(channelTarget, buffer.network);
      if (channelBuffer != null) {
        returnBuffer = channelBuffer;
      }
      var membership = channelBuffer?.members?.members[client.nick] ?? '';
      const operatorPrefixes = '!~&@%';
      if (role != 'irc_operator' &&
          membership.split('').any(operatorPrefixes.contains)) {
        role = 'channel_operator';
      }
      channelMembers =
          channelBuffer?.members?.members.keys.toList(growable: false) ??
              const [];
      channelMemberPrefixes = channelBuffer?.members?.members ?? const {};
    }
    var parsed = CallPageArguments.tryParse(
      roomUrl,
      target: caller.isNotEmpty ? caller : buffer.name,
      video: video,
      nick: client.nick,
      role: role,
      channelMembers: channelMembers,
      channelMemberPrefixes: channelMemberPrefixes,
      client: client,
      returnRouteName: BufferPage.routeName,
      returnRouteArguments: BufferPageArguments(buffer: returnBuffer),
    );
    if (parsed != null) {
      navigatorState.pushNamed(CallPage.routeName, arguments: parsed);
    }
  }

  void _handleSelectBufferNotification(String payload) {
    var bufferId = int.parse(payload);
    var bufferList = context.read<BufferListModel>();
    var navigatorState = _navigatorKey.currentState!;
    var buffer = bufferList.byId(bufferId);
    if (buffer == null) {
      return; // maybe closed by the user in-between
    }
    BufferPage.open(navigatorState.context, buffer.name, buffer.network);
  }

  void _handleSelectInviteNotification(String payload) {
    var i = payload.indexOf(':');
    if (i < 0) {
      throw FormatException('Invalid invite payload: $payload');
    }
    var networkId = int.parse(payload.substring(0, i));
    var channel = payload.substring(i + 1);

    var networkList = context.read<NetworkListModel>();
    var network = networkList.byId(networkId)!;

    BufferPage.open(_navigatorKey.currentState!.context, channel, network);
  }

  void _handleNetworkStateChange() {
    var networkList = context.read<NetworkListModel>();
    var state = _networkStateAggregator.state;
    var faultyNetworks = _networkStateAggregator.faultyNetworks;

    String? faultyNetworkName;
    if (faultyNetworks.length == 1) {
      faultyNetworkName = faultyNetworks.first.displayName;
    } else if (faultyNetworks.length == networkList.networks.length) {
      // If all networks belong to the same server (e.g. bouncer), use
      // that server's display name in the status message
      int? serverId;
      for (var network in faultyNetworks) {
        if (serverId == null) {
          serverId = network.serverEntry.id;
        } else if (serverId != network.serverEntry.id) {
          faultyNetworkName = null;
          break;
        }

        if (network.networkEntry.bouncerId == null) {
          faultyNetworkName = network.displayName;
        }
      }

      faultyNetworkName ??= 'all servers';
    } else {
      faultyNetworkName = '${faultyNetworks.length} servers';
    }

    var affectedNetworks = Set.of(faultyNetworks).union(_faultyNetworks);
    for (var network in affectedNetworks) {
      _closeNetworkSnackBars(network);
    }

    _faultyNetworks = Set.of(faultyNetworks);

    if (state != NetworkState.offline) {
      _networkStateSnackBarController?.close();
      _networkStateSnackBarController = null;
      return;
    }

    _networkStateSnackBarController?.close();
    var overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleNetworkStateChange();
        }
      });
      return;
    }
    _networkStateSnackBarController = showTopRightSnackBar(
        overlay.context,
        SnackBar(
          content: Text('Disconnected from $faultyNetworkName'),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'RECONNECT',
            onPressed: () {
              var clientProvider = context.read<ClientProvider>();
              for (var client in clientProvider.clients) {
                if (client.state == ClientState.disconnected) {
                  client.connect().ignore();
                }
              }
            },
          ),
        ),
        overlay: overlay);
  }

  void _handleAppLink(String uriStr) {
    var networkList = context.read<NetworkListModel>();
    var bufferList = context.read<BufferListModel>();
    var navigatorState = _navigatorKey.currentState!;

    var uri = IrcUri.parse(uriStr);

    if (networkList.networks.isEmpty) {
      navigatorState.pushReplacementNamed(ConnectPage.routeName,
          arguments: uri);
      return;
    }

    // TODO: also match port
    NetworkModel? network;
    for (var net in networkList.networks) {
      if (net.serverEntry.host == uri.host) {
        network = net;
        break;
      }

      var bouncerUri = net.networkEntry.bouncerUri;
      if (bouncerUri != null && bouncerUri.host == uri.host) {
        network = net;
        break;
      }
    }
    if (network != null) {
      if (uri.entity != null) {
        var buffer = bufferList.get(uri.entity!.name, network);
        if (buffer != null) {
          BufferPage.open(navigatorState.context, buffer.name, buffer.network,
              preserveStack: true);
        } else {
          _confirmOpenBuffer(network, uri.entity!.name);
        }
      } else {
        navigatorState.pushNamed(NetworkDetailsPage.routeName,
            arguments: network);
      }
      return;
    }

    bool hasBouncer = false;
    for (var net in networkList.networks) {
      if (net.networkEntry.caps.containsKey('soju.im/bouncer-networks')) {
        hasBouncer = true;
        break;
      }
    }
    if (!hasBouncer) {
      throw Exception(
          'Adding new networks without a bouncer is not yet supported');
    }

    navigatorState.pushNamed(EditBouncerNetworkPage.routeName, arguments: uri);
  }

  void _handleSharedMedia(SharedMedia sharedMedia) {
    var navigatorState = _navigatorKey.currentState!;
    navigatorState.pushNamed(SharePage.routeName, arguments: sharedMedia);
  }

  void _confirmOpenBuffer(NetworkModel network, String target) async {
    var client = context.read<ClientProvider>().get(network);

    Widget content;
    if (client.isNick(target)) {
      content = Text.rich(TextSpan(children: [
        TextSpan(text: 'Do you want to start a conversation with the user '),
        TextSpan(text: target, style: TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: '?'),
      ]));
    } else if (client.isChannel(target)) {
      content = Text.rich(TextSpan(children: [
        TextSpan(text: 'Do you want to join the channel '),
        TextSpan(text: target, style: TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: '?'),
      ]));
    } else {
      throw Exception(
          'Cannot open buffer "$target": neither a nick nor a channel');
    }

    unawaited(showDialog<void>(
        context: _navigatorKey.currentState!.overlay!.context,
        builder: (context) {
          return AlertDialog(
            title: const Text('New conversation'),
            content: content,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  BufferPage.open(context, target, network);
                },
                child: const Text('Start conversation'),
              ),
            ],
          );
        }));
  }

  Route<dynamic>? _handleGenerateRoute(RouteSettings settings) {
    WidgetBuilder builder;
    switch (settings.name) {
      case ConnectPage.routeName:
        var args = settings.arguments;
        if (args is ConnectPageArguments) {
          builder = (context) => ConnectPage(
                initialUri: args.initialUri,
                additionalServer: args.additionalServer,
              );
        } else {
          builder = (context) => ConnectPage(initialUri: args as IrcUri?);
        }
        break;
      case BufferListPage.routeName:
        builder = (context) => BufferListPage();
        break;
      case JoinPage.routeName:
        builder = (context) => JoinPage();
        break;
      case SettingsPage.routeName:
        builder = (context) => SettingsPage();
        break;
      case BufferPage.routeName:
        var args = settings.arguments as BufferPageArguments;
        var buffer = args.buffer;
        builder = (context) {
          var client = context.read<ClientProvider>().get(buffer.network);
          return MultiProvider(
            providers: [
              ChangeNotifierProvider<BufferModel>.value(value: buffer),
              ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
              Provider<Client>.value(value: client),
            ],
            child: BufferPage(
              unreadMarkerTime: buffer.entry.lastReadTime,
              sharedMedia: args.sharedMedia,
            ),
          );
        };
        break;
      case BufferDetailsPage.routeName:
        var buffer = settings.arguments as BufferModel;
        builder = (context) {
          var client = context.read<ClientProvider>().get(buffer.network);
          return MultiProvider(
            providers: [
              ChangeNotifierProvider<BufferModel>.value(value: buffer),
              ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
              Provider<Client>.value(value: client),
            ],
            child: BufferDetailsPage(),
          );
        };
        break;
      case CallPage.routeName:
        var args = settings.arguments as CallPageArguments;
        builder = (context) => CallPage(args: args);
        break;
      case EditBouncerNetworkPage.routeName:
        BouncerNetworkModel? network;
        IrcUri? initialUri;
        if (settings.arguments is BouncerNetworkModel) {
          network = settings.arguments as BouncerNetworkModel;
        } else if (settings.arguments is IrcUri) {
          initialUri = settings.arguments as IrcUri;
        } else if (settings.arguments != null) {
          throw ArgumentError.value(settings.arguments, null,
              'EditBouncerNetworkPage only accepts a BouncerNetworkModel or Uri argument');
        }
        builder = (context) =>
            EditBouncerNetworkPage(network: network, initialUri: initialUri);
        break;
      case NetworkDetailsPage.routeName:
        var network = settings.arguments as NetworkModel;
        builder = (context) {
          var client = context.read<ClientProvider>().get(network);
          return MultiProvider(
            providers: [
              ChangeNotifierProvider<NetworkModel>.value(value: network),
              Provider<Client>.value(value: client),
            ],
            child: NetworkDetailsPage(),
          );
        };
        break;
      case GalleryPage.routeName:
        var args = settings.arguments as GalleryPageArguments;
        builder =
            (context) => GalleryPage(uri: args.uri, heroTag: args.heroTag);
        break;
      case SharePage.routeName:
        var sharedMedia = settings.arguments as SharedMedia;
        builder = (context) => SharePage(sharedMedia: sharedMedia);
        break;
      default:
        throw Exception('Unknown route ${settings.name}');
    }
    return MaterialPageRoute(builder: builder, settings: settings);
  }

  List<Route<dynamic>> _handleGenerateInitialRoutes(String initialRoute) {
    Object? routeArguments;
    if (initialRoute == ConnectPage.routeName) {
      routeArguments = widget.initialUri;
    } else if (initialRoute == SharePage.routeName) {
      routeArguments = widget.initialSharedMedia!;
    } else {
      return Navigator.defaultGenerateInitialRoutes(
          _navigatorKey.currentState!, initialRoute);
    }

    // Prevent the default implementation from generating routes for
    // both '/' and '/connect' (or '/share')
    return [
      _handleGenerateRoute(RouteSettings(
        name: initialRoute,
        arguments: routeArguments,
      ))!
    ];
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IRC mobile',
      theme: _nativeTheme(_nativeDarkScheme),
      darkTheme: _nativeTheme(_nativeDarkScheme),
      themeMode: _themeMode,
      initialRoute: _initialRoute,
      onGenerateRoute: _handleGenerateRoute,
      onGenerateInitialRoutes: _handleGenerateInitialRoutes,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
    );
  }
}

class _IncomingCallScreen extends StatelessWidget {
  final String caller;
  final bool video;

  const _IncomingCallScreen({
    required this.caller,
    required this.video,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var title = video ? 'Incoming video call' : 'Incoming voice call';
    var displayCaller = caller.isEmpty ? 'Incoming call' : caller;
    return Material(
      color: scheme.surfaceContainerLowest,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 42, 24, 28),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width - 48,
                  ),
                  child: Container(
                    width: 360,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.28),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.22),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            video ? Icons.videocam : Icons.call,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                displayCaller,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _IncomingCallSwipeAction(
                    icon: Icons.call_end,
                    label: 'No',
                    color: const Color(0xFFDC2626),
                    onTriggered: () => Navigator.pop(context, false),
                  ),
                  _IncomingCallSwipeAction(
                    icon: video ? Icons.videocam : Icons.call,
                    label: 'Yes',
                    color: const Color(0xFF16A34A),
                    onTriggered: () => Navigator.pop(context, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IncomingCallSwipeAction extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTriggered;

  const _IncomingCallSwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTriggered,
  });

  @override
  State<_IncomingCallSwipeAction> createState() =>
      _IncomingCallSwipeActionState();
}

class _IncomingCallSwipeActionState extends State<_IncomingCallSwipeAction> {
  static const _triggerDistance = 54.0;
  double _dragOffset = 0;

  void _handleDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy)
          .clamp(-_triggerDistance, 0)
          .toDouble();
    });
  }

  void _handleDragEnd() {
    if (_dragOffset <= -_triggerDistance * 0.72) {
      widget.onTriggered();
      return;
    }
    setState(() => _dragOffset = 0);
  }

  @override
  Widget build(BuildContext context) {
    var progress = (-_dragOffset / _triggerDistance).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 86,
          height: 116,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Positioned(
                top: 0,
                child: Icon(
                  Icons.keyboard_arrow_up,
                  color: widget.color.withValues(alpha: 0.45 + progress * 0.35),
                  size: 30,
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: _handleDragUpdate,
                onVerticalDragEnd: (_) => _handleDragEnd(),
                onVerticalDragCancel: _handleDragEnd,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  transform: Matrix4.translationValues(0, _dragOffset, 0),
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: widget.color.withValues(alpha: 0.32),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(widget.icon, size: 32, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          widget.label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}
