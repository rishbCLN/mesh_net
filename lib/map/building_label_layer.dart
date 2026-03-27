import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class BuildingLabel {
  final String name;
  final LatLng position;
  final BuildingType type;

  const BuildingLabel({
    required this.name,
    required this.position,
    required this.type,
  });
}

enum BuildingType {
  hospital,
  shelter,
  danger,
  landmark,
  entrance,
}

const List<BuildingLabel> kDemoBuildingLabels = [
  BuildingLabel(
    name: 'Tech Tower',
    position: LatLng(12.9694, 79.1562),
    type: BuildingType.landmark,
  ),
  BuildingLabel(
    name: 'Health Center',
    position: LatLng(12.9700, 79.1540),
    type: BuildingType.hospital,
  ),
  BuildingLabel(
    name: 'Anna Auditorium',
    position: LatLng(12.9706, 79.1547),
    type: BuildingType.shelter,
  ),
  BuildingLabel(
    name: 'Main Gate',
    position: LatLng(12.9657, 79.1553),
    type: BuildingType.entrance,
  ),
  BuildingLabel(
    name: 'Viswam Library',
    position: LatLng(12.9682, 79.1578),
    type: BuildingType.landmark,
  ),
];

class BuildingLabelLayer extends StatelessWidget {
  final List<BuildingLabel> labels;

  const BuildingLabelLayer({
    super.key,
    this.labels = kDemoBuildingLabels,
  });

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: labels
          .map((label) => Marker(
                point: label.position,
                width: 160,
                height: 56,
                alignment: Alignment.topCenter,
                child: _BuildingLabelWidget(label: label),
              ))
          .toList(),
    );
  }
}

class _BuildingLabelWidget extends StatelessWidget {
  final BuildingLabel label;
  const _BuildingLabelWidget({required this.label});

  Color get _bgColor {
    switch (label.type) {
      case BuildingType.hospital:
        return const Color(0xFFE53935);
      case BuildingType.shelter:
        return const Color(0xFF2E7D32);
      case BuildingType.danger:
        return const Color(0xFFFF6F00);
      case BuildingType.entrance:
        return const Color(0xFF1565C0);
      case BuildingType.landmark:
        return const Color(0xFF212121);
    }
  }

  IconData get _icon {
    switch (label.type) {
      case BuildingType.hospital:
        return Icons.local_hospital;
      case BuildingType.shelter:
        return Icons.holiday_village;
      case BuildingType.danger:
        return Icons.warning_amber;
      case BuildingType.entrance:
        return Icons.door_front_door;
      case BuildingType.landmark:
        return Icons.business;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, color: Colors.white, size: 13),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    height: 1.0,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
        
        Container(
          width: 2,
          height: 8,
          color: _bgColor,
        ),
        
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: _bgColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
          ),
        ),
      ],
    );
  }
}
