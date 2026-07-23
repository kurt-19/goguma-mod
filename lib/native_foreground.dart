import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.ircmobile.app/activity');

class NativeForegroundService {
  static final StreamController<String?> _selectionsController =
      StreamController(sync: true);
  static String? _lastStartKey;
  static String? _pendingStartKey;
  static Future<void>? _pendingStart;
  static bool _handlerInstalled = false;
  static void Function(bool isPlaying, String? status, bool? userStopped)?
      _radioStateChanged;
  static void Function()? _foregroundMessagesDismissed;

  static Stream<String?> get selections => _selectionsController.stream;

  static void configure({
    void Function(bool isPlaying, String? status, bool? userStopped)?
        onRadioStateChanged,
    void Function()? onForegroundMessagesDismissed,
  }) {
    if (onRadioStateChanged != null) {
      _radioStateChanged = onRadioStateChanged;
    }
    if (onForegroundMessagesDismissed != null) {
      _foregroundMessagesDismissed = onForegroundMessagesDismissed;
    }
    _ensureMethodHandler();
  }

  static Future<String?> popLaunchSelection() async {
    if (!Platform.isAndroid) {
      return null;
    }
    _ensureMethodHandler();
    try {
      return await _channel.invokeMethod<String>('popForegroundSelection');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> start({
    required String title,
    required String text,
    bool? radioPlaying,
    String? radioUrl,
    String? payload,
    bool alert = false,
    bool alertSound = false,
    String? alertKind,
    bool force = false,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    _ensureMethodHandler();
    var key = Object.hash(title, text, radioPlaying, radioUrl, payload, alert,
            alertSound, alertKind)
        .toString();
    if (!force && _lastStartKey == key) {
      return;
    }
    var pending = _pendingStart;
    if (!force && _pendingStartKey == key && pending != null) {
      return pending;
    }
    var args = {
      'title': title,
      'text': text,
      if (radioPlaying != null) 'radioPlaying': radioPlaying,
      if (radioUrl != null) 'radioUrl': radioUrl,
      if (payload != null) 'payload': payload,
      'alert': alert,
      'alertSound': alertSound,
      if (alertKind != null) 'alertKind': alertKind,
    };
    var future = _channel.invokeMethod<void>('startForeground', args);
    _pendingStartKey = key;
    _pendingStart = future;
    try {
      await future;
      _lastStartKey = key;
    } finally {
      if (_pendingStartKey == key) {
        _pendingStartKey = null;
        _pendingStart = null;
      }
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }
    var pending = _pendingStart;
    if (pending != null) {
      try {
        await pending;
      } on Exception {
        // The stop call below is the authoritative final state.
      }
    }
    _lastStartKey = null;
    _pendingStartKey = null;
    _pendingStart = null;
    await _channel.invokeMethod<void>('stopForeground');
  }

  static Future<void> clearAlert() async {
    if (!Platform.isAndroid) {
      return;
    }
    _ensureMethodHandler();
    _lastStartKey = null;
    _pendingStartKey = null;
    _pendingStart = null;
    await _channel.invokeMethod<void>('clearForegroundAlert');
  }

  static Future<void> stopNow() async {
    if (!Platform.isAndroid) {
      return;
    }
    _lastStartKey = null;
    _pendingStartKey = null;
    _pendingStart = null;
    await _channel.invokeMethod<void>('stopForeground');
  }

  static Future<void> quitApp() async {
    if (!Platform.isAndroid) {
      await SystemNavigator.pop();
      return;
    }
    await stopNow();
    try {
      await _channel.invokeMethod<void>('quitApp');
    } on MissingPluginException {
      await SystemNavigator.pop();
    }
    await SystemNavigator.pop();
  }

  static void _ensureMethodHandler() {
    if (_handlerInstalled) {
      return;
    }
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'foregroundSelection':
          _selectionsController.add(call.arguments as String?);
          break;
        case 'radioStateChanged':
          var rawArgs = call.arguments;
          if (rawArgs is Map) {
            var isPlaying = rawArgs['radioPlaying'] == true;
            var status = rawArgs['status'] as String?;
            var userStopped = rawArgs['userStopped'] as bool?;
            _radioStateChanged?.call(isPlaying, status, userStopped);
          }
          break;
        case 'foregroundMessagesDismissed':
          _lastStartKey = null;
          _pendingStartKey = null;
          _pendingStart = null;
          _foregroundMessagesDismissed?.call();
          break;
        default:
          debugPrint('Unhandled native foreground call: ${call.method}');
      }
    });
  }
}
