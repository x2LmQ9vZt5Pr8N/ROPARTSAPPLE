import '../models/product.dart';

enum QrItemType { kit, product }

class ScannedRoItem {
  final String code;
  final String name;
  final QrItemType type;
  final double mrp;
  final double price;
  final String description;
  final String imageAsset;
  final String batchNumber;
  final String hologramCode;
  final String qcStatus;
  final String warranty;
  final String compatibility;
  final String? partNature;
  final bool? isConsumable;
  final int? shelfLifeLiters;
  final double? warrantyYears;
  final int? shelfLifeMonths;
  final String? cbmSpecLabel;
  final List<String> bundledItems;
  final List<Map<String, dynamic>> rawComponents;
  final String? sku;
  final List<Map<String, dynamic>> freeSpares;
  final bool sealedFreeSpares;
  final bool isComplimentary;

  const ScannedRoItem({
    required this.code,
    required this.name,
    required this.type,
    required this.mrp,
    required this.price,
    required this.description,
    required this.imageAsset,
    required this.batchNumber,
    required this.hologramCode,
    required this.qcStatus,
    required this.warranty,
    required this.compatibility,
    this.partNature,
    this.isConsumable,
    this.shelfLifeLiters,
    this.warrantyYears,
    this.shelfLifeMonths,
    this.cbmSpecLabel,
    this.bundledItems = const [],
    this.rawComponents = const [],
    this.sku,
    this.freeSpares = const [],
    this.sealedFreeSpares = false,
    this.isComplimentary = false,
  });

  ScannedRoItem copyWith({
    String? name,
    double? mrp,
    double? price,
    List<Map<String, dynamic>>? rawComponents,
    String? sku,
    List<Map<String, dynamic>>? freeSpares,
    bool? sealedFreeSpares,
    bool? isComplimentary,
  }) {
    return ScannedRoItem(
      code: code,
      name: name ?? this.name,
      type: type,
      mrp: mrp ?? this.mrp,
      price: price ?? this.price,
      description: description,
      imageAsset: imageAsset,
      batchNumber: batchNumber,
      hologramCode: hologramCode,
      qcStatus: qcStatus,
      warranty: warranty,
      compatibility: compatibility,
      partNature: partNature,
      isConsumable: isConsumable,
      shelfLifeLiters: shelfLifeLiters,
      warrantyYears: warrantyYears,
      shelfLifeMonths: shelfLifeMonths,
      cbmSpecLabel: cbmSpecLabel,
      bundledItems: bundledItems,
      rawComponents: rawComponents ?? this.rawComponents,
      sku: sku ?? this.sku,
      freeSpares: freeSpares ?? this.freeSpares,
      sealedFreeSpares: sealedFreeSpares ?? this.sealedFreeSpares,
      isComplimentary: isComplimentary ?? this.isComplimentary,
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'type': type == QrItemType.kit ? 'KIT' : 'PRODUCT',
    'mrp': mrp,
    'price': price,
    'description': description,
    'imageAsset': imageAsset,
    'batchNumber': batchNumber,
    'hologramCode': hologramCode,
    'qcStatus': qcStatus,
    'warranty': warranty,
    'compatibility': compatibility,
    if (partNature != null) 'part_nature': partNature,
    if (isConsumable != null) 'is_consumable': isConsumable,
    if (shelfLifeLiters != null) 'shelf_life_liters': shelfLifeLiters,
    if (warrantyYears != null) 'warranty_years': warrantyYears,
    if (shelfLifeMonths != null) 'shelf_life_months': shelfLifeMonths,
    if (cbmSpecLabel != null) 'cbm_spec_label': cbmSpecLabel,
    'bundledItems': bundledItems,
    'rawComponents': rawComponents,
    if (sku != null) 'sku': sku,
    if (freeSpares.isNotEmpty) 'freeSpares': freeSpares,
    if (sealedFreeSpares) 'sealedFreeSpares': true,
    if (isComplimentary) 'isComplimentary': true,
  };

  factory ScannedRoItem.fromJson(Map<String, dynamic> json) => ScannedRoItem(
    code: json['code'] ?? '',
    name: json['name'] ?? '',
    type: json['type'] == 'KIT' ? QrItemType.kit : QrItemType.product,
    mrp: (json['mrp'] is num) ? (json['mrp'] as num).toDouble() : (double.tryParse(json['mrp']?.toString() ?? '') ?? 0.0),
    price: (json['price'] is num) ? (json['price'] as num).toDouble() : (double.tryParse(json['price']?.toString() ?? '') ?? 0.0),
    description: json['description'] ?? '',
    imageAsset: json['imageAsset'] ?? 'assets/images/membrane.png',
    batchNumber: json['batchNumber'] ?? '',
    hologramCode: json['hologramCode'] ?? '',
    qcStatus: json['qcStatus'] ?? '',
    warranty: json['warranty']?.toString() ?? '',
    compatibility: json['compatibility'] ?? 'Universal Fit',
    partNature: (json['partNature'] ?? json['part_nature'])?.toString(),
    isConsumable: (json['isConsumable'] ?? json['is_consumable']) is bool
        ? (json['isConsumable'] ?? json['is_consumable']) as bool
        : null,
    shelfLifeLiters: int.tryParse((json['shelfLifeLiters'] ?? json['shelf_life_liters'])?.toString() ?? ''),
    warrantyYears: double.tryParse((json['warrantyYears'] ?? json['warranty_years'])?.toString() ?? ''),
    shelfLifeMonths: int.tryParse((json['shelfLifeMonths'] ?? json['shelf_life_months'])?.toString() ?? ''),
    cbmSpecLabel: (json['cbmSpecLabel'] ?? json['cbm_spec_label'])?.toString(),
    bundledItems: (json['bundledItems'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
    rawComponents: (json['rawComponents'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? const [],
    sku: (json['sku'] ?? json['product_sku'])?.toString(),
    freeSpares: (json['freeSpares'] ?? json['free_spares'] ?? json['free_spares_snapshot']) is List
        ? ((json['freeSpares'] ?? json['free_spares'] ?? json['free_spares_snapshot']) as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const [],
    sealedFreeSpares: json['sealedFreeSpares'] == true || json['sealed_free_spares'] == true,
    isComplimentary: json['isComplimentary'] == true || json['is_complimentary'] == true,
  );

  bool get isKit => type == QrItemType.kit;
  double get savings => mrp - price;
  double get discountPercent => mrp > 0 ? (((mrp - price) / mrp) * 100).roundToDouble() : 0;

  Product toProduct() {
    return Product(
      id: code,
      sku: code,
      name: name,
      slug: code.toLowerCase(),
      brand: 'ROParts Genuine',
      sellingPrice: price.round(),
      mrp: mrp.round(),
      image: imageAsset,
      shortDescription: description,
      categoryId: isKit ? 'kits' : 'spares',
      segment: 'domestic',
    );
  }
}

class QrProductRegistry {
  static final Map<String, ScannedRoItem> _catalog = {
    // 1. Individual Spare Parts (Prefix: A00... / PRD...)
    'A00001': const ScannedRoItem(
      code: 'A00001',
      name: 'Aquatech 75 GPD RO Membrane',
      type: QrItemType.product,
      mrp: 1899,
      price: 849,
      description: 'Factory-tested 0.0001µ polyamide thin-film composite membrane. 97% TDS rejection rate.',
      imageAsset: 'assets/images/domestic-membrane-roll.jpg',
      batchNumber: 'BATCH-2026-BLR-0482',
      hologramCode: 'ROP-SECURE-8921',
      qcStatus: 'Passed 150 PSI Burst & Pressure Rejection Test',
      warranty: '1-Year Direct Replacement Warranty',
      compatibility: 'Kent, Aquaguard, Pureit, Livpure, ZeroB, All 75/80 GPD Domestic ROs',
    ),
    'A00002': const ScannedRoItem(
      code: 'A00002',
      name: '100 GPD Heavy-Duty RO Booster Pump',
      type: QrItemType.product,
      mrp: 2499,
      price: 1299,
      description: 'High-torque pure copper wound 24V DC motor. 130 PSI working pressure, 1.8 LPM open flow.',
      imageAsset: 'assets/images/whichpart.png',
      batchNumber: 'BATCH-2026-PUMP-9104',
      hologramCode: 'ROP-SECURE-4431',
      qcStatus: 'Passed 24h Continuous Run & Thermal Cut-off Test',
      warranty: '1-Year On-Site Replacement Warranty',
      compatibility: 'All standard domestic RO purifiers (Kent, Aquaguard, Havells, etc.)',
    ),
    'A00003': const ScannedRoItem(
      code: 'A00003',
      name: 'Active Copper + Alkaline Mineral Cartridge',
      type: QrItemType.product,
      mrp: 999,
      price: 449,
      description: 'Infuses essential copper ions, balances water pH to 8.0–8.5, and restores calcium & magnesium.',
      imageAsset: 'assets/images/alkaline.png',
      batchNumber: 'BATCH-2026-MIN-1120',
      hologramCode: 'ROP-SECURE-7729',
      qcStatus: 'Food Grade Biocompatibility & pH Buffer Certified',
      warranty: '12-Month Optimal Mineral Activity Guarantee',
      compatibility: 'Fits all inline push-fit 1/4" domestic RO connections',
    ),
    'A00004': const ScannedRoItem(
      code: 'A00004',
      name: '24V 2.5A SMPS Power Supply Adapter',
      type: QrItemType.product,
      mrp: 899,
      price: 399,
      description: 'Stabilized SMPS with built-in surge protection, short-circuit auto-recovery, and copper winding.',
      imageAsset: 'assets/images/whichpart.png',
      batchNumber: 'BATCH-2026-PWR-3312',
      hologramCode: 'ROP-SECURE-2105',
      qcStatus: 'Passed 3000V High-Pot & Spike Isolation Test',
      warranty: '1-Year Direct Replacement Warranty',
      compatibility: 'Powers all standard 24V booster pumps & solenoid valves',
    ),
    'A00005': const ScannedRoItem(
      code: 'A00005',
      name: 'Food-Grade Solenoid Valve (SV 24V DC)',
      type: QrItemType.product,
      mrp: 549,
      price: 249,
      description: 'Instant auto shut-off solenoid valve. 100% leak-proof copper coil prevents continuous wastewater run.',
      imageAsset: 'assets/images/whichpart.png',
      batchNumber: 'BATCH-2026-VALV-6601',
      hologramCode: 'ROP-SECURE-5519',
      qcStatus: 'Passed 100,000 Cycle Auto-Trigger Durability Test',
      warranty: '1-Year Replacement Warranty',
      compatibility: 'Universal 1/4" push-fit connector for all domestic ROs',
    ),

    // 2. Service & Replacement Kits (Prefix: KIT...)
    'KIT00001': const ScannedRoItem(
      code: 'KIT00001',
      name: 'Complete 1-Year RO Service Overhaul Kit',
      type: QrItemType.kit,
      mrp: 2999,
      price: 1399,
      description: 'All-inclusive annual maintenance kit. Contains all primary pre-filters, carbon inline blocks, and connectors.',
      imageAsset: 'assets/images/standard-kit-desk.png',
      batchNumber: 'BATCH-2026-KIT-8801',
      hologramCode: 'ROP-SECURE-KIT-01',
      qcStatus: 'Full Bundle Multi-Stage Flow Tested',
      warranty: '1-Year Comprehensive Replacement Guarantee',
      compatibility: 'Kent, Aquaguard, Pureit, Livpure, ZeroB, Eureka Forbes',
      bundledItems: [
        '1x 5-Micron Spun Pre-Filter Cartridge (High-Density Polypropylene)',
        '1x Sediment Filter Cartridge (Food-Grade Housing)',
        '1x Pre-Carbon Block (1100+ IV Activated Coconut Shell)',
        '1x Post-Carbon Inline Polisher (Odor Eliminator)',
        '5 Meters Food-Grade 1/4" RO Water Tube',
        '1x Teflon Sealing Tape & 4x Push-Fit Quick Elbows',
      ],
    ),
    'KIT00002': const ScannedRoItem(
      code: 'KIT00002',
      name: 'Membrane & Booster Performance Tuning Kit',
      type: QrItemType.kit,
      mrp: 3899,
      price: 1899,
      description: 'High-recovery membrane kit designed for high TDS source water (up to 2500 ppm).',
      imageAsset: 'assets/images/advance-kit-desk.png',
      batchNumber: 'BATCH-2026-KIT-8802',
      hologramCode: 'ROP-SECURE-KIT-02',
      qcStatus: 'TDS Rejection & Flow Calibration Certified',
      warranty: '1-Year Replacement Warranty on Membrane & Parts',
      compatibility: 'All 75 / 80 / 100 GPD Domestic Water Purifiers',
      bundledItems: [
        '1x Aquatech 75 GPD RO Membrane (0.0001 Micron)',
        '1x FR 450 Flow Restrictor Valve',
        '1x Non-Return Check Valve',
        '2x Heavy-Duty Membrane Housing Elbows',
      ],
    ),
    'KIT00003': const ScannedRoItem(
      code: 'KIT00003',
      name: 'Pre-Filter Housing Bowl + 2x Spun Filters Kit',
      type: QrItemType.kit,
      mrp: 1199,
      price: 499,
      description: 'External transparent heavy-duty bowl with brass threads. Protects internal RO pumps from tap mud & sand.',
      imageAsset: 'assets/images/spun-combo-4pcs.jpg',
      batchNumber: 'BATCH-2026-KIT-8803',
      hologramCode: 'ROP-SECURE-KIT-03',
      qcStatus: 'Passed 300 PSI Hydrostatic Pressure Burst Test',
      warranty: '1-Year Housing Crack Replacement Warranty',
      compatibility: 'Universal wall mount for all domestic tap water inlets',
      bundledItems: [
        '1x 10" Heavy-Duty Pre-Filter Housing Bowl (Food Grade)',
        '2x 5-Micron Spun Polypropylene Filter Cartridges',
        '1x Heavy-Duty Housing Spanner Wrench',
        '1x Rust-Proof Stainless Steel Wall Mounting Bracket',
        '2x 1/4" Brass Thread to Push-Fit Connectors',
      ],
    ),
  };

  /// Auto-detects item type by prefix and returns item details
  static ScannedRoItem? lookup(String rawCode) {
    final cleanCode = rawCode.trim().toUpperCase();
    if (cleanCode.isEmpty) return null;

    // Direct catalog lookup
    if (_catalog.containsKey(cleanCode)) {
      return _catalog[cleanCode];
    }

    // Dynamic prefix auto-detection
    if (cleanCode.startsWith('KIT')) {
      // Auto-detected as a Service/Filter Kit
      return ScannedRoItem(
        code: cleanCode,
        name: 'RO Service & Maintenance Kit ($cleanCode)',
        type: QrItemType.kit,
        mrp: 2499,
        price: 1199,
        description: 'Certified factory-assembled RO maintenance kit. Pre-tested for seamless compatibility.',
        imageAsset: 'assets/images/standard-kit-desk.png',
        batchNumber: 'BATCH-2026-DYN-${cleanCode.hashCode.abs() % 9000 + 1000}',
        hologramCode: 'ROP-SECURE-KT-${cleanCode.hashCode.abs() % 900 + 100}',
        qcStatus: 'Passed Multistage Assembly Leak & Flow Test',
        warranty: '1-Year Factory Replacement Guarantee',
        compatibility: 'Universal Domestic Water Purifiers (Kent, Aquaguard, Pureit, etc.)',
        bundledItems: const [
          'Pre-Filter & Inline Sediment Cartridges',
          'Activated Carbon Odor Neutralizer',
          'Food-Grade Connectors & Sealing Tape',
        ],
      );
    } else if (cleanCode.startsWith('A') || cleanCode.startsWith('PRD')) {
      // Auto-detected as an Individual Spare Part
      return ScannedRoItem(
        code: cleanCode,
        name: 'Genuine RO Spare Part ($cleanCode)',
        type: QrItemType.product,
        mrp: 1499,
        price: 699,
        description: '100% Original factory-direct certified domestic RO spare component.',
        imageAsset: 'assets/images/whichpart.png',
        batchNumber: 'BATCH-2026-DYN-${cleanCode.hashCode.abs() % 9000 + 1000}',
        hologramCode: 'ROP-SECURE-PR-${cleanCode.hashCode.abs() % 900 + 100}',
        qcStatus: 'Passed 150 PSI Standard Factory QC Inspection',
        warranty: '1-Year Direct Replacement Warranty',
        compatibility: 'Fits all domestic water purifier models',
      );
    }

    // Unrecognized format
    return null;
  }

  /// Preset test codes for rapid offline / emulator / physical testing
  static List<ScannedRoItem> get testPresets => _catalog.values.toList();
}
