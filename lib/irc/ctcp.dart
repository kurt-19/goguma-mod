import 'message.dart';

/// A CTCP message as defined in:
/// https://rawgit.com/DanielOaks/irc-rfcs/master/dist/draft-oakley-irc-ctcp-latest.html
class CtcpMessage {
	final String cmd;
	final String? param;

	CtcpMessage(String cmd, [ this.param ]) :
		cmd = cmd.toUpperCase();

	String format() {
		var s = '\x01$cmd';
		if (param != null) {
			s += ' $param';
		}
		s += '\x01';
		return s;
	}

	static CtcpMessage? parse(IrcMessage msg) {
		if (msg.cmd != 'PRIVMSG' && msg.cmd != 'NOTICE') {
			return null;
		}

		var s = msg.params[1];
		if (!s.startsWith('\x01')) {
			return null;
		}
		s = s.substring(1);
		if (s.endsWith('\x01')) {
			s = s.substring(0, s.length - 1);
		}

		var i = s.indexOf(' ');
		if (i >= 0) {
			return CtcpMessage(s.substring(0, i), s.substring(i + 1));
		} else {
			return CtcpMessage(s);
		}
	}
}
