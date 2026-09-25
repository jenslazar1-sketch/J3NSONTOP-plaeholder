/// Form rendered from a JSON schema (documented subset): nested objects as
/// collapsible panels, arrays with add/remove/reorder, enums as dropdowns,
/// numbers with steppers and bounds, booleans as switches, strings with
/// length/pattern validation. Every edit goes through the controller, which
/// rewrites the raw JSON and re-validates.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/json_parser.dart';
import '../../domain/json_schema.dart';
import '../../domain/json_tree_ops.dart';
import '../../domain/json_value.dart';
import '../widgets/lab_widgets.dart';
import 'save_editor_controller.dart';

/// Root of the form.
class SchemaForm extends ConsumerWidget {
  const SchemaForm({super.key, required this.schema});
  final SchemaNode schema;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(saveEditorProvider);
    return SchemaFieldView(
      schema: schema,
      path: const [],
      value: s.data,
      label: schema.title ?? 'Save data',
      readOnly: s.dataError != null,
    );
  }
}

void _guard(WidgetRef ref, void Function() edit) {
  try {
    edit();
  } on JsonEditError catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, e.message);
  }
}

String _typeOf(Object? v) => switch (v) {
  Map<Object?, Object?>() => 'object',
  List<Object?>() => 'array',
  String() => 'string',
  int() => 'integer',
  double() => 'number',
  bool() => 'boolean',
  _ => 'null',
};

bool _fits(String type, Object? v) => switch (type) {
  'object' => v is Map<String, Object?>,
  'array' => v is List<Object?>,
  'string' => v is String,
  'integer' => v is int || (v is double && v == v.truncateToDouble()),
  'number' => v is num,
  'boolean' => v is bool,
  'null' => v == null,
  _ => true,
};

/// One schema-described value.
class SchemaFieldView extends ConsumerWidget {
  const SchemaFieldView({
    super.key,
    required this.schema,
    required this.path,
    required this.value,
    required this.label,
    this.required = false,
    this.readOnly = false,
  });

  final SchemaNode schema;
  final List<Object> path;
  final Object? value;
  final String label;
  final bool required;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(saveEditorProvider.notifier);
    final errors = [for (final v in c.violationsAt(path)) v.message];
    // Schemas without "type" but with properties/items still describe an
    // object/array; anything else untyped is edited as raw JSON.
    final type = schema.type ?? (schema.properties.isNotEmpty ? 'object' : (schema.items != null ? 'array' : null));
    final title = '${schema.title ?? label}${required ? ' *' : ''}';
    if (type != null && !_fits(type, value)) {
      return _MismatchField(schema: schema, path: path, value: value, title: title, readOnly: readOnly);
    }
    if (schema.enumValues != null) {
      return _EnumField(schema: schema, path: path, value: value, title: title, errors: errors, readOnly: readOnly);
    }
    final ptr = formatJsonPointer(path);
    switch (type) {
      case 'object':
        return _ObjectPanel(
          schema: schema,
          path: path,
          value: value! as Map<String, Object?>,
          title: title,
          readOnly: readOnly,
        );
      case 'array':
        return _ArrayPanel(
          schema: schema,
          path: path,
          value: value! as List<Object?>,
          title: title,
          readOnly: readOnly,
        );
      case 'string':
        return _TextValueField(
          key: ValueKey('str$ptr'),
          schema: schema,
          path: path,
          value: value! as String,
          title: title,
          errors: errors,
          readOnly: readOnly,
        );
      case 'integer' || 'number':
        return _NumberValueField(
          key: ValueKey('num$ptr'),
          schema: schema,
          path: path,
          value: value! as num,
          integer: type == 'integer',
          title: title,
          errors: errors,
          readOnly: readOnly,
        );
      case 'boolean':
        return _FieldShell(
          errors: errors,
          child: LabSwitch(
            label: title,
            description: schema.description,
            value: value! as bool,
            onChanged: readOnly ? null : (v) => _guard(ref, () => c.setAt(path, v)),
          ),
        );
      default:
        return _RawValueField(
          key: ValueKey('raw$ptr'),
          path: path,
          value: value,
          title: '$title (${type ?? 'any JSON'})',
          errors: errors,
          readOnly: readOnly,
        );
    }
  }
}

/// Error lines under a field.
class _FieldShell extends StatelessWidget {
  const _FieldShell({required this.child, required this.errors});
  final Widget child;
  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        for (final e in errors)
          Padding(
            padding: const EdgeInsets.only(left: J3Space.sm, top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 14, color: J3Colors.error),
                const SizedBox(width: J3Space.xs),
                Expanded(
                  child: Text(e, style: J3Type.caption.copyWith(color: J3Colors.error)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ObjectPanel extends ConsumerWidget {
  const _ObjectPanel({
    required this.schema,
    required this.path,
    required this.value,
    required this.title,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final Map<String, Object?> value;
  final String title;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(saveEditorProvider);
    final c = ref.read(saveEditorProvider.notifier);
    final ptr = formatJsonPointer(path);
    final collapsed = s.collapsed.contains(ptr);
    final below = c.violationsBelow(path);
    final ownErrors = [for (final v in c.violationsAt(path)) v.message];
    final extras = [
      for (final k in value.keys)
        if (!schema.properties.containsKey(k)) k,
    ];
    return NeonPanel(
      kicker: path.isEmpty ? 'SAVE ROOT' : ptr,
      title: title,
      emphasis: below > 0 ? PanelEmphasis.danger : PanelEmphasis.subtle,
      padding: const EdgeInsets.all(J3Space.md),
      actions: [
        if (below > 0) StatusBadge(kind: StatusKind.error, text: '$below', dense: true),
        IconButton(
          tooltip: collapsed ? 'Expand $title' : 'Collapse $title',
          onPressed: () => c.toggleCollapsed(ptr),
          icon: Icon(collapsed ? Icons.unfold_more : Icons.unfold_less, size: 18),
        ),
      ],
      child: collapsed
          ? Text('${value.length} properties (collapsed)', style: J3Type.caption)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (schema.description != null) ...[
                  Text(schema.description!, style: J3Type.caption),
                  const SizedBox(height: J3Space.sm),
                ],
                for (final e in ownErrors)
                  Padding(
                    padding: const EdgeInsets.only(bottom: J3Space.xs),
                    child: Text('ERROR: $e', style: J3Type.caption.copyWith(color: J3Colors.error)),
                  ),
                for (final entry in schema.properties.entries) ...[
                  if (value.containsKey(entry.key))
                    SchemaFieldView(
                      schema: entry.value,
                      path: [...path, entry.key],
                      value: value[entry.key],
                      label: entry.key,
                      required: schema.isRequired(entry.key),
                      readOnly: readOnly,
                    )
                  else
                    _MissingRow(
                      name: entry.key,
                      required: schema.isRequired(entry.key),
                      onAdd: readOnly
                          ? null
                          : () => _guard(ref, () => c.addProperty(path, entry.key, defaultForSchema(entry.value))),
                    ),
                  const SizedBox(height: J3Space.sm),
                ],
                for (final k in extras) ...[
                  _ExtraRow(
                    name: k,
                    value: value[k],
                    allowed: schema.additionalProperties,
                    onRemove: readOnly ? null : () => _guard(ref, () => c.remove([...path, k])),
                  ),
                  const SizedBox(height: J3Space.sm),
                ],
                if (schema.properties.isEmpty && extras.isEmpty) Text('No properties', style: J3Type.caption),
              ],
            ),
    );
  }
}

class _MissingRow extends StatelessWidget {
  const _MissingRow({required this.name, required this.required, required this.onAdd});
  final String name;
  final bool required;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          required ? Icons.error_outline : Icons.remove_circle_outline,
          size: 16,
          color: required ? J3Colors.error : J3Colors.textMuted,
        ),
        const SizedBox(width: J3Space.sm),
        Expanded(
          child: Text(
            '$name: ${required ? 'REQUIRED but missing' : 'not set (optional)'}',
            style: J3Type.caption.copyWith(color: required ? J3Colors.error : J3Colors.textMuted),
          ),
        ),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: Text('Add $name', overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _ExtraRow extends StatelessWidget {
  const _ExtraRow({required this.name, required this.value, required this.allowed, required this.onRemove});
  final String name;
  final Object? value;
  final bool allowed;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          allowed ? Icons.info_outline : Icons.error_outline,
          size: 16,
          color: allowed ? J3Colors.info : J3Colors.error,
        ),
        const SizedBox(width: J3Space.sm),
        Expanded(
          child: Text(
            '$name = ${jsonPreview(value)}  (${allowed ? 'not in schema, kept as is' : 'NOT ALLOWED by the schema'})',
            style: J3Type.codeSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(tooltip: 'Remove $name', onPressed: onRemove, icon: const Icon(Icons.delete_outline, size: 18)),
      ],
    );
  }
}

class _ArrayPanel extends ConsumerWidget {
  const _ArrayPanel({
    required this.schema,
    required this.path,
    required this.value,
    required this.title,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final List<Object?> value;
  final String title;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(saveEditorProvider);
    final c = ref.read(saveEditorProvider.notifier);
    final ptr = formatJsonPointer(path);
    final collapsed = s.collapsed.contains(ptr);
    final below = c.violationsBelow(path);
    final itemSchema = schema.items ?? SchemaNode(pointer: '${schema.pointer}/items');
    return NeonPanel(
      kicker: ptr.isEmpty ? 'SAVE ROOT' : ptr,
      title: '$title (${value.length} ${value.length == 1 ? 'item' : 'items'})',
      emphasis: below > 0 ? PanelEmphasis.danger : PanelEmphasis.subtle,
      padding: const EdgeInsets.all(J3Space.md),
      actions: [
        if (below > 0) StatusBadge(kind: StatusKind.error, text: '$below', dense: true),
        IconButton(
          tooltip: collapsed ? 'Expand $title' : 'Collapse $title',
          onPressed: () => c.toggleCollapsed(ptr),
          icon: Icon(collapsed ? Icons.unfold_more : Icons.unfold_less, size: 18),
        ),
      ],
      child: collapsed
          ? Text('${value.length} items (collapsed)', style: J3Type.caption)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (schema.description != null) ...[
                  Text(schema.description!, style: J3Type.caption),
                  const SizedBox(height: J3Space.sm),
                ],
                for (var i = 0; i < value.length; i++) ...[
                  Container(
                    padding: const EdgeInsets.all(J3Space.sm),
                    decoration: BoxDecoration(
                      borderRadius: J3Radius.small,
                      border: Border.all(color: J3Colors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text('Item ${i + 1}', style: J3Type.label)),
                            IconButton(
                              tooltip: 'Move item ${i + 1} up',
                              onPressed: readOnly || i == 0 ? null : () => _guard(ref, () => c.move(path, i, i - 1)),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Move item ${i + 1} down',
                              onPressed: readOnly || i == value.length - 1
                                  ? null
                                  : () => _guard(ref, () => c.move(path, i, i + 1)),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Remove item ${i + 1}',
                              onPressed: readOnly ? null : () => _guard(ref, () => c.remove([...path, i])),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
                        ),
                        SchemaFieldView(
                          schema: itemSchema,
                          path: [...path, i],
                          value: value[i],
                          label: 'Item ${i + 1}',
                          readOnly: readOnly,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: J3Space.sm),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: NeonButton.secondary(
                    label: 'Add item',
                    icon: Icons.add,
                    dense: true,
                    onPressed: readOnly ? null : () => _guard(ref, () => c.addItem(path, defaultForSchema(itemSchema))),
                  ),
                ),
              ],
            ),
    );
  }
}

class _EnumField extends ConsumerWidget {
  const _EnumField({
    required this.schema,
    required this.path,
    required this.value,
    required this.title,
    required this.errors,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final Object? value;
  final String title;
  final List<String> errors;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = schema.enumValues!;
    final index = options.indexWhere((o) => jsonDeepEquals(o, value, strictNumbers: false));
    String label(Object? o) => o is String ? o : jsonPreview(o);
    return _FieldShell(
      errors: errors,
      child: DropdownButtonFormField<int>(
        key: ValueKey('enum${formatJsonPointer(path)}#$index'),
        initialValue: index,
        isExpanded: true,
        decoration: InputDecoration(labelText: title, helperText: schema.description),
        items: [
          if (index < 0)
            DropdownMenuItem(
              value: -1,
              child: Text('${label(value)} (not an allowed value)', overflow: TextOverflow.ellipsis),
            ),
          for (var i = 0; i < options.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(label(options[i]), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: readOnly
            ? null
            : (i) {
                if (i == null || i < 0) return;
                _guard(ref, () => ref.read(saveEditorProvider.notifier).setAt(path, jsonDeepCopy(options[i])));
              },
      ),
    );
  }
}

String _stringHint(SchemaNode s) => [
  if (s.description != null) s.description!,
  if (s.minLength != null) 'min ${s.minLength} chars',
  if (s.maxLength != null) 'max ${s.maxLength} chars',
  if (s.pattern != null) 'pattern ${s.pattern}',
].join(' · ');

class _TextValueField extends ConsumerStatefulWidget {
  const _TextValueField({
    super.key,
    required this.schema,
    required this.path,
    required this.value,
    required this.title,
    required this.errors,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final String value;
  final String title;
  final List<String> errors;
  final bool readOnly;

  @override
  ConsumerState<_TextValueField> createState() => _TextValueFieldState();
}

class _TextValueFieldState extends ConsumerState<_TextValueField> {
  late final TextEditingController _c = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_TextValueField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && !_focus.hasFocus) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = _stringHint(widget.schema);
    return TextField(
      controller: _c,
      focusNode: _focus,
      readOnly: widget.readOnly,
      style: J3Type.code,
      decoration: InputDecoration(
        labelText: widget.title,
        helperText: hint.isEmpty ? null : hint,
        helperMaxLines: 3,
        errorText: widget.errors.isEmpty ? null : widget.errors.join('\n'),
      ),
      onChanged: (v) => _guard(ref, () => ref.read(saveEditorProvider.notifier).setAt(widget.path, v)),
    );
  }
}

class _NumberValueField extends ConsumerStatefulWidget {
  const _NumberValueField({
    super.key,
    required this.schema,
    required this.path,
    required this.value,
    required this.integer,
    required this.title,
    required this.errors,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final num value;
  final bool integer;
  final String title;
  final List<String> errors;
  final bool readOnly;

  @override
  ConsumerState<_NumberValueField> createState() => _NumberValueFieldState();
}

class _NumberValueFieldState extends ConsumerState<_NumberValueField> {
  late final TextEditingController _c = TextEditingController(text: jsonPreview(widget.value));
  final FocusNode _focus = FocusNode();
  String? _local;

  @override
  void didUpdateWidget(_NumberValueField old) {
    super.didUpdateWidget(old);
    final text = jsonPreview(widget.value);
    if (!_focus.hasFocus && text != _c.text) {
      _c.text = text;
      _local = null;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(num v) => _guard(ref, () => ref.read(saveEditorProvider.notifier).setAt(widget.path, v));

  void _onChanged(String text) {
    try {
      final v = parseScalarInput(ScalarKind.number, text) as num;
      if (widget.integer && v is double && v != v.truncateToDouble()) {
        setState(() => _local = 'Whole number required');
        return;
      }
      setState(() => _local = null);
      _set(widget.integer && v is double ? v.toInt() : v);
    } on JsonEditError catch (e) {
      setState(() => _local = e.message);
    }
  }

  void _step(int delta) {
    final s = widget.schema;
    num next = widget.value + delta;
    if (s.minimum != null && next < s.minimum!) next = s.minimum!;
    if (s.maximum != null && next > s.maximum!) next = s.maximum!;
    if (widget.integer) next = next.round();
    _c.text = jsonPreview(next);
    setState(() => _local = null);
    _set(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.schema;
    final range = [
      if (s.minimum != null) 'min ${s.minimum}',
      if (s.maximum != null) 'max ${s.maximum}',
      widget.integer ? 'whole number' : 'number',
    ].join(' · ');
    final errors = [?_local, ...widget.errors];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _c,
            focusNode: _focus,
            readOnly: widget.readOnly,
            style: J3Type.code,
            keyboardType: TextInputType.numberWithOptions(decimal: !widget.integer, signed: true),
            decoration: InputDecoration(
              labelText: widget.title,
              helperText: s.description == null ? range : '${s.description} · $range',
              helperMaxLines: 3,
              errorText: errors.isEmpty ? null : errors.join('\n'),
            ),
            onChanged: widget.readOnly ? null : _onChanged,
          ),
        ),
        IconButton(
          tooltip: 'Decrease ${widget.title}',
          onPressed: widget.readOnly ? null : () => _step(-1),
          icon: const Icon(Icons.remove, size: 18),
        ),
        IconButton(
          tooltip: 'Increase ${widget.title}',
          onPressed: widget.readOnly ? null : () => _step(1),
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
  }
}

/// Free JSON for values without a usable type (or type mismatches).
class _RawValueField extends ConsumerStatefulWidget {
  const _RawValueField({
    super.key,
    required this.path,
    required this.value,
    required this.title,
    required this.errors,
    required this.readOnly,
  });

  final List<Object> path;
  final Object? value;
  final String title;
  final List<String> errors;
  final bool readOnly;

  @override
  ConsumerState<_RawValueField> createState() => _RawValueFieldState();
}

class _RawValueFieldState extends ConsumerState<_RawValueField> {
  late final TextEditingController _c = TextEditingController(text: jsonEncode(widget.value));
  final FocusNode _focus = FocusNode();
  String? _local;

  @override
  void didUpdateWidget(_RawValueField old) {
    super.didUpdateWidget(old);
    final text = jsonEncode(widget.value);
    if (!_focus.hasFocus && text != _c.text) _c.text = text;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply() {
    try {
      final v = decodeJsonStrict(_c.text);
      setState(() => _local = null);
      _guard(ref, () => ref.read(saveEditorProvider.notifier).setAt(widget.path, v));
    } on JsonSyntaxError catch (e) {
      setState(() => _local = 'Not valid JSON: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final errors = [?_local, ...widget.errors];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _c,
            focusNode: _focus,
            readOnly: widget.readOnly,
            style: J3Type.code,
            decoration: InputDecoration(
              labelText: widget.title,
              helperText: 'JSON value; press Enter or Apply',
              errorText: errors.isEmpty ? null : errors.join('\n'),
            ),
            onSubmitted: widget.readOnly ? null : (_) => _apply(),
          ),
        ),
        IconButton(
          tooltip: 'Apply ${widget.title}',
          onPressed: widget.readOnly ? null : _apply,
          icon: const Icon(Icons.check, size: 18),
        ),
      ],
    );
  }
}

class _MismatchField extends ConsumerWidget {
  const _MismatchField({
    required this.schema,
    required this.path,
    required this.value,
    required this.title,
    required this.readOnly,
  });

  final SchemaNode schema;
  final List<Object> path;
  final Object? value;
  final String title;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(J3Space.sm),
      decoration: BoxDecoration(
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.error.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'ERROR: $title should be ${schema.type ?? (schema.properties.isNotEmpty ? 'object' : 'array')} but is ${_typeOf(value)} ${jsonPreview(value)}',
            style: J3Type.caption.copyWith(color: J3Colors.error),
          ),
          const SizedBox(height: J3Space.xs),
          _RawValueField(
            key: ValueKey('mismatch${formatJsonPointer(path)}'),
            path: path,
            value: value,
            title: title,
            errors: const [],
            readOnly: readOnly,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: readOnly
                  ? null
                  : () =>
                        _guard(ref, () => ref.read(saveEditorProvider.notifier).setAt(path, defaultForSchema(schema))),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('Reset to schema default'),
            ),
          ),
        ],
      ),
    );
  }
}
