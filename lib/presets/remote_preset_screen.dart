import 'package:material_ui/material_ui.dart';

import 'preset.dart';
import 'preset_api.dart';

class RemotePresetScreen extends StatefulWidget {
  const RemotePresetScreen({super.key, required this.api, required this.local});

  final PresetApi api;
  final List<Preset> local;

  @override
  State<RemotePresetScreen> createState() => _RemotePresetScreenState();
}

class _RemotePresetScreenState extends State<RemotePresetScreen> {
  List<RemotePreset> _items = [];
  String _query = '';
  String? _error;
  bool _mine = false;
  bool _busy = true;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.api.list(
        _query,
        _mine,
        more ? _items.length : 0,
      );
      if (mounted) {
        setState(() {
          _items = more ? [..._items, ...page] : page;
          _hasMore = page.length == 30;
        });
      }
    } on Exception {
      if (mounted) setState(() => _error = '프리셋 목록을 불러오지 못했어요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish({RemotePreset? existing}) async {
    var preset = existing?.preset;
    var isPublic = existing?.isPublic ?? false;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, rebuild) {
          return AlertDialog(
            title: Text(existing == null ? '프리셋 올리기' : '공유 프리셋 수정'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Preset>(
                  initialValue: preset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '프리셋'),
                  items: [
                    if (existing != null)
                      DropdownMenuItem(
                        value: existing.preset,
                        child: Text(existing.preset.name),
                      ),
                    for (final item in widget.local)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: (value) => rebuild(() => preset = value),
                ),
                SwitchListTile(
                  title: const Text('다른 사용자에게 공개'),
                  value: isPublic,
                  onChanged: (value) => rebuild(() => isPublic = value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: preset == null
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || save != true || preset == null) return;
    await _change(() => widget.api.save(preset!, isPublic, id: existing?.id));
  }

  Future<void> _change(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) await _load();
    } on Exception {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('서버에 변경 사항을 저장하지 못했어요.')));
      }
    }
  }

  Future<void> _delete(RemotePreset item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${item.preset.name} 삭제'),
        content: const Text('서버에서 이 프리셋을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _change(() => widget.api.delete(item.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('프리셋 공유'),
      actions: [
        IconButton(
          tooltip: '프리셋 올리기',
          onPressed: _busy || widget.local.isEmpty ? null : _publish,
          icon: const Icon(Icons.upload),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            enabled: !_busy,
            maxLength: 60,
            decoration: const InputDecoration(labelText: '이름으로 프리셋 검색'),
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              _query = value.trim();
              _load();
            },
          ),
        ),
        SwitchListTile(
          title: const Text('내 프리셋만'),
          value: _mine,
          onChanged: _busy
              ? null
              : (value) {
                  _mine = value;
                  _load();
                },
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          TextButton(
            onPressed: _busy ? null : _load,
            child: Text('$_error 다시 시도'),
          ),
        if (!_busy && _error == null && _items.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('프리셋이 없어요.')),
        Expanded(
          child: ListView(
            children: [
              for (final item in _items)
                ListTile(
                  title: Text(item.preset.name),
                  subtitle: _mine ? Text(item.isPublic ? '공개' : '비공개') : null,
                  enabled: !_busy,
                  leading: const Icon(Icons.download),
                  onTap: () => Navigator.pop(context, item.preset),
                  trailing: _mine
                      ? PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (value) => value == 'edit'
                              ? _publish(existing: item)
                              : _delete(item),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('수정')),
                            PopupMenuItem(value: 'delete', child: Text('삭제')),
                          ],
                        )
                      : null,
                ),
              if (_hasMore)
                TextButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('더 보기'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
