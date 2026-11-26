class UserAddress {
  final String id;
  final String? sk;
  final String tag; // 'Home', 'Work', 'Workshop', 'Other', 'Parents'
  final String addressType; // 'UNIFIED' (supports both Pan-India Courier & Doorstep)
  final String? recipientName;
  final String? recipientPhone;
  final String flatNo;
  final String streetArea;
  final String landmark;
  final String city;
  final String? stateName;
  final String pincode;
  final double latitude;
  final double longitude;
  final bool isDefault;

  const UserAddress({
    required this.id,
    this.sk,
    required this.tag,
    this.addressType = 'UNIFIED',
    this.recipientName,
    this.recipientPhone,
    required this.flatNo,
    required this.streetArea,
    this.landmark = '',
    required this.city,
    this.stateName,
    required this.pincode,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.isDefault = false,
  });

  bool get hasMapPin => latitude.abs() > 0.0001 && longitude.abs() > 0.0001;

  bool get isOnlineShipping => addressType.toUpperCase() == 'ONLINE_SHIPPING';

  bool get hasValidDoorstep {
    final f = flatNo.trim().toLowerCase();
    return f.isNotEmpty && f != 'current location' && f != 'home' && f != 'work';
  }

  String get fullAddress {
    final parts = <String>[];
    if (hasValidDoorstep) {
      parts.add(flatNo.trim());
    }
    String s = streetArea.trim();
    final c = city.trim();
    final st = (stateName ?? '').trim();
    final p = pincode.trim();

    // Prevent 'Bengaluru, Bengaluru' duplication if streetArea already contains city
    if (c.isNotEmpty && s.toLowerCase().endsWith(c.toLowerCase())) {
      s = s.substring(0, s.length - c.length).trim();
      if (s.endsWith(',')) s = s.substring(0, s.length - 1).trim();
    }

    if (s.isNotEmpty) {
      parts.add(s);
    }
    if (landmark.isNotEmpty) {
      parts.add(landmark.toLowerCase().startsWith('near ') ? landmark : 'Near $landmark');
    }
    final cityState = (st.isNotEmpty && st.toLowerCase() != c.toLowerCase())
        ? (c.isNotEmpty ? '$c, $st' : st)
        : c;
    if (cityState.isNotEmpty && p.isNotEmpty) {
      parts.add('$cityState - $p');
    } else if (cityState.isNotEmpty) {
      parts.add(cityState);
    } else if (p.isNotEmpty) {
      parts.add(p);
    }
    return parts.where((part) => part.isNotEmpty).join(', ');
  }

  UserAddress copyWith({
    String? id,
    String? sk,
    String? tag,
    String? addressType,
    String? recipientName,
    String? recipientPhone,
    String? flatNo,
    String? streetArea,
    String? landmark,
    String? city,
    String? stateName,
    String? pincode,
    double? latitude,
    double? longitude,
    bool? isDefault,
  }) {
    return UserAddress(
      id: id ?? this.id,
      sk: sk ?? this.sk,
      tag: tag ?? this.tag,
      addressType: addressType ?? this.addressType,
      recipientName: recipientName ?? this.recipientName,
      recipientPhone: recipientPhone ?? this.recipientPhone,
      flatNo: flatNo ?? this.flatNo,
      streetArea: streetArea ?? this.streetArea,
      landmark: landmark ?? this.landmark,
      city: city ?? this.city,
      stateName: stateName ?? this.stateName,
      pincode: pincode ?? this.pincode,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sk': sk,
    'tag': tag,
    'addressType': addressType,
    'recipientName': recipientName,
    'recipientPhone': recipientPhone,
    'flatNo': flatNo,
    'streetArea': streetArea,
    'landmark': landmark,
    'city': city,
    'stateName': stateName,
    'pincode': pincode,
    'latitude': latitude,
    'longitude': longitude,
    'isDefault': isDefault,
  };

  factory UserAddress.fromJson(Map<String, dynamic> json) => UserAddress(
    id: json['id'] as String? ?? 'addr_${DateTime.now().millisecondsSinceEpoch}',
    sk: json['sk'] as String?,
    tag: json['tag'] as String? ?? 'Home',
    addressType: json['addressType'] as String? ?? json['address_type'] as String? ?? 'UNIFIED',
    recipientName: json['recipientName'] as String? ?? json['recipient_name'] as String?,
    recipientPhone: json['recipientPhone'] as String? ?? json['recipient_phone'] as String?,
    flatNo: json['flatNo'] as String? ?? '',
    streetArea: json['streetArea'] as String? ?? '',
    landmark: json['landmark'] as String? ?? '',
    city: json['city'] as String? ?? '',
    stateName: json['stateName'] as String? ?? json['state'] as String?,
    pincode: json['pincode'] as String? ?? '',
    latitude: (json['latitude'] is num) ? (json['latitude'] as num).toDouble() : (double.tryParse(json['latitude']?.toString() ?? '') ?? 0.0),
    longitude: (json['longitude'] is num) ? (json['longitude'] as num).toDouble() : (double.tryParse(json['longitude']?.toString() ?? '') ?? 0.0),
    isDefault: json['isDefault'] as bool? ?? false,
  );

  factory UserAddress.fromDynamo(Map<String, dynamic> json) {
    final line = (json['line1'] ?? json['address_line'] ?? '').toString();
    final parts = line.split(',');
    final flat = (json['house_no'] ?? '').toString().trim().isNotEmpty
        ? (json['house_no'] ?? '').toString().trim()
        : (parts.isNotEmpty ? parts.first.trim() : '');
    final street = (json['street'] ?? '').toString().trim().isNotEmpty
        ? (json['street'] ?? '').toString().trim()
        : (parts.length > 1 ? parts.sublist(1).join(',').trim() : line);
    return UserAddress(
      id: (json['address_id'] ?? json['id'] ?? 'addr_${DateTime.now().millisecondsSinceEpoch}').toString(),
      sk: json['sk']?.toString(),
      tag: (json['tag'] ?? json['label'] ?? 'Home').toString(),
      addressType: (json['address_type'] ?? 'UNIFIED').toString().toUpperCase(),
      recipientName: json['recipient_name']?.toString(),
      recipientPhone: json['recipient_phone']?.toString(),
      flatNo: flat,
      streetArea: street.isNotEmpty ? street : line,
      landmark: (json['landmark'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      stateName: json['state']?.toString(),
      pincode: (json['pincode'] ?? '').toString(),
      latitude: (json['latitude'] is num) ? (json['latitude'] as num).toDouble() : (double.tryParse(json['latitude']?.toString() ?? '') ?? 0.0),
      longitude: (json['longitude'] is num) ? (json['longitude'] as num).toDouble() : (double.tryParse(json['longitude']?.toString() ?? '') ?? 0.0),
      isDefault: json['is_default'] == true || json['isDefault'] == true,
    );
  }
}
