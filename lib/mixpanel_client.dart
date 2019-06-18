import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:device_info/device_info.dart';
import 'package:package_info/package_info.dart';
import 'package:http/http.dart' as http;

/// Handler for any errors while reporting an event to mixpanel
typedef void MixpanelErrorTrackHandler(Object error, StackTrace strackTrace, {String endpoint, Map<String, dynamic> data});

/// Allows sending events and properties to Mixpanel. Has some convenience methods for common events.
class MixpanelAnalyticsClient {
  Map<String, DateTime> _timedEvents = <String, DateTime>{};
  String _distinctId;
  _MixPanelSession _session = _MixPanelSession();
  String _token;
  Map<String, dynamic> _superProperties = <String, dynamic>{};
  Map<String, dynamic> _deviceInfo = <String, dynamic>{};

  /// List of events that set to be sent to Mixpanel. Only populated if debugRecord is true
  List<Map<String, dynamic>> debugList;

  bool _debugRecord;
  bool get debugRecord => _debugRecord;
  set debugRecord(bool v) {
    _debugRecord = v;
    debugList = v ? <Map<String, dynamic>>[] : null;
  }

  /// Print all events that are set to be sent to the console
  bool debugPrint;

  /// Return verbose errors from Mixpanel API
  bool debugErrors;

  /// Whether or not to sent events that are reported to Mixpanel
  bool get enabled => _enabled && _token != null;
  set enabled(bool value) => _enabled = value;
  bool _enabled;
  
  final MixpanelErrorTrackHandler errorTrackHandler;

  MixpanelAnalyticsClient({
    @required String token,
    bool debugRecord = false,
    this.debugPrint = false,
    this.debugErrors = false,
    bool enabled = true,
    this.errorTrackHandler,
  }) {
    _token = token;
    _enabled = enabled;
    _debugRecord = debugRecord;
    onForeground();
  }

  Future<void> prepareDeviceInfo(PackageInfo packageInfo, String environment) async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      _deviceInfo = {
        'environment': environment,
        '\$android_os': 'Android',
        '\$android_os_version': info.version.release ?? 'UNKNOWN',
        '\$android_manufacturer': info.manufacturer ?? 'UNKNOWN',
        '\$android_brand': info.brand ?? 'UNKNOWN',
        '\$android_model': info.model ?? 'UNKNOWN',
        '\$android_app_version': packageInfo.version,
        '\$android_app_version_code': packageInfo.buildNumber,
        // '\$android_lib_version': '0.0',
      };
    } else if (Platform.isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      _deviceInfo = {
        'environment': environment,
        '\$ios_app_version': packageInfo.version,
        '\$ios_app_release': packageInfo.buildNumber,
        '\$ios_device_model': info.model,
        '\$ios_version': info.systemVersion,
        // '\$ios_lib_version': AutomaticProperties.libVersion()
        // '\$swift_lib_version': AutomaticProperties.libVersion()
      };
    }
  }

  Future<void> alias(String newId) {
    assert(_distinctId != null);

    final p = track('\$create_alias', properties: {
      'alias': newId,
      'original': _distinctId,
    });
    _distinctId = newId;
    return p;
  }

  Future<void> identify(String distinctId, {bool autoAlias = false}) async {
    if (autoAlias && _distinctId != null && _distinctId != distinctId)  {
      if (debugPrint)
        print('[ANALYTICS]: alias from $_distinctId to $distinctId');
      await alias(distinctId);
    } else {
      if (debugPrint)
        print('[ANALYTICS]: identify as $distinctId');
      _distinctId = distinctId;
    }
  }

  void timeEvent(String eventName) {
    assert(!_timedEvents.containsKey(eventName));
    _timedEvents[eventName] = DateTime.now();
  }

  /// Track the given event.
  Future<void> track(String eventName, {Map<String, dynamic> properties = const {}}) {
    final data = <String, dynamic>{};
    data.addAll(_superProperties);
    data['distinct_id'] = _distinctId;
    data['\$user_id'] = _distinctId;
    if (_timedEvents[eventName] != null) {
      data['\$duration'] = DateTime.now().difference(_timedEvents[eventName]).inSeconds;
      _timedEvents.remove(eventName);
    }
    data.addAll(properties);
    data['token'] = _token;
    // FIXME Not sure if we need this event, android mixpanel appears to be sending it, but mixpanel appears not to make use of it
    // data['\$device_id'] = anonymousId;

    return send('/track', {'event': eventName, 'properties': data, '\$mp_metadata': _session.prepareEvent()});
  }

  /// Change a people property
  Future<void> people(String operation, Map<String, dynamic> properties) {
    return send('/engage', {
      '\$token': _token,
      '\$distinct_id': _distinctId,
      '\$user_id': _distinctId,
      // '\$device_id': anonymousId,
      '\$mp_metadata': _session.prepareEvent(true),
      operation: properties..addAll(_deviceInfo),
    });
  }

  /// Directly send something to a mixpanel endpoint. Should generally not be used, but rather [people] and [track].
  Future<void> send(String endpoint, Map<String, dynamic> data) async {
    debugList?.add(data);
    if (debugPrint)
      print('[ANALYTICS]: $endpoint --> $data');

    if (!enabled)
      return;

    try {
      final response = await http.get(Uri(
        scheme: 'https',
        host: 'api.mixpanel.com',
        path: endpoint,
        queryParameters: {
          'data': base64Url.encode(utf8.encode(json.encode(data))),
          'verbose': debugErrors ? '1' : '0',
        }
      ));

      if (debugErrors) {
        final res = json.decode(response.body);
        if (res['status'] != 1)
          throw Exception('Failed to send mixpanel analytics to $endpoint (${res['error']})');
      } else {
        if (response.body != '1')
          throw Exception('Failed to send mixpanel analytics to $endpoint');
      }
    } catch (error, stackTrace) {
      if (errorTrackHandler != null)
        errorTrackHandler(error, stackTrace, endpoint: endpoint, data: data);
      else
        throw error;
    }
  }

  /// Report that the app opened for the very first time
  Future<void> trackFirstOpen() => track('\$ae_first_open');

  /// Report that the app was updated
  Future<void> trackAppUpdated(String version) =>
    track('\$ae_updated', properties: {'\$ae_updated_version': version});

  /// Report a crash to mixpanel
  Future<void> trackCrashed(String reason) =>
    track('\$ae_crashed', properties: {'\$ae_crashed_reason': reason});

  /// Report a screen view
  Future<void> trackScreenView(String name) =>
    track('screen_view', properties: {'name': name});

  /// Report that the app was just put to the foreground, we begin tracking an app session
  void onForeground() => _session.begin();

  /// Report that the app was just put to the background, we end tracking an app session and
  /// report the session's duration
  void onBackground() => _session.end(this);
}

/// Helper class wrapping the duration tracking of an app session
class _MixPanelSession {
  static const minimumSessionDuration = Duration(seconds: 10);
  static const maximumSessionDuration = Duration(hours: 4);

  String _sessionId;
  DateTime _sessionStart;
  int _eventCounter;
  int _peopleCounter;

  void begin() {
    _sessionId = _randomId();
    _sessionStart = DateTime.now();
    _eventCounter = 0;
    _peopleCounter = 0;
  }

  void end(MixpanelAnalyticsClient analytics) {
    final sessionLength = DateTime.now().difference(_sessionStart);
    if (sessionLength >= minimumSessionDuration && sessionLength <= maximumSessionDuration) {
      analytics.track("\$ae_session", properties: {"\$ae_session_length": sessionLength.inSeconds});
    }
  }

  String _randomId() => Random().nextInt(1<<32).toRadixString(16);

  Map<String, dynamic> prepareEvent([bool isPeopleEvent = false]) => {
    '\$mp_event_id': _randomId(),
    '\$mp_session_id': _sessionId,
    '\$mp_session_seq_id': isPeopleEvent ? _peopleCounter++ : _eventCounter++,
    '\$mp_session_start_sec': (_sessionStart.millisecondsSinceEpoch / 1000).floor()
  };
}
