class Device {
  final String id;
  final String name;
  final bool isConnected;

  Device({
    required this.id,
    required this.name,
    required this.isConnected,
  });

  Device copyWith({
    String? id,
    String? name,
    bool? isConnected,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}
