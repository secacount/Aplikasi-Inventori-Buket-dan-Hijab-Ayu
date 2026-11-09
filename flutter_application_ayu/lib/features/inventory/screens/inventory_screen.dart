import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _categoryLabels = <String, String>{
  'hijab': 'Hijab',
  'flower': 'Bunga',
  'tool': 'Perkakas',
  'packaging': 'Bahan & kemasan',
  'finished_product': 'Produk jadi',
};

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final _client = Supabase.instance.client;
  final _searchController = TextEditingController();
  final _currency = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );
  final _quantityFormat = NumberFormat.decimalPattern('id_ID');

  List<Map<String, dynamic>> _businesses = [];
  List<Map<String, dynamic>> _units = [];
  List<Map<String, dynamic>> _items = [];
  String? _businessId;
  String? _unitFilterId;
  String _categoryFilter = 'all';
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({String? preferredBusinessId}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final businessRows = await _client
          .from('businesses')
          .select('id,name')
          .order('created_at');
      final businesses = List<Map<String, dynamic>>.from(businessRows);
      if (businesses.isEmpty) {
        if (!mounted) return;
        setState(() {
          _businesses = [];
          _units = [];
          _items = [];
          _businessId = null;
        });
        return;
      }

      final requestedId = preferredBusinessId ?? _businessId;
      final selectedBusinessId =
          businesses.any((row) => row['id'] == requestedId)
          ? requestedId!
          : businesses.first['id'] as String;
      final unitRows = await _client
          .from('business_units')
          .select('id,name,slug')
          .eq('business_id', selectedBusinessId)
          .order('name');
      final itemRows = await _client
          .from('inventory_items')
          .select('*,business_units(name)')
          .eq('business_id', selectedBusinessId)
          .eq('is_active', true)
          .order('updated_at', ascending: false);

      if (!mounted) return;
      final units = List<Map<String, dynamic>>.from(unitRows);
      setState(() {
        _businesses = businesses;
        _businessId = selectedBusinessId;
        _units = units;
        _items = List<Map<String, dynamic>>.from(itemRows);
        if (!units.any((unit) => unit['id'] == _unitFilterId)) {
          _unitFilterId = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _visibleItems {
    final search = _searchController.text.trim().toLowerCase();
    return _items.where((item) {
      final categoryMatches =
          _categoryFilter == 'all' || item['category'] == _categoryFilter;
      final unitMatches =
          _unitFilterId == null || item['business_unit_id'] == _unitFilterId;
      final searchMatches =
          search.isEmpty ||
          [item['name'], item['variant'], item['color'], item['sku']]
              .whereType<String>()
              .any((value) => value.toLowerCase().contains(search));
      return categoryMatches && unitMatches && searchMatches;
    }).toList();
  }

  Future<void> _openItemForm({Map<String, dynamic>? item}) async {
    if (_units.isEmpty) {
      _showMessage('Workspace belum memiliki unit bisnis.');
      return;
    }
    final value = await showDialog<_InventoryFormValue>(
      context: context,
      builder: (context) => _InventoryFormDialog(units: _units, item: item),
    );
    if (value == null || _businessId == null) return;

    setState(() => _isSaving = true);
    String? newImagePath;
    var newImageLinked = false;
    var itemCreated = false;
    try {
      if (item == null) {
        final createdData = await _client.rpc(
          'create_inventory_item',
          params: {
            'p_business_id': _businessId,
            'p_business_unit_id': value.businessUnitId,
            'p_category': value.category,
            'p_name': value.name,
            'p_variant': value.variant,
            'p_color': value.color,
            'p_sku': value.sku,
            'p_unit': value.unit,
            'p_initial_stock': value.initialStock,
            'p_min_stock': value.minStock,
            'p_purchase_price': value.purchasePrice,
            'p_stem_price': value.stemPrice,
            'p_selling_price': value.sellingPrice,
            'p_description': value.description,
          },
        ) as Map<String, dynamic>;
        itemCreated = true;
        final createdItemId = createdData['id'] as String;
        if (value.compressedImage != null) {
          final image = await _uploadImage(
            _businessId!,
            value.compressedImage!,
          );
          newImagePath = image['image_path'];
          await _client
              .from('inventory_items')
              .update(image)
              .eq('id', createdItemId)
              .eq('business_id', _businessId!);
          newImageLinked = true;
        }
        _showMessage('Barang berhasil ditambahkan.');
      } else {
        final oldImagePath = item['image_path'] as String?;
        final imageUpdate = <String, dynamic>{};
        if (value.compressedImage != null) {
          imageUpdate.addAll(
            await _uploadImage(_businessId!, value.compressedImage!),
          );
          newImagePath = imageUpdate['image_path'] as String?;
        } else if (value.removeExistingImage) {
          imageUpdate['image_path'] = null;
          imageUpdate['image_url'] = null;
        }

        await _client
            .from('inventory_items')
            .update({
              'business_unit_id': value.businessUnitId,
              'category': value.category,
              'name': value.name,
              'variant': value.variant,
              'color': value.color,
              'sku': value.sku,
              'unit': value.unit,
              'min_stock': value.minStock,
              'purchase_price': value.purchasePrice,
              'stem_price': value.stemPrice,
              'selling_price': value.sellingPrice,
              'description': value.description,
              ...imageUpdate,
            })
            .eq('id', item['id'])
            .eq('business_id', _businessId!);
        newImageLinked = true;
        if (oldImagePath != null &&
            (newImagePath != null || value.removeExistingImage) &&
            oldImagePath != newImagePath) {
          await _deleteImage(oldImagePath);
        }
        _showMessage('Barang berhasil diperbarui.');
      }
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      if (newImagePath != null && !newImageLinked) {
        await _deleteImage(newImagePath);
      }
      _showMessage(
        itemCreated
            ? 'Barang tersimpan, tetapi foto gagal diproses: $error'
            : 'Gagal menyimpan barang: $error',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<Map<String, String>> _uploadImage(
    String businessId,
    Uint8List bytes,
  ) async {
    final random = math.Random.secure();
    final filename = List.generate(
      16,
      (index) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '$businessId/$filename.jpg';
    final bucket = _client.storage.from('inventory-images');
    await bucket.uploadBinary(
      path,
      bytes,
      fileOptions: const FileOptions(
        contentType: 'image/jpeg',
        upsert: false,
        cacheControl: '3600',
      ),
    );
    return {'image_path': path, 'image_url': bucket.getPublicUrl(path)};
  }

  Future<void> _deleteImage(String path) async {
    try {
      await _client.storage.from('inventory-images').remove([path]);
    } catch (_) {
      // Keep the item update successful if an old Storage object cannot be removed.
    }
  }

  Future<void> _recordMovement(Map<String, dynamic> item, String type) async {
    final quantityController = TextEditingController();
    final noteController = TextEditingController();
    final quantity = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(switch (type) {
          'IN' => 'Stok masuk',
          'OUT' => 'Stok keluar',
          _ => 'Atur saldo akhir',
        }),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Saldo saat ini: ${_quantityFormat.format(item['stock_qty'])} ${item['unit']}',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: quantityController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: type == 'ADJUSTMENT'
                    ? 'Saldo akhir (boleh 0)'
                    : 'Jumlah',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: 'Catatan (opsional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(
                quantityController.text.trim().replaceAll(',', '.'),
              );
              if (parsed == null ||
                  parsed < 0 ||
                  (type != 'ADJUSTMENT' && parsed == 0)) {
                return;
              }
              Navigator.pop(context, parsed);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final note = noteController.text.trim();
    quantityController.dispose();
    noteController.dispose();
    if (quantity == null) return;

    setState(() => _isSaving = true);
    try {
      await _client.rpc(
        'register_stock_movement',
        params: {
          'p_item_id': item['id'],
          'p_movement_type': type,
          'p_quantity': quantity,
          'p_note': note.isEmpty ? null : note,
        },
      );
      _showMessage(
        type == 'ADJUSTMENT'
            ? 'Saldo stok diperbarui.'
            : 'Perubahan stok dicatat.',
      );
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      _showMessage('Gagal mencatat stok: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _archiveItem(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Arsipkan barang?'),
        content: Text('${item['name']} akan disembunyikan dari daftar aktif.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Arsipkan'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _isSaving = true);
    try {
      await _client.rpc('archive_item', params: {'p_item_id': item['id']});
      _showMessage('Barang berhasil diarsipkan.');
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      _showMessage('Gagal mengarsipkan barang: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _visibleItems;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventaris'),
        actions: [
          IconButton(
            onPressed: () => context.push('/history'),
            tooltip: 'Riwayat stok',
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            onPressed: _isLoading ? null : () => _load(),
            tooltip: 'Muat ulang',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: _businessId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _isSaving ? null : () => _openItemForm(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Barang'),
            ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _InventoryError(message: _error!, onRetry: _load)
          : _businesses.isEmpty
          ? const _InventoryEmpty(
              icon: Icons.business_outlined,
              message: 'Akun ini belum menjadi anggota workspace bisnis.',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    children: [
                      if (_businesses.length > 1)
                        DropdownButtonFormField<String>(
                          initialValue: _businessId,
                          decoration: const InputDecoration(
                            labelText: 'Bisnis',
                          ),
                          items: _businesses
                              .map(
                                (business) => DropdownMenuItem(
                                  value: business['id'] as String,
                                  child: Text(business['name'] as String),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              _load(preferredBusinessId: value);
                            }
                          },
                        ),
                      TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: 'Cari nama, warna, varian, atau SKU',
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                  tooltip: 'Hapus pencarian',
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _categoryFilter,
                              decoration: const InputDecoration(
                                labelText: 'Kategori',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 'all',
                                  child: Text('Semua'),
                                ),
                                ..._categoryLabels.entries.map(
                                  (entry) => DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                                ),
                              ],
                              onChanged: (value) => setState(
                                () => _categoryFilter = value ?? 'all',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              initialValue: _unitFilterId,
                              decoration: const InputDecoration(
                                labelText: 'Unit',
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('Semua unit'),
                                ),
                                ..._units.map(
                                  (unit) => DropdownMenuItem<String?>(
                                    value: unit['id'] as String,
                                    child: Text(unit['name'] as String),
                                  ),
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _unitFilterId = value),
                            ),
                          ),
                        ],
                      ),
                      if (_isSaving)
                        const LinearProgressIndicator(minHeight: 2),
                    ],
                  ),
                ),
                Expanded(
                  child: items.isEmpty
                      ? const _InventoryEmpty(
                          icon: Icons.inventory_2_outlined,
                          message: 'Belum ada barang yang cocok dengan filter.',
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                            itemCount: items.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) =>
                                _buildItemRow(items[index]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildItemRow(Map<String, dynamic> item) {
    final stock = (item['stock_qty'] as num?)?.toDouble() ?? 0;
    final minimum = (item['min_stock'] as num?)?.toDouble() ?? 0;
    final purchasePrice = (item['purchase_price'] as num?)?.toDouble() ?? 0;
    final stemPrice = (item['stem_price'] as num?)?.toDouble() ?? 0;
    final lowStock = stock <= minimum;
    final unitName =
        (item['business_units'] as Map<String, dynamic>?)?['name'] as String? ??
        'Unit';
    final category =
        _categoryLabels[item['category']] ??
        item['category'] as String? ??
        'Barang';
    final details = [
      item['variant'],
      item['color'],
      item['sku'] == null ? null : 'SKU ${item['sku']}',
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final imageUrl = item['image_url'] as String?;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      leading: imageUrl == null || imageUrl.isEmpty
          ? CircleAvatar(
              backgroundColor: lowStock
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: Icon(
                lowStock
                    ? Icons.priority_high_rounded
                    : Icons.inventory_2_outlined,
                color: lowStock ? Theme.of(context).colorScheme.error : null,
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholder: (context, url) => const SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                errorWidget: (context, url, error) => const SizedBox.square(
                  dimension: 48,
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
      title: Text(
        item['name'] as String? ?? 'Barang',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty)
            Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('$category · $unitName'),
          Text(
            'Stok ${_quantityFormat.format(stock)} ${item['unit']} · Minimum ${_quantityFormat.format(minimum)}',
            style: TextStyle(
              color: lowStock ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          if (purchasePrice > 0)
            Text('Modal ${_currency.format(purchasePrice)}'),
          if (item['category'] == 'flower' && stemPrice > 0)
            Text('Per tangkai ${_currency.format(stemPrice)}'),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        tooltip: 'Tindakan barang',
        onSelected: (action) {
          switch (action) {
            case 'edit':
              _openItemForm(item: item);
            case 'in':
              _recordMovement(item, 'IN');
            case 'out':
              _recordMovement(item, 'OUT');
            case 'adjust':
              _recordMovement(item, 'ADJUSTMENT');
            case 'archive':
              _archiveItem(item);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit detail')),
          PopupMenuItem(value: 'in', child: Text('Stok masuk')),
          PopupMenuItem(value: 'out', child: Text('Stok keluar')),
          PopupMenuItem(value: 'adjust', child: Text('Atur saldo akhir')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'archive', child: Text('Arsipkan')),
        ],
      ),
    );
  }
}

class _InventoryFormValue {
  const _InventoryFormValue({
    required this.businessUnitId,
    required this.category,
    required this.name,
    required this.variant,
    required this.color,
    required this.sku,
    required this.unit,
    required this.initialStock,
    required this.minStock,
    required this.purchasePrice,
    required this.stemPrice,
    required this.sellingPrice,
    required this.description,
    required this.compressedImage,
    required this.removeExistingImage,
  });

  final String businessUnitId;
  final String category;
  final String name;
  final String? variant;
  final String? color;
  final String? sku;
  final String unit;
  final double initialStock;
  final double minStock;
  final double purchasePrice;
  final double stemPrice;
  final double sellingPrice;
  final String? description;
  final Uint8List? compressedImage;
  final bool removeExistingImage;
}

class _InventoryFormDialog extends StatefulWidget {
  const _InventoryFormDialog({required this.units, this.item});

  final List<Map<String, dynamic>> units;
  final Map<String, dynamic>? item;

  @override
  State<_InventoryFormDialog> createState() => _InventoryFormDialogState();
}

class _InventoryFormDialogState extends State<_InventoryFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _imagePicker = ImagePicker();
  late final Map<String, TextEditingController> _controllers;
  late String _category;
  late String _businessUnitId;
  late final String? _existingImageUrl;
  Uint8List? _compressedImage;
  bool _removeExistingImage = false;
  bool _isCompressingImage = false;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _category = item?['category'] as String? ?? 'hijab';
    _existingImageUrl = item?['image_url'] as String?;
    _businessUnitId =
        item?['business_unit_id'] as String? ??
        widget.units.first['id'] as String;
    _controllers = {
      'name': TextEditingController(text: item?['name'] as String? ?? ''),
      'variant': TextEditingController(text: item?['variant'] as String? ?? ''),
      'color': TextEditingController(text: item?['color'] as String? ?? ''),
      'sku': TextEditingController(text: item?['sku'] as String? ?? ''),
      'unit': TextEditingController(text: item?['unit'] as String? ?? 'pcs'),
      'initial': TextEditingController(text: '0'),
      'minimum': TextEditingController(text: '${item?['min_stock'] ?? 0}'),
      'purchase': TextEditingController(
        text: '${item?['purchase_price'] ?? 0}',
      ),
      'stem': TextEditingController(text: '${item?['stem_price'] ?? 0}'),
      'selling': TextEditingController(text: '${item?['selling_price'] ?? 0}'),
      'description': TextEditingController(
        text: item?['description'] as String? ?? '',
      ),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  double _number(String key) =>
      double.tryParse(_controllers[key]!.text.trim().replaceAll(',', '.')) ?? 0;

  String? _nullable(String key) {
    final value = _controllers[key]!.text.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _pickAndCompressImage() async {
    try {
      final selected = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (selected == null) return;

      final extension = selected.name.split('.').last.toLowerCase();
      final mimeType = selected.mimeType?.toLowerCase();
      final allowedExtensions = {'jpg', 'jpeg', 'png', 'webp'};
      final allowedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
      if (!allowedExtensions.contains(extension) &&
          (mimeType == null || !allowedMimeTypes.contains(mimeType))) {
        _showImageMessage('Format foto harus JPG, PNG, atau WEBP.');
        return;
      }
      if (await selected.length() > 20 * 1024 * 1024) {
        _showImageMessage('Ukuran foto asli maksimal 20 MB.');
        return;
      }

      setState(() => _isCompressingImage = true);
      final originalBytes = await selected.readAsBytes();
      var compressed = await FlutterImageCompress.compressWithList(
        originalBytes,
        minWidth: 1280,
        minHeight: 1280,
        quality: 78,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (compressed.length > 1024 * 1024) {
        compressed = await FlutterImageCompress.compressWithList(
          originalBytes,
          minWidth: 1000,
          minHeight: 1000,
          quality: 62,
          format: CompressFormat.jpeg,
          keepExif: false,
        );
      }
      if (compressed.length > 2 * 1024 * 1024) {
        _showImageMessage(
          'Foto masih lebih besar dari batas 2 MB setelah kompresi.',
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _compressedImage = compressed;
        _removeExistingImage = false;
      });
      _showImageMessage(
        'Foto dikompres menjadi ${(compressed.length / 1024).round()} KB.',
      );
    } catch (error) {
      _showImageMessage('Foto tidak dapat diproses: $error');
    } finally {
      if (mounted) setState(() => _isCompressingImage = false);
    }
  }

  void _showImageMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      _InventoryFormValue(
        businessUnitId: _businessUnitId,
        category: _category,
        name: _controllers['name']!.text.trim(),
        variant: _nullable('variant'),
        color: _nullable('color'),
        sku: _nullable('sku'),
        unit: _controllers['unit']!.text.trim(),
        initialStock: _isEditing ? 0 : _number('initial'),
        minStock: _number('minimum'),
        purchasePrice: _number('purchase'),
        stemPrice: _number('stem'),
        sellingPrice: _number('selling'),
        description: _nullable('description'),
        compressedImage: _compressedImage,
        removeExistingImage: _removeExistingImage,
      ),
    );
  }

  Widget _textField(
    String key,
    String label, {
    bool numeric = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _controllers[key],
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (key == 'name' && text.isEmpty) return 'Nama barang wajib diisi.';
          if (numeric && text.isNotEmpty) {
            final parsed = double.tryParse(text.replaceAll(',', '.'));
            if (parsed == null || parsed < 0) {
              return 'Masukkan angka nol atau lebih.';
            }
          }
          return null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit barang' : 'Tambah barang'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Kategori'),
                  items: _categoryLabels.entries
                      .map(
                        (entry) => DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _category = value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _businessUnitId,
                  decoration: const InputDecoration(labelText: 'Unit bisnis'),
                  items: widget.units
                      .map(
                        (unit) => DropdownMenuItem(
                          value: unit['id'] as String,
                          child: Text(unit['name'] as String),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _businessUnitId = value);
                  },
                ),
                const SizedBox(height: 12),
                _textField('name', 'Nama / jenis barang'),
                _buildImagePicker(),
                _textField('variant', 'Model / varian'),
                _textField('color', 'Warna'),
                _textField('sku', 'SKU (opsional)'),
                _textField('unit', 'Satuan'),
                if (!_isEditing) _textField('initial', 'Saldo awal'),
                _textField('minimum', 'Stok minimum', numeric: true),
                _textField('purchase', 'Harga modal / beli', numeric: true),
                _textField('stem', 'Harga per tangkai (bunga)', numeric: true),
                _textField('selling', 'Harga jual (opsional)', numeric: true),
                _textField('description', 'Deskripsi', maxLines: 3),
                if (_category == 'flower')
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Harga modal berbeda dari harga per tangkai.'),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _isCompressingImage ? null : _save,
          child: const Text('Simpan'),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    final showExistingImage =
        _compressedImage == null &&
        !_removeExistingImage &&
        _existingImageUrl != null &&
        _existingImageUrl.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Foto barang', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 16 / 10,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: _compressedImage != null
                    ? Image.memory(_compressedImage!, fit: BoxFit.cover)
                    : showExistingImage
                    ? CachedNetworkImage(
                        imageUrl: _existingImageUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            const Center(child: CircularProgressIndicator()),
                        errorWidget: (context, url, error) => const Center(
                          child: Icon(Icons.broken_image_outlined, size: 40),
                        ),
                      )
                    : const Center(child: Icon(Icons.image_outlined, size: 40)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _isCompressingImage ? null : _pickAndCompressImage,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(
                  _compressedImage != null || showExistingImage
                      ? 'Ganti foto'
                      : 'Pilih foto',
                ),
              ),
              if (_compressedImage != null || showExistingImage)
                IconButton(
                  onPressed: _isCompressingImage
                      ? null
                      : () => setState(() {
                          _compressedImage = null;
                          _removeExistingImage = true;
                        }),
                  tooltip: 'Hapus foto',
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              if (_isCompressingImage)
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Text('JPG, PNG, WEBP · maks. 2 MB setelah kompresi'),
            ],
          ),
        ],
      ),
    );
  }
}

class _InventoryEmpty extends StatelessWidget {
  const _InventoryEmpty({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _InventoryError extends StatelessWidget {
  const _InventoryError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Coba lagi'),
          ),
        ],
      ),
    ),
  );
}
