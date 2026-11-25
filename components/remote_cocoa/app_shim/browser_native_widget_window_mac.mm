// Copyright 2018 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "components/remote_cocoa/app_shim/browser_native_widget_window_mac.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "base/mac/mac_util.h"
#include "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "components/remote_cocoa/common/native_widget_ns_window_host.mojom.h"

@interface NSObject (LightPrivateCornerRadiiInit)
- (instancetype)initWithTopLeft:(CGFloat)tl
                       topRight:(CGFloat)tr
                     bottomLeft:(CGFloat)bl
                    bottomRight:(CGFloat)br;
@end

namespace {
// Workaround for https://crbug.com/1369643
const double kThinControllerHeight = 0.5;

struct PerCornerRadiiState {
  CGFloat tl = 20.0;
  CGFloat tr = 20.0;
  CGFloat bl = 20.0;
  CGFloat br = 20.0;

  bool operator==(const PerCornerRadiiState& o) const {
    return std::abs(tl - o.tl) < 0.01 && std::abs(tr - o.tr) < 0.01 &&
           std::abs(bl - o.bl) < 0.01 && std::abs(br - o.br) < 0.01;
  }
  bool operator!=(const PerCornerRadiiState& o) const { return !(*this == o); }
};

bool UserDefaultBoolOr(NSString* key, bool fallback) {
  NSObject* val = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([val isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)val boolValue];
  }
  return fallback;
}

CGFloat UserDefaultDoubleOr(NSString* key, CGFloat fallback) {
  NSObject* val = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([val isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)val doubleValue];
  }
  return fallback;
}

void LightLogWindowDiag(const char* tag,
                        NSWindow* win,
                        const PerCornerRadiiState& c) {
  (void)tag;
  (void)win;
  (void)c;
}

PerCornerRadiiState ComputeWindowPerCornerRadii(NSWindow* window) {
  const CGFloat base_radius = std::max<CGFloat>(
      0.001, UserDefaultDoubleOr(@"LightBaseWindowCornerRadius", 20.0));
  PerCornerRadiiState out{base_radius, base_radius, base_radius, base_radius};
  if (!window) {
    return out;
  }
  if ((window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
    return {0.001, 0.001, 0.001, 0.001};
  }
  if (!UserDefaultBoolOr(@"LightAutoCornerRadiusEnabled", true)) {
    return out;
  }
  NSScreen* screen = window.screen ?: NSScreen.mainScreen;
  if (!screen) {
    return out;
  }
  const NSRect wf = window.frame;
  const NSRect vf = screen.visibleFrame;
  const NSRect sf = screen.frame;
  constexpr CGFloat kTol = 4.0;

  const bool touches_left = std::abs(NSMinX(wf) - NSMinX(vf)) <= kTol ||
                            std::abs(NSMinX(wf) - NSMinX(sf)) <= kTol;
  const bool touches_right = std::abs(NSMaxX(wf) - NSMaxX(vf)) <= kTol ||
                             std::abs(NSMaxX(wf) - NSMaxX(sf)) <= kTol;
  const bool touches_bottom = std::abs(NSMinY(wf) - NSMinY(vf)) <= kTol ||
                              std::abs(NSMinY(wf) - NSMinY(sf)) <= kTol;
  const bool touches_top = std::abs(NSMaxY(wf) - NSMaxY(vf)) <= kTol ||
                           std::abs(NSMaxY(wf) - NSMaxY(sf)) <= kTol;

  if (touches_top && touches_left &&
      UserDefaultBoolOr(@"LightAutoCornerTopLeft", true)) {
    out.tl = 0.001;
  }
  if (touches_top && touches_right &&
      UserDefaultBoolOr(@"LightAutoCornerTopRight", true)) {
    out.tr = 0.001;
  }
  if (touches_bottom && touches_left &&
      UserDefaultBoolOr(@"LightAutoCornerBottomLeft", true)) {
    out.bl = 0.001;
  }
  if (touches_bottom && touches_right &&
      UserDefaultBoolOr(@"LightAutoCornerBottomRight", true)) {
    out.br = 0.001;
  }
  return out;
}
}  // namespace
@interface NSWindow (PrivateBrowserNativeWidgetAPI)
+ (Class)frameViewClassForStyleMask:(NSUInteger)windowStyle;
- (void)_setCornerRadii:(id)radii;
- (void)_updateWindowCornerMask;
@end

@interface NSThemeFrame (PrivateBrowserNativeWidgetAPI)
- (CGFloat)_titlebarHeight;
- (CGFloat)_minXTitlebarWidgetInset;
- (CGFloat)_getCachedWindowCornerRadius;
- (void)setStyleMask:(NSUInteger)styleMask;
- (void)setButtonRevealAmount:(double)amount;
@end

// The base class of traffic light buttons.
WEAK_IMPORT_ATTRIBUTE
@interface _NSThemeWidget : NSButton
- (void)setRevealAmount:(double)amount;
@end

@interface BrowserWindowFrame : NativeWidgetMacNSWindowTitledFrame
@end

@implementation BrowserWindowFrame {
  BOOL _inFullScreen;
  BOOL _alwaysShowTrafficLights;
}

// NSThemeFrame overrides.

// Note that while this has an effect on the location of the window control
// widgets, this is also an important part of the functioning of immersive
// fullscreen and must not be removed lest that break.
- (CGFloat)_titlebarHeight {
  auto* window = base::apple::ObjCCast<NativeWidgetMacNSWindow>(self.window);
  remote_cocoa::NativeWidgetNSWindowBridge* bridge = window.bridge;
  if (!bridge) {
    return [super _titlebarHeight];
  }

  // The titlebar will be the same size during non-fullscreen and immersive
  // fullscreen. During content fullscreen the toolbar is hidden and the
  // titlebar will be smaller default height.
  if (!_inFullScreen || bridge->ShouldUseCustomTitlebarHeightForFullscreen()) {
    bool overrideTitlebarHeight = false;
    float titlebarHeight = 0;
    bridge->host()->GetWindowFrameTitlebarHeight(&overrideTitlebarHeight,
                                                 &titlebarHeight);
    if (overrideTitlebarHeight) {
      return titlebarHeight;
    }
  }

  return [super _titlebarHeight];
}

- (CGFloat)_minXTitlebarWidgetInset {
  if (@available(macOS 26, *)) {
    // Position traffic lights cleanly inside the floating Liquid Glass sidebar.
    return 20.0;
  }
  return [super _minXTitlebarWidgetInset];
}

- (CGFloat)_getCachedWindowCornerRadius {
  if (@available(macOS 26, *)) {
    return std::max<CGFloat>(
        0.001, UserDefaultDoubleOr(@"LightBaseWindowCornerRadius", 20.0));
  }
  return [super _getCachedWindowCornerRadius];
}

- (void)setStyleMask:(NSUInteger)styleMask {
  _inFullScreen = (styleMask & NSWindowStyleMaskFullScreen) != 0;
  [super setStyleMask:styleMask];
}

- (BOOL)_shouldCenterTrafficLights {
  return YES;
}

- (void)setButtonRevealAmount:(double)amount {
  // Don't override the reveal amount sent to `super`. `-[NSThemeFrame
  // setButtonRevealAmount:]` performs layout operations in addition to
  // adjusting the visibility of the traffic lights. The layout changes are
  // desired and should be left intact.
  [super setButtonRevealAmount:amount];
  if (amount == 1.0) {
    return;
  }

  [self maybeShowTrafficLights];
}

- (void)setAlwaysShowTrafficLights:(BOOL)alwaysShow {
  _alwaysShowTrafficLights = alwaysShow;
  [self maybeShowTrafficLights];
}

- (void)maybeShowTrafficLights {
  if (!_alwaysShowTrafficLights) {
    return;
  }
  NSWindow* window = [self window];
  const NSWindowButton kButtons[] = {
      NSWindowCloseButton,
      NSWindowMiniaturizeButton,
      NSWindowZoomButton,
  };
  for (NSWindowButton type : kButtons) {
    NSButton* button = [window standardWindowButton:type];
    CHECK(button);
    CHECK([button isKindOfClass:[_NSThemeWidget class]]);
    [button setAlphaValue:1.0];
    // macOS 27 adds -[NSThemeWidget setRevealAmount:] to control the visibility
    // of the traffic lights.
    if ([button respondsToSelector:@selector(setRevealAmount:)]) {
      [(_NSThemeWidget*)button setRevealAmount:1.0];
    }
  }
}

@end

@interface BrowserNativeWidgetWindow (LightCornerAnimStep)
- (void)stepCornerRadiiAnimation:(CADisplayLink*)link API_AVAILABLE(macos(14.0));
@end

API_AVAILABLE(macos(14.0))
@interface LightCornerAnimProxy : NSObject
@property(nonatomic, weak) BrowserNativeWidgetWindow* targetWindow;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation LightCornerAnimProxy
@synthesize targetWindow = _targetWindow;
- (void)onDisplayLink:(CADisplayLink*)link {
  BrowserNativeWidgetWindow* w = _targetWindow;
  if (!w) {
    [link invalidate];
    return;
  }
  [w stepCornerRadiiAnimation:link];
}
@end

@implementation BrowserNativeWidgetWindow {
  PerCornerRadiiState _currentCornerRadii;
  PerCornerRadiiState _velocityCornerRadii;
  PerCornerRadiiState _targetCornerRadii;
  id __strong _cornerDisplayLink;
  BOOL _hasAppliedCornerRadii;
}

@synthesize thinTitlebarViewController = _thinTitlebarViewController;

// NSWindow (PrivateAPI) overrides.

+ (Class)frameViewClassForStyleMask:(NSUInteger)windowStyle {
  // - NSThemeFrame and its subclasses will be nil if it's missing at runtime.
  if ([BrowserWindowFrame class])
    return [BrowserWindowFrame class];
  return [super frameViewClassForStyleMask:windowStyle];
}

- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSUInteger)windowStyle
                            backing:(NSBackingStoreType)bufferingType
                              defer:(BOOL)deferCreation {
  if ((self = [super initWithContentRect:contentRect
                               styleMask:windowStyle
                                 backing:bufferingType
                                   defer:deferCreation])) {
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidBecomeKey:)
               name:NSWindowDidBecomeKeyNotification
             object:nil];
    NSArray<NSNotificationName>* geometryNotes = @[
      NSWindowDidResizeNotification,
      NSWindowDidMoveNotification,
      NSWindowDidEnterFullScreenNotification,
      NSWindowDidExitFullScreenNotification,
      NSWindowDidChangeScreenNotification,
    ];
    for (NSNotificationName name in geometryNotes) {
      [NSNotificationCenter.defaultCenter
          addObserver:self
             selector:@selector(windowGeometryDidChangeForCorners:)
                 name:name
               object:self];
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(liveResizeBoundaryNote:)
               name:NSWindowWillStartLiveResizeNotification
             object:self];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(liveResizeBoundaryNote:)
               name:NSWindowDidEndLiveResizeNotification
             object:self];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(lightSettingsDidChange:)
               name:@"LightSettingsDidChangeNotification"
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowWillCloseCleanup:)
               name:NSWindowWillCloseNotification
             object:self];
    _thinTitlebarViewController =
        [[NSTitlebarAccessoryViewController alloc] init];
    NSView* thinView = [[NSView alloc] init];
    thinView.wantsLayer = YES;
    thinView.layer.backgroundColor = NSColor.blackColor.CGColor;
    _thinTitlebarViewController.view = thinView;
    _thinTitlebarViewController.layoutAttribute = NSLayoutAttributeBottom;
    _thinTitlebarViewController.fullScreenMinHeight = kThinControllerHeight;
    _thinTitlebarViewController.hidden = YES;
    [self addTitlebarAccessoryViewController:_thinTitlebarViewController];
  }
  return self;
}

- (void)dealloc {
  if (@available(macOS 14.0, *)) {
    [(CADisplayLink*)_cornerDisplayLink invalidate];
  }
  _cornerDisplayLink = nil;
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)windowWillCloseCleanup:(NSNotification*)notify {
  if (@available(macOS 14.0, *)) {
    [(CADisplayLink*)_cornerDisplayLink invalidate];
  }
  _cornerDisplayLink = nil;
}

- (void)commitCornerRadiiToWindow:(const PerCornerRadiiState&)c {
  Class radiiCls = NSClassFromString(@"NSViewCornerRadii");
  if (radiiCls && [self respondsToSelector:@selector(_setCornerRadii:)]) {
    id radii = [[radiiCls alloc] initWithTopLeft:c.tl
                                        topRight:c.tr
                                      bottomLeft:c.bl
                                     bottomRight:c.br];
    [self _setCornerRadii:radii];
    if ([self respondsToSelector:@selector(_updateWindowCornerMask)]) {
      [self _updateWindowCornerMask];
    }
  }
}

- (void)stepCornerRadiiAnimation:(CADisplayLink*)link API_AVAILABLE(macos(14.0)) {
  const CGFloat dt = std::clamp<CGFloat>(
      link.targetTimestamp - link.timestamp, 1.0 / 240.0, 1.0 / 30.0);

  auto stepOne = [dt](CGFloat& pos, CGFloat& vel, CGFloat target) -> bool {
    const CGFloat diff = target - pos;
    if (std::abs(diff) < 0.04 && std::abs(vel) < 0.4) {
      pos = target;
      vel = 0.0;
      return false;
    }
    // Critically-damped spring (smooth ~165ms morph, zero negative overshoot).
    constexpr CGFloat kOmega = 24.0;
    const CGFloat accel = (kOmega * kOmega) * diff - (2.0 * kOmega) * vel;
    vel += accel * dt;
    pos = std::clamp<CGFloat>(pos + vel * dt, 0.001, 64.0);
    return true;
  };

  bool active = false;
  active |= stepOne(_currentCornerRadii.tl, _velocityCornerRadii.tl,
                    _targetCornerRadii.tl);
  active |= stepOne(_currentCornerRadii.tr, _velocityCornerRadii.tr,
                    _targetCornerRadii.tr);
  active |= stepOne(_currentCornerRadii.bl, _velocityCornerRadii.bl,
                    _targetCornerRadii.bl);
  active |= stepOne(_currentCornerRadii.br, _velocityCornerRadii.br,
                    _targetCornerRadii.br);

  [self commitCornerRadiiToWindow:_currentCornerRadii];

  if (!active) {
    link.paused = YES;
    LightLogWindowDiag("CORNERS-SETTLED", self, _currentCornerRadii);
  }
}

- (void)applyPerCornerRadiiForce:(BOOL)force reason:(const char*)reason {
  PerCornerRadiiState desired = ComputeWindowPerCornerRadii(self);
  LightLogWindowDiag(reason, self, desired);

  // First application on window startup snaps immediately without animating.
  if (!_hasAppliedCornerRadii) {
    _hasAppliedCornerRadii = YES;
    _currentCornerRadii = desired;
    _targetCornerRadii = desired;
    _velocityCornerRadii = {0.0, 0.0, 0.0, 0.0};
    [self commitCornerRadiiToWindow:desired];
    LightLogWindowDiag("CORNERS-APPLIED", self, desired);
    return;
  }

  if (!force && desired == _targetCornerRadii) {
    return;
  }
  _targetCornerRadii = desired;

  if (_currentCornerRadii == _targetCornerRadii) {
    if (force) {
      [self commitCornerRadiiToWindow:_targetCornerRadii];
    }
    return;
  }

  if (@available(macOS 14.0, *)) {
    CADisplayLink* link = (CADisplayLink*)_cornerDisplayLink;
    if (!link) {
      LightCornerAnimProxy* proxy = [[LightCornerAnimProxy alloc] init];
      proxy.targetWindow = self;
      link =
          [self displayLinkWithTarget:proxy selector:@selector(onDisplayLink:)];
      // NSRunLoopCommonModes ensures smooth 120Hz interpolation even during
      // active mouse-tracking loops (window dragging & live resizing)!
      [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
      _cornerDisplayLink = link;
    }
    link.paused = NO;
  } else {
    _currentCornerRadii = _targetCornerRadii;
    [self commitCornerRadiiToWindow:_currentCornerRadii];
  }
}

- (void)liveResizeBoundaryNote:(NSNotification*)notify {
  const bool started =
      [notify.name isEqualToString:NSWindowWillStartLiveResizeNotification];
  [self applyPerCornerRadiiForce:NO
                          reason:(started ? "LIVE-RESIZE-START"
                                          : "LIVE-RESIZE-END")];
}

- (void)lightSettingsDidChange:(NSNotification*)notify {
  [self applyPerCornerRadiiForce:YES reason:"SETTINGS-CHANGED"];
}

- (void)windowGeometryDidChangeForCorners:(NSNotification*)notify {
  const char* tag = notify ? notify.name.UTF8String : "BECOME-KEY";
  [self applyPerCornerRadiiForce:NO reason:tag];
}

- (void)windowDidBecomeKey:(NSNotification*)notify {
  if (notify.object == self) {
    [self windowGeometryDidChangeForCorners:nil];
  }
  // NSToolbarFullScreenWindow should never become the key window, otherwise
  // the browser window will appear inactive. Activate the browser window
  // when this happens.
  NSWindow* toolbarWindow = notify.object;
  if (toolbarWindow.parentWindow == self &&
      remote_cocoa::IsNSToolbarFullScreenWindow(toolbarWindow)) {
    [self makeKeyAndOrderFront:nil];
  }
}

// The base implementation returns YES if the window's frame view is a custom
// class, which causes undesirable changes in behavior. AppKit NSWindow
// subclasses are known to override it and return NO.
- (BOOL)_usesCustomDrawing {
  return NO;
}

// Handle "Move focus to the window toolbar" configured in System Preferences ->
// Keyboard -> Shortcuts -> Keyboard. Usually Ctrl+F5. The argument (|unknown|)
// tends to just be nil.
- (void)_handleFocusToolbarHotKey:(id)unknown {
  remote_cocoa::NativeWidgetNSWindowBridge* bridge = [self bridge];
  if (bridge)
    bridge->host()->OnFocusWindowToolbar();
}

- (void)setAlwaysShowTrafficLights:(BOOL)alwaysShow {
  [base::apple::ObjCCastStrict<BrowserWindowFrame>(self.contentView.superview)
      setAlwaysShowTrafficLights:alwaysShow];
}

@end
