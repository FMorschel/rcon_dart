import 'package:mc_rcon_dart/mc_rcon_dart.dart';

Future<void> main() async {
  // Replace the host and password with your server's RCON settings.
  var rcon = await RconClient.connect('192.168.1.20', port: 25575);
  try {
    await rcon.login('123');
    print(await rcon.send('list'));
  } finally {
    await rcon.close();
  }
}
