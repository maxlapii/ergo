// ergo — settings window host.
//
// Opens ui/configure.html in a native fullscreen macOS window using only
// osascript's built-in JavaScript (JXA) bridge to AppKit and WebKit.
// Launched by `ergo.sh --configure`; not meant to be run directly.
//
//   osascript -l JavaScript configure.js <configure.html> <ergo.sh> <initial JSON>
//
// The page never touches files itself. Saving, sending a test nudge, and
// refreshing data all go back through ergo.sh, so the same validation and
// atomic writes apply as on the command line.

ObjC.import('Cocoa');
ObjC.import('WebKit');
ObjC.import('stdlib');

var ctx = {
  app: null,
  win: null,
  web: null,
  bridge: null,
  ergo: '',
  projectDir: '',
  savedSummary: '',
  closeRequestedAt: 0,
  shown: false,
  wantFullScreen: $.NSProcessInfo.processInfo.environment.objectForKey('ERGO_WINDOWED').isNil()
};

// ─── Helpers ──────────────────────────────────────────────────────────────

function nsString(data) {
  var s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return s.isNil() ? '' : s.js;
}

function writeStdout(text) {
  if (!text) return;
  var data = $(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(data);
}

function evalInPage(source) {
  ctx.web.evaluateJavaScriptCompletionHandler(source, function () {});
}

// Run ergo.sh with arguments (no shell involved, so nothing needs quoting).
function runErgo(args) {
  var task = $.NSTask.alloc.init;
  var out = $.NSPipe.pipe;
  var err = $.NSPipe.pipe;
  task.launchPath = '/bin/zsh';
  task.arguments = $([ctx.ergo].concat(args));
  task.standardOutput = out;
  task.standardError = err;
  task.launch;
  var stdout = nsString(out.fileHandleForReading.readDataToEndOfFile);
  var stderr = nsString(err.fileHandleForReading.readDataToEndOfFile);
  task.waitUntilExit;
  return { status: task.terminationStatus, stdout: stdout.trim(), stderr: stderr.trim() };
}

function freshData() {
  var r = runErgo(['--status-json']);
  if (r.status !== 0) return null;
  try { return JSON.parse(r.stdout); } catch (e) { return null; }
}

function cleanError(text) {
  return text.split('\n').map(function (line) {
    return line.replace(/^ergo: /, '').replace(/^\s*•\s*/, '• ');
  }).join('\n');
}

function finish() {
  if (ctx.savedSummary) writeStdout(ctx.savedSummary);
  $.exit(0);
}

// ─── Messages from the page ───────────────────────────────────────────────

function handleMessage(raw) {
  var msg;
  try { msg = JSON.parse(raw); } catch (e) { return; }
  var reply = { id: msg.id, ok: true };

  switch (msg.action) {
    case 'save': {
      var r = runErgo(['--apply-config', JSON.stringify(msg.payload || {})]);
      reply.ok = r.status === 0;
      reply.message = reply.ok ? r.stdout : cleanError(r.stderr || 'ergo could not save these settings.');
      if (reply.ok) {
        ctx.savedSummary = r.stdout;
        reply.data = freshData();
      }
      break;
    }
    case 'test': {
      var t = runErgo(['--test']);
      reply.ok = t.status === 0;
      reply.message = reply.ok ? t.stdout : cleanError(t.stderr || 'ergo could not send a nudge.');
      reply.data = freshData();
      break;
    }
    case 'refresh':
      reply.data = freshData();
      break;
    case 'playSound': {
      var sound = $.NSSound.soundNamed('Glass');
      if (!sound.isNil()) sound.play;
      break;
    }
    case 'openLibrary': {
      // Open the cue library in the default text editor.
      var task = $.NSTask.alloc.init;
      task.launchPath = '/usr/bin/open';
      task.arguments = $(['-t', ctx.projectDir + '/nudges.json']);
      task.launch;
      break;
    }
    case 'close':
      finish();
      return;
    default:
      reply.ok = false;
      reply.message = 'Unknown action: ' + msg.action;
  }
  evalInPage('window.ergoReply(' + JSON.stringify(reply) + ')');
}

// ─── Objective-C classes ──────────────────────────────────────────────────

ObjC.registerSubclass({
  name: 'ErgoBridge',
  superclass: 'NSObject',
  methods: {
    // WKScriptMessageHandler: window.webkit.messageHandlers.ergo.postMessage(...)
    'userContentController:didReceiveScriptMessage:': {
      types: ['void', ['id', 'id']],
      implementation: function (controller, message) {
        // Defer slightly so the page can paint its loading state first.
        ctx.bridge.performSelectorWithObjectAfterDelay('handle:', message.body, 0.03);
      }
    },
    'handle:': {
      types: ['void', ['id']],
      implementation: function (body) { handleMessage(ObjC.unwrap(body)); }
    },
    'menuSave:': {
      types: ['void', ['id']],
      implementation: function () { evalInPage('window.ergoSave && window.ergoSave()'); }
    },
    // WKNavigationDelegate: reveal the window only once the page is ready (no white flash).
    'webView:didFinishNavigation:': {
      types: ['void', ['id', 'id']],
      implementation: function () { showWindow(); }
    },
    'webView:didFailProvisionalNavigation:withError:': {
      types: ['void', ['id', 'id', 'id']],
      implementation: function (w, n, error) {
        console.log('ergo: could not load the settings page: ' + error.localizedDescription.js);
        $.exit(1);
      }
    },
    // NSWindowDelegate: route the close button, ⌘W, and ⌘Q through the page,
    // so unsaved changes are never lost silently.
    'windowShouldClose:': {
      types: ['bool', ['id']],
      implementation: function () {
        var now = Date.now();
        if (now - ctx.closeRequestedAt < 1500) return true;   // page not answering: close anyway
        ctx.closeRequestedAt = now;
        evalInPage('window.ergoRequestClose && window.ergoRequestClose()');
        return false;
      }
    },
    'windowDidBecomeKey:': {
      types: ['void', ['id']],
      implementation: function () { enterFullScreen(); }
    },
    'windowDidExitFullScreen:': {
      types: ['void', ['id']],
      implementation: function () { ctx.wantFullScreen = false; }   // respect ⌃⌘F / green button
    },
    'windowWillClose:': {
      types: ['void', ['id']],
      implementation: function () { finish(); }
    }
  }
});

// ─── Window ───────────────────────────────────────────────────────────────

function menuItem(title, action, key, target) {
  var item = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(title, action, key);
  if (target) item.target = target;
  return item;
}

function buildMenu() {
  var bar = $.NSMenu.alloc.init;

  var appItem = $.NSMenuItem.alloc.init;
  var appMenu = $.NSMenu.alloc.initWithTitle('ergo');
  appMenu.addItem(menuItem('Save Changes', 'menuSave:', 's', ctx.bridge));
  appMenu.addItem($.NSMenuItem.separatorItem);
  appMenu.addItem(menuItem('Close Settings', 'performClose:', 'w', null));
  appMenu.addItem(menuItem('Quit ergo Settings', 'performClose:', 'q', null));
  appItem.submenu = appMenu;
  bar.addItem(appItem);

  var editItem = $.NSMenuItem.alloc.init;
  var editMenu = $.NSMenu.alloc.initWithTitle('Edit');
  editMenu.addItem(menuItem('Undo', 'undo:', 'z', null));
  editMenu.addItem($.NSMenuItem.separatorItem);
  editMenu.addItem(menuItem('Cut', 'cut:', 'x', null));
  editMenu.addItem(menuItem('Copy', 'copy:', 'c', null));
  editMenu.addItem(menuItem('Paste', 'paste:', 'v', null));
  editMenu.addItem(menuItem('Select All', 'selectAll:', 'a', null));
  editItem.submenu = editMenu;
  bar.addItem(editItem);

  var viewItem = $.NSMenuItem.alloc.init;
  var viewMenu = $.NSMenu.alloc.initWithTitle('View');
  var fs = menuItem('Toggle Full Screen', 'toggleFullScreen:', 'f', null);
  fs.keyEquivalentModifierMask = $.NSEventModifierFlagCommand | $.NSEventModifierFlagControl;
  viewMenu.addItem(fs);
  viewItem.submenu = viewMenu;
  bar.addItem(viewItem);

  ctx.app.mainMenu = bar;
}

// Dock icon: the ergo mark, drawn natively.
function buildIcon() {
  try {
    var size = 512;
    var img = $.NSImage.alloc.initWithSize($.NSMakeSize(size, size));
    img.lockFocus;
    var rect = $.NSMakeRect(40, 40, size - 80, size - 80);
    var shape = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(rect, 100, 100);
    var top = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.44, 0.94, 0.85, 1);
    var bottom = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.05, 0.61, 0.52, 1);
    $.NSGradient.alloc.initWithStartingColorEndingColor(top, bottom).drawInBezierPathAngle(shape, -60);

    $.NSColor.whiteColor.set;
    var u = (size - 80) / 64, ox = 40, oy = 40;
    function p(x, y) { return $.NSMakePoint(ox + x * u, oy + (64 - y) * u); }   // flip SVG y
    $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(ox + (32 - 5.2) * u, oy + (64 - 16.5 - 5.2) * u, 10.4 * u, 10.4 * u)).fill;
    var figure = $.NSBezierPath.bezierPath;
    figure.moveToPoint(p(19, 19.5)); figure.lineToPoint(p(32, 29)); figure.lineToPoint(p(45, 19.5));
    figure.moveToPoint(p(32, 29)); figure.lineToPoint(p(32, 40.5));
    figure.moveToPoint(p(24.5, 51)); figure.lineToPoint(p(32, 40.5)); figure.lineToPoint(p(39.5, 51));
    figure.lineWidth = 4.2 * u;
    figure.lineCapStyle = $.NSLineCapStyleRound;
    figure.lineJoinStyle = $.NSLineJoinStyleRound;
    figure.stroke;
    img.unlockFocus;
    ctx.app.applicationIconImage = img;
  } catch (e) {
    // Purely cosmetic; the generic icon is fine.
  }
}

function isFullScreen() {
  return (ctx.win.styleMask & $.NSWindowStyleMaskFullScreen) !== 0;
}

function enterFullScreen() {
  if (ctx.wantFullScreen && !isFullScreen()) ctx.win.toggleFullScreen(null);
}

function showWindow() {
  if (ctx.shown) return;
  ctx.shown = true;
  ctx.win.makeKeyAndOrderFront(null);
  ctx.win.orderFrontRegardless;
  // macOS 14+ activation is cooperative and may be declined. If it is, the window
  // still comes forward, and fullscreen starts as soon as it becomes key.
  try { ctx.app.activate; } catch (e) { ctx.app.activateIgnoringOtherApps(true); }
  ctx.win.makeFirstResponder(ctx.web);
  enterFullScreen();
}

function run(argv) {
  if (argv.length < 3) {
    console.log('ergo: open the settings window with: ergo.sh --configure');
    $.exit(2);
  }
  var htmlPath = argv[0];
  ctx.ergo = argv[1];
  ctx.projectDir = ctx.ergo.replace(/\/[^\/]*$/, '');
  var initialJSON = argv[2];

  ctx.app = $.NSApplication.sharedApplication;
  ctx.app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
  ctx.bridge = $.ErgoBridge.alloc.init;
  buildMenu();
  buildIcon();

  var screen = $.NSScreen.mainScreen;
  var frame = screen.visibleFrame;
  var mask = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable |
             $.NSWindowStyleMaskResizable | $.NSWindowStyleMaskFullSizeContentView;
  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(frame, mask, $.NSBackingStoreBuffered, false);
  win.title = 'ergo Settings';
  win.titlebarAppearsTransparent = true;
  win.titleVisibility = $.NSWindowTitleHidden;
  win.releasedWhenClosed = false;
  win.restorable = false;
  win.minSize = $.NSMakeSize(900, 640);
  win.collectionBehavior = $.NSWindowCollectionBehaviorFullScreenPrimary;
  var dark = ctx.app.effectiveAppearance.name.js.indexOf('Dark') !== -1;
  win.backgroundColor = dark
    ? $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.035, 0.055, 0.067, 1)
    : $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.949, 0.961, 0.957, 1);
  win.delegate = ctx.bridge;
  ctx.win = win;

  var content = $.WKUserContentController.alloc.init;
  content.addScriptMessageHandlerName(ctx.bridge, 'ergo');
  content.addUserScript($.WKUserScript.alloc.initWithSourceInjectionTimeForMainFrameOnly(
    'window.ERGO_DATA = ' + initialJSON + ';', $.WKUserScriptInjectionTimeAtDocumentStart, true));
  var config = $.WKWebViewConfiguration.alloc.init;
  config.userContentController = content;

  var web = $.WKWebView.alloc.initWithFrameConfiguration(win.contentView.bounds, config);
  web.autoresizingMask = $.NSViewWidthSizable | $.NSViewHeightSizable;
  web.setValueForKey($.NSNumber.numberWithBool(false), 'drawsBackground');
  web.navigationDelegate = ctx.bridge;
  win.contentView.addSubview(web);
  ctx.web = web;

  var pageURL = $.NSURL.fileURLWithPath(htmlPath);
  web.loadFileURLAllowingReadAccessToURL(pageURL, pageURL.URLByDeletingLastPathComponent);

  ctx.app.run;
}
