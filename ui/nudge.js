// ergo — fullscreen break host.
//
// Shows ui/nudge.html as a calm, blurred overlay across every display, using only
// osascript's built-in JavaScript (JXA) bridge to AppKit and WebKit.
// Launched by ergo.sh when a nudge is due; not meant to be run directly.
//
//   osascript -l JavaScript nudge.js <nudge.html> <break JSON>
//
// Prints one JSON line when the break ends and exits 0:
//   {"outcome": "completed" | "ready" | "skipped" | "timeout", "seconds": 15}
// Any other exit means the break could not be shown; ergo.sh then falls back to a
// regular notification.

ObjC.import('Cocoa');
ObjC.import('WebKit');
ObjC.import('stdlib');

var IDLE_TIMEOUT = 15 * 60;   // close by itself after 15 minutes with no interaction
var OVERLAY_LEVEL = 25;       // NSStatusWindowLevel: above the menu bar and the Dock

var ctx = {
  app: null,
  bridge: null,
  windows: [],
  main: null,
  web: null,
  data: null,
  shownAt: 0,
  shown: false,
  finished: false,
  chime: null
};

// ─── Helpers ──────────────────────────────────────────────────────────────

function writeStdout(text) {
  var data = $(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(data);
}

function evalInPage(source) {
  ctx.web.evaluateJavaScriptCompletionHandler(source, function () {});
}

function play(name) {
  if (!ctx.data.sound) return null;
  var sound = $.NSSound.soundNamed(name);
  if (sound.isNil()) return null;
  sound.play;
  return sound;
}

function later(selector, seconds) {
  ctx.bridge.performSelectorWithObjectAfterDelay(selector, null, seconds);
}

function resetIdleTimer() {
  $.NSObject.cancelPreviousPerformRequestsWithTargetSelectorObject(ctx.bridge, 'idleTimeout:', null);
  later('idleTimeout:', IDLE_TIMEOUT);
}

// The display the pointer is on is where the person is looking.
function activeScreen(screens) {
  var p = $.NSEvent.mouseLocation;
  for (var i = 0; i < screens.length; i++) {
    var f = screens[i].frame;
    if (p.x >= f.origin.x && p.x <= f.origin.x + f.size.width &&
        p.y >= f.origin.y && p.y <= f.origin.y + f.size.height) return screens[i];
  }
  return screens[0];
}

// ─── Windows ──────────────────────────────────────────────────────────────

ObjC.registerSubclass({
  name: 'ErgoBreakWindow',
  superclass: 'NSWindow',
  methods: {
    // Borderless windows can't take keyboard focus unless they say so.
    'canBecomeKeyWindow': { types: ['bool', []], implementation: function () { return true; } },
    'canBecomeMainWindow': { types: ['bool', []], implementation: function () { return true; } }
  }
});

function makeWindow(screen) {
  var frame = screen.frame;
  var win = $.ErgoBreakWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    frame, $.NSWindowStyleMaskBorderless, $.NSBackingStoreBuffered, false);
  win.level = OVERLAY_LEVEL;
  win.opaque = false;
  win.backgroundColor = $.NSColor.clearColor;
  win.hasShadow = false;
  win.releasedWhenClosed = false;
  // All Spaces, over fullscreen apps, not in the window cycle, not moved by Exposé.
  win.collectionBehavior = $.NSWindowCollectionBehaviorCanJoinAllSpaces |
                           $.NSWindowCollectionBehaviorStationary |
                           $.NSWindowCollectionBehaviorIgnoresCycle |
                           $.NSWindowCollectionBehaviorFullScreenAuxiliary;

  // Native blur of whatever is behind the overlay, always in dark appearance.
  var blur = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, frame.size.width, frame.size.height));
  blur.material = $.NSVisualEffectMaterialFullScreenUI;
  blur.blendingMode = $.NSVisualEffectBlendingModeBehindWindow;
  blur.state = $.NSVisualEffectStateActive;
  blur.appearance = $.NSAppearance.appearanceNamed($.NSAppearanceNameDarkAqua);
  blur.autoresizingMask = $.NSViewWidthSizable | $.NSViewHeightSizable;
  win.contentView = blur;
  win.alphaValue = 0;
  return win;
}

function showAll() {
  ctx.windows.forEach(function (win) {
    win.alphaValue = 0;
    win.orderFrontRegardless;
    win.animator.alphaValue = 1;
  });
  ctx.main.makeKeyAndOrderFront(null);
  try { ctx.app.activate; } catch (e) { ctx.app.activateIgnoringOtherApps(true); }
  ctx.main.makeFirstResponder(ctx.web);
  resetIdleTimer();
}

function finish(outcome) {
  if (ctx.finished) return;
  ctx.finished = true;
  writeStdout(JSON.stringify({
    outcome: outcome,
    seconds: Math.round((Date.now() - ctx.shownAt) / 1000)
  }));
  ctx.windows.forEach(function (win) { win.animator.alphaValue = 0; });
  // The overlay fades out at once; stay alive just long enough for a chime to finish.
  later('quit:', ctx.chime && ctx.chime.isPlaying ? Math.max(0.35, ctx.chime.duration) : 0.35);
}

// ─── Messages from the page ───────────────────────────────────────────────

function handleMessage(raw) {
  var msg;
  try { msg = JSON.parse(raw); } catch (e) { return; }
  switch (msg.action) {
    case 'finish':
      finish(msg.outcome || 'ready');
      break;
    case 'chime':
      ctx.chime = play('Hero');
      break;
    case 'openURL':
      if (/^https?:\/\//i.test(msg.url || '')) {
        $.NSWorkspace.sharedWorkspace.openURL($.NSURL.URLWithString(msg.url));
      }
      break;
  }
}

ObjC.registerSubclass({
  name: 'ErgoBreakBridge',
  superclass: 'NSObject',
  methods: {
    'userContentController:didReceiveScriptMessage:': {
      types: ['void', ['id', 'id']],
      implementation: function (controller, message) { handleMessage(ObjC.unwrap(message.body)); }
    },
    'webView:didFinishNavigation:': {
      types: ['void', ['id', 'id']],
      implementation: function () {
        if (ctx.shown) return;
        ctx.shown = true;
        ctx.shownAt = Date.now();
        showAll();
        play('Glass');
      }
    },
    'webView:didFailProvisionalNavigation:withError:': {
      types: ['void', ['id', 'id', 'id']],
      implementation: function (w, n, error) {
        console.log('ergo: could not load the break screen: ' + error.localizedDescription.js);
        $.exit(1);
      }
    },
    'idleTimeout:': {
      types: ['void', ['id']],
      implementation: function () {
        evalInPage('window.ergoTimeout && window.ergoTimeout()');
        later('forceTimeout:', 1.5);   // in case the page doesn't answer
      }
    },
    'forceTimeout:': {
      types: ['void', ['id']],
      implementation: function () { finish('timeout'); }
    },
    'quit:': {
      types: ['void', ['id']],
      implementation: function () { $.exit(0); }
    }
  }
});

// ─── Main ─────────────────────────────────────────────────────────────────

function run(argv) {
  if (argv.length < 2) {
    console.log('ergo: this break screen is opened by ergo.sh');
    $.exit(2);
  }
  var htmlPath = argv[0];
  ctx.data = JSON.parse(argv[1]);

  ctx.app = $.NSApplication.sharedApplication;
  ctx.app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);   // no Dock icon
  ctx.bridge = $.ErgoBreakBridge.alloc.init;

  var screens = ObjC.unwrap($.NSScreen.screens);
  var primary = activeScreen(screens);
  screens.forEach(function (screen) {
    var win = makeWindow(screen);
    ctx.windows.push(win);
    if (screen.isEqual(primary)) ctx.main = win;
  });
  if (!ctx.main) ctx.main = ctx.windows[0];

  // The break content lives on the active display; the others just dim and blur.
  var content = $.WKUserContentController.alloc.init;
  content.addScriptMessageHandlerName(ctx.bridge, 'ergo');
  content.addUserScript($.WKUserScript.alloc.initWithSourceInjectionTimeForMainFrameOnly(
    'window.ERGO_BREAK = ' + JSON.stringify(ctx.data) + ';', $.WKUserScriptInjectionTimeAtDocumentStart, true));
  var config = $.WKWebViewConfiguration.alloc.init;
  config.userContentController = content;

  var host = ctx.main.contentView;
  var web = $.WKWebView.alloc.initWithFrameConfiguration(host.bounds, config);
  web.autoresizingMask = $.NSViewWidthSizable | $.NSViewHeightSizable;
  web.setValueForKey($.NSNumber.numberWithBool(false), 'drawsBackground');
  web.navigationDelegate = ctx.bridge;
  host.addSubview(web);
  ctx.web = web;

  var pageURL = $.NSURL.fileURLWithPath(htmlPath);
  web.loadFileURLAllowingReadAccessToURL(pageURL, pageURL.URLByDeletingLastPathComponent);

  ctx.app.run;
}
