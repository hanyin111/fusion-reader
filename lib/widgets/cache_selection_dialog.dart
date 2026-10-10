import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';

/// Chapter numbers are positions in the currently selected volume/catalog.
class CacheSelectionDialog extends StatefulWidget {
  final MediaEpisodeGroup group;
  final int initialChapter;
  const CacheSelectionDialog({
    super.key,
    required this.group,
    this.initialChapter = 1,
  });

  @override
  State<CacheSelectionDialog> createState() => _CacheSelectionDialogState();
}

class _CacheSelectionDialogState extends State<CacheSelectionDialog> {
  final _form = GlobalKey<FormState>();
  late final _start = TextEditingController(
    text: widget.initialChapter.clamp(1, widget.group.urls.length).toString(),
  );
  late final _end = TextEditingController(
    text: math
        .min(int.parse(_start.text) + 19, widget.group.urls.length)
        .toString(),
  );

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  String? _validate(String? value, {bool end = false}) {
    final number = int.tryParse(value ?? '');
    if (number == null || number < 1 || number > widget.group.urls.length) {
      return '请输入 1–${widget.group.urls.length}';
    }
    if (end && number < (int.tryParse(_start.text) ?? 1)) return '结束章节不能小于起始章节';
    return null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自定义缓存'),
    scrollable: true,
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.group.title} · 共 ${widget.group.urls.length} 个章节'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _start,
              decoration: const InputDecoration(
                labelText: '起始章节',
                prefixText: '第 ',
                suffixText: ' 章',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: _validate,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _end,
              decoration: const InputDecoration(
                labelText: '结束章节',
                prefixText: '第 ',
                suffixText: ' 章',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) => _validate(value, end: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            if (_validate(_start.text) == null &&
                _validate(_end.text, end: true) == null) ...[
              Text(
                '${widget.group.urls[int.parse(_start.text) - 1].name} → ${widget.group.urls[int.parse(_end.text) - 1].name}',
              ),
              const SizedBox(height: 8),
              Text(
                '选择 ${int.parse(_end.text) - int.parse(_start.text) + 1} 个章节，已缓存和排队中的章节会跳过。',
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            widget.group.urls.sublist(
              int.parse(_start.text) - 1,
              int.parse(_end.text),
            ),
          );
        },
        child: const Text('加入缓存列表'),
      ),
    ],
  );
}
