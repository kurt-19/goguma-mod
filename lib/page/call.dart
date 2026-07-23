import 'package:flutter/material.dart';

import '../client.dart';
import '../profile_backend.dart';

// WebRTC calls are disabled to keep the release APK smaller and the app stable.
// The original WebRTC pages are kept next to this file as *.disabled.
bool get callsEnabled => false;

class CallPageArguments {
  final String roomUrl;
  final String? target;
  final bool? video;
  final bool autoJoin;
  final bool outgoing;
  final bool channel;
  final String? nick;
  final String role;
  final String controlToken;
  final List<String> channelMembers;
  final Map<String, String> channelMemberPrefixes;
  final Client? client;
  final String? returnRouteName;
  final Object? returnRouteArguments;

  const CallPageArguments({
    required this.roomUrl,
    this.target,
    this.video,
    this.autoJoin = true,
    this.outgoing = false,
    this.channel = false,
    this.nick,
    this.role = 'member',
    this.controlToken = '',
    this.channelMembers = const [],
    this.channelMemberPrefixes = const {},
    this.client,
    this.returnRouteName,
    this.returnRouteArguments,
  });

  static CallPageArguments? tryParse(
    String url, {
    String? target,
    bool? video,
    bool channel = false,
    String? nick,
    String role = 'member',
    String controlToken = '',
    List<String> channelMembers = const [],
    Map<String, String> channelMemberPrefixes = const {},
    Client? client,
    String? returnRouteName,
    Object? returnRouteArguments,
  }) {
    if (!callsEnabled) {
      return null;
    }
    var roomId = callRoomIdFromUrl(url);
    if (roomId == null) {
      return null;
    }
    var uri = Uri.tryParse(url);
    var channelTarget = uri?.queryParameters['channel']?.trim() ?? '';
    var isChannel = channel || channelTarget.isNotEmpty;
    var queryVideo = uri?.queryParameters['video'];
    return CallPageArguments(
      roomUrl: url,
      target: channelTarget.isNotEmpty ? channelTarget : target,
      video: video ?? (queryVideo == null ? null : queryVideo == '1'),
      channel: isChannel,
      nick: nick,
      role: role,
      controlToken: controlToken,
      channelMembers: channelMembers,
      channelMemberPrefixes: channelMemberPrefixes,
      client: client,
      returnRouteName: returnRouteName,
      returnRouteArguments: returnRouteArguments,
    );
  }
}

class CallPage extends StatelessWidget {
  static const routeName = '/call';

  final CallPageArguments args;

  const CallPage({required this.args, super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Calls are disabled'),
      ),
    );
  }
}

class ActiveCallInfo {
  final CallPageArguments args;

  const ActiveCallInfo(this.args);

  String get roomUrl => args.roomUrl;
  String get target => args.target ?? '';
  bool get video => args.video ?? false;
  bool get channel => args.channel;
}

final activeCallInfo = ValueNotifier<ActiveCallInfo?>(null);
