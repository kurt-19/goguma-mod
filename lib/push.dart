import 'dart:async';
import 'dart:convert' show utf8;

import 'database.dart';
import 'irc/irc.dart';
import 'logging.dart';
import 'models.dart';
import 'notification_controller.dart';
import 'prefs.dart';
import 'webpush.dart';

class PushSubscription {
	final String endpoint;
	final String? tag;

	PushSubscription({
		required this.endpoint,
		this.tag,
	});

	PushSubscription.fromEntry(WebPushSubscriptionEntry entry) :
		endpoint = entry.endpoint,
		tag = entry.tag;
}

abstract class PushController {
	String get providerName;
	Future<PushSubscription> createSubscription(NetworkEntry network, String? vapidKey);
	Future<void> deleteSubscription(NetworkEntry network, PushSubscription sub);
}

class PushUnavailableException implements Exception {
	final String message;

	PushUnavailableException(this.message);

	@override
	String toString() {
		return message;
	}
}

// This function may called from a separate Isolate
Future<void> handlePushMessage(DB db, WebPushSubscriptionEntry sub, List<int> ciphertext) async {
	var config = WebPushConfig(
		p256dhPublicKey: sub.p256dhPublicKey,
		p256dhPrivateKey: sub.p256dhPrivateKey,
		authKey: sub.authKey,
	);
	var webPush = await WebPush.import(config);

	var bytes = await webPush.decrypt(ciphertext);
	var str = utf8.decode(bytes);
	var msg = IrcMessage.parse(str);

	log.print('Decrypted push message payload: $msg');

	var networkEntry = await _fetchNetwork(db, sub.network);
	if (networkEntry == null) {
		throw Exception('Got push message for an unknown network #${sub.network}');
	}
	var serverEntry = await _fetchServer(db, networkEntry.server);
	if (serverEntry == null) {
		throw Exception('Network #${sub.network} has an unknown server #${networkEntry.server}');
	}

	var prefs = await Prefs.load();

	var nickname = serverEntry.nick ?? prefs.nickname;
	var realname = prefs.realname ?? nickname;
	var network = NetworkModel(serverEntry, networkEntry, nickname, realname);

	var notifController = await NotificationController.init();

	switch (msg.cmd) {
	case 'PRIVMSG':
		var ctcp = CtcpMessage.parse(msg);
		if (ctcp != null && ctcp.cmd != 'ACTION') {
			log.print('Ignoring CTCP ${ctcp.cmd} message');
			break;
		}

		var target = msg.params[0];
		var isChannel = networkEntry.isupport.isChannel(target);
		if (!isChannel) {
			var channelCtx = msg.tags['+channel-context'] ?? msg.tags['+draft/channel-context'];
			if (channelCtx != null && networkEntry.isupport.isChannel(channelCtx) && await _fetchBuffer(db, channelCtx, networkEntry) != null) {
				target = channelCtx;
				isChannel = true;
			} else {
				target = msg.source!.name;
			}
		}

		var bufferEntry = await _fetchBuffer(db, target, networkEntry);
		if (bufferEntry == null) {
			bufferEntry = BufferEntry(name: target, network: sub.network);
			await db.storeBuffer(bufferEntry);
		}

		var buffer = BufferModel(entry: bufferEntry, network: network);
		if (buffer.muted) {
			break;
		}

		var msgEntry = MessageEntry(msg, bufferEntry.id!);

		if (isChannel) {
			await notifController.showHighlight([msgEntry], buffer);
		} else {
			await notifController.showDirectMessage([msgEntry], buffer);
		}
		break;
	case 'INVITE':
		await notifController.showInvite(msg, network);
		break;
	case 'MARKREAD':
		var target = msg.params[0];
		var bound = msg.params[1];
		if (bound == '*') {
			break;
		}
		if (!bound.startsWith('timestamp=')) {
			throw FormatException('Invalid MARKREAD bound: $msg');
		}
		var time = DateTime.parse(bound.replaceFirst('timestamp=', ''));

		var bufferEntry = await _fetchBuffer(db, target, networkEntry);
		if (bufferEntry == null) {
			break;
		}

		// TODO: we should check lastReadTime here, but we might be racing
		// against the main Isolate, which also receives MARKREAD via the TCP
		// connection and isn't aware about notifications opened via push

		var buffer = BufferModel(entry: bufferEntry, network: network);
		await notifController.cancelAllWithBuffer(buffer, time);
		break;
	default:
		log.print('Ignoring ${msg.cmd} message');
		return;
	}
}

Future<NetworkEntry?> _fetchNetwork(DB db, int id) async {
	var entries = await db.listNetworks();
	for (var entry in entries) {
		if (entry.id == id) {
			return entry;
		}
	}
	return null;
}

Future<ServerEntry?> _fetchServer(DB db, int id) async {
	var entries = await db.listServers();
	for (var entry in entries) {
		if (entry.id == id) {
			return entry;
		}
	}
	return null;
}

Future<BufferEntry?> _fetchBuffer(DB db, String name, NetworkEntry network) async {
	var entries = await db.listBuffers();
	for (var entry in entries) {
		if (entry.network == network.id && network.isupport.caseMapping.equals(entry.name, name)) {
			return entry;
		}
	}
	return null;
}
