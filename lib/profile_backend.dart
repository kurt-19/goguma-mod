import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import 'app_config.dart';

const profileBackendBaseUrl = appApiBaseUrl;

class ProfileBackendClient {
  const ProfileBackendClient({this.baseUrl = profileBackendBaseUrl});

  final String baseUrl;
  static final Map<String, String> _avatarCache = {};
  static final StreamController<ProfileAvatarChange> _avatarChanges =
      StreamController<ProfileAvatarChange>.broadcast();
  static bool _avatarEventsStarted = false;

  static Stream<ProfileAvatarChange> get avatarChanges => _avatarChanges.stream;

  static void startAvatarEventListener(
      {String baseUrl = profileBackendBaseUrl}) {
    if (_avatarEventsStarted) {
      return;
    }
    _avatarEventsStarted = true;
    unawaited(_listenAvatarEvents(baseUrl));
  }

  Map<String, String> cachedAvatarUrls(String server, Iterable<String> nicks) {
    var result = <String, String>{};
    for (var nick in nicks) {
      var clean = nick.trim();
      if (clean.isEmpty) {
        continue;
      }
      var avatar = _avatarCache[_avatarCacheKey(baseUrl, server, clean)];
      if (avatar != null) {
        result[clean.toLowerCase()] = avatar;
      }
    }
    return result;
  }

  Future<Map<String, String>> fetchAvatarUrls(
      String server, Iterable<String> nicks) async {
    var uniqueNicks = <String>[];
    var seen = <String>{};
    var result = <String, String>{};
    for (var nick in nicks) {
      var clean = nick.trim();
      if (clean.isEmpty) {
        continue;
      }
      var key = clean.toLowerCase();
      if (seen.add(key)) {
        var cacheKey = _avatarCacheKey(baseUrl, server, clean);
        var cached = _avatarCache[cacheKey];
        if (cached != null) {
          result[key] = cached;
        }
        uniqueNicks.add(clean);
      }
      if (uniqueNicks.length >= 200) {
        break;
      }
    }
    if (server.isEmpty || uniqueNicks.isEmpty) {
      return result;
    }

    var uri = Uri.parse(
            '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/profiles/avatars')
        .replace(queryParameters: {
      'server': server,
      'nicks': uniqueNicks.join(','),
    });
    var data = await _getJson(uri);
    var profiles = data['profiles'];
    if (profiles is! Map) {
      return result;
    }

    for (var nick in uniqueNicks) {
      var profile = profiles[nick] ?? profiles[nick.toLowerCase()];
      var cacheKey = _avatarCacheKey(baseUrl, server, nick);
      var resultKey = nick.toLowerCase();
      if (profile is! Map) {
        _avatarCache.remove(cacheKey);
        result.remove(resultKey);
        continue;
      }
      var avatarUrl = (profile['avatarUrl'] as String?)?.trim();
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        var resolved =
            _versionAvatarUrl(_resolveUrl(avatarUrl), profile['updatedAt']);
        _avatarCache[cacheKey] = resolved;
        result[resultKey] = resolved;
      } else {
        _avatarCache.remove(cacheKey);
        result.remove(resultKey);
      }
    }
    return result;
  }

  Future<String> uploadProfileAvatar({
    required String server,
    required String nick,
    required String account,
    required XFile file,
  }) async {
    if (account.trim().isEmpty) {
      throw Exception('Identify or register your nick before uploading');
    }
    var fileName = file.name.isEmpty
        ? 'avatar-${DateTime.now().millisecondsSinceEpoch}.jpg'
        : file.name;
    var contentType = file.mimeType ??
        lookupMimeType(fileName) ??
        _contentTypeFromName(fileName);
    if (!contentType.startsWith('image/')) {
      throw Exception('Please select an image file');
    }
    var bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw Exception('Image must be between 1 byte and 5MB');
    }

    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/profile/avatar/upload');
    var client = HttpClient();
    try {
      var req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json');
      req.headers.set('X-IRC-Mobile-App', '1');
      req.write(json.encode({
        'server': server,
        'nick': nick,
        'account': account,
        'fileName': fileName,
        'contentType': contentType,
        'dataBase64': base64Encode(bytes),
      }));
      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(_serverErrorMessage(
            resp.statusCode, text, 'Profile photo upload failed'));
      }
      var data = json.decode(text);
      var profile = data['profile'];
      var avatarUrl = profile is Map ? profile['avatarUrl'] as String? : null;
      avatarUrl ??= data['saved_url'] as String?;
      if (avatarUrl == null || avatarUrl.trim().isEmpty) {
        throw Exception('Profile photo upload returned no URL');
      }
      var updatedAt = profile is Map ? profile['updatedAt'] : null;
      var resolved = _versionAvatarUrl(_resolveUrl(avatarUrl),
          updatedAt ?? DateTime.now().toIso8601String());
      _setAvatarCache(
        baseUrl: baseUrl,
        server: server,
        nick: nick,
        avatarUrl: resolved,
      );
      return resolved;
    } finally {
      client.close();
    }
  }

  Future<void> deleteProfileAvatar({
    required String server,
    required String nick,
    required String account,
  }) async {
    if (account.trim().isEmpty) {
      throw Exception('Identify or register your nick before removing');
    }

    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/profile/avatar');
    var client = HttpClient();
    try {
      var req = await client.deleteUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json');
      req.headers.set('X-IRC-Mobile-App', '1');
      req.write(json.encode({
        'server': server,
        'nick': nick,
        'account': account,
      }));
      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(_serverErrorMessage(
            resp.statusCode, text, 'Profile photo removal failed'));
      }

      var cacheKey = _avatarCacheKey(baseUrl, server, nick);
      _avatarCache.remove(cacheKey);
      _avatarChanges.add(ProfileAvatarChange(
        server: server,
        nick: nick,
        avatarUrl: null,
      ));
    } finally {
      client.close();
    }
  }

  Future<MediaUploadResult> uploadMedia({
    required String server,
    required String target,
    required String nick,
    required XFile file,
  }) async {
    var fileName = file.name.isEmpty
        ? 'media-${DateTime.now().millisecondsSinceEpoch}'
        : file.name;
    var contentType = file.mimeType ??
        lookupMimeType(fileName) ??
        _contentTypeFromName(fileName);
    if (!contentType.startsWith('image/') &&
        !contentType.startsWith('video/') &&
        !contentType.startsWith('audio/')) {
      throw Exception('Please select an image, video or audio');
    }

    var bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception('Selected media is empty');
    }
    if (bytes.length > 25 * 1024 * 1024) {
      throw Exception('File must be less than 25MB');
    }

    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/media/upload');
    var client = HttpClient();
    try {
      var req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json');
      req.write(json.encode({
        'server': server,
        'target': target,
        'nick': nick,
        'fileName': fileName,
        'contentType': contentType,
        'dataBase64': base64Encode(bytes),
      }));

      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(_uploadErrorMessage(resp.statusCode, text));
      }

      var data = json.decode(text);
      if (data is! Map) {
        throw Exception('Upload returned no media URL');
      }
      var savedUrl = _firstStringValue(data, const [
        'saved_url',
        'mediaUrl',
        'media_url',
        'fileUrl',
        'file_url',
        'url',
      ]);
      var media = data['media'];
      if ((savedUrl == null || savedUrl.isEmpty) && media is Map) {
        savedUrl = _firstStringValue(media, const [
          'saved_url',
          'mediaUrl',
          'media_url',
          'fileUrl',
          'file_url',
          'url',
        ]);
      }
      if (savedUrl == null || savedUrl.isEmpty) {
        throw Exception('Upload returned no media URL');
      }
      var mediaId = _firstStringValue(data, const ['media_id', 'mediaId']);
      var deleteToken =
          _firstStringValue(data, const ['delete_token', 'deleteToken']);
      if (mediaId == null || mediaId.isEmpty ||
          deleteToken == null || deleteToken.isEmpty) {
        throw Exception('Upload returned no media delete credentials');
      }
      var resolvedUrl = savedUrl;
      if (!savedUrl.startsWith('http://') &&
          !savedUrl.startsWith('https://')) {
        var publicBase = _publicBaseUrl();
        resolvedUrl = '$publicBase$savedUrl';
      }
      return MediaUploadResult(
        savedUrl: resolvedUrl,
        mediaId: mediaId,
        deleteToken: deleteToken,
        expiresAt: _firstStringValue(data, const ['expires_at', 'expiresAt']),
      );
    } finally {
      client.close();
    }
  }

  Future<void> deleteMedia({
    required String mediaId,
    required String deleteToken,
  }) async {
    var cleanId = mediaId.trim();
    var cleanToken = deleteToken.trim();
    if (cleanId.isEmpty || cleanToken.isEmpty) {
      throw Exception('Invalid media delete credential');
    }

    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/media/${Uri.encodeComponent(cleanId)}');
    var client = HttpClient();
    try {
      var req = await client.deleteUrl(uri);
      req.headers.set('Accept', 'application/json');
      req.headers.set('X-Media-Delete-Token', cleanToken);
      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if ((resp.statusCode < 200 || resp.statusCode > 299) &&
          resp.statusCode != HttpStatus.notFound) {
        throw Exception(
            _serverErrorMessage(resp.statusCode, text, 'Media removal failed'));
      }
    } finally {
      client.close();
    }
  }

  Future<CallRoomCreation> createCallRoom({
    required String server,
    required String target,
    required String nick,
    required String mode,
    String role = 'member',
  }) async {
    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/calls/create');
    var client = HttpClient();
    try {
      var req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json');
      req.write(json.encode({
        'server': server,
        'target': target,
        'nick': nick,
        'mode': mode,
        'role': role,
      }));

      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(
            _serverErrorMessage(resp.statusCode, text, 'Could not start call'));
      }

      var data = json.decode(text);
      var roomUrl = (data['room_url'] as String?)?.trim();
      if (roomUrl == null || roomUrl.isEmpty) {
        throw Exception('Call room returned no URL');
      }
      return CallRoomCreation(
        roomUrl: _resolveUrl(roomUrl),
        controlToken: data['creator_token'] as String? ?? '',
      );
    } finally {
      client.close();
    }
  }

  Future<CallPollResult> pollCallEvents({
    required String roomId,
    required String clientId,
    required int after,
  }) async {
    var uri = Uri.parse(
            '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/calls/$roomId/events')
        .replace(queryParameters: {
      'client': clientId,
      'after': after.toString(),
    });
    var client = HttpClient();
    try {
      var req = await client.getUrl(uri);
      req.headers.set('Accept', 'application/json');
      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(
            _serverErrorMessage(resp.statusCode, text, 'Could not read call'));
      }
      var data = json.decode(text);
      return CallPollResult.fromJson(
          data is Map<String, dynamic> ? data : <String, dynamic>{});
    } finally {
      client.close();
    }
  }

  Future<List<ActiveChannelCall>> fetchActiveChannelCalls({
    required String server,
    required String channel,
  }) async {
    var uri = Uri.parse(
            '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/calls/active')
        .replace(queryParameters: {
      'server': server,
      'target': channel,
    });
    var data = await _getJson(uri);
    var rawRooms = data['rooms'];
    if (rawRooms is! List) {
      return const [];
    }
    return rawRooms
        .whereType<Map<Object?, Object?>>()
        .map((item) {
          var room = Map<String, dynamic>.from(item);
          return ActiveChannelCall(
            room: CallRoom.fromJson(room),
            roomUrl: _resolveUrl(room['room_url'] as String? ?? ''),
          );
        })
        .where((call) => call.roomUrl.isNotEmpty)
        .toList();
  }

  Future<void> postCallEvent({
    required String roomId,
    required String clientId,
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    var uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/chat/calls/$roomId/events');
    var client = HttpClient();
    try {
      var req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json');
      req.write(json.encode({
        'client': clientId,
        'type': type,
        'payload': payload,
      }));

      var resp = await req.close();
      var text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        throw Exception(_serverErrorMessage(
            resp.statusCode, text, 'Could not update call'));
      }
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    var client = HttpClient();
    try {
      var req = await client.getUrl(uri);
      req.headers.set('Accept', 'application/json');
      var resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        return {};
      }
      var text = await resp.transform(utf8.decoder).join();
      var data = json.decode(text);
      return data is Map<String, dynamic> ? data : {};
    } on Object {
      return {};
    } finally {
      client.close();
    }
  }

  String _resolveUrl(String value) {
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    var cleanBase = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return value.startsWith('/') ? '$cleanBase$value' : '$cleanBase/$value';
  }

  String _publicBaseUrl() {
    var cleanBase = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    var uri = Uri.tryParse(cleanBase);
    if (uri == null || !uri.hasScheme) {
      return cleanBase;
    }
    return uri
        .replace(path: '', query: null, fragment: null)
        .toString()
        .replaceFirst(RegExp(r'/+$'), '');
  }

  String? _firstStringValue(Map<Object?, Object?> data, List<String> keys) {
    for (var key in keys) {
      var value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  String _contentTypeFromName(String fileName) {
    switch (fileName.split('.').last.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'm4a':
      case 'mp4a':
        return 'audio/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      default:
        return 'application/octet-stream';
    }
  }

  String _uploadErrorMessage(int code, String responseText) {
    return _serverErrorMessage(code, responseText, 'Media upload failed');
  }

  String _serverErrorMessage(
      int code, String responseText, String fallbackPrefix) {
    try {
      var data = json.decode(responseText);
      var serverMessage = (data['error'] as String?)?.trim();
      if (serverMessage != null && serverMessage.isNotEmpty) {
        return serverMessage;
      }
    } on Object {
      // Fall back to the HTTP status below.
    }
    return '$fallbackPrefix: $code';
  }

  static Future<void> _listenAvatarEvents(String baseUrl) async {
    while (true) {
      try {
        var uri = Uri.parse(
            '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/api/profile/events');
        var client = HttpClient();
        try {
          var req = await client.getUrl(uri);
          req.headers.set('Accept', 'text/event-stream');
          var resp = await req.close();
          if (resp.statusCode < 200 || resp.statusCode > 299) {
            await resp.drain<void>();
          } else {
            var eventName = '';
            var dataLines = <String>[];
            await for (var line
                in resp.transform(utf8.decoder).transform(LineSplitter())) {
              if (line.isEmpty) {
                if (eventName == 'avatar' && dataLines.isNotEmpty) {
                  _handleAvatarEvent(baseUrl, dataLines.join('\n'));
                }
                eventName = '';
                dataLines.clear();
                continue;
              }
              if (line.startsWith('event:')) {
                eventName = line.substring(6).trim();
              } else if (line.startsWith('data:')) {
                dataLines.add(line.substring(5).trimLeft());
              }
            }
          }
        } finally {
          client.close();
        }
      } on Object {
        // Reconnect below.
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  static void _handleAvatarEvent(String baseUrl, String raw) {
    try {
      var data = json.decode(raw);
      if (data is! Map) {
        return;
      }
      var server = (data['server'] as String?)?.trim() ?? '';
      var nick = (data['nick'] as String?)?.trim() ?? '';
      if (server.isEmpty || nick.isEmpty) {
        return;
      }
      var action = (data['action'] as String?)?.trim();
      var avatarUrl = (data['avatarUrl'] as String?)?.trim();
      if (action == 'delete' || avatarUrl == null || avatarUrl.isEmpty) {
        _removeAvatarCache(baseUrl: baseUrl, server: server, nick: nick);
        return;
      }
      var resolved = _versionAvatarUrl(
          ProfileBackendClient(baseUrl: baseUrl)._resolveUrl(avatarUrl),
          data['updatedAt']);
      _setAvatarCache(
        baseUrl: baseUrl,
        server: server,
        nick: nick,
        avatarUrl: resolved,
      );
    } on Object {
      // Ignore malformed events.
    }
  }

  static void _setAvatarCache({
    required String baseUrl,
    required String server,
    required String nick,
    required String avatarUrl,
  }) {
    _avatarCache[_avatarCacheKey(baseUrl, server, nick)] = avatarUrl;
    _avatarChanges.add(ProfileAvatarChange(
      server: server,
      nick: nick,
      avatarUrl: avatarUrl,
    ));
  }

  static void _removeAvatarCache({
    required String baseUrl,
    required String server,
    required String nick,
  }) {
    _avatarCache.remove(_avatarCacheKey(baseUrl, server, nick));
    _avatarChanges.add(ProfileAvatarChange(
      server: server,
      nick: nick,
      avatarUrl: null,
    ));
  }
}

class ProfileAvatarChange {
  final String server;
  final String nick;
  final String? avatarUrl;

  const ProfileAvatarChange({
    required this.server,
    required this.nick,
    required this.avatarUrl,
  });
}

class MediaUploadResult {
  final String savedUrl;
  final String mediaId;
  final String deleteToken;
  final String? expiresAt;

  const MediaUploadResult({
    required this.savedUrl,
    required this.mediaId,
    required this.deleteToken,
    this.expiresAt,
  });
}

class CallRoomCreation {
  final String roomUrl;
  final String controlToken;

  const CallRoomCreation({
    required this.roomUrl,
    required this.controlToken,
  });
}

class ActiveChannelCall {
  final CallRoom room;
  final String roomUrl;

  const ActiveChannelCall({
    required this.room,
    required this.roomUrl,
  });
}

String _avatarCacheKey(String baseUrl, String server, String nick) =>
    '${baseUrl.toLowerCase()}|${server.toLowerCase()}|${nick.toLowerCase()}';

String _versionAvatarUrl(String url, Object? version) {
  var clean = version?.toString().trim();
  if (clean == null || clean.isEmpty) {
    return url;
  }
  var uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return url;
  }
  var params = Map<String, String>.from(uri.queryParameters);
  params['v'] = clean;
  return uri.replace(queryParameters: params).toString();
}

String? callRoomIdFromUrl(String value) {
  var uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  var segments = uri.pathSegments;
  if (segments.length < 2 || segments[segments.length - 2] != 'call') {
    return null;
  }
  var roomId = segments.last;
  return RegExp(r'^[a-f0-9]{32}$').hasMatch(roomId) ? roomId : null;
}

class CallRoom {
  final String id;
  final String mode;
  final String target;
  final String createdBy;
  final bool channel;
  final bool ended;
  final List<CallParticipant> participants;
  final List<Map<String, dynamic>> iceServers;

  const CallRoom({
    required this.id,
    required this.mode,
    required this.target,
    required this.createdBy,
    required this.channel,
    required this.ended,
    required this.participants,
    required this.iceServers,
  });

  bool get video => mode == 'video';

  factory CallRoom.fromJson(Map<String, dynamic> data) {
    var rawIceServers = data['iceServers'];
    var iceServers = <Map<String, dynamic>>[];
    if (rawIceServers is List) {
      for (var item in rawIceServers) {
        if (item is Map) {
          iceServers.add(Map<String, dynamic>.from(item));
        }
      }
    }
    var participants = <CallParticipant>[];
    var rawParticipants = data['participants'];
    if (rawParticipants is List) {
      for (var item in rawParticipants.whereType<Map<Object?, Object?>>()) {
        participants
            .add(CallParticipant.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    return CallRoom(
      id: data['id'] as String? ?? '',
      mode: data['mode'] as String? ?? 'audio',
      target: data['target'] as String? ?? '',
      createdBy: data['createdBy'] as String? ?? '',
      channel: data['channel'] == true,
      ended: data['ended'] == true,
      participants: participants,
      iceServers: iceServers,
    );
  }
}

class CallParticipant {
  final String client;
  final String nick;
  final String role;
  final bool muted;
  final bool cameraOff;

  const CallParticipant({
    required this.client,
    required this.nick,
    required this.role,
    required this.muted,
    required this.cameraOff,
  });

  bool get canModerate => role == 'creator' || role == 'irc_operator';

  factory CallParticipant.fromJson(Map<String, dynamic> data) {
    return CallParticipant(
      client: data['client'] as String? ?? '',
      nick: data['nick'] as String? ?? '',
      role: data['role'] as String? ?? 'member',
      muted: data['muted'] == true,
      cameraOff: data['cameraOff'] == true,
    );
  }
}

class CallEvent {
  final int seq;
  final String client;
  final String type;
  final Map<String, dynamic> payload;

  const CallEvent({
    required this.seq,
    required this.client,
    required this.type,
    required this.payload,
  });

  factory CallEvent.fromJson(Map<String, dynamic> data) {
    var payload = data['payload'];
    return CallEvent(
      seq: data['seq'] as int? ?? 0,
      client: data['client'] as String? ?? '',
      type: data['type'] as String? ?? '',
      payload: payload is Map ? Map<String, dynamic>.from(payload) : {},
    );
  }
}

class CallPollResult {
  final CallRoom room;
  final List<CallEvent> events;
  final int nextSeq;

  const CallPollResult({
    required this.room,
    required this.events,
    required this.nextSeq,
  });

  factory CallPollResult.fromJson(Map<String, dynamic> data) {
    var rawRoom = data['room'];
    var rawEvents = data['events'];
    return CallPollResult(
      room: CallRoom.fromJson(rawRoom is Map<Object?, Object?>
          ? Map<String, dynamic>.from(rawRoom)
          : {}),
      events: rawEvents is List
          ? rawEvents
              .whereType<Map<Object?, Object?>>()
              .map(
                  (item) => CallEvent.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : [],
      nextSeq: data['next_seq'] as int? ?? 0,
    );
  }
}
