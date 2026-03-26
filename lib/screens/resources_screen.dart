import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/resource.dart';
import '../services/nearby_service.dart';

class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({super.key});

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D1423),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D1423),
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.inventory_2_rounded, color: Colors.amberAccent, size: 22),
                SizedBox(width: 8),
                Text('Resources', style: TextStyle(color: Colors.white)),
              ],
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: Colors.amberAccent,
              labelColor: Colors.amberAccent,
              unselectedLabelColor: Colors.white54,
              tabs: const [
                Tab(icon: Icon(Icons.volunteer_activism), text: 'I Have'),
                Tab(icon: Icon(Icons.search), text: 'I Need'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _OfferTab(service: service),
              _NeedTab(service: service),
            ],
          ),
        );
      },
    );
  }
}

// ─── "I Have" tab: offer resources ───────────────────────────────────────────

class _OfferTab extends StatelessWidget {
  final NearbyService service;

  const _OfferTab({required this.service});

  @override
  Widget build(BuildContext context) {
    // Resources currently being offered by ME
    final myOffers = service.peerResources.values
        .where((r) => r.userId == service.userName && r.isOffering)
        .toList();

    // Resources NEEDED by others on the mesh
    final othersNeeds = service.peerResources.values
        .where((r) => r.userId != service.userName && !r.isOffering)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'TAP TO OFFER A RESOURCE',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        _ResourceGrid(
          service: service,
          isOffering: true,
          activeTypes: myOffers.map((r) => r.resourceType).toSet(),
        ),
        if (othersNeeds.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text(
            'OTHERS NEED',
            style: TextStyle(
              color: Colors.redAccent,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          ...othersNeeds.map((r) => _ResourceListTile(
                resource: r,
                myLocation: service.myLocation,
              )),
        ],
      ],
    );
  }
}

// ─── "I Need" tab: request resources ─────────────────────────────────────────

class _NeedTab extends StatelessWidget {
  final NearbyService service;

  const _NeedTab({required this.service});

  @override
  Widget build(BuildContext context) {
    // Resources currently being requested by ME
    final myNeeds = service.peerResources.values
        .where((r) => r.userId == service.userName && !r.isOffering)
        .toList();

    // Resources OFFERED by others on the mesh
    final othersOffers = service.peerResources.values
        .where((r) => r.userId != service.userName && r.isOffering)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'TAP TO REQUEST A RESOURCE',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        _ResourceGrid(
          service: service,
          isOffering: false,
          activeTypes: myNeeds.map((r) => r.resourceType).toSet(),
        ),
        if (othersOffers.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text(
            'AVAILABLE NEARBY',
            style: TextStyle(
              color: Colors.greenAccent,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          ...othersOffers.map((r) => _ResourceListTile(
                resource: r,
                myLocation: service.myLocation,
              )),
        ],
      ],
    );
  }
}

// ─── Resource selection grid ─────────────────────────────────────────────────

class _ResourceGrid extends StatelessWidget {
  final NearbyService service;
  final bool isOffering;
  final Set<ResourceType> activeTypes;

  const _ResourceGrid({
    required this.service,
    required this.isOffering,
    required this.activeTypes,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: ResourceType.values.map((type) {
        final isActive = activeTypes.contains(type);
        return _ResourceChip(
          type: type,
          isActive: isActive,
          onTap: () => _broadcast(context, type),
        );
      }).toList(),
    );
  }

  Future<void> _broadcast(BuildContext context, ResourceType type) async {
    final myLoc = service.myLocation;
    final resource = ResourceBroadcast(
      userId: service.userName,
      userName: service.userName,
      resourceType: type,
      isOffering: isOffering,
      latitude: myLoc?.latitude ?? 0.0,
      longitude: myLoc?.longitude ?? 0.0,
      timestamp: DateTime.now(),
    );
    await service.broadcastResource(resource);
    HapticFeedback.mediumImpact();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isOffering
                ? '${type.emoji} Offering ${type.label} — broadcast to mesh'
                : '${type.emoji} Requesting ${type.label} — broadcast to mesh',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: isOffering ? Colors.green.shade800 : Colors.orange.shade800,
        ),
      );
    }
  }
}

class _ResourceChip extends StatelessWidget {
  final ResourceType type;
  final bool isActive;
  final VoidCallback onTap;

  const _ResourceChip({
    required this.type,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: (MediaQuery.of(context).size.width - 52) / 3,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.amberAccent.withValues(alpha: 0.15)
              : const Color(0xFF1A2440),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive
                ? Colors.amberAccent
                : Colors.white.withValues(alpha: 0.08),
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(type.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 6),
            Text(
              type.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isActive ? Colors.amberAccent : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isActive)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Icon(Icons.check_circle, color: Colors.amberAccent, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Resource list tile (shows peer resources with distance) ─────────────────

class _ResourceListTile extends StatelessWidget {
  final ResourceBroadcast resource;
  final dynamic myLocation; // LocationUpdate?

  const _ResourceListTile({
    required this.resource,
    this.myLocation,
  });

  @override
  Widget build(BuildContext context) {
    String distText = '';
    if (myLocation != null && resource.latitude != 0.0) {
      final meters = _distanceMeters(
        myLocation.latitude,
        myLocation.longitude,
        resource.latitude,
        resource.longitude,
      );
      distText = _formatDistance(meters);
    }

    final isOffer = resource.isOffering;
    final color = isOffer ? Colors.greenAccent : Colors.redAccent;

    return Card(
      color: const Color(0xFF1A2440),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(resource.resourceType.emoji,
                style: const TextStyle(fontSize: 22)),
          ),
        ),
        title: Text(
          '${resource.userName} — ${resource.resourceType.label}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          isOffer ? 'Offering' : 'Needs this',
          style: TextStyle(color: color, fontSize: 12),
        ),
        trailing: distText.isNotEmpty
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  distText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : null,
      ),
    );
  }

  static double _distanceMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a1 = lat1 * pi / 180.0;
    final a2 = lat2 * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(a1) * cos(a2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earthRadius * c;
  }

  static String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }
}
