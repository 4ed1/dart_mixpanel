# Dart Mixpanel

This library provides deep integration with your flutter and Mixpanel, in a similar way that Mixpanel's iOS and Android libraries do. Core features are:

* Automatic Properties (first open, app updated, app session)
* Mapping to Mixpanel endpoints for events and people properties
* Automatically populates device and package info
* Convenient API for timed events and navigation tracking
* Support for integration testing by exposing all tracked events while in debug mode

## Usage Example

```dart
class MyAnalytics extends MixpanelAnalytics {
  static const bool debugAnalytics  = false;

  // Static methods don't support covariant, so we have to repeat this to get the proper type.
  static MyAnalytics of(BuildContext context) => MixpanelAnalytics.of(context);

  MyAnalytics(MixpanelStorage storage) : super(
    token: 'your-mixpanel-token',
    trackErrorHandler: (error, stackTrace, {endpoint, data}) => print('failed so send events'),
    storage: storage,
  );

  // We could also call [track] directly, but this way our API is typed and all strings are in one place.
  Future<void> reportSaidHi(int intensity, {BuildContext context}) => track('said_hi', properties: {'intensity': intensity}, context: context);
  
  Future<void> reportImageUpload(Future action(), {BuildContext context}) => trackTimedAction('image_upload', action, context: context);
}

Future main() async {
  // These actions will likely finish well below a couple milliseconds, but are still defined
  // async and we need those to be ready when the app goes up, so do those before we start up
  // properly.
  final storage = MixpanelLocalStorage();
  await storage.init();
  final analytics = MyAnalytics(storage);
  await analytics.init();
  // If you do this on startup, you can later alias the user to their actual id and the
  // previous action will be attributed to the proper account.
  await analytics.setAnonymousUser();

  runApp(MyApp(analytics));
}

class MyApp extends StatefulWidget {
  final MixpanelAnalytics analytics;
  const MyApp(this.analytics);

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return MixpanelAnalyticsProvider(
      analytics: widget.analytics,
      child: MaterialApp(
        navigatorObservers: [MixpanelAnalyticsObserver(widget.analytics)],
        home: MyWidget(),
      ),
    );
  }
}

class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FlatButton(child: Text('Hi'), onPressed: () {
      MyAnalytics.of(context).setUser('my-actual-user-id', properties: {'name': 'Bob'});

      // If you pass in the context, it will automatically try to find the name of the current route
      // that can be set via RouteSettings.name when you push a MaterialPageRoute
      MyAnalytics.of(context).reportSaidHi(7, context: context);

      // Timed action, event gets added a duration field
      MyAnalytics.of(context).reportImageUpload(() async {
        // await ...
      }, context: context);
    });
  }
}
```

## Missing Features
- [ ] Offline buffering
- [ ] Batched reporting (i.e. don't send each event immediately, but buffer a couple)
- [ ] Retry strategies for network errors
