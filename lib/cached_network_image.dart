import 'dart:async';
import 'dart:convert' show utf8, base64;
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'logging.dart';

class CachedNetworkImage extends ImageProvider<CachedNetworkImage> {
  final String url;

  const CachedNetworkImage(this.url);

  static final _httpClient = HttpClient();
  static final _rawFetches = <String, Future<Uint8List>>{};

  @override
  Future<CachedNetworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
      CachedNetworkImage key, ImageDecoderCallback decode) {
    var chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode, chunkEvents),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<Codec> _loadAsync(ImageDecoderCallback decode,
      StreamController<ImageChunkEvent> chunkEvents) async {
    try {
      var raw = await _fetchShared(Uri.base.resolve(url), chunkEvents);
      return decode(await ImmutableBuffer.fromUint8List(raw));
    } finally {
      await chunkEvents.close();
    }
  }

  Future<Uint8List> _fetchShared(
      Uri uri, StreamController<ImageChunkEvent> chunkEvents) {
    var key = uri.toString();
    var pending = _rawFetches[key];
    if (pending != null) {
      return pending;
    }
    var future = _fetch(uri, chunkEvents);
    _rawFetches[key] = future;
    future.whenComplete(() {
      if (identical(_rawFetches[key], future)) {
        _rawFetches.remove(key);
      }
    });
    return future;
  }

  Future<Uint8List> _fetch(
      Uri uri, StreamController<ImageChunkEvent> chunkEvents) async {
    var rootDir = await _getRootDir();
    var key = _hashKey(uri.toString());
    var entryDir = Directory(path.join(rootDir.path, key));

    // We keep a marker to indicate the timestamp of the last HTTP request
    // via the file's last modified date
    var lastCheckFile = File(path.join(entryDir.path, '.last-check'));
    var cachedFile = await _findLatestBlob(entryDir);
    var cachedMetadata = cachedFile != null
        ? _HttpCacheMetadata.parse(path.basename(cachedFile.path))
        : null;

    if (cachedFile != null) {
      var expires = cachedMetadata?.expires;
      if (expires == null) {
        try {
          var lastCheck = await lastCheckFile.lastModified();
          expires = lastCheck.add(Duration(days: 7));
        } on PathNotFoundException {
          // ignore
        }
      }
      if (expires != null && expires.isAfter(DateTime.now())) {
        return cachedFile.readAsBytes();
      }
    }

    var req = await _httpClient.getUrl(uri);
    if (cachedMetadata?.lastModified != null) {
      req.headers.ifModifiedSince = cachedMetadata!.lastModified;
    }
    if (cachedMetadata?.etag != null) {
      req.headers.set(HttpHeaders.ifNoneMatchHeader, cachedMetadata!.etag!);
    }
    var resp = await req.close();
    if (resp.statusCode == HttpStatus.notModified && cachedFile != null) {
      var newCacheMetadata = _HttpCacheMetadata.fromHeaders(resp.headers);
      if (newCacheMetadata != null &&
          cachedMetadata!.toString() != newCacheMetadata.toString()) {
        cachedFile = await cachedFile
            .rename(path.join(entryDir.path, newCacheMetadata.toString()));
      }

      await lastCheckFile.writeAsString('');

      return cachedFile.readAsBytes();
    }
    if (resp.statusCode != HttpStatus.ok) {
      throw NetworkImageLoadException(statusCode: resp.statusCode, uri: uri);
    }

    var buf = await _readResponse(resp, chunkEvents);

    try {
      await entryDir.delete(recursive: true);
    } on PathNotFoundException {
      // ignore
    }

    var newCacheMetadata = _HttpCacheMetadata.fromHeaders(resp.headers);
    if (newCacheMetadata != null) {
      await entryDir.create(recursive: true);
      var newCacheFile =
          File(path.join(entryDir.path, newCacheMetadata.toString()));
      await newCacheFile.writeAsBytes(buf);
      await lastCheckFile.writeAsString('');
    }

    return buf;
  }

  Future<Uint8List> _readResponse(HttpClientResponse resp,
      StreamController<ImageChunkEvent> chunkEvents) async {
    int? total = resp.contentLength;
    if (total == -1) {
      total = null;
    }
    if (resp.compressionState ==
        HttpClientResponseCompressionState.decompressed) {
      total = null;
    }

    var chunks = <List<int>>[];
    var cumulative = 0;
    await for (var chunk in resp) {
      chunks.add(chunk);
      cumulative += chunk.length;
      chunkEvents.add(ImageChunkEvent(
        cumulativeBytesLoaded: cumulative,
        expectedTotalBytes: total,
      ));
    }

    var buf = Uint8List(cumulative);
    var offset = 0;
    for (var chunk in chunks) {
      buf.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return buf;
  }

  @override
  bool operator ==(Object other) {
    return other is CachedNetworkImage && other.url == url;
  }

  @override
  int get hashCode => url.hashCode;
}

void pruneNetworkImageCache() async {
  var rootDir = await _getRootDir();

  var lastScanFile = File(path.join(rootDir.path, '.last-scan'));
  DateTime? dueDate;
  try {
    var lastScan = await lastScanFile.lastModified();
    dueDate = lastScan.add(Duration(days: 7));
  } on PathNotFoundException {
    // ignore
  }
  if (dueDate != null && DateTime.now().isBefore(dueDate)) {
    return;
  }

  var start = DateTime.now();
  log.print('Started cached network image cleanup');

  await rootDir.create(recursive: true);

  var tooOld = DateTime.now().subtract(Duration(days: 30));
  var total = 0;
  var deleted = 0;
  await for (var entry in rootDir.list()) {
    if (path.basename(entry.path).startsWith('.')) {
      continue;
    }

    var lastCheckFile = File(path.join(entry.path, '.last-check'));
    DateTime? lastCheck;
    try {
      lastCheck = await lastCheckFile.lastModified();
    } on PathNotFoundException {
      // ignore
    }

    if (lastCheck == null || lastCheck.isBefore(tooOld)) {
      await entry.delete(recursive: true);
      deleted++;
    }

    total++;
  }

  await lastScanFile.writeAsString('');

  var ellapsed = DateTime.now().difference(start);
  log.print(
      'Finished cached network image cleanup (took $ellapsed, scanned $total entries, deleted $deleted entries)');
}

Future<File?> _findLatestBlob(Directory entryDir) async {
  try {
    await for (var file in entryDir.list()) {
      if (!path.basename(file.path).startsWith('.') && file is File) {
        return file;
      }
    }
  } on PathNotFoundException {
    // ignore
  }
  return null;
}

Directory? _cacheDir;

Future<Directory> _getRootDir() async {
  if (_cacheDir == null) {
    var dir = await getApplicationCacheDirectory();
    _cacheDir = dir;
  }
  return Directory(path.join(_cacheDir!.path, 'http'));
}

String _hashKey(String key) {
  return sha256.convert(utf8.encode(key)).toString();
}

class _HttpCacheMetadata {
  final DateTime? lastModified;
  final DateTime? expires;
  final String? etag;

  const _HttpCacheMetadata({this.lastModified, this.expires, this.etag});

  static _HttpCacheMetadata? fromHeaders(HttpHeaders headers) {
    var rawLastModified = headers.value(HttpHeaders.lastModifiedHeader);
    DateTime? lastModified;
    if (rawLastModified != null) {
      try {
        lastModified = HttpDate.parse(rawLastModified);
      } on HttpException {
        // ignore
      }
    }

    var expires = headers.expires;

    for (var rawCacheControl
        in headers[HttpHeaders.cacheControlHeader] ?? <String>[]) {
      var cacheControl = _HttpCacheControl.parse(rawCacheControl);
      if (cacheControl.noStore) {
        return null;
      }
      if (cacheControl.maxAge != null) {
        // Cache-Control's max-age is preferred over Expires
        expires = DateTime.now().add(cacheControl.maxAge!);
      }
      if (cacheControl.noCache) {
        // no-cache is preferred over max-age and means that we always
        // need to recheck the file with an HTTP request. We still
        // cache the file for 304 Not Modified.
        expires = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    return _HttpCacheMetadata(
      lastModified: lastModified,
      expires: expires,
      etag: headers.value(HttpHeaders.etagHeader),
    );
  }

  static _HttpCacheMetadata parse(String raw) {
    var fields = raw.split('-');
    if (fields.length < 3) {
      throw FormatException('Malformed HTTP cache metadata');
    }

    return _HttpCacheMetadata(
      lastModified: fields[0] != ''
          ? DateTime.fromMillisecondsSinceEpoch(int.parse(fields[0]))
          : null,
      expires: fields[1] != ''
          ? DateTime.fromMillisecondsSinceEpoch(int.parse(fields[1]))
          : null,
      etag: fields[2] != '' ? utf8.decode(base64.decode(fields[2])) : null,
    );
  }

  @override
  String toString() {
    return [
      lastModified != null
          ? lastModified!.millisecondsSinceEpoch.toString()
          : '',
      expires != null ? expires!.millisecondsSinceEpoch.toString() : '',
      // Note, filenames are usually restricted to 255 bytes
      etag != null && etag!.length <= 128
          ? base64.encode(utf8.encode(etag!))
          : '',
    ].join('-');
  }
}

class _HttpCacheControl {
  final bool noCache;
  final bool noStore;
  final Duration? maxAge;

  const _HttpCacheControl(
      {this.noCache = false, this.noStore = false, this.maxAge});

  static _HttpCacheControl parse(String raw) {
    var noCache = false;
    var noStore = false;
    Duration? maxAge;
    for (var directive in raw.split(',')) {
      var parts = directive.split('=');
      var key = parts[0].trim().toLowerCase();
      var value = parts.length > 1 ? parts[1].trim() : null;

      switch (key) {
        case 'no-cache':
          noCache = true;
          break;
        case 'no-store':
          noStore = true;
          break;
        case 'max-age':
          var sec = value != null ? int.tryParse(value) : null;
          maxAge = sec != null ? Duration(seconds: sec) : null;
          break;
      }
    }

    return _HttpCacheControl(
        noCache: noCache, noStore: noStore, maxAge: maxAge);
  }
}
