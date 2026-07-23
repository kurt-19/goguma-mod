// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../cached_network_image.dart';
import '../client.dart';
import '../client_controller.dart';
import '../dialog/edit_topic.dart';
import '../irc/irc.dart';
import '../linkify.dart';
import '../logging.dart';
import '../models.dart';
import '../profile_backend.dart';
import '../widget/profile_avatar.dart';
import 'buffer.dart';
import 'network_details.dart';

class BufferDetailsPage extends StatefulWidget {
  static const routeName = '/buffer/details';

  const BufferDetailsPage({super.key});

  @override
  State<BufferDetailsPage> createState() => _BufferDetailsPageState();
}

class _BufferDetailsPageState extends State<BufferDetailsPage> {
  Whois? _whois;

  List<WhoReply>? _members;
  bool _preparingMembers = false;
  bool? _inviteOnly;
  bool? _protectedTopic;
  bool? _moderated;
  final Map<String, String> _backendAvatars = {};
  MemberListModel? _observedMemberList;
  late final StreamSubscription<ProfileAvatarChange> _avatarSubscription;

  @override
  void initState() {
    super.initState();
    _avatarSubscription =
        ProfileBackendClient.avatarChanges.listen(_handleAvatarChanged);

    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();
    if (client.state == ClientState.disconnected) {
      return;
    }
    if (client.isNick(buffer.name) && buffer.online != false) {
      _seedBackendAvatars(client, [buffer.name]);
      _fetchUserDetails(client, buffer.name);
      _fetchBackendAvatars(client, [buffer.name]);
    }
    if (client.isChannel(buffer.name)) {
      var cachedMembers = buffer.members;
      if (cachedMembers != null) {
        var network = context.read<NetworkModel>();
        _members = _membersFromMemberList(cachedMembers, network);
        _seedBackendAvatars(
            client, _members!.map((who) => who.nickname).take(80));
        unawaited(_fetchBackendAvatars(
            client, _members!.map((who) => who.nickname).take(80)));
      } else {
        _preparingMembers = true;
      }
      _fetchChannelDetails(client, buffer.name);
    }
  }

  void _fetchUserDetails(Client client, String nick) async {
    var whois = await client.whois(nick);
    if (!mounted) {
      return;
    }
    setState(() {
      _whois = whois;
    });
  }

  @override
  void dispose() {
    _avatarSubscription.cancel();
    _observedMemberList?.removeListener(_handleMemberListChanged);
    super.dispose();
  }

  void _handleAvatarChanged(ProfileAvatarChange change) {
    if (!mounted) {
      return;
    }
    var client = context.read<Client>();
    var network = context.read<NetworkModel>();
    if (!_profileEventMatchesNetwork(change.server, network, client)) {
      return;
    }
    var buffer = context.read<BufferModel>();
    var cm = client.isupport.caseMapping;
    var relevant =
        client.isNick(buffer.name) && cm.equals(change.nick, buffer.name);
    relevant = relevant ||
        (_members?.any((member) => cm.equals(member.nickname, change.nick)) ??
            false);
    relevant = relevant ||
        (buffer.members?.members.keys
                .any((nick) => cm.equals(nick, change.nick)) ??
            false);
    if (!relevant) {
      return;
    }
    if (client.isNick(buffer.name) && cm.equals(change.nick, buffer.name)) {
      buffer.setBackendAvatar(change.avatarUrl);
    }
    buffer.members?.setAvatar(change.nick, change.avatarUrl);
    var key = change.nick.toLowerCase();
    setState(() {
      if (change.avatarUrl == null) {
        _backendAvatars.remove(key);
      } else {
        _backendAvatars[key] = change.avatarUrl!;
      }
    });
  }

  void _syncMemberListListener(MemberListModel? memberList) {
    if (_observedMemberList == memberList) {
      return;
    }
    _observedMemberList?.removeListener(_handleMemberListChanged);
    _observedMemberList = memberList;
    _observedMemberList?.addListener(_handleMemberListChanged);
  }

  void _handleMemberListChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _fetchChannelDetails(Client client, String channel) async {
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    try {
      var modeFuture = client.fetchMode(channel);
      var whoFuture = client.who(channel);

      var modeReply = await modeFuture;
      var whoReplies = await whoFuture;
      if (!mounted) {
        return;
      }

      var modes = modeReply.params[2];
      _sortMembers(whoReplies);
      for (var reply in whoReplies) {
        network.users.updateUser(UserModel(
          nickname: reply.nickname,
          realname: reply.realname,
          username: reply.username,
          host: reply.host,
          account: reply.account,
        ));
      }
      var avatarNicks = whoReplies.map((who) => who.nickname).take(80).toList();
      var avatars = await _loadBackendAvatars(client, avatarNicks);
      if (!mounted) {
        return;
      }

      buffer.members?.syncAvatars(avatarNicks, avatars);
      setState(() {
        for (var nick in avatarNicks) {
          _backendAvatars.remove(nick.toLowerCase());
        }
        _backendAvatars.addAll(avatars);
        _inviteOnly = modes.contains(ChannelMode.inviteOnly);
        _protectedTopic = modes.contains(ChannelMode.protectedTopic);
        _moderated = modes.contains(ChannelMode.moderated);
        _members = whoReplies;
        _preparingMembers = false;
      });
    } on Exception catch (err) {
      log.print('Failed to prepare channel user list', error: err);
      if (!mounted) {
        return;
      }
      setState(() {
        _preparingMembers = false;
        if (_members == null && buffer.members != null) {
          _members = _membersFromMemberList(buffer.members!, network);
        }
      });
    }
  }

  Future<void> _fetchBackendAvatars(
      Client client, Iterable<String> nicks) async {
    var requestedNicks = nicks.toList(growable: false);
    var avatars = await _loadBackendAvatars(client, requestedNicks);
    if (!mounted) {
      return;
    }
    var buffer = context.read<BufferModel>();
    buffer.members?.syncAvatars(requestedNicks, avatars);
    if (client.isNick(buffer.name) &&
        requestedNicks.any(
            (nick) => client.isupport.caseMapping.equals(nick, buffer.name))) {
      buffer.setBackendAvatar(avatars[buffer.name.toLowerCase()]);
    }
    setState(() {
      for (var nick in requestedNicks) {
        _backendAvatars.remove(nick.toLowerCase());
      }
      _backendAvatars.addAll(avatars);
    });
  }

  void _seedBackendAvatars(Client client, Iterable<String> nicks) {
    var avatars = const ProfileBackendClient()
        .cachedAvatarUrls(client.params.host, nicks);
    if (avatars.isNotEmpty) {
      _backendAvatars.addAll(avatars);
    }
  }

  Future<Map<String, String>> _loadBackendAvatars(
      Client client, Iterable<String> nicks) async {
    var avatars = await const ProfileBackendClient()
        .fetchAvatarUrls(client.params.host, nicks);
    if (avatars.isNotEmpty && mounted) {
      await _precacheAvatars(avatars.values);
    }
    return avatars;
  }

  Future<void> _precacheAvatars(Iterable<String> urls) async {
    var imageSize = (40 * MediaQuery.devicePixelRatioOf(context)).round();
    await Future.wait(urls.take(80).map((url) {
      var image = ResizeImage.resizeIfNeeded(
          imageSize, imageSize, CachedNetworkImage(url));
      return precacheImage(image, context).catchError((_) {});
    }));
  }

  @override
  Widget build(BuildContext context) {
    var buffer = context.watch<BufferModel>();
    var network = context.watch<NetworkModel>();
    var client = context.read<Client>();
    var isStatusBuffer = isServerBufferName(buffer.name);
    _syncMemberListListener(buffer.members);

    var canEditTopic = false;
    if (client.state == ClientState.connected) {
      var membership = '';
      if (buffer.members != null) {
        membership = buffer.members!.members[client.nick] ?? '';
      } else if (_members != null) {
        for (var who in _members!) {
          if (client.isupport.caseMapping.equals(who.nickname, client.nick)) {
            membership = who.membershipPrefix ?? '';
            break;
          }
        }
      }

      var editTopicMemberships = const [
        IrcIsupportMembership.founder,
        IrcIsupportMembership.op,
        IrcIsupportMembership.halfop,
      ];
      for (var ms in editTopicMemberships) {
        if (membership.contains(ms.prefix)) {
          canEditTopic = true;
          break;
        }
      }
    }
    if (client.state == ClientState.connected && _protectedTopic == false) {
      canEditTopic = true;
    }

    List<Widget> children = [];

    if (isStatusBuffer) {
      var host = network.serverDisplayName;
      var port = network.serverEntry.port;
      var address = port == null ? host : '$host:$port';
      var account = network.account;
      var realname = network.realname.trim();
      var nickSubtitle = account == null
          ? (realname.isEmpty ? null : realname)
          : 'Authenticated as $account';

      children.add(_NativeInfoTile(
        title: host,
        subtitle: 'Server and service notices',
        icon: Icons.dns,
        onTap: network.bouncerNetwork == null
            ? null
            : () {
                Navigator.pushNamed(context, NetworkDetailsPage.routeName,
                    arguments: network);
              },
      ));
      children.add(_NativeInfoTile(
        title: address,
        subtitle: networkStateDescription(network.state),
        icon: Icons.language,
        iconSize: 20,
      ));
      children.add(_NativeInfoTile(
        title: client.nick,
        subtitle: nickSubtitle ?? 'Current nickname',
        icon: Icons.person,
      ));
      if (account != null) {
        children.add(_NativeInfoTile(
          title: 'Authenticated as $account',
          subtitle: 'This connection is logged in with an account.',
          icon: Icons.gpp_good,
        ));
      } else if (client.caps.available.containsKey('sasl')) {
        children.add(_NativeInfoTile(
          title: 'Unauthenticated',
          subtitle: 'This connection is not logged in.',
          icon: Icons.gpp_bad,
        ));
      }
      children.add(_NativeInfoTile(
        title: client.params.tls ? 'Secure connection' : 'Standard connection',
        subtitle: client.params.tls
            ? 'Encrypted IRC connection to the server.'
            : 'Plain IRC connection to the server.',
        icon: client.params.tls ? Icons.lock : Icons.lock_open,
      ));
      if (network.isIrcOperator) {
        children.add(_NativeInfoTile(
          title: 'Network operator',
          subtitle: 'This user is a server operator.',
          icon: Icons.gavel,
        ));
      }
    }

    if (!isStatusBuffer && client.isNick(buffer.name)) {
      var avatarUrl = buffer.hasBackendAvatarValue
          ? buffer.avatar
          : _backendAvatars[buffer.name.toLowerCase()] ?? buffer.avatar;
      children.add(_NativeProfileHeader(
        nickname: buffer.name,
        subtitle: buffer.realname ?? network.serverDisplayName,
        avatarUrl: avatarUrl,
      ));
    }

    if (buffer.topic != null) {
      var topic = stripAnsiFormatting(buffer.topic!);
      children.add(Container(
        margin: const EdgeInsets.all(15),
        child: Builder(builder: (context) {
          var textStyle =
              DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
          var linkStyle = TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
            decorationColor: Colors.blue,
          );
          return DefaultTextStyle(
            style: textStyle,
            child: SelectableText.rich(
              linkify(context, topic, linkStyle: linkStyle),
              textAlign: TextAlign.center,
            ),
          );
        }),
      ));
      children.add(Divider());
    }

    if (!isStatusBuffer) {
      children.add(_NativeInfoTile(
        title: network.serverDisplayName,
        icon: Icons.dns,
        onTap: network.bouncerNetwork == null
            ? null
            : () {
                Navigator.pushNamed(context, NetworkDetailsPage.routeName,
                    arguments: network);
              },
      ));
    }

    var whoisAddress = _whoisAddress(_whois);
    if (client.isNick(buffer.name) && whoisAddress != null) {
      children.add(_NativeInfoTile(
        title: whoisAddress,
        icon: Icons.language,
        iconSize: 20,
      ));
    }

    if (buffer.online == false) {
      children.add(_NativeInfoTile(
        title: 'Disconnected',
        subtitle: 'This user will not receive new messages.',
        icon: Icons.error,
      ));
    } else if (buffer.away == true) {
      children.add(_NativeInfoTile(
        title: 'Away',
        subtitle: 'This user might not see new messages immediately.',
        icon: Icons.pending,
      ));
    }

    if (_inviteOnly == true) {
      children.add(_NativeInfoTile(
        title: 'Invite-only',
        subtitle: 'Only invited users can join this channel.',
        icon: Icons.shield,
      ));
    }
    if (_moderated == true) {
      children.add(_NativeInfoTile(
        title: 'Moderated',
        subtitle: 'Only privileged users can send messages.',
        icon: Icons.forum,
      ));
    }

    var whois = _whois;
    SliverList? commonChannels;
    if (whois != null) {
      if (whois.account != null) {
        var loggedInTitle = 'Authenticated';
        if (whois.account != whois.nickname) {
          loggedInTitle = 'Authenticated as ${whois.account}';
        }
        children.add(_NativeInfoTile(
          title: loggedInTitle,
          subtitle:
              'This user is logged in with the account "${whois.account}".',
          icon: Icons.gpp_good,
        ));
      } else if (client.caps.available.containsKey('sasl')) {
        children.add(_NativeInfoTile(
          title: 'Unauthenticated',
          subtitle: 'This user is not logged in.',
          icon: Icons.gpp_bad,
        ));
      }

      if (whois.op) {
        children.add(_NativeInfoTile(
          title: 'Network operator',
          subtitle:
              'This user is a server operator, they have administrator privileges.',
          icon: Icons.gavel,
        ));
      }

      if (client.params.tls && whois.secureConnection) {
        children.add(_NativeInfoTile(
          title: 'Secure connection',
          subtitle:
              'This user has established a secure connection to the server.',
          icon: Icons.lock,
        ));
      }

      if (whois.bot) {
        children.add(_NativeInfoTile(
          title: 'Bot',
          subtitle: 'This user is an automated bot.',
          icon: Icons.smart_toy,
        ));
      }

      if (!whois.channels.isEmpty) {
        // TODO: don't sort on each build() call
        var l = whois.channels.keys.toList();
        l.sort();
        commonChannels = SliverList(
            delegate: SliverChildBuilderDelegate(
          (context, index) {
            var name = l[index];
            return _NativeChannelTile(
              nickname: name,
              onTap: () {
                BufferPage.open(context, name, network);
              },
            );
          },
          childCount: l.length,
        ));

        var s = l.length > 1 ? 's' : '';

        children.add(_NativeSectionHeader('${l.length} channel$s in common'));
      }
    }

    var displayMembers = _preparingMembers
        ? null
        : (buffer.members == null
            ? _members
            : _membersFromMemberList(buffer.members!, network,
                details: _members));
    SliverList? members;
    if (_preparingMembers) {
      members = SliverList(
          delegate: SliverChildListDelegate([
        _NativePreparingTile(),
      ]));
      children.add(_NativeSectionHeader('Preparing user list'));
    } else if (displayMembers != null) {
      members = SliverList(
          delegate: SliverChildBuilderDelegate(
        (context, index) {
          var member = displayMembers[index];
          var membership =
              _membershipDescription(member.membershipPrefix ?? '');
          var memberAvatar = buffer.members?.avatar(member.nickname);
          var hasMemberAvatarValue =
              buffer.members?.hasAvatarValue(member.nickname) ?? false;
          return _NativeMemberTile(
            nickname: member.nickname,
            subtitle: _memberSubtitle(member),
            role: membership,
            avatarUrl: hasMemberAvatarValue
                ? memberAvatar
                : _backendAvatars[member.nickname.toLowerCase()],
            onTap: () {
              BufferPage.open(context, member.nickname, network,
                  preserveStack: true);
            },
          );
        },
        childCount: displayMembers.length,
      ));

      var s = displayMembers.length > 1 ? 's' : '';

      children.add(_NativeSectionHeader('${displayMembers.length} member$s'));
    }

    var title = Text(isStatusBuffer ? statusDisplayName : buffer.name,
        maxLines: 1, overflow: TextOverflow.ellipsis);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            snap: false,
            floating: false,
            expandedHeight: isStatusBuffer ? null : 88,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerLowest,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            leadingWidth: isStatusBuffer ? 36 : null,
            title: isStatusBuffer ? title : null,
            titleSpacing: isStatusBuffer ? 0 : null,
            flexibleSpace: isStatusBuffer
                ? null
                : FlexibleSpaceBar(
                    title: title,
                    centerTitle: false,
                    expandedTitleScale: 1.0,
                    titlePadding: EdgeInsetsDirectional.only(
                        start: 8, bottom: 16, end: 24),
                  ),
            actions: [
              if (canEditTopic)
                IconButton(
                  icon: Icon(Icons.edit),
                  tooltip: 'Edit topic',
                  onPressed: () {
                    EditTopicDialog.show(context, buffer);
                  },
                ),
            ],
          ),
          SliverList(delegate: SliverChildListDelegate(children)),
          if (members != null) members,
          if (commonChannels != null) commonChannels,
        ],
      ),
    );
  }
}

bool _profileEventMatchesNetwork(
    String eventServer, NetworkModel network, Client client) {
  var needle = eventServer.trim().toLowerCase();
  if (needle.isEmpty) {
    return false;
  }
  var candidates = <String?>[
    client.params.host,
    network.serverEntry.host,
    network.displayName,
    network.upstreamName,
    network.bouncerNetwork?.host,
    network.bouncerNetwork?.name,
    network.serverId.toString(),
    network.networkId.toString(),
  ];
  return candidates
      .whereType<String>()
      .map((value) => value.trim().toLowerCase())
      .any((value) => value.isNotEmpty && value == needle);
}

String? _memberSubtitle(WhoReply member) {
  var host = stripAnsiFormatting(member.host ?? '').trim();
  if (host.isNotEmpty) {
    return _cleanHost(host);
  }

  var realname = stripAnsiFormatting(member.realname).trim();
  if (realname.isNotEmpty && !isStubRealname(realname, member.nickname)) {
    return realname;
  }
  return null;
}

String? _whoisAddress(Whois? whois) {
  var host = stripAnsiFormatting(whois?.source?.host ?? '').trim();
  if (host.isEmpty) {
    return null;
  }
  return _cleanHost(host);
}

int _compareMembers(WhoReply a, WhoReply b) {
  const privilegeOrder = '!~&@%+';
  var i = _membershipRank(privilegeOrder, a.membershipPrefix);
  var j = _membershipRank(privilegeOrder, b.membershipPrefix);
  if (i != j) {
    return i - j;
  }
  return a.nickname.toLowerCase().compareTo(b.nickname.toLowerCase());
}

String _cleanHost(String host) {
  return host.substring(host.indexOf('@') + 1).trim().replaceFirst('~', '');
}

List<WhoReply> _membersFromMemberList(
    MemberListModel memberList, NetworkModel network,
    {List<WhoReply>? details}) {
  var detailsByNick = {
    for (var detail in details ?? const <WhoReply>[])
      detail.nickname.toLowerCase(): detail,
  };
  var members = memberList.members.entries.map((entry) {
    var user = network.users.map[entry.key];
    var detail = detailsByNick[entry.key.toLowerCase()];
    return WhoReply(
      nickname: entry.key,
      away: detail?.away ?? false,
      op: detail?.op ?? false,
      realname: detail?.realname ?? user?.realname ?? '',
      username: detail?.username ?? user?.username,
      host: detail?.host ?? user?.host,
      channel: detail?.channel,
      membershipPrefix: entry.value,
      account: detail?.account ?? user?.account,
    );
  }).toList();
  _sortMembers(members);
  return members;
}

void _sortMembers(List<WhoReply> members) {
  members.sort(_compareMembers);
}

int _membershipRank(String prefixes, String? membershipPrefix) {
  var best = prefixes.length;
  if (membershipPrefix == null || membershipPrefix.isEmpty) {
    return best;
  }
  for (var prefix in membershipPrefix.split('')) {
    var index = prefixes.indexOf(prefix);
    if (index >= 0 && index < best) {
      best = index;
    }
  }
  return best;
}

String? _membershipDescription(String membership) {
  if (membership == '') {
    return null;
  }
  var m = {
    '!': 'founder / operator',
    IrcIsupportMembership.founder.prefix: 'founder',
    IrcIsupportMembership.protected.prefix: 'protected',
    IrcIsupportMembership.op.prefix: 'operator',
    IrcIsupportMembership.halfop.prefix: 'halfop',
    IrcIsupportMembership.voice.prefix: 'voice',
  };
  return membership.split('').map((prefix) {
    return m[prefix] ?? prefix;
  }).join(', ');
}

class _NativeSectionHeader extends StatelessWidget {
  final String title;

  const _NativeSectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _NativeInfoTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final double iconSize;
  final VoidCallback? onTap;

  const _NativeInfoTile({
    required this.title,
    this.subtitle,
    required this.icon,
    this.iconSize = 22,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ListTile(
        tileColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: icon == null
            ? null
            : Icon(icon, color: scheme.onSurfaceVariant, size: iconSize),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
        onTap: onTap,
      ),
    );
  }
}

class _NativePreparingTile extends StatelessWidget {
  const _NativePreparingTile();

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ListTile(
        minTileHeight: 56,
        tileColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Preparing user list'),
      ),
    );
  }
}

class _NativeProfileHeader extends StatelessWidget {
  final String nickname;
  final String? subtitle;
  final String? avatarUrl;

  const _NativeProfileHeader({
    required this.nickname,
    this.subtitle,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          ProfileAvatar(
            name: nickname,
            avatarUrl: avatarUrl,
            size: 50,
            backgroundColor: scheme.surfaceContainer,
            foregroundColor: scheme.onSurface,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nickname,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    stripAnsiFormatting(subtitle!),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _NativeMemberTile extends StatelessWidget {
  final String nickname;
  final String? subtitle;
  final String? role;
  final String? avatarUrl;
  final VoidCallback? onTap;

  const _NativeMemberTile({
    required this.nickname,
    this.subtitle,
    this.role,
    this.avatarUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: 64),
        child: ListTile(
          tileColor: scheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Stack(children: [
            ProfileAvatar(
              name: nickname,
              avatarUrl: avatarUrl,
              showOnlineIndicator: true,
              backgroundColor: scheme.surfaceContainer,
              foregroundColor: scheme.onSurface,
            ),
          ]),
          title: Text(nickname, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle ?? '',
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          trailing: role == null
              ? null
              : Container(
                  padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    role!,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _NativeChannelTile extends StatelessWidget {
  final String nickname;
  final VoidCallback? onTap;

  const _NativeChannelTile({
    required this.nickname,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ListTile(
        minTileHeight: 56,
        tileColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(nickname, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
      ),
    );
  }
}
