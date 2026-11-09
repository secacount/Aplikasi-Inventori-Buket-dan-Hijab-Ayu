import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BusinessMembersScreen extends StatefulWidget {
  const BusinessMembersScreen({super.key});

  @override
  State<BusinessMembersScreen> createState() => _BusinessMembersScreenState();
}

class _BusinessMembersScreenState extends State<BusinessMembersScreen> {
  final _client = Supabase.instance.client;
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<Map<String, dynamic>> _businesses = [];
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _invitations = [];
  String? _businessId;
  bool _isOwner = false;
  bool _canBootstrap = false;
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailController.dispose();
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
      final userEmail = _client.auth.currentUser?.email?.trim().toLowerCase();
      var invitations = <Map<String, dynamic>>[];

      if (userEmail != null && userEmail.isNotEmpty) {
        final invitationRows = await _client
            .from('business_members')
            .select('id,business_id,invited_email,role,status')
            .eq('status', 'INVITED')
            .eq('invited_email', userEmail);
        invitations = List<Map<String, dynamic>>.from(invitationRows);
      }

      if (businesses.isEmpty) {
        final canBootstrap = await _client.rpc('can_bootstrap_ayu_owner') as bool;
        if (!mounted) return;
        setState(() {
          _businesses = businesses;
          _businessId = null;
          _members = [];
          _invitations = invitations;
          _isOwner = false;
          _canBootstrap = canBootstrap;
        });
        return;
      }

      final requestedId = preferredBusinessId ?? _businessId;
      final selectedBusinessId = businesses.any((business) => business['id'] == requestedId)
          ? requestedId!
          : businesses.first['id'] as String;
      final isOwner = await _client.rpc(
        'is_business_owner',
        params: {'p_business_id': selectedBusinessId},
      ) as bool;
      final memberRows = await _client
          .from('business_members')
          .select('id,user_id,invited_email,role,status,created_at')
          .eq('business_id', selectedBusinessId)
          .order('created_at');

      if (!mounted) return;
      setState(() {
        _businesses = businesses;
        _businessId = selectedBusinessId;
        _members = List<Map<String, dynamic>>.from(memberRows);
        _invitations = invitations;
        _isOwner = isOwner;
        _canBootstrap = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendInvitation() async {
    if (!(_formKey.currentState?.validate() ?? false) || _businessId == null) return;
    setState(() => _isSubmitting = true);
    try {
      await _client.rpc(
        'create_business_invitation',
        params: {
          'p_business_id': _businessId,
          'p_email': _emailController.text.trim(),
        },
      );
      _emailController.clear();
      _showMessage('Undangan Staff disiapkan. Minta anggota masuk dengan email tersebut.');
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _acceptInvitations() async {
    setState(() => _isSubmitting = true);
    try {
      final accepted = await _client.rpc('accept_business_invitations') as int;
      _showMessage(accepted == 1 ? 'Undangan diterima.' : '$accepted undangan diterima.');
      await _load();
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _bootstrapOwner() async {
    setState(() => _isSubmitting = true);
    try {
      await _client.rpc('bootstrap_ayu_owner');
      _showMessage('Workspace AYU berhasil diaktifkan sebagai Owner.');
      await _load();
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _changeRole(Map<String, dynamic> member, String role) async {
    try {
      await _client.rpc(
        'set_business_member_role',
        params: {'p_member_id': member['id'], 'p_role': role},
      );
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus anggota?'),
        content: const Text('Anggota ini akan kehilangan akses ke workspace.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _client.rpc('remove_business_member', params: {'p_member_id': member['id']});
      await _load(preferredBusinessId: _businessId);
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _memberLabel(Map<String, dynamic> member) {
    final email = member['invited_email'] as String?;
    if (email != null && email.isNotEmpty) return email;
    final userId = member['user_id'] as String? ?? 'Akun';
    return 'Akun ${userId.length > 8 ? userId.substring(0, 8) : userId}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anggota bisnis'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : () => _load(),
            tooltip: 'Muat ulang',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (_invitations.isNotEmpty) ...[
                        _InvitationNotice(
                          count: _invitations.length,
                          isSubmitting: _isSubmitting,
                          onAccept: _acceptInvitations,
                        ),
                        const SizedBox(height: 20),
                      ],
                      if (_businesses.isEmpty && _invitations.isEmpty)
                        Column(
                          children: [
                            const _EmptyState(
                              message: 'Akun ini belum menjadi anggota workspace bisnis.',
                            ),
                            if (_canBootstrap)
                              FilledButton.icon(
                                onPressed: _isSubmitting ? null : _bootstrapOwner,
                                icon: const Icon(Icons.business_rounded),
                                label: const Text('Aktifkan workspace Owner'),
                              ),
                          ],
                        )
                      else if (_businesses.isNotEmpty) ...[
                        if (_businesses.length > 1) ...[
                          DropdownButtonFormField<String>(
                            initialValue: _businessId,
                            decoration: const InputDecoration(labelText: 'Workspace'),
                            items: _businesses
                                .map((business) => DropdownMenuItem(
                                      value: business['id'] as String,
                                      child: Text(business['name'] as String),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value != null) _load(preferredBusinessId: value);
                            },
                          ),
                          const SizedBox(height: 20),
                        ] else
                          Text(
                            _businesses.first['name'] as String,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        const SizedBox(height: 12),
                        if (_isOwner) _buildInviteForm(),
                        const SizedBox(height: 12),
                        if (_members.isEmpty)
                          const _EmptyState(message: 'Belum ada anggota yang tercatat.')
                        else
                          ..._members.map(_buildMemberTile),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildInviteForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Undang Staff', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email akun'),
            validator: (value) {
              final email = value?.trim() ?? '';
              if (!email.contains('@') || email.endsWith('@')) return 'Masukkan email yang valid.';
              return null;
            },
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _isSubmitting ? null : _sendInvitation,
              icon: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Buat undangan'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberTile(Map<String, dynamic> member) {
    final role = member['role'] as String? ?? 'STAFF';
    final status = member['status'] as String? ?? 'ACTIVE';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(role == 'OWNER' ? Icons.shield_outlined : Icons.person_outline_rounded),
      ),
      title: Text(_memberLabel(member)),
      subtitle: Text(status == 'INVITED' ? 'Undangan tertunda' : role),
      trailing: _isOwner
          ? PopupMenuButton<String>(
              tooltip: 'Kelola anggota',
              onSelected: (value) {
                if (value == 'REMOVE') {
                  _removeMember(member);
                } else {
                  _changeRole(member, value);
                }
              },
              itemBuilder: (context) => [
                if (status == 'ACTIVE') ...const [
                  PopupMenuItem(value: 'OWNER', child: Text('Jadikan Owner')),
                  PopupMenuItem(value: 'STAFF', child: Text('Jadikan Staff')),
                ],
                const PopupMenuItem(value: 'REMOVE', child: Text('Hapus anggota')),
              ],
              icon: const Icon(Icons.more_vert_rounded),
            )
          : Text(role),
    );
  }
}

class _InvitationNotice extends StatelessWidget {
  const _InvitationNotice({
    required this.count,
    required this.isSubmitting,
    required this.onAccept,
  });

  final int count;
  final bool isSubmitting;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$count undangan workspace menunggu jawaban.'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: isSubmitting ? null : onAccept,
              child: const Text('Terima undangan'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(child: Text(message, textAlign: TextAlign.center)),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

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