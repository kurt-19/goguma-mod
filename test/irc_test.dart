import 'package:flutter_test/flutter_test.dart';
import 'package:ircmobileapp/irc/irc.dart';

void main() {
  test('empty NAMES reply keeps the channel and has no members', () {
    var reply = NamesReply.empty('#empty');

    expect(reply.channel, '#empty');
    expect(reply.status, ChannelStatus.public);
    expect(reply.members, isEmpty);
  });
}
