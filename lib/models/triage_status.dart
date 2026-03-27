import 'package:flutter/material.dart';

enum TriageStatus {
  ok,       
  injured,  
  critical, 
  sos,      
}

extension TriageStatusX on TriageStatus {
  String get label {
    switch (this) {
      case TriageStatus.ok:       return 'OK';
      case TriageStatus.injured:  return 'INJURED';
      case TriageStatus.critical: return 'CRITICAL';
      case TriageStatus.sos:      return 'TRAPPED';
    }
  }

  String get description {
    switch (this) {
      case TriageStatus.ok:       return 'Safe and uninjured';
      case TriageStatus.injured:  return 'Minor injury, can move';
      case TriageStatus.critical: return 'Serious injury — needs help soon';
      case TriageStatus.sos:      return 'Trapped / life-threatening emergency';
    }
  }

  Color get color {
    switch (this) {
      case TriageStatus.ok:       return const Color(0xFF4CAF50); 
      case TriageStatus.injured:  return const Color(0xFFFFEB3B); 
      case TriageStatus.critical: return const Color(0xFFFF9800); 
      case TriageStatus.sos:      return const Color(0xFFF44336); 
    }
  }

  Color get onColor {
    
    switch (this) {
      case TriageStatus.injured: return Colors.black87; 
      default:                   return Colors.white;
    }
  }

  IconData get icon {
    switch (this) {
      case TriageStatus.ok:       return Icons.check_circle_rounded;
      case TriageStatus.injured:  return Icons.healing_rounded;
      case TriageStatus.critical: return Icons.local_hospital_rounded;
      case TriageStatus.sos:      return Icons.warning_rounded;
    }
  }

  String get jsonValue => name; 

  static TriageStatus fromJson(String? value) {
    switch (value) {
      case 'injured':  return TriageStatus.injured;
      case 'critical': return TriageStatus.critical;
      case 'sos':      return TriageStatus.sos;
      default:         return TriageStatus.ok;
    }
  }
}
