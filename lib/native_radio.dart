import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'native_foreground.dart';

class RadioStation {
  final String id;
  final String name;
  final String url;

  const RadioStation(this.id, this.name, this.url);
}

const nativeRadioStations = [
  RadioStation('power-turk', 'Power Turk',
      'https://listen.powerapp.com.tr/powerturk/mpeg/icecast.audio'),
  RadioStation('super-fm', 'Super FM',
      'https://29103.live.streamtheworld.com/SUPER_FM.mp3'),
  RadioStation('joy-turk', 'Joy Turk',
      'https://playerservices.streamtheworld.com/api/livestream-redirect/JOY_TURK.mp3'),
];

class NativeRadioPlayback {
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static final AudioPlayer _player = AudioPlayer();
  static final StreamSubscription<PlayerState> _playerStateSub =
      _player.onPlayerStateChanged.listen(_handlePlayerState);

  static int stationIndex = 1;
  static bool isPlaying = false;
  static bool userStopped = false;
  static String status = 'Ready';
  static String? connectionNick;
  static bool _initialAutoStartDone = false;
  static String? _lastNotificationState;

  static RadioStation get station => nativeRadioStations[
      stationIndex.clamp(0, nativeRadioStations.length - 1)];

  static String get notificationText {
    var label = connectionNick;
    if (label == null || label.isEmpty) {
      return 'Connected';
    }
    return label;
  }

  static void _notify() {
    var nextState = '$stationIndex|$isPlaying|$userStopped|$status';
    if (_lastNotificationState == nextState) {
      return;
    }
    _lastNotificationState = nextState;
    changes.value++;
  }

  static void _handlePlayerState(PlayerState state) {
    isPlaying = state == PlayerState.playing;
    if (isPlaying) {
      status = 'On air';
    }
    _notify();
  }

  static void _handleNativeRadioState(
      bool nativeIsPlaying, String? nativeStatus, bool? nativeUserStopped) {
    if (!Platform.isAndroid) {
      return;
    }
    isPlaying = nativeIsPlaying;
    userStopped = nativeUserStopped ?? !nativeIsPlaying;
    status = nativeStatus ??
        (nativeIsPlaying
            ? 'On air'
            : userStopped
                ? 'Stopped'
                : 'Ready');
    _notify();
  }

  static Future<void> autoStart() async {
    if (userStopped || isPlaying || status == 'Connecting') {
      return;
    }
    await play();
  }

  static Future<void> autoStartInitialConnection() async {
    if (_initialAutoStartDone) {
      return;
    }
    _initialAutoStartDone = true;
    if (isPlaying || status == 'Connecting') {
      return;
    }
    await play();
  }

  static Future<void> play({bool restart = false}) async {
    userStopped = false;
    if (Platform.isAndroid && isPlaying && !restart) {
      status = 'On air';
      _notify();
      await NativeForegroundService.start(
        title: notificationText,
        text: station.name,
        radioPlaying: true,
        radioUrl: station.url,
      );
      return;
    }
    status = restart ? 'Switching' : 'Connecting';
    _notify();
    if (Platform.isAndroid) {
      try {
        await NativeForegroundService.start(
          title: notificationText,
          text: station.name,
          radioPlaying: true,
          radioUrl: station.url,
        );
        isPlaying = true;
        status = 'On air';
      } on Exception {
        isPlaying = false;
        status = 'Stream error';
      }
      _notify();
      return;
    }
    try {
      if (restart) {
        await _player.stop();
      }
      await _player.play(UrlSource(station.url));
      isPlaying = true;
      status = 'On air';
    } on Exception {
      isPlaying = false;
      status = 'Stream error';
    }
    _notify();
  }

  static Future<void> pause() async {
    if (Platform.isAndroid) {
      isPlaying = false;
      userStopped = true;
      status = 'Paused';
      _notify();
      await NativeForegroundService.start(
        title: notificationText,
        text: station.name,
        radioPlaying: false,
        radioUrl: station.url,
      );
      return;
    }
    await _player.pause();
    isPlaying = false;
    userStopped = true;
    status = 'Paused';
    _notify();
  }

  static Future<void> stop({
    bool userInitiated = true,
    bool updateForeground = true,
  }) async {
    isPlaying = false;
    userStopped = userInitiated;
    status = 'Stopped';
    _notify();
    if (Platform.isAndroid) {
      if (updateForeground) {
        await NativeForegroundService.start(
          title: notificationText,
          text: station.name,
          radioPlaying: false,
          radioUrl: station.url,
        );
      }
      return;
    }
    try {
      await _player.stop();
      await _player.release();
    } on Exception {
      // Keep the user's stop intent even if the stream backend is slow.
    }
    isPlaying = false;
    userStopped = userInitiated;
    status = 'Stopped';
    _notify();
  }

  static Future<void> next() async {
    var shouldAutoPlay = isPlaying || status == 'Connecting';
    stationIndex = (stationIndex + 1) % nativeRadioStations.length;
    isPlaying = false;
    userStopped = !shouldAutoPlay;
    status = shouldAutoPlay ? 'Switching' : 'Selected';
    _notify();
    if (shouldAutoPlay) {
      await play(restart: true);
    } else if (Platform.isAndroid) {
      await NativeForegroundService.start(
        title: notificationText,
        text: station.name,
        radioPlaying: false,
        radioUrl: station.url,
      );
    } else {
      await _player.stop();
    }
  }

  static void keepAlive() {
    _playerStateSub;
    NativeForegroundService.configure(
        onRadioStateChanged: _handleNativeRadioState);
  }
}
