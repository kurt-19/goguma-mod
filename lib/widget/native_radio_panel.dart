import 'package:flutter/material.dart';

import '../native_radio.dart';

class NativeRadioPanel extends StatefulWidget {
  const NativeRadioPanel({super.key});

  @override
  State<NativeRadioPanel> createState() => _NativeRadioPanelState();
}

class _NativeRadioPanelState extends State<NativeRadioPanel> {
  @override
  void initState() {
    super.initState();
    NativeRadioPlayback.changes.addListener(_handleRadioChange);
  }

  @override
  void dispose() {
    NativeRadioPlayback.changes.removeListener(_handleRadioChange);
    super.dispose();
  }

  void _handleRadioChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var station = NativeRadioPlayback.station;
    var isPlaying = NativeRadioPlayback.isPlaying;
    var status = NativeRadioPlayback.status;
    var isActive = isPlaying || status == 'Connecting' || status == 'Switching';
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isPlaying ? scheme.secondary : scheme.outline,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 7),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Radio',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${station.name} / $status',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              )),
            ]),
            SizedBox(height: 7),
            Row(children: [
              _RadioIconButton(
                tooltip: isActive ? 'Stop radio' : 'Play radio',
                icon: isActive ? Icons.stop : Icons.play_arrow,
                onPressed: () {
                  if (isActive) {
                    NativeRadioPlayback.stop();
                  } else {
                    NativeRadioPlayback.play();
                  }
                },
              ),
              SizedBox(width: 6),
              _RadioIconButton(
                tooltip: 'Restart radio',
                icon: Icons.refresh,
                onPressed: () => NativeRadioPlayback.play(restart: true),
              ),
              SizedBox(width: 6),
              _RadioIconButton(
                tooltip: 'Stop radio',
                icon: Icons.close,
                onPressed: NativeRadioPlayback.stop,
              ),
              SizedBox(width: 6),
              TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  minimumSize: Size(0, 32),
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: NativeRadioPlayback.next,
                child: Text('Next', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _RadioIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _RadioIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        color: Color(0xFFF5F7FB),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
