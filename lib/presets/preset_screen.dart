import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'preset.dart';
import 'preset_api.dart';
import 'remote_preset_screen.dart';

class PresetScreen extends StatefulWidget {
  const PresetScreen({super.key, required this.zoom, required this.exposure});
  final double zoom;
  final double exposure;

  @override
  State<PresetScreen> createState() => _PresetScreenState();
}

class _PresetScreenState extends State<PresetScreen> {
  final _store = PresetStore();
  final _api = const bool.fromEnvironment('CAM_ENABLE_PRESET_SHARING')
      ? PresetApi.fromEnvironment()
      : null;
  List<Preset>? _presets;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final presets = await _store.load();
      if (mounted) setState(() => _presets = presets);
    } on Exception {
      if (mounted) setState(() => _error = '프리셋을 읽을 수 없어요.');
    }
  }

  Future<void> _edit({int? index, bool import = false}) async {
    if (_busy || _presets == null) return;
    setState(() => _busy = true);
    final updated = [..._presets!];
    try {
      final original = index == null
          ? Preset(
              '',
              capture: {
                'zoom': widget.zoom.clamp(1.0, 100.0),
                'exposureEv': widget.exposure.clamp(-12.0, 12.0),
              },
            )
          : updated[index];
      final preset = await showDialog<Preset>(
        context: context,
        builder: (_) => _PresetEditor(original: original, importing: import),
      );
      if (!mounted || preset == null) return;
      if (index == null) {
        updated.add(preset);
      } else {
        updated[index] = preset;
      }
      await _store.save(updated);
      if (mounted) setState(() => _presets = updated);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('프리셋을 저장하지 못했어요.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCopy(Future<Preset?> Function() pickPreset) async {
    if (_busy || _presets == null) return;
    setState(() => _busy = true);
    try {
      final preset = await pickPreset();
      if (!mounted || preset == null) return;
      final updated = [..._presets!, preset];
      await _store.save(updated);
      if (mounted) setState(() => _presets = updated);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('프리셋을 가져오지 못했어요. JSON 형식과 크기를 확인해 주세요.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Preset?> _pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'JSON',
          mimeTypes: ['application/json'],
          uniformTypeIdentifiers: ['public.json'],
          extensions: ['json'],
        ),
      ],
    );
    if (file == null) return null;
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, 16385)) {
      bytes.addAll(chunk);
    }
    if (bytes.length > 16384) {
      throw const FormatException('Preset is too large');
    }
    return Preset.fromJson(jsonDecode(utf8.decode(bytes)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('프리셋'),
      actions: [
        if (_api case final api?)
          IconButton(
            tooltip: '공유 프리셋',
            onPressed: _busy || _presets == null
                ? null
                : () => _saveCopy(
                    () => Navigator.of(context).push<Preset>(
                      MaterialPageRoute(
                        builder: (_) =>
                            RemotePresetScreen(api: api, local: _presets!),
                      ),
                    ),
                  ),
            icon: const Icon(Icons.cloud_outlined),
          ),
        IconButton(
          tooltip: 'JSON 파일 열기',
          onPressed: _busy || _presets == null
              ? null
              : () => _saveCopy(_pickFile),
          icon: const Icon(Icons.folder_open_outlined),
        ),
        IconButton(
          tooltip: 'JSON 가져오기',
          onPressed: _busy || _presets == null
              ? null
              : () => _edit(import: true),
          icon: const Icon(Icons.file_open_outlined),
        ),
        IconButton(
          tooltip: '새 프리셋',
          onPressed: _busy || _presets == null ? null : _edit,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: _presets == null
        ? Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : Text(_error!),
          )
        : ListView(
            children: [
              ListTile(
                title: const Text('기본 색감'),
                enabled: !_busy,
                onTap: () => Navigator.pop(context, const Preset('기본 색감')),
              ),
              for (final (index, preset) in _presets!.indexed)
                ListTile(
                  title: Text(preset.name),
                  enabled: !_busy,
                  onTap: () => Navigator.pop(context, preset),
                  trailing: IconButton(
                    tooltip: '${preset.name} 수정',
                    onPressed: _busy ? null : () => _edit(index: index),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
            ],
          ),
  );
}

class _PresetEditor extends StatefulWidget {
  const _PresetEditor({required this.original, required this.importing});
  final Preset original;
  final bool importing;

  @override
  State<_PresetEditor> createState() => _PresetEditorState();
}

class _PresetEditorState extends State<_PresetEditor> {
  late final _text = TextEditingController(text: widget.original.name);
  late final _color = {...widget.original.color};
  late final _capture = {
    for (final key in captureControls.keys)
      key: TextEditingController(
        text: widget.original.capture[key]?.toString(),
      ),
  };
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    if (!widget.importing) {
      for (final controller in _capture.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  void _submit() {
    try {
      final text = _text.text;
      if (text.length > 16384) throw const FormatException('프리셋이 너무 커요.');
      final value = widget.importing
          ? jsonDecode(text)
          : Preset(
              text,
              capture: {
                for (final MapEntry(:key, :value) in _capture.entries)
                  if (value.text.trim().isNotEmpty)
                    key: double.parse(value.text),
              },
              color: _color,
            ).toJson();
      Navigator.pop(context, Preset.fromJson(value));
    } on FormatException catch (error) {
      setState(
        () => _error = widget.importing
            ? 'JSON 버전과 설정 값 형식을 확인해 주세요.'
            : error.message,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.importing ? '프리셋 가져오기' : '프리셋 편집'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            minLines: widget.importing ? 4 : 1,
            maxLines: widget.importing ? 8 : 1,
            decoration: InputDecoration(
              labelText: widget.importing ? '프리셋 JSON 붙여넣기' : '이름',
              errorText: _error,
            ),
          ),
          if (!widget.importing)
            for (final MapEntry(key: key, value: label)
                in colorControls.entries)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  Slider(
                    min: -1,
                    max: 1,
                    value: _color[key] ?? 0,
                    onChanged: (value) => setState(() => _color[key] = value),
                  ),
                ],
              ),
          if (!widget.importing)
            ExpansionTile(
              title: const Text('촬영 설정'),
              children: [
                for (final MapEntry(:key, :value) in captureControls.entries)
                  TextField(
                    controller: _capture[key],
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: value.$1),
                  ),
              ],
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _submit, child: const Text('저장')),
    ],
  );
}
