/// Severity of a validation or resolution finding.
///
/// * [error] blocks importing, building or applying.
/// * [warning] is shown and must be acknowledged but does not block.
/// * [info] is purely informational.
enum IssueSeverity {
  error('ERROR'),
  warning('WARN'),
  info('NOTE');

  const IssueSeverity(this.label);
  final String label;
}

/// A typed finding about a manifest, package, or profile field.
class ModIssue {
  const ModIssue(this.severity, this.field, this.message);

  const ModIssue.error(this.field, this.message) : severity = IssueSeverity.error;
  const ModIssue.warning(this.field, this.message) : severity = IssueSeverity.warning;
  const ModIssue.info(this.field, this.message) : severity = IssueSeverity.info;

  final IssueSeverity severity;

  /// Dotted path of the offending field, e.g. `version`, `files[2].target`,
  /// `dependencies[0].version`, or `archive` for container problems.
  final String field;
  final String message;

  bool get isError => severity == IssueSeverity.error;
  bool get isWarning => severity == IssueSeverity.warning;

  @override
  String toString() => '${severity.label} $field: $message';

  @override
  bool operator ==(Object other) =>
      other is ModIssue && other.severity == severity && other.field == field && other.message == message;

  @override
  int get hashCode => Object.hash(severity, field, message);
}

extension ModIssueList on Iterable<ModIssue> {
  List<ModIssue> get errors => where((i) => i.isError).toList();
  List<ModIssue> get warnings => where((i) => i.isWarning).toList();
  bool get hasErrors => any((i) => i.isError);
}
