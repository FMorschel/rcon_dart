import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mc_rcon_dart/mc_rcon_dart.dart';
import 'package:test/test.dart';

const int _typeResponse = 0;
const int _typeAuth = 3;
const int _authFailedId = -1;

/// Answers RCON packets on loopback so the client runs over a real socket.
final class FakeRconServer {
  FakeRconServer._(this._server, this._password);

  /// Starts a server on an ephemeral port that accepts [password].
  static Future<FakeRconServer> start({String password = 'secret'}) async {
    var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var fake = FakeRconServer._(server, password);
    server.listen(fake._accept);
    return fake;
  }

  final ServerSocket _server;
  final String _password;
  final List<Socket> _clients = [];

  /// Produces the reply for each command; tests override it to delay, reorder
  /// or fail replies.
  Future<String> Function(String command) onCommand = (command) async =>
      'ran $command';

  /// Port the client must connect to.
  int get port => _server.port;

  /// Closes every client connection, as a crashed server would.
  void dropClients() {
    for (var client in _clients) {
      client.destroy();
    }
  }

  /// Stops accepting connections and drops the open ones.
  Future<void> close() async {
    dropClients();
    await _server.close();
  }

  void _accept(Socket client) {
    _clients.add(client);
    var incoming = BytesBuilder(copy: false);
    client.listen((chunk) {
      incoming.add(chunk);
      var bytes = incoming.takeBytes();
      var offset = 0;
      while (bytes.length - offset >= 4) {
        var length = ByteData.sublistView(bytes, offset, offset + 4)
            .getInt32(0, Endian.little);
        var end = offset + 4 + length;
        if (end > bytes.length) break;
        var body = ByteData.sublistView(bytes, offset + 4, end);
        var id = body.getInt32(0, Endian.little);
        var type = body.getInt32(4, Endian.little);
        var payload = utf8.decode(bytes.sublist(offset + 12, end - 2));
        offset = end;
        unawaited(_answer(client, id, type, payload));
      }
      if (offset < bytes.length) incoming.add(bytes.sublist(offset));
    }, onError: (Object _) {});
  }

  Future<void> _answer(Socket client, int id, int type, String payload) async {
    if (type == _typeAuth) {
      client.add(
        _encode(payload == _password ? id : _authFailedId, 2, ''),
      );
      return;
    }
    var reply = await onCommand(payload);
    client.add(_encode(id, _typeResponse, reply));
  }

  static Uint8List _encode(int id, int type, String payload) {
    var body = utf8.encode(payload);
    var length = body.length + 10;
    var packet = Uint8List(4 + length);
    ByteData.sublistView(packet)
      ..setInt32(0, length, Endian.little)
      ..setInt32(4, id, Endian.little)
      ..setInt32(8, type, Endian.little);
    packet.setRange(12, 12 + body.length, body);
    return packet;
  }
}

void main() {
  late FakeRconServer server;

  setUp(() async {
    server = await FakeRconServer.start();
  });

  tearDown(() => server.close());

  Future<RconClient> connectAndLogin({String password = 'secret'}) async {
    var client = await RconClient.connect(
      InternetAddress.loopbackIPv4.address,
      port: server.port,
    );
    await client.login(password);
    return client;
  }

  group('login', () {
    test('succeeds with the right password', () async {
      var client = await connectAndLogin();
      addTearDown(client.close);

      expect(await client.send('list'), 'ran list');
    });

    test('throws RconException without echoing the password', () async {
      var client = await RconClient.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(client.close);

      var failure = await client.login('wrong-password').then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );

      expect(failure, isA<RconException>());
      expect(failure.toString(), isNot(contains('wrong-password')));
    });
  });

  group('send', () {
    test('matches each reply to its own command when replies arrive out of '
        'order', () async {
      server.onCommand = (command) async {
        if (command == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return 'reply to $command';
      };
      var client = await connectAndLogin();
      addTearDown(client.close);

      var slow = client.send('slow');
      var fast = client.send('fast');

      expect(await fast, 'reply to fast');
      expect(await slow, 'reply to slow');
    });

    test('times out when the server stays silent', () async {
      server.onCommand = (_) => Completer<String>().future;
      var client = await connectAndLogin();
      addTearDown(client.close);

      await expectLater(
        client.send('list', timeout: const Duration(milliseconds: 100)),
        throwsA(isA<RconException>()),
      );
    });

    test('fails the commands in flight when the server drops the connection',
        () async {
      server.onCommand = (_) => Completer<String>().future;
      var client = await connectAndLogin();
      addTearDown(client.close);

      var pending = client.send('list');
      server.dropClients();

      await expectLater(pending, throwsA(isA<RconException>()));
    });

    test('fails once the connection is closed', () async {
      var client = await connectAndLogin();
      await client.close();

      await expectLater(client.send('list'), throwsA(isA<RconException>()));
    });
  });

  test('returns a reply too large for one TCP read', () async {
    server.onCommand = (_) async => 'x' * 3000;
    var client = await connectAndLogin();
    addTearDown(client.close);

    expect(await client.send('list'), 'x' * 3000);
  });
}
