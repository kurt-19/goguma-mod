import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc/irc.dart';
import '../models.dart';
import '../page/buffer.dart';
import '../page/buffer_details.dart';
import '../prefs.dart';
import '../profile_backend.dart';
import './emoji_sheet.dart';

const _defaultReactions = ['❤️', '👍', '👎', '😂', '😮', '😢'];

class MessageSheet extends StatelessWidget {
  final MessageModel message;
  final VoidCallback? onReply;

  const MessageSheet({super.key, required this.message, this.onReply});

  static void open(BuildContext context, BufferModel buffer,
      MessageModel message, VoidCallback? onReply) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        var client = context.read<ClientProvider>().get(buffer.network);
        return MultiProvider(
          providers: [
            ChangeNotifierProvider<BufferModel>.value(value: buffer),
            ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
            Provider<Client>.value(value: client),
          ],
          child: MessageSheet(message: message, onReply: onReply),
        );
      },
    );
  }

  void _handleViewProfile(BuildContext context, String sender) async {
    var db = context.read<DB>();
    var bufferList = context.read<BufferListModel>();
    var network = context.read<NetworkModel>();
    var navigator = Navigator.of(context);

    var buffer = bufferList.get(sender, network);
    if (buffer == null) {
      var entry = await db
          .storeBuffer(BufferEntry(name: sender, network: network.networkId));
      buffer = BufferModel(entry: entry, network: network);
      bufferList.add(buffer);
    }

    await navigator.pushNamed(BufferDetailsPage.routeName, arguments: buffer);
  }

  void _handleReact(BuildContext context, String reaction) async {
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();

    var reacted =
        message.reactionsByText[reaction]?.contains(client.nick) == true;
    var reactTag = reacted ? '+draft/unreact' : '+draft/react';

    await client.sendTextMessage(IrcMessage('TAGMSG', [
      buffer.name
    ], tags: {
      '+draft/reply': message.entry.networkMsgid!,
      '+reply': message.entry.networkMsgid!,
      reactTag: reaction,
    }));
  }

  Future<bool> _handleRedact(BuildContext context) async {
    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();
    var msgid = message.entry.networkMsgid;
    if (msgid == null) {
      return false;
    }

    var sender = message.msg.source!.name;
    var target = buffer.name;
    if (!client.isChannel(buffer.name) &&
        !isServerBufferName(buffer.name) &&
        !client.isMyNick(sender)) {
      target = client.nick;
    }

    if (client.isMyNick(sender)) {
      var body = message.msg.params.length > 1
          ? stripAnsiFormatting(message.msg.params[1])
          : '';
      var prefs = context.read<Prefs>();
      var credentials = prefs.mediaDeleteCredentialsInText(body);
      for (var credential in credentials) {
        try {
          await const ProfileBackendClient().deleteMedia(
            mediaId: credential.mediaId,
            deleteToken: credential.deleteToken,
          );
          await prefs.forgetMediaDeleteCredential(credential.url);
        } on Exception catch (err) {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(err.toString())),
            );
          }
          return false;
        }
      }
    }

    client.send(IrcMessage('REDACT', [target, msgid]));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    var ircMsg = message.msg;
    var sender = ircMsg.source!.name;
    var client = context.read<Client>();
    var buffer = context.watch<BufferModel>();
    var network = context.watch<NetworkModel>();
    var isOwn = client.isMyNick(sender);
    var ctcp = CtcpMessage.parse(ircMsg);
    var isAction = ctcp != null && ctcp.cmd == 'ACTION';
    var canSendMessage = canSendMessageToBuffer(buffer, network);
    var reactions = message.reactionsByText;
    var canReact =
        canSendMessage && message.entry.networkMsgid != null && client.canReact;
    var canShowDelete = !message.entry.redacted &&
        message.entry.networkMsgid != null &&
        client.canRedact;
    var canRedact = canShowDelete && (isOwn || network.isIrcOperator);
    var deleteLabel =
        network.isIrcOperator && !isOwn ? 'DELETE $sender' : 'DELETE';

    return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (onReply != null && (!isOwn || client.canReply))
        ListTile(
          title: Text('REPLY'),
          leading: Icon(Icons.reply),
          onTap: () {
            Navigator.pop(context);
            onReply!();
          },
        ),
      if (canReact)
        Container(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _defaultReactions
                .map((reaction) => IconButton.filledTonal(
                      isSelected:
                          reactions[reaction]?.contains(client.nick) ?? false,
                      constraints: BoxConstraints(minWidth: 50, minHeight: 50),
                      onPressed: () {
                        Navigator.pop(context);
                        _handleReact(context, reaction);
                      },
                      icon: Text(
                        reaction,
                        style: TextStyle(fontSize: 20),
                      ),
                    ))
                .followedBy([
              IconButton.filledTonal(
                isSelected: false,
                constraints: BoxConstraints(minWidth: 50, minHeight: 50),
                onPressed: () async {
                  var reaction = await EmojiSheet.open(context);
                  if (!context.mounted) {
                    return;
                  }
                  if (reaction != null) {
                    _handleReact(context, reaction);
                  }
                  Navigator.pop(context);
                },
                icon: Icon(Icons.add_reaction),
              ),
            ]).toList(),
          ),
        ),
      if (!isOwn)
        ListTile(
          title: Text('MESSAGE $sender'),
          leading: Icon(Icons.chat_bubble),
          onTap: () {
            var network = context.read<NetworkModel>();
            Navigator.pop(context);
            BufferPage.open(context, sender, network);
          },
        ),
      if (!isOwn)
        ListTile(
          title: Text('VIEW PROFILE'),
          leading: Icon(Icons.person),
          onTap: () {
            Navigator.pop(context);
            _handleViewProfile(context, sender);
          },
        ),
      if (canShowDelete)
        ListTile(
          enabled: canRedact,
          title: Text(deleteLabel),
          leading: Icon(Icons.delete_outline),
          onTap: canRedact
              ? () async {
                  var redacted = await _handleRedact(context);
                  if (redacted && context.mounted) {
                    Navigator.pop(context);
                  }
                }
              : null,
        ),
      ListTile(
        title: Text('COPY'),
        leading: Icon(Icons.content_copy),
        onTap: () async {
          var text = '';
          if (isAction) {
            var body = ctcp.param;
            if (body == null) {
              return;
            }
            body = stripAnsiFormatting(body);
            text = '$sender $body';
          } else {
            var body = stripAnsiFormatting(ircMsg.params[1]);
            text = '<$sender> $body';
          }
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            Navigator.pop(context);
          }
        },
      ),
    ]));
  }
}
