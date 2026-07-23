// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_handler/share_handler.dart';

import '../ansi.dart';
import '../cached_network_image.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../ignore_store.dart';
import '../irc/irc.dart';
import '../logging.dart';
import '../models.dart';
import '../native_foreground.dart';
import '../notification_controller.dart';
import '../prefs.dart';
import '../profile_backend.dart';
import '../widget/app_snack_bar.dart';
import '../widget/composer.dart';
import '../widget/date_indicator.dart';
import '../widget/message_item.dart';
import '../widget/network_indicator.dart';
import '../widget/profile_avatar.dart';
import 'buffer_details.dart';
import 'buffer_list.dart';
import 'call.dart';
import 'connect.dart';

const _maxVisibleMessages = 1000;
const _channelEventLifetime = Duration(hours: 24);
const _expiringChannelEventCommands = {
  'JOIN',
  'PART',
  'QUIT',
  'KICK',
  'NICK',
  'MODE',
};

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

PopupMenuEntry<String> _darkPopupDivider(BuildContext context) {
  return PopupMenuItem<String>(
    enabled: false,
    height: 1,
    padding: EdgeInsets.zero,
    child: Container(
      width: double.infinity,
      height: 1,
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.45),
    ),
  );
}

class BufferPageArguments {
  final BufferModel buffer;
  final SharedMedia? sharedMedia;

  const BufferPageArguments({
    required this.buffer,
    this.sharedMedia,
  });
}

class BufferPage extends StatefulWidget {
  static const routeName = '/buffer';
  static final Set<String> _pendingOpenKeys = {};
  static final Map<int, int> _openBufferCounts = {};

  final String? unreadMarkerTime;
  final SharedMedia? sharedMedia;

  const BufferPage({super.key, this.unreadMarkerTime, this.sharedMedia});

  @override
  State<BufferPage> createState() => _BufferPageState();

  static String _openKey(BufferModel buffer) {
    return '${buffer.network.networkId}:${buffer.id}:${buffer.name.toLowerCase()}';
  }

  static void _registerOpenBuffer(BufferModel buffer) {
    _pendingOpenKeys.remove(_openKey(buffer));
    _openBufferCounts.update(buffer.id, (count) => count + 1,
        ifAbsent: () => 1);
  }

  static void _unregisterOpenBuffer(BufferModel buffer) {
    var count = _openBufferCounts[buffer.id];
    if (count == null) {
      return;
    }
    if (count <= 1) {
      _openBufferCounts.remove(buffer.id);
    } else {
      _openBufferCounts[buffer.id] = count - 1;
    }
  }

  static void open(BuildContext context, String name, NetworkModel network,
      {bool replaceCurrent = false, bool preserveStack = false}) async {
    var db = context.read<DB>();
    var bufferList = context.read<BufferListModel>();
    var clientProvider = context.read<ClientProvider>();
    var client = clientProvider.get(network);
    var navigator = Navigator.of(context);
    var route = ModalRoute.of(context);

    var requestedName = name;
    name = normalizeServerBufferName(name);
    var buffer = bufferList.get(name, network);
    if (buffer == null &&
        name == statusBufferName &&
        requestedName != statusBufferName) {
      buffer = bufferList.get(requestedName, network);
    }
    if (buffer == null) {
      var entry = await db
          .storeBuffer(BufferEntry(name: name, network: network.networkId));
      buffer = BufferModel(entry: entry, network: network);
      bufferList.add(buffer);
    }
    if (client.registered && client.isNick(name) && buffer.avatar == null) {
      try {
        var avatars = await const ProfileBackendClient()
            .fetchAvatarUrls(client.params.host, [name]);
        var avatar = avatars[name.toLowerCase()];
        if (avatar != null) {
          if (context.mounted) {
            await precacheImage(CachedNetworkImage(avatar), context);
          }
          buffer.setBackendAvatar(avatar);
        }
      } on Exception catch (err) {
        log.print('Failed to preload private avatar', error: err);
      }
      if (!context.mounted) {
        return;
      }
    }
    if (client.registered && client.isNick(name) && buffer.realname == null) {
      try {
        await clientProvider.fetchBufferUser(buffer);
      } on Exception catch (err) {
        log.print('Failed to preload private realname', error: err);
      }
      if (!context.mounted) {
        return;
      }
    }

    var args = BufferPageArguments(buffer: buffer);
    if (!replaceCurrent &&
        !preserveStack &&
        route?.settings.name == routeName &&
        route?.settings.arguments is BufferPageArguments &&
        (route!.settings.arguments as BufferPageArguments).buffer == buffer) {
      return;
    }
    if (!replaceCurrent &&
        !preserveStack &&
        (_openBufferCounts[buffer.id] ?? 0) > 0) {
      return;
    }
    var pendingOpenKey = _openKey(buffer);
    if (!replaceCurrent &&
        !preserveStack &&
        !_pendingOpenKeys.add(pendingOpenKey)) {
      return;
    }
    Timer(const Duration(seconds: 5), () {
      _pendingOpenKeys.remove(pendingOpenKey);
    });

    // TODO: this is racy if the user has navigated away since the
    // BufferPage.open() call
    if (replaceCurrent) {
      unawaited(navigator.pushReplacementNamed(routeName, arguments: args));
    } else if (preserveStack) {
      unawaited(navigator.pushNamed(routeName, arguments: args));
    } else {
      var until = ModalRoute.withName(BufferListPage.routeName);
      unawaited(
          navigator.pushNamedAndRemoveUntil(routeName, until, arguments: args));
    }

    if (client.isChannel(name)) {
      _join(client, buffer);
    }
  }
}

void _join(Client client, BufferModel buffer) async {
  if (buffer.joined) {
    return;
  }

  buffer.joining = true;
  try {
    await client.join([buffer.name]);
  } on IrcException catch (err) {
    log.print('Failed to join "${buffer.name}"', error: err);
  } finally {
    buffer.joining = false;
  }
}

class _BufferPageState extends State<BufferPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static final Set<int> _memberAvatarPreloadBuffers = {};

  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _userScrollListener =
      ScrollOffsetListener.create(recordProgrammaticScrolls: false);
  final _dateIndicatorValue = ValueNotifier<DateTime?>(null);
  final _showJumpToBottomValue = ValueNotifier<bool>(false);
  final _listKey = GlobalKey();
  final GlobalKey<ComposerState> _composerKey = GlobalKey();
  final GlobalKey<DateIndicatorState> _dateIndicatorKey = GlobalKey();
  late final AnimationController _blinkMsgController;
  late final StreamSubscription<double> _userScrollSubscription;
  late final StreamSubscription<ProfileAvatarChange> _profileAvatarSubscription;
  late final BufferModel _routeBuffer;

  bool _activated = true;
  bool _chatHistoryLoading = false;
  bool _isAtTop = false;
  bool _isAtBottom = true;
  bool _bottomScrollScheduled = false;

  bool _initialChatHistoryLoaded = false;
  int? _blinkMsgIndex;
  int? _latestVisibleMessageId;
  int _visibleMessageCount = 0;
  String? _profileAvatar;
  Timer? _channelEventExpiryTimer;
  DateTime? _scheduledChannelEventExpiry;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _routeBuffer = context.read<BufferModel>();
    BufferPage._registerOpenBuffer(_routeBuffer);

    _itemPositionsListener.itemPositions.addListener(_handleScroll);
    _userScrollSubscription =
        _userScrollListener.changes.listen(_handleUserScroll);

    _blinkMsgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1,
    );

    var buffer = _routeBuffer;
    _fetchMetadata();
    _fetchProfileAvatar();
    _profileAvatarSubscription =
        ProfileBackendClient.avatarChanges.listen(_handleProfileAvatarChange);
    if (buffer.messages.length >= _maxVisibleMessages) {
      _setInitialChatHistoryLoaded();
      _updateBufferFocus();
      return;
    }

    // Timer.run prevents calling setState() from inside initState()
    Timer.run(() async {
      try {
        await _fetchChatHistory();
      } on Exception catch (err) {
        log.print('Failed to fetch chat history', error: err);
      }
      if (mounted) {
        _updateBufferFocus();
      }
    });
  }

  void _handleScroll() {
    var positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return;
    }

    var buffer = context.read<BufferModel>();
    var messages = _visibleMessages(buffer);
    if (messages.isEmpty) {
      return;
    }

    var isAtTop = positions.any((pos) => pos.index == messages.length - 1);
    if (!_isAtTop && isAtTop) {
      _fetchChatHistory();
    }
    _isAtTop = isAtTop;

    var isAtBottom = positions.any((pos) => pos.index == 0);
    if (_isAtBottom != isAtBottom) {
      _isAtBottom = isAtBottom;
      _updateBufferFocus();
    }

    var topPosition = positions.reduce((a, b) {
      return a.itemLeadingEdge < b.itemLeadingEdge ? a : b;
    });
    var visibleIndex = topPosition.index;
    if (visibleIndex < messages.length) {
      var firstDateTime =
          messages[messages.length - visibleIndex - 1].entry.dateTime;
      _dateIndicatorValue.value = firstDateTime;
    }

    var showJumpToBottom =
        positions.any((pos) => pos.index >= 20) && !isAtBottom;
    _showJumpToBottomValue.value = showJumpToBottom;
  }

  bool _canJumpToBottom() {
    if (!_initialChatHistoryLoaded || !_itemScrollController.isAttached) {
      return false;
    }
    return _visibleMessageCount > 0;
  }

  void _jumpToBottom() {
    if (!_canJumpToBottom()) {
      return;
    }
    _itemScrollController.jumpTo(index: 0, alignment: 0);
  }

  void _scheduleJumpToBottom() {
    if (_bottomScrollScheduled) {
      return;
    }
    _bottomScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomScrollScheduled = false;
      if (!mounted) {
        return;
      }
      _jumpToBottom();
    });
  }

  void _handleUserScroll(double value) {
    _dateIndicatorKey.currentState?.show();
  }

  List<MessageModel> _displayMessages(BufferModel buffer) {
    if (isServerBufferName(buffer.name)) {
      return buffer.messages;
    }
    var isChannel = buffer.network.networkEntry.isupport.isChannel(buffer.name);
    return buffer.messages.where((msg) {
      if (isServiceMessage(msg.msg)) {
        return false;
      }
      return !isChannel ||
          !_expiringChannelEventCommands.contains(msg.msg.cmd);
    }).toList();
  }

  List<MessageModel> _channelEvents(BufferModel buffer) {
    var now = DateTime.now();
    return buffer.messages.where((message) {
      return _expiringChannelEventCommands.contains(message.msg.cmd) &&
          message.entry.dateTime.add(_channelEventLifetime).isAfter(now);
    }).toList();
  }

  Future<void> _showChannelEvents(BufferModel buffer) async {
    var client = context.read<Client>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        var colors = Theme.of(context).colorScheme;
        return FractionallySizedBox(
          heightFactor: 0.94,
          child: AnimatedBuilder(
              animation: buffer,
              builder: (context, _) {
                var events = _channelEvents(buffer).reversed.toList();
                return Material(
                  color: colors.surfaceContainerLowest,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'EVENTS',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    'Channel activity from the last 24 hours',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: colors.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: colors.outlineVariant),
                      Expanded(
                        child: events.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'No channel events in the last 24 hours.',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge,
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.separated(
                                reverse: true,
                                padding: const EdgeInsets.only(bottom: 16),
                                itemCount: events.length,
                                separatorBuilder: (_, __) => Divider(
                                    height: 1, color: colors.outlineVariant),
                                itemBuilder: (context, index) {
                                  var event = events[index];
                                  var text =
                                      formatChannelEvent(event.msg, client) ??
                                          event.msg.cmd;
                                  var localTime =
                                      event.entry.dateTime.toLocal();
                                  var time = MaterialLocalizations.of(context)
                                      .formatTimeOfDay(TimeOfDay.fromDateTime(
                                          localTime));
                                  return ColoredBox(
                                    color: colors.surfaceContainerLowest,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 11,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colors.surfaceContainer,
                                            ),
                                            child: Text(
                                              event.msg.cmd,
                                              style: TextStyle(
                                                color: colors.onSurfaceVariant,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 9),
                                          Expanded(
                                            child: Text(
                                              text,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            time,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                    color: colors
                                                        .onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
        );
      },
    );
  }

  Future<void> _removeExpiredChannelEvents(BufferModel buffer) async {
    var now = DateTime.now();
    var expiredIds = buffer.messages
        .where((message) =>
            _expiringChannelEventCommands.contains(message.msg.cmd) &&
            !message.entry.dateTime
                .add(_channelEventLifetime)
                .isAfter(now))
        .take(500)
        .map((message) => message.id)
        .toList();
    if (expiredIds.isEmpty) {
      return;
    }

    try {
      await context.read<DB>().deleteMessages(expiredIds);
      buffer.removeMessages(expiredIds);
    } on Object catch (err) {
      log.print('Failed to remove expired channel events', error: err);
    }
  }

  void _scheduleChannelEventExpiry(BufferModel buffer) {
    DateTime? nextExpiry;
    var now = DateTime.now();
    for (var message in buffer.messages) {
      if (!_expiringChannelEventCommands.contains(message.msg.cmd)) {
        continue;
      }
      var expiry = message.entry.dateTime.add(_channelEventLifetime);
      if (nextExpiry == null || expiry.isBefore(nextExpiry)) {
        nextExpiry = expiry;
      }
    }
    if (nextExpiry == _scheduledChannelEventExpiry) {
      return;
    }
    _channelEventExpiryTimer?.cancel();
    _scheduledChannelEventExpiry = nextExpiry;
    if (nextExpiry == null) {
      return;
    }
    var delay = nextExpiry.difference(now);
    if (delay.isNegative) {
      delay = Duration.zero;
    }
    _channelEventExpiryTimer = Timer(delay, () async {
      if (!mounted) {
        return;
      }
      _scheduledChannelEventExpiry = null;
      await _removeExpiredChannelEvents(buffer);
      if (mounted) {
        _scheduleChannelEventExpiry(buffer);
      }
    });
  }

  List<MessageModel> _visibleMessages(BufferModel buffer) {
    var messages = _displayMessages(buffer);
    return messages.length > _maxVisibleMessages
        ? messages.sublist(messages.length - _maxVisibleMessages)
        : messages;
  }

  void _fetchMetadata() async {
    var clientProvider = context.read<ClientProvider>();
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();
    var userList = context.read<NetworkModel>().users;

    if (!client.registered) {
      return;
    }

    if (client.isChannel(buffer.name)) {
      if (buffer.members != null) {
        unawaited(_preloadMemberAvatars(
            buffer, client, buffer.members!.members.keys.take(80)));
        return;
      }

      List<WhoReply> replies;
      try {
        replies = await client.who(buffer.name);
      } on Exception catch (err) {
        log.print('Failed to fetch channel WHO', error: err);
        await client.names(buffer.name);
        return;
      }

      var members = MemberListModel(client.isupport.caseMapping);
      for (var reply in replies) {
        members.set(reply.nickname, reply.membershipPrefix!);
        userList.updateUser(UserModel(
          nickname: reply.nickname,
          realname: reply.realname,
        ));
      }

      buffer.members = members;
      unawaited(_preloadMemberAvatars(
          buffer, client, replies.map((reply) => reply.nickname).take(80)));
    } else {
      unawaited(clientProvider.fetchBufferUser(buffer));
      client.monitor([buffer.name]);
    }
  }

  Future<void> _preloadMemberAvatars(
      BufferModel buffer, Client client, Iterable<String> nicks) async {
    if (!_memberAvatarPreloadBuffers.add(buffer.id)) {
      return;
    }
    var requestedNicks = nicks.toList(growable: false);
    var avatars = await const ProfileBackendClient()
        .fetchAvatarUrls(client.params.host, requestedNicks);
    if (!mounted) {
      return;
    }
    buffer.members?.syncAvatars(requestedNicks, avatars);
    if (avatars.isEmpty) {
      return;
    }
    var imageSize = (40 * MediaQuery.devicePixelRatioOf(context)).round();
    await Future.wait(avatars.values.take(80).map((url) {
      var image = ResizeImage.resizeIfNeeded(
          imageSize, imageSize, CachedNetworkImage(url));
      return precacheImage(image, context).catchError((_) {});
    }));
  }

  void _fetchProfileAvatar() async {
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();

    if (!client.registered || !client.isNick(buffer.name)) {
      return;
    }

    var backend = const ProfileBackendClient();
    var cachedAvatar = backend.cachedAvatarUrls(
        client.params.host, [buffer.name])[buffer.name.toLowerCase()];
    if (cachedAvatar != null) {
      _profileAvatar = cachedAvatar;
      buffer.setBackendAvatar(cachedAvatar);
    }

    var avatars =
        await backend.fetchAvatarUrls(client.params.host, [buffer.name]);
    var avatar = avatars[buffer.name.toLowerCase()];
    if (avatar != null && mounted) {
      await precacheImage(CachedNetworkImage(avatar), context);
    }
    if (!mounted) {
      return;
    }
    buffer.setBackendAvatar(avatar);
    setState(() {
      _profileAvatar = avatar;
    });
  }

  Future<void> _fetchChatHistory() async {
    if (_chatHistoryLoading) {
      return;
    }

    var db = context.read<DB>();
    var clientProvider = context.read<ClientProvider>();
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();

    // First try to load history from the DB, then try from the server

    int? firstMsgId;
    if (!buffer.messages.isEmpty) {
      firstMsgId = buffer.messages.first.id;
    }

    var limit = _maxVisibleMessages;
    var entries = await db.listMessagesBefore(buffer.id, firstMsgId, limit);
    var models = await buildMessageModelList(db, entries);
    buffer.populateMessageHistory(models.toList());

    if (mounted) {
      setState(_setInitialChatHistoryLoaded);
    }

    if (entries.length >= limit ||
        !client.caps.enabled.contains('draft/chathistory')) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _chatHistoryLoading = true;
    });

    try {
      await clientProvider.fetchChatHistory(buffer);
    } finally {
      if (mounted) {
        setState(() {
          _chatHistoryLoading = false;
        });
      }
    }
  }

  void _setInitialChatHistoryLoaded() {
    if (_initialChatHistoryLoaded) {
      return;
    }
    _initialChatHistoryLoaded = true;
    _isAtBottom = true;
    _scheduleJumpToBottom();
  }

  @override
  void dispose() {
    BufferPage._unregisterOpenBuffer(_routeBuffer);
    _itemPositionsListener.itemPositions.removeListener(_handleScroll);
    _userScrollSubscription.cancel();
    _profileAvatarSubscription.cancel();
    _channelEventExpiryTimer?.cancel();
    _blinkMsgController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleProfileAvatarChange(ProfileAvatarChange change) {
    if (!mounted) {
      return;
    }
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    if (!client.isNick(buffer.name) ||
        !_profileEventMatchesNetwork(change.server, network, client) ||
        !client.isupport.caseMapping.equals(change.nick, buffer.name)) {
      return;
    }
    buffer.setBackendAvatar(change.avatarUrl);
    setState(() {
      _profileAvatar = change.avatarUrl;
    });
  }

  @override
  void deactivate() {
    _activated = false;
    _updateBufferFocus();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _activated = true;
    // Timer.run prevents calling setState() from inside activate()
    Timer.run(() {
      _updateBufferFocus();
    });
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    _updateBufferFocus();
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await _saveDraft();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _saveDraft();
    return AppExitResponse.exit;
  }

  void _updateBufferFocus() {
    var buffer = context.read<BufferModel>();
    var state =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    buffer.focused =
        state == AppLifecycleState.resumed && _activated && _isAtBottom;
    if (buffer.focused) {
      _markRead();
    }
  }

  void _returnToBufferList() {
    var navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    navigator.pushNamedAndRemoveUntil(
        BufferListPage.routeName, (route) => false);
  }

  Future<void> _saveDraft() async {
    var composer = _composerKey.currentState;
    if (composer == null) {
      return;
    }
    var buffer = context.read<BufferModel>();
    buffer.draft = composer.draft;
    await context.read<DB>().storeBuffer(buffer.entry);
  }

  void _setReplyTo(MessageModel message) {
    var composer = _composerKey.currentState;
    if (composer != null) {
      composer.setReplyTo(message);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _composerKey.currentState?.setReplyTo(message);
      }
    });
  }

  Future<void> _clearMessages() async {
    var db = context.read<DB>();
    var buffer = context.read<BufferModel>();
    buffer.draft = null;
    buffer.entry.lastReadTime = null;
    await db.storeBuffer(buffer.entry);
    await db.clearMessages(buffer.id);
    buffer.clearMessages();
  }

  void _markRead() {
    var db = context.read<DB>();
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var notifController = context.read<NotificationController>();

    if (buffer.messages.length > 0) {
      var latestTime = buffer.messages.last.entry.time;
      if (buffer.entry.lastReadTime == null ||
          buffer.entry.lastReadTime!.compareTo(latestTime) < 0) {
        buffer.entry.lastReadTime = latestTime;
        unawaited(db.storeBuffer(buffer.entry));

        if (client.state != ClientState.disconnected) {
          client.setReadMarker(buffer.name, latestTime);
        }
      }
    }
    buffer.unreadCount = 0;

    notifController.cancelAllWithBuffer(buffer, null);
  }

  Future<void> _toggleBufferMuted(BufferModel buffer) async {
    var client = context.read<Client>();
    var bufferList = context.read<BufferListModel>();
    var db = context.read<DB>();
    var notifController = context.read<NotificationController>();
    var muted = !buffer.muted;

    try {
      if (client.metadataSubs.contains('soju.im/muted')) {
        await client.setMetadata(
            buffer.name, 'soju.im/muted', muted ? '1' : '0');
      }
      if (buffer.muted != muted) {
        bufferList.setMuted(buffer, muted);
      }
      await db.storeBuffer(buffer.entry);
      if (muted) {
        await notifController.cancelAllWithBuffer(buffer, null);
      }
    } on Object catch (err) {
      if (mounted) {
        showTopRightSnackBar(
          context,
          SnackBar(content: Text('Unable to update mute setting: $err')),
        );
      }
    }
  }

  void _handleMsgRefTap(int id) {
    var buffer = context.read<BufferModel>();
    var messages = _visibleMessages(buffer);
    int? index;
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].id == id) {
        index = messages.length - i - 1;
        break;
      }
    }
    if (index == null) {
      return;
    }

    setState(() {
      _blinkMsgIndex = index;
    });
    if (index != 0 && _isAtBottom) {
      _isAtBottom = false;
      _updateBufferFocus();
    }

    _itemScrollController.jumpTo(
      index: index,
      alignment: 0.5,
    );
    _blinkMsgController.repeat(reverse: true);
    Timer(_blinkMsgController.duration! * 4, () {
      if (!mounted) {
        return;
      }
      _blinkMsgController.animateTo(1);
      setState(() {
        _blinkMsgIndex = null;
      });
    });
  }

  void _showCommandSent(String label) {
    showTopRightSnackBar(
      context,
      SnackBar(content: Text('$label sent')),
    );
  }

  void _showTopRightNotice(String text) {
    showTopRightSnackBar(
        context,
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 2),
        ));
  }

  void _sendCommand(Client client, String command, List<String> params) {
    client.send(IrcMessage(command, params));
    _showCommandSent(command);
  }

  Future<void> _startPrivateCall({required bool video}) async {
    if (!callsEnabled) {
      return;
    }
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    if (!client.isNick(buffer.name)) {
      return;
    }
    if (!canSendMessageToBuffer(buffer, network)) {
      showTopRightSnackBar(
        context,
        SnackBar(content: Text('Network is offline')),
      );
      return;
    }

    var label = video ? 'video call start' : 'voice call start';
    var notice = video ? 'Video invite sent' : 'Voice invite sent';
    try {
      var created = await const ProfileBackendClient().createCallRoom(
        server: client.params.host,
        target: buffer.name,
        nick: network.nickname,
        mode: video ? 'video' : 'audio',
      );
      var roomUrl = created.roomUrl;
      await client.sendTextMessage(
          IrcMessage('PRIVMSG', [buffer.name, '$label: $roomUrl']));
      if (!mounted) {
        return;
      }
      _showTopRightNotice(notice);
      await Navigator.of(context).pushNamed(
        CallPage.routeName,
        arguments: CallPageArguments(
          roomUrl: roomUrl,
          target: buffer.name,
          video: video,
          autoJoin: true,
          outgoing: true,
          nick: network.nickname,
          controlToken: created.controlToken,
          client: client,
          returnRouteName: BufferPage.routeName,
          returnRouteArguments: BufferPageArguments(buffer: buffer),
        ),
      );
    } on Exception catch (err) {
      if (!mounted) {
        return;
      }
      showTopRightSnackBar(
        context,
        SnackBar(content: Text(err.toString())),
      );
    }
  }

  Future<void> _startChannelCall({required bool video}) async {
    if (!callsEnabled) {
      return;
    }
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    if (!client.isChannel(buffer.name) ||
        !canSendMessageToBuffer(buffer, network)) {
      return;
    }
    var membership = buffer.members?.members[client.nick] ?? '';
    const operatorPrefixes = '!~&@%';
    var channelOperator = membership.split('').any(operatorPrefixes.contains);
    if (!channelOperator && !network.isIrcOperator) {
      return;
    }

    var role = network.isIrcOperator ? 'irc_operator' : 'channel_operator';
    var notice = video ? 'Channel video started' : 'Channel voice started';
    try {
      var created = await const ProfileBackendClient().createCallRoom(
        server: client.params.host,
        target: buffer.name,
        nick: network.nickname,
        mode: video ? 'video' : 'audio',
        role: role,
      );
      var roomUrl = created.roomUrl;
      if (!mounted) return;
      _showTopRightNotice(notice);
      await Navigator.of(context).pushNamed(
        CallPage.routeName,
        arguments: CallPageArguments(
          roomUrl: roomUrl,
          target: buffer.name,
          video: video,
          channel: true,
          outgoing: true,
          nick: network.nickname,
          role: role,
          controlToken: created.controlToken,
          channelMembers:
              buffer.members?.members.keys.toList(growable: false) ?? const [],
          channelMemberPrefixes: buffer.members?.members ?? const {},
          client: client,
          returnRouteName: BufferPage.routeName,
          returnRouteArguments: BufferPageArguments(buffer: buffer),
        ),
      );
    } on Exception catch (err) {
      if (!mounted) return;
      showTopRightSnackBar(context, SnackBar(content: Text(err.toString())));
    }
  }

  Future<void> _showActiveChannelCalls() async {
    if (!callsEnabled) {
      return;
    }
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    try {
      var calls = await const ProfileBackendClient().fetchActiveChannelCalls(
        server: client.params.host,
        channel: buffer.name,
      );
      if (!mounted) return;
      if (calls.isEmpty) {
        showTopRightSnackBar(
          context,
          const SnackBar(content: Text('No active channel calls')),
        );
        return;
      }
      var selected = await showDialog<ActiveChannelCall>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ACTIVE CHANNEL CALLS'),
          content: SizedBox(
            width: 340,
            height: min(360, calls.length * 72).toDouble(),
            child: ListView.builder(
              itemCount: calls.length,
              itemBuilder: (context, index) {
                var call = calls[index];
                return ListTile(
                  leading: Icon(call.room.video ? Icons.videocam : Icons.call),
                  title: Text(call.room.video ? 'VIDEO CALL' : 'VOICE CALL'),
                  subtitle: Text(
                      '${call.room.createdBy} • ${call.room.participants.length} users'),
                  onTap: () => Navigator.pop(context, call),
                );
              },
            ),
          ),
        ),
      );
      if (selected == null || !mounted) return;
      await Navigator.of(context).pushNamed(
        CallPage.routeName,
        arguments: CallPageArguments(
          roomUrl: selected.roomUrl,
          target: buffer.name,
          video: selected.room.video,
          channel: true,
          outgoing: true,
          nick: network.nickname,
          role: 'irc_operator',
          channelMembers:
              buffer.members?.members.keys.toList(growable: false) ?? const [],
          channelMemberPrefixes: buffer.members?.members ?? const {},
          client: client,
          returnRouteName: BufferPage.routeName,
          returnRouteArguments: BufferPageArguments(buffer: buffer),
        ),
      );
    } on Exception catch (err) {
      if (!mounted) return;
      showTopRightSnackBar(context, SnackBar(content: Text(err.toString())));
    }
  }

  bool _activeCallMatchesBuffer(ActiveCallInfo active, BufferModel buffer) {
    var target = active.target.trim();
    if (target.isEmpty) {
      return false;
    }
    return target.toLowerCase() == buffer.name.trim().toLowerCase();
  }

  void _openActiveCall() {
    if (!callsEnabled) {
      return;
    }
    var active = activeCallInfo.value;
    if (active == null) {
      showTopRightSnackBar(
        context,
        const SnackBar(content: Text('No active call')),
      );
      return;
    }
    var navigator = Navigator.of(context);
    var found = false;
    navigator.popUntil((route) {
      var args = route.settings.arguments;
      var matches = route.settings.name == CallPage.routeName &&
          args is CallPageArguments &&
          args.roomUrl == active.roomUrl;
      if (matches) {
        found = true;
      }
      return matches || route.isFirst;
    });
    if (!found) {
      navigator.pushNamed(CallPage.routeName, arguments: active.args);
    }
  }

  String _activeCallLabel(ActiveCallInfo active) {
    return active.video ? 'ACTIVE VIDEO CALL' : 'ACTIVE VOICE CALL';
  }

  Future<void> _setIgnored(
      NetworkModel network, String nick, bool ignored) async {
    setState(() {
      if (ignored) {
        network.ignoreNick(nick);
      } else {
        network.unignoreNick(nick);
      }
    });
    await saveIgnoredNicks(network.ignoredNicks);
  }

  Future<void> _showIgnoreList(NetworkModel network) async {
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        var scheme = Theme.of(context).colorScheme;
        return MediaQuery.removeViewInsets(
          removeBottom: true,
          context: context,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
              child: Material(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(8),
                child: AnimatedBuilder(
                  animation: network,
                  builder: (context, _) {
                    var ignored = network.ignoredNicks;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                            child: Text(
                              'IGNORE LIST',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              children: [
                                if (ignored.isEmpty)
                                  ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    leading: Icon(Icons.volume_up),
                                    title: Text('No ignored users'),
                                  ),
                                for (var nick in ignored)
                                  ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    leading: Icon(Icons.volume_off),
                                    title: Text(nick),
                                    subtitle: Text('Tap to unignore'),
                                    onTap: () =>
                                        _setIgnored(network, nick, false),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCenteredPanel({
    required BuildContext context,
    required Widget child,
  }) {
    return MediaQuery.removeViewInsets(
      removeBottom: true,
      context: context,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(8),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildPanelTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }

  ListTile _buildToolTile(ColorScheme scheme, _ToolAction action) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      enabled: action.enabled,
      leading: Icon(action.icon,
          color: action.enabled
              ? scheme.onSurfaceVariant
              : scheme.onSurfaceVariant.withValues(alpha: 0.45)),
      title: Text(action.title),
      subtitle: action.subtitle == null ? null : Text(action.subtitle!),
      onTap: action.enabled
          ? () {
              Navigator.pop(context);
              action.onTap();
            }
          : null,
    );
  }

  String _normalizeChannelName(Client client, String value) {
    var clean = value.trim();
    if (clean.isEmpty || client.isChannel(clean)) {
      return clean;
    }
    return '#$clean';
  }

  Future<void> _showCommandDialog({
    required String title,
    required List<_CommandField> fields,
    required void Function(List<String> values) onSubmit,
  }) async {
    var controllers = [
      for (var field in fields) TextEditingController(text: field.initialValue),
    ];
    try {
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        builder: (context) {
          return _buildCenteredPanel(
            context: context,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < fields.length; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                      child: TextField(
                        controller: controllers[i],
                        decoration: InputDecoration(
                          labelText: fields[i].label,
                          hintText: fields[i].hint,
                          isDense: true,
                        ),
                        obscureText: fields[i].obscure,
                        keyboardType: fields[i].keyboardType,
                        autofocus: i == 0,
                        textInputAction: i == fields.length - 1
                            ? TextInputAction.done
                            : TextInputAction.next,
                        onSubmitted: (_) {
                          if (i == fields.length - 1) {
                            Navigator.pop(context);
                            onSubmit(controllers
                                .map((controller) => controller.text.trim())
                                .toList());
                          }
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                          onSubmit(controllers
                              .map((controller) => controller.text.trim())
                              .toList());
                        },
                        child: Text('Send'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
  }

  void _openServiceCommand(String key, Client client, BufferModel buffer) {
    switch (key) {
      case 'command-change-nick':
        _showCommandDialog(
          title: 'Change nickname',
          fields: [_CommandField('New nickname', initialValue: client.nick)],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            unawaited(client.setNickname(values[0]));
            _showCommandSent('Nickname change');
          },
        );
        break;
      case 'command-identify':
        _showCommandDialog(
          title: 'Identify with NickServ',
          fields: [
            _CommandField('Nickname', initialValue: client.nick),
            const _CommandField('Password', obscure: true),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty || values[1].isEmpty) return;
            client.send(IrcMessage(
                'PRIVMSG', ['NickServ', 'IDENTIFY ${values[0]} ${values[1]}']));
            _showCommandSent('NickServ identify');
          },
        );
        break;
      case 'command-register-nick':
        _showCommandDialog(
          title: 'Register nickname',
          fields: const [
            _CommandField('Password', obscure: true),
            _CommandField(
              'Email',
              hint: 'optional',
              keyboardType: TextInputType.emailAddress,
            ),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            var params = values[1].isEmpty
                ? 'REGISTER ${values[0]}'
                : 'REGISTER ${values[0]} ${values[1]}';
            client.send(IrcMessage('PRIVMSG', ['NickServ', params]));
            _showCommandSent('NickServ registration');
          },
        );
        break;
      case 'command-join-channel':
        _showCommandDialog(
          title: 'Join channel',
          fields: [
            _CommandField(
              'Channel',
              initialValue: client.isChannel(buffer.name) ? buffer.name : '',
              hint: '#channel',
            ),
            const _CommandField('key password (optional)', obscure: true),
          ],
          onSubmit: (values) {
            var channel = _normalizeChannelName(client, values[0]);
            if (channel.isEmpty) return;
            var keyPassword = values[1];
            unawaited(keyPassword.isEmpty
                ? client.join([channel])
                : client.join([channel], keys: [keyPassword]));
            _showCommandSent('Join channel');
          },
        );
        break;
      case 'command-register-channel':
        _showCommandDialog(
          title: 'Register channel',
          fields: [
            _CommandField(
              'Channel',
              initialValue: client.isChannel(buffer.name) ? buffer.name : '',
              hint: '#channel',
            ),
            const _CommandField('Password', obscure: true),
            const _CommandField('Description', hint: 'optional'),
          ],
          onSubmit: (values) {
            var channel = _normalizeChannelName(client, values[0]);
            if (channel.isEmpty || values[1].isEmpty) return;
            var description = values[2].isEmpty ? channel : values[2];
            client.send(IrcMessage('PRIVMSG',
                ['ChanServ', 'REGISTER $channel ${values[1]} $description']));
            _showCommandSent('ChanServ registration');
          },
        );
        break;
    }
  }

  Future<void> _quitApp() async {
    var clientProvider = context.read<ClientProvider>();
    var notifController = context.read<NotificationController>();
    var db = context.read<DB>();
    var prefs = context.read<Prefs>();
    var navigator = Navigator.of(context);
    notifController.leaveMainApp();
    prefs.quitRequested = true;
    await clientProvider.shutdownForExit();
    await notifController.dismissAll();
    await db.clearConnectionState();
    clientProvider.clear();
    if (mounted) {
      unawaited(navigator.pushNamedAndRemoveUntil(
          ConnectPage.routeName, (route) => false));
    }
    await NativeForegroundService.quitApp();
  }

  Future<void> _showToolSheet({
    required String title,
    required List<_ToolAction> actions,
  }) async {
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        var scheme = Theme.of(context).colorScheme;
        return _buildCenteredPanel(
          context: context,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPanelTitle(context, title),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (var action in actions)
                        _buildToolTile(scheme, action),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showUserTools(Client client, BufferModel buffer) {
    _showToolSheet(
      title: 'User tools',
      actions: [
        _ToolAction(
          title: 'Change nick',
          icon: Icons.badge,
          onTap: () =>
              _openServiceCommand('command-change-nick', client, buffer),
        ),
        _ToolAction(
          title: 'Identify',
          icon: Icons.verified_user,
          onTap: () => _openServiceCommand('command-identify', client, buffer),
        ),
        _ToolAction(
          title: 'Register nick',
          icon: Icons.app_registration,
          onTap: () =>
              _openServiceCommand('command-register-nick', client, buffer),
        ),
        _ToolAction(
          title: 'OPER login',
          icon: Icons.vpn_key,
          onTap: () => _openOperTool('oper-login', client, buffer),
        ),
        _ToolAction(
          title: 'Quit',
          subtitle: 'Disconnect, clear notifications, and close the app.',
          icon: Icons.logout,
          onTap: _quitApp,
        ),
      ],
    );
  }

  void _showChannelTools(Client client, BufferModel buffer, bool enabled) {
    _showToolSheet(
      title: 'CHANNEL TOOLS',
      actions: [
        _ToolAction(
          title: 'OP user',
          icon: Icons.admin_panel_settings,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-op', client, buffer),
        ),
        _ToolAction(
          title: 'DEOP user',
          icon: Icons.remove_moderator,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-deop', client, buffer),
        ),
        _ToolAction(
          title: 'Voice / devoice',
          icon: Icons.record_voice_over,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-voice', client, buffer),
        ),
        _ToolAction(
          title: 'Set channel key',
          icon: Icons.key,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-key', client, buffer),
        ),
        _ToolAction(
          title: 'Remove channel key',
          icon: Icons.no_encryption,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-key-remove', client, buffer),
        ),
        _ToolAction(
          title: 'Kick user',
          icon: Icons.logout,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-kick', client, buffer),
        ),
        _ToolAction(
          title: 'Ban and kick',
          icon: Icons.block,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-ban', client, buffer),
        ),
        _ToolAction(
          title: 'Unban mask',
          icon: Icons.lock_open,
          enabled: enabled,
          onTap: () => _openChannelTool('channel-unban', client, buffer),
        ),
      ],
    );
  }

  void _showOperTools(Client client, BufferModel buffer) {
    _showToolSheet(
      title: 'Oper tools',
      actions: [
        _ToolAction(
          title: 'KILL user',
          icon: Icons.gavel,
          onTap: () => _openOperTool('oper-kill', client, buffer),
        ),
        _ToolAction(
          title: 'GLINE mask',
          icon: Icons.public_off,
          onTap: () => _openOperTool('oper-gline', client, buffer),
        ),
        _ToolAction(
          title: 'ZLINE host/IP',
          icon: Icons.security,
          onTap: () => _openOperTool('oper-zline', client, buffer),
        ),
        _ToolAction(
          title: 'SHUN mask',
          icon: Icons.comments_disabled,
          onTap: () => _openOperTool('oper-shun', client, buffer),
        ),
        _ToolAction(
          title: 'SAJOIN / SAPART',
          icon: Icons.compare_arrows,
          onTap: () => _openOperTool('oper-sajoin', client, buffer),
        ),
        _ToolAction(
          title: 'SVSNICK',
          icon: Icons.badge,
          onTap: () => _openOperTool('oper-svsnick', client, buffer),
        ),
      ],
    );
  }

  void _openChannelTool(String key, Client client, BufferModel buffer) {
    switch (key) {
      case 'channel-op':
      case 'channel-deop':
        _showCommandDialog(
          title: key == 'channel-op' ? 'OP user' : 'DEOP user',
          fields: const [_CommandField('Nickname')],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'MODE',
                [buffer.name, key == 'channel-op' ? '+o' : '-o', values[0]]);
          },
        );
        break;
      case 'channel-voice':
        _showCommandDialog(
          title: 'Voice / Devoice',
          fields: const [
            _CommandField('Nickname'),
            _CommandField('Mode (+v or -v)', initialValue: '+v'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty || (values[1] != '+v' && values[1] != '-v')) {
              return;
            }
            _sendCommand(client, 'MODE', [buffer.name, values[1], values[0]]);
          },
        );
        break;
      case 'channel-key':
        _showCommandDialog(
          title: 'Set channel key',
          fields: const [
            _CommandField('key password', obscure: true),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'MODE', [buffer.name, '+k', values[0]]);
          },
        );
        break;
      case 'channel-key-remove':
        _showCommandDialog(
          title: 'Remove channel key',
          fields: const [
            _CommandField('current key (optional)', obscure: true),
          ],
          onSubmit: (values) {
            var params = [buffer.name, '-k'];
            if (values[0].isNotEmpty) {
              params.add(values[0]);
            }
            _sendCommand(client, 'MODE', params);
          },
        );
        break;
      case 'channel-kick':
        _showCommandDialog(
          title: 'Kick user',
          fields: const [
            _CommandField('Nickname'),
            _CommandField('Reason', initialValue: 'Requested'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'KICK', [buffer.name, values[0], values[1]]);
          },
        );
        break;
      case 'channel-ban':
        _showCommandDialog(
          title: 'Ban and kick',
          fields: const [
            _CommandField('Nick or mask'),
            _CommandField('Reason', initialValue: 'Banned'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'MODE', [buffer.name, '+b', values[0]]);
            _sendCommand(client, 'KICK', [buffer.name, values[0], values[1]]);
          },
        );
        break;
      case 'channel-unban':
        _showCommandDialog(
          title: 'Unban mask',
          fields: const [_CommandField('Ban mask')],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'MODE', [buffer.name, '-b', values[0]]);
          },
        );
        break;
    }
  }

  void _openOperTool(String key, Client client, BufferModel buffer) {
    switch (key) {
      case 'oper-login':
        _showCommandDialog(
          title: 'OPER login',
          fields: [
            _CommandField('Oper name', initialValue: client.nick),
            const _CommandField('Password', obscure: true),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty || values[1].isEmpty) return;
            _sendCommand(client, 'OPER', [values[0], values[1]]);
          },
        );
        break;
      case 'oper-kill':
        _showCommandDialog(
          title: 'KILL user',
          fields: const [
            _CommandField('Nickname'),
            _CommandField('Reason', initialValue: 'Operator action'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, 'KILL', [values[0], values[1]]);
          },
        );
        break;
      case 'oper-gline':
      case 'oper-zline':
      case 'oper-shun':
        var command = switch (key) {
          'oper-gline' => 'GLINE',
          'oper-zline' => 'ZLINE',
          _ => 'SHUN',
        };
        _showCommandDialog(
          title: '$command mask',
          fields: const [
            _CommandField('Nick, host, or mask'),
            _CommandField('Reason', initialValue: 'Operator action'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty) return;
            _sendCommand(client, command, [values[0], values[1]]);
          },
        );
        break;
      case 'oper-sajoin':
        _showCommandDialog(
          title: 'SAJOIN / SAPART',
          fields: [
            const _CommandField('Command', initialValue: 'SAJOIN'),
            const _CommandField('Nickname'),
            _CommandField(
              'Channel',
              initialValue: client.isChannel(buffer.name) ? buffer.name : '',
            ),
          ],
          onSubmit: (values) {
            var command = values[0].toUpperCase();
            if ((command != 'SAJOIN' && command != 'SAPART') ||
                values[1].isEmpty ||
                values[2].isEmpty) {
              return;
            }
            _sendCommand(client, command, [values[1], values[2]]);
          },
        );
        break;
      case 'oper-svsnick':
        _showCommandDialog(
          title: 'SVSNICK',
          fields: const [
            _CommandField('Current nick'),
            _CommandField('New nick'),
          ],
          onSubmit: (values) {
            if (values[0].isEmpty || values[1].isEmpty) return;
            _sendCommand(client, 'PRIVMSG',
                ['OperServ', 'SVSNICK ${values[0]} ${values[1]}']);
          },
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    var client = context.read<Client>();
    var prefs = context.read<Prefs>();
    var buffer = context.watch<BufferModel>();
    var network = context.watch<NetworkModel>();

    var isStatusBuffer = isServerBufferName(buffer.name);
    var isPrivateNick = !isStatusBuffer && client.isNick(buffer.name);
    var displayName = isStatusBuffer ? statusDisplayName : buffer.name;
    var subtitle = isStatusBuffer
        ? 'Server and service notices'
        : isPrivateNick
            ? buffer.realname ?? ' '
            : buffer.topic;
    var showTitleAvatar = isPrivateNick;
    var titleAvatarUrl = showTitleAvatar
        ? (buffer.hasBackendAvatarValue
            ? buffer.avatar
            : (buffer.avatar ?? _profileAvatar))
        : null;
    var isOnline = network.state == NetworkState.synchronizing ||
        network.state == NetworkState.online;
    var canSendMessage = canSendMessageToBuffer(buffer, network);
    var isChannel = client.isChannel(buffer.name);
    var isProtectedChannel =
        isChannel && isProtectedDefaultChannel(buffer.name);
    var canChannelOperate = false;
    if (isChannel && client.state == ClientState.connected) {
      var membership = buffer.members?.members[client.nick] ?? '';
      const operatorPrefixes = '!~&@%';
      canChannelOperate = membership
          .split('')
          .any((prefix) => operatorPrefixes.contains(prefix));
    }
    var isPrivateIgnored =
        isPrivateNick ? network.isIgnored(buffer.name) : false;
    var messages = buffer.archived && isChannel
        ? <MessageModel>[]
        : _visibleMessages(buffer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scheduleChannelEventExpiry(buffer);
      }
    });
    _visibleMessageCount = messages.length;
    var latestVisibleMessageId = messages.isEmpty ? null : messages.last.id;
    if (_initialChatHistoryLoaded &&
        latestVisibleMessageId != _latestVisibleMessageId) {
      var shouldStickToBottom = _latestVisibleMessageId == null || _isAtBottom;
      _latestVisibleMessageId = latestVisibleMessageId;
      if (shouldStickToBottom && latestVisibleMessageId != null) {
        _scheduleJumpToBottom();
      }
    }

    var compact = prefs.bufferCompact;
    var showTyping = prefs.typingIndicator;
    if (!client.caps.enabled.contains('message-tags')) {
      showTyping = false;
    }

    if (canSendMessage && showTyping) {
      var typingNicks = buffer.typing;
      if (typingNicks.isNotEmpty) {
        subtitle = typingNicks.join(', ') +
            ' ${typingNicks.length > 1 ? 'are' : 'is'} typing...';
      }
    }

    MaterialBanner? banner;
    if (network.state == NetworkState.online &&
        isChannel &&
        !buffer.joined &&
        !buffer.joining) {
      banner = MaterialBanner(
        content: Text('You have left this channel.'),
        actions: [
          TextButton(
            child: Text('JOIN'),
            onPressed: () {
              var bufferList = context.read<BufferListModel>();
              var db = context.read<DB>();

              bufferList.setArchived(buffer, false);
              db.storeBuffer(buffer.entry);

              _join(client, buffer);
              _fetchMetadata();
            },
          ),
        ],
      );
    }
    if (banner == null && buffer.archived) {
      banner = MaterialBanner(
        content: Text(isChannel
            ? 'This channel is disabled.'
            : 'This conversation is archived.'),
        actions: [
          TextButton(
            child: Text(isChannel ? 'ENABLE' : 'UNARCHIVE'),
            onPressed: () {
              var bufferList = context.read<BufferListModel>();
              var db = context.read<DB>();

              bufferList.setArchived(buffer, false);
              db.storeBuffer(buffer.entry);

              _fetchMetadata();
            },
          ),
        ],
      );
    }

    Widget msgList;
    if (_initialChatHistoryLoaded && messages.isEmpty) {
      msgList = Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(22, 44, 22, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum,
                size: 44,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.76),
              ),
              SizedBox(height: 12),
              Text(
                displayName,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.left,
              ),
              SizedBox(height: 6),
              Text(
                buffer.archived && isChannel
                    ? 'This channel is disabled. Messages are hidden while the connection remains active.'
                    : 'No messages yet in this conversation.',
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (_initialChatHistoryLoaded) {
      msgList = NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (notification) {
          notification.disallowIndicator();
          return false;
        },
        child: ScrollablePositionedList.builder(
          key: _listKey,
          reverse: true,
          itemScrollController: _itemScrollController,
          itemPositionsListener: _itemPositionsListener,
          scrollOffsetListener: _userScrollListener,
          itemCount: messages.length,
          initialScrollIndex: 0,
          initialAlignment: 0,
          keyboardDismissBehavior: Platform.isIOS
              ? ScrollViewKeyboardDismissBehavior.onDrag
              : ScrollViewKeyboardDismissBehavior.manual,
          itemBuilder: (context, index) {
            var msgIndex = messages.length - index - 1;
            var msg = messages[msgIndex];
            var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;
            var key = ValueKey(msg.id);

            VoidCallback? onReply;
            if (msg.msg.cmd == 'PRIVMSG' || msg.msg.cmd == 'NOTICE') {
              onReply = () => _setReplyTo(msg);
            }

            if (compact) {
              Widget compactMsgWidget = CompactMessageItem(
                key: key,
                msg: msg,
                prevMsg: prevMsg,
                unreadMarkerTime: widget.unreadMarkerTime,
                onReply: onReply,
                last: msgIndex == messages.length - 1,
              );
              if (index == 0) {
                compactMsgWidget = Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: compactMsgWidget,
                );
              }
              return compactMsgWidget;
            }

            var nextMsg =
                msgIndex + 1 < messages.length ? messages[msgIndex + 1] : null;

            Widget msgWidget = RegularMessageItem(
              key: key,
              msg: msg,
              prevMsg: prevMsg,
              nextMsg: nextMsg,
              unreadMarkerTime: widget.unreadMarkerTime,
              onReply: onReply,
              onMsgRefTap: _handleMsgRefTap,
            );
            if (index == _blinkMsgIndex) {
              msgWidget = FadeTransition(
                  opacity: _blinkMsgController, child: msgWidget);
            }
            if (index == 0) {
              msgWidget = Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: msgWidget,
              );
            }
            return msgWidget;
          },
        ),
      );
    } else {
      msgList = Container();
    }

    Widget? composer;
    if (!buffer.archived && !(isOnline && isChannel && !buffer.joined)) {
      composer = Material(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Container(
          padding: EdgeInsets.fromLTRB(10, 8, 10, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            border: Border(
              top: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.18)),
            ),
          ),
          child: Composer(
            key: _composerKey,
            sharedMedia: widget.sharedMedia,
            draft: buffer.draft,
          ),
        ),
      );
    }

    Widget jumpToBottom = ValueListenableBuilder(
      valueListenable: _showJumpToBottomValue,
      builder: (context, showJumpToBottom, _) {
        if (!showJumpToBottom) return Container();
        return Positioned(
          right: 15,
          bottom: 15,
          child: FloatingActionButton(
            mini: true,
            tooltip: 'Jump to bottom',
            heroTag: null,
            backgroundColor: Colors.grey,
            foregroundColor: Colors.white,
            onPressed: () {
              _isAtBottom = true;
              _jumpToBottom();
              _updateBufferFocus();
            },
            child: const Icon(Icons.keyboard_double_arrow_down, size: 18),
          ),
        );
      },
    );

    Widget dateIndicator = Container(
      padding: EdgeInsets.only(top: 4),
      alignment: Alignment.topCenter,
      child: DateIndicator(key: _dateIndicatorKey, date: _dateIndicatorValue),
    );
    var scaffold = Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        leadingWidth: isStatusBuffer ? 38 : 48,
        leading: isStatusBuffer
            ? null
            : IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _returnToBufferList,
              ),
        titleSpacing: 0,
        title: InkResponse(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTitleAvatar) ...[
                ProfileAvatar(
                  name: buffer.name,
                  avatarUrl: titleAvatarUrl,
                  size: 28,
                ),
                SizedBox(width: 9),
              ],
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName, overflow: TextOverflow.fade),
                    if (subtitle != null)
                      Text(
                        stripAnsiFormatting(subtitle),
                        style: TextStyle(fontSize: 12.0),
                        overflow: TextOverflow.fade,
                      ),
                  ],
                ),
              ),
            ],
          ),
          onTap: () {
            Navigator.pushNamed(context, BufferDetailsPage.routeName,
                arguments: buffer);
          },
        ),
        actions: [
          PopupMenuButton<String>(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            onSelected: (key) {
              var bufferList = context.read<BufferListModel>();
              var db = context.read<DB>();
              switch (key) {
                case 'details':
                  Navigator.pushNamed(context, BufferDetailsPage.routeName,
                      arguments: buffer);
                  break;
                case 'channel-events':
                  unawaited(_showChannelEvents(buffer));
                  break;
                case 'private-video-call':
                  unawaited(_startPrivateCall(video: true));
                  break;
                case 'private-voice-call':
                  unawaited(_startPrivateCall(video: false));
                  break;
                case 'channel-video-call':
                  unawaited(_startChannelCall(video: true));
                  break;
                case 'channel-voice-call':
                  unawaited(_startChannelCall(video: false));
                  break;
                case 'active-channel-calls':
                  unawaited(_showActiveChannelCalls());
                  break;
                case 'active-current-call':
                  _openActiveCall();
                  break;
                case 'mute':
                  unawaited(_toggleBufferMuted(buffer));
                  break;
                case 'part':
                  if (isProtectedChannel) {
                    break;
                  }
                  var client = context.read<Client>();
                  if (client.isChannel(buffer.name)) {
                    client.send(IrcMessage('PART', [buffer.name]));
                  } else {
                    client.unmonitor([buffer.name]);
                  }
                  bufferList.setArchived(buffer, true);
                  db.storeBuffer(buffer.entry);
                  Navigator.pop(context);
                  break;
                case 'delete':
                  if (isProtectedChannel) {
                    break;
                  }
                  bufferList.remove(buffer);
                  db.deleteBuffer(buffer.entry.id!);
                  Navigator.pop(context);
                  break;
                case 'command-change-nick':
                case 'command-identify':
                case 'command-register-nick':
                case 'command-join-channel':
                case 'command-register-channel':
                  _openServiceCommand(key, client, buffer);
                  break;
                case 'open-user-tools':
                  _showUserTools(client, buffer);
                  break;
                case 'open-channel-tools':
                  _showChannelTools(client, buffer, canChannelOperate);
                  break;
                case 'open-oper-tools':
                  _showOperTools(client, buffer);
                  break;
                case 'private-toggle-ignore':
                  _setIgnored(network, buffer.name, !isPrivateIgnored);
                  break;
                case 'private-ignore-list':
                  _showIgnoreList(network);
                  break;
                case 'clear':
                  unawaited(_clearMessages());
                  break;
                case 'toggle-channel-disabled':
                  bufferList.setArchived(buffer, !buffer.archived);
                  db.storeBuffer(buffer.entry);
                  break;
                case 'close-profile':
                  var client = context.read<Client>();
                  client.unmonitor([buffer.name]);
                  bufferList.remove(buffer);
                  db.deleteBuffer(buffer.entry.id!);
                  Navigator.pop(context);
                  break;
              }
            },
            itemBuilder: (context) {
              // WebRTC calls are disabled for smaller/stabler app builds.
              var activeCall = callsEnabled ? activeCallInfo.value : null;
              var showActiveCall = activeCall != null &&
                  _activeCallMatchesBuffer(activeCall, buffer);
              if (isStatusBuffer) {
                return [
                  PopupMenuItem(value: 'clear', child: Text('CLEAR')),
                ];
              }
              var hasBufferActions = (isOnline && isPrivateNick) ||
                  (isChannel &&
                      !isProtectedChannel &&
                      !buffer.archived &&
                      isOnline) ||
                  (!isProtectedChannel && buffer.archived);
              return [
                PopupMenuItem(
                    value: 'details',
                    child: Text(
                      isChannel ? 'USER LIST' : 'WHOIS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    )),
                if (isChannel) ...[
                  _darkPopupDivider(context),
                  PopupMenuItem(
                    value: 'channel-events',
                    child: Text(
                      'EVENTS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'mute',
                    child: Text(
                      buffer.muted ? 'UNMUTE' : 'MUTE',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
                if (showActiveCall)
                  PopupMenuItem(
                    value: 'active-current-call',
                    child: Text(_activeCallLabel(activeCall)),
                  ),
                if (callsEnabled && isPrivateNick) ...[
                  PopupMenuItem(
                    value: 'private-voice-call',
                    child: Text('VOICE CALL'),
                  ),
                  PopupMenuItem(
                    value: 'private-video-call',
                    child: Text('VIDEO CALL'),
                  ),
                ],
                if (callsEnabled &&
                    isChannel &&
                    (canChannelOperate || network.isIrcOperator)) ...[
                  PopupMenuItem(
                    value: 'channel-voice-call',
                    child: Text('VOICE CALL'),
                  ),
                  PopupMenuItem(
                    value: 'channel-video-call',
                    child: Text('VIDEO CALL'),
                  ),
                ],
                if (callsEnabled && isChannel && network.isIrcOperator)
                  PopupMenuItem(
                    value: 'active-channel-calls',
                    child: Text('ACTIVE VOICE / VIDEO CALLS'),
                  ),
                if (isChannel && canChannelOperate) ...[
                  _darkPopupDivider(context),
                  PopupMenuItem(
                    value: 'open-channel-tools',
                    child: Text('CHANNEL TOOLS'),
                  ),
                ],
                if (isChannel && network.isIrcOperator) ...[
                  if (!canChannelOperate) _darkPopupDivider(context),
                  PopupMenuItem(
                    value: 'open-oper-tools',
                    child: Text('Oper tools'),
                  ),
                ],
                if (isPrivateNick) ...[
                  _darkPopupDivider(context),
                  if (network.isIrcOperator)
                    PopupMenuItem(
                      value: 'open-oper-tools',
                      child: Text('Oper tools'),
                    ),
                  PopupMenuItem(
                    value: 'private-toggle-ignore',
                    child: Text(isPrivateIgnored
                        ? 'UNIGNORE ${buffer.name}'
                        : 'IGNORE ${buffer.name}'),
                  ),
                  PopupMenuItem(
                    value: 'private-ignore-list',
                    child: Text('IGNORE LIST'),
                  ),
                ],
                if (!isStatusBuffer && !isChannel && !isPrivateNick) ...[
                  _darkPopupDivider(context),
                  PopupMenuItem(
                    value: 'open-user-tools',
                    child: Text('User tools'),
                  ),
                ],
                if (hasBufferActions) _darkPopupDivider(context),
                if (isOnline && isPrivateNick)
                  PopupMenuItem(
                      value: 'mute',
                      child: Text(buffer.muted ? 'UNMUTE' : 'MUTE')),
                if (isChannel &&
                    !isProtectedChannel &&
                    !buffer.archived &&
                    isOnline)
                  PopupMenuItem(
                      value: 'part',
                      child: Text(buffer.joined ? 'Leave' : 'Archive')),
                if (!isChannel && !isProtectedChannel && buffer.archived)
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                _darkPopupDivider(context),
                PopupMenuItem(value: 'clear', child: Text('CLEAR')),
                if (isChannel)
                  PopupMenuItem(
                      value: 'toggle-channel-disabled',
                      child: Text(buffer.archived ? 'ENABLE' : 'DISABLE')),
                if (isPrivateNick)
                  PopupMenuItem(value: 'close-profile', child: Text('CLOSE')),
              ];
            },
          ),
        ],
      ),
      body: NetworkIndicator(
          network: network,
          child: Column(children: [
            if (banner != null) banner,
            Expanded(
                child: SafeArea(
                    bottom: false,
                    child: Stack(children: [
                      msgList,
                      jumpToBottom,
                      dateIndicator,
                    ]))),
            if (composer != null) composer,
          ])),
      bottomNavigationBar: null,
    );

    return PopScope(
        canPop: true,
        onPopInvokedWithResult: (bool didPop, bool? result) async {
          if (didPop) {
            await _saveDraft();
          }
        },
        child: scaffold);
  }
}

class _CommandField {
  final String label;
  final String initialValue;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;

  const _CommandField(
    this.label, {
    this.initialValue = '',
    this.hint,
    this.obscure = false,
    this.keyboardType,
  });
}

class _ToolAction {
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _ToolAction({
    required this.title,
    this.subtitle,
    required this.icon,
    this.enabled = true,
    required this.onTap,
  });
}
