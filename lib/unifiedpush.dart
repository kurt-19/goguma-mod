import 'dart:async';
import 'dart:convert' show base64UrlEncode;
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:unifiedpush/unifiedpush.dart';

import 'database.dart';
import 'logging.dart';
import 'push.dart';

class UnifiedPushController extends PushController {
	final Map<String, Completer<PushSubscription>> _pendingSubscriptions = {};
	String? _distributor;

	static UnifiedPushController? _instance;

	UnifiedPushController._();

	Future<void> _init() async {
		// initialize() succeeds when missing LinuxOptions, but then
		// getDistributor() fails an assertion
		if (Platform.isLinux) {
			throw PushUnavailableException('UnifiedPush not supported on Linux');
		}

		try {
			await UnifiedPush.initialize(
				onNewEndpoint: _handleNewEndpoint,
				onRegistrationFailed: _handleRegistrationFailed,
				onUnregistered: _handleUnregistered,
				onMessage: _handleMessage,
			);
		} on UnimplementedError {
			throw PushUnavailableException('UnifiedPush not supported on this platform');
		}

		var distributor = await UnifiedPush.getDistributor();
		if (distributor == null) {
			var distributors = await UnifiedPush.getDistributors();
			if (distributors.length == 0) {
				throw PushUnavailableException('No UnifiedPush distributor found');
			}
			// TODO: allow the user to select the distributor
			distributor = distributors.first;
			await UnifiedPush.saveDistributor(distributor);
		}
		log.print('Using UnifiedPush distributor: $distributor');
		_distributor = distributor;
	}

	static Future<UnifiedPushController> init() async {
		if (_instance == null) {
			_instance = UnifiedPushController._();
			await _instance!._init();
		}
		return _instance!;
	}

	@override
	String get providerName => 'unifiedpush:' + _distributor!;

	@override
	Future<PushSubscription> createSubscription(NetworkEntry network, String? vapidKey) async {
		var instance = _generateInstance();

		await UnifiedPush.register(instance: instance);

		var completer = Completer<PushSubscription>();
		_pendingSubscriptions[instance] = completer;
		try {
			return await completer.future.timeout(Duration(seconds: 30), onTimeout: () {
				throw TimeoutException('Timed out creating UnifiedPush subscription');
			});
		} finally {
			_pendingSubscriptions.remove(instance);
		}
	}

	@override
	Future<void> deleteSubscription(NetworkEntry network, PushSubscription sub) async {
		// Compat with old subscriptions
		// TODO: drop this
		var instance = sub.tag ?? 'network:${network.id}';
		await UnifiedPush.unregister(instance);
	}

	void _handleNewEndpoint(PushEndpoint endpoint, String instance) {
		log.print('New UnifiedPush endpoint for instance $instance');
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			log.print('Unhandled UnifiedPush endpoint update');
			// TODO: handle endpoint changes
			return;
		}
		completer.complete(PushSubscription(
			endpoint: endpoint.url,
			tag: instance,
		));
	}

	void _handleRegistrationFailed(FailedReason reason, String instance) {
		log.print('UnifiedPush registration failed for instance $instance');
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			log.print('Unhandled UnifiedPush failed registration');
			return;
		}
		completer.completeError(Exception('UnifiedPush registration failed'));
	}

	void _handleUnregistered(String instance) async {
		log.print('Unregistered UnifiedPush instance $instance');

		var db = await DB.open();
		var sub = await _fetchSubscriptionWithInstance(db, instance);
		if (sub == null) {
			log.print('Unregistered unknown UnifiedPush instance: $instance');
			return;
		}

		await db.deleteWebPushSubscription(sub.id!);
		// TODO: send WEBPUSH UNREGISTER to the IRC server
	}
}

// This function may called from a separate Isolate
@pragma('vm:entry-point')
void _handleMessage(PushMessage message, String instance) async {
	DartPluginRegistrant.ensureInitialized();

	var ciphertext = message.content;
	log.print('Got UnifiedPush message for $instance');

	var db = await DB.open();
	var sub = await _fetchSubscriptionWithInstance(db, instance);
	if (sub == null) {
		log.print('Got UnifiedPush push message for an unknown instance: $instance');
		throw Exception('Got UnifiedPush push message for an unknown instance');
	}

	await handlePushMessage(db, sub, ciphertext);
}

Future<WebPushSubscriptionEntry?> _fetchSubscriptionWithInstance(DB db, String instance) async {
	// TODO: drop old compat code
	var subs = await db.listWebPushSubscriptions();
	var prefix = 'network:';
	if (instance.startsWith(prefix)) {
		var netId = int.parse(instance.replaceFirst(prefix, ''));
		return _findSubscriptionWithNetId(subs, netId);
	} else {
		return _findSubscriptionWithTag(subs, instance);
	}
}

WebPushSubscriptionEntry? _findSubscriptionWithNetId(List<WebPushSubscriptionEntry> entries, int netId) {
	for (var entry in entries) {
		if (entry.network == netId) {
			return entry;
		}
	}
	return null;
}

WebPushSubscriptionEntry? _findSubscriptionWithTag(List<WebPushSubscriptionEntry> entries, String tag) {
	for (var entry in entries) {
		if (entry.tag == tag) {
			return entry;
		}
	}
	return null;
}

String _generateInstance() {
	var len = 16;
	var random = Random.secure();
	var values = List<int>.generate(len, (i) => random.nextInt(255));
	return base64UrlEncode(values).replaceAll('=', '');
}
