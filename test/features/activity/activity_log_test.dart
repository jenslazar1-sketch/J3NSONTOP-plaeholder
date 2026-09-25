import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/activity/operation.dart';
import 'package:j3nsontop_multitool/features/activity/activity_log.dart';

OperationRecord op(
  String id, {
  String title = 'Operation',
  String toolId = 'files.hash',
  OperationStatus status = OperationStatus.succeeded,
  String? summary,
  String? error,
  List<String> details = const [],
  Map<String, num> counts = const {},
  String? workspaceId,
}) {
  final start = DateTime(2026, 9, 25, 18, 40, 1);
  return OperationRecord(
    id: id,
    toolId: toolId,
    title: title,
    status: status,
    startedAt: start,
    endedAt: status == OperationStatus.running ? null : start.add(const Duration(milliseconds: 1250)),
    summary: summary,
    error: error,
    details: details,
    counts: counts,
    workspaceId: workspaceId,
  );
}

void main() {
  group('redactSecrets', () {
    test('masks header values to the end of the line', () {
      expect(redactSecrets('Authorization: Bearer abc.def.ghi'), 'Authorization: $kRedacted');
      expect(redactSecrets('authorization:Basic dXNlcjpwYXNz'), 'authorization:$kRedacted');
      expect(redactSecrets('Proxy-Authorization: Digest x'), 'Proxy-Authorization: $kRedacted');
      expect(redactSecrets('Cookie: session=1; theme=dark\nnext line'), 'Cookie: $kRedacted\nnext line');
      expect(redactSecrets('Set-Cookie: id=a3fWa; Secure'), 'Set-Cookie: $kRedacted');
      expect(redactSecrets('> sent header "Authorization": "Bearer xyz"'), '> sent header "Authorization": $kRedacted');
    });

    test('masks key=value secrets and keeps the rest of the line', () {
      expect(
        redactSecrets('GET https://dev.local/api?token=abc123&page=2'),
        'GET https://dev.local/api?token=$kRedacted&page=2',
      );
      expect(redactSecrets('password=hunter2 user=bob'), 'password=$kRedacted user=bob');
      expect(redactSecrets('secret = s3cr3t;next'), 'secret = $kRedacted;next');
      expect(
        redactSecrets('apikey=K1&api_key=K2&API-KEY=K3'),
        'apikey=$kRedacted&api_key=$kRedacted&API-KEY=$kRedacted',
      );
      expect(redactSecrets('access_token=a1 client_secret=b2'), 'access_token=$kRedacted client_secret=$kRedacted');
      expect(redactSecrets('password="two words" ok=1'), 'password=$kRedacted ok=1');
      expect(redactSecrets('TOKEN=UPPER'), 'TOKEN=$kRedacted');
    });

    test('masks JSON/YAML style secrets', () {
      expect(redactSecrets('{"token": "abc", "page": 2}'), '{"token": $kRedacted, "page": 2}');
      expect(redactSecrets('password: hunter2'), 'password: $kRedacted');
      expect(redactSecrets('X-Api-Key: 1234'), 'X-Api-Key: $kRedacted');
    });

    test('masks bare bearer credentials', () {
      expect(redactSecrets('used Bearer eyJhbGciOi.payload.sig'), 'used Bearer $kRedacted');
    });

    test('leaves ordinary text untouched', () {
      const plain = [
        'Hashed 12 files (40960 bytes) in 1.2 s',
        'tokens: 12',
        'tokenizer=fast',
        'secretary=Ann',
        'Cookies are not used',
        'Authorization header missing',
        'counts: files=3, bytes=1024',
      ];
      for (final line in plain) {
        expect(redactSecrets(line), line, reason: line);
      }
    });

    test('is idempotent', () {
      const input = 'Authorization: Bearer abc\ntoken=x password: y';
      final once = redactSecrets(input);
      expect(redactSecrets(once), once);
      expect(once.contains('abc') || once.contains('=x') || once.contains(': y'), isFalse);
    });
  });

  group('ActivityFilter', () {
    final ops = [
      op('1', title: 'Hash files', toolId: 'files.hash', summary: '3 files hashed'),
      op('2', title: 'Decode', toolId: 'dev.base64', status: OperationStatus.failed, error: 'Invalid padding'),
      op('3', title: 'Apply profile', toolId: 'mods.apply', status: OperationStatus.warning, summary: 'overlaps'),
    ];

    test('search matches title, summary, error and tool id', () {
      expect(filterOperations(ops, const ActivityFilter(query: 'hash')).map((o) => o.id), ['1']);
      expect(filterOperations(ops, const ActivityFilter(query: 'PADDING')).map((o) => o.id), ['2']);
      expect(filterOperations(ops, const ActivityFilter(query: 'mods.apply')).map((o) => o.id), ['3']);
      expect(filterOperations(ops, const ActivityFilter(query: 'files hashed')).map((o) => o.id), ['1']);
      expect(filterOperations(ops, const ActivityFilter(query: 'nothing')), isEmpty);
    });

    test('status and tool filters combine with search', () {
      expect(filterOperations(ops, const ActivityFilter(status: OperationStatus.failed)).map((o) => o.id), ['2']);
      expect(filterOperations(ops, const ActivityFilter(toolId: 'mods.apply')).map((o) => o.id), ['3']);
      expect(filterOperations(ops, const ActivityFilter(toolId: 'mods.apply', query: 'hash')), isEmpty);
      expect(filterOperations(ops, const ActivityFilter()).length, 3);
    });

    test('search can use the display name of a tool', () {
      final r = filterOperations(ops, const ActivityFilter(query: 'base64 codec'), toolName: (id) => 'Base64 codec');
      expect(r.length, 3);
    });

    test('describe and copyWith', () {
      expect(const ActivityFilter().describe(), 'none (full history)');
      const f = ActivityFilter(query: 'x', status: OperationStatus.failed, toolId: 'files.hash');
      expect(f.describe(toolName: (_) => 'Hash files'), 'search "x", status FAILED, tool Hash files');
      expect(f.copyWith(clearStatus: true).status, isNull);
      expect(f.copyWith(clearTool: true).toolId, isNull);
      expect(f.isActive, isTrue);
      expect(const ActivityFilter(query: '  ').isActive, isFalse);
    });
  });

  group('buildActivityLog', () {
    test('contains every field and is redacted', () {
      final text = buildActivityLog(
        [
          op(
            'a',
            title: 'HTTP request',
            toolId: 'dev.http',
            summary: '200 OK',
            details: ['Authorization: Bearer supersecret', 'GET /items?api_key=K9&page=1'],
            counts: {'bytes': 2048, 'headers': 5},
            workspaceId: 'w1',
          ),
          op('b', title: 'Decode', status: OperationStatus.failed, error: 'password=hunter2 rejected'),
        ],
        now: DateTime(2026, 9, 25, 19),
        platformLabel: 'Linux (dev/test)',
        toolName: (id) => id == 'dev.http' ? 'HTTP client' : id,
        workspaceName: (id) => id == null ? null : 'Neon Dungeon',
        filterDescription: 'status FAILED',
      );
      expect(text, contains(AppInfo.fullName));
      expect(text, contains('Filter:    status FAILED'));
      expect(text, contains('Entries:   2'));
      expect(text, contains('HTTP client (dev.http)'));
      expect(text, contains('Workspace: Neon Dungeon'));
      expect(text, contains('Duration:  1.25 s'));
      expect(text, contains('Counts:    bytes=2.0 KB (2048), headers=5'));
      expect(text, contains('Summary:   200 OK'));
      expect(text, contains('Error:     password=$kRedacted rejected'));
      expect(text, contains('> Authorization: $kRedacted'));
      expect(text, contains('api_key=$kRedacted&page=1'));
      expect(text, isNot(contains('supersecret')));
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('K9')));
    });

    test('running operations show their progress', () {
      final running = OperationRecord(
        id: 'r',
        toolId: 'files.hash',
        title: 'Hashing',
        status: OperationStatus.running,
        startedAt: DateTime(2026, 9, 25),
        progress: 0.5,
        progressMessage: '5 of 10 files',
      );
      final text = buildActivityLog([running], now: DateTime(2026, 9, 25), platformLabel: 'Windows');
      expect(text, contains('Progress:  50 % - 5 of 10 files'));
      expect(text, contains('RUNNING'));
    });
  });

  test('formatCount', () {
    expect(formatCount('files', 3), '3');
    expect(formatCount('bytes', 512), '512 B (512)');
    expect(formatCount('ratio', 0.5), '0.50');
    expect(formatCount('ratio', 2.0), '2');
  });
}
