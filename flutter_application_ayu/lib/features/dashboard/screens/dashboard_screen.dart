import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/providers/auth_controller.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _client = Supabase.instance.client;
  final _quantityFormat = NumberFormat.decimalPattern('id_ID');
  late Future<_DashboardSummary> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _loadSummary();
  }

  Future<_DashboardSummary> _loadSummary() async {
    final businessRows = await _client.from('businesses').select('id');
    final businesses = List<Map<String, dynamic>>.from(businessRows);
    if (businesses.isEmpty) return const _DashboardSummary.empty();

    final businessIds = businesses
        .map((business) => business['id'] as String)
        .toList();
    final itemRows = await _client
        .from('inventory_items')
        .select('category,stock_qty,min_stock')
        .inFilter('business_id', businessIds)
        .eq('is_active', true);
    final items = List<Map<String, dynamic>>.from(itemRows);
    var lowStockCount = 0;
    var hijabStock = 0.0;
    var flowerStock = 0.0;

    for (final item in items) {
      final stock = (item['stock_qty'] as num?)?.toDouble() ?? 0;
      final minimum = (item['min_stock'] as num?)?.toDouble() ?? 0;
      if (stock <= minimum) lowStockCount++;
      if (item['category'] == 'hijab') hijabStock += stock;
      if (item['category'] == 'flower') flowerStock += stock;
    }

    return _DashboardSummary(
      businessCount: businesses.length,
      itemCount: items.length,
      lowStockCount: lowStockCount,
      hijabStock: hijabStock,
      flowerStock: flowerStock,
    );
  }

  Future<void> _refresh() async {
    final nextSummary = _loadSummary();
    setState(() => _summaryFuture = nextSummary);
    await nextSummary;
  }

  @override
  Widget build(BuildContext context) {
    final user = _client.auth.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AYU Dashboard'),
        actions: [
          IconButton(
            onPressed: () => context.go('/members'),
            tooltip: 'Anggota bisnis',
            icon: const Icon(Icons.group_outlined),
          ),
          IconButton(
            onPressed: () => context.go('/history'),
            tooltip: 'Riwayat stok',
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            onPressed: () async => ref.read(authControllerProvider).signOut(),
            tooltip: 'Logout',
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: FutureBuilder<_DashboardSummary>(
        future: _summaryFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _DashboardError(
              message: snapshot.error.toString(),
              onRetry: _refresh,
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final summary = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Selamat datang',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  user?.email ?? 'Pengguna terautentikasi',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => context.go('/inventory'),
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('Buka inventaris'),
                ),
                const SizedBox(height: 20),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.5,
                  children: [
                    _StatCard(
                      label: 'Jenis barang',
                      value: '${summary.itemCount}',
                    ),
                    _StatCard(
                      label: 'Perlu restock',
                      value: '${summary.lowStockCount}',
                    ),
                    _StatCard(
                      label: 'Stok hijab',
                      value: _quantityFormat.format(summary.hijabStock),
                    ),
                    _StatCard(
                      label: 'Tangkai bunga',
                      value: _quantityFormat.format(summary.flowerStock),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  summary.businessCount == 0
                      ? 'Akun ini belum menjadi anggota workspace.'
                      : 'Ringkasan dari ${summary.businessCount} workspace yang dapat diakses.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DashboardSummary {
  const _DashboardSummary({
    required this.businessCount,
    required this.itemCount,
    required this.lowStockCount,
    required this.hijabStock,
    required this.flowerStock,
  });

  const _DashboardSummary.empty()
    : businessCount = 0,
      itemCount = 0,
      lowStockCount = 0,
      hijabStock = 0,
      flowerStock = 0;

  final int businessCount;
  final int itemCount;
  final int lowStockCount;
  final double hijabStock;
  final double flowerStock;
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Ringkasan inventaris tidak dapat dimuat.\n$message',
            textAlign: TextAlign.center,
          ),
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

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
    );
  }
}
