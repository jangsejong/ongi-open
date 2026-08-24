import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../apps/app_repository.dart';

/// 카테고리 안의 앱 목록 — 큰 아이콘·큰 글씨 행, 탭 한 번으로 실행.
/// 행 우측 '바꾸기' 버튼(또는 길게 누르기)으로 보호자용 편집
/// (음성 별칭 추가·칸 옮기기 — §8 ADR-12). 길게 누르기 단독은
/// 시니어·보호자가 발견하기 어려워 싱글 탭 경로를 병행한다(CB2).
class CategoryAppsScreen extends StatefulWidget {
  const CategoryAppsScreen({
    super.key,
    required this.category,
    required this.entries,
    required this.apps,
  });

  final LifeCategory category;
  final List<AppEntry> entries;
  final AppRepository apps;

  @override
  State<CategoryAppsScreen> createState() => _CategoryAppsScreenState();
}

class _CategoryAppsScreenState extends State<CategoryAppsScreen> {
  late final List<AppEntry> _entries = List.of(widget.entries);

  Future<void> _launch(AppEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    var ok = false;
    try {
      ok = await widget.apps.launch(entry.packageName);
    } catch (_) {}
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text('${entry.label} 앱을 열 수 없어요')),
      );
    }
  }

  Future<void> _edit(AppEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(entry.label,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            ListTile(
              leading: const Icon(Icons.record_voice_over, size: 32),
              title: Text('부르는 이름 추가',
                  style: Theme.of(context).textTheme.bodyLarge),
              subtitle: const Text('예: "큰딸 은행" — 말로 하기에서 이 이름으로 열려요'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addAlias(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline, size: 32),
              title:
                  Text('다른 칸으로 옮기기', style: Theme.of(context).textTheme.bodyLarge),
              onTap: () {
                Navigator.pop(sheetContext);
                _moveCategory(entry);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _addAlias(AppEntry entry) async {
    final controller = TextEditingController();
    final alias = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${entry.label} 부르는 이름'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 우리은행 말고 "은행앱"'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (alias == null || alias.trim().isEmpty) return;
    await widget.apps.addAlias(entry.packageName, alias);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${alias.trim()}"(으)로도 부를 수 있어요')),
      );
    }
  }

  Future<void> _moveCategory(AppEntry entry) async {
    final target = await showModalBottomSheet<LifeCategory>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final category in LifeCategory.values)
              ListTile(
                title: Text(category.label,
                    style: Theme.of(context).textTheme.bodyLarge),
                trailing: category == entry.category
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, category),
              ),
          ],
        ),
      ),
    );
    if (target == null || target == entry.category) return;
    await widget.apps.setCategory(entry.packageName, target, source: 'user');
    if (!mounted) return; // DB write 중 뒤로가기 — dispose 후 setState 방지.
    setState(() {
      _entries.removeWhere((e) => e.packageName == entry.packageName);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.label} → ${target.label} 칸으로 옮겼어요')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.label)),
      // edge-to-edge(Android 15+)에서 마지막 행이 내비 바 뒤에 깔리지 않게.
      body: SafeArea(
        top: false,
        child: _entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '이 칸에는 아직 앱이 없어요.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return InkWell(
                  onTap: () => _launch(entry),
                  onLongPress: () => _edit(entry),
                  child: Padding(
                    // 터치 타깃 최소 60dp(§6) — 아이콘 56 + 상하 여백으로 초과 확보.
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    child: Row(
                      children: [
                        FutureBuilder(
                          future: widget.apps.icon(entry.packageName),
                          builder: (context, snapshot) {
                            final bytes = snapshot.data;
                            if (bytes == null) {
                              return const Icon(Icons.android, size: 56);
                            }
                            return Image.memory(bytes,
                                width: 56, height: 56, gaplessPlayback: true);
                          },
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Text(
                            entry.label,
                            style: Theme.of(context).textTheme.bodyLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // '>' 화살표는 클릭 요소로 인지되지 않는다(toss①) —
                        // 편집 진입은 명시적 버튼으로(길게 누르기는 보조 경로).
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            textStyle:
                                Theme.of(context).textTheme.titleMedium,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          onPressed: () => _edit(entry),
                          child: const Text('바꾸기'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      ),
    );
  }
}
