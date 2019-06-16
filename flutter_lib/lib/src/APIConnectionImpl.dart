import 'dart:async';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../JSONObject.dart';
import '../JSONArray.dart';
import '../APIConnection.dart';
import 'JSONObjectImpl.dart';

class APIConnectionImpl implements APIConnection {

  bool DEBUG = true;
  bool ADVANCED_DEBUG = true;

  // these expected to be assgined by the user of this module
  String wsUri = "";

  // to store extended credential information, login_name/passwd or credential_data
  // only one of those is valid, not both. The same is true with registration
  // registration.login_name/login_passwd or registration.credential_data shall be true
  String login_name = "";
  String login_passwd = "";
  var credential_data = null;
  var registration = null;

  // last response, not useful anyway, could be overwritten anytime
  JSONObject response = null;
  int last_resp = 0;

  List<JSONObject> req_queue_after_connect = List<JSONObject>();
  List<JSONObject> req_queue_after_login = List<JSONObject>();

  // does not response within this time frame, consider connection lost
  // this time limit is for both ping and normal request
  int MAX_RESPONSE_TIME = 15;

  // check the connection and response regularly
  int MINDER_TIME = 30;

  // connecting state shall not exceed this limit, or will be reset
  int MAX_CONNECTING_TIME = 5;
  int last_connecting = 0; // timestamp

  // last_resp is keepalive time ago, we will reuse the connection for GUEST_SEND
  int GUEST_SEND_KEEPALIVE_TIME = 30;

  ////////////////////////////////////////////////////////////////////////
  // utilities
  String version() { return "120"; } //126
  bool is_logged_in() { return conn_state == "IN_SESSION"; }

  void clog(String s) {
    if (!DEBUG) return;

    // comment this out in production
    print("[CAFL "+(new DateTime.now().toLocal().toString().substring(11, 11+12))+"]: "+s);
  }

  int getUnixTime() { return (DateTime.now().millisecondsSinceEpoch/1000).round(); }
  String pretty(String s) { return s; }

  ////////////////////////////////////////////////////////////////////////
  // websocket layer, handle the websocket re connection etc.
  // global sess var to be injected into each request
  String sess = "";

  JSONObject user_info = null;
  JSONObject server_info = null;

  // convenient place to hold app data, globally accessible
  JSONObject user_data = new JSONObjectImpl();

  SharedPreferences prefs = null;

  // persistent data
  Future<JSONObject> user_joread() async {
    if (prefs == null) prefs = await SharedPreferences.getInstance();
    String js = prefs.getString("sdk_user_jowrite_json_string");
    JSONObject jo = new JSONObjectImpl();
    if (js == null || js == "") return jo;
    jo = JSONObject.parse(js);
    return new Future<JSONObject>.value(jo);
  }

  void user_jowrite(JSONObject data) async {
    if (prefs == null) prefs = await SharedPreferences.getInstance();
    prefs.setString("sdk_user_jowrite_json_string", data.toString());
  }

  // client info set by client app
  JSONObject client_info = new JSONObjectImpl();

  // string key/value settings, "true" and "false" and number is rpresented as string as well
  JSONObject user_pref = new JSONObjectImpl(); //{"perf_enabled":"true"};

  ////////////////////////////////////////////////////////////////////////
  // connection and state maintenance
  int last_ping = 0;
  WebSocketChannel websocket = null;

  // state tracking,
  // all the CONNECTING states are to track why we initiate the websocket connection
  // once the connection is open, what action shall follow

  // keep tracking of the state and transition, states can be
  //
  // LOGIN_SCREEN_SHOWN
  // SERVERINFO_REQ
  // LOGIN_SCREEN_ENABLED
  // GUEST_SEND
  // INITIAL_LOGIN
  // IN_SESSION
  // SESSION_LOGIN
  // REGISTRATION
  // CONNECTING

  String conn_state = "LOGIN_SCREEN_SHOWN";

  // from_state is the last state before transition
  String from_state = "LOGIN_SCREEN_SHOWN";

  // target_state is the immediate state after websocket connection is re-established
  String target_state = "SERVERINFO_REQ";

  // get minder to work, maintaining connection
  //minder = function() {

  ////////////////////////////////////////////////////////////////////////
  // Routines  
  Set<APIConnectionListener> response_received_handlers = new Set<APIConnectionListener>();
  Set<APIConnectionListener> state_changed_handlers = new Set<APIConnectionListener>();
  
  void response_received_handlers_subscribe(APIConnectionListener listener) {
	  response_received_handlers.add(listener);
  }
  void response_received_handlers_unsubscribe(APIConnectionListener listener) {
	  response_received_handlers.remove(listener);
  }
  void response_received_handlers_post(JSONObject jo) {
    response_received_handlers.forEach((APIConnectionListener s){
      s.response_received(jo);
    });
  }
  void state_changed_handlers_subscribe(APIConnectionListener listener) {
	  state_changed_handlers.add(listener);
  }
  void state_changed_handlers_unsubscribe(APIConnectionListener listener) {
	  state_changed_handlers.remove(listener);
  }
  void state_changed_handlers_post() {
    response_received_handlers.forEach((APIConnectionListener s){
      s.state_changed();
    });
  }
  
  void credential(String name, String passwd) {
    // set credential, reset state back to start, expecting connect() call right way
    login_name = name;
    login_passwd = passwd;
    credential_data = null;

    user_info = null;
    registration = null;

    // set the target for state transition, if credential/login_name empty,
    // this is actually an logout request, with the same target_state here
    target_state = "INITIAL_LOGIN";
  }

  void credentialx(JSONObject cred) {
    // set credential, extended version, arbitury format
    login_name = "";
    login_passwd = "";
    credential_data = cred;

    user_info = null;
    registration = null;

    // set the target for state transition, if credential/login_name empty,
    // this is actually an logout request, with the same target_state here
    target_state = "INITIAL_LOGIN";
  }

  Timer minder_timer;

  void connect() {

    // kick of the periodic timer, only once
    if (minder_timer == null) minder_timer = Timer.periodic(Duration(seconds: MINDER_TIME), (Timer timer) {
      minder();
    });

    // for non-interference, if it is in -ing state, ignore this request
    if (conn_state == "CONNECTING") {

      // since failure to open new connection will revert back to previous state,
      // this filter will not stop it from attemping new connection
      // every connecting attemp will have a resolution in the end, no need to retry while it is in progress

      clog("connect: already connecting, connect request is ignored");
      return;
    }

    // target_state is set outside this routine, with this one exception
    if (conn_state == "LOGIN_SCREEN_ENABLED" && registration != null) {
      // registration is accepted only at this state
      target_state = "REGISTRATION";
      reset_websocket_conn();
    }

    if (target_state == "INITIAL_LOGIN") {
      // this actually is an logout request, simply logout and done!
      if ((login_name == null || login_name == "") && credential_data == null) {
        logout_();
        return;
      }
    }

    // reset the connection timer here
    last_connecting = getUnixTime();

    set_state("CONNECTING", false);

    clog("websocket create: wsUri:"+wsUri+" from_state:"+from_state+" state:"+conn_state);

    // do not add "protocl", chromium browser will complain no response back
    //this.websocket = new WebSocket(this.wsUri, "myprotocol");
    websocket = IOWebSocketChannel.connect(wsUri);
	
    websocket.stream.listen((data) {
        handle_message(data);
      },	  
	  onDone: () {
	    clog("websocket onDone");
	  },	  
	  onError: (error) {
	    clog("websocket onError: $error");
	  },
	);
  }

  void login(String username, String passwd) {
    credential(username, passwd);
    login_(true);
  }

  void loginx(JSONObject cred) {
    credentialx(cred);
    login_(true);
  }

  void logout() {
    credential("","");
    logout_();
  }

  void register(JSONObject reg) {
    registration = reg;
    send_registration();
  }

  void login_(verbose) {

    if (credential_data == null && login_name == "") return;
    if (credential_data == null && login_passwd == "") return;

    JSONObject cmd_obj = new JSONObjectImpl();

    cmd_obj["obj"] = "person";
    cmd_obj["act"] = "login";

    // server may reject login if sdk version is too low
    if (verbose) cmd_obj["sdk_version_webapp"] = version();

    if (credential_data == null) {
      cmd_obj["login_name"] = login_name;
      cmd_obj["login_passwd"] = login_passwd;
    } else {
      cmd_obj["credential_data"] = credential_data;
    }

    if (verbose) cmd_obj["verbose"] = 1;

    // during the connection maintenance stage, if user_info is missing, turn this option on as well
    if (user_info == null || user_info.data.length == 0) {
      cmd_obj["verbose"] = 1;
    }

    if (verbose) set_state("INITIAL_LOGIN", true);
    // reconnection, do not notify clients
    else set_state("SESSION_LOGIN", false);

    send_obj_now(cmd_obj);
  }

  void logout_() {

    if (sess == "") return;

    JSONObject cmd_obj = new JSONObjectImpl();

    cmd_obj["obj"] = "person";
    cmd_obj["act"] = "logout";

    set_state("LOGIN_SCREEN_ENABLED", true);

    send_obj_now(cmd_obj);
  }

  void send_registration() {

    if (registration == null) return;

    // the moment of registration is attempted, old credentials will be gone
    // meaning if registration fails, session will no longer be valid
    sess = "";
    login_name = "";
    login_passwd = "";
    credential_data = null;

    registration.obj = "person";
    registration.act = "register";

    set_state("REGISTRATION", true);

    send_obj_now(registration);
  }

  void ping() {
    JSONObject jo = new JSONObjectImpl();
    jo << {"obj":"server","act":"pinw"};
    send_obj_now(jo);
  }

  void req_server_info() {
    set_state("SERVERINFO_REQ", true);
    JSONObject jo = new JSONObjectImpl();
    jo << {"obj":"server","act":"info","sdk":version()};
    send_obj_now(jo);
  }

  // keep a log collection which can be retrieved on request
  // in-memory, small, continuouse, error/critical log only
  // no plan saving to disk to survive crash
  // to be space efficient, do not add timestamp, log it as is
  List<String> log_strings = new List<String>();

  int log_total_len = 0;

  void log_add(String logstr) {

    log_strings.add(logstr);
    log_total_len += logstr.length;

    // will keep the total length within max
    while(log_total_len > 10240) {
      var ls = log_strings.removeAt(0);
      log_total_len -= ls.length;
    }
  }

  String log_extra() {
    // called when sdk does a logsend, send extra info here
    // may be overriden by app of sdk
    return "";
  }

  void sdk_logsend(String to_pid) {
    // as requested send the log collection and app can collect
    // extra information, and send it along the result of logreq call
    JSONObject jo = new JSONObjectImpl();
    jo << {
      "obj":"sdk",
      "act":"logsend",
      "to_pid":to_pid,
      "version":version(),
      "data":log_strings.join("\n"),
      "extra":log_extra()
    };
    send_obj_now(jo);
  }

  void sdk_userdatasend(String to_pid) {
    // as requested send the user_data
    JSONObject jo = new JSONObjectImpl();
    jo << {
      "obj":"sdk",
      "act":"logsend",
      "to_pid":to_pid,
      "data":user_data
    };
    send_obj_now(jo);
  }

  void sdk_joreadsend(String to_pid, JSONObject data) {
    // as requested send the persistent data
    JSONObject jo = new JSONObjectImpl();
    jo << {
      "obj":"sdk",
      "act":"logsend",
      "to_pid":to_pid,
      "data":data
    };
    send_obj_now(jo);
  }

  void reset_websocket_conn() {
    clog("reset_websocket_conn: websocket:"+((websocket==null)?"null":websocket));
    websocket = null;
  }

  void revert_and_reset_state() {
    clog("revert_and_reset_state: from_state:"+from_state+" state:"+conn_state);
    // resert and reset back to base state: LOGIN_SCREEN_SHOWN LOGIN_SCREEN_ENABLED IN_SESSION

    if (conn_state == "CONNECTING") {
      conn_state = from_state;
      // target state remain the same
    }

    if (conn_state == "SESSION_LOGIN") {
      conn_state = "IN_SESSION";
      target_state = "SESSION_LOGIN";
    }

    if (conn_state == "REGISTRATION") {
      conn_state = "LOGIN_SCREEN_ENABLED";
      target_state = "REGISTRATION";
    }

    if (conn_state == "INITIAL_LOGIN") {
      conn_state = "LOGIN_SCREEN_ENABLED";
      target_state = "INITIAL_LOGIN";
    }

    if (conn_state == "SERVERINFO_REQ") {
      conn_state = "LOGIN_SCREEN_SHOWN";
      target_state = "SERVERINFO_REQ";
    }

    // GUEST_SEND state is imaginary and transient
  }

  void wsconn_and_state_sanity_check() {
    // this routine only put the state back to sanity, it does not initiate connect

    // this is insane !!
    if (conn_state == "LOGIN_SCREEN_SHOWN") {
      clog("wsconn_and_state_sanity_check: LOGIN_SCREEN_SHOWN, it appears it is restarted");
      target_state = "SERVERINFO_REQ";
      reset_websocket_conn();
      connect();
      return;
    }

    var time_now = getUnixTime();

    // check to see if it connecting takes too long, revert back to old state
    // do not get stuck in connecting state
    if (conn_state == "CONNECTING" && (time_now - last_connecting > MAX_CONNECTING_TIME)) {
      // target_state will remain the same
      revert_and_reset_state();
      reset_websocket_conn();
    }

    if (conn_state == "IN_SESSION") {

      var ping_interval = 180;

      // this interval is configurable on the server side but can not be disabled
      if (server_info != null && server_info.i("web_app_ping") > 0)
        ping_interval = server_info.i("web_app_ping");

      // it takes too long to serve an request, something is wrong
      if ((last_resp < last_ping) && (time_now - last_ping > MAX_RESPONSE_TIME)) {
        revert_and_reset_state();
        reset_websocket_conn();
      }

      // reset websocket connection if stale, minder is failing, here is safeguard
      if ((time_now - last_resp) > 2*ping_interval) {
        revert_and_reset_state();
        reset_websocket_conn();
      }
    }
  }

  bool send_str(String msg) {
    var cmd = JSONObject.parse(msg);
    return send_obj(cmd);
  }

  // return false if request is not accepted. our job queue max length is 1
  // send - used by sdk client, limited to LOGIN_SCREEN_ENABLED and IN_SESSION state
  // system send shall use send_obj_now to bypass this restriction
  bool send_obj(JSONObject req) {

    // public routine, used by client, intercept certain API's
    if (req["obj"] == "person" && (

        req["act"] == "login" ||
        req["act"] == "logout" ||
        req["act"] == "register")) {

      clog("send_obj: not authorized to call login/logout/register direct, request ignored");
      return false;
    }

    // depends on what state we are now at, drop onto different FIFO request queue
    if (conn_state == "IN_SESSION" || conn_state == "SESSION_LOGIN" ||
        conn_state == "CONNECTING" && from_state == "IN_SESSION") {

      req_queue_after_login.add(req);

    } else {
      req_queue_after_connect.add(req);
    }

    if (conn_state == "LOGIN_SCREEN_ENABLED") {

      if (websocket != null) {
        // reuse the connection for performance
        var now = getUnixTime();
        if (now-last_resp < GUEST_SEND_KEEPALIVE_TIME) {
          return send_all_after_connect();
        }
      }
    }

    wsconn_and_state_sanity_check();

    if (conn_state == "LOGIN_SCREEN_ENABLED") {

      reset_websocket_conn();

      target_state = "GUEST_SEND";

      connect();

      return true;
    }

    if (conn_state == "IN_SESSION") {

      if (websocket == null) {

        // print state information for debugging
        clog("send: websocket is null, from_state: " + from_state + "  state: " + conn_state);

        target_state = "SESSION_LOGIN";

        connect();

        return true;
      }

      // now send over the wire to server
      return send_all_after_login();
    }

    return true;
  }

  bool send_all_after_login() {
    while (req_queue_after_login.length > 0) {

      // remove ping request
      if (req_queue_after_login[0]["obj"] == "server") {
        var act = req_queue_after_login[0]["act"];
        var time_now = getUnixTime();
        if ((act == "pinw" || act == "ping")
            && (time_now - last_resp) < 5) {
          req_queue_after_login.removeAt(0);
          continue;
        }
      }

      if (send_obj_now(req_queue_after_login[0])) {
        req_queue_after_login.removeAt(0);
      } else {
        return false;
      }
    }
    return true;
  }

  bool send_all_after_connect() {
    while (req_queue_after_connect.length > 0) {

      // remove ping request
      if (req_queue_after_connect[0]["obj"] == "server") {
        var act = req_queue_after_connect[0]["act"];
        var time_now = getUnixTime();
        if ((act == "pinw" || act == "ping")
            && (time_now - last_resp) < 5) {
          req_queue_after_connect.removeAt(0);
          continue;
        }
      }

      if (send_obj_now(req_queue_after_connect[0])) {
        req_queue_after_connect.removeAt(0);
      } else {
        return false;
      }
    }
    return true;
  }

  bool send_obj_now(JSONObject cmd) {

    if (cmd == null) return false;

    // inject the sess information if not present
    if (cmd.s("sess") == "") cmd["sess"] = sess;
    if (cmd.s("io") == "") cmd["io"] = "i";

    if (user_pref.s("perf_enabled") == "true") {
      cmd["perf"] = 1;
    }

    // inject client_info if there is data
    if (cmd.s("client_info") != "" && client_info != null
        && client_info.data.length > 0) {

      // for debugging of loss of sess, inject state if not session'ed state
      if (conn_state != "IN_SESSION") {
        client_info["state"] = conn_state;
      } else {
        client_info.data.remove("state");
      }

      cmd["client_info"] = client_info.data;
    }

    if (cmd["obj"] == "person" && (cmd["act"] == "login" || cmd["act"] == "logout" || cmd["act"] == "register")) {
      // this will not valid any longer
      sess = "";
    }

    var data = cmd.toString()+"\n";

    clog("send_obj_now "+data);

    last_ping = getUnixTime();

    // clear the response field
    response = null;
    websocket.sink.add(data);

    return true;
  }

  // handle message from the wire
  void handle_message(var data) {

    last_resp = getUnixTime();

    data = data.replaceAll(RegExp(r'[\s\r\n]+$'), "");
    var lines = data.split('\n');

    // first line is length
    lines.removeAt(0);

    clog(pretty('['+lines.join(',')+']'));

    // extract the sess and keep it in the global var
    var cmds = JSONArray.parse('['+lines.join(',')+']');

    for (var i=0, len=cmds.data.length; i<len; i++) {

        var jo = cmds.o(i);

        // this is the only flag deciding if login succeeded - a valid new session!
        // before login, sess is reset to ""
        if (jo.s("sess") != "") sess = jo.s("sess");

        if (jo.s("sessreset") == sess) {
            // if the sess needs to be renewed, kick off a login request
            // we only deal with it when it is in this state
            if (conn_state == "IN_SESSION") {
                // initiate a session login for new session
                login_(false);
            }
        }

        // filter these uninterested responses
        if (jo["obj"] == "server" && (jo["act"] == "ping" || jo["act"] == "pinw")) continue;

        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "server" && jo["act"] == "info") {

            server_info = jo.o("server_info");

            if (conn_state == "SERVERINFO_REQ" && jo["server_info"] != null) {
                set_state("LOGIN_SCREEN_ENABLED", true);
            }
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "person" && jo["act"] == "login"
            || jo["obj"] == "person" && jo["act"] == "register") {

            if (jo["user_info"] != null) user_info = jo.o("user_info");
            if (jo["server_info"] != null) server_info = jo.o("server_info");

            // successful
            if (sess != "") {
                if (conn_state == "REGISTRATION") {
                    // copy the credential from the registration form, for later use
                    // for compatibility, one of these two format is valid
                    login_name = registration.s("login_name");
                    login_passwd = registration.s("login_passwd");
                    if (registration["credential_data"] != null) credential_data = registration.o("credential_data");

                    // this has served its purpose
                    registration = null;
                }

                // SESSION_LOGIN: reconnection, do not notify clients
                if (conn_state == "INITIAL_LOGIN" || conn_state == "REGISTRATION") set_state("IN_SESSION", true);
                else set_state("IN_SESSION", false);

                // execute any pending request from the job queue
                send_all_after_login();

            // login not right, it could be the problem of passwd, it could be the problem of wire loss of connection
            } else {
                // user info may not be valid, just in case, nullify it
                user_info = null;

                // just to be safe, in case it is from registration, need to reset this field
                registration = null;

                    // only two places where these two fields are reset, log out or login failure
                login_name = "";
                login_passwd = "";
                credential_data = null;

                // login fails, return to screen for prompt,
                // either from SESSION_LOGIN or INITIAL_LOGIN or REGISTRATION
                // registeration normally on different screen, do not switch screen
                if (conn_state == "REGISTRATION") set_state("LOGIN_SCREEN_ENABLED", true);
                else set_state("LOGIN_SCREEN_ENABLED", false);
            }
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "person" && jo["act"] == "logout") {

            user_info = null;
            sess = "";

            // only two places where these two fields are reset, log out or login failure
            login_name = "";
            login_passwd = "";
            credential_data = null;

            reset_websocket_conn();

            set_state("LOGIN_SCREEN_ENABLED", true);
        }
        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "sdk" && jo["act"] == "logreq") {

            sdk_logsend(jo.s("from_pid"));
        }
        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "sdk" && jo["act"] == "user_data") {
            if (jo["data"] == null)
                sdk_userdatasend(jo.s("from_pid"));
            else
                user_data = jo.o("data");
        }
        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "sdk" && jo["act"] == "user_joread") {

            user_joread().then((JSONObject fjo){
                sdk_joreadsend(jo.s("from_pid"), fjo);
            });
        }
        //////////////////////////////////////////////////////////////////////////////////////////////////
        if (jo["obj"] == "sdk" && jo["act"] == "user_jowrite") {

            user_jowrite(jo.o("data"));
        }

        // process some of the response, and pass along the rest
        // to response handler provided by client
        response_received_handlers_post(jo);
    }
  }

  void set_state(String s, bool notify) {

    from_state = conn_state;
    conn_state = s;
	
    if (notify) state_changed_handlers_post();

    // turn this off when releasing this library
    if (ADVANCED_DEBUG) clog("set_state: "+from_state+" => "+conn_state);

    // certain state transition shall not bother our clients
    // CONNECTING state is of no interest to our clients
  }
  
  // maintaining connection
  void minder() {
    clog("minder is running, conn_state: "+conn_state);

    // in-memory credential is good and not in-session state, start working toward session'ed state
    if (conn_state == "LOGIN_SCREEN_SHOWN" ||
        conn_state == "LOGIN_SCREEN_ENABLED") {
      if (login_name != "" && login_passwd != "")
        login(login_name, login_passwd);
      else if (credential_data != null) loginx(credential_data);

      // it has been silent, check to see if OK
    } else if (conn_state == "IN_SESSION") {
      // inactivity check
      var time_now = getUnixTime();

      var ping_interval = 180;

      // this interval is configurable on the server side but can not be disabled
      if (server_info != null && server_info["web_app_ping"] != null &&
          server_info.i("web_app_ping") > 0)
        ping_interval = server_info["web_app_ping"];

      // a normal request is also considered a ping and a timely response is expected
      if ((last_resp < last_ping) &&
          (time_now - last_ping > MAX_RESPONSE_TIME)) {
        // no timely response since last ping, reconnect the websocket
        // it is possible: APIConnection.last_resp == APIConnection.last_ping
        reset_websocket_conn();
      } else if ((time_now - last_ping) >= ping_interval) {
        clog("connection_minder ping initiated");
        ping();
      }
    }
  }
}