import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:sealpost/data/session/session_storage.dart';

import '../data/session/account_session_manager.dart';
import '../screens/login/view/login_view.dart';

class AccountSwitchSheet {
  static Future<void> show(BuildContext context) async {
    final manager = Get.find<AccountSessionManager>();
    await manager.refresh();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1B1D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            child: Obx(() {
              final accounts = manager.accounts;
              final activeId = manager.activeAccountId.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Switch account',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (accounts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No accounts found',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  else
                    ...accounts.map(
                      (a) => _AccountTile(
                        account: a,
                        isActive: a.accountId == activeId,
                        onTap: () async {
                          if (a.accountId == activeId) {
                            Navigator.of(ctx).pop();
                            return;
                          }
                          // Close bottom sheet before global route/state changes.
                          Navigator.of(ctx).pop();
                          WidgetsBinding.instance.addPostFrameCallback((_) async {
                            final ok = await manager.switchToAccount(a.accountId);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Unable to switch account'),
                                ),
                              );
                            }
                          });
                        },
                      ),
                    ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await Get.to<void>(
                          () => const LoginScreen(addAccountMode: true),
                        );
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Add new account'),
                    ),
                  ),
                ],
              );
            }),
          ),
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isActive,
    required this.onTap,
  });

  final SessionAccountIdentity account;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = account.name.trim().isEmpty ? account.email : account.name;
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF22314A) : const Color(0xFF232427),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive ? const Color(0xFF3B82F6) : Colors.white10,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF2563EB),
          child: Text(initial, style: const TextStyle(color: Colors.white)),
        ),
        title: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          account.email,
          style: const TextStyle(color: Colors.white70),
        ),
        trailing: isActive
            ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
            : const Icon(Icons.chevron_right, color: Colors.white54),
      ),
    );
  }
}
