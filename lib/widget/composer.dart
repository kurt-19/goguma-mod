import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:share_handler/share_handler.dart';

import '../client.dart';
import '../client_controller.dart';
import '../commands.dart';
import '../database.dart';
import '../irc/irc.dart';
import '../models.dart';
import '../prefs.dart';
import '../profile_backend.dart';
import '../widget/app_snack_bar.dart';
import '../widget/emoji_sheet.dart';

final whitespaceRegExp = RegExp(r'\s', unicode: true);
final _hexColorRegExp = RegExp(r'^#?[0-9A-Fa-f]{6}$');

const _mircPalette = [
  0xFFFFFF,
  0x000000,
  0x00007F,
  0x009300,
  0xFF0000,
  0x7F0000,
  0x9C009C,
  0xFC7F00,
  0xFFFF00,
  0x00FC00,
  0x009393,
  0x00FFFF,
  0x0000FC,
  0xFF00FF,
  0x7F7F7F,
  0xD2D2D2,
];

class Composer extends StatefulWidget {
  final SharedMedia? sharedMedia;
  final Draft? draft;

  const Composer({super.key, this.sharedMedia, this.draft});

  @override
  ComposerState createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final _formKey = GlobalKey<FormState>();
  final _focusNode = FocusNode();
  final _controller = _CommandTextEditingController();
  final _imagePicker = ImagePicker();
  final List<String> _pendingUploadUrls = [];

  bool _isCommand = false;
  bool _hasTextInput = false;
  bool _addMenuLoading = false;

  DateTime? _ownTyping;
  Timer? _typingIdleTimer;
  MessageModel? _replyTo;
  AudioRecorder? _recorder;
  Stream<String>? _recordTimer;

  @override
  void initState() {
    super.initState();

    if (widget.sharedMedia != null) {
      _initSharedMedia(widget.sharedMedia!);
    }

    if (widget.draft != null) {
      _initDraft(widget.draft!);
    }
  }

  void _initSharedMedia(SharedMedia sharedMedia) {
    var text = sharedMedia.content;
    if (text != null) {
      if (text.startsWith('/')) {
        // Insert a zero-width space to ensure this doesn't end up
        // being executed as a command
        text = '\u200B$text';
      }
      _controller.text = text;
      _isCommand = false;
      _hasTextInput = text.trim().isNotEmpty;
    }

    var attachments = sharedMedia.attachments ?? [];
    if (!attachments.isEmpty) {
      var file = XFile(attachments.single!.path);
      _runAddMenuTask(() async {
        await _uploadFile(file);
      });
    }
  }

  void _initDraft(Draft draft) async {
    _controller.text = draft.text;
    _isCommand = draft.text.startsWith('/') && !draft.text.contains('\n');
    _hasTextInput = draft.text.trim().isNotEmpty;

    if (draft.replyTo != null) {
      var db = context.read<DB>();
      var msg = await db.fetchMessage(draft.replyTo!);
      if (msg != null) {
        _replyTo = MessageModel(entry: msg);
      }
    }
  }

  String? _getReplyPrefix() {
    if (_replyTo == null) {
      return null;
    }

    var nickname = _replyTo!.msg.source!.name;
    var prefix = '$nickname: ';
    if (prefix.startsWith('/')) {
      // Insert a zero-width space to ensure this doesn't end up
      // being executed as a command
      prefix = '\u200B$prefix';
    }
    return prefix;
  }

  int _getMaxPrivmsgLen() {
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();

    var msg = IrcMessage(
      'PRIVMSG',
      [buffer.name, ''],
      source: IrcSource(
        client.nick,
        user: '_' * client.isupport.usernameLen,
        host: '_' * client.isupport.hostnameLen,
      ),
    );
    var raw = msg.toString() + '\r\n';
    return client.isupport.lineLen - raw.length;
  }

  List<IrcMessage> _buildPrivmsg(String text) {
    var buffer = context.read<BufferModel>();
    var maxLen = _getMaxPrivmsgLen();
    var chatTextColor = context.read<Prefs>().chatTextColor;

    List<IrcMessage> messages = [];
    for (var line in text.split('\n')) {
      Map<String, String?> tags = {};

      while (maxLen > 1 && line.length > maxLen) {
        // Pick a good cut-off index, preferably at a whitespace
        // character
        var i = line.substring(0, maxLen).lastIndexOf(whitespaceRegExp);
        if (i <= 0) {
          i = maxLen - 1;
        }

        var leading = line.substring(0, i + 1);
        line = line.substring(i + 1);

        messages.add(IrcMessage('PRIVMSG',
            [buffer.name, _applyOutgoingIrcColor(leading, chatTextColor)],
            tags: tags));
      }

      // We'll get ERR_NOTEXTTOSEND if we try to send an empty message
      if (line != '') {
        messages.add(IrcMessage('PRIVMSG',
            [buffer.name, _applyOutgoingIrcColor(line, chatTextColor)],
            tags: tags));
      }
    }

    return messages;
  }

  String _applyOutgoingIrcColor(String text, String hexColor) {
    var code = _nearestMirccolorCode(hexColor);
    if (code == null ||
        text.trim().isEmpty ||
        text.contains('\x03') ||
        text.contains('\x0F')) {
      return text;
    }
    return '\x03${code.toString().padLeft(2, '0')}$text\x0F';
  }

  int? _nearestMirccolorCode(String hexColor) {
    var clean = hexColor.trim().replaceFirst('#', '');
    if (!_hexColorRegExp.hasMatch(clean)) {
      return null;
    }
    var rgb = int.tryParse(clean, radix: 16);
    if (rgb == null) {
      return null;
    }
    var r = (rgb >> 16) & 255;
    var g = (rgb >> 8) & 255;
    var b = rgb & 255;
    int? bestIndex;
    int? bestDistance;
    for (var i = 0; i < _mircPalette.length; i++) {
      var value = _mircPalette[i];
      var dr = r - ((value >> 16) & 255);
      var dg = g - ((value >> 8) & 255);
      var db = b - (value & 255);
      var distance = dr * dr + dg * dg + db * db;
      if (bestDistance == null || distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  void _send(List<IrcMessage> messages) async {
    var client = context.read<Client>();

    List<Future<IrcMessage>> futures = [];
    for (var msg in messages) {
      var localMessageId = await _appendOptimisticMessage(msg);
      futures.add(client.sendTextMessage(msg).then((echo) async {
        if (localMessageId != null) {
          await _replaceOptimisticMessage(localMessageId, echo);
        }
        return echo;
      }));
    }

    try {
      await Future.wait(futures);
    } on IrcException catch (err) {
      if (err.msg.cmd != ERR_NOSUCHNICK) {
        rethrow;
      }
    }
  }

  Future<int?> _appendOptimisticMessage(IrcMessage msg) async {
    if (msg.cmd != 'PRIVMSG' || !mounted) {
      return null;
    }

    var db = context.read<DB>();
    var buffer = context.read<BufferModel>();
    var bufferList = context.read<BufferListModel>();
    var client = context.read<Client>();
    var network = context.read<NetworkModel>();
    var localMsg = msg.copyWith(source: IrcSource(client.nick));
    var entry = MessageEntry(localMsg, buffer.id);

    await db.storeMessages([entry]);
    rememberOptimisticSelfEcho(network, buffer.name, msg.params[1], entry.id!);
    bufferList.bumpLastDeliveredTime(buffer, entry.time);

    if (buffer.messageHistoryLoaded) {
      buffer.addMessages([
        MessageModel(
          entry: entry,
        ),
      ], append: true);
    }
    return entry.id;
  }

  Future<void> _replaceOptimisticMessage(int messageId, IrcMessage echo) async {
    if (echo.cmd != 'PRIVMSG' || echo.tags['msgid'] == null || !mounted) {
      return;
    }

    var db = context.read<DB>();
    var buffer = context.read<BufferModel>();
    var replacement = MessageEntry(echo, buffer.id)..id = messageId;
    await db.storeMessages([replacement]);
    if (mounted && buffer.messageHistoryLoaded) {
      buffer.replaceMessage(messageId, replacement);
    }
  }

  void _showStatusLine(String text) {
    unawaited(appendLocalStatusMessage(
      db: context.read<DB>(),
      bufferList: context.read<BufferListModel>(),
      network: context.read<NetworkModel>(),
      text: text,
    ));
  }

  void _submitCommand(String text) {
    String name;
    String? param;
    var i = text.indexOf(' ');
    if (i >= 0) {
      name = text.substring(0, i);
      param = text.substring(i + 1);
    } else {
      name = text;
    }
    name = name.toLowerCase();

    var cmd = commands[name];
    if (cmd == null) {
      _showStatusLine('Unknown command: /$name');
      return;
    }

    String? msgText;
    try {
      msgText = cmd.exec(context, param);
    } on CommandException catch (err) {
      _showStatusLine(err.message);
      return;
    }
    if (msgText != null) {
      var buffer = context.read<BufferModel>();
      if (isServerBufferName(buffer.name)) {
        return;
      }
      var msg = IrcMessage('PRIVMSG', [buffer.name, msgText]);
      _send([msg]);
    }
  }

  Future<bool> _showConfirmSendDialog(String text, int msgCount) async {
    var result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Multiple messages'),
        content: Text(
            'You are about to send $msgCount messages because you composed a long text. Are you sure?'),
        actions: [
          TextButton(
            child: Text('CANCEL'),
            onPressed: () {
              Navigator.pop(context, false);
            },
          ),
          ElevatedButton(
            child: Text('SEND'),
            onPressed: () {
              Navigator.pop(context, true);
            },
          ),
        ],
      ),
    );
    return result!;
  }

  Future<bool> _submitText(String text) async {
    var buffer = context.read<BufferModel>();
    if (isServerBufferName(buffer.name)) {
      return true;
    }

    var messages = _buildPrivmsg(text);
    if (messages.length == 0) {
      return true;
    } else if (messages.length > 3) {
      var confirmed = await _showConfirmSendDialog(text, messages.length);
      if (!confirmed || !mounted) {
        return false;
      }
    }

    _send(messages);
    return true;
  }

  void _submit() async {
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();

    // Remove empty lines at start and end of the text (can happen when
    // pasting text)
    var lines = _controller.text.split('\n');
    while (!lines.isEmpty && lines.first.trim() == '') {
      lines = lines.sublist(1);
    }
    while (!lines.isEmpty && lines.last.trim() == '') {
      lines = lines.sublist(0, lines.length - 1);
    }
    var text = lines.join('\n');

    var ok = true;
    var hasPendingUploads = _pendingUploadUrls.isNotEmpty;
    var isStatusBuffer = isServerBufferName(buffer.name);
    if (isStatusBuffer && (!_isCommand || hasPendingUploads)) {
      if (text.trim().isNotEmpty || hasPendingUploads) {
        _showStatusLine('You are not on a channel');
      }
      _typingIdleTimer?.cancel();
      _typingIdleTimer = null;
      _pendingUploadUrls.clear();
      _controller.text = '';
      _hasTextInput = false;
      _focusNode.requestFocus();
      setState(() {
        _isCommand = false;
        _hasTextInput = false;
      });
      return;
    }
    if (!canSendMessageToBuffer(buffer, network)) {
      _showStatusLine('Network is offline');
      return;
    }
    if (_isCommand && !hasPendingUploads) {
      assert(text.startsWith('/'));
      assert(!text.contains('\n'));

      if (text.startsWith('//')) {
        ok = await _submitText(text.substring(1));
      } else {
        _submitCommand(text.substring(1));
      }
    } else if (isServerBufferName(buffer.name)) {
      ok = true;
    } else {
      var outgoingParts = <String>[];
      if (text.trim().isNotEmpty) {
        outgoingParts.add(text);
      }
      outgoingParts.addAll(_pendingUploadUrls);
      ok = await _submitText(outgoingParts.join(' '));
    }
    if (!ok) {
      return;
    }

    _sendTypingStatus(active: false);
    _replyTo = null;
    _pendingUploadUrls.clear();
    _controller.text = '';
    _hasTextInput = false;
    _focusNode.requestFocus();
    setState(() {
      _isCommand = false;
      _hasTextInput = _controller.text.trim().isNotEmpty;
    });
  }

  Future<Iterable<_AutocompleteOption>> _buildOptions(
      TextEditingValue textEditingValue) async {
    var text = textEditingValue.text;
    var network = context.read<NetworkModel>();
    var client = context.read<Client>();
    var bufferList = context.read<BufferListModel>();

    if (text.startsWith('/') && !text.contains(' ')) {
      text = text.toLowerCase().substring(1);
      return commands.entries.where((entry) {
        return entry.key.startsWith(text) && entry.value.isAvailable(context);
      }).map((entry) =>
          _AutocompleteOption('/' + entry.key, entry.value.description));
    }

    String pattern;
    var i = text.lastIndexOf(' ');
    if (i >= 0) {
      pattern = text.substring(i + 1);
    } else {
      pattern = text;
    }
    pattern = pattern.toLowerCase();

    if (pattern.length < 3) {
      return [];
    }

    if (!client.isChannel(pattern)) {
      return [];
    }

    return bufferList.buffers
        .where((buffer) => buffer.network == network)
        .map((buffer) => _AutocompleteOption(buffer.name, buffer.topic))
        .where((option) {
          return option.value.toLowerCase().startsWith(pattern);
        })
        .take(10)
        .map((option) {
          if (option.value.startsWith('/')) {
            // Insert a zero-width space to ensure this doesn't end up
            // being executed as a command
            return _AutocompleteOption(
                '\u200B' + option.value, option.description);
          }
          return option;
        });
  }

  String _displayStringForOption(_AutocompleteOption option) {
    var text = _controller.text;

    var i = text.lastIndexOf(' ');
    if (i >= 0) {
      return text.substring(0, i + 1) + option.value + ' ';
    } else if (option.value.startsWith('/')) {
      // command
      return option.value + ' ';
    } else {
      return option.value + ': ';
    }
  }

  void _sendTypingStatus({bool? active}) {
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();
    if (isServerBufferName(buffer.name)) {
      _typingIdleTimer?.cancel();
      _typingIdleTimer = null;
      return;
    }
    if (!client.caps.enabled.contains('message-tags') ||
        !client.isupport.isClientTagAllowed('typing')) {
      _typingIdleTimer?.cancel();
      _typingIdleTimer = null;
      return;
    }

    var isActive = active ?? _controller.text.isNotEmpty;
    if (isActive) {
      _typingIdleTimer?.cancel();
      _typingIdleTimer = Timer(Duration(seconds: 1), () {
        if (mounted) {
          _sendTypingStatus(active: false);
        }
      });
    } else {
      _typingIdleTimer?.cancel();
      _typingIdleTimer = null;
    }

    var notify = _setOwnTyping(isActive);
    if (notify) {
      var msg = IrcMessage('TAGMSG', [buffer.name],
          tags: {'+typing': isActive ? 'active' : 'done'});
      client.send(msg);
    }
  }

  bool _setOwnTyping(bool active) {
    bool notify;
    var time = DateTime.now();
    if (!active) {
      notify = _ownTyping != null;
      _ownTyping = null;
    } else {
      notify = _ownTyping == null ||
          _ownTyping!.add(Duration(seconds: 1)).isBefore(time);
      if (notify) {
        _ownTyping = time;
      }
    }
    return notify;
  }

  Draft? get draft {
    if (_controller.text.isEmpty) {
      return null;
    }
    return Draft(text: _controller.text, replyTo: _replyTo?.id);
  }

  void setReplyTo(MessageModel msg) {
    var nickname = msg.msg.source!.name;
    var prefix = '$nickname: ';
    if (prefix.startsWith('/')) {
      // Insert a zero-width space to ensure this doesn't end up
      // being executed as a command
      prefix = '\u200B$prefix';
    }

    _replyTo = msg;
    if (!_controller.text.startsWith(prefix)) {
      _controller.text = prefix + _controller.text;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
    _focusNode.requestFocus();
    setState(() {
      _isCommand = false;
      _hasTextInput = _controller.text.trim().isNotEmpty;
    });
  }

  Future<void> _uploadFile(XFile file) async {
    var client = context.read<Client>();
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    var prefs = context.read<Prefs>();
    const backend = ProfileBackendClient();
    var upload = await backend.uploadMedia(
      server: client.params.host,
      target: buffer.name,
      nick: network.nickname,
      file: file,
    );

    try {
      await prefs.rememberMediaDeleteCredential(
        url: upload.savedUrl,
        mediaId: upload.mediaId,
        deleteToken: upload.deleteToken,
        expiresAt: upload.expiresAt,
      );
    } on Object {
      try {
        await backend.deleteMedia(
          mediaId: upload.mediaId,
          deleteToken: upload.deleteToken,
        );
      } on Object {
        // Preserve the local persistence error.
      }
      rethrow;
    }

    if (!mounted) {
      try {
        await backend.deleteMedia(
          mediaId: upload.mediaId,
          deleteToken: upload.deleteToken,
        );
        await prefs.forgetMediaDeleteCredential(upload.savedUrl);
      } on Object {
        // Keep the credential if cleanup could not reach the backend.
      }
      return;
    }

    setState(() {
      _pendingUploadUrls.add(upload.savedUrl);
    });
  }

  String _formatRecordDuration(Duration duration) {
    var totalSeconds = duration.inSeconds;
    var minutes = totalSeconds ~/ 60;
    var seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Stream<String> _recordDurationStream(DateTime startedAt) {
    return Stream.periodic(Duration(seconds: 1), (_) {
      return _formatRecordDuration(DateTime.now().difference(startedAt));
    });
  }

  Future<void> _startRecord() async {
    var buffer = context.read<BufferModel>();
    var network = context.read<NetworkModel>();
    if (!canSendMessageToBuffer(buffer, network)) {
      _showStatusLine('Network is offline');
      return;
    }
    if (isServerBufferName(buffer.name)) {
      _showStatusLine('Status accepts IRC commands only');
      return;
    }

    var recorder = AudioRecorder();
    Directory? recordDir;
    try {
      if (!await recorder.hasPermission()) {
        await recorder.dispose();
        if (mounted) {
          showTopRightSnackBar(
              context,
              SnackBar(
                content: Text('Microphone permission denied'),
              ));
        }
        return;
      }

      var dir = await Directory.systemTemp.createTemp('irc-voice-');
      recordDir = dir;
      var path =
          '${dir.path}${Platform.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );

      if (!mounted) {
        var file = await recorder.stop();
        await recorder.dispose();
        if (file != null) {
          var recordedFile = File(file);
          if (await recordedFile.exists()) {
            await recordedFile.delete();
          }
          var parent = recordedFile.parent;
          if (await parent.exists()) {
            await parent.delete(recursive: true);
          }
        }
        return;
      }

      setState(() {
        _recorder = recorder;
        _recordTimer = _recordDurationStream(DateTime.now());
      });
    } on Exception catch (err) {
      await recorder.dispose();
      var dir = recordDir;
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
      if (mounted) {
        showTopRightSnackBar(
            context,
            SnackBar(
              content: Text(err.toString()),
            ));
      }
    }
  }

  Future<void> _finishRecord() async {
    var recorder = _recorder;
    if (recorder == null) {
      return;
    }

    String? file;
    try {
      file = await recorder.stop();
    } finally {
      await recorder.dispose();
      if (mounted) {
        setState(() {
          _recorder = null;
          _recordTimer = null;
        });
      }
    }

    if (file == null) {
      return;
    }
    var recordedPath = file;
    var uploaded = false;
    await _runAddMenuTask(() async {
      try {
        await _uploadFile(XFile(recordedPath, mimeType: 'audio/mp4'));
        uploaded = true;
      } finally {
        var recordedFile = File(recordedPath);
        if (await recordedFile.exists()) {
          await recordedFile.delete();
        }
        var parent = recordedFile.parent;
        if (await parent.exists()) {
          await parent.delete(recursive: true);
        }
      }
    });
    if (mounted && uploaded) {
      _submit();
    }
  }

  Future<void> _runAddMenuTask(Future<void> Function() f) async {
    setState(() {
      _addMenuLoading = true;
    });
    try {
      await f();
    } on Exception catch (err) {
      if (mounted) {
        showTopRightSnackBar(
            context,
            SnackBar(
              content: Text(err.toString()),
            ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _addMenuLoading = false;
        });
      }
    }
  }

  Future<void> _cancelRecord() async {
    var file = await _recorder?.stop();
    await _recorder?.dispose();
    if (file != null) {
      var recordedFile = File(file);
      if (await recordedFile.exists()) {
        await recordedFile.delete();
      }
      var parent = recordedFile.parent;
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    }
  }

  @override
  void dispose() {
    _typingIdleTimer?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    unawaited(_cancelRecord());
    super.dispose();
  }

  Widget _buildTextField(BuildContext context, TextEditingController controller,
      FocusNode focusNode, VoidCallback onFieldSubmitted) {
    var client = context.read<Client>();
    var prefs = context.read<Prefs>();
    var buffer = context.read<BufferModel>();
    var isStatusBuffer = isServerBufferName(buffer.name);
    var scheme = Theme.of(context).colorScheme;
    var sendTyping = prefs.typingIndicator && !isStatusBuffer;

    ContentInsertionConfiguration? contentInsertionConfiguration;
    if (!isStatusBuffer && client.isupport.filehost != null) {
      contentInsertionConfiguration = ContentInsertionConfiguration(
        onContentInserted: (data) async {
          if (!data.hasData) {
            return;
          }
          var file = XFile.fromData(data.data!,
              mimeType: data.mimeType, path: data.uri);
          await _runAddMenuTask(() async {
            await _uploadFile(file);
          });
        },
      );
    }

    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      maxLines: 1,
      textAlignVertical: TextAlignVertical.center,
      onChanged: (value) {
        if (sendTyping) {
          _sendTypingStatus();
        }

        var needsUpdate = false;
        var replyPrefix = _getReplyPrefix();
        if (replyPrefix != null && !value.startsWith(replyPrefix)) {
          _replyTo = null;
          needsUpdate = true;
        }

        var isCommand = value.startsWith('/') && !value.contains('\n');
        if (_isCommand != isCommand) {
          _isCommand = isCommand;
          needsUpdate = true;
        }
        var hasTextInput = value.trim().isNotEmpty;
        if (_hasTextInput != hasTextInput) {
          _hasTextInput = hasTextInput;
          needsUpdate = true;
        }
        if (needsUpdate) {
          setState(() {});
        }
      },
      onFieldSubmitted: (value) {
        onFieldSubmitted();
        _submit();
      },
      // Prevent the virtual keyboard from being closed when
      // sending a message
      onEditingComplete: () {},
      decoration: InputDecoration(
        hintText: _pendingUploadUrls.isEmpty
            ? 'Write a message...'
            : 'Media ready to send',
        hintMaxLines: 1,
        isDense: true,
        border: InputBorder.none,
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
          height: 1.0,
          fontWeight: FontWeight.w500,
        ),
        contentPadding: EdgeInsets.fromLTRB(12, 0, 7, 0),
      ),
      style: TextStyle(
        color: scheme.onSurface,
        fontSize: 15,
        height: 1.0,
        fontWeight: FontWeight.w500,
      ),
      cursorColor: scheme.primary,
      textInputAction: TextInputAction.send,
      scrollPadding: EdgeInsets.zero,
      keyboardType: TextInputType.text, // disallows newlines
      contentInsertionConfiguration: contentInsertionConfiguration,
    );
  }

  Widget _buildOptionsView(
      BuildContext context,
      AutocompleteOnSelected<_AutocompleteOption> onSelected,
      Iterable<_AutocompleteOption> options) {
    var listView = ListView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      itemCount: options.length,
      reverse: true,
      itemBuilder: (context, index) {
        var option = options.elementAt(index);
        return InkWell(
          onTap: () {
            onSelected(option);
          },
          child: Builder(
            builder: (context) {
              var highlight =
                  AutocompleteHighlightedOption.of(context) == index;
              if (highlight) {
                SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
                  Scrollable.ensureVisible(context, alignment: 0.5);
                });
              }
              return Container(
                color: highlight ? Theme.of(context).focusColor : null,
                padding: const EdgeInsets.all(16.0),
                child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: option.value),
                      if (option.description != null)
                        TextSpan(
                            text: '  ' + option.description!,
                            style: TextStyle(
                                color:
                                    Theme.of(context).colorScheme.secondary)),
                    ]),
                    overflow: TextOverflow.ellipsis),
              );
            },
          ),
        );
      },
    );

    return Material(elevation: 4.0, child: listView);
  }

  @override
  Widget build(BuildContext context) {
    var buffer = context.watch<BufferModel>();
    var network = context.watch<NetworkModel>();

    var canSendMessage = canSendMessageToBuffer(buffer, network);
    var isStatusBuffer = isServerBufferName(buffer.name);
    var canUseAddMenu = canSendMessage || isStatusBuffer;

    if (_recorder != null) {
      return SafeArea(
          maintainBottomViewPadding: true,
          child: Row(children: [
            Container(
              width: 15,
              height: 15,
              margin: EdgeInsets.all(10),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Expanded(child: Text('Recording audio...')),
            StreamBuilder(
                stream: _recordTimer!,
                initialData: '0:00',
                builder:
                    (BuildContext context, AsyncSnapshot<String> snapshot) =>
                        Text(snapshot.data ?? '')),
            IconButton(
              icon: Icon(Icons.delete),
              onPressed: () async {
                await _cancelRecord();
                setState(() {
                  _recorder = null;
                  _recordTimer = null;
                });
              },
              tooltip: 'Cancel',
              color: Colors.red,
            ),
            FloatingActionButton(
              onPressed: _finishRecord,
              tooltip: 'Accept',
              mini: true,
              elevation: 0,
              child: Icon(Icons.check, size: 18),
            ),
          ]));
    }

    var showRecordButton = canSendMessage &&
        !isStatusBuffer &&
        !_isCommand &&
        !_hasTextInput &&
        _pendingUploadUrls.isEmpty;
    var scheme = Theme.of(context).colorScheme;
    const composerHeight = 46.0;
    const composerButtonRadius = 12.0;
    const composerIconSize = 20.0;
    const recordIconSize = 24.0;
    const addMenuHeight = composerHeight;
    var softButtonColor = scheme.surfaceContainerHigh.withValues(alpha: 0.72);
    var softBorderColor = scheme.outlineVariant.withValues(alpha: 0.34);

    Widget softIconButton({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      Color? iconColor,
    }) {
      return Container(
        width: composerHeight,
        height: composerHeight,
        decoration: BoxDecoration(
          color: softButtonColor,
          borderRadius: BorderRadius.circular(composerButtonRadius),
          border: Border.all(color: softBorderColor),
        ),
        child: IconButton(
          icon: Icon(icon, size: composerIconSize),
          tooltip: tooltip,
          color: iconColor ?? scheme.onSurfaceVariant,
          constraints: BoxConstraints.tightFor(
            width: composerHeight,
            height: composerHeight,
          ),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
        ),
      );
    }

    var sendBackground = _isCommand ? Color(0xFFEF4444) : scheme.primary;
    var sendForeground = Color(0xFFFFFFFF);
    var sendButton = Tooltip(
      message:
          showRecordButton ? 'Record voice' : (_isCommand ? 'Execute' : 'Send'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: showRecordButton ? _startRecord : _submit,
        child: Container(
          width: composerHeight,
          height: composerHeight,
          decoration: BoxDecoration(
            color: sendBackground,
            borderRadius: BorderRadius.circular(composerButtonRadius),
          ),
          alignment: Alignment.center,
          child: Icon(
            showRecordButton
                ? Icons.mic
                : (_isCommand ? Icons.done : Icons.send),
            key: ValueKey('${showRecordButton}_${_isCommand}_send'),
            size: showRecordButton ? recordIconSize : composerIconSize,
            color: sendForeground,
          ),
        ),
      ),
    );

    Widget addMenu;
    if (_addMenuLoading) {
      addMenu = Container(
        width: composerHeight,
        height: addMenuHeight,
        decoration: BoxDecoration(
          color: softButtonColor,
          borderRadius: BorderRadius.circular(composerButtonRadius),
          border: Border.all(color: softBorderColor),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 17,
          height: 17,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      addMenu = softIconButton(
          icon: Icons.add,
          tooltip: 'Add',
          onPressed: canUseAddMenu
              ? () {
                  if (isStatusBuffer) {
                    _showStatusLine('Status accepts IRC commands only');
                    return;
                  }
                  showModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    showDragHandle: true,
                    builder: (context) => SafeArea(
                        child: Padding(
                            padding: EdgeInsets.fromLTRB(10, 0, 10, 12),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _NativeComposerAction(
                                    title: 'Share photo or video',
                                    icon: Icons.add_photo_alternate,
                                    onTap: () async {
                                      Navigator.pop(context);
                                      var file = await _imagePicker.pickMedia();
                                      if (file != null) {
                                        await _runAddMenuTask(() async {
                                          await _uploadFile(file);
                                        });
                                      }
                                    },
                                  ),
                                ]))),
                  );
                }
              : null);
    }

    var emojiButton = IconButton(
      icon: Icon(Icons.emoji_emotions_outlined, size: composerIconSize),
      tooltip: 'Smiles',
      color: scheme.onSurfaceVariant.withValues(alpha: 0.86),
      constraints: BoxConstraints.tightFor(width: 40, height: composerHeight),
      padding: EdgeInsets.zero,
      onPressed: () async {
        var emoji = await EmojiSheet.open(context);
        if (emoji == null || emoji.isEmpty) {
          return;
        }
        var prefix = _controller.text.isEmpty || _controller.text.endsWith(' ')
            ? ''
            : ' ';
        _controller.text += '$prefix$emoji ';
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
        _focusNode.requestFocus();
        setState(() {
          _hasTextInput = _controller.text.trim().isNotEmpty;
        });
      },
    );

    return SafeArea(
        maintainBottomViewPadding: true,
        child: Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Transform.translate(
                  offset: Offset.zero,
                  child: SizedBox(
                    width: composerHeight,
                    height: composerHeight,
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: addMenuHeight,
                      maxHeight: addMenuHeight,
                      child: addMenu,
                    ),
                  ),
                ),
                SizedBox(width: 5),
                Expanded(
                    child: AnimatedBuilder(
                  animation: _focusNode,
                  builder: (context, child) {
                    return ConstrainedBox(
                      constraints: BoxConstraints.tightFor(
                        height: composerHeight,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainer,
                          borderRadius:
                              BorderRadius.circular(composerButtonRadius),
                          border: Border.all(color: softBorderColor),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Row(children: [
                    Expanded(
                      child: RawAutocomplete(
                        optionsBuilder: _buildOptions,
                        displayStringForOption: _displayStringForOption,
                        fieldViewBuilder: _buildTextField,
                        focusNode: _focusNode,
                        textEditingController: _controller,
                        optionsViewBuilder: _buildOptionsView,
                        optionsViewOpenDirection: OptionsViewOpenDirection.up,
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      height: composerHeight,
                      child: emojiButton,
                    ),
                  ]),
                )),
                SizedBox(width: 5),
                sendButton,
              ],
            )));
  }
}

class _NativeComposerAction extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _NativeComposerAction({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        tileColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: Icon(icon, color: scheme.onSurfaceVariant),
        title: Text(title),
        onTap: onTap,
      ),
    );
  }
}

class _AutocompleteOption {
  final String value;
  final String? description;

  const _AutocompleteOption(this.value, [this.description]);
}

class _CommandTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    var textSpan = super.buildTextSpan(
        context: context, style: style, withComposing: withComposing);
    if (!text.startsWith('/')) {
      return textSpan;
    }

    var cmd = commands[text.toLowerCase().substring(1).trim()];
    if (cmd == null) {
      return textSpan;
    }

    var suggestion = cmd.usage;
    if (!text.endsWith(' ')) {
      suggestion = ' ' + cmd.usage;
    }

    var suggestColor = (style ?? DefaultTextStyle.of(context).style)
        .color!
        .withValues(alpha: 0.5);
    return TextSpan(style: style, children: [
      textSpan,
      TextSpan(text: suggestion, style: TextStyle(color: suggestColor)),
    ]);
  }
}
