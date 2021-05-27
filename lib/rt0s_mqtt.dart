library rt0s_mqtt;

import 'dart:async';
import 'dart:convert';
//import 'dart:html';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

class API {}

class MQTTapi {
  bool done = false;
  MqttBrowserClient client;
  var uuid = Uuid();
  JsonEncoder encoderi = new JsonEncoder.withIndent('  ');
  JsonEncoder encoder = new JsonEncoder();
  var reqs = {};
  Map<String, dynamic> apis = {};
  Function _onBroadcast = null;
  Function _onEvent = null;
  bool online = false;

  static int stampms() => DateTime.now().millisecondsSinceEpoch;

  static int stamp() =>
      ((DateTime.now().millisecondsSinceEpoch) / 1000).round();

  static String hash(String input) {
    return md5.convert(utf8.encode(input)).toString();
  }

  void subscribe(
      String topic, Function(void) f(String topic, Map<String, dynamic> msg)) {
    client.subscribe(topic, MqttQos.exactlyOnce);
    MqttClientTopicFilter clientTopicFilter =
        MqttClientTopicFilter(topic, client.updates);
    clientTopicFilter.updates
        .listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload;
      final String pt =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      Map<String, dynamic> obj = jsonDecode(pt);
      f(c[0].topic, obj);
    });
  }

  void broadcast(String path, Map<String, dynamic> obj, {bool retain = false}) {
    publish("/bc/$_id/$path", obj, retain: retain);
  }

  void onConnected() {
    //print('MQTTapi connected....');
    online = true;
    if (_onEvent != null) _onEvent(online, "online");
    broadcast("state", {"state": "online", "stamp": stamp()}, retain: true);
  }

  void onDisonnected() {
    online = false;
    print('MQTTapi disconnected');
    if (_onEvent != null) _onEvent(online, "offline");
  }

  var lastPing = stamp();
  void pongCallback() {
    var now = stamp();
    if (_onEvent != null) _onEvent(online, "ping");
    print('MQTTapi pongCallback ${now - lastPing}');
    lastPing = now;
  }

  void onAutoReconnect() {
    print('MQTTapi onAutoReconnect');
    if (_onEvent != null) _onEvent(online, "autoreconnect");
    // subscribe("/dn/$_id/#", (String topic, Map<String, dynamic> msg) {
    //   print(["API CHECK", msg['req']['args']]);
    // });
  }

  void publish(String topic, Map<String, dynamic> msg, {bool retain = false}) {
    String message;
    try {
      message = encoder.convert(msg);
    } catch (e) {
      print(["JSON ERR at MQTTapi: ", msg, e]);
      return;
    }
    try {
      final MqttClientPayloadBuilder builder = MqttClientPayloadBuilder();
      builder.addString(message);
      client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload,
          retain: retain);
    } catch (e) {
      print(["cannot pub -- err ", e]);
    }
  }

  Future req(String target, Map<String, dynamic> msg,
      {int timeut = 3000, int retries = 0}) async {
    Completer completer = new Completer();
    Map<String, dynamic> obj = {
      'mid': uuid.v4(),
      'src': _id,
      'target': target,
      'req': msg,
    };
    reqs[obj['mid']] = {
      'obj': obj,
      'completer': completer,
      'done': false,
      'created': stampms(),
      'sent': stampms(),
      'tries': 1,
      'retries': retries,
      'timeout': timeut
    };
    publish("/dn/$target/${obj['mid']}", obj);
    return completer.future;
  }

  String _host;
  int _port;
  String _user;
  String _pw;
  int _ping;
  String _id;
  String _type;
  String _descr;
  String _uuid;
  Timer _timeri;

  MQTTapi(
      {String id,
      String descr,
      String host = 'mqtt.rt0s.com',
      int port = 1884,
      int ping = 10,
      String user,
      String pw}) {
    _host = host;
    _port = port;
    _user = user;
    _pw = pw;
    _ping = ping;
    _id = id;
    _descr = descr;

    client = MqttBrowserClient(host, '', maxConnectionAttempts: 9999);
    client.logging(on: false);
    client.port = port;
    //client. secure = (port == 1884) || (port == 8889);
    client.pongCallback = pongCallback;
    client.onConnected = onConnected;
    client.onAutoReconnect = onAutoReconnect;
    client.onDisconnected = onDisonnected;

    client.keepAlivePeriod = _ping;
    _timeri = new Timer.periodic(Duration(milliseconds: 100), (Timer t) {
      var now = stampms();
      var dlist = [];
      reqs.keys.forEach((r) {
        var obj = reqs[r];
        if (obj['done']) {
          dlist.add(r);
        } else {
          if (now > obj['sent'] + obj['timeout']) {
            reqs[r]['tries'] += 1;
            if (reqs[r]['tries'] > reqs[r]['retries']) {
              reqs[r]['done'] = true;
              print(["failed $r", reqs[r]]);
              reqs[r]['completer'].complete({"error": "timeout"});
            } else {
              reqs[r]['sent'] = stampms();
              print(["resend $r", reqs[r]]);
              publish("/dn/${obj['obj']['target']}/$r", obj['obj']);
            }
          }
        }
      });
      dlist.forEach((r) {
        reqs.remove(r);
      });
    });
  }

  do_subs() {
    subscribe("/dn/$_id/#", (String topic, Map<String, dynamic> msg) {
      //print(["API CHECK", msg['req']['args']]);
      if (apis.containsKey(msg['req']['args'][0])) {
        var api = apis[msg['req']['args'][0]];
        var reply = api['f'](msg);
        if (reply == null) {
          //print("api will reply later");
          return;
        }
        msg['reply'] = reply;
        //print(["API HIT", api, msg['req']['args'], msg['reply']]);
      } else if (apis.containsKey("*")) {
        var api = apis["*"];
        var reply = api['f'](msg);
        if (reply == null) {
          return;
        }
        msg['reply'] = reply;
      } else
        msg['reply'] = {
          "error": "no api '${msg['req']['args'][0]}' at '${_id}'"
        };
      publish("/up/${msg['src']}/${msg['mid']}", msg);
      return;
    });

    subscribe("/up/$_id/#", (String topic, Map<String, dynamic> msg) {
      if (reqs.containsKey(msg['mid'])) {
        var r = reqs[msg['mid']];
        if (!r['done']) {
          msg['dur'] = stampms() - r['sent'];
          msg['tries'] = r['tries'];
          r['completer'].complete(msg);
          r['done'] = true;
        } else {
          print(["extra reply", msg]);
        }
      } else {
        print(["stray reply", msg]);
      }
      return;
    });

    subscribe("/bc/#", (String topic, Map<String, dynamic> msg) {
      RegExp regExp = new RegExp(r"^\/bc\/" + _id);
      if (!regExp.hasMatch(topic)) {
        if (_onBroadcast != null) _onBroadcast(topic, msg);
      }
      return;
    });
  }

  reconnect(String user, String pw, String id) async {
    _user = user;
    _pw = pw;
    _id = id;
    client.disconnect();
    await client.connect();
    print("reconn ok");
    do_subs();
  }

  connect(
      {bool wait = true,
      Function onBroadcast = null,
      Function onEvent = null}) async {
    _onBroadcast = onBroadcast;
    _onEvent = onEvent;
    if (done) {
      print('MQTTapi connected already :)');
    } else {
      registerAPI("ping", "Ping with a Pong", [], (Map<String, dynamic> args) {
        return {"pong": true};
      });
      final connMess = MqttConnectMessage()
          .authenticateAs(_user, _pw)
          .withClientIdentifier(_id)
          .keepAliveFor(_ping)
          .withWillRetain()
          .startClean() // Non persistent session for testing
          //.withWillMessage(encoder.convert({"state": "off"}))
          .withWillTopic("/bc/$_id/state")
          .withWillQos(MqttQos.exactlyOnce);
      done = true;
      print('MQTTapi connecting.... xx');
      client.autoReconnect = true;
      client.resubscribeOnAutoReconnect = true;
      client.connectionMessage = connMess;
      client.autoReconnect = true;
      try {
        await client.connect();
        print("conn ok");
        do_subs();

        new Timer.periodic(Duration(milliseconds: 1000), (Timer t) {
          var now = stamp();
          var delta = now - lastPing;
          if (delta > _ping * 2) print("MQTT lost?");
        });
      } on Exception catch (e) {
        print('MQTTapi exception - $e');
        client.disconnect();
      }
    }
  }

  registerAPI(String path, String descr, List args, Function f) {
    apis[path] = {"f": f, "descr": descr, "args": args};
    //print(["api reg ok", apis]);
  }
}
