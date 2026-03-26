import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/nearby_service.dart';
import 'services/gateway_service.dart';
import 'services/roll_call_scheduler.dart';
import 'services/notification_service.dart';
import 'services/danger_zone_service.dart';
import 'services/storage_service.dart';
import 'core/theme.dart';

class MeshApp extends StatelessWidget {
  const MeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NearbyService()),
        ChangeNotifierProvider(create: (_) => DangerZoneService()),
      ],
      child: const _MeshLifecycleRoot(),
    );
  }
}

class _MeshLifecycleRoot extends StatefulWidget {
  const _MeshLifecycleRoot();

  @override
  State<_MeshLifecycleRoot> createState() => _MeshLifecycleRootState();
}

class _MeshLifecycleRootState extends State<_MeshLifecycleRoot>
    with WidgetsBindingObserver {
  GatewayService? _gatewayService;
  RollCallScheduler? _rollCallScheduler;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize gateway after first frame so Provider is available
    WidgetsBinding.instance.addPostFrameCallback((_) => _initGateway());
  }

  void _initGateway() async {
    final nearby = Provider.of<NearbyService>(context, listen: false);
    final dangerZone = Provider.of<DangerZoneService>(context, listen: false);
    final storage = StorageService();
    _gatewayService = GatewayService(storage: storage, nearby: nearby);
    _gatewayService!.initialize();

    // Connect DangerZoneService ↔ NearbyService
    nearby.dangerZoneService = dangerZone;
    dangerZone.loadFromStorage();

    // Hook peer connection events to gateway
    nearby.onPeerConnectedCallback = (peerId, peerName) async {
      await _gatewayService!.onPeerConnected(peerId, peerName);
    };

    // Start the 5-minute auto roll call scheduler
    _rollCallScheduler = RollCallScheduler(nearby);
    _rollCallScheduler!.navigatorKey = _navigatorKey;
    _rollCallScheduler!.start();

    setState(() {});

    // Initialize notification service (non-blocking — UI is already loaded)
    NotificationService.instance.initialize(nearby).catchError((e) {
      debugPrint('Notification init error: $e');
    });
  }

  @override
  void dispose() {
    _rollCallScheduler?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final service = Provider.of<NearbyService>(context, listen: false);

    if (state == AppLifecycleState.detached) {
      service.disconnect();
      return;
    }

    // Do NOT disconnect on pause/hidden — keep mesh alive while screen is off.
    // Only reconnect if the service stopped for some other reason.
    if (state == AppLifecycleState.resumed && !service.isRunning) {
      _resumeMesh(service);
    }
  }

  Future<void> _resumeMesh(NearbyService service) async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('userName');
    if (name != null && name.isNotEmpty && !service.isRunning) {
      await service.init(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_gatewayService == null) {
      return MaterialApp(
        title: 'MeshAlert',
        theme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return ChangeNotifierProvider<GatewayService>.value(
      value: _gatewayService!,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'MeshAlert',
        theme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const HomeScreen(),
      ),
    );
  }
}
