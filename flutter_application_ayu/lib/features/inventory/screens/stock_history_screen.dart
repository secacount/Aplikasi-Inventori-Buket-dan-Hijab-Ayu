import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _movementLabels = <String, String>{
  'OPENING': 'Saldo awal',
  'IN': 'Stok masuk',
  'OUT': 'Stok keluar',
  'ADJUSTMENT': 'Saldo akhir',
};

class StockHistoryScreen extends StatefulWidget {
  const StockHistoryScreen({super.key});

  @override
  State<StockHistoryScreen> createState() => _StockHistoryScreenState();
}

class _StockHistoryScreenState extends State<StockHistoryScreen> {
  final _client = Supabase.instance.client;
  final _quantityFormat = NumberFormat.decimalPattern('id_ID');
  final _dateFormat = DateFormat('d MMM yyyy, HH:mm', 'id_ID');

  List<Map<String, dynamic>> _movements = [];
  Map<String, String> _businessNames = {};
  String _typeFilter = 'all';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final businessRows = await _client.from('businesses').select('id,name');
      final businesses = List<Map<String, dynamic>>.from(businessRows);
      if (businesses.isEmpty) {
        if (!mounted) return;
        setState(() {
          _movements = [];
          _businessNames = {};
        });
        return;
      }

      final businessIds = businesses
          .map((business) => business['id'] as String)
          .toList();
      final businessNames = {
        for (final business in businesses)
          business['id'] as String: business['name'] as String,
      };
      final movementRows = await _client
          .from('stock_movements')
          .select(
            'id,business_id,item_id,actor_user_id,movement_type,quantity,stock_before,stock_after,note,created_at,inventory_items!stock_movements_business_item_workspace_fkey(name,category,color,unit)',
          )
          .inFilter('business_id', businessIds)
          .order('created_at', ascending: false)
          .limit(250);

      if (!mounted) return;
      setState(() {
        _businessNames = businessNames;
        _movements = List<Map<String, dynamic>>.from(movementRows);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _visibleMovements => _typeFilter == 'all'
      ? _movements
      : _movements
            .where((movement) => movement['movement_type'] == _typeFilter)
            .toList();

  @override
  Widget build(BuildContext context) {
    final movements = _visibleMovements;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Riwayat stok'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _load,
            tooltip: 'Muat ulang',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _HistoryError(message: _error!, onRetry: _load)
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _typeFilter,
                    decoration: const InputDecoration(
                      labelText: 'Jenis perubahan',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('Semua perubahan'),
                      ),
                      ..._movementLabels.entries.map(
                        (entry) => DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _typeFilter = value ?? 'all'),
                  ),
                ),
                Expanded(
                  child: movements.isEmpty
                      ? const _HistoryEmpty()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: movements.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) =>
                                _buildMovement(movements[index]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildMovement(Map<String, dynamic> movement) {
    final type = movement['movement_type'] as String? ?? '';
    final itemValue = movement['inventory_items'];
    final item = itemValue is Map<String, dynamic>
        ? itemValue
        : <String, dynamic>{};
    final itemName = item['name'] as String? ?? 'Barang';
    final category = item['category'] as String? ?? '';
    final color = item['color'] as String?;
    final unit = item['unit'] as String? ?? 'pcs';
    final label = _movementLabels[type] ?? type;
    final quantity = (movement['quantity'] as num?)?.toDouble() ?? 0;
    final stockBefore = (movement['stock_before'] as num?)?.toDouble() ?? 0;
    final stockAfter = (movement['stock_after'] as num?)?.toDouble() ?? 0;
    final createdAt = DateTime.tryParse(movement['created_at'] as String? ?? '')
        ?.toLocal();
    final actorId = movement['actor_user_id'] as String?;
    final currentUserId = _client.auth.currentUser?.id;
    final actor = actorId == currentUserId
        ? 'Oleh Anda'
        : actorId == null
        ? 'Akun lama'
        : 'Akun ${actorId.substring(0, actorId.length > 8 ? 8 : actorId.length)}';
    final details = [
      category,
      color,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final businessName = _businessNames[movement['business_id']] ?? 'Workspace';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      leading: CircleAvatar(child: Icon(_movementIcon(type))),
      title: Text(itemName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty) Text(details),
          Text('$label · $businessName'),
          Text(
            '${_quantityFormat.format(stockBefore)} → ${_quantityFormat.format(stockAfter)} $unit',
          ),
          if (movement['note'] is String &&
              (movement['note'] as String).isNotEmpty)
            Text(
              movement['note'] as String,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            '${createdAt == null ? 'Waktu tidak tersedia' : _dateFormat.format(createdAt)} · $actor',
          ),
        ],
      ),
      trailing: Text(
        type == 'ADJUSTMENT'
            ? _quantityFormat.format(quantity)
            : '${type == 'OUT' ? '−' : '+'}${_quantityFormat.format(quantity)}',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      isThreeLine: true,
    );
  }

  IconData _movementIcon(String type) => switch (type) {
    'OPENING' => Icons.flag_outlined,
    'IN' => Icons.south_west_rounded,
    'OUT' => Icons.north_east_rounded,
    'ADJUSTMENT' => Icons.tune_rounded,
    _ => Icons.history_rounded,
  };
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_rounded, size: 38),
          SizedBox(height: 12),
          Text('Belum ada riwayat stok.'),
        ],
      ),
    ),
  );
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.message, required this.onRetry});

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
