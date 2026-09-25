import 'package:flutter/material.dart';

import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/issues.dart';
import '../domain/manifest.dart';
import '../domain/package_inspector.dart';
import 'mods_widgets.dart';

/// Validity headline + key facts of a package report.
class PackageSummary extends StatelessWidget {
  const PackageSummary({super.key, required this.report});
  final PackageReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final m = r.parsedManifest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        r.isValid
            ? ModBanner(
                kind: r.warningCount > 0 ? StatusKind.warning : StatusKind.success,
                title: r.warningCount > 0 ? 'Valid with ${r.warningCount} warning(s)' : 'Valid package',
                message: '${r.displayName} ${r.displayVersion ?? ''} can be imported and applied.',
              )
            : ModBanner(
                kind: StatusKind.error,
                title: 'Blocked: ${r.errorCount} error(s)',
                message: 'This package cannot be imported or applied until the errors below are fixed.',
              ),
        const SizedBox(height: J3Space.md),
        KeyValueTable(
          keyWidth: 118,
          rows: [
            ('Name', r.displayName),
            ('Id', r.displayId),
            ('Version', r.displayVersion ?? '(missing)'),
            if (m?.author != null) ('Author', m!.author!),
            if (m?.license != null) ('License', m!.license!),
            if (m != null) ('Made for', m.compatibility.toString()),
            ('Archive', '${r.fileName} (${Fmt.bytes(r.archiveBytes)})'),
            ('Payload', '${Fmt.count(r.mapped.length, 'mapped file')}, ${Fmt.bytes(r.payloadBytes)} uncompressed'),
            if (m != null && m.tags.isNotEmpty) ('Tags', m.tags.join(', ')),
          ],
        ),
        if (m?.description != null && m!.description!.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          Text(m.description!, style: J3Type.bodySecondary),
        ],
      ],
    );
  }
}

/// All issues grouped by severity.
class PackageIssues extends StatelessWidget {
  const PackageIssues({super.key, required this.issues});
  final List<ModIssue> issues;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) {
      return const IssueLine(severity: IssueSeverity.info, message: 'No issues found.');
    }
    final errors = issues.errors;
    final warnings = issues.warnings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errors.isNotEmpty)
          IssueGroup(title: 'Errors', kind: StatusKind.error, children: [for (final i in errors) IssueLine.of(i)]),
        if (warnings.isNotEmpty)
          IssueGroup(
            title: 'Warnings',
            kind: StatusKind.warning,
            children: [for (final i in warnings) IssueLine.of(i)],
          ),
      ],
    );
  }
}

/// The manifest's file mapping: target <- source, size, presence.
class PackageMapping extends StatelessWidget {
  const PackageMapping({super.key, required this.report});
  final PackageReport report;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    if (report.mapped.isEmpty) {
      return Text(
        report.manifestResult == null ? 'No manifest could be read.' : 'The manifest maps no usable files.',
        style: J3Type.caption,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in report.mapped)
          Container(
            margin: const EdgeInsets.only(bottom: J3Space.xs),
            padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
            decoration: BoxDecoration(
              color: J3Colors.surfaceRaised,
              borderRadius: J3Radius.small,
              border: Border.all(color: m.exists ? J3Colors.border : J3Colors.error.withValues(alpha: 0.6)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    m.exists ? Icons.description_outlined : Icons.error_outline,
                    size: 16,
                    color: m.exists ? fx.accentText : J3Colors.error,
                  ),
                ),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.mapping.target, style: J3Type.code),
                      Text(
                        '<- ${m.mapping.source}  |  ${m.exists ? Fmt.bytes(m.size) : 'MISSING in archive'}',
                        style: J3Type.codeSmall.copyWith(color: m.exists ? J3Colors.textMuted : J3Colors.error),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (report.unmapped.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          Text('NOT MAPPED (ignored)', style: J3Type.kicker.copyWith(color: J3Colors.warning)),
          for (final u in report.unmapped) Text(u, style: J3Type.codeSmall),
        ],
      ],
    );
  }
}

/// Dependencies, optional dependencies and conflicts.
class PackageRelations extends StatelessWidget {
  const PackageRelations({super.key, required this.manifest});
  final ModManifest manifest;

  @override
  Widget build(BuildContext context) {
    final m = manifest;
    if (m.dependencies.isEmpty && m.optionalDependencies.isEmpty && m.conflicts.isEmpty) {
      return Text('No dependencies or conflicts declared.', style: J3Type.caption);
    }
    Widget row(IconData icon, String kind, String text, Color color) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$kind ',
                    style: J3Type.codeSmall.copyWith(color: color),
                  ),
                  TextSpan(text: text, style: J3Type.code),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in m.dependencies) row(Icons.link, 'REQUIRES', d.toString(), J3Colors.info),
        for (final d in m.optionalDependencies) row(Icons.link_off, 'OPTIONAL', d.toString(), J3Colors.textMuted),
        for (final c in m.conflicts)
          row(
            Icons.block,
            'CONFLICTS',
            '${c.id}${c.constraint.isAny ? '' : ' ${c.constraintText}'}${c.reason != null ? ' - ${c.reason}' : ''}',
            J3Colors.error,
          ),
      ],
    );
  }
}

/// The full package report as one scrollable column (drawer + inspector).
class PackageReportView extends StatelessWidget {
  const PackageReportView({super.key, required this.report, this.footer = const [], this.usedBy = const []});
  final PackageReport report;
  final List<Widget> footer;
  final List<String> usedBy;

  @override
  Widget build(BuildContext context) {
    final m = report.parsedManifest;
    return ListView(
      padding: const EdgeInsets.all(J3Space.lg),
      children: [
        PackageSummary(report: report),
        if (usedBy.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          Text('Used by: ${usedBy.join(', ')}', style: J3Type.caption),
        ],
        const SectionHeader(title: 'Files', kicker: 'mapping'),
        PackageMapping(report: report),
        if (m != null) ...[
          const SectionHeader(title: 'Relations', kicker: 'dependencies'),
          PackageRelations(manifest: m),
        ],
        const SectionHeader(title: 'Issues', kicker: 'validation'),
        PackageIssues(issues: report.issues),
        if (footer.isNotEmpty) ...[
          const SizedBox(height: J3Space.lg),
          Wrap(spacing: J3Space.sm, runSpacing: J3Space.sm, children: footer),
        ],
      ],
    );
  }
}
