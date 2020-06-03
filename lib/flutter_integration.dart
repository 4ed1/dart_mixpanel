import 'dart:async';

import 'package:flutter/material.dart';

import 'package:dart_mixpanel/mixpanel_client.dart';
import 'package:package_info/package_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// This class does some of the deeper integration with flutter apps and the MixpanelAnalyticsClient.
///
/// It will listen on app foreground/background changes and report these and set up device information,
/// as well as report app updates and first open.
///
/// For advanced usage, don't be afraid to access the [client] object directly.
class MixpanelAnalytics with WidgetsBindingObserver {
  /// If you're using a [MixpanelAnalyticsProvider], this allows you to call MixpanelAnalytics.of(context).track(...).
  static MixpanelAnalytics of(BuildContext context) {
    final MixpanelAnalyticsProvider provider =
        context.findAncestorWidgetOfExactType();

    return provider.analytics;
  }

  MixpanelAnalyticsClient _client;
  MixpanelAnalyticsClient get client => _client;

  bool get enabled => _client.enabled;

  /// List of events that set to be sent to Mixpanel. Only populated if debugRecord is true
  List<Map<String, dynamic>> get debugList => _client.debugList;
  set enabled(bool val) => _client.enabled = val;

  /// Provide a name for your environment
  final String environmentName;

  bool _running = true;

  final MixpanelStorage storage;

  /// Construct a new instance of MixpanelAnalytics. Don't forget to call [init] afterwards.
  ///
  /// [debugRecord] will populate the [debugList] with events
  /// [debugPrint] will print a string representation of each event to the console
  /// [debugErrors] will ask Mixpanel to return verbose errors
  ///
  /// Set [environmentName] to the name of the environment the app is launched in to have it be
  /// reported with each event. Defaults to 'debug'.
  ///
  /// Set the [errorTrackHandler] to have all errors that occur during tracking report to that function,
  /// freeing you from doing a [catchError] after every call to a track function in your code base.
  MixpanelAnalytics({
    @required String token,
    @required this.storage,
    bool debugRecord = false,
    bool debugPrint = false,
    bool debugErrors = false,
    bool enabled = true,
    MixpanelErrorTrackHandler trackErrorHandler,
    this.environmentName = 'debug',
  }) : _client = MixpanelAnalyticsClient(
            token: token,
            debugRecord: debugRecord,
            debugPrint: debugPrint,
            debugErrors: debugErrors,
            errorTrackHandler: trackErrorHandler) {
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
  }

  Future<void> init() async {
    final packageInfo = await PackageInfo.fromPlatform();
    await Future.wait([
      _client.prepareDeviceInfo(packageInfo, environmentName),
      initPreferences(packageInfo),
    ]);
  }

  Future<void> initPreferences(PackageInfo packageInfo) async {
    // FIXME mixpanel android/ios additionally check for existence of a file
    if (!storage.firstOpen) {
      storage.setFirstOpen(true);
      _client.trackFirstOpen();
    }

    final savedVersion = storage.version;
    final currentVersion = packageInfo.version;
    // FIXME may only want to send if currentVersion is numerically larger than savedVersion
    if (savedVersion != null && currentVersion != savedVersion)
      _client.trackAppUpdated(currentVersion);
    storage.setVersion(currentVersion);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _running) {
      _running = false;
      _client.onBackground();
    } else if (state == AppLifecycleState.resumed && !_running) {
      _running = true;
      _client.onForeground();
    }
  }

  /// Use this before sending any events to associate them with an anonymous handle.
  /// Calling [setUserInfo] later with [autoAlias] set to [true] will then associate
  /// those past events with the new account.
  Future<void> setAnonymousUser() => _client.identify(Uuid().v4());

  Future<void> setUser(String id,
      {Map<String, dynamic> properties = const {},
      bool autoAlias = true}) async {
    await client.identify(id, autoAlias: autoAlias);
    await client.people('\$set', properties);
  }

  /// Track the given event. If [context] is not null, try getting the route's name on which this event occurred
  /// and report it in a screen_name field in  properties.
  Future<void> track(String name,
      {Map<String, dynamic> properties = const {}, BuildContext context}) {
    final screenName =
        context != null ? ModalRoute.of(context)?.settings?.name : null;
    if (screenName != null)
      properties = {'screen_name': screenName}..addAll(properties);
    return client.track(name, properties: properties);
  }

  /// Change a people property
  Future<void> people(String operation, Map<String, dynamic> properties) =>
      client.people(operation, properties);

  /// Start timer for the event [name]. Finish the timer by calling [track] with the same [name].
  ///
  /// Also consider using [trackTimedAction].
  void startTimer(String name) => client.timeEvent(name);

  /// Begin a timer for the action [name] and report when it finished with the duration it took.
  Future<void> trackTimedAction(String name, Future Function() timedAction,
      {Map<String, dynamic> properties = const {},
      BuildContext context}) async {
    try {
      startTimer(name);
      await timedAction();
    } finally {
      track(name, properties: properties, context: context);
    }
  }
}

/// A route observer that reports route changes from the navigator to mixpanel with screen_view events.
///
/// Typical usage is in the context of a [MaterialApp]:
///
/// MaterialApp(
///   navigatorObservers: [MixpanelAnalyticsObserver(analytics)]
/// )
class MixpanelAnalyticsObserver extends RouteObserver<PageRoute<dynamic>> {
  MixpanelAnalytics analytics;

  MixpanelAnalyticsObserver(this.analytics);

  @override
  void didPush(Route<dynamic> route, Route<dynamic> previousRoute) {
    super.didPush(route, previousRoute);
    if (route is PageRoute) {
      _track(route.settings);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic> previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute is PageRoute && route is PageRoute) {
      _track(previousRoute.settings);
    }
  }

  void _track(RouteSettings settings) {
    final name = settings.name;
    if (name != null) analytics.client.trackScreenView(name);
  }
}

/// An inherited widget that allows you to call
class MixpanelAnalyticsProvider extends InheritedWidget {
  final MixpanelAnalytics analytics;

  const MixpanelAnalyticsProvider(
      {@required this.analytics, @required Widget child})
      : super(child: child);

  @override
  bool updateShouldNotify(InheritedWidget oldWidget) => false;
}

/// Mixin that has to be fulfilled by some saving mechanism to support reading first open and version
mixin MixpanelStorage {
  bool get firstOpen;
  Future<void> setFirstOpen(bool value);

  String get version;
  Future<void> setVersion(String value);
}

/// Implementation of the [MixpanelStorage] using [SharedPreferences]
class MixpanelLocalStorage with MixpanelStorage {
  SharedPreferences prefs;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
  }

  static const firstOpenKey = 'MPFirstOpen';
  bool get firstOpen => prefs.getBool(firstOpenKey) ?? false;
  Future<bool> setFirstOpen(bool v) => prefs.setBool(firstOpenKey, v);

  static const versionKey = 'MPAppVersion';
  String get version => prefs.getString(versionKey);
  Future<bool> setVersion(String v) => prefs.setString(versionKey, v);
}
