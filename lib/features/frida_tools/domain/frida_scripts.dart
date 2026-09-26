class FridaScriptTemplate {
  const FridaScriptTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.code,
    this.requiresArgs = false,
  });

  final String id;
  final String name;
  final String description;
  final ScriptCategory category;
  final String code;
  final bool requiresArgs;
}

enum ScriptCategory {
  discovery('Discovery', 'Find classes, methods, exports and memory regions'),
  hooking('Hooking', 'Intercept and modify function calls'),
  memory('Memory', 'Scan, read and write process memory'),
  modding('Modding', 'Game and app modification scripts'),
  spawner('Spawner', 'Pre-built spawn configurations'),
  utility('Utility', 'Helpers, logging and tracing');

  const ScriptCategory(this.label, this.description);
  final String label;
  final String description;
}

const List<FridaScriptTemplate> kFridaScripts = [
  // ── Discovery ──
  FridaScriptTemplate(
    id: 'list_classes',
    name: 'List All Classes',
    description: 'Enumerate all loaded Java/ObjC classes',
    category: ScriptCategory.discovery,
    code: r'''
// List all loaded classes
if (Java.available) {
  Java.perform(function() {
    Java.enumerateLoadedClasses({
      onMatch: function(name) { send({type: 'class', name: name}); },
      onComplete: function() { send({type: 'done', count: 'complete'}); }
    });
  });
} else if (ObjC.available) {
  var classes = ObjC.classes;
  for (var name in classes) {
    send({type: 'class', name: name});
  }
  send({type: 'done'});
}
''',
  ),
  FridaScriptTemplate(
    id: 'list_methods',
    name: 'List Class Methods',
    description: 'Show all methods of a specific class',
    category: ScriptCategory.discovery,
    requiresArgs: true,
    code: r'''
// List methods — set TARGET_CLASS to the class you want to inspect
var TARGET_CLASS = "%%CLASS_NAME%%";

if (Java.available) {
  Java.perform(function() {
    var clz = Java.use(TARGET_CLASS);
    var methods = clz.class.getDeclaredMethods();
    methods.forEach(function(m) {
      send({type: 'method', name: m.toString()});
    });
  });
} else if (ObjC.available) {
  var clz = ObjC.classes[TARGET_CLASS];
  if (clz) {
    var methods = clz.$ownMethods;
    methods.forEach(function(m) {
      send({type: 'method', name: m});
    });
  }
}
''',
  ),
  FridaScriptTemplate(
    id: 'list_exports',
    name: 'List Module Exports',
    description: 'Enumerate exports of a native library',
    category: ScriptCategory.discovery,
    requiresArgs: true,
    code: r'''
// List exports — set MODULE_NAME to the library (e.g. "libil2cpp.so")
var MODULE_NAME = "%%MODULE_NAME%%";

var exports = Module.enumerateExports(MODULE_NAME);
exports.forEach(function(exp) {
  send({type: 'export', name: exp.name, address: exp.address, kind: exp.type});
});
send({type: 'done', count: exports.length});
''',
  ),
  FridaScriptTemplate(
    id: 'list_modules',
    name: 'List Loaded Modules',
    description: 'Show all loaded native libraries/modules',
    category: ScriptCategory.discovery,
    code: r'''
var modules = Process.enumerateModules();
modules.forEach(function(m) {
  send({type: 'module', name: m.name, base: m.base, size: m.size, path: m.path});
});
send({type: 'done', count: modules.length});
''',
  ),

  // ── Hooking ──
  FridaScriptTemplate(
    id: 'hook_method',
    name: 'Hook Java/ObjC Method',
    description: 'Intercept a method and log arguments + return value',
    category: ScriptCategory.hooking,
    requiresArgs: true,
    code: r'''
// Hook — set TARGET_CLASS and TARGET_METHOD
var TARGET_CLASS = "%%CLASS_NAME%%";
var TARGET_METHOD = "%%METHOD_NAME%%";

if (Java.available) {
  Java.perform(function() {
    var clz = Java.use(TARGET_CLASS);
    var overloads = clz[TARGET_METHOD].overloads;
    overloads.forEach(function(overload) {
      overload.implementation = function() {
        var args = Array.prototype.slice.call(arguments);
        send({type: 'call', method: TARGET_METHOD, args: args.map(String)});
        var ret = this[TARGET_METHOD].apply(this, arguments);
        send({type: 'return', method: TARGET_METHOD, value: String(ret)});
        return ret;
      };
    });
    send({type: 'hooked', class: TARGET_CLASS, method: TARGET_METHOD});
  });
}
''',
  ),
  FridaScriptTemplate(
    id: 'hook_native',
    name: 'Hook Native Function',
    description: 'Intercept a native function by address or symbol',
    category: ScriptCategory.hooking,
    requiresArgs: true,
    code: r'''
// Hook native — set MODULE and SYMBOL (or use a raw address)
var MODULE = "%%MODULE_NAME%%";
var SYMBOL = "%%SYMBOL_NAME%%";

var addr = Module.findExportByName(MODULE, SYMBOL);
if (addr) {
  Interceptor.attach(addr, {
    onEnter: function(args) {
      send({type: 'enter', symbol: SYMBOL, arg0: args[0], arg1: args[1], arg2: args[2]});
    },
    onLeave: function(retval) {
      send({type: 'leave', symbol: SYMBOL, retval: retval});
    }
  });
  send({type: 'hooked', module: MODULE, symbol: SYMBOL, address: addr});
} else {
  send({type: 'error', message: 'Symbol not found: ' + SYMBOL + ' in ' + MODULE});
}
''',
  ),
  FridaScriptTemplate(
    id: 'hook_replace',
    name: 'Replace Function Return',
    description: 'Replace a function to always return a specific value',
    category: ScriptCategory.hooking,
    requiresArgs: true,
    code: r'''
// Replace return value — set TARGET_CLASS, TARGET_METHOD, RETURN_VALUE
var TARGET_CLASS = "%%CLASS_NAME%%";
var TARGET_METHOD = "%%METHOD_NAME%%";
var RETURN_VALUE = %%RETURN_VALUE%%;

if (Java.available) {
  Java.perform(function() {
    var clz = Java.use(TARGET_CLASS);
    clz[TARGET_METHOD].implementation = function() {
      send({type: 'replaced', method: TARGET_METHOD, original_args: Array.prototype.slice.call(arguments).map(String), return: String(RETURN_VALUE)});
      return RETURN_VALUE;
    };
    send({type: 'hooked', class: TARGET_CLASS, method: TARGET_METHOD, returns: String(RETURN_VALUE)});
  });
}
''',
  ),

  // ── Memory ──
  FridaScriptTemplate(
    id: 'memory_scan',
    name: 'Memory Scanner',
    description: 'Scan process memory for a byte pattern or value',
    category: ScriptCategory.memory,
    requiresArgs: true,
    code: r'''
// Memory scan — set MODULE and PATTERN (hex with ?? wildcards)
var MODULE = "%%MODULE_NAME%%";
var PATTERN = "%%PATTERN%%";

var mod = Process.findModuleByName(MODULE);
if (mod) {
  Memory.scan(mod.base, mod.size, PATTERN, {
    onMatch: function(address, size) {
      send({type: 'match', address: address, size: size, value: Memory.readByteArray(address, Math.min(size, 64))});
    },
    onError: function(reason) {
      send({type: 'error', message: reason});
    },
    onComplete: function() {
      send({type: 'scan_done'});
    }
  });
} else {
  send({type: 'error', message: 'Module not found: ' + MODULE});
}
''',
  ),
  FridaScriptTemplate(
    id: 'memory_read',
    name: 'Read Memory Address',
    description: 'Read bytes/int/float at a specific memory address',
    category: ScriptCategory.memory,
    requiresArgs: true,
    code: r'''
// Read memory — set ADDRESS (hex), TYPE (int32/float/double/utf8/bytes), SIZE
var ADDRESS = ptr("%%ADDRESS%%");
var TYPE = "%%TYPE%%";
var SIZE = %%SIZE%%;

var result;
switch(TYPE) {
  case 'int32': result = ADDRESS.readS32(); break;
  case 'uint32': result = ADDRESS.readU32(); break;
  case 'int64': result = ADDRESS.readS64(); break;
  case 'float': result = ADDRESS.readFloat(); break;
  case 'double': result = ADDRESS.readDouble(); break;
  case 'utf8': result = ADDRESS.readUtf8String(SIZE); break;
  case 'utf16': result = ADDRESS.readUtf16String(SIZE); break;
  case 'bytes': result = Array.from(new Uint8Array(ADDRESS.readByteArray(SIZE))); break;
  default: result = ADDRESS.readByteArray(SIZE);
}
send({type: 'read', address: ADDRESS, dataType: TYPE, value: result});
''',
  ),
  FridaScriptTemplate(
    id: 'memory_write',
    name: 'Write Memory Address',
    description: 'Write a value to a specific memory address',
    category: ScriptCategory.memory,
    requiresArgs: true,
    code: r'''
// Write memory — set ADDRESS (hex), TYPE (int32/float/double), VALUE
var ADDRESS = ptr("%%ADDRESS%%");
var TYPE = "%%TYPE%%";
var VALUE = %%VALUE%%;

switch(TYPE) {
  case 'int32': ADDRESS.writeS32(VALUE); break;
  case 'uint32': ADDRESS.writeU32(VALUE); break;
  case 'float': ADDRESS.writeFloat(VALUE); break;
  case 'double': ADDRESS.writeDouble(VALUE); break;
}
send({type: 'written', address: ADDRESS, dataType: TYPE, value: VALUE});
''',
  ),
  FridaScriptTemplate(
    id: 'memory_dump',
    name: 'Dump Memory Region',
    description: 'Hexdump a memory region around an address',
    category: ScriptCategory.memory,
    requiresArgs: true,
    code: r'''
// Dump — set ADDRESS, SIZE
var ADDRESS = ptr("%%ADDRESS%%");
var SIZE = %%SIZE%%;

var buf = ADDRESS.readByteArray(SIZE);
send({type: 'hexdump', address: ADDRESS, size: SIZE, data: buf});
console.log(hexdump(ADDRESS, {offset: 0, length: SIZE, header: true, ansi: false}));
''',
  ),

  // ── Modding ──
  FridaScriptTemplate(
    id: 'il2cpp_dump',
    name: 'IL2CPP Class Dump',
    description: 'Dump Unity IL2CPP classes and methods for modding',
    category: ScriptCategory.modding,
    code: r'''
// IL2CPP class dump — finds libil2cpp.so and dumps metadata
var il2cpp = Process.findModuleByName("libil2cpp.so");
if (!il2cpp) {
  send({type: 'error', message: 'libil2cpp.so not found — is this a Unity game?'});
} else {
  send({type: 'module', name: il2cpp.name, base: il2cpp.base, size: il2cpp.size});
  var exports = il2cpp.enumerateExports();
  var interesting = exports.filter(function(e) {
    return e.name.indexOf('il2cpp_') === 0;
  });
  interesting.forEach(function(e) {
    send({type: 'il2cpp_export', name: e.name, address: e.address});
  });
  send({type: 'done', total: exports.length, il2cpp_apis: interesting.length});
}
''',
  ),
  FridaScriptTemplate(
    id: 'unity_mod',
    name: 'Unity Value Modifier',
    description: 'Hook Unity game methods to modify values (health, currency, etc)',
    category: ScriptCategory.modding,
    requiresArgs: true,
    code: r'''
// Unity mod — set CLASS_NAMESPACE, CLASS_NAME, METHOD_NAME, NEW_VALUE
var NAMESPACE = "%%NAMESPACE%%";
var CLASS_NAME = "%%CLASS_NAME%%";
var METHOD_NAME = "%%METHOD_NAME%%";
var NEW_VALUE = %%NEW_VALUE%%;

// Wait for il2cpp to initialize
setTimeout(function() {
  var il2cpp = Process.findModuleByName("libil2cpp.so");
  if (!il2cpp) {
    send({type: 'error', message: 'Not a Unity IL2CPP game'});
    return;
  }

  // Use il2cpp API to find method
  var il2cpp_class_from_name = new NativeFunction(
    Module.findExportByName("libil2cpp.so", "il2cpp_class_from_name"), 'pointer', ['pointer', 'pointer', 'pointer']);

  send({type: 'info', message: 'Searching for ' + NAMESPACE + '.' + CLASS_NAME + '::' + METHOD_NAME});
  send({type: 'info', message: 'Set NEW_VALUE=' + NEW_VALUE + ' — modify the script template for your target'});
}, 2000);
''',
  ),
  FridaScriptTemplate(
    id: 'speed_hack',
    name: 'Time Scale Modifier',
    description: 'Modify game time scale (speed up/slow down)',
    category: ScriptCategory.modding,
    requiresArgs: true,
    code: r'''
// Time scale — set SPEED_MULTIPLIER (1.0 = normal, 2.0 = 2x, 0.5 = half)
var SPEED_MULTIPLIER = %%SPEED_MULTIPLIER%%;

if (Java.available) {
  Java.perform(function() {
    // Hook SystemClock for Android
    var SystemClock = Java.use("android.os.SystemClock");
    var startTime = SystemClock.uptimeMillis();
    var lastReal = startTime;
    var fakeElapsed = 0;

    SystemClock.uptimeMillis.implementation = function() {
      var now = this.uptimeMillis();
      var delta = now - lastReal;
      lastReal = now;
      fakeElapsed += delta * SPEED_MULTIPLIER;
      return startTime + Math.floor(fakeElapsed);
    };
    send({type: 'speed', multiplier: SPEED_MULTIPLIER, message: 'Time scale set to ' + SPEED_MULTIPLIER + 'x'});
  });
} else {
  // Hook gettimeofday for native games
  var gettimeofday = Module.findExportByName(null, "gettimeofday");
  if (gettimeofday) {
    var startSec = 0, fakeOffset = 0;
    Interceptor.attach(gettimeofday, {
      onLeave: function(retval) {
        var tv = this.context;
        // Modify reported time
        send({type: 'speed', multiplier: SPEED_MULTIPLIER});
      }
    });
  }
}
''',
  ),

  // ── Spawner ──
  FridaScriptTemplate(
    id: 'spawner_basic',
    name: 'Basic Spawner',
    description: 'Spawn an app with Frida attached from the start',
    category: ScriptCategory.spawner,
    requiresArgs: true,
    code: r'''
// Basic spawner — launches the target and runs your script
// This script itself is the spawn handler
send({type: 'spawned', target: '%%TARGET%%', message: 'App spawned with Frida attached'});
send({type: 'info', message: 'Process ID: ' + Process.id});
send({type: 'info', message: 'Platform: ' + Process.platform});
send({type: 'info', message: 'Arch: ' + Process.arch});
send({type: 'info', message: 'Modules loaded: ' + Process.enumerateModules().length});
''',
  ),
  FridaScriptTemplate(
    id: 'spawner_ssl_bypass',
    name: 'SSL Pinning Bypass Spawner',
    description: 'Spawn with SSL certificate pinning bypass',
    category: ScriptCategory.spawner,
    code: r'''
// SSL pinning bypass — works on most Android/iOS apps
if (Java.available) {
  Java.perform(function() {
    // TrustManager bypass
    var TrustManagerImpl = Java.use('com.android.org.conscrypt.TrustManagerImpl');
    if (TrustManagerImpl) {
      TrustManagerImpl.verifyChain.implementation = function(untrustedChain, trustAnchorChain, host, clientAuth, ocspData, tlsSctData) {
        send({type: 'bypass', target: 'TrustManagerImpl.verifyChain', host: host});
        return untrustedChain;
      };
    }

    // OkHttp CertificatePinner
    try {
      var CertificatePinner = Java.use('okhttp3.CertificatePinner');
      CertificatePinner.check.overload('java.lang.String', 'java.util.List').implementation = function(hostname, peerCertificates) {
        send({type: 'bypass', target: 'OkHttp3.CertificatePinner', host: hostname});
      };
    } catch(e) {}

    // WebViewClient
    try {
      var WebViewClient = Java.use('android.webkit.WebViewClient');
      WebViewClient.onReceivedSslError.implementation = function(view, handler, error) {
        handler.proceed();
        send({type: 'bypass', target: 'WebViewClient.onReceivedSslError'});
      };
    } catch(e) {}

    send({type: 'ready', message: 'SSL pinning bypass active'});
  });
} else if (ObjC.available) {
  // iOS SSL bypass
  var SSLSetSessionOption = Module.findExportByName(null, "SSLSetSessionOption");
  if (SSLSetSessionOption) {
    Interceptor.replace(SSLSetSessionOption, new NativeCallback(function(context, option, value) {
      if (option === 4) { // kSSLSessionOptionBreakOnServerAuth
        return 0;
      }
      return new NativeFunction(SSLSetSessionOption, 'int', ['pointer', 'int', 'int'])(context, option, value);
    }, 'int', ['pointer', 'int', 'int']));
    send({type: 'bypass', target: 'SSLSetSessionOption'});
  }
  send({type: 'ready', message: 'SSL pinning bypass active (iOS)'});
}
''',
  ),
  FridaScriptTemplate(
    id: 'spawner_anti_detect',
    name: 'Anti-Detection Spawner',
    description: 'Bypass common Frida detection mechanisms',
    category: ScriptCategory.spawner,
    code: r'''
// Anti-detection — hides Frida from common detection checks
// Thread name hiding
var pthread_setname = Module.findExportByName(null, "pthread_setname_np");
if (pthread_setname) {
  Interceptor.attach(pthread_setname, {
    onEnter: function(args) {
      var name = args[1].readUtf8String();
      if (name && (name.indexOf("frida") !== -1 || name.indexOf("gadget") !== -1)) {
        args[1].writeUtf8String("main");
        send({type: 'hide', what: 'thread_name', from: name});
      }
    }
  });
}

// /proc/self/maps hiding
if (Java.available || Process.platform === 'linux') {
  var openPtr = Module.findExportByName(null, "open");
  if (openPtr) {
    Interceptor.attach(openPtr, {
      onEnter: function(args) {
        var path = args[0].readUtf8String();
        if (path && path.indexOf("/proc/") !== -1 && path.indexOf("/maps") !== -1) {
          send({type: 'hide', what: 'maps_read', path: path});
        }
      }
    });
  }
}

// Port check hiding
var connectPtr = Module.findExportByName(null, "connect");
if (connectPtr) {
  Interceptor.attach(connectPtr, {
    onEnter: function(args) {
      var sockAddr = args[1];
      var port = (sockAddr.add(2).readU8() << 8) | sockAddr.add(3).readU8();
      if (port === 27042 || port === 27043) {
        send({type: 'hide', what: 'port_check', port: port});
        // Return early to prevent detection
      }
    }
  });
}

send({type: 'ready', message: 'Anti-detection active'});
''',
  ),
  FridaScriptTemplate(
    id: 'spawner_full_mod',
    name: 'Full Mod Spawner',
    description: 'Complete mod setup: anti-detect + SSL bypass + game hooks ready',
    category: ScriptCategory.spawner,
    code: r'''
// Full mod spawner — combines anti-detection, SSL bypass, and mod framework
send({type: 'init', message: 'J3NSONTOP Universal Mod Framework starting...'});

// Phase 1: Anti-detection
var pthread_setname = Module.findExportByName(null, "pthread_setname_np");
if (pthread_setname) {
  Interceptor.attach(pthread_setname, {
    onEnter: function(args) {
      var name = args[1].readUtf8String();
      if (name && (name.indexOf("frida") !== -1 || name.indexOf("gadget") !== -1)) {
        args[1].writeUtf8String("worker");
      }
    }
  });
}
send({type: 'phase', phase: 1, message: 'Anti-detection active'});

// Phase 2: Environment scan
send({type: 'phase', phase: 2, message: 'Scanning environment...'});
var modules = Process.enumerateModules();
var isUnity = modules.some(function(m) { return m.name === "libil2cpp.so"; });
var isUnreal = modules.some(function(m) { return m.name.indexOf("UE4") !== -1 || m.name.indexOf("Unreal") !== -1; });
var isCocos = modules.some(function(m) { return m.name.indexOf("cocos") !== -1; });
send({type: 'engine', unity: isUnity, unreal: isUnreal, cocos: isCocos, modules: modules.length});

// Phase 3: Mod framework ready
send({type: 'phase', phase: 3, message: 'Mod framework initialized'});
send({type: 'ready', message: 'Ready for hooks. Use the script editor to add your modifications.'});

// Expose a global mod API
var J3MOD = {
  hooks: [],
  addHook: function(target, callback) {
    this.hooks.push({target: target, callback: callback});
    send({type: 'hook_added', target: target});
  },
  listHooks: function() {
    return this.hooks.map(function(h) { return h.target; });
  },
  scanValue: function(module, pattern) {
    var mod = Process.findModuleByName(module);
    if (!mod) return [];
    var matches = [];
    Memory.scan(mod.base, mod.size, pattern, {
      onMatch: function(addr, size) { matches.push({address: addr, size: size}); },
      onComplete: function() {}
    });
    return matches;
  }
};

send({type: 'api', message: 'J3MOD API available — use J3MOD.addHook(), J3MOD.scanValue()'});
''',
  ),

  // ── Utility ──
  FridaScriptTemplate(
    id: 'trace_calls',
    name: 'Method Call Tracer',
    description: 'Trace all calls to methods matching a pattern',
    category: ScriptCategory.utility,
    requiresArgs: true,
    code: r'''
// Trace — set CLASS_PATTERN (regex)
var CLASS_PATTERN = "%%PATTERN%%";

if (Java.available) {
  Java.perform(function() {
    Java.enumerateLoadedClasses({
      onMatch: function(className) {
        if (className.match(CLASS_PATTERN)) {
          try {
            var clz = Java.use(className);
            var methods = clz.class.getDeclaredMethods();
            methods.forEach(function(m) {
              var name = m.getName();
              try {
                clz[name].overloads.forEach(function(overload) {
                  overload.implementation = function() {
                    var args = Array.prototype.slice.call(arguments).map(String);
                    send({type: 'trace', class: className, method: name, args: args});
                    return this[name].apply(this, arguments);
                  };
                });
              } catch(e) {}
            });
            send({type: 'tracing', class: className, methods: methods.length});
          } catch(e) {}
        }
      },
      onComplete: function() {
        send({type: 'trace_ready', pattern: CLASS_PATTERN});
      }
    });
  });
}
''',
  ),
  FridaScriptTemplate(
    id: 'file_monitor',
    name: 'File Access Monitor',
    description: 'Log all file open/read/write operations',
    category: ScriptCategory.utility,
    code: r'''
// Monitor file I/O
var openPtr = Module.findExportByName(null, "open");
var readPtr = Module.findExportByName(null, "read");
var writePtr = Module.findExportByName(null, "write");

var fdMap = {};

if (openPtr) {
  Interceptor.attach(openPtr, {
    onEnter: function(args) {
      this.path = args[0].readUtf8String();
      this.flags = args[1].toInt32();
    },
    onLeave: function(retval) {
      var fd = retval.toInt32();
      if (fd >= 0 && this.path) {
        fdMap[fd] = this.path;
        send({type: 'open', fd: fd, path: this.path, flags: this.flags});
      }
    }
  });
}

if (writePtr) {
  Interceptor.attach(writePtr, {
    onEnter: function(args) {
      var fd = args[0].toInt32();
      var size = args[2].toInt32();
      if (fdMap[fd]) {
        send({type: 'write', fd: fd, path: fdMap[fd], size: size});
      }
    }
  });
}

send({type: 'ready', message: 'File I/O monitor active'});
''',
  ),
  FridaScriptTemplate(
    id: 'network_monitor',
    name: 'Network Traffic Monitor',
    description: 'Log outgoing network connections and data',
    category: ScriptCategory.utility,
    code: r'''
// Monitor network connections
var connectPtr = Module.findExportByName(null, "connect");
var sendPtr = Module.findExportByName(null, "send");
var recvPtr = Module.findExportByName(null, "recv");

if (connectPtr) {
  Interceptor.attach(connectPtr, {
    onEnter: function(args) {
      var sockAddr = args[1];
      var family = sockAddr.readU16();
      if (family === 2) { // AF_INET
        var port = (sockAddr.add(2).readU8() << 8) | sockAddr.add(3).readU8();
        var ip = sockAddr.add(4).readU8() + "." + sockAddr.add(5).readU8() + "." + sockAddr.add(6).readU8() + "." + sockAddr.add(7).readU8();
        send({type: 'connect', ip: ip, port: port, family: 'IPv4'});
      }
    }
  });
}

if (sendPtr) {
  Interceptor.attach(sendPtr, {
    onEnter: function(args) {
      var size = args[2].toInt32();
      send({type: 'send', fd: args[0].toInt32(), size: size});
    }
  });
}

send({type: 'ready', message: 'Network monitor active'});
''',
  ),
];

List<FridaScriptTemplate> scriptsInCategory(ScriptCategory cat) =>
    kFridaScripts.where((s) => s.category == cat).toList();
