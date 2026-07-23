import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DateIndicator extends StatefulWidget {
	final ValueListenable<DateTime?> date;

	const DateIndicator({ super.key, required this.date });

	@override
	DateIndicatorState createState() => DateIndicatorState();
}

class DateIndicatorState extends State<DateIndicator> with SingleTickerProviderStateMixin<DateIndicator> {
	late final AnimationController _controller;
	late final Animation<Offset> _animation;

	RestartableTimer? _timer;

	@override
	void initState() {
		super.initState();

		_controller = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 200),
		);
		_animation = _controller.drive(Tween<Offset>(
			begin: const Offset(0, -5),
			end: Offset.zero,
		));
	}

	@override
	void dispose() {
		_controller.dispose();
		_timer?.cancel();
		super.dispose();
	}

	void show() {
		if (_controller.value == 0) {
			_controller.animateTo(1.0);
		}

		if (_timer == null) {
			_timer = RestartableTimer(Duration(milliseconds: 500), () {
				_timer = null;
				_controller.animateTo(0.0);
			});
		} else {
			_timer?.reset();
		}
	}

	@override
	Widget build(BuildContext context) {
		return SlideTransition(
			position: _animation,
			child: Container(
				padding: const EdgeInsets.all(7.0),
				decoration: BoxDecoration(
					color: Theme.of(context).colorScheme.secondaryContainer,
					borderRadius: BorderRadius.circular(5),
				),
				child: ValueListenableBuilder(valueListenable: widget.date, builder: (context, date, _) {
					return Text(
						date != null ? _formatDate(date.toLocal()) : '',
						style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer),
					);
				}),
			),
		);
	}
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}
