import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../cached_network_image.dart';
import '../profile_backend.dart';

class ProfileAvatar extends StatefulWidget {
  final String name;
  final String? avatarUrl;
  final Uint8List? avatarBytes;
  final double size;
  final bool showOnlineIndicator;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const ProfileAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.avatarBytes,
    this.size = 40,
    this.showOnlineIndicator = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  late ValueNotifier<String?> _avatarNotifier;
  String? _liveAvatarUrl;

  @override
  void initState() {
    super.initState();
    _liveAvatarUrl = widget.avatarUrl;
    _avatarNotifier = _ProfileAvatarUpdates.forNick(widget.name);
    _avatarNotifier.addListener(_handleAvatarChanged);
  }

  @override
  void didUpdateWidget(ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _avatarNotifier.removeListener(_handleAvatarChanged);
      _avatarNotifier = _ProfileAvatarUpdates.forNick(widget.name);
      _avatarNotifier.addListener(_handleAvatarChanged);
    }
    if (oldWidget.name != widget.name ||
        oldWidget.avatarUrl != widget.avatarUrl) {
      _liveAvatarUrl = widget.avatarUrl;
    }
  }

  @override
  void dispose() {
    _avatarNotifier.removeListener(_handleAvatarChanged);
    super.dispose();
  }

  void _handleAvatarChanged() {
    if (!mounted || _liveAvatarUrl == _avatarNotifier.value) {
      return;
    }
    setState(() {
      _liveAvatarUrl = _avatarNotifier.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var cleanUrl = _liveAvatarUrl?.trim();
    if (cleanUrl != null && cleanUrl.isEmpty) {
      cleanUrl = null;
    }
    var cleanBytes = widget.avatarBytes;
    if (cleanBytes != null && cleanBytes.isEmpty) {
      cleanBytes = null;
    }
    var bg = widget.backgroundColor ?? scheme.surfaceContainer;
    var fg = widget.foregroundColor ?? scheme.onSurface;
    var imageSize =
        (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
    ImageProvider? imageProvider;
    if (cleanBytes != null) {
      imageProvider = MemoryImage(cleanBytes);
    } else if (cleanUrl != null) {
      imageProvider = CachedNetworkImage(cleanUrl);
    }

    Widget avatar = ClipOval(
      child: Container(
        width: widget.size,
        height: widget.size,
        color: bg,
        child: imageProvider == null
            ? _AvatarFallback(name: widget.name, color: fg)
            : Image(
                image: ResizeImage.resizeIfNeeded(
                    imageSize, imageSize, imageProvider),
                fit: BoxFit.cover,
                width: widget.size,
                height: widget.size,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    return child;
                  }
                  return _AvatarFallback(name: widget.name, color: fg);
                },
                errorBuilder: (context, error, stackTrace) {
                  return _AvatarFallback(name: widget.name, color: fg);
                },
              ),
      ),
    );

    if (!widget.showOnlineIndicator) {
      return avatar;
    }

    var dotSize = (widget.size * 0.26).clamp(8.0, 12.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(children: [
        avatar,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: Color(0xFF22C55E),
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ProfileAvatarUpdates {
  static final Map<String, ValueNotifier<String?>> _notifiers = {};
  static StreamSubscription<ProfileAvatarChange>? _subscription;

  static ValueNotifier<String?> forNick(String nick) {
    _subscription ??=
        ProfileBackendClient.avatarChanges.listen(_handleAvatarChanged);
    return _notifiers.putIfAbsent(
      nick.toLowerCase(),
      () => ValueNotifier<String?>(null),
    );
  }

  static void _handleAvatarChanged(ProfileAvatarChange change) {
    var notifier = _notifiers[change.nick.toLowerCase()];
    if (notifier != null && notifier.value != change.avatarUrl) {
      notifier.value = change.avatarUrl;
    }
  }
}

class _AvatarFallback extends StatelessWidget {
  final String name;
  final Color color;

  const _AvatarFallback({
    required this.name,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        _initials(name),
        semanticsLabel: '',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
        maxLines: 1,
      ),
    );
  }
}

String _initials(String name) {
  for (var r in name.runes) {
    var ch = String.fromCharCode(r);
    if (ch == '#') {
      continue;
    }
    return ch.toUpperCase();
  }
  return '';
}
