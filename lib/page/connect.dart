import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hex/hex.dart';
import 'package:provider/provider.dart';

import '../app_config.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../ignore_store.dart';
import '../irc/irc.dart';
import '../logging.dart';
import '../models.dart';
import '../prefs.dart';
import 'buffer_list.dart';

class _ServerFeatures {
  bool passwordRequired;
  bool passwordUnsupported;
  String? networkName;
  int? nickLen;

  _ServerFeatures({
    this.passwordRequired = false,
    this.passwordUnsupported = false,
    this.networkName,
    this.nickLen,
  });
}

class ConnectPageArguments {
  final IrcUri? initialUri;
  final bool additionalServer;

  const ConnectPageArguments({
    this.initialUri,
    this.additionalServer = false,
  });
}

class ConnectPage extends StatefulWidget {
  static const routeName = '/connect';

  final IrcUri? initialUri;
  final bool additionalServer;

  const ConnectPage({
    super.key,
    this.initialUri,
    this.additionalServer = false,
  });

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  static const _nativeServerHost = appIrcServerHost;
  static const _nativeServerPort = appIrcServerPort;

  bool _loading = false;
  Exception? _error;
  _ServerFeatures _serverFeatures =
      _ServerFeatures(networkName: appIrcServerHost);
  Client? _client;
  String? _pinnedCertSHA1;
  bool _obscurePassword = true;
  bool _nicknameMissing = false;
  bool _serverMissing = false;

  final serverController = TextEditingController();
  final nicknameController = TextEditingController();
  final passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();

    if (widget.initialUri != null) {
      _populateFromUri(widget.initialUri!);
    }
  }

  void _populateFromUri(IrcUri uri) {
    var server = '';
    if (uri.host != null) {
      server = uri.host!;
    }
    if (uri.port != null) {
      server += ':${uri.port}';
    }
    serverController.text = server;

    if (uri.auth != null) {
      nicknameController.text = uri.auth!.username;
    }
  }

  ServerEntry _generateServerEntry() {
    if (widget.additionalServer) {
      var raw = serverController.text.trim();
      if (raw.isEmpty) {
        throw const FormatException('Server is required');
      }
      var uri = Uri.tryParse(
          raw.contains('://') ? raw : 'ircs://${raw.replaceAll(' ', '')}');
      if (uri == null || uri.host.isEmpty) {
        throw const FormatException('Invalid server address');
      }
      var tls = uri.scheme.toLowerCase() != 'irc';
      return ServerEntry(
        host: uri.host,
        port: uri.hasPort ? uri.port : (tls ? 6697 : 6667),
        tls: tls,
        nick: nicknameController.text.trim(),
        pinnedCertSHA1: _pinnedCertSHA1,
      );
    }
    return ServerEntry(
      host: _nativeServerHost,
      port: _nativeServerPort,
      tls: true,
      nick: nicknameController.text.trim(),
      pinnedCertSHA1: _pinnedCertSHA1,
    );
  }

  Future<Client> _connect({ConnectParams? connectParams}) async {
    var prefs = context.read<Prefs>();

    var client = _client;
    if (client != null && client.state == ClientState.connected) {
      try {
        // Make sure the connection is still alive and usable
        // Note, some servers reject PING before registration
        await client.fetchAvailableCaps();
        return client;
      } on Exception {
        log.print('Failed to reuse client, creating a new one');
      }
    }

    _disconnect();

    var clientParams = connectParams ??
        connectParamsFromServerEntry(_generateServerEntry(), prefs);
    client = Client(clientParams, autoReconnect: false);
    _client = client;
    try {
      await client.connect(register: false);
      return client;
    } on Exception {
      client.dispose();
      if (_client == client) {
        _client = null;
      }
      rethrow;
    }
  }

  void _disconnect() {
    _client?.disconnect();
    _client = null;
  }

  void _submit() async {
    if (_loading) {
      return;
    }
    if (widget.additionalServer && serverController.text.trim().isEmpty) {
      setState(() {
        _error = null;
        _serverMissing = true;
      });
      return;
    }
    if (nicknameController.text.trim().isEmpty) {
      setState(() {
        _error = null;
        _nicknameMissing = true;
      });
      return;
    }

    var db = context.read<DB>();
    var prefs = context.read<Prefs>();
    var networkList = context.read<NetworkListModel>();
    var bufferList = context.read<BufferListModel>();
    var clientProvider = context.read<ClientProvider>();

    prefs.nickname = nicknameController.text.trim();

    ServerEntry serverEntry;
    try {
      serverEntry = _generateServerEntry();
    } on FormatException catch (err) {
      setState(() {
        _error = err;
      });
      return;
    }
    if (passwordController.text.isNotEmpty) {
      serverEntry.saslPlainUsername = nicknameController.text.trim();
      serverEntry.saslPlainPassword = passwordController.text;
    }
    var clientParams = connectParamsFromServerEntry(serverEntry, prefs);

    setState(() {
      _loading = true;
      _obscurePassword = true;
      _nicknameMissing = false;
    });

    Client client;
    NetworkModel? network;
    try {
      client = await _connect(connectParams: clientParams);

      await db.storeServer(serverEntry);
      var networkEntry =
          await db.storeNetwork(NetworkEntry(server: serverEntry.id!));
      network =
          NetworkModel(serverEntry, networkEntry, client.nick, client.realname);
      network.setIgnoredNicks(await loadIgnoredNicks());
      networkList.add(network);
      clientProvider.add(client, network);
      var serverBufferEntry = await db.storeBuffer(
          BufferEntry(name: statusBufferName, network: network.networkId));
      bufferList.add(BufferModel(entry: serverBufferEntry, network: network));

      await client.register(clientParams);
      if (clientParams.saslPlain == null &&
          passwordController.text.isNotEmpty) {
        var account = nicknameController.text.trim();
        client.send(IrcMessage('PRIVMSG',
            ['NickServ', 'IDENTIFY $account ${passwordController.text}']));
      }
    } on Exception catch (err) {
      if (network != null) {
        clientProvider.remove(network);
        await db.deleteNetwork(network.networkId);
      } else {
        _disconnect();
      }
      setState(() {
        _loading = false;
        _error = err;
        if (err is IrcException) {
          if (err.msg.cmd == 'FAIL' &&
              err.msg.params[1] == 'ACCOUNT_REQUIRED') {
            _serverFeatures.passwordRequired = true;
          }
        }
      });
      return;
    }

    // Ownership moved to ClientProvider; do not let this page dispose it.
    if (_client == client) {
      _client = null;
    }
    if (mounted) {
      if (widget.additionalServer) {
        Navigator.pop(context);
      } else {
        unawaited(
            Navigator.pushReplacementNamed(context, BufferListPage.routeName));
      }
    }
  }

  void _handleServerFocusChange(bool hasFocus) async {
    if (widget.additionalServer || hasFocus || serverController.text.isEmpty) {
      return;
    }

    var serverText = serverController.text;

    _ServerFeatures features;
    try {
      features = await _fetchServerFeatures();
    } on Exception catch (err) {
      if (serverText != serverController.text || !mounted) {
        return;
      }
      log.print('Failed to fetch server caps', error: err);
      setState(() {
        _error = err;
      });

      if (err is BadCertException) {
        askBadCertficate(context, err.badCert);
      }

      return;
    }

    if (serverText != serverController.text || !mounted) {
      return;
    }

    setState(() {
      _error = null;
      _serverFeatures = features;
    });
  }

  Future<_ServerFeatures> _fetchServerFeatures() async {
    IrcAvailableCapRegistry availableCaps;
    IrcIsupportRegistry isupport;
    try {
      var client = await _connect();

      try {
        availableCaps = await client.fetchAvailableCaps();
      } on IrcException catch (err) {
        if (err.msg.cmd == ERR_UNKNOWNCOMMAND) {
          availableCaps = IrcAvailableCapRegistry();
        } else {
          rethrow;
        }
      }

      var extendedIsupport =
          availableCaps.containsKey('draft/extended-isupport-0.2')
              ? 'draft/extended-isupport-0.2'
              : availableCaps.containsKey('draft/extended-isupport')
                  ? 'draft/extended-isupport'
                  : null;
      if (extendedIsupport != null && availableCaps.containsKey('batch')) {
        client.send(IrcMessage('CAP', ['REQ', 'batch $extendedIsupport']));
        isupport = await client.fetchIsupport();
      } else {
        isupport = IrcIsupportRegistry();
      }
    } on IrcException {
      _disconnect();
      rethrow;
    }
    return _ServerFeatures(
      passwordUnsupported: !availableCaps.containsSasl('PLAIN'),
      passwordRequired:
          availableCaps.accountRequired || isupport.accountRequired,
      networkName: isupport.network,
      nickLen: isupport.nickLen,
    );
  }

  @override
  void dispose() {
    _client?.dispose();
    serverController.dispose();
    nicknameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var err = _error;
    String? serverErr, nicknameErr, passwordErr;
    if (_serverMissing) {
      serverErr = 'Required';
    }
    if (_nicknameMissing) {
      nicknameErr = 'Required';
    }
    var colorScheme = Theme.of(context).colorScheme;
    if (err is IrcException) {
      switch (err.msg.cmd) {
        case 'FAIL':
          var code = err.msg.params[1];
          if (code == 'ACCOUNT_REQUIRED') {
            passwordErr = err.toString();
          } else {
            serverErr = err.toString();
          }
          break;
        case ERR_PASSWDMISMATCH:
          serverErr = 'Server password required but not supported ($err)';
          break;
        case ERR_SASLFAIL:
        case ERR_SASLTOOLONG:
        case ERR_SASLABORTED:
          passwordErr = err.toString();
          break;
        case ERR_NICKLOCKED:
        case ERR_ERRONEUSNICKNAME:
        case ERR_NICKNAMEINUSE:
        case ERR_NICKCOLLISION:
        case ERR_YOUREBANNEDCREEP:
          nicknameErr = err.toString();
          break;
        default:
          serverErr = err.toString();
          break;
      }
    } else if (err is BadCertException) {
      serverErr = 'Bad server certificate';
    } else if (err is SocketException) {
      serverErr = 'Network error: ${err.message}';
    } else {
      serverErr = _error?.toString();
    }

    var focusNode = FocusScope.of(context);
    var stableLoginMedia = MediaQuery.of(context).copyWith(
      textScaler: const TextScaler.linear(1.0),
    );
    var keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    const fieldGap = 8.0;
    const fieldHeight = 44.0;
    const serverDisplayName = 'Azerbaijan [AZ] IRC network';
    const connectButtonHeight = 40.0;
    const fieldTextAlignVertical = TextAlignVertical.center;
    var fieldTextStyle = TextStyle(
      color: Color(0xFFF5F7FB),
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w400,
    );
    const fieldStrutStyle = StrutStyle(
      fontSize: 14,
      height: 1.2,
      forceStrutHeight: true,
    );

    Widget connectPanel = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 4),
        Builder(builder: (context) {
          var serverField = _NativeLabeledConnectField(
            label: 'SERVER',
            errorText: serverErr,
            height: fieldHeight,
            child: TextField(
              controller: serverController,
              textAlignVertical: fieldTextAlignVertical,
              strutStyle: fieldStrutStyle,
              style: fieldTextStyle,
              decoration: _connectInputDecoration(
                context,
                hintText: 'Server',
                compact: true,
              ),
              scrollPadding: EdgeInsets.zero,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.next,
              onEditingComplete: () => focusNode.nextFocus(),
              onChanged: (value) {
                if (_serverMissing && value.trim().isNotEmpty) {
                  setState(() {
                    _serverMissing = false;
                  });
                }
              },
            ),
          );
          var nickField = _NativeLabeledConnectField(
            label: 'Username',
            errorText: nicknameErr,
            height: fieldHeight,
            child: TextField(
              maxLines: 1,
              textAlignVertical: fieldTextAlignVertical,
              strutStyle: fieldStrutStyle,
              style: fieldTextStyle,
              decoration: _connectInputDecoration(
                context,
                hintText: 'User',
                compact: true,
              ),
              scrollPadding: EdgeInsets.zero,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textCapitalization: TextCapitalization.none,
              controller: nicknameController,
              textInputAction: TextInputAction.next,
              inputFormatters: _serverFeatures.nickLen == null
                  ? null
                  : [
                      LengthLimitingTextInputFormatter(_serverFeatures.nickLen),
                    ],
              onEditingComplete: () => focusNode.nextFocus(),
              onChanged: (value) {
                if (_nicknameMissing && value.trim().isNotEmpty) {
                  setState(() {
                    _nicknameMissing = false;
                  });
                }
              },
            ),
          );
          var passwordField = _NativeLabeledConnectField(
            label: 'Password',
            errorText: passwordErr,
            height: fieldHeight,
            child: TextField(
              maxLines: 1,
              textAlignVertical: fieldTextAlignVertical,
              strutStyle: fieldStrutStyle,
              style: fieldTextStyle,
              obscureText: _obscurePassword,
              decoration: _connectInputDecoration(
                context,
                hintText: 'Password (optional)',
                compact: true,
                suffixIcon: SizedBox(
                  width: 42,
                  height: fieldHeight,
                  child: Center(
                    child: IconButton(
                      tooltip:
                          _obscurePassword ? 'Show password' : 'Hide password',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 38, height: 38),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
              scrollPadding: EdgeInsets.zero,
              controller: passwordController,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textCapitalization: TextCapitalization.none,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                _submit();
              },
            ),
          );
          return Container(
            padding: EdgeInsets.fromLTRB(10, 10, 10, 10),
            decoration: BoxDecoration(
              color: Color(0xFF14161B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Color(0xFF3B404C), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.36),
                  blurRadius: 30,
                  offset: Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF3A3F48), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: Color(0xFF22C55E),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'IRC Server',
                                  style: TextStyle(
                                    color: Color(0xFFF5F7FB),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ]),
                            SizedBox(height: 4),
                            Text(
                              serverDisplayName,
                              style: TextStyle(
                                color: Color(0xFF8B9098),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: Color(0xFF10B981).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: Color(0xFF34D399).withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          'secure',
                          style: TextStyle(
                            color: Color(0xFF6EE7B7),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                if (widget.additionalServer) ...[
                  serverField,
                  SizedBox(height: fieldGap),
                ],
                nickField,
                SizedBox(height: fieldGap),
                passwordField,
              ],
            ),
          );
        }),
        SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 118,
            height: connectButtonHeight,
            child: keyboardOpen
                ? const SizedBox.shrink()
                : FilledButton(
                    onPressed: _loading ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: Color(0xFF5865F2),
                      disabledBackgroundColor: Color(0xFF263858),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                      padding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: _loading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: colorScheme.onPrimary),
                          )
                        : Text(
                            'Connect',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              letterSpacing: 0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
          ),
        ),
        if (serverErr != null)
          Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              serverErr,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colorScheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF080B10),
      body: SafeArea(
        child: ColoredBox(
          color: Color(0xFF080B10),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 390),
                child: MediaQuery(
                  data: stableLoginMedia,
                  child: connectPanel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void askBadCertficate(BuildContext context, X509Certificate cert) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        Widget noButton = TextButton(
          child: const Text('Reject'),
          onPressed: () {
            Navigator.pop(context);
          },
        );
        Widget yesButton = TextButton(
          child: const Text('Accept Always'),
          onPressed: () {
            Navigator.pop(context);
            setState(() => _pinnedCertSHA1 = HEX.encode(cert.sha1));
            _handleServerFocusChange(false);
          },
        );
        return AlertDialog(
          title: const Text('Bad Certificate'),
          content: SingleChildScrollView(
              child: Text('Untrusted server certificate. '
                  'Only accept this certificate if you know what you\'re doing.\n\n'
                  'Issuer: ${cert.issuer}\n'
                  'SHA1 Fingerprint: ${HEX.encode(cert.sha1)}\n'
                  'From: ${cert.startValidity}\n'
                  'To: ${cert.endValidity}')),
          actions: [noButton, yesButton],
        );
      },
    );
  }
}

InputDecoration _connectInputDecoration(
  BuildContext context, {
  required String hintText,
  String? counterText,
  IconData? prefixIcon,
  Widget? suffixIcon,
  bool compact = false,
}) {
  return InputDecoration(
    hintText: hintText,
    counterText: counterText,
    isDense: true,
    filled: false,
    prefixIcon: prefixIcon == null
        ? null
        : Icon(prefixIcon, size: 21, color: Color(0xFF8EA0B8)),
    prefixIconConstraints: BoxConstraints(
      minWidth: compact ? 36 : 42,
      minHeight: compact ? 42 : 52,
    ),
    suffixIcon: suffixIcon,
    suffixIconConstraints: BoxConstraints(
      minWidth: compact ? 44 : 48,
      minHeight: compact ? 44 : 52,
    ),
    suffixIconColor: Color(0xFF8EA0B8),
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(
      horizontal: prefixIcon == null ? 12 : 0,
      vertical: compact ? 12 : 14,
    ),
    hintStyle: TextStyle(
      color: Color(0xFF6C7078),
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w400,
    ),
  );
}

class _NativeLabeledConnectField extends StatelessWidget {
  final String? label;
  final Widget child;
  final String? errorText;
  final double height;

  const _NativeLabeledConnectField({
    required this.label,
    required this.child,
    this.height = 50,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Color(0xFF8B9098),
                  fontSize: 10.5,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 4),
        ],
        _NativeConnectField(height: height, child: child),
        if (errorText != null)
          Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              errorText!,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: colorScheme.error),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _NativeConnectField extends StatelessWidget {
  final Widget child;
  final double height;

  const _NativeConnectField({
    required this.child,
    this.height = 50,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF0F1012),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFF343946),
          width: 1.15,
        ),
      ),
      child: child,
    );
  }
}
