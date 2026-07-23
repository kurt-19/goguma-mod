import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sentry/sentry.dart';

const _sentryDsn = String.fromEnvironment('SENTRY_DSN');
var _sentryInitialized = false;

final log = Logger._();

class Logger {
	Logger._();

	bool Function() isSentryEnabled = () => true;

	Future<void> init() async {
		if (Platform.isLinux) {
			// Use sync logging on Linux.
			debugPrint = debugPrintSynchronously;
		}

		if (_sentryDsn == '') {
			return;
		}

		try {
			await Sentry.init((options) {
				options.enablePrintBreadcrumbs = false;
			});
			_sentryInitialized = true;
			log.print('Sentry error reporting enabled');
		} on Exception catch (err) {
			log.print('Failed to initialize Sentry', error: err);
		}
	}

	void print(String msg, { Object? error }) {
		if (error != null) {
			msg += ': $error';
		}
		debugPrint('[${DateTime.now().toString()}] $msg');
	}

	void reportFlutterError(FlutterErrorDetails details) async {
		FlutterError.dumpErrorToConsole(details, forceReport: true);

		if (details.silent) {
			return;
		}

		if (_sentryInitialized && _isSentryException(details.exception) && isSentryEnabled()) {
			await Sentry.captureException(details.exception, stackTrace: details.stack);
		}

		if (kReleaseMode && details.exception is Error) {
			exit(1);
		}
	}

	String? get sentryHost {
		if (!_sentryInitialized) {
			return null;
		}
		var uri = Uri.parse(_sentryDsn);
		return uri.host;
	}
}

bool _isSentryException(Object exception) {
	return !(exception is TimeoutException) && !(exception is IOException);
}
