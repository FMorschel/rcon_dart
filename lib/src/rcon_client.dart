import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Failure talking to an RCON server.
///
/// Messages never include the password.
final class RconException implements Exception {
  /// Creates the exception with a human-readable [message].
  const RconException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'RconException: $message';
}

/// One RCON connection to a Minecraft server.
///
/// Each command gets its own request ID, so replies are matched to the command
/// that asked for them and several commands can be in flight at once.
final class RconClient {
  RconClient._(this._socket) {
    _subscription = _socket.listen(
      _onBytes,
      onError: (Object _) => _failAll(const RconException('Connection lost')),
      onDone: () => _failAll(const RconException('Connection closed')),
      cancelOnError: true,
    );
    // Socket.done reports a reset as an error that nothing else listens to,
    // so it must be handled here or it surfaces as an uncaught async error.
    unawaited(
      _socket.done.then<void>(
        (_) => _failAll(const RconException('Connection closed')),
        onError: (Object _) => _failAll(const RconException('Connection lost')),
      ),
    );
  }

  static const int _typeCommand = 2;
  static const int _typeAuth = 3;

  /// Bytes after the length field that are not payload: request ID, type, and
  /// the two terminating NULs.
  static const int _packetOverhead = 10;

  /// Largest reply accepted, so a corrupt length cannot exhaust memory.
  static const int _maxPacketLength = 1 << 20;

  /// Request ID the server answers with when a login is rejected.
  static const int _authFailedId = -1;

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  final Map<int, ({int type, Completer<String> reply})> _pending = {};
  int _lastRequestId = 0;
  bool _closed = false;

  /// Opens a connection to [host] on [port], failing after [timeout].
  static Future<RconClient> connect(
    String host, {
    int port = 25575,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    var socket = await Socket.connect(host, port, timeout: timeout);
    return RconClient._(socket);
  }

  /// Authenticates with [password]; throws [RconException] when it is wrong.
  Future<void> login(
    String password, {
    Duration timeout = const Duration(seconds: 5),
  }) => _request(_typeAuth, password, timeout).then((_) {});

  /// Runs [command] and returns the server's reply.
  ///
  /// Throws [RconException] when the connection is closed or no reply arrives
  /// within [timeout].
  Future<String> send(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) => _request(_typeCommand, command, timeout);

  /// Closes the connection and fails any command still waiting for a reply.
  Future<void> close() async {
    _failAll(const RconException('Connection closed'));
    await _subscription.cancel();
    _socket.destroy();
  }

  Future<String> _request(int type, String payload, Duration timeout) {
    if (_closed) {
      return Future.error(const RconException('Connection is closed'));
    }
    var id = _nextRequestId();
    var reply = Completer<String>();
    _pending[id] = (type: type, reply: reply);
    _socket.add(_encode(id, type, payload));
    return reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw const RconException('The server did not reply in time');
      },
    );
  }

  int _nextRequestId() {
    _lastRequestId = _lastRequestId == 0x7fffffff ? 1 : _lastRequestId + 1;
    return _lastRequestId;
  }

  void _onBytes(Uint8List chunk) {
    _incoming.add(chunk);
    var bytes = _incoming.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      var length = ByteData.sublistView(bytes, offset, offset + 4)
          .getInt32(0, Endian.little);
      if (length < _packetOverhead || length > _maxPacketLength) {
        _failAll(const RconException('Malformed packet from the server'));
        return;
      }
      var end = offset + 4 + length;
      if (end > bytes.length) break;
      var body = ByteData.sublistView(bytes, offset + 4, end);
      var id = body.getInt32(0, Endian.little);
      var payload = utf8.decode(
        bytes.sublist(offset + 12, end - 2),
        allowMalformed: true,
      );
      offset = end;
      _onPacket(id, payload);
    }
    if (offset < bytes.length) _incoming.add(bytes.sublist(offset));
  }

  void _onPacket(int id, String payload) {
    if (id == _authFailedId) {
      _rejectLogin();
      return;
    }
    var request = _pending.remove(id);
    request?.reply.complete(payload);
  }

  void _rejectLogin() {
    for (var entry in _pending.entries) {
      if (entry.value.type != _typeAuth) continue;
      _pending.remove(entry.key)?.reply.completeError(
        const RconException('The RCON password was rejected'),
      );
      return;
    }
  }

  void _failAll(RconException error) {
    _closed = true;
    for (var request in _pending.values) {
      request.reply.completeError(error);
    }
    _pending.clear();
  }

  static Uint8List _encode(int id, int type, String payload) {
    var body = utf8.encode(payload);
    var length = body.length + _packetOverhead;
    var packet = Uint8List(4 + length);
    ByteData.sublistView(packet)
      ..setInt32(0, length, Endian.little)
      ..setInt32(4, id, Endian.little)
      ..setInt32(8, type, Endian.little);
    packet.setRange(12, 12 + body.length, body);
    return packet;
  }
}
