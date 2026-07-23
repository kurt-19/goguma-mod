import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const _bufferCompactKey = 'buffer_compact';
const _typingIndicatorKey = 'typing_indicator';
const _nicknameKey = 'nickname';
const _realnameKey = 'realname';
const _pushProviderKey = 'push_provider';
const _linkPreviewKey = 'link_preview';
const _linkExtAppKey = 'link_external_app';
const _recentReactionsKey = 'recent_reactions';
const _uploadErrorReportsKey = 'upload_error_reports';
const _chatTextColorKey = 'chat_text_color';
const _quitRequestedKey = 'quit_requested';
const _mediaDeleteCredentialsKey = 'media_delete_credentials';

const _maxRecentReactions = 14;
const _maxMediaDeleteCredentials = 200;

class Prefs {
  final SharedPreferences _prefs;

  Prefs._(this._prefs);

  static Future<Prefs> load() async {
    return Prefs._(await SharedPreferences.getInstance());
  }

  bool get bufferCompact => _prefs.getBool(_bufferCompactKey) ?? false;
  bool get typingIndicator => true;
  String get nickname => _prefs.getString(_nicknameKey) ?? 'user';
  String? get realname => _prefs.getString(_realnameKey);
  String? get pushProvider => _prefs.getString(_pushProviderKey);
  bool get linkPreview => _prefs.getBool(_linkPreviewKey) ?? true;
  bool get linkExtApp => _prefs.getBool(_linkExtAppKey) ?? false;
  List<String> get recentReactions =>
      _prefs.getStringList(_recentReactionsKey) ?? [];
  bool get uploadErrorReports => _prefs.getBool(_uploadErrorReportsKey) ?? true;
  String get chatTextColor => _prefs.getString(_chatTextColorKey) ?? '';
  bool get quitRequested => _prefs.getBool(_quitRequestedKey) ?? false;

  List<MediaDeleteCredential> mediaDeleteCredentialsInText(String text) {
    var stored = _readMediaDeleteCredentials();
    var result = <MediaDeleteCredential>[];
    var seen = <String>{};
    var urlPattern = RegExp(r'https?://[^\s]+', caseSensitive: false);
    var trailingPunctuation = RegExp(r'[.,!;:)\]}>]+$');

    for (var match in urlPattern.allMatches(text)) {
      var rawUrl = match.group(0)!;
      var candidates = <String>{
        rawUrl,
        rawUrl.replaceFirst(trailingPunctuation, ''),
      };
      for (var candidate in candidates) {
        var key = _mediaUrlKey(candidate);
        if (key == null || !seen.add(key)) {
          continue;
        }
        var credential =
            MediaDeleteCredential.fromStored(key, stored[key]);
        if (credential != null && !credential.isExpired) {
          result.add(credential);
        }
      }
    }
    return result;
  }

  Future<void> rememberMediaDeleteCredential({
    required String url,
    required String mediaId,
    required String deleteToken,
    String? expiresAt,
  }) async {
    var key = _mediaUrlKey(url);
    var cleanId = mediaId.trim();
    var cleanToken = deleteToken.trim();
    if (key == null ||
        cleanId.isEmpty ||
        cleanId.length > 512 ||
        cleanToken.isEmpty ||
        cleanToken.length > 4096) {
      throw Exception('Invalid media delete credential');
    }

    var stored = _readMediaDeleteCredentials();
    stored.removeWhere((storedUrl, value) {
      var credential = MediaDeleteCredential.fromStored(storedUrl, value);
      return credential == null || credential.isExpired;
    });
    stored.remove(key);
    stored[key] = {
      'media_id': cleanId,
      'delete_token': cleanToken,
      if (expiresAt != null && expiresAt.trim().isNotEmpty)
        'expires_at': expiresAt.trim(),
      'saved_at': DateTime.now().toUtc().toIso8601String(),
    };
    while (stored.length > _maxMediaDeleteCredentials) {
      stored.remove(stored.keys.first);
    }

    var saved =
        await _prefs.setString(_mediaDeleteCredentialsKey, json.encode(stored));
    if (!saved) {
      throw Exception('Could not save media delete credential');
    }
  }

  Future<void> forgetMediaDeleteCredential(String url) async {
    var key = _mediaUrlKey(url);
    if (key == null) {
      return;
    }
    var stored = _readMediaDeleteCredentials();
    if (stored.remove(key) == null) {
      return;
    }
    if (stored.isEmpty) {
      await _prefs.remove(_mediaDeleteCredentialsKey);
    } else {
      await _prefs.setString(
          _mediaDeleteCredentialsKey, json.encode(stored));
    }
  }

  Map<String, dynamic> _readMediaDeleteCredentials() {
    var raw = _prefs.getString(_mediaDeleteCredentialsKey);
    if (raw == null || raw.isEmpty) {
      return {};
    }
    try {
      var decoded = json.decode(raw);
      if (decoded is Map) {
        return decoded.map(
            (key, value) => MapEntry(key.toString(), value));
      }
    } on Object {
      // Ignore malformed local data and start with an empty credential map.
    }
    return {};
  }

  set bufferCompact(bool enabled) {
    _prefs.setBool(_bufferCompactKey, enabled);
  }

  set typingIndicator(bool enabled) {
    if (enabled) {
      _prefs.setBool(_typingIndicatorKey, true);
    } else {
      _prefs.remove(_typingIndicatorKey);
    }
  }

  set nickname(String nickname) {
    _prefs.setString(_nicknameKey, nickname);
  }

  void _setOptionalString(String k, String? v) {
    if (v != null) {
      _prefs.setString(k, v);
    } else {
      _prefs.remove(k);
    }
  }

  set realname(String? realname) {
    _setOptionalString(_realnameKey, realname);
  }

  set pushProvider(String? provider) {
    _setOptionalString(_pushProviderKey, provider);
  }

  set linkPreview(bool enabled) {
    _prefs.setBool(_linkPreviewKey, enabled);
  }

  set linkExtApp(bool enabled) {
    _prefs.setBool(_linkExtAppKey, enabled);
  }

  void addRecentReaction(String reaction) {
    var reactions = [
      reaction,
      ...recentReactions
          .where((r) => r != reaction)
          .take(_maxRecentReactions - 1)
    ];
    _prefs.setStringList(_recentReactionsKey, reactions);
  }

  set uploadErrorReports(bool enabled) {
    _prefs.setBool(_uploadErrorReportsKey, enabled);
  }

  set chatTextColor(String color) {
    var value = color.trim().toUpperCase();
    if (value.isEmpty) {
      _prefs.remove(_chatTextColorKey);
    } else {
      _prefs.setString(_chatTextColorKey, value);
    }
  }

  set quitRequested(bool quitRequested) {
    if (quitRequested) {
      _prefs.setBool(_quitRequestedKey, true);
    } else {
      _prefs.remove(_quitRequestedKey);
    }
  }
}

class MediaDeleteCredential {
  final String url;
  final String mediaId;
  final String deleteToken;
  final String? expiresAt;

  const MediaDeleteCredential({
    required this.url,
    required this.mediaId,
    required this.deleteToken,
    this.expiresAt,
  });

  bool get isExpired {
    var value = expiresAt;
    if (value == null || value.isEmpty) {
      return false;
    }
    var expiry = DateTime.tryParse(value);
    return expiry != null && !expiry.isAfter(DateTime.now());
  }

  static MediaDeleteCredential? fromStored(String url, Object? value) {
    if (value is! Map) {
      return null;
    }
    var mediaId = value['media_id'];
    var deleteToken = value['delete_token'];
    if (mediaId is! String ||
        mediaId.trim().isEmpty ||
        deleteToken is! String ||
        deleteToken.trim().isEmpty) {
      return null;
    }
    var expiresAt = value['expires_at'];
    return MediaDeleteCredential(
      url: url,
      mediaId: mediaId.trim(),
      deleteToken: deleteToken.trim(),
      expiresAt: expiresAt is String ? expiresAt.trim() : null,
    );
  }
}

String? _mediaUrlKey(String value) {
  var uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.replace(fragment: null).toString();
}
