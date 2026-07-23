import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../logging.dart';
import '../models.dart';
import '../native_foreground.dart';
import '../notification_controller.dart';
import '../prefs.dart';
import '../profile_backend.dart';
import '../widget/app_snack_bar.dart';
import '../widget/profile_avatar.dart';
import 'connect.dart';

const _activityChannel = MethodChannel('com.ircmobile.app/activity');

class SettingsPage extends StatefulWidget {
  static const routeName = '/settings';

  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _compact;
  late bool _typing;
  late bool _linkPreview;
  late bool _linkExtApp;
  late bool _uploadErrorReports;
  late String _chatTextColor;
  late String? _uploadErrorReportsHost;
  bool _supportsInAppBrowserView = true;
  String? _profileAvatar;
  String? _profileAvatarKey;
  Uint8List? _profileAvatarPreview;
  bool _profileAvatarUploading = false;
  bool _profileAvatarRemoving = false;

  @override
  void initState() {
    super.initState();

    var prefs = context.read<Prefs>();
    _compact = prefs.bufferCompact;
    _typing = true;
    _linkPreview = prefs.linkPreview;
    _linkExtApp = prefs.linkExtApp;
    _uploadErrorReports = prefs.uploadErrorReports;
    _chatTextColor = prefs.chatTextColor;
    _uploadErrorReportsHost = log.sentryHost;

    unawaited(() async {
      var supportsInAppBrowserView =
          await supportsLaunchMode(LaunchMode.inAppBrowserView);
      if (!mounted) {
        return;
      }
      setState(() {
        _supportsInAppBrowserView = supportsInAppBrowserView;
      });
    }());
  }

  void _showLogoutDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Quit'),
        content: Text('Disconnect, clear notifications, and close the app?'),
        actions: [
          TextButton(
            child: Text('CANCEL'),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
          ElevatedButton(
            child: Text('QUIT'),
            onPressed: () {
              Navigator.pop(context);
              _quitApp();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _quitApp() async {
    var clientProvider = context.read<ClientProvider>();
    var notifController = context.read<NotificationController>();
    var db = context.read<DB>();
    var prefs = context.read<Prefs>();
    var navigator = Navigator.of(context);

    try {
      notifController.leaveMainApp();
      prefs.quitRequested = true;
      await clientProvider.shutdownForExit();
      await notifController.dismissAll();
      await db.clearConnectionState();
      clientProvider.clear();
      if (mounted) {
        unawaited(navigator.pushNamedAndRemoveUntil(
            ConnectPage.routeName, (route) => false));
      }
      await NativeForegroundService.quitApp();
    } on Exception catch (err) {
      log.print('Failed to quit cleanly', error: err);
    }
  }

  void _showChatTextColorDialog() {
    const palette = [
      '#000000',
      '#111827',
      '#1F2937',
      '#334155',
      '#F8FAFC',
      '#E2E8F0',
      '#CBD5E1',
      '#94A3B8',
      '#B9D6FF',
      '#93C5FD',
      '#60A5FA',
      '#38BDF8',
      '#7DD3FC',
      '#67E8F9',
      '#5EEAD4',
      '#2DD4BF',
      '#A7F3D0',
      '#86EFAC',
      '#4ADE80',
      '#22C55E',
      '#FDE68A',
      '#FACC15',
      '#FDBA74',
      '#FB923C',
      '#FDA4AF',
      '#FB7185',
      '#F472B6',
      '#EC4899',
      '#F0ABFC',
      '#D946EF',
      '#C4B5FD',
      '#A78BFA',
      '#818CF8',
      '#6366F1',
      '#FFB86B',
      '#FF6B6B',
    ];
    var selected = _chatTextColor;
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('Chat text color'),
            content: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: palette.map((hex) {
                var color =
                    Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
                var active = selected.toUpperCase() == hex;
                return InkResponse(
                  onTap: () {
                    setDialogState(() => selected = hex);
                  },
                  radius: 18,
                  child: Container(
                    width: active ? 28 : 24,
                    height: active ? 28 : 24,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white24,
                        width: active ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            actions: [
              TextButton(
                child: Text('DEFAULT'),
                onPressed: () {
                  context.read<Prefs>().chatTextColor = '';
                  setState(() => _chatTextColor = '');
                  Navigator.pop(context);
                },
              ),
              FilledButton(
                child: Text('SAVE'),
                onPressed: () {
                  context.read<Prefs>().chatTextColor = selected;
                  setState(() => _chatTextColor = selected);
                  Navigator.pop(context);
                },
              ),
            ],
          );
        });
      },
    );
  }

  void _requestProfileAvatar(Client client, NetworkModel network) {
    var key = '${client.params.host}/${network.nickname.toLowerCase()}';
    if (_profileAvatarKey == key) {
      return;
    }
    _profileAvatarKey = key;
    _profileAvatarPreview = null;
    var backend = const ProfileBackendClient();
    var cached =
        backend.cachedAvatarUrls(client.params.host, [network.nickname]);
    _profileAvatar = cached[network.nickname.toLowerCase()];
    backend.fetchAvatarUrls(client.params.host, [network.nickname]).then(
        (avatars) {
      if (!mounted) {
        return;
      }
      setState(() {
        _profileAvatar = avatars[network.nickname.toLowerCase()];
      });
    });
  }

  Future<void> _uploadProfileAvatar(Client client, NetworkModel network) async {
    var account = network.account?.trim() ?? '';
    if (account.isEmpty || _profileAvatarUploading || _profileAvatarRemoving) {
      return;
    }
    XFile? file;
    try {
      file = await _pickProfileAvatarFile();
    } on Exception catch (err) {
      if (!mounted) return;
      showTopRightSnackBar(context, SnackBar(content: Text(err.toString())));
      return;
    }
    if (file == null || !mounted) return;
    var previousPreview = _profileAvatarPreview;
    Uint8List? previewBytes;
    try {
      previewBytes = await file.readAsBytes();
    } on Exception catch (_) {
      previewBytes = null;
    }
    if (!mounted) return;
    setState(() {
      _profileAvatarUploading = true;
      if (previewBytes != null && previewBytes.isNotEmpty) {
        _profileAvatarPreview = previewBytes;
      }
    });
    try {
      var avatar = await const ProfileBackendClient().uploadProfileAvatar(
        server: client.params.host,
        nick: network.nickname,
        account: account,
        file: file,
      );
      if (!mounted) return;
      setState(() {
        _profileAvatar = avatar;
        if (previewBytes != null && previewBytes.isNotEmpty) {
          _profileAvatarPreview = previewBytes;
        }
      });
      showTopRightSnackBar(
        context,
        const SnackBar(content: Text('Profile photo updated')),
      );
    } on Exception catch (err) {
      if (!mounted) return;
      setState(() => _profileAvatarPreview = previousPreview);
      showTopRightSnackBar(context, SnackBar(content: Text(err.toString())));
    } finally {
      if (mounted) {
        setState(() => _profileAvatarUploading = false);
      }
    }
  }

  Future<XFile?> _pickProfileAvatarFile() async {
    if (!Platform.isAndroid) {
      return ImagePicker().pickImage(source: ImageSource.gallery);
    }

    var picked = await _activityChannel
        .invokeMapMethod<String, Object?>('pickLocalImage');
    if (picked == null) {
      return null;
    }

    var bytes = picked['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      return null;
    }

    var name = (picked['name'] as String?)?.trim();
    var mimeType = (picked['mimeType'] as String?)?.trim();
    return XFile.fromData(
      bytes,
      name: name == null || name.isEmpty ? 'profile-avatar.jpg' : name,
      mimeType: mimeType == null || mimeType.isEmpty ? null : mimeType,
    );
  }

  Future<void> _removeProfileAvatar(Client client, NetworkModel network) async {
    var account = network.account?.trim() ?? '';
    if (account.isEmpty ||
        _profileAvatar == null ||
        _profileAvatarUploading ||
        _profileAvatarRemoving) {
      return;
    }

    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove profile photo?'),
        content: const Text('Your current profile photo will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _profileAvatarRemoving = true);
    try {
      await const ProfileBackendClient().deleteProfileAvatar(
        server: client.params.host,
        nick: network.nickname,
        account: account,
      );
      if (!mounted) return;
      setState(() {
        _profileAvatar = null;
        _profileAvatarPreview = null;
      });
      showTopRightSnackBar(
        context,
        const SnackBar(content: Text('Profile photo removed')),
      );
    } on Exception catch (err) {
      if (!mounted) return;
      showTopRightSnackBar(context, SnackBar(content: Text(err.toString())));
    } finally {
      if (mounted) {
        setState(() => _profileAvatarRemoving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var networkList = context.watch<NetworkListModel>();

    NetworkModel? mainNetwork;
    for (var network in networkList.networks) {
      if (network.networkEntry.bouncerId == null) {
        mainNetwork = network;
        break;
      }
    }
    if (mainNetwork == null) {
      // This can happen when logging out: the settings page is still
      // being displayed because of a fade-out animation but we no longer
      // have any network configured.
      return Container();
    }

    NetworkModel mainNetworkValue = mainNetwork;
    var mainClient = context.read<ClientProvider>().get(mainNetworkValue);
    _requestProfileAvatar(mainClient, mainNetworkValue);

    var networkListenable = Listenable.merge(networkList.networks);
    return AnimatedBuilder(
        animation: networkListenable,
        builder: (context, _) => Scaffold(
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerLowest,
              appBar: AppBar(
                title: Text('Settings'),
              ),
              body: ListView(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  minLeadingWidth: 48,
                  leading: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(children: [
                      Center(
                        child: ProfileAvatar(
                          name: mainNetworkValue.nickname,
                          avatarUrl: _profileAvatar,
                          avatarBytes: _profileAvatarPreview,
                          size: 48,
                          backgroundColor:
                              Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          foregroundColor:
                              Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                          decoration: BoxDecoration(
                            color: mainNetworkValue.state == NetworkState.online
                                ? Color(0xFF22C55E)
                                : Color(0xFFEAB308),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: const Color(0xFF142033),
                                width: 2),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  title: Text(
                    mainNetworkValue.nickname,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Profile pictures only with registered nick',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.65),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _profileAvatarUploading
                      ? SizedBox(
                          width: 40,
                          height: 40,
                          child: Center(
                            child: SizedBox(
                              width: 21,
                              height: 21,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        )
                      : Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: mainNetworkValue.account == null
                                ? Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                : Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.file_upload_outlined,
                            color: mainNetworkValue.account == null
                                ? Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                : Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                          ),
                        ),
                  title: const Text('Upload profile photo'),
                  subtitle: Text(mainNetworkValue.account == null
                      ? 'Only identified or registered nicks'
                      : 'Choose an image up to 5MB'),
                  trailing: mainNetworkValue.account == null
                      ? Transform.translate(
                          offset: const Offset(0, 2),
                          child: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                          ),
                        )
                      : const Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                        ),
                  enabled: mainNetworkValue.account != null &&
                      !_profileAvatarUploading &&
                      !_profileAvatarRemoving,
                  onTap: mainNetworkValue.account == null
                      ? null
                      : () =>
                          _uploadProfileAvatar(mainClient, mainNetworkValue),
                ),
                if (_profileAvatar != null)
                  Divider(
                    height: 1,
                    indent: 74,
                    endIndent: 16,
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.45),
                  ),
                if (_profileAvatar != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _profileAvatarRemoving
                        ? SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: SizedBox(
                                width: 21,
                                height: 21,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          )
                        : Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .errorContainer
                                  .withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.hide_image_outlined,
                              color:
                                  Theme.of(context).colorScheme.onErrorContainer,
                            ),
                          ),
                    title: Text(
                      'Remove profile photo',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text('Use the default profile avatar'),
                    enabled: mainNetworkValue.account != null &&
                        !_profileAvatarUploading &&
                        !_profileAvatarRemoving,
                    onTap: mainNetworkValue.account == null
                        ? null
                        : () =>
                            _removeProfileAvatar(mainClient, mainNetworkValue),
                  ),
                      ],
                    ),
                  ),
                ),
                Divider(),
                SwitchListTile(
                  title: Text('Compact message list'),
                  secondary: Icon(Icons.reorder),
                  value: _compact,
                  onChanged: (bool enabled) {
                    context.read<Prefs>().bufferCompact = enabled;
                    setState(() {
                      _compact = enabled;
                    });
                  },
                ),
                SwitchListTile(
                  title: Text('Send & display typing indicators'),
                  subtitle: Text('Always on'),
                  secondary: Icon(Icons.border_color),
                  value: _typing,
                  onChanged: (bool enabled) {
                    context.read<Prefs>().typingIndicator = true;
                    setState(() {
                      _typing = true;
                    });
                  },
                ),
                ListTile(
                  title: Text('Chat text color'),
                  subtitle:
                      Text(_chatTextColor.isEmpty ? 'Default' : _chatTextColor),
                  leading: CircleAvatar(
                    backgroundColor: _chatTextColor.isEmpty
                        ? Theme.of(context).colorScheme.surfaceContainer
                        : Color(
                            int.parse(_chatTextColor.substring(1), radix: 16) |
                                0xFF000000),
                    child: _chatTextColor.isEmpty ? Icon(Icons.palette) : null,
                  ),
                  onTap: _showChatTextColorDialog,
                ),
                SwitchListTile(
                  title: Text('Display link previews'),
                  subtitle: Text(
                      'Retrieve link previews directly from websites for messages you receive. Privacy-conscious users may want to leave this off.'),
                  secondary: Icon(Icons.preview),
                  value: _linkPreview,
                  onChanged: (bool enabled) {
                    context.read<Prefs>().linkPreview = enabled;
                    setState(() {
                      _linkPreview = enabled;
                    });
                  },
                ),
                if (_supportsInAppBrowserView)
                  SwitchListTile(
                    title: Text('Open links in external app'),
                    subtitle: Text(
                        'Use an external application (web browser, navigation, etc.) for opening links.'),
                    secondary: Icon(Icons.link),
                    value: _linkExtApp,
                    onChanged: (bool enabled) {
                      context.read<Prefs>().linkExtApp = enabled;
                      setState(() {
                        _linkExtApp = enabled;
                      });
                    },
                  ),
                if (_uploadErrorReportsHost != null)
                  SwitchListTile(
                    title: Text('Send crash reports'),
                    subtitle: Text(
                        'Crash reports will be sent to $_uploadErrorReportsHost.'),
                    secondary: Icon(Icons.bug_report),
                    value: _uploadErrorReports,
                    onChanged: (bool enabled) {
                      context.read<Prefs>().uploadErrorReports = enabled;
                      setState(() {
                        _uploadErrorReports = enabled;
                      });
                    },
                  ),
                Divider(),
                ListTile(
                  title: Text('About'),
                  leading: Icon(Icons.info),
                  onTap: () {
                    launchUrl(
                        Uri.parse('https://codeberg.org/emersion/goguma'));
                  },
                ),
                ListTile(
                  title: Text('Quit'),
                  leading: Icon(Icons.logout, color: Colors.red),
                  textColor: Colors.red,
                  onTap: _showLogoutDialog,
                ),
              ]),
            ));
  }
}
