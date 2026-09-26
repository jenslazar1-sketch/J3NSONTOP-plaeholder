import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/features/shell/app_shell.dart';
import 'package:j3nsontop_multitool/features/shell/destinations.dart';

void main() {
  int? tab(String location, [ToolSection? section]) => bottomNavIndexFor(location, destinationFor(location, section));

  test('each phone tab highlights its own pages', () {
    expect(tab('/'), 0);
    expect(tab('/workspaces'), 1);
    expect(tab('/mods'), 2);
    expect(tab('/tools'), 3);
    expect(tab('/tools?q=hash'), 3);
    expect(tab('/activity'), 4);
  });

  test('tools and sections without a tab highlight Tools; their own section otherwise', () {
    expect(tab('/config'), 3);
    expect(tab('/dev'), 3);
    expect(tab('/tool/config.json', ToolSection.configLab), 3);
    expect(tab('/tool/system.terminal', ToolSection.system), 3);
    expect(tab('/tool/workspaces.search', ToolSection.workspaces), 1);
    expect(tab('/tool/mods.manager', ToolSection.mods), 2);
  });

  test('Settings and About highlight no tab', () {
    expect(tab('/settings'), isNull);
    expect(tab('/about'), isNull);
  });
}
