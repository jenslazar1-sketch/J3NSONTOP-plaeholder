import 'package:flutter/material.dart';

import '../../core/platform/capabilities.dart';
import '../../core/tools/tool_definition.dart';
import 'commands/dev_commands.dart';
import 'presentation/base64_page.dart';
import 'presentation/case_page.dart';
import 'presentation/diff_page.dart';
import 'presentation/http_page.dart';
import 'presentation/json_escape_page.dart';
import 'presentation/jwt_page.dart';
import 'presentation/number_base_page.dart';
import 'presentation/regex_page.dart';
import 'presentation/text_stats_page.dart';
import 'presentation/timestamp_page.dart';
import 'presentation/url_page.dart';
import 'presentation/uuid_page.dart';

/// Developer Tools: encoders, converters, regex, diff, HTTP and friends.
/// Everything runs locally except the HTTP tool, which only contacts the
/// URL the user enters.
final FeatureModule devToolsModule = FeatureModule(
  id: 'dev_tools',
  tools: [
    ToolDefinition(
      id: Base64Page.id,
      name: 'Base64',
      section: ToolSection.devTools,
      description: 'Encode and decode Base64 (standard or URL-safe), files up to 10 MiB, binary hex preview.',
      icon: Icons.code,
      keywords: const ['base64', 'b64', 'encode', 'decode', 'base64url', 'data uri', 'binary', 'padding', 'mime'],
      builder: (context) => const Base64Page(),
    ),
    ToolDefinition(
      id: UrlPage.id,
      name: 'URL Encode/Decode',
      section: ToolSection.devTools,
      description: 'Percent-encode components, full URIs and forms; decode with exact errors; inspect URL parts.',
      icon: Icons.link,
      keywords: const [
        'url',
        'uri',
        'percent',
        'encode',
        'decode',
        'query',
        'querystring',
        'form',
        'urlencode',
        'inspect',
        'parameters',
      ],
      builder: (context) => const UrlPage(),
    ),
    ToolDefinition(
      id: UuidPage.id,
      name: 'UUID',
      section: ToolSection.devTools,
      description: 'Generate v4/v7 UUIDs in bulk and inspect any UUID: version, variant and embedded time.',
      icon: Icons.fingerprint,
      keywords: const ['uuid', 'guid', 'v4', 'v7', 'random', 'id', 'identifier', 'generate', 'unique'],
      builder: (context) => const UuidPage(),
    ),
    ToolDefinition(
      id: TimestampPage.id,
      name: 'Timestamp Converter',
      section: ToolSection.devTools,
      description: 'Live clock and Unix s/ms/us/ns <-> ISO-8601, RFC 2822 and HTTP dates, weeks and relative time.',
      icon: Icons.schedule,
      keywords: const [
        'timestamp',
        'unix',
        'epoch',
        'time',
        'date',
        'iso8601',
        'rfc2822',
        'http date',
        'utc',
        'timezone',
        'milliseconds',
        'ts',
      ],
      builder: (context) => const TimestampPage(),
    ),
    ToolDefinition(
      id: TextStatsPage.id,
      name: 'Text Stats',
      section: ToolSection.devTools,
      description: 'Characters, code points, graphemes, words, lines, bytes and reading time, live as you type.',
      icon: Icons.bar_chart,
      keywords: const ['text', 'stats', 'count', 'words', 'characters', 'lines', 'bytes', 'graphemes', 'wc', 'length'],
      builder: (context) => const TextStatsPage(),
    ),
    ToolDefinition(
      id: JsonEscapePage.id,
      name: 'JSON Escape/Unescape',
      section: ToolSection.devTools,
      description: 'Turn any text into a JSON string literal and back, with precise errors for bad escapes.',
      icon: Icons.data_object,
      keywords: const ['json', 'escape', 'unescape', 'string', 'literal', 'quote', 'unicode', 'stringify'],
      builder: (context) => const JsonEscapePage(),
    ),
    ToolDefinition(
      id: RegexPage.id,
      name: 'Regex Tester',
      section: ToolSection.devTools,
      description: 'Test patterns with flags, highlighted matches, groups and replace preview. Time-limited runs.',
      icon: Icons.pattern,
      keywords: const [
        'regex',
        'regexp',
        'regular expression',
        'pattern',
        'match',
        'replace',
        'groups',
        'test',
        'grep',
      ],
      builder: (context) => const RegexPage(),
    ),
    ToolDefinition(
      id: DiffPage.id,
      name: 'Text Diff',
      section: ToolSection.devTools,
      description: 'Compare two texts or files: unified and side-by-side views, word highlights, patch export.',
      icon: Icons.difference_outlined,
      keywords: const ['diff', 'compare', 'difference', 'patch', 'unified', 'side by side', 'changes', 'merge'],
      builder: (context) => const DiffPage(),
    ),
    ToolDefinition(
      id: HttpPage.id,
      name: 'HTTP Request',
      section: ToolSection.devTools,
      description: 'Send requests to your own dev endpoints: headers, JSON bodies, timing, redacted history.',
      icon: Icons.http,
      keywords: const [
        'http',
        'https',
        'request',
        'rest',
        'api',
        'curl',
        'get',
        'post',
        'headers',
        'json',
        'localhost',
        'postman',
      ],
      requiredCapabilities: const {Capability.networkRequests},
      worksOffline: false,
      builder: (context) => const HttpPage(),
    ),
    ToolDefinition(
      id: CasePage.id,
      name: 'Case Converter',
      section: ToolSection.devTools,
      description: 'camelCase, PascalCase, snake_case, kebab-case, CONSTANT_CASE and more, with smart word splitting.',
      icon: Icons.text_fields,
      keywords: const [
        'case',
        'camel',
        'pascal',
        'snake',
        'kebab',
        'constant',
        'title',
        'upper',
        'lower',
        'rename',
        'identifier',
      ],
      builder: (context) => const CasePage(),
    ),
    ToolDefinition(
      id: NumberBasePage.id,
      name: 'Number Base Converter',
      section: ToolSection.devTools,
      description: "Binary, octal, decimal, hex and any base 2-36; two's complement, bytes and float bits.",
      icon: Icons.calculate_outlined,
      keywords: const [
        'number',
        'base',
        'hex',
        'binary',
        'octal',
        'decimal',
        'radix',
        'twos complement',
        'endian',
        'bytes',
        'float',
      ],
      builder: (context) => const NumberBasePage(),
    ),
    ToolDefinition(
      id: JwtPage.id,
      name: 'JWT Decoder',
      section: ToolSection.devTools,
      description: 'Decode JWT header and claims with expiry badges. Decode only: signatures are not verified.',
      icon: Icons.key_outlined,
      keywords: const ['jwt', 'token', 'jose', 'bearer', 'claims', 'decode', 'oauth', 'exp', 'json web token'],
      builder: (context) => const JwtPage(),
    ),
  ],
  commands: devToolsCommands,
);
