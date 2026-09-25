/// Itemised conversion reports. Every conversion in the Config Lab returns a
/// [ConversionReport] that lists *every* difference between what the source
/// contained and what the output can express.
///
/// * [IssueSeverity.error]: the conversion was refused (no output).
/// * [IssueSeverity.loss]: the output CHANGES REPRESENTATION - converting it
///   back would not reproduce the source (comments dropped, types changed,
///   keys reordered, values inferred...).
/// * [IssueSeverity.note]: information only; data, types and order are kept.
///
/// A conversion is LOSSLESS when it has no errors and no losses. Formatting
/// (indentation, quoting style, flow vs block style) is always regenerated in
/// the target format's canonical style and is not itemised.
library;

enum IssueSeverity { error, loss, note }

enum IssueKind {
  syntax('Syntax error'),
  commentsDropped('Comments dropped'),
  keyOrderChanged('Key order changed'),
  datetimeToString('Date-time converted to string'),
  anchorsExpanded('Anchors/aliases expanded'),
  tagsResolved('Explicit tags resolved'),
  directivesDropped('Directives dropped'),
  mergeKeyNotApplied('Merge key not applied'),
  nonStringKeys('Non-string keys stringified'),
  nullsUnsupported('Null not supported'),
  numericPrecision('Numeric precision'),
  numberNotation('Number notation normalised'),
  nonFiniteNumber('Non-finite number'),
  duplicateKeys('Duplicate keys'),
  typesInferred('Types inferred'),
  typesToText('Types written as text'),
  quotingAdded('Quoting added'),
  quotesRemoved('Quotes removed'),
  multiDocument('Multiple documents'),
  structureFlattened('Structure flattened'),
  nestedUnsupported('Nested value not supported'),
  missingCells('Missing cells'),
  extraCells('Extra cells'),
  headerRenamed('Header renamed'),
  blankLinesSkipped('Blank lines skipped'),
  mixedArray('Mixed-type array'),
  structureNote('Structure'),
  invalidName('Invalid name'),
  unsupportedValue('Unsupported value'),
  emptyInput('Empty input'),
  verification('Round-trip verification');

  const IssueKind(this.label);
  final String label;
}

class ConversionIssue {
  const ConversionIssue(this.kind, this.severity, this.message, {this.path, this.line});

  const ConversionIssue.error(this.kind, this.message, {this.path, this.line}) : severity = IssueSeverity.error;
  const ConversionIssue.loss(this.kind, this.message, {this.path, this.line}) : severity = IssueSeverity.loss;
  const ConversionIssue.note(this.kind, this.message, {this.path, this.line}) : severity = IssueSeverity.note;

  final IssueKind kind;
  final IssueSeverity severity;
  final String message;

  /// JSONPath (or section/key label) the issue refers to.
  final String? path;

  /// 1-based source line, when known.
  final int? line;

  String describe() {
    final where = [if (line != null) 'line $line', ?path].join(' ');
    return where.isEmpty ? message : '$where: $message';
  }
}

class ConversionReport {
  const ConversionReport({required this.from, required this.to, this.issues = const [], this.verified = false});

  final String from;
  final String to;
  final List<ConversionIssue> issues;

  /// The output was re-parsed and compared with the source data.
  final bool verified;

  bool get failed => issues.any((i) => i.severity == IssueSeverity.error);
  bool get lossless => !failed && !issues.any((i) => i.severity == IssueSeverity.loss);

  List<ConversionIssue> get errors => [
    for (final i in issues)
      if (i.severity == IssueSeverity.error) i,
  ];
  List<ConversionIssue> get losses => [
    for (final i in issues)
      if (i.severity == IssueSeverity.loss) i,
  ];
  List<ConversionIssue> get notes => [
    for (final i in issues)
      if (i.severity == IssueSeverity.note) i,
  ];

  bool has(IssueKind kind) => issues.any((i) => i.kind == kind);
  List<ConversionIssue> ofKind(IssueKind kind) => [
    for (final i in issues)
      if (i.kind == kind) i,
  ];

  String get verdict => failed
      ? 'FAILED'
      : lossless
      ? 'LOSSLESS'
      : 'CHANGES REPRESENTATION';

  ConversionReport copyWith({List<ConversionIssue>? issues, bool? verified}) =>
      ConversionReport(from: from, to: to, issues: issues ?? this.issues, verified: verified ?? this.verified);

  /// Plain-text report for export.
  String toText() {
    final b = StringBuffer()
      ..writeln('Conversion $from -> $to: $verdict')
      ..writeln(verified ? 'Round trip verified: output re-parsed and compared with the source.' : '');
    void section(String title, List<ConversionIssue> items) {
      if (items.isEmpty) return;
      b.writeln('$title (${items.length}):');
      for (final i in items) {
        b.writeln('  - [${i.kind.label}] ${i.describe()}');
      }
    }

    section('Errors', errors);
    section('Changes in representation', losses);
    section('Notes', notes);
    if (issues.isEmpty) b.writeln('No differences: data, types, key order and comments are preserved.');
    return b.toString().replaceAll('\n\n', '\n');
  }
}

class ConversionResult {
  const ConversionResult(this.output, this.report);

  const ConversionResult.failed(this.report) : output = null;

  /// Converted text, or null when the conversion failed.
  final String? output;
  final ConversionReport report;

  bool get ok => output != null && !report.failed;
}
