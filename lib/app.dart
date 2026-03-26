import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/nearby_service.dart';
import 'services/gateway_service.dart';
import 'services/storage_service.dart';
import 'core/theme.dart';

class MeshApp extends StatelessWidget {
  const MeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => NearbyService(),
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
  static const Duration _pauseDisconnectDelay = Duration(seconds: 8);
  GatewayService? _gatewayService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize gateway after first frame so Provider is available
    WidgetsBinding.instance.addPostFrameCallback((_) => _initGateway());
  }

  void _initGateway() {
    final nearby = Provider.of<NearbyService>(context, listen: false);
    final storage = StorageService();
    _gatewayService = GatewayService(storage: storage, nearby: nearby);
    _gatewayService!.initialize();

    // Hook peer connection events to gateway
    nearby.onPeerConnectedCallback = (peerId, peerName) async {
      await _gatewayService!.onPeerConnected(peerId, peerName);
    };
    setState(() {});
  }

  @override
  void dispose() {
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

    if (state == AppLifecycleState.paused) {
      Future<void>.delayed(_pauseDisconnectDelay).then((_) async {
        // If still not running foreground by the time delay expires, tear down.
        if (!mounted) return;
        final current = WidgetsBinding.instance.lifecycleState;
        if (current == AppLifecycleState.paused ||
            current == AppLifecycleState.hidden) {
          await service.disconnect();
        }
      });
      return;
    }

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
        title: 'MeshAlert',
        theme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const HomeScreen(),
      ),
    );
  }
}
