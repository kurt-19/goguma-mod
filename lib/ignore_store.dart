import 'package:shared_preferences/shared_preferences.dart';

const _ignoredNicksKey = 'ignored_nicks';

Future<List<String>> loadIgnoredNicks() async {
  var prefs = await SharedPreferences.getInstance();
  var nicks = prefs.getStringList(_ignoredNicksKey) ?? const [];
  return _normalizeIgnoredNicks(nicks);
}

Future<void> saveIgnoredNicks(Iterable<String> nicks) async {
  var prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_ignoredNicksKey, _normalizeIgnoredNicks(nicks));
}

List<String> _normalizeIgnoredNicks(Iterable<String> nicks) {
  var byLower = <String, String>{};
  for (var nick in nicks) {
    var clean = nick.trim();
    if (clean.isNotEmpty) {
      byLower[clean.toLowerCase()] = clean;
    }
  }
  var normalized = byLower.values.toList();
  normalized.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return normalized;
}
