import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'ansi.dart';
import 'database.dart';
import 'irc/irc.dart';
import 'logging.dart';
import 'models.dart';
import 'native_foreground.dart';
import 'native_radio.dart';
import 'page/call.dart';
import 'profile_backend.dart';

var _nextId = 1;
var _launchSelectionPopped = false;
var _androidNotificationPermissionAsked = false;
const _maxId = 0x7FFFFFFF; // 2^31 - 1

class _NotificationChannel {
  final String id;
  final String name;
  final String? description;

  const _NotificationChannel(
      {required this.id, required this.name, this.description});
}

const _directMessageChannel = _NotificationChannel(
  id: 'privmsg',
  name: 'Messages',
  description: 'Direct and channel messages',
);

const _highlightChannel = _NotificationChannel(
  id: 'highlight',
  name: 'Messages',
  description: 'Direct and channel messages',
);

const _inviteChannel = _NotificationChannel(
  id: 'invite',
  name: 'Invitations',
  description: 'Invitations to join a channel',
);

const _callChannel = _NotificationChannel(
  id: 'irc_calls_v2',
  name: 'Calls',
  description: 'Incoming voice and video calls',
);

const _radioChannel = _NotificationChannel(
  id: 'irc_connection_status',
  name: 'IRC mobile',
  description: 'Keeps IRC mobile connected in the background',
);

const _radioStartAction = 'radio-start';
const _radioStopAction = 'radio-stop';
const _callAnswerAction = 'call-answer';
const _callDeclineAction = 'call-decline';
const _radioNotificationId = 1;
const _callNotificationId = 7002;
const _foregroundPrivateAlertedUserCacheLimit = 300;

@pragma('vm:entry-point')
void _handleNotificationResponseBackground(NotificationResponse resp) {
  switch (resp.actionId) {
    case _radioStartAction:
      NativeRadioPlayback.play().ignore();
      break;
    case _radioStopAction:
      NativeRadioPlayback.stop().ignore();
      break;
    case _callDeclineAction:
      // The action itself cancels the call notification.
      break;
  }
}

var _channels = Map.fromEntries([
  _directMessageChannel,
  _highlightChannel,
  _inviteChannel,
  if (callsEnabled) _callChannel,
  _radioChannel,
].map((channel) => MapEntry(channel.id, channel)));

class _ActiveNotification {
  final int id;
  final String tag;
  final String title;
  final String? body;
  final String? channelId;
  final MessagingStyleInformation? messagingStyleInfo;

  const _ActiveNotification({
    required this.id,
    required this.tag,
    required this.title,
    this.body,
    this.channelId,
    this.messagingStyleInfo,
  });
}

class _ForegroundMessageAlert {
  final String tag;
  final String title;
  final String? body;
  final bool isChannel;
  final List<Message> messages;

  const _ForegroundMessageAlert({
    required this.tag,
    required this.title,
    required this.body,
    required this.isChannel,
    required this.messages,
  });
}

String _withServerPrefix(NetworkModel network, String value) {
  var cleanValue = value.trim();
  var server = network.serverDisplayName.trim();
  if (server.isEmpty || cleanValue.isEmpty) {
    return cleanValue.isEmpty ? server : cleanValue;
  }
  return '$server: $cleanValue';
}

String _senderTitle(NetworkModel network, String nick) =>
    _withServerPrefix(network, nick);

String _bufferTitle(BufferModel buffer) =>
    _withServerPrefix(buffer.network, buffer.name);

class _CallInvite {
  final String roomUrl;
  final String caller;
  final bool video;
  final int bufferId;

  const _CallInvite({
    required this.roomUrl,
    required this.caller,
    required this.video,
    required this.bufferId,
  });

  String get payload =>
      'call:$bufferId:${video ? 1 : 0}:${Uri.encodeComponent(caller)}:${Uri.encodeComponent(roomUrl)}';

  static _CallInvite? tryParse(MessageEntry entry, BufferModel buffer) {
    if (entry.msg.cmd != 'PRIVMSG' || entry.msg.params.length < 2) {
      return null;
    }
    if (_isChannelBuffer(buffer.name)) {
      return null;
    }
    var text = stripAnsiFormatting(entry.msg.params[1]);
    var lower = text.toLowerCase();
    if (!lower.contains('call start')) {
      return null;
    }
    var video = lower.contains('video call start');
    var voice = lower.contains('voice call start');
    if (!video && !voice) {
      return null;
    }
    var roomUrl = _extractCallRoomUrl(text);
    if (roomUrl == null) {
      return null;
    }
    var bufferId = buffer.entry.id;
    if (bufferId == null) {
      return null;
    }
    return _CallInvite(
      roomUrl: roomUrl,
      caller:
          _senderTitle(buffer.network, entry.msg.source?.name ?? buffer.name),
      video: video,
      bufferId: bufferId,
    );
  }

  static bool _isChannelBuffer(String name) {
    return RegExp(r'^[#&+!]').hasMatch(name.trim());
  }

  static String? _extractCallRoomUrl(String text) {
    var matches = RegExp(r'https?://\S+').allMatches(text);
    for (var match in matches) {
      var candidate = match.group(0)?.replaceAll(RegExp(r'[\])}>,.!?]+$'), '');
      if (candidate != null && callRoomIdFromUrl(candidate) != null) {
        return candidate;
      }
    }
    return null;
  }
}

class _CallEnd {
  final String caller;
  final int bufferId;

  const _CallEnd({
    required this.caller,
    required this.bufferId,
  });

  String get payload => 'call-end:$bufferId:${Uri.encodeComponent(caller)}';

  static _CallEnd? tryParse(MessageEntry entry, BufferModel buffer) {
    if (entry.msg.cmd != 'PRIVMSG' || entry.msg.params.length < 2) {
      return null;
    }
    if (_CallInvite._isChannelBuffer(buffer.name)) {
      return null;
    }
    var text = stripAnsiFormatting(entry.msg.params[1]).toLowerCase();
    var isCallEnd =
        text.contains('voice call end') || text.contains('video call end');
    if (!isCallEnd) {
      return null;
    }
    var bufferId = buffer.entry.id;
    if (bufferId == null) {
      return null;
    }
    return _CallEnd(
      caller:
          _senderTitle(buffer.network, entry.msg.source?.name ?? buffer.name),
      bufferId: bufferId,
    );
  }
}

class NotificationController {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<String?> _selectionsController =
      StreamController(sync: true);
  final StreamController<String> _incomingCallsController =
      StreamController.broadcast(sync: true);
  final List<_ActiveNotification> _active = [];
  _ForegroundMessageAlert? _foregroundMessageAlert;
  final Set<String> _foregroundPrivateAlertedUsers = {};
  final List<String> _foregroundPrivateAlertedUserOrder = [];
  bool _appForeground = false;
  bool _mainAppEntered = false;

  static NotificationController? _instance;

  Stream<String?> get selections => _selectionsController.stream;
  Stream<String> get incomingCalls => _incomingCallsController.stream;

  Future<void> enterMainApp() async {
    _mainAppEntered = true;
    // Show/update the foreground radio notification immediately, then ask for
    // notification permission. On Android 13+ the first update may be hidden
    // until permission is granted, so refresh once again after the permission
    // dialog finishes.
    unawaited(showRadioStatus());
    await requestAndroidNotificationPermissionOnce();
    await showRadioStatus(forceNativeUpdate: true);
  }

  void leaveMainApp() {
    _mainAppEntered = false;
  }

  Future<void> requestAndroidNotificationPermissionOnce() async {
    if (_androidNotificationPermissionAsked || !Platform.isAndroid) {
      return;
    }
    _androidNotificationPermissionAsked = true;
    var androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await androidPlugin?.requestNotificationsPermission();
    } on Exception catch (err) {
      log.print('Failed to request notifications permission', error: err);
    }
  }

  NotificationController._();

  Future<void> _init() async {
    await _plugin.initialize(
      settings: InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        android: AndroidInitializationSettings('ic_stat_name'),
        windows: WindowsInitializationSettings(
            appName: 'IRC mobile',
            appUserModelId: 'com.ircmobile.app',
            guid: '41b2ec15-f640-44be-a9c2-a4144969e94b'),
      ),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          _handleNotificationResponseBackground,
    );
    NativeRadioPlayback.keepAlive();
    NativeForegroundService.configure(onForegroundMessagesDismissed: () {
      _foregroundMessageAlert = null;
    });
    NativeForegroundService.selections.listen(_selectionsController.add);
    NativeRadioPlayback.changes.addListener(() {
      showRadioStatus().ignore();
    });

    var androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      try {
        var activeNotifs = await androidPlugin.getActiveNotifications();
        await _populateActive(androidPlugin, activeNotifs);
      } on Exception catch (err) {
        log.print('Failed to list active notifications', error: err);
      }
    }
  }

  static Future<NotificationController> init() async {
    // Use a singleton because flutter_local_notifications gets confused
    // when initialized multiple times per Isolate
    if (_instance == null) {
      _instance = NotificationController._();
      await _instance!._init();
    }
    return _instance!;
  }

  static Future<void> dismissNativeNotifications() async {
    var controller = _instance ?? await init();
    await controller.dismissAll();
  }

  Future<String?> popLaunchSelection() async {
    if (_launchSelectionPopped) {
      return null;
    }
    NotificationAppLaunchDetails? launchDetails;
    try {
      launchDetails = await _plugin.getNotificationAppLaunchDetails();
    } on UnimplementedError {
      // Ignore
    }
    _launchSelectionPopped = true;
    if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
      var pluginPayload = launchDetails.notificationResponse?.payload;
      if (pluginPayload != null) {
        return pluginPayload;
      }
    }
    return NativeForegroundService.popLaunchSelection();
  }

  Future<void> _populateActive(
      AndroidFlutterLocalNotificationsPlugin androidPlugin,
      List<ActiveNotification> activeNotifs) async {
    for (var notif in activeNotifs) {
      if (notif.id == null) {
        continue; // not created by the flutter_local_notifications plugin
      }

      if (_nextId <= notif.id!) {
        _nextId = notif.id! + 1;
        _nextId = _nextId % _maxId;
      }

      if (notif.tag == null || notif.title == null) {
        log.print('Found an active notification without a tag or title');
        continue;
      }

      MessagingStyleInformation? messagingStyleInfo;
      try {
        messagingStyleInfo =
            await androidPlugin.getActiveNotificationMessagingStyle(
          id: notif.id!,
          tag: notif.tag,
        );
      } on Exception catch (err) {
        log.print('Failed to get active notification messaging style',
            error: err);
      }

      _active.add(_ActiveNotification(
        id: notif.id!,
        tag: notif.tag!,
        title: notif.title!,
        body: notif.body,
        channelId: notif.channelId,
        messagingStyleInfo: messagingStyleInfo,
      ));
    }
  }

  Future<void> _syncAndroidActiveNotifications() async {
    if (!Platform.isAndroid || _active.isEmpty) {
      return;
    }

    var androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) {
      return;
    }

    try {
      var activeNotifs = await androidPlugin.getActiveNotifications();
      _active.removeWhere((notif) {
        for (var activeNotif in activeNotifs) {
          if (activeNotif.id == notif.id && activeNotif.tag == notif.tag) {
            return false;
          }
        }
        return true;
      });
    } on Exception catch (err) {
      log.print('Failed to sync active notifications', error: err);
    }
  }

  void _handleNotificationResponse(NotificationResponse resp) {
    if (!callsEnabled &&
        (resp.actionId == _callAnswerAction ||
            resp.actionId == _callDeclineAction ||
            resp.payload?.startsWith('call:') == true ||
            resp.payload?.startsWith('call-end:') == true ||
            resp.payload?.startsWith('call-decline:') == true)) {
      _plugin.cancel(id: _callNotificationId, tag: 'call').ignore();
      return;
    }
    switch (resp.actionId) {
      case _radioStartAction:
        NativeRadioPlayback.play().ignore();
        showRadioStatus().ignore();
        return;
      case _radioStopAction:
        NativeRadioPlayback.stop().ignore();
        showRadioStatus().ignore();
        return;
      case _callDeclineAction:
        _plugin.cancel(id: _callNotificationId, tag: 'call').ignore();
        return;
      case _callAnswerAction:
        _plugin.cancel(id: _callNotificationId, tag: 'call').ignore();
        _selectionsController.add(resp.payload);
        return;
    }
    if (resp.payload?.startsWith('call:') == true) {
      _plugin.cancel(id: _callNotificationId, tag: 'call').ignore();
    }
    _selectionsController.add(resp.payload);
  }

  void setAppLifecycleState(AppLifecycleState state) {
    var appForeground = state == AppLifecycleState.resumed;
    if (_appForeground == appForeground) {
      return;
    }
    _appForeground = appForeground;
    if (_appForeground) {
      unawaited(_dismissMessageNotifications());
    }
  }

  String _bufferTag(BufferModel buffer) {
    return 'buffer:${buffer.id}';
  }

  Future<bool> showDirectCallInvite(
      List<MessageEntry> entries, BufferModel buffer) async {
    if (!callsEnabled) {
      return false;
    }
    var callEnd = _findCallEnd(entries, buffer);
    if (callEnd != null) {
      await _showCallEnd(callEnd);
      return true;
    }
    var callInvite = _findCallInvite(entries, buffer);
    if (callInvite != null) {
      await _showCallInvite(callInvite);
      return true;
    }
    return false;
  }

  Future<void> showDirectMessage(
      List<MessageEntry> entries, BufferModel buffer) async {
    if (buffer.muted) {
      return;
    }
    if (callsEnabled) {
      var callEnd = _findCallEnd(entries, buffer);
      if (callEnd != null) {
        await _showCallEnd(callEnd);
        return;
      }
      var callInvite = _findCallInvite(entries, buffer);
      if (callInvite != null) {
        await _showCallInvite(callInvite);
        return;
      }
    }

    if (_appForeground) {
      await _showForegroundPrivateMessageOnce(entries, buffer);
      return;
    }
    if (Platform.isAndroid) {
      await _showForegroundMessage(entries, buffer, isChannel: false);
      return;
    }

    await _syncAndroidActiveNotifications();
    var entry = entries.first;
    String tag = _bufferTag(buffer);
    _ActiveNotification? replace = _getActiveWithTag(tag);
    var sender = _senderTitle(buffer.network, entry.msg.source!.name);

    String title;
    if (replace == null) {
      title = sender;
    } else {
      title = _incrementTitleCount(replace.title, entries.length,
          ' messages from $sender');
    }

    List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
    messages.addAll(entries.map((entry) => _buildMessage(entry, buffer)));

    await _show(
      title: title,
      body: _getMessageBody(entry),
      channel: _directMessageChannel,
      dateTime: _getLatestMessageTimestamp(messages),
      messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, false),
      tag: _bufferTag(buffer),
    );
  }

  Future<void> showHighlight(
      List<MessageEntry> entries, BufferModel buffer) async {
    if (buffer.muted) {
      return;
    }
    if (_appForeground) {
      return;
    }
    if (Platform.isAndroid) {
      await _showForegroundMessage(entries, buffer, isChannel: true);
      return;
    }

    await _syncAndroidActiveNotifications();
    var entry = entries.first;
    String tag = _bufferTag(buffer);
    _ActiveNotification? replace = _getActiveWithTag(tag);
    var sender = _senderTitle(buffer.network, entry.msg.source!.name);

    String title;
    if (replace == null) {
      title = '$sender in ${buffer.name}';
    } else {
      title = _incrementTitleCount(
          replace.title, entries.length,
          ' mentions in ${_bufferTitle(buffer)}');
    }

    List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
    messages.addAll(entries.map((entry) => _buildMessage(entry, buffer)));

    await _show(
      title: title,
      body: _getMessageBody(entry),
      channel: _highlightChannel,
      dateTime: _getLatestMessageTimestamp(messages),
      messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, true),
      tag: _bufferTag(buffer),
    );
  }

  Future<void> showInvite(IrcMessage msg, NetworkModel network) async {
    if (_appForeground) {
      return;
    }
    await _syncAndroidActiveNotifications();
    assert(msg.cmd == 'INVITE');
    var channel = msg.params[1];
    var time = msg.tags['time'];
    var sender = _senderTitle(network, msg.source!.name);

    await _show(
      title: '$sender invited you to $channel',
      channel: _inviteChannel,
      dateTime: time != null ? DateTime.tryParse(time) : null,
      tag: 'invite:${network.networkEntry.id}:$channel',
    );
  }

  Future<void> showRadioStatus({bool forceNativeUpdate = false}) async {
    var isPlaying = NativeRadioPlayback.isPlaying ||
        NativeRadioPlayback.status == 'Connecting' ||
        NativeRadioPlayback.status == 'Switching';
    if (Platform.isAndroid) {
      var foregroundAlert = _foregroundMessageAlert;
      if (foregroundAlert != null) {
        await _showForegroundMessageAlert(foregroundAlert, alertSound: false);
      } else if (!_mainAppEntered) {
        await _plugin.cancel(id: 7001);
        return;
      } else {
        await NativeForegroundService.start(
          title: NativeRadioPlayback.notificationText,
          text: NativeRadioPlayback.station.name,
          radioPlaying: isPlaying,
          radioUrl: NativeRadioPlayback.station.url,
          payload: 'radio',
          force: forceNativeUpdate,
        );
      }
      await _plugin.cancel(id: 7001);
      return;
    }

    var action = AndroidNotificationAction(
      isPlaying ? _radioStopAction : _radioStartAction,
      isPlaying ? 'Stop' : 'Start',
      icon: DrawableResourceAndroidBitmap(
          isPlaying ? 'ic_notification_stop' : 'ic_notification_start'),
      showsUserInterface: true,
      cancelNotification: false,
    );

    await _plugin.show(
      id: _radioNotificationId,
      title: isPlaying ? 'Connected' : 'IRC mobile',
      body: NativeRadioPlayback.notificationText,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _radioChannel.id,
          _radioChannel.name,
          channelDescription: _radioChannel.description,
          icon: isPlaying ? 'ic_notification_stop' : 'ic_notification_start',
          importance: Importance.low,
          priority: Priority.low,
          category: AndroidNotificationCategory.service,
          ongoing: true,
          silent: true,
          onlyAlertOnce: true,
          showWhen: false,
          channelShowBadge: false,
          actions: [action],
        ),
      ),
      payload: 'radio',
    );
  }

  Future<void> _dismissMessageNotifications() async {
    _foregroundMessageAlert = null;
    await _cancelAndroidMessageNotifications();
    if (Platform.isAndroid) {
      await showRadioStatus();
    }
  }

  Future<void> dismissAll() async {
    _foregroundMessageAlert = null;
    _active.clear();
    await NativeRadioPlayback.stop(updateForeground: false);
    await _plugin.cancelAll();
    await NativeForegroundService.stopNow();
    await _plugin.cancelAll();
  }

  Future<void> _cancelAndroidMessageNotifications() async {
    if (!Platform.isAndroid) {
      return;
    }
    _foregroundMessageAlert = null;
    var prevActive = [..._active];
    var futures = <Future<void>>[];
    for (var notif in prevActive) {
      if (notif.channelId != _directMessageChannel.id &&
          notif.channelId != _highlightChannel.id) {
        continue;
      }
      futures.add(_plugin.cancel(id: notif.id, tag: notif.tag));
      _active.remove(notif);
    }
    await Future.wait(futures);
  }

  Future<void> _showForegroundMessage(
      List<MessageEntry> entries, BufferModel buffer,
      {required bool isChannel, bool alertSound = true}) async {
    var tag = _bufferTag(buffer);
    var entry = entries.first;
    var previous =
        _foregroundMessageAlert?.tag == tag ? _foregroundMessageAlert : null;
    var sender = _senderTitle(buffer.network, entry.msg.source!.name);

    String title;
    if (previous == null) {
      title = isChannel
          ? '$sender in ${buffer.name}'
          : sender;
    } else if (isChannel) {
      title = _incrementTitleCount(
          previous.title, entries.length,
          ' mentions in ${_bufferTitle(buffer)}');
    } else {
      title = _incrementTitleCount(previous.title, entries.length,
          ' messages from $sender');
    }

    var messages = [
      ...?previous?.messages,
      ...entries.map((entry) => _buildMessage(entry, buffer)),
    ];
    var latest =
        messages.reduce((a, b) => a.timestamp.isAfter(b.timestamp) ? a : b);
    var foregroundAlert = _ForegroundMessageAlert(
      tag: tag,
      title: title,
      body: latest.text,
      isChannel: isChannel,
      messages: messages,
    );
    _foregroundMessageAlert = foregroundAlert;
    await _showForegroundMessageAlert(foregroundAlert, alertSound: alertSound);
  }

  Future<void> _showForegroundMessageAlert(
    _ForegroundMessageAlert foregroundAlert, {
    bool alertSound = true,
  }) async {
    var isPlaying = NativeRadioPlayback.isPlaying ||
        NativeRadioPlayback.status == 'Connecting' ||
        NativeRadioPlayback.status == 'Switching';
    await NativeForegroundService.start(
      title: foregroundAlert.title,
      text: foregroundAlert.body ?? '',
      radioPlaying: isPlaying,
      radioUrl: NativeRadioPlayback.station.url,
      payload: foregroundAlert.tag,
      alert: true,
      alertSound: alertSound,
    );
  }

  _CallInvite? _findCallInvite(List<MessageEntry> entries, BufferModel buffer) {
    for (var entry in entries) {
      var invite = _CallInvite.tryParse(entry, buffer);
      if (invite != null) {
        return invite;
      }
    }
    return null;
  }

  _CallEnd? _findCallEnd(List<MessageEntry> entries, BufferModel buffer) {
    for (var entry in entries) {
      var callEnd = _CallEnd.tryParse(entry, buffer);
      if (callEnd != null) {
        return callEnd;
      }
    }
    return null;
  }

  Future<void> _showCallEnd(_CallEnd callEnd) async {
    await dismissCallInvite();
    if (_appForeground) {
      _incomingCallsController.add(callEnd.payload);
    }
  }

  Future<void> _showCallInvite(_CallInvite invite) async {
    var callKind = invite.video ? 'video call' : 'voice call';
    var title = 'Incoming $callKind';
    var body = invite.caller.isEmpty ? 'Tap Answer to join' : invite.caller;
    if (_appForeground) {
      _incomingCallsController.add(invite.payload);
    }
    if (Platform.isAndroid) {
      // Do not use flutter_local_notifications for incoming calls on Android.
      // Its channel can only play the short notification ding. The native
      // foreground service shows the Answer/Decline call notification and plays
      // the bundled ringtone WAV in a loop.
      await _plugin.cancel(id: _callNotificationId, tag: 'call');
      await NativeForegroundService.start(
        title: title,
        text: body,
        payload: invite.payload,
        alert: true,
        alertSound: true,
        alertKind: 'call',
      );
      unawaited(requestAndroidNotificationPermissionOnce().then((_) {
        return NativeForegroundService.start(
          title: title,
          text: body,
          payload: invite.payload,
          alert: true,
          alertSound: true,
          alertKind: 'call',
          force: true,
        );
      }));
      return;
    }

    await requestAndroidNotificationPermissionOnce();
    await _show(
      title: title,
      body: body,
      channel: _callChannel,
      tag: 'call',
      payload: invite.payload,
    );
  }

  Future<void> dismissCallInvite() async {
    await _plugin.cancel(id: _callNotificationId, tag: 'call');
    await NativeForegroundService.clearAlert();
  }

  Future<void> _showForegroundPrivateMessageOnce(
      List<MessageEntry> entries, BufferModel buffer) async {
    if (!_rememberForegroundPrivateUser(buffer)) {
      return;
    }
    if (Platform.isAndroid) {
      await _showForegroundMessage(entries, buffer,
          isChannel: false, alertSound: true);
      return;
    }
    await _playForegroundPrivatePing();
  }

  bool _rememberForegroundPrivateUser(BufferModel buffer) {
    var key = _foregroundPrivateUserKey(buffer);
    if (!_foregroundPrivateAlertedUsers.add(key)) {
      return false;
    }
    _foregroundPrivateAlertedUserOrder.add(key);
    while (_foregroundPrivateAlertedUserOrder.length >
        _foregroundPrivateAlertedUserCacheLimit) {
      _foregroundPrivateAlertedUsers
          .remove(_foregroundPrivateAlertedUserOrder.removeAt(0));
    }
    return true;
  }

  String _foregroundPrivateUserKey(BufferModel buffer) {
    return _bufferTag(buffer);
  }

  Future<void> _playForegroundPrivatePing() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } on Exception catch (err) {
      log.print('Failed to play foreground private-message alert', error: err);
    }
  }

  String _incrementTitleCount(String title, int incr, String suffix) {
    int total;
    if (!title.endsWith(suffix)) {
      total = 1;
    } else {
      total = int.parse(title.substring(0, title.length - suffix.length));
    }
    total += incr;
    return '$total$suffix';
  }

  MessagingStyleInformation _buildMessagingStyleInfo(
      List<Message> messages, BufferModel buffer, bool isChannel) {
    // TODO: Person.key, Person.bot, Person.uri
    return MessagingStyleInformation(
      Person(name: _bufferTitle(buffer)),
      conversationTitle: _bufferTitle(buffer),
      groupConversation: isChannel,
      messages: messages,
    );
  }

  Message _buildMessage(MessageEntry entry, BufferModel buffer) {
    return Message(
      _getMessageBody(entry),
      entry.dateTime,
      Person(name: _senderTitle(buffer.network, entry.msg.source!.name)),
    );
  }

  String _getMessageBody(MessageEntry entry) {
    var sender = entry.msg.source!.name;
    var ctcp = CtcpMessage.parse(entry.msg);
    if (ctcp == null) {
      return stripAnsiFormatting(entry.msg.params[1]);
    }
    if (ctcp.cmd == 'ACTION') {
      var action = stripAnsiFormatting(ctcp.param ?? '');
      return '$sender $action';
    } else {
      return '$sender has sent a CTCP "${ctcp.cmd}" command';
    }
  }

  DateTime? _getLatestMessageTimestamp(List<Message> messages) {
    DateTime? latest;
    for (var msg in messages) {
      if (latest == null || msg.timestamp.isAfter(latest)) {
        latest = msg.timestamp;
      }
    }
    return latest;
  }

  Future<void> cancelAllWithBuffer(BufferModel buffer, DateTime? before) async {
    var tag = _bufferTag(buffer);
    await _syncAndroidActiveNotifications();
    var foregroundAlert = _foregroundMessageAlert;
    if (Platform.isAndroid && foregroundAlert?.tag == tag) {
      var epsilon = Duration(milliseconds: 500);
      var messages = foregroundAlert!.messages.where((msg) {
        return before != null &&
            msg.timestamp.subtract(epsilon).isAfter(before);
      }).toList();
      if (messages.isEmpty) {
        _foregroundMessageAlert = null;
        await showRadioStatus();
      } else if (messages.length != foregroundAlert.messages.length) {
        var latest =
            messages.reduce((a, b) => a.timestamp.isAfter(b.timestamp) ? a : b);
        _foregroundMessageAlert = _ForegroundMessageAlert(
          tag: foregroundAlert.tag,
          title: foregroundAlert.title,
          body: latest.text,
          isChannel: foregroundAlert.isChannel,
          messages: messages,
        );
        await _showForegroundMessageAlert(_foregroundMessageAlert!,
            alertSound: false);
      }
    }

    var prevActive = [..._active]; // copy to be able to remove while iterating
    List<Future<void>> futures = [];
    for (var notif in prevActive) {
      if (notif.tag != tag) {
        continue;
      }

      var prevMessagingStyleInfo = notif.messagingStyleInfo;
      var prevMessages = prevMessagingStyleInfo?.messages ?? [];

      var epsilon = Duration(
          milliseconds: 500); // the platform may round notification timestamps
      var messages = prevMessages.where((msg) {
        return before != null &&
            msg.timestamp.subtract(epsilon).isAfter(before);
      }).toList();

      _NotificationChannel? channel;
      if (notif.channelId != null) {
        channel = _channels[notif.channelId];
      }

      // TODO: on non-Android, check notification timestamp
      if (messages.isEmpty ||
          channel == null ||
          prevMessagingStyleInfo == null) {
        futures.add(_plugin.cancel(id: notif.id, tag: notif.tag));
        _active.remove(notif);
        continue;
      }

      if (messages.length == prevMessages.length) {
        continue;
      }

      // TODO: update notification title
      futures.add(_show(
        title: notif.title,
        body: notif.body,
        channel: channel,
        dateTime: _getLatestMessageTimestamp(messages),
        messagingStyleInfo: MessagingStyleInformation(
          prevMessagingStyleInfo.person,
          conversationTitle: prevMessagingStyleInfo.conversationTitle,
          groupConversation: prevMessagingStyleInfo.groupConversation,
          messages: messages,
        ),
        tag: notif.tag,
      ));
    }
    await Future.wait(futures);
  }

  _ActiveNotification? _getActiveWithTag(String tag) {
    for (var notif in _active) {
      if (notif.tag == tag) {
        return notif;
      }
    }
    return null;
  }

  bool _isIdAvailable(int id) {
    for (var notif in _active) {
      if (notif.id == id) {
        return false;
      }
    }
    return true;
  }

  Future<void> _show({
    required String title,
    String? body,
    required _NotificationChannel channel,
    required String tag,
    DateTime? dateTime,
    MessagingStyleInformation? messagingStyleInfo,
    String? payload,
  }) async {
    _ActiveNotification? replaced = _getActiveWithTag(tag);
    int id;
    var onlyAlertOnce = false;
    if (replaced != null) {
      _active.remove(replaced);
      id = replaced.id;

      var oldMessageCount = replaced.messagingStyleInfo?.messages?.length ?? 0;
      var newMessageCount = messagingStyleInfo?.messages?.length ?? 0;
      onlyAlertOnce = oldMessageCount > newMessageCount;
    } else {
      while (true) {
        id = _nextId++;
        _nextId = _nextId % _maxId;
        if (_isIdAvailable(id)) {
          break;
        }
      }
    }
    _active.add(_ActiveNotification(
      id: id,
      tag: tag,
      title: title,
      body: body,
      channelId: channel.id,
      messagingStyleInfo: messagingStyleInfo,
    ));

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        linux: LinuxNotificationDetails(
          category: LinuxNotificationCategory.imReceived,
        ),
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          when: dateTime?.millisecondsSinceEpoch,
          styleInformation: messagingStyleInfo,
          tag: tag,
          enableLights: true,
          ongoing: false,
          autoCancel: true,
          onlyAlertOnce: onlyAlertOnce,
        ),
      ),
      payload: payload ?? tag,
    );
  }
}
