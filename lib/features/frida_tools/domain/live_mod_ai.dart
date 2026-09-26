import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'frida_service.dart';

enum AiModAction { scan, hook, modify, watch, analyze }

class AiModRequest {
  const AiModRequest({required this.action, required this.description, this.target, this.value});
  final AiModAction action;
  final String description;
  final String? target;
  final String? value;
}

class AiModResult {
  const AiModResult({required this.script, required this.description, this.preview});
  final String script;
  final String description;
  final String? preview;
}

class LiveModSession {
  LiveModSession({required this.processName, this.device});

  final String processName;
  final String? device;
  final List<AiModResult> appliedMods = [];
  final List<String> discoveredClasses = [];
  final List<String> discoveredModules = [];
  final List<String> log = [];

  bool _scanning = false;
  bool get isScanning => _scanning;

  String generateScanScript() {
    return '''
// J3NSONTOP AI Scanner — cataloging game internals
send({type: 'ai_scan', phase: 'start'});

var modules = Process.enumerateModules();
modules.forEach(function(m) {
  send({type: 'ai_module', name: m.name, base: m.base.toString(), size: m.size});
});

if (Java.available) {
  Java.perform(function() {
    var classCount = 0;
    Java.enumerateLoadedClasses({
      onMatch: function(name) {
        classCount++;
        // Send interesting game classes
        if (name.indexOf('Player') !== -1 || name.indexOf('Game') !== -1 ||
            name.indexOf('Score') !== -1 || name.indexOf('Health') !== -1 ||
            name.indexOf('Currency') !== -1 || name.indexOf('Coin') !== -1 ||
            name.indexOf('Money') !== -1 || name.indexOf('Gem') !== -1 ||
            name.indexOf('Level') !== -1 || name.indexOf('Shop') !== -1 ||
            name.indexOf('Inventory') !== -1 || name.indexOf('Item') !== -1 ||
            name.indexOf('Weapon') !== -1 || name.indexOf('Damage') !== -1 ||
            name.indexOf('Speed') !== -1 || name.indexOf('Config') !== -1 ||
            name.indexOf('Manager') !== -1 || name.indexOf('Controller') !== -1 ||
            name.indexOf('Data') !== -1 || name.indexOf('Save') !== -1 ||
            name.indexOf('Reward') !== -1 || name.indexOf('Ad') !== -1) {
          send({type: 'ai_class', name: name});
        }
      },
      onComplete: function() {
        send({type: 'ai_scan', phase: 'done', total_classes: classCount});
      }
    });
  });
} else if (ObjC.available) {
  var classes = Object.keys(ObjC.classes);
  var interesting = classes.filter(function(name) {
    return name.match(/(Player|Game|Score|Health|Currency|Coin|Money|Level|Shop|Inventory|Item|Weapon)/i);
  });
  interesting.forEach(function(name) {
    send({type: 'ai_class', name: name});
  });
  send({type: 'ai_scan', phase: 'done', total_classes: classes.length});
}
''';
  }

  String generateModScript(AiModRequest request) {
    switch (request.action) {
      case AiModAction.scan:
        return generateScanScript();
      case AiModAction.hook:
        return _generateHookScript(request);
      case AiModAction.modify:
        return _generateModifyScript(request);
      case AiModAction.watch:
        return _generateWatchScript(request);
      case AiModAction.analyze:
        return _generateAnalyzeScript(request);
    }
  }

  String _generateHookScript(AiModRequest request) {
    final target = request.target ?? '';
    return '''
// AI-generated hook for: ${request.description}
if (Java.available) {
  Java.perform(function() {
    try {
      var clz = Java.use("$target");
      var methods = clz.class.getDeclaredMethods();
      methods.forEach(function(m) {
        var name = m.getName();
        try {
          clz[name].overloads.forEach(function(overload) {
            overload.implementation = function() {
              var args = Array.prototype.slice.call(arguments);
              send({type: 'ai_hook', class: "$target", method: name, args: args.map(String)});
              var ret = this[name].apply(this, arguments);
              send({type: 'ai_return', method: name, value: String(ret)});
              return ret;
            };
          });
        } catch(e) {}
      });
      send({type: 'ai_hooked', class: "$target"});
    } catch(e) {
      send({type: 'ai_error', message: String(e)});
    }
  });
}
''';
  }

  String _generateModifyScript(AiModRequest request) {
    final target = request.target ?? '';
    final value = request.value ?? '999999';
    return '''
// AI-generated modifier for: ${request.description}
// Target: $target → $value
if (Java.available) {
  Java.perform(function() {
    try {
      var parts = "$target".split(".");
      var methodName = parts.pop();
      var className = parts.join(".");
      var clz = Java.use(className);

      // Try to hook getter/setter patterns
      var getterNames = ["get" + methodName, methodName, "is" + methodName];
      getterNames.forEach(function(getter) {
        try {
          clz[getter].overloads.forEach(function(overload) {
            overload.implementation = function() {
              send({type: 'ai_mod', method: getter, original: 'intercepted', modified: '$value'});
              return $value;
            };
          });
          send({type: 'ai_modded', method: getter, value: '$value'});
        } catch(e) {}
      });
    } catch(e) {
      send({type: 'ai_error', message: String(e)});
    }
  });
}
''';
  }

  String _generateWatchScript(AiModRequest request) {
    final target = request.target ?? '';
    return '''
// AI-generated watcher for: ${request.description}
setInterval(function() {
  if (Java.available) {
    Java.perform(function() {
      try {
        var clz = Java.use("$target");
        send({type: 'ai_watch', class: "$target", timestamp: Date.now()});
      } catch(e) {}
    });
  }
}, 1000);
send({type: 'ai_watching', target: "$target"});
''';
  }

  String _generateAnalyzeScript(AiModRequest request) {
    final target = request.target ?? '';
    return '''
// AI-generated analyzer for: ${request.description}
if (Java.available) {
  Java.perform(function() {
    try {
      var clz = Java.use("$target");
      var fields = clz.class.getDeclaredFields();
      fields.forEach(function(f) {
        f.setAccessible(true);
        send({type: 'ai_field', class: "$target", name: f.getName(), type: f.getType().getName()});
      });
      var methods = clz.class.getDeclaredMethods();
      methods.forEach(function(m) {
        send({type: 'ai_method', class: "$target", name: m.getName(),
              returnType: m.getReturnType().getName(),
              params: m.getParameterTypes().map(function(p) { return p.getName(); })});
      });
      send({type: 'ai_analyzed', class: "$target", fields: fields.length, methods: methods.length});
    } catch(e) {
      send({type: 'ai_error', message: String(e)});
    }
  });
}
''';
  }
}

class LiveModState {
  const LiveModState({this.session, this.output = const [], this.isRunning = false, this.discoveredClasses = const [], this.discoveredModules = const []});
  final LiveModSession? session;
  final List<String> output;
  final bool isRunning;
  final List<String> discoveredClasses;
  final List<String> discoveredModules;

  LiveModState copyWith({LiveModSession? session, List<String>? output, bool? isRunning, List<String>? discoveredClasses, List<String>? discoveredModules}) {
    return LiveModState(
      session: session ?? this.session,
      output: output ?? this.output,
      isRunning: isRunning ?? this.isRunning,
      discoveredClasses: discoveredClasses ?? this.discoveredClasses,
      discoveredModules: discoveredModules ?? this.discoveredModules,
    );
  }
}

class LiveModController extends Notifier<LiveModState> {
  @override
  LiveModState build() => const LiveModState();

  void startSession(String processName, {String? device}) {
    state = LiveModState(session: LiveModSession(processName: processName, device: device));
  }

  void addOutput(String line) {
    state = state.copyWith(output: [...state.output, line]);
  }

  void clearOutput() {
    state = state.copyWith(output: []);
  }

  void setRunning(bool running) {
    state = state.copyWith(isRunning: running);
  }

  void addDiscoveredClass(String className) {
    if (!state.discoveredClasses.contains(className)) {
      state = state.copyWith(discoveredClasses: [...state.discoveredClasses, className]);
    }
  }

  void addDiscoveredModule(String module) {
    if (!state.discoveredModules.contains(module)) {
      state = state.copyWith(discoveredModules: [...state.discoveredModules, module]);
    }
  }

  void endSession() {
    state = const LiveModState();
  }
}

final liveModProvider = NotifierProvider<LiveModController, LiveModState>(LiveModController.new);
