import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

final List<TopRightSnackBarController> _activeSnackBars = [];
var _showTopRightSnackBars = false;

class TopRightSnackBarController {
  TopRightSnackBarController._(this._entry, this._timer);

  final OverlayEntry? _entry;
  final Timer? _timer;
  final _closed = Completer<void>();
  bool _isClosed = false;

  Future<void> get closed => _closed.future;

  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _timer?.cancel();
    _activeSnackBars.remove(this);
    _entry?.remove();
    for (var controller in _activeSnackBars) {
      controller._entry?.markNeedsBuild();
    }
    _closed.complete();
  }
}

TopRightSnackBarController showTopRightSnackBar(
  BuildContext context,
  SnackBar snackBar, {
  OverlayState? overlay,
}) {
  if (!_showTopRightSnackBars) {
    var controller = TopRightSnackBarController._(null, null);
    controller.close();
    return controller;
  }

  overlay ??= Overlay.of(context, rootOverlay: true);
  late TopRightSnackBarController controller;
  var timer = Timer(snackBar.duration, () => controller.close());
  var entry = OverlayEntry(
    builder: (context) => _TopRightSnackBar(
      snackBar: snackBar,
      index: _activeSnackBars.indexOf(controller),
      onClose: controller.close,
    ),
  );
  controller = TopRightSnackBarController._(entry, timer);
  _activeSnackBars.add(controller);
  overlay.insert(entry);
  return controller;
}

class _TopRightSnackBar extends StatelessWidget {
  final SnackBar snackBar;
  final int index;
  final VoidCallback onClose;

  const _TopRightSnackBar({
    required this.snackBar,
    required this.index,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var scheme = theme.colorScheme;
    var snackTheme = theme.snackBarTheme;
    var width = math.min(MediaQuery.sizeOf(context).width - 24, 380.0);
    var top = MediaQuery.paddingOf(context).top + 12 + math.max(index, 0) * 96;
    var background = snackBar.backgroundColor ??
        snackTheme.backgroundColor ??
        scheme.surface;
    var textStyle = snackTheme.contentTextStyle ??
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface);
    var action = snackBar.action;

    return Positioned(
      top: top,
      right: 12,
      child: SafeArea(
        child: Material(
          color: background,
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: 16,
                top: 12,
                end: action == null ? 16 : 8,
                bottom: 12,
              ),
              child: DefaultTextStyle(
                style: textStyle ?? const TextStyle(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 64),
                        child: SingleChildScrollView(child: snackBar.content),
                      ),
                    ),
                    if (action != null) ...[
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () {
                          action.onPressed();
                          onClose();
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: action.textColor ?? scheme.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: Text(action.label),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
