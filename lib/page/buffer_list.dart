// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../additional_server_subscription.dart';
import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc/irc.dart';
import '../models.dart';
import '../native_foreground.dart';
import '../notification_controller.dart';
import '../page/edit_bouncer_network.dart';
import '../page/join.dart';
import '../page/settings.dart';
import '../prefs.dart';
import '../widget/app_snack_bar.dart';
import '../widget/native_radio_panel.dart';
import '../widget/network_indicator.dart';
import 'buffer.dart';
import 'connect.dart';

class BufferListPage extends StatefulWidget {
  static const routeName = '/';

  const BufferListPage({super.key});

  @override
  State<BufferListPage> createState() => _BufferListPageState();
}

class _BufferListPageState extends State<BufferListPage> {
  String? _searchQuery;
  final TextEditingController _searchController = TextEditingController();
  final _listKey = GlobalKey();
  bool _conversationPanelOpen = true;

  @override
  void initState() {
    super.initState();
    Timer.run(() {
      if (!mounted) {
        return;
      }
      unawaited(context.read<NotificationController>().enterMainApp());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _search(String query) {
    setState(() {
      _searchQuery = query.toLowerCase();
    });
  }

  void _startSearch() {
    ModalRoute.of(context)
        ?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
      setState(() {
        _searchQuery = null;
      });
      _searchController.text = '';
    }));
    _search('');
  }

  Client? _firstClient() {
    var clients = context.read<ClientProvider>().clients;
    return clients.isEmpty ? null : clients.first;
  }

  void _showCommandSent(String label) {
    showTopRightSnackBar(
      context,
      SnackBar(content: Text('$label sent')),
    );
  }

  String _normalizeChannelName(Client client, String value) {
    var clean = value.trim();
    if (clean.isEmpty || client.isChannel(clean)) {
      return clean;
    }
    return '#$clean';
  }

  void _showJoinChannelDialog() {
    var client = _firstClient();
    if (client == null) {
      return;
    }

    _showCommandDialog(
      title: 'Join channel',
      fields: const [
        _CommandField('Channel', hint: '#channel'),
        _CommandField('key password (optional)', obscure: true),
      ],
      onSubmit: (values) {
        var channel = _normalizeChannelName(client, values[0]);
        if (channel.isEmpty) return;
        var keyPassword = values[1];
        unawaited(keyPassword.isEmpty
            ? client.join([channel])
            : client.join([channel], keys: [keyPassword]));
        _showCommandSent('Join channel');
      },
    );
  }

  Future<void> _addServer() async {
    var subscription = context.read<AdditionalServerSubscription>();
    await subscription.refresh();
    if (!mounted) return;

    var allowed = subscription.entitled;
    if (!allowed) {
      allowed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => const _AdditionalServerPaywall(),
          ) ==
          true;
    }
    if (!mounted || !allowed) return;
    await Navigator.pushNamed(
      context,
      ConnectPage.routeName,
      arguments: const ConnectPageArguments(additionalServer: true),
    );
  }

  Future<void> _closeBuffer(BufferModel buffer) async {
    if (isServerBufferName(buffer.name)) {
      return;
    }
    var isChannel = buffer.network.networkEntry.isupport.isChannel(buffer.name);
    if (isChannel && isProtectedDefaultChannel(buffer.name)) {
      return;
    }

    var db = context.read<DB>();
    var bufferList = context.read<BufferListModel>();
    var client = context.read<ClientProvider>().get(buffer.network);
    if (isChannel) {
      if (client.state == ClientState.connected) {
        client.send(IrcMessage('PART', [buffer.name]));
      }
    } else {
      client.unmonitor([buffer.name]);
    }
    bufferList.remove(buffer);
    await db.deleteBuffer(buffer.entry.id!);
  }

  void _showBufferActions(BufferModel buffer) {
    var isChannel = buffer.network.networkEntry.isupport.isChannel(buffer.name);
    var isProtectedChannel =
        isChannel && isProtectedDefaultChannel(buffer.name);
    var canClose = !isServerBufferName(buffer.name) && !isProtectedChannel;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.close),
                title: Text('CLOSE'),
                enabled: canClose,
                onTap: canClose
                    ? () {
                        Navigator.pop(context);
                        unawaited(_closeBuffer(buffer));
                      }
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCommandDialog({
    required String title,
    required List<_CommandField> fields,
    required void Function(List<String> values) onSubmit,
  }) async {
    var controllers = [
      for (var field in fields) TextEditingController(text: field.initialValue),
    ];
    try {
      await showDialog<void>(
        context: context,
        useSafeArea: true,
        builder: (context) {
          var scheme = Theme.of(context).colorScheme;
          return MediaQuery.removeViewInsets(
            removeBottom: true,
            context: context,
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 360, maxHeight: 420),
                child: Material(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        for (var i = 0; i < fields.length; i++)
                          Padding(
                            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                            child: TextField(
                              controller: controllers[i],
                              decoration: InputDecoration(
                                labelText: fields[i].label,
                                hintText: fields[i].hint,
                                isDense: true,
                              ),
                              obscureText: fields[i].obscure,
                              keyboardType: fields[i].keyboardType,
                              autofocus: i == 0,
                              textInputAction: i == fields.length - 1
                                  ? TextInputAction.done
                                  : TextInputAction.next,
                              onSubmitted: (_) {
                                if (i == fields.length - 1) {
                                  Navigator.pop(context);
                                  onSubmit(controllers
                                      .map((controller) =>
                                          controller.text.trim())
                                      .toList());
                                }
                              },
                            ),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(context);
                                onSubmit(controllers
                                    .map((controller) => controller.text.trim())
                                    .toList());
                              },
                              child: const Text('Send'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
  }

  Future<void> _quitApp() async {
    var clientProvider = context.read<ClientProvider>();
    var notifController = context.read<NotificationController>();
    var db = context.read<DB>();
    var prefs = context.read<Prefs>();
    var navigator = Navigator.of(context);
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
  }

  Future<void> _showUserTools() async {
    var client = _firstClient();
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        var scheme = Theme.of(context).colorScheme;
        var actions = [
          _ToolAction(
            title: 'Change nick',
            icon: Icons.badge,
            enabled: client != null,
            onTap: () {
              if (client == null) return;
              _showCommandDialog(
                title: 'Change nickname',
                fields: [
                  _CommandField('New nickname', initialValue: client.nick),
                ],
                onSubmit: (values) {
                  if (values[0].isEmpty) return;
                  unawaited(client.setNickname(values[0]));
                  _showCommandSent('Nickname change');
                },
              );
            },
          ),
          _ToolAction(
            title: 'Identify',
            icon: Icons.verified_user,
            enabled: client != null,
            onTap: () {
              if (client == null) return;
              _showCommandDialog(
                title: 'Identify with NickServ',
                fields: [
                  _CommandField('Nickname', initialValue: client.nick),
                  const _CommandField('Password', obscure: true),
                ],
                onSubmit: (values) {
                  if (values[0].isEmpty || values[1].isEmpty) return;
                  client.send(IrcMessage('PRIVMSG',
                      ['NickServ', 'IDENTIFY ${values[0]} ${values[1]}']));
                  _showCommandSent('NickServ identify');
                },
              );
            },
          ),
          _ToolAction(
            title: 'Register nick',
            icon: Icons.app_registration,
            enabled: client != null,
            onTap: () {
              if (client == null) return;
              _showCommandDialog(
                title: 'Register nickname',
                fields: const [
                  _CommandField('Password', obscure: true),
                  _CommandField(
                    'Email',
                    hint: 'optional',
                    keyboardType: TextInputType.emailAddress,
                  ),
                ],
                onSubmit: (values) {
                  if (values[0].isEmpty) return;
                  var params = values[1].isEmpty
                      ? 'REGISTER ${values[0]}'
                      : 'REGISTER ${values[0]} ${values[1]}';
                  client.send(IrcMessage('PRIVMSG', ['NickServ', params]));
                  _showCommandSent('NickServ registration');
                },
              );
            },
          ),
          _ToolAction(
            title: 'OPER login',
            icon: Icons.vpn_key,
            enabled: client != null,
            onTap: () {
              if (client == null) return;
              _showCommandDialog(
                title: 'OPER login',
                fields: const [
                  _CommandField('Oper name'),
                  _CommandField('Password', obscure: true),
                ],
                onSubmit: (values) {
                  if (values[0].isEmpty || values[1].isEmpty) return;
                  client.send(IrcMessage('OPER', [values[0], values[1]]));
                  _showCommandSent('OPER');
                },
              );
            },
          ),
          _ToolAction(
            title: 'Quit',
            icon: Icons.logout,
            onTap: _quitApp,
          ),
        ];
        return MediaQuery.removeViewInsets(
          removeBottom: true,
          context: context,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
              child: Material(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                        child: Text(
                          'User tools',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                      ),
                      for (var action in actions)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          enabled: action.enabled,
                          leading: Icon(
                            action.icon,
                            color: action.enabled
                                ? scheme.onSurfaceVariant
                                : scheme.onSurfaceVariant
                                    .withValues(alpha: 0.45),
                          ),
                          title: Text(action.title),
                          onTap: action.enabled
                              ? () {
                                  Navigator.pop(context);
                                  action.onTap();
                                }
                              : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _shouldSuggestNewNetwork() {
    var clientProvider = context.read<ClientProvider>();
    if (clientProvider.clients.length != 1) {
      return false;
    }

    var client = clientProvider.clients.first;
    return client.caps.enabled.contains('soju.im/bouncer-networks') &&
        client.params.bouncerNetId == null;
  }

  @override
  Widget build(BuildContext context) {
    List<BufferModel> buffers = context.watch<BufferListModel>().buffers;
    if (_searchQuery != null) {
      var query = _searchQuery!;
      List<BufferModel> filtered = [];
      for (var buf in buffers) {
        if (buf.name.toLowerCase().contains(query) ||
            (buf.topic ?? buf.realname ?? '').toLowerCase().contains(query)) {
          filtered.add(buf);
        }
      }
      buffers = filtered;
    }
    var serverBuffersByNetwork = <NetworkModel, BufferModel>{};
    var channelBuffers = <BufferModel>[];
    var privateBuffers = <BufferModel>[];
    for (var buffer in buffers) {
      if (isServerBufferName(buffer.name)) {
        var current = serverBuffersByNetwork[buffer.network];
        if (current == null ||
            (!isServerBufferName(current.name) &&
                buffer.name == statusBufferName) ||
            current.name != statusBufferName &&
                buffer.name == statusBufferName) {
          serverBuffersByNetwork[buffer.network] = buffer;
        }
      } else if (buffer.network.networkEntry.isupport.isChannel(buffer.name)) {
        channelBuffers.add(buffer);
      } else {
        privateBuffers.add(buffer);
      }
    }
    var serverBuffers = serverBuffersByNetwork.values.toList();
    buffers = [...serverBuffers, ...channelBuffers, ...privateBuffers];

    Map<String, int> bufferNames = {};
    for (var buffer in buffers) {
      bufferNames.update(buffer.name.toLowerCase(), (n) => n + 1,
          ifAbsent: () => 1);
    }

    Widget body;
    if (buffers.length == 0) {
      if (_searchQuery != null) {
        body = _BufferListPlaceholder(
          icon: Icons.search,
          title: 'No search result',
          subtitle: 'No conversation matches the search query.',
        );
      } else if (_shouldSuggestNewNetwork()) {
        body = _BufferListPlaceholder(
          icon: Icons.hub,
          title: 'Join a network',
          subtitle: 'Welcome to IRC! To get started, join a network.',
          trailing: ElevatedButton(
            child: Text('New network'),
            onPressed: () {
              Navigator.pushNamed(context, EditBouncerNetworkPage.routeName);
            },
          ),
        );
      } else {
        body = _BufferListPlaceholder(
          icon: Icons.tag,
          title: 'Join a conversation',
          subtitle:
              'Welcome to IRC! To get started, join a channel or start a discussion with a user.',
          trailing: ElevatedButton(
            child: Text('JOIN'),
            onPressed: () {
              Navigator.pushNamed(context, JoinPage.routeName);
            },
          ),
        );
      }
    } else {
      Widget buildBufferItem(BufferModel buffer) {
        return _BufferItem(
          buffer: buffer,
          showNetworkName: bufferNames[buffer.name.toLowerCase()]! > 1,
          onLongPress: isServerBufferName(buffer.name)
              ? null
              : () => _showBufferActions(buffer),
        );
      }

      var panelChildren = [
        if (serverBuffers.isNotEmpty) _BufferSectionTitle(statusDisplayName),
        ...serverBuffers.map(buildBufferItem),
        if (_searchQuery == null || channelBuffers.isNotEmpty)
          _BufferSectionTitle('Channels'),
        ...channelBuffers.map(buildBufferItem),
        if (_searchQuery == null || privateBuffers.isNotEmpty)
          _BufferSectionDivider(),
        if (_searchQuery == null || privateBuffers.isNotEmpty)
          _BufferSectionTitle('Private messages', icon: Icons.chat_bubble),
        if (privateBuffers.isEmpty)
          _BufferPanelEmpty(
            icon: Icons.chat_bubble_outline,
            text: _searchQuery == null
                ? 'No private messages'
                : 'No private messages match',
          )
        else
          ...privateBuffers.map(buildBufferItem),
      ];

      body = _SingleSidePanelLayout(
        open: _conversationPanelOpen,
        child: _BufferSidePanel(
          title: 'Status, Channels & Private',
          icon: Icons.forum,
          open: _conversationPanelOpen,
          sideLabel: 'Chats',
          expandIcon: Icons.keyboard_double_arrow_right,
          collapseIcon: Icons.keyboard_double_arrow_left,
          onToggle: () {
            setState(() {
              _conversationPanelOpen = !_conversationPanelOpen;
            });
          },
          child: ListView(
            key: _listKey,
            padding: EdgeInsets.fromLTRB(8, 2, 8, 8),
            children: panelChildren,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: _searchQuery != null ? CloseButton() : null,
        title: Builder(builder: (context) {
          if (_searchQuery != null) {
            return TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search...',
                border: InputBorder.none,
              ),
              onChanged: _search,
            );
          } else {
            return Text('IRC mobile');
          }
        }),
        actions: _searchQuery != null
            ? null
            : [
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: _startSearch,
                ),
                PopupMenuButton(
                  onSelected: (key) {
                    switch (key) {
                      case 'add-server':
                        unawaited(_addServer());
                        break;
                      case 'join':
                        _showJoinChannelDialog();
                        break;
                      case 'user-tools':
                        _showUserTools();
                        break;
                      case 'settings':
                        Navigator.pushNamed(context, SettingsPage.routeName);
                        break;
                    }
                  },
                  itemBuilder: (context) {
                    return [
                      PopupMenuItem(
                          value: 'add-server', child: Text('ADD SERVER')),
                      PopupMenuItem(
                          value: 'user-tools', child: Text('USER TOOLS')),
                      PopupMenuItem(value: 'join', child: Text('JOIN')),
                      PopupMenuItem(value: 'settings', child: Text('SETTINGS')),
                    ];
                  },
                ),
              ],
      ),
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      body: DecoratedBox(
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest),
        child: NetworkListIndicator(
            child: _BackgroundServicePermissionBanner(
                child: Column(children: [
          NativeRadioPanel(),
          Expanded(child: body),
        ]))),
      ),
    );
  }
}

class _AdditionalServerPaywall extends StatefulWidget {
  const _AdditionalServerPaywall();

  @override
  State<_AdditionalServerPaywall> createState() =>
      _AdditionalServerPaywallState();
}

class _AdditionalServerPaywallState extends State<_AdditionalServerPaywall> {
  AdditionalServerSubscription? _subscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var subscription = context.read<AdditionalServerSubscription>();
    if (_subscription == subscription) return;
    _subscription?.removeListener(_handleSubscription);
    _subscription = subscription;
    subscription.addListener(_handleSubscription);
  }

  void _handleSubscription() {
    if (_subscription?.entitled == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  void dispose() {
    _subscription?.removeListener(_handleSubscription);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var subscription = context.watch<AdditionalServerSubscription>();
    return AlertDialog(
      icon: const Icon(Icons.dns_outlined),
      title: const Text('Add another server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${subscription.price} / month',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
              'Your main server stays free. This subscription unlocks additional IRC servers.'),
          if (subscription.error != null) ...[
            const SizedBox(height: 10),
            Text(
              subscription.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              subscription.loading ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: subscription.loading ? null : () => subscription.restore(),
          child: const Text('Restore'),
        ),
        FilledButton(
          onPressed:
              subscription.loading ? null : () => subscription.purchase(),
          child: subscription.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Subscribe'),
        ),
      ],
    );
  }
}

class _BackgroundServicePermissionBanner extends StatelessWidget {
  final Widget child;

  const _BackgroundServicePermissionBanner({
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}

class _SingleSidePanelLayout extends StatelessWidget {
  final Widget child;
  final bool open;

  const _SingleSidePanelLayout({
    required this.child,
    required this.open,
  });

  @override
  Widget build(BuildContext context) {
    var viewportWidth = MediaQuery.sizeOf(context).width;
    var panelWidth = open ? (viewportWidth - 18).clamp(260.0, 430.0) : 58.0;

    return Scrollbar(
      thumbVisibility: panelWidth > viewportWidth,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: panelWidth < viewportWidth ? viewportWidth : panelWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: panelWidth, child: child),
          ),
        ),
      ),
    );
  }
}

class _BufferSidePanel extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool open;
  final String sideLabel;
  final IconData expandIcon;
  final IconData collapseIcon;
  final VoidCallback onToggle;

  const _BufferSidePanel({
    required this.title,
    required this.icon,
    required this.child,
    required this.open,
    required this.sideLabel,
    required this.expandIcon,
    required this.collapseIcon,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    if (!open) {
      return Material(
        color: scheme.surfaceContainerLowest,
        child: InkWell(
          onTap: onToggle,
          child: Column(children: [
            SizedBox(
              height: 44,
              child: Icon(
                expandIcon,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: Center(
                  child: Text(
                    sideLabel,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
    }

    return Column(children: [
      Container(
        height: 44,
        padding: EdgeInsets.only(left: 12, right: 4),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.34),
            ),
          ),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                    letterSpacing: 0,
                  ),
            ),
          ),
          IconButton(
            tooltip: 'Collapse $title',
            icon: Icon(collapseIcon),
            iconSize: 20,
            onPressed: onToggle,
          ),
        ]),
      ),
      Expanded(child: child),
    ]);
  }
}

class _BufferPanelEmpty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BufferPanelEmpty({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 28, 10, 0),
      child: Column(children: [
        Icon(icon, size: 30, color: scheme.onSurfaceVariant),
        SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ]),
    );
  }
}

class _BufferSectionDivider extends StatelessWidget {
  const _BufferSectionDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Divider(
        height: 1,
        color: Theme.of(context).colorScheme.outlineVariant.withValues(
              alpha: 0.36,
            ),
      ),
    );
  }
}

class _BufferSectionTitle extends StatelessWidget {
  final String label;
  final IconData? icon;

  const _BufferSectionTitle(this.label, {this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 5, 12, 0),
      child: Row(children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: Color(0xFF7F93B1)),
          SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Color(0xFF7F93B1),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
          ),
        ),
      ]),
    );
  }
}

class _BufferItem extends AnimatedWidget {
  final BufferModel buffer;
  final bool showNetworkName;
  final VoidCallback? onLongPress;

  const _BufferItem(
      {required this.buffer, this.showNetworkName = false, this.onLongPress})
      : super(listenable: buffer);

  @override
  Widget build(BuildContext context) {
    var subtitle = buffer.draft == null
        ? (buffer.topic ?? buffer.realname)
        : 'Draft: ${buffer.draft!.text}';
    if (isServerBufferName(buffer.name)) {
      subtitle = 'All status messages';
    }

    Widget title;
    if (isServerBufferName(buffer.name)) {
      title = Text(statusDisplayName, overflow: TextOverflow.ellipsis);
    } else if (showNetworkName) {
      title = Text.rich(
        TextSpan(children: [
          TextSpan(text: buffer.name),
          TextSpan(
            text: ' on ${buffer.network.displayName}',
            style:
                TextStyle(color: Theme.of(context).textTheme.bodySmall!.color),
          ),
        ]),
        overflow: TextOverflow.fade,
      );
    } else {
      title = Text(buffer.name, overflow: TextOverflow.ellipsis);
    }

    List<Widget> trailing = [];
    if (buffer.muted) {
      trailing.add(Icon(
        Icons.notifications_off,
        size: 20,
        color: Theme.of(context).textTheme.bodySmall!.color,
      ));
    }
    if (buffer.pinned) {
      trailing.add(Icon(
        Icons.push_pin,
        size: 20,
        color: Theme.of(context).textTheme.bodySmall!.color,
      ));
    }
    if (buffer.archived) {
      trailing.add(Icon(
        Icons.inventory_2,
        size: 20,
        color: Theme.of(context).textTheme.bodySmall!.color,
      ));
    }
    if (buffer.unreadCount != 0) {
      var theme = Theme.of(context);
      trailing.add(Container(
        padding: EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: buffer.muted
              ? theme.textTheme.bodySmall!.color
              : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        constraints: BoxConstraints(minWidth: 20, minHeight: 20),
        child: Text(
          '${buffer.unreadCount}',
          style: TextStyle(fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ));
    }

    var theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: ListTile(
        minVerticalPadding: 2,
        visualDensity: VisualDensity(vertical: -4),
        tileColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        trailing: Wrap(
          spacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: trailing,
        ),
        title: title,
        subtitle: subtitle == null
            ? null
            : Text(
                stripAnsiFormatting(subtitle),
                overflow: TextOverflow.fade,
                softWrap: false,
                style: buffer.draft == null
                    ? null
                    : TextStyle(fontStyle: FontStyle.italic),
              ),
        onTap: () {
          BufferPage.open(context, buffer.name, buffer.network);
        },
        onLongPress: onLongPress,
      ),
    );
  }
}

class _CommandField {
  final String label;
  final String initialValue;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;

  const _CommandField(
    this.label, {
    this.initialValue = '',
    this.hint,
    this.obscure = false,
    this.keyboardType,
  });
}

class _ToolAction {
  final String title;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _ToolAction({
    required this.title,
    required this.icon,
    this.enabled = true,
    required this.onTap,
  });
}

class _BufferListPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _BufferListPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
        child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 100),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 15),
        Container(
          constraints: BoxConstraints(maxWidth: 300),
          child: Text(
            subtitle,
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: 15),
        if (trailing != null) trailing!,
      ],
    ));
  }
}
