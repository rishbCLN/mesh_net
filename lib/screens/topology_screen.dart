import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/triage_status.dart';
import '../services/nearby_service.dart';

// ─── Data classes ─────────────────────────────────────────────────────────────

class _NodeState {
  double x, y;
  double vx = 0, vy = 0;

  _NodeState(this.x, this.y);
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({super.key});

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

  // Physics state
  final Map<String, _NodeState> _nodes = {};
  Size _canvasSize = Size.zero;

  // Physics constants
  static const double _kSpringConnected = 0.04;
  static const double _kSpringDiscovered = 0.015;
  static const double _kRepel = 18000.0;
  static const double _kGravity = 0.03;
  static const double _kDamping = 0.82;
  static const double _kRestConnected = 130.0;
  static const double _kRestDiscovered = 220.0;
  static const double _dt = 0.8;

  // Tooltip
  String? _tappedNodeId;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(days: 1), // runs indefinitely
    )
      ..addListener(_tick)
      ..repeat();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// One physics integration step, called every animation frame.
  void _tick() {
    if (_canvasSize == Size.zero || !mounted) return;
    final service = Provider.of<NearbyService>(context, listen: false);
    _syncNodes(service);
    _integrate(service);
    setState(() {}); // repaint
  }

  String get _meId => 'ME';

  /// Add/remove nodes to match current device lists.
  void _syncNodes(NearbyService service) {
    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;
    final rng = Random();

    // Ensure "me" node exists, anchored near centre
    _nodes.putIfAbsent(_meId, () => _NodeState(cx, cy));

    // Connected devices: initialise at random position on inner ring
    for (final d in service.connectedDevices) {
      _nodes.putIfAbsent(d.id, () {
        final angle = rng.nextDouble() * 2 * pi;
        return _NodeState(
          cx + cos(angle) * _kRestConnected,
          cy + sin(angle) * _kRestConnected,
        );
      });
    }

    // Discovered devices: outer ring
    for (final d in service.discoveredDevices) {
      _nodes.putIfAbsent(d.id, () {
        final angle = rng.nextDouble() * 2 * pi;
        return _NodeState(
          cx + cos(angle) * _kRestDiscovered,
          cy + sin(angle) * _kRestDiscovered,
        );
      });
    }

    // Prune disconnected devices
    final validIds = {
      _meId,
      ...service.connectedDevices.map((d) => d.id),
      ...service.discoveredDevices.map((d) => d.id),
    };
    _nodes.removeWhere((id, _) => !validIds.contains(id));
  }

  /// Run one Euler integration step for all nodes.
  void _integrate(NearbyService service) {
    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;

    // Compute forces for every node
    final fx = <String, double>{};
    final fy = <String, double>{};
    for (final id in _nodes.keys) {
      fx[id] = 0;
      fy[id] = 0;
    }

    // 1. Gravity toward canvas centre (for all nodes)
    for (final entry in _nodes.entries) {
      final id = entry.key;
      final n = entry.value;
      fx[id] = fx[id]! + _kGravity * (cx - n.x);
      fy[id] = fy[id]! + _kGravity * (cy - n.y);
    }

    // 2. Spring along edges (me ↔ connected, me ↔ discovered)
    final meNode = _nodes[_meId]!;
    _applySpring(fx, fy, _meId, meNode,
        service.connectedDevices.map((d) => d.id), _kSpringConnected, _kRestConnected);
    _applySpring(fx, fy, _meId, meNode,
        service.discoveredDevices.map((d) => d.id), _kSpringDiscovered, _kRestDiscovered);

    // 3. Repulsion between all node pairs
    final ids = _nodes.keys.toList();
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = _nodes[ids[i]]!;
        final b = _nodes[ids[j]]!;
        final dx = a.x - b.x;
        final dy = a.y - b.y;
        final dist2 = max(dx * dx + dy * dy, 1.0);
        final force = _kRepel / dist2;
        final dist = sqrt(dist2);
        final nx = dx / dist;
        final ny = dy / dist;
        fx[ids[i]] = fx[ids[i]]! + force * nx;
        fy[ids[i]] = fy[ids[i]]! + force * ny;
        fx[ids[j]] = fx[ids[j]]! - force * nx;
        fy[ids[j]] = fy[ids[j]]! - force * ny;
      }
    }

    // 4. Integrate + clamp to canvas
    const pad = 40.0;
    for (final entry in _nodes.entries) {
      final id = entry.key;
      final n = entry.value;
      n.vx = (n.vx + fx[id]! * _dt) * _kDamping;
      n.vy = (n.vy + fy[id]! * _dt) * _kDamping;
      n.x = (n.x + n.vx * _dt).clamp(pad, _canvasSize.width - pad);
      n.y = (n.y + n.vy * _dt).clamp(pad, _canvasSize.height - pad);
    }
  }

  void _applySpring(Map<String, double> fx, Map<String, double> fy,
      String anchorId, _NodeState anchor, Iterable<String> peerIds,
      double k, double restLen) {
    for (final peerId in peerIds) {
      final peer = _nodes[peerId];
      if (peer == null) continue;
      final dx = peer.x - anchor.x;
      final dy = peer.y - anchor.y;
      final dist = max(sqrt(dx * dx + dy * dy), 0.001);
      final force = k * (dist - restLen);
      final nx = dx / dist;
      final ny = dy / dist;
      fx[anchorId] = fx[anchorId]! + force * nx;
      fy[anchorId] = fy[anchorId]! + force * ny;
      if (fx.containsKey(peerId)) {
        fx[peerId] = fx[peerId]! - force * nx;
        fy[peerId] = fy[peerId]! - force * ny;
      }
    }
  }

  void _onTap(TapDownDetails details) {
    const hitRadius = 30.0;
    String? hit;
    final pos = details.localPosition;
    for (final entry in _nodes.entries) {
      final n = entry.value;
      final dx = n.x - pos.dx;
      final dy = n.y - pos.dy;
      if (dx * dx + dy * dy < hitRadius * hitRadius) {
        hit = entry.key;
        break;
      }
    }
    setState(() => _tappedNodeId = (hit == _tappedNodeId) ? null : hit);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NearbyService>(
      builder: (context, service, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D0D1A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF10102A),
            title: const Text(
              'Mesh Topology',
              style: TextStyle(color: Colors.white),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(30),
              child: _StatsBar(service: service),
            ),
          ),
          body: GestureDetector(
            onTapDown: _onTap,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _canvasSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                return CustomPaint(
                  painter: _TopologyPainter(
                    nodes: Map.unmodifiable(_nodes),
                    meId: _meId,
                    service: service,
                    tappedNodeId: _tappedNodeId,
                    now: DateTime.now(),
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

// ─── Stats bar ────────────────────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final NearbyService service;
  const _StatsBar({required this.service});

  @override
  Widget build(BuildContext context) {
    final nodes = 1 + service.connectedDevices.length + service.discoveredDevices.length;
    final edges = service.connectedDevices.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Chip(Icons.device_hub, '$nodes nodes', Colors.cyanAccent),
          const SizedBox(width: 16),
          _Chip(Icons.linear_scale, '$edges edges', Colors.greenAccent),
          const SizedBox(width: 16),
          _Chip(Icons.repeat, '${service.totalMessagesRouted} relayed', Colors.orangeAccent),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Chip(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ─── Painter ──────────────────────────────────────────────────────────────────

class _TopologyPainter extends CustomPainter {
  final Map<String, _NodeState> nodes;
  final String meId;
  final NearbyService service;
  final String? tappedNodeId;
  final DateTime now;

  static const _kRelayTTL = 4000; // ms — matches NearbyService._kRelayEventTTL

  _TopologyPainter({
    required this.nodes,
    required this.meId,
    required this.service,
    required this.tappedNodeId,
    required this.now,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _drawBackground(canvas, size);
    _drawEdges(canvas);
    _drawRelayPulses(canvas);
    _drawNodes(canvas);
  }

  void _drawBackground(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0D0D1A),
    );
    // Subtle radial glow at canvas centre
    final meNode = nodes[meId];
    if (meNode == null) return;
    canvas.drawCircle(
      Offset(meNode.x, meNode.y),
      200,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.blueAccent.withOpacity(0.08),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(
            center: Offset(meNode.x, meNode.y), radius: 200)),
    );
  }

  void _drawEdges(Canvas canvas) {
    final meNode = nodes[meId];
    if (meNode == null) return;
    final meOff = Offset(meNode.x, meNode.y);

    // Connected: solid bright edge
    final connectedPaint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.45)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;

    for (final d in service.connectedDevices) {
      final peer = nodes[d.id];
      if (peer == null) continue;
      canvas.drawLine(meOff, Offset(peer.x, peer.y), connectedPaint);
    }

    // Discovered: dashed faint edge
    for (final d in service.discoveredDevices) {
      final peer = nodes[d.id];
      if (peer == null) continue;
      _drawDashedLine(canvas, meOff, Offset(peer.x, peer.y),
          Colors.white.withOpacity(0.18), 1.0);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Color color, double width) {
    const dashLen = 6.0;
    const gapLen = 5.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;

    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final dist = sqrt(dx * dx + dy * dy);
    if (dist == 0) return;
    final nx = dx / dist;
    final ny = dy / dist;

    double pos = 0;
    bool drawing = true;
    while (pos < dist) {
      final end = min(pos + (drawing ? dashLen : gapLen), dist);
      if (drawing) {
        canvas.drawLine(
          Offset(a.dx + nx * pos, a.dy + ny * pos),
          Offset(a.dx + nx * end, a.dy + ny * end),
          paint,
        );
      }
      pos = end;
      drawing = !drawing;
    }
  }

  void _drawRelayPulses(Canvas canvas) {
    final meNode = nodes[meId];
    if (meNode == null) return;
    final meOff = Offset(meNode.x, meNode.y);

    for (final event in service.relayEvents) {
      final age = now.difference(event.timestamp).inMilliseconds;
      if (age > _kRelayTTL) continue;
      final t = age / _kRelayTTL.toDouble(); // 0.0 → 1.0

      final fromNode = nodes[event.fromId];
      final toNode = nodes[event.toId];

      final color = event.isSOS
          ? Color.lerp(Colors.redAccent, Colors.red, t)!
          : Color.lerp(Colors.cyanAccent, Colors.deepPurpleAccent, t)!;

      final opacity = (1.0 - t).clamp(0.0, 1.0);

      // First half: fromId → me
      // Second half: me → toId
      Offset dotPos;
      if (t < 0.5) {
        final s = t / 0.5; // 0→1
        if (fromNode != null) {
          dotPos = Offset.lerp(Offset(fromNode.x, fromNode.y), meOff, s)!;
        } else {
          dotPos = meOff;
        }
      } else {
        final s = (t - 0.5) / 0.5; // 0→1
        if (toNode != null) {
          dotPos = Offset.lerp(meOff, Offset(toNode.x, toNode.y), s)!;
        } else {
          dotPos = meOff;
        }
      }

      // Glow
      canvas.drawCircle(
        dotPos,
        12,
        Paint()..color = color.withOpacity(opacity * 0.25),
      );
      // Core
      canvas.drawCircle(
        dotPos,
        5,
        Paint()..color = color.withOpacity(opacity),
      );
    }
  }

  void _drawNodes(Canvas canvas) {
    for (final entry in nodes.entries) {
      final id = entry.key;
      final node = entry.value;
      final isMe = id == meId;
      final isTapped = id == tappedNodeId;

      // Resolve device info
      String label;
      Color baseColor;
      TriageStatus? triage;

      if (isMe) {
        label = service.userName.isNotEmpty ? service.userName : 'Me';
        baseColor = Colors.blueAccent;
        triage = service.myTriageStatus;
      } else {
        final connected = service.connectedDevices.where((d) => d.id == id);
        final discovered = service.discoveredDevices.where((d) => d.id == id);
        if (connected.isNotEmpty) {
          label = connected.first.name;
          baseColor = Colors.greenAccent;
        } else if (discovered.isNotEmpty) {
          label = discovered.first.name;
          baseColor = Colors.amber;
        } else {
          label = id.substring(0, min(6, id.length));
          baseColor = Colors.grey;
        }
        triage = service.peerLocations[label]?.triageStatus;
      }

      final pos = Offset(node.x, node.y);
      final radius = isMe ? 22.0 : 15.0;

      // Tapped glow
      if (isTapped) {
        canvas.drawCircle(
          pos,
          radius + 14,
          Paint()..color = baseColor.withOpacity(0.15),
        );
      }

      // Triage colour outer ring
      if (triage != null && triage != TriageStatus.ok) {
        canvas.drawCircle(
          pos,
          radius + 5,
          Paint()
            ..color = triage.color.withOpacity(0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }

      // Soft glow halo
      canvas.drawCircle(
        pos,
        radius + 6,
        Paint()..color = baseColor.withOpacity(0.18),
      );

      // Shadow
      canvas.drawCircle(
        pos + const Offset(2, 2),
        radius,
        Paint()..color = Colors.black38,
      );

      // Main node fill
      canvas.drawCircle(pos, radius, Paint()..color = baseColor.withOpacity(0.9));

      // Inner highlight
      canvas.drawCircle(
        pos - Offset(radius * 0.25, radius * 0.25),
        radius * 0.35,
        Paint()..color = Colors.white.withOpacity(0.2),
      );

      // Icon for "me"
      if (isMe) {
        final tp = TextPainter(
          text: const TextSpan(
            text: '⬡',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
      }

      // Label below node
      _drawLabel(canvas, label, pos, radius, baseColor, triage);

      // Tooltip on tap
      if (isTapped) {
        _drawTooltip(canvas, pos, radius, label, triage, isMe, service);
      }
    }
  }

  void _drawLabel(Canvas canvas, String label, Offset pos, double radius,
      Color baseColor, TriageStatus? triage) {
    final displayLabel = label.length > 10 ? '${label.substring(0, 9)}…' : label;
    final tp = TextPainter(
      text: TextSpan(
        text: displayLabel,
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy + radius + 4));

    // Triage badge under label
    if (triage != null && triage != TriageStatus.ok) {
      final badgeTp = TextPainter(
        text: TextSpan(
          text: triage.label,
          style: TextStyle(
            color: triage.color,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      badgeTp.paint(
        canvas,
        Offset(pos.dx - badgeTp.width / 2, pos.dy + radius + 16),
      );
    }
  }

  void _drawTooltip(
    Canvas canvas,
    Offset pos,
    double radius,
    String label,
    TriageStatus? triage,
    bool isMe,
    NearbyService service,
  ) {
    final lines = [
      label,
      isMe ? 'This device' : 'Peer device',
      if (triage != null) '${triage.label}: ${triage.description}',
    ];

    const padding = 8.0;
    const lineH = 14.0;
    final boxW = 160.0;
    final boxH = lines.length * lineH + padding * 2;

    var tx = pos.dx + radius + 10;
    var ty = pos.dy - boxH / 2;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tx, ty, boxW, boxH),
      const Radius.circular(8),
    );

    canvas.drawRRect(rect, Paint()..color = const Color(0xDD1E2040));
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Colors.cyanAccent.withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    for (var i = 0; i < lines.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: lines[i],
          style: TextStyle(
            color: i == 0 ? Colors.white : Colors.white70,
            fontSize: i == 0 ? 12 : 10,
            fontWeight: i == 0 ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: boxW - padding * 2);
      tp.paint(canvas, Offset(tx + padding, ty + padding + i * lineH));
    }
  }

  @override
  bool shouldRepaint(_TopologyPainter old) => true; // always repaint while ticker runs
}
