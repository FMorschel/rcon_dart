# mc_rcon_dart

A Dart client for the Minecraft RCON protocol.

## Getting started

Add it from Git until it is published:

```yaml
dependencies:
  mc_rcon_dart:
    git:
      url: https://github.com/FMorschel/rcon_dart.git
```

## Usage

```dart
import 'package:mc_rcon_dart/mc_rcon_dart.dart';

Future<void> main() async {
  var rcon = await RconClient.connect('192.168.1.20', port: 25575);
  try {
    await rcon.login('password');
    print(await rcon.send('list'));
  } finally {
    await rcon.close();
  }
}
```

* `RconClient.connect` opens the socket, with a `timeout` for the connection.
* `login` throws `RconException` when the password is rejected.
* `send` returns the server's reply, matched to its own request, and throws
  `RconException` if the connection is lost or the reply takes longer than its
  `timeout` (5 seconds by default).
* Several `send` calls may be in flight at once.
* `close` ends the connection and fails any command still waiting.

Errors never include the password.

## Additional information

* The RCON protocol is described at [wiki.vg/RCON](https://wiki.vg/RCON).
* Minecraft console commands are described at
  [the Minecraft wiki](https://minecraft.fandom.com/wiki/Commands).
