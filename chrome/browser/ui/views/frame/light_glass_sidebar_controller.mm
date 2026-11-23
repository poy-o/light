// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/views/frame/light_glass_sidebar_controller.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/autocomplete/autocomplete_classifier_factory.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/command_observer.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_change_type.h"
#include "chrome/browser/ui/tabs/tab_data.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_group_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/tabs/tab_strip_user_gesture_details.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/browser/ui/extensions/extensions_toolbar_view_model.h"
#include "chrome/browser/ui/views/extensions/extensions_toolbar_desktop.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/light_native_settings_controller.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_enums.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_match_type.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_id.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_group.h"
#include "components/tabs/public/tab_interface.h"
#include "components/tabs/public/tab_network_state.h"
#include "components/url_formatter/url_fixer.h"
#include "components/url_formatter/url_formatter.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/isolated_world_ids.h"
#include "extensions/browser/extension_registry.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/models/image_model.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"
#include "url/gurl.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

constexpr CGFloat kSidebarInset = 7.0;
constexpr CGFloat kDefaultSidebarWidth = 228.0;
constexpr CGFloat kDefaultSidebarCornerRadius = 20.0;
constexpr CGFloat kDefaultSidebarHiddenBlurRadius = 14.0;
constexpr CGFloat kDefaultHoverEdgeTriggerWidth = 14.0;
constexpr CGFloat kKeepOpenExtraMargin = 10.0;
constexpr CGFloat kHeaderHeight = 84.0;
constexpr CGFloat kFooterHeight = 46.0;
constexpr CGFloat kTabRowHeight = 34.0;
constexpr CGFloat kTabRowSpacing = 2.0;

bool SidebarUDBool(NSString* key, bool fallback) {
  NSObject* v = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([v isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)v boolValue];
  }
  return fallback;
}

CGFloat SidebarUDDouble(NSString* key, CGFloat fallback) {
  NSObject* v = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([v isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)v doubleValue];
  }
  return fallback;
}

NSInteger SidebarUDInt(NSString* key, NSInteger fallback) {
  NSObject* v = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([v isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)v integerValue];
  }
  return fallback;
}

bool IsViewDarkAppearance(NSView* view) {
  NSAppearance* app = view.effectiveAppearance ?: NSApp.effectiveAppearance;
  NSAppearanceName best =
      [app bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua, NSAppearanceNameAqua
      ]];
  return [best isEqualToString:NSAppearanceNameDarkAqua];
}

struct LightGroupColorEntry {
  tab_groups::TabGroupColorId id;
  const char* name;
  CGFloat r, g, b;
};

constexpr LightGroupColorEntry kLightGroupColors[] = {
    {tab_groups::TabGroupColorId::kGrey, "Grey", 0x8E / 255.0, 0x8E / 255.0,
     0x93 / 255.0},
    {tab_groups::TabGroupColorId::kBlue, "Blue", 0x4C / 255.0, 0x8D / 255.0,
     0xF6 / 255.0},
    {tab_groups::TabGroupColorId::kRed, "Red", 0xE5 / 255.0, 0x53 / 255.0,
     0x4B / 255.0},
    {tab_groups::TabGroupColorId::kYellow, "Yellow", 0xE3 / 255.0, 0xB3 / 255.0,
     0x41 / 255.0},
    {tab_groups::TabGroupColorId::kGreen, "Green", 0x3F / 255.0, 0xB0 / 255.0,
     0x6C / 255.0},
    {tab_groups::TabGroupColorId::kPink, "Pink", 0xDB / 255.0, 0x61 / 255.0,
     0xA2 / 255.0},
    {tab_groups::TabGroupColorId::kPurple, "Purple", 0x9B / 255.0, 0x6C / 255.0,
     0xF0 / 255.0},
    {tab_groups::TabGroupColorId::kCyan, "Cyan", 0x35 / 255.0, 0xB8 / 255.0,
     0xC6 / 255.0},
    {tab_groups::TabGroupColorId::kOrange, "Orange", 0xEE / 255.0, 0x84 / 255.0,
     0x34 / 255.0},
};

NSColor* GroupColorForId(tab_groups::TabGroupColorId cid) {
  for (const auto& entry : kLightGroupColors) {
    if (entry.id == cid) {
      return [NSColor colorWithSRGBRed:entry.r
                                 green:entry.g
                                  blue:entry.b
                                 alpha:1.0];
    }
  }
  return [NSColor colorWithSRGBRed:0x8E / 255.0
                             green:0x8E / 255.0
                              blue:0x93 / 255.0
                             alpha:1.0];
}

NSImage* GroupSwatchImage(NSColor* color, CGFloat diameter = 11.0) {
  NSImage* img = [NSImage imageWithSize:NSMakeSize(diameter, diameter)
                                flipped:NO
                         drawingHandler:^BOOL(NSRect dstRect) {
                           NSRect inset = NSInsetRect(dstRect, 0.5, 0.5);
                           NSBezierPath* p =
                               [NSBezierPath bezierPathWithOvalInRect:inset];
                           [color setFill];
                           [p fill];
                           [[NSColor.whiteColor colorWithAlphaComponent:0.25]
                               setStroke];
                           p.lineWidth = 0.5;
                           [p stroke];
                           return YES;
                         }];
  return img;
}

// [LIGHT-DIAG-LOG] Temporary mouse/sidebar/resize diagnostic logger.
void LightLogSidebarDiag(const char* tag,
                         NSWindow* win,
                         NSPoint localPt,
                         BOOL sidebarVis,
                         const char* extra = "") {
  if (!SidebarUDBool(@"LightVerboseDiagLogging", true)) {
    return;
  }
  static FILE* fp = nullptr;
  if (!fp) {
    fp = std::fopen("/tmp/light_ui_debug.log", "a");
  }
  NSRect wf = win ? win.frame : NSZeroRect;
  NSPoint scrPt = [NSEvent mouseLocation];
  BOOL live = win ? win.inLiveResize : NO;
  char buf[512];
  std::snprintf(
      buf, sizeof(buf),
      "[LIGHT-DIAG][%s] live=%d vis=%d win=(%.1f,%.1f %.1fx%.1f) "
      "mouseScr=(%.1f,%.1f) local=(%.1f,%.1f) btns=0x%lx %s\n",
      tag, live ? 1 : 0, sidebarVis ? 1 : 0, wf.origin.x, wf.origin.y,
      wf.size.width, wf.size.height, scrPt.x, scrPt.y, localPt.x, localPt.y,
      (unsigned long)[NSEvent pressedMouseButtons], extra ? extra : "");
  std::fputs(buf, stderr);
  if (fp) {
    std::fputs(buf, fp);
    std::fflush(fp);
  }
}

bool IsNewTabOrBlankURL(const GURL& url) {
  if (!url.is_valid() || url.is_empty()) {
    return true;
  }
  const std::string spec = url.spec();
  return spec == "chrome://newtab/" || spec == "chrome://new-tab-page/" ||
         spec == "about:blank";
}

NSImage* SymbolImage(NSString* name, CGFloat pointSize, NSFontWeight weight) {
  NSImage* img = [NSImage imageWithSystemSymbolName:name
                           accessibilityDescription:nil];
  if (!img) {
    return nil;
  }
  NSImageSymbolConfiguration* config =
      [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                      weight:weight];
  return [img imageWithSymbolConfiguration:config];
}

}  // namespace

class LightGlassSidebarBridgeImpl;

// -----------------------------------------------------------------------------
// Hover-aware icon button used in header and tab rows.
// -----------------------------------------------------------------------------
@interface LightIconButton : NSView
@property(nonatomic, copy) void (^actionBlock)(void);
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
@property(nonatomic, assign) CGFloat cornerRadius;
- (instancetype)initWithSymbol:(NSString*)symbolName
                     pointSize:(CGFloat)pointSize
                        weight:(NSFontWeight)weight
                       toolTip:(NSString*)toolTip;
- (void)setSymbol:(NSString*)symbolName
        pointSize:(CGFloat)pointSize
           weight:(NSFontWeight)weight;
@end

@implementation LightIconButton {
  NSImageView* __strong _imageView;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _pressed;
}

@synthesize actionBlock = _actionBlock;
@synthesize enabled = _enabled;
@synthesize cornerRadius = _cornerRadius;

- (instancetype)initWithSymbol:(NSString*)symbolName
                     pointSize:(CGFloat)pointSize
                        weight:(NSFontWeight)weight
                       toolTip:(NSString*)toolTip {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _enabled = YES;
    _cornerRadius = 7.0;
    self.wantsLayer = YES;
    self.toolTip = toolTip;

    _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _imageView.imageScaling = NSImageScaleProportionallyDown;
    _imageView.contentTintColor = NSColor.labelColor;
    [self setSymbol:symbolName pointSize:pointSize weight:weight];
    [self addSubview:_imageView];
  }
  return self;
}

- (void)setSymbol:(NSString*)symbolName
        pointSize:(CGFloat)pointSize
           weight:(NSFontWeight)weight {
  _imageView.image = SymbolImage(symbolName, pointSize, weight);
}

- (void)setEnabled:(BOOL)enabled {
  _enabled = enabled;
  _imageView.alphaValue = enabled ? 1.0 : 0.32;
  if (!enabled) {
    _hovered = NO;
    _pressed = NO;
  }
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  _imageView.frame = self.bounds;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  if (!_enabled) {
    return;
  }
  _hovered = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _pressed = NO;
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
  if (!_enabled) {
    return;
  }
  _pressed = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
  if (!_enabled || !_pressed) {
    return;
  }
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  BOOL inside = NSPointInRect(local, self.bounds);
  _pressed = NO;
  _hovered = inside;
  [self setNeedsDisplay:YES];
  if (inside && _actionBlock) {
    _actionBlock();
  }
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (!_enabled || (!_hovered && !_pressed)) {
    return;
  }
  CGFloat alpha = _pressed ? 0.18 : 0.10;
  [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:_cornerRadius
                                                       yRadius:_cornerRadius];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Custom NSTextField for the Liquid Glass address/search bar.
// -----------------------------------------------------------------------------
@interface LightAddressTextField : NSTextField
@property(nonatomic, copy) void (^onFocusChanged)(BOOL focused);
@end

@implementation LightAddressTextField

@synthesize onFocusChanged = _onFocusChanged;

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok && _onFocusChanged) {
    _onFocusChanged(YES);
  }
  return ok;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

@end

// -----------------------------------------------------------------------------
// Block-backed NSMenuItem helper (retained via representedObject).
// -----------------------------------------------------------------------------
@interface LightMenuBlockTarget : NSObject
@property(nonatomic, copy) void (^block)(void);
- (void)invokeMenuAction:(id)sender;
@end

@implementation LightMenuBlockTarget
@synthesize block = _block;
- (void)invokeMenuAction:(id)sender {
  if (_block) {
    _block();
  }
}
@end

namespace {

NSMenuItem* MakeBlockMenuItem(NSString* title,
                              NSImage* image,
                              BOOL enabled,
                              BOOL checked,
                              void (^action)(void)) {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:(title ?: @"")
                                                action:nil
                                         keyEquivalent:@""];
  if (image) {
    item.image = image;
  }
  item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
  if (enabled && action) {
    LightMenuBlockTarget* tgt = [[LightMenuBlockTarget alloc] init];
    tgt.block = action;
    item.representedObject = tgt;
    item.target = tgt;
    item.action = @selector(invokeMenuAction:);
  } else {
    item.enabled = NO;
  }
  return item;
}

NSMenuItem* MakeSymbolMenuItem(NSString* title,
                               NSString* symbolName,
                               BOOL enabled,
                               void (^action)(void)) {
  NSImage* icon = symbolName.length > 0
                      ? SymbolImage(symbolName, 12.5, NSFontWeightMedium)
                      : nil;
  return MakeBlockMenuItem(title, icon, enabled, NO, action);
}

}  // namespace

@protocol LightThemeWidgetPrivate <NSObject>
@optional
- (void)mouseEnteredOrExited;
- (void)update;
@end

@protocol LightCIFilterPrivate <NSObject>
+ (id)filterWithName:(NSString*)name;
- (void)setDefaults;
@end

// -----------------------------------------------------------------------------
// Flipped NSView inside NSScrollView: double-click empty space -> New Tab;
// drag empty space -> move window; right-click -> sidebar menu.
// -----------------------------------------------------------------------------
@interface LightFlippedDocumentView : NSView
@property(nonatomic, copy) void (^onDoubleClickEmpty)(void);
@property(nonatomic, copy) NSMenu* (^menuProvider)(void);
@end

@implementation LightFlippedDocumentView
@synthesize onDoubleClickEmpty = _onDoubleClickEmpty;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)mouseDown:(NSEvent*)event {
  if (event.clickCount == 2 && _onDoubleClickEmpty) {
    _onDoubleClickEmpty();
  }
}

- (void)mouseDragged:(NSEvent*)event {
  [self.window performWindowDragWithEvent:event];
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider() : nil;
}
@end

// -----------------------------------------------------------------------------
// Netnyahoo Pinned Tile Visual Analysis (DockSelection.swift + PinGlow.swift +
// iconBacking.ts ported 1:1 to Objective-C++ with NSCache).
// -----------------------------------------------------------------------------
@interface LightPinVisualAnalysis : NSObject
@property(nonatomic, assign) BOOL isMultiColor;
@property(nonatomic, strong) NSColor* backgroundTint;
@property(nonatomic, strong) id blurredCGImageObj;  // CFBridgingRelease(CGImageRef)
@property(nonatomic, assign) CGFloat singleLuma;
@property(nonatomic, strong) NSColor* singleMarkColor;
- (id)conicRingCGImageForSize:(NSSize)size
                    lineWidth:(CGFloat)lwPts
                       radius:(CGFloat)radius;
+ (LightPinVisualAnalysis*)analysisForFavicon:(NSImage*)favicon
                                     cacheKey:(NSString*)cacheKey;
@end

@implementation LightPinVisualAnalysis {
  std::vector<NSColor*> _glowColors;    // [avg, dom0, dom1, dom2]
  std::vector<CGFloat> _glowCoverage;   // 36 bins normalized 0..1
  NSMutableDictionary<NSString*, id>* __strong _ringImageCache;
}

@synthesize isMultiColor = _isMultiColor;
@synthesize backgroundTint = _backgroundTint;
@synthesize blurredCGImageObj = _blurredCGImageObj;
@synthesize singleLuma = _singleLuma;
@synthesize singleMarkColor = _singleMarkColor;

+ (NSCache<NSString*, LightPinVisualAnalysis*>*)sharedCache {
  static NSCache<NSString*, LightPinVisualAnalysis*>* cache = nil;
  if (!cache) {
    cache = [[NSCache alloc] init];
    cache.countLimit = 128;
  }
  return cache;
}

+ (CIContext*)sharedCIContext {
  static CIContext* ctx = nil;
  if (!ctx) {
    ctx = [CIContext contextWithOptions:nil];
  }
  return ctx;
}

+ (NSColor*)cappedLight:(NSColor*)c cap:(CGFloat)cap {
  NSColor* rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!rgb) {
    return c;
  }
  CGFloat h = 0, s = 0, b = 0, a = 1;
  [rgb getHue:&h saturation:&s brightness:&b alpha:&a];
  return (b > cap) ? [NSColor colorWithHue:h
                                saturation:s
                                brightness:cap
                                     alpha:a]
                   : rgb;
}

+ (LightPinVisualAnalysis*)analysisForFavicon:(NSImage*)favicon
                                     cacheKey:(NSString*)cacheKey {
  if (!favicon || cacheKey.length == 0) {
    return nil;
  }
  LightPinVisualAnalysis* cached = [[self sharedCache] objectForKey:cacheKey];
  if (cached) {
    return cached;
  }

  constexpr int kDim = 64;
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr
                    pixelsWide:kDim
                    pixelsHigh:kDim
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSCalibratedRGBColorSpace
                   bytesPerRow:kDim * 4
                  bitsPerPixel:32];
  if (!rep || !rep.bitmapData) {
    return nil;
  }

  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext =
      [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [[NSColor clearColor] setFill];
  NSRectFill(NSMakeRect(0, 0, kDim, kDim));
  [favicon drawInRect:NSMakeRect(0, 0, kDim, kDim)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
  [NSGraphicsContext restoreGraphicsState];

  const unsigned char* d = rep.bitmapData;

  // 1) Opaque pixel spread test (IconTheme.generate from DockSelection.swift)
  double sumR = 0, sumG = 0, sumB = 0;
  int opaqueCount = 0;
  for (int i = 0; i < kDim * kDim; ++i) {
    double a = d[i * 4 + 3] / 255.0;
    if (a >= 0.90) {
      double r = (d[i * 4 + 0] / 255.0) / a;
      double g = (d[i * 4 + 1] / 255.0) / a;
      double b = (d[i * 4 + 2] / 255.0) / a;
      sumR += std::clamp(r, 0.0, 1.0);
      sumG += std::clamp(g, 0.0, 1.0);
      sumB += std::clamp(b, 0.0, 1.0);
      ++opaqueCount;
    }
  }
  if (opaqueCount == 0) {
    return nil;
  }
  const double meanR = sumR / opaqueCount;
  const double meanG = sumG / opaqueCount;
  const double meanB = sumB / opaqueCount;
  double spreadAcc = 0.0;
  for (int i = 0; i < kDim * kDim; ++i) {
    double a = d[i * 4 + 3] / 255.0;
    if (a >= 0.90) {
      double r = std::clamp((d[i * 4 + 0] / 255.0) / a, 0.0, 1.0) - meanR;
      double g = std::clamp((d[i * 4 + 1] / 255.0) / a, 0.0, 1.0) - meanG;
      double b = std::clamp((d[i * 4 + 2] / 255.0) / a, 0.0, 1.0) - meanB;
      spreadAcc += std::sqrt(r * r + g * g + b * b);
    }
  }
  const double spread = spreadAcc / opaqueCount;

  LightPinVisualAnalysis* out = [[LightPinVisualAnalysis alloc] init];
  out->_ringImageCache = [NSMutableDictionary dictionary];

  if (spread < 0.055) {
    // Single-color / monochrome icon -> iconBacking.ts tray & rim!
    out.isMultiColor = NO;
    auto lin = [](double c) {
      return (c <= 0.03928) ? (c / 12.92) : std::pow((c + 0.055) / 1.055, 2.4);
    };
    out.singleLuma =
        0.2126 * lin(meanR) + 0.7152 * lin(meanG) + 0.0722 * lin(meanB);
    out.singleMarkColor = [NSColor colorWithSRGBRed:meanR
                                              green:meanG
                                               blue:meanB
                                              alpha:1.0];
    [[self sharedCache] setObject:out forKey:cacheKey];
    return out;
  }

  // 2) Multi-color icon -> PinGlow.compute (6 hue buckets + 36 angular bins)
  out.isMultiColor = YES;
  double score[6] = {0}, rs[6] = {0}, gs[6] = {0}, bs[6] = {0}, npx[6] = {0};
  double cov[36] = {0};
  double ta = 0, tr = 0, tg = 0, tb = 0;
  constexpr double kHalf = (kDim - 1) * 0.5;
  constexpr double kRadNorm = kDim * 0.375;

  for (int i = 0; i < kDim * kDim; ++i) {
    double a = d[i * 4 + 3] / 255.0;
    if (a < 0.25) {
      continue;
    }
    double r = std::clamp((d[i * 4 + 0] / 255.0) / a, 0.0, 1.0);
    double g = std::clamp((d[i * 4 + 1] / 255.0) / a, 0.0, 1.0);
    double b = std::clamp((d[i * 4 + 2] / 255.0) / a, 0.0, 1.0);
    ta += a;
    tr += r * a;
    tg += g * a;
    tb += b * a;
    double mx = std::max({r, g, b});
    double mn = std::min({r, g, b});
    double sat = (mx <= 0.0) ? 0.0 : ((mx - mn) / mx);
    if (mx < 0.12) {
      continue;
    }
    double dx = (i % kDim) - kHalf;
    double dy = kHalf - (i / kDim);
    double rr = std::sqrt(dx * dx + dy * dy);
    double rw = std::clamp(rr / kRadNorm, 0.15, 1.0);
    double th = std::atan2(dy, dx);
    if (th < 0.0) {
      th += 2.0 * M_PI;
    }
    int bin = static_cast<int>(std::floor(th / (2.0 * M_PI) * 36.0)) % 36;
    if (bin < 0) {
      bin = 0;
    }
    cov[bin] += rw;

    double hue = 0.0;
    if (mx != mn) {
      if (mx == r) {
        hue = std::fmod((g - b) / (mx - mn), 6.0);
      } else if (mx == g) {
        hue = ((b - r) / (mx - mn)) + 2.0;
      } else {
        hue = ((r - g) / (mx - mn)) + 4.0;
      }
      if (hue < 0.0) {
        hue += 6.0;
      }
    }
    int hb = static_cast<int>(hue) % 6;
    double wgt = 0.25 + sat;
    score[hb] += wgt;
    rs[hb] += r * wgt;
    gs[hb] += g * wgt;
    bs[hb] += b * wgt;
    npx[hb] += 1.0;
  }

  if (ta <= 0.0) {
    return nil;
  }
  const double ar = tr / ta, ag = tg / ta, ab = tb / ta;
  int order[3] = {-1, -1, -1};
  for (int pick = 0; pick < 3; ++pick) {
    int best = -1;
    for (int h = 0; h < 6; ++h) {
      if (npx[h] <= 0.0) {
        continue;
      }
      bool used = false;
      for (int p = 0; p < pick; ++p) {
        if (order[p] == h) {
          used = true;
        }
      }
      if (used) {
        continue;
      }
      double dr = rs[h] / score[h], dg = gs[h] / score[h], db = bs[h] / score[h];
      double mx = std::max({dr, dg, db});
      double mn = std::min({dr, dg, db});
      if ((mx <= 0.0 ? 0.0 : (mx - mn) / mx) < 0.25) {
        continue;
      }
      if (best < 0 || npx[h] > npx[best] ||
          (npx[h] == npx[best] && h < best)) {
        best = h;
      }
    }
    order[pick] = best;
  }

  NSColor* avg = [NSColor colorWithSRGBRed:ar green:ag blue:ab alpha:1.0];
  std::vector<NSColor*> domCols;
  for (int pick = 0; pick < 3; ++pick) {
    int h = order[pick];
    if (h < 0) {
      continue;
    }
    double dr = rs[h] / score[h], dg = gs[h] / score[h], db = bs[h] / score[h];
    NSColor* mixed = [NSColor colorWithSRGBRed:(dr * 0.82 + ar * 0.18)
                                         green:(dg * 0.82 + ag * 0.18)
                                          blue:(db * 0.82 + ab * 0.18)
                                         alpha:1.0];
    domCols.push_back([self cappedLight:mixed cap:0.90]);
  }
  if (domCols.empty()) {
    domCols = {avg, avg, avg};
  }
  while (domCols.size() < 3) {
    domCols.push_back(domCols[0]);
  }

  out->_glowColors = {avg, domCols[0], domCols[1], domCols[2]};
  double maxCov = 0.0;
  for (double c : cov) {
    maxCov = std::max(maxCov, c);
  }
  out->_glowCoverage.resize(36);
  for (int i = 0; i < 36; ++i) {
    out->_glowCoverage[i] = (maxCov > 0.0) ? (cov[i] / maxCov) : 1.0;
  }

  // PinGlow.background(g: 1.0)
  double luma = 0.299 * ar + 0.587 * ag + 0.114 * ab;
  NSColor* bgMix = [NSColor colorWithSRGBRed:(ar * 0.45 + luma * 0.55)
                                       green:(ag * 0.45 + luma * 0.55)
                                        blue:(ab * 0.45 + luma * 0.55)
                                       alpha:0.30];
  out.backgroundTint = [self cappedLight:bgMix cap:0.30];

  // BlurredIcon (CIGaussianBlur radius = 5)
  CGImageRef srcCG = [rep CGImage];
  if (srcCG) {
    CIImage* ciIn = [CIImage imageWithCGImage:srcCG];
    CIFilter* filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [filter setValue:ciIn forKey:kCIInputImageKey];
    [filter setValue:@(5.0) forKey:kCIInputRadiusKey];
    CIImage* ciOut = filter.outputImage;
    if (ciOut) {
      CGImageRef blurredCG =
          [[self sharedCIContext] createCGImage:ciOut fromRect:ciOut.extent];
      if (blurredCG) {
        out.blurredCGImageObj = CFBridgingRelease(blurredCG);
      }
    }
  }

  [[self sharedCache] setObject:out forKey:cacheKey];
  return out;
}

- (NSColor*)conicColorAtAngle:(CGFloat)angle {
  if (_glowColors.size() < 4) {
    return NSColor.systemBlueColor;
  }
  NSColor* cols[3] = {_glowColors[1], _glowColors[2], _glowColors[3]};
  CGFloat t = std::fmod(angle, 2.0 * M_PI);
  if (t < 0.0) {
    t += 2.0 * M_PI;
  }
  CGFloat u = (t / (2.0 * M_PI)) * 3.0;
  int idx = static_cast<int>(std::floor(u)) % 3;
  CGFloat f = u - std::floor(u);
  NSColor* a = cols[idx];
  NSColor* b = cols[(idx + 1) % 3];
  CGFloat ar = 0, ag = 0, ab = 0, aa = 1;
  CGFloat br = 0, bg = 0, bb = 0, ba = 1;
  [[a colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getRed:&ar
                                                         green:&ag
                                                          blue:&ab
                                                         alpha:&aa];
  [[b colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getRed:&br
                                                         green:&bg
                                                          blue:&bb
                                                         alpha:&ba];
  return [NSColor colorWithSRGBRed:(ar + (br - ar) * f)
                             green:(ag + (bg - ag) * f)
                              blue:(ab + (bb - ab) * f)
                             alpha:1.0];
}

- (id)conicRingCGImageForSize:(NSSize)size
                    lineWidth:(CGFloat)lwPts
                       radius:(CGFloat)radius {
  if (!_isMultiColor || size.width < 8.0 || size.height < 8.0) {
    return nil;
  }
  const CGFloat scale = 3.0;
  const int W = static_cast<int>(std::ceil(size.width * scale));
  const int H = static_cast<int>(std::ceil(size.height * scale));
  NSString* key =
      [NSString stringWithFormat:@"%dx%d|%.1f|%.1f", W, H, lwPts, radius];
  id existing = _ringImageCache[key];
  if (existing) {
    return existing;
  }

  NSMutableArray* cgColors = [NSMutableArray arrayWithCapacity:37];
  NSMutableArray<NSNumber*>* locs = [NSMutableArray arrayWithCapacity:37];
  for (int s = 0; s <= 36; ++s) {
    CGFloat ang = (static_cast<CGFloat>(s) / 36.0) * 2.0 * M_PI;
    NSColor* cc = [self conicColorAtAngle:ang];
    CGFloat cv = _glowCoverage.empty() ? 1.0 : _glowCoverage[s % 36];
    cv = std::clamp(cv, 0.0, 1.0);
    cv = cv * cv * (3.0 - 2.0 * cv);
    NSColor* stop = [cc colorWithAlphaComponent:(0.60 + 0.40 * cv)];
    [cgColors addObject:(__bridge id)stop.CGColor];
    [locs addObject:@(static_cast<double>(s) / 36.0)];
  }

  CAGradientLayer* grad = [CAGradientLayer layer];
  grad.type = kCAGradientLayerConic;
  grad.colors = cgColors;
  grad.locations = locs;
  grad.startPoint = CGPointMake(0.5, 0.5);
  grad.endPoint = CGPointMake(1.0, 0.5);
  grad.frame = CGRectMake(0, 0, W, H);

  CGFloat lw = std::clamp<CGFloat>(lwPts, 1.0, 6.0) * scale;
  CGFloat cr = std::max<CGFloat>(0.5, radius * scale - lw * 0.5);
  CGRect strokeRect = CGRectMake(lw * 0.5, lw * 0.5, W - lw, H - lw);
  CGPathRef rpath =
      CGPathCreateWithRoundedRect(strokeRect, cr, cr, nullptr);
  CAShapeLayer* mask = [CAShapeLayer layer];
  mask.path = rpath;
  CGPathRelease(rpath);
  mask.fillColor = nullptr;
  mask.strokeColor = NSColor.whiteColor.CGColor;
  mask.lineWidth = lw;
  mask.frame = grad.frame;
  grad.mask = mask;

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      nullptr, W, H, 8, W * 4, cs,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return nil;
  }
  [grad renderInContext:ctx];
  CGImageRef outImg = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  if (!outImg) {
    return nil;
  }
  id bridged = CFBridgingRelease(outImg);
  _ringImageCache[key] = bridged;
  return bridged;
}

@end

// -----------------------------------------------------------------------------
// Netnyahoo Pinned Tile View (PinnedGrid.tsx + DockSelection.swift)
// -----------------------------------------------------------------------------
@interface LightPinnedTileView : NSView
@property(nonatomic, assign) int tabIndex;
@property(nonatomic, copy) void (^onSelect)(int index);
@property(nonatomic, copy) void (^onClose)(int index);
@property(nonatomic, copy) void (^onResetPin)(int index);
@property(nonatomic, copy) void (^onDragAtScreenPoint)(int index, NSPoint screenPt);
@property(nonatomic, copy) NSMenu* (^menuProvider)(int index);
- (void)configureWithTitle:(NSString*)title
                   urlSpec:(NSString*)urlSpec
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  selected:(BOOL)selected
                   audible:(BOOL)audible
                     muted:(BOOL)muted;
@end

@implementation LightPinnedTileView {
  CALayer* __strong _faceLayer;
  CALayer* __strong _clipTileLayer;
  CALayer* __strong _bgLayer;
  CALayer* __strong _blurredTintLayer;
  CALayer* __strong _borderRingLayer;
  CALayer* __strong _conicGlowLayer;
  CALayer* __strong _conicGlowPressLayer;
  NSImageView* __strong _iconView;
  NSImageView* __strong _audioBadgeView;
  LightPinVisualAnalysis* __strong _analysis;
  NSTrackingArea* __strong _trackingArea;
  BOOL _selected;
  BOOL _hovered;
  BOOL _pressed;
  NSPoint _dragStartScreen;
  BOOL _dragging;
}

@synthesize tabIndex = _tabIndex;
@synthesize onSelect = _onSelect;
@synthesize onClose = _onClose;
@synthesize onResetPin = _onResetPin;
@synthesize onDragAtScreenPoint = _onDragAtScreenPoint;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;

    _faceLayer = [CALayer layer];
    _faceLayer.masksToBounds = NO;
    [self.layer addSublayer:_faceLayer];

    _clipTileLayer = [CALayer layer];
    _clipTileLayer.masksToBounds = YES;
    _clipTileLayer.cornerRadius = 10.0;
    _clipTileLayer.cornerCurve = kCACornerCurveContinuous;
    [_faceLayer addSublayer:_clipTileLayer];

    _bgLayer = [CALayer layer];
    [_clipTileLayer addSublayer:_bgLayer];

    _blurredTintLayer = [CALayer layer];
    _blurredTintLayer.opacity = 0.22f;
    _blurredTintLayer.contentsGravity = kCAGravityResizeAspectFill;
    _blurredTintLayer.masksToBounds = YES;
    [_clipTileLayer addSublayer:_blurredTintLayer];

    _borderRingLayer = [CALayer layer];
    _borderRingLayer.cornerRadius = 10.0;
    _borderRingLayer.cornerCurve = kCACornerCurveContinuous;
    [_faceLayer addSublayer:_borderRingLayer];

    _conicGlowLayer = [CALayer layer];
    _conicGlowLayer.contentsGravity = kCAGravityResize;
    _conicGlowLayer.contentsScale = 3.0;
    [_faceLayer addSublayer:_conicGlowLayer];

    _conicGlowPressLayer = [CALayer layer];
    _conicGlowPressLayer.contentsGravity = kCAGravityResize;
    _conicGlowPressLayer.contentsScale = 3.0;
    _conicGlowPressLayer.opacity = 0.0f;
    [_faceLayer addSublayer:_conicGlowPressLayer];

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _audioBadgeView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _audioBadgeView.imageScaling = NSImageScaleProportionallyDown;
    _audioBadgeView.hidden = YES;
    [self addSubview:_audioBadgeView];
  }
  return self;
}

- (void)configureWithTitle:(NSString*)title
                   urlSpec:(NSString*)urlSpec
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  selected:(BOOL)selected
                   audible:(BOOL)audible
                     muted:(BOOL)muted {
  _selected = selected;
  self.toolTip = title.length > 0 ? title : (urlSpec ?: @"Pinned Tab");

  if (isLoading) {
    _iconView.image = SymbolImage(@"arrow.trianglehead.2.clockwise", 13.0,
                                  NSFontWeightMedium);
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
    _analysis = nil;
  } else if (favicon) {
    _iconView.image = favicon;
    _iconView.contentTintColor = nil;
    _analysis =
        [LightPinVisualAnalysis analysisForFavicon:favicon
                                          cacheKey:(urlSpec ?: title ?: @"pin")];
  } else {
    _iconView.image = SymbolImage(
        @"globe", 14.0, selected ? NSFontWeightMedium : NSFontWeightRegular);
    _iconView.contentTintColor =
        selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
    _analysis = nil;
  }

  if (muted || audible) {
    _audioBadgeView.hidden = NO;
    _audioBadgeView.image =
        SymbolImage(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", 8.5,
                    NSFontWeightSemibold);
    _audioBadgeView.contentTintColor = NSColor.secondaryLabelColor;
  } else {
    _audioBadgeView.hidden = YES;
  }

  [self updateTileLayers];
  [self setNeedsLayout:YES];
}

- (void)layout {
  [super layout];
  NSRect b = self.bounds;
  CGFloat w = b.size.width;
  CGFloat h = b.size.height;
  _iconView.frame = NSMakeRect(std::floor((w - 16.0) * 0.5),
                               std::floor((h - 16.0) * 0.5), 16.0, 16.0);
  _audioBadgeView.frame = NSMakeRect(w - 15.0, h - 13.0, 11.0, 10.0);
  [self updateTileLayers];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateTileLayers];
}

- (void)updateTileLayers {
  NSRect b = self.bounds;
  if (NSIsEmptyRect(b)) {
    return;
  }
  const bool dark = IsViewDarkAppearance(self);
  constexpr CGFloat kRadius = 10.0;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  _faceLayer.bounds = b;
  _faceLayer.position = CGPointMake(NSMidX(b), NSMidY(b));
  _clipTileLayer.frame = b;
  _bgLayer.frame = b;
  _blurredTintLayer.frame = CGRectInset(b, -b.size.width * 0.75,
                                        -b.size.height * 0.75);
  _borderRingLayer.frame = b;
  _conicGlowLayer.frame = b;
  _conicGlowPressLayer.frame = b;

  if (_selected) {
    if (_analysis && _analysis.isMultiColor) {
      // Colorful favicon -> PIVOT / Netnyahoo conic glow ring + blurred tint!
      _clipTileLayer.cornerCurve = kCACornerCurveCircular;
      _bgLayer.backgroundColor = _analysis.backgroundTint.CGColor;
      _blurredTintLayer.contents = _analysis.blurredCGImageObj;
      _blurredTintLayer.hidden = (_analysis.blurredCGImageObj == nil);
      _borderRingLayer.hidden = YES;
      _conicGlowLayer.contents =
          [_analysis conicRingCGImageForSize:b.size
                                   lineWidth:2.0
                                      radius:kRadius];
      _conicGlowPressLayer.contents =
          [_analysis conicRingCGImageForSize:b.size
                                   lineWidth:3.0
                                      radius:kRadius];
      _conicGlowLayer.hidden = NO;
      _conicGlowPressLayer.hidden = NO;
    } else if (_analysis) {
      // Single-color favicon -> iconBacking.ts contrasting tray + 2pt rim!
      _clipTileLayer.cornerCurve = kCACornerCurveContinuous;
      _blurredTintLayer.hidden = YES;
      _conicGlowLayer.hidden = YES;
      _conicGlowPressLayer.hidden = YES;
      _borderRingLayer.hidden = NO;
      _borderRingLayer.borderWidth = 2.0;

      NSColor* fill = nil;
      NSColor* rim = nil;
      if (_analysis.singleLuma > 0.85) {
        fill = [NSColor colorWithWhite:0.0 alpha:0.28];
        rim = [NSColor colorWithWhite:(dark ? 1.0 : 0.0) alpha:0.55];
      } else if (_analysis.singleLuma < 0.15 && dark) {
        fill = [NSColor colorWithWhite:1.0 alpha:0.16];
        rim = [NSColor colorWithWhite:1.0 alpha:0.50];
      } else {
        fill = [_analysis.singleMarkColor colorWithAlphaComponent:0.16];
        rim = [_analysis.singleMarkColor colorWithAlphaComponent:0.85];
      }
      _bgLayer.backgroundColor = fill.CGColor;
      _borderRingLayer.borderColor = rim.CGColor;
    } else {
      // Fallback active tile (globe / NTP)
      _clipTileLayer.cornerCurve = kCACornerCurveContinuous;
      _blurredTintLayer.hidden = YES;
      _conicGlowLayer.hidden = YES;
      _conicGlowPressLayer.hidden = YES;
      _borderRingLayer.hidden = NO;
      _borderRingLayer.borderWidth = 2.0;
      _bgLayer.backgroundColor =
          [NSColor colorWithWhite:1.0 alpha:(dark ? 0.25 : 0.70)].CGColor;
      _borderRingLayer.borderColor =
          [NSColor colorWithWhite:(dark ? 1.0 : 0.0)
                            alpha:(dark ? 0.28 : 0.14)]
              .CGColor;
    }
  } else {
    // Resting / Hover / Pressed un-selected pinned tile (theme.ts)
    _clipTileLayer.cornerCurve = kCACornerCurveContinuous;
    _blurredTintLayer.hidden = YES;
    _conicGlowLayer.hidden = YES;
    _conicGlowPressLayer.hidden = YES;
    _borderRingLayer.hidden = NO;
    _borderRingLayer.borderWidth = 0.5;
    _borderRingLayer.borderColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.14]
              : [NSColor colorWithWhite:0.0 alpha:0.18])
            .CGColor;

    NSColor* restingFill = nil;
    if (_pressed) {
      restingFill = dark ? [NSColor colorWithWhite:1.0 alpha:0.31]
                         : [NSColor colorWithWhite:1.0 alpha:0.70];
    } else if (_hovered) {
      restingFill = dark ? [NSColor colorWithWhite:1.0 alpha:0.16]
                         : [NSColor colorWithWhite:1.0 alpha:0.55];
    } else {
      restingFill = dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
                         : [NSColor colorWithWhite:0.0 alpha:0.05];
    }
    _bgLayer.backgroundColor = restingFill.CGColor;
  }

  [CATransaction commit];
}

- (void)animatePressState:(BOOL)pressed {
  if (_pressed == pressed) {
    return;
  }
  _pressed = pressed;
  [self updateTileLayers];

  const CGFloat targetScale = pressed ? 0.95 : 1.0;
  const float targetPressRing = pressed ? 1.0f : 0.0f;
  const CFTimeInterval dur = pressed ? 0.10 : 0.08;

  [CATransaction begin];
  [CATransaction setAnimationDuration:dur];
  [CATransaction
      setAnimationTimingFunction:[CAMediaTimingFunction
                                     functionWithName:
                                         kCAMediaTimingFunctionEaseOut]];
  _faceLayer.transform =
      CATransform3DMakeScale(targetScale, targetScale, 1.0);
  _iconView.layer.transform =
      CATransform3DMakeScale(targetScale, targetScale, 1.0);
  _conicGlowPressLayer.opacity = targetPressRing;
  [CATransaction commit];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self updateTileLayers];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  if (_pressed) {
    [self animatePressState:NO];
  } else {
    [self updateTileLayers];
  }
}

- (void)mouseDown:(NSEvent*)event {
  _dragStartScreen = [self.window convertPointToScreen:event.locationInWindow];
  _dragging = NO;
  [self animatePressState:YES];
  if (event.clickCount == 2) {
    if (_onResetPin) {
      _onResetPin(_tabIndex);
    }
  } else if (_onSelect) {
    _onSelect(_tabIndex);
  }
}

- (void)mouseDragged:(NSEvent*)event {
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (!_dragging && std::hypot(scr.x - _dragStartScreen.x,
                              scr.y - _dragStartScreen.y) >= 4.0) {
    _dragging = YES;
  }
  if (_dragging && _onDragAtScreenPoint) {
    _onDragAtScreenPoint(_tabIndex, scr);
  }
}

- (void)mouseUp:(NSEvent*)event {
  _dragging = NO;
  [self animatePressState:NO];
}

- (void)otherMouseUp:(NSEvent*)event {
  if (event.buttonNumber == 2 && _onClose) {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(local, self.bounds)) {
      _onClose(_tabIndex);
    }
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider(_tabIndex) : nil;
}

@end

// -----------------------------------------------------------------------------
// Netnyahoo Tab Group Block View (GroupBlock.tsx: 12pt tinted card + 34pt
// header with favicon/color dot, inline rename, chevron, +/x hover buttons,
// and full Group context menu).
// -----------------------------------------------------------------------------
@interface LightTabGroupBlockView : NSView <NSTextFieldDelegate>
@property(nonatomic, copy) NSString* groupToken;
@property(nonatomic, assign) tab_groups::TabGroupColorId colorId;
@property(nonatomic, assign) BOOL collapsed;
@property(nonatomic, readonly) BOOL isRenaming;
@property(nonatomic, copy) void (^onToggleCollapse)(NSString* token);
@property(nonatomic, copy) void (^onCommitRename)(NSString* token,
                                                  NSString* newTitle);
@property(nonatomic, copy) void (^onCancelRename)(NSString* token);
@property(nonatomic, copy) void (^onNewTabInGroup)(NSString* token);
@property(nonatomic, copy) void (^onCloseGroup)(NSString* token);
@property(nonatomic, copy) NSMenu* (^menuProvider)(NSString* token);

- (void)configureWithToken:(NSString*)token
                     title:(NSString*)title
             fallbackLabel:(NSString*)fallbackLabel
                   colorId:(tab_groups::TabGroupColorId)colorId
                 collapsed:(BOOL)collapsed
           firstTabFavicon:(NSImage*)favicon
                  renaming:(BOOL)renaming;
- (void)focusInlineRenameEditor;
@end

@implementation LightTabGroupBlockView {
  NSImageView* __strong _leadIconView;
  NSView* __strong _colorDotView;
  NSTextField* __strong _titleLabel;
  NSImageView* __strong _chevronView;
  NSTextField* __strong _renameField;
  LightIconButton* __strong _addTabButton;
  LightIconButton* __strong _closeGroupButton;
  NSTrackingArea* __strong _headerTrackingArea;
  NSString* __strong _rawTitle;
  NSString* __strong _displayLabel;
  BOOL _headerHovered;
  BOOL _isRenaming;
  BOOL _didHandleRenameEnd;
}

@synthesize groupToken = _groupToken;
@synthesize colorId = _colorId;
@synthesize collapsed = _collapsed;
@synthesize isRenaming = _isRenaming;
@synthesize onToggleCollapse = _onToggleCollapse;
@synthesize onCommitRename = _onCommitRename;
@synthesize onCancelRename = _onCancelRename;
@synthesize onNewTabInGroup = _onNewTabInGroup;
@synthesize onCloseGroup = _onCloseGroup;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;

    _colorDotView = [[NSView alloc] initWithFrame:NSZeroRect];
    _colorDotView.wantsLayer = YES;
    _colorDotView.layer.cornerRadius = 5.0;
    [self addSubview:_colorDotView];

    _leadIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _leadIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_leadIconView];

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    _titleLabel.textColor = NSColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.maximumNumberOfLines = 1;
    [self addSubview:_titleLabel];

    _chevronView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _chevronView.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_chevronView];

    _renameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _renameField.bordered = NO;
    _renameField.bezeled = NO;
    _renameField.drawsBackground = YES;
    _renameField.backgroundColor =
        [NSColor.labelColor colorWithAlphaComponent:0.10];
    _renameField.focusRingType = NSFocusRingTypeNone;
    _renameField.font =
        [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    _renameField.textColor = NSColor.labelColor;
    _renameField.wantsLayer = YES;
    _renameField.layer.cornerRadius = 5.0;
    _renameField.hidden = YES;
    _renameField.delegate = self;
    [self addSubview:_renameField];

    __weak __typeof(self) weakSelf = self;
    _addTabButton =
        [[LightIconButton alloc] initWithSymbol:@"plus"
                                      pointSize:10.0
                                         weight:NSFontWeightSemibold
                                        toolTip:@"New Tab in Group"];
    _addTabButton.cornerRadius = 5.0;
    _addTabButton.hidden = YES;
    _addTabButton.actionBlock = ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s.onNewTabInGroup) {
        s.onNewTabInGroup(s.groupToken);
      }
    };
    [self addSubview:_addTabButton];

    _closeGroupButton =
        [[LightIconButton alloc] initWithSymbol:@"xmark"
                                      pointSize:9.5
                                         weight:NSFontWeightSemibold
                                        toolTip:@"Close Group"];
    _closeGroupButton.cornerRadius = 5.0;
    _closeGroupButton.hidden = YES;
    _closeGroupButton.actionBlock = ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s.onCloseGroup) {
        s.onCloseGroup(s.groupToken);
      }
    };
    [self addSubview:_closeGroupButton];
  }
  return self;
}

- (void)configureWithToken:(NSString*)token
                     title:(NSString*)title
             fallbackLabel:(NSString*)fallbackLabel
                   colorId:(tab_groups::TabGroupColorId)colorId
                 collapsed:(BOOL)collapsed
           firstTabFavicon:(NSImage*)favicon
                  renaming:(BOOL)renaming {
  _groupToken = [token copy];
  _rawTitle = title ?: @"";
  _displayLabel =
      (title.length > 0) ? title : (fallbackLabel.length > 0 ? fallbackLabel : @"Untitled");
  _colorId = colorId;
  _collapsed = collapsed;

  NSColor* gc = GroupColorForId(colorId);
  if (favicon) {
    _leadIconView.image = favicon;
    _leadIconView.hidden = NO;
    _colorDotView.layer.backgroundColor = gc.CGColor;
    _colorDotView.layer.cornerRadius = 3.0;
  } else {
    _leadIconView.hidden = YES;
    _colorDotView.layer.backgroundColor = gc.CGColor;
    _colorDotView.layer.cornerRadius = 5.0;
  }

  _titleLabel.stringValue = _displayLabel;
  _chevronView.image =
      SymbolImage(collapsed ? @"chevron.right" : @"chevron.down", 9.0,
                  NSFontWeightSemibold);
  _chevronView.contentTintColor =
      [NSColor.labelColor colorWithAlphaComponent:0.55];

  if (renaming != _isRenaming) {
    _isRenaming = renaming;
    _didHandleRenameEnd = NO;
    if (_isRenaming) {
      _renameField.stringValue = _rawTitle;
      _renameField.placeholderString = _displayLabel;
    }
  }
  _renameField.hidden = !_isRenaming;
  _titleLabel.hidden = _isRenaming;
  _chevronView.hidden = _isRenaming;
  BOOL showHoverActions = _headerHovered && !_isRenaming;
  _addTabButton.hidden = !showHoverActions;
  _closeGroupButton.hidden = !showHoverActions;

  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)focusInlineRenameEditor {
  if (!_isRenaming || !self.window) {
    return;
  }
  [self.window makeFirstResponder:_renameField];
  if (_renameField.currentEditor) {
    [_renameField.currentEditor selectAll:nil];
  }
}

- (void)layout {
  [super layout];
  CGFloat w = self.bounds.size.width;
  constexpr CGFloat kHdrH = 34.0;

  if (!_leadIconView.isHidden) {
    _leadIconView.frame = NSMakeRect(10.0, 9.0, 15.0, 15.0);
    _colorDotView.frame = NSMakeRect(21.0, 19.0, 6.0, 6.0);
  } else {
    _colorDotView.frame = NSMakeRect(12.0, 12.0, 10.0, 10.0);
  }

  _closeGroupButton.frame = NSMakeRect(w - 26.0, 7.0, 20.0, 20.0);
  _addTabButton.frame = NSMakeRect(w - 48.0, 7.0, 20.0, 20.0);

  CGFloat textX = 32.0;
  CGFloat rightLim = (!_closeGroupButton.isHidden) ? (w - 52.0) : (w - 10.0);
  if (_isRenaming) {
    _renameField.frame =
        NSMakeRect(textX - 2.0, 6.0, std::max<CGFloat>(40.0, w - textX - 8.0),
                   22.0);
  } else {
    NSSize fit = [_titleLabel sizeThatFits:NSMakeSize(500.0, kHdrH)];
    CGFloat maxTitleW = std::max<CGFloat>(0.0, rightLim - textX - 16.0);
    CGFloat titleW = std::min<CGFloat>(std::ceil(fit.width), maxTitleW);
    CGFloat titleH = std::ceil(fit.height);
    _titleLabel.frame = NSMakeRect(textX, std::floor((kHdrH - titleH) * 0.5),
                                   titleW, titleH);
    _chevronView.frame = NSMakeRect(textX + titleW + 4.0,
                                    std::floor((kHdrH - 10.0) * 0.5), 10.0,
                                    10.0);
  }
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_headerTrackingArea) {
    [self removeTrackingArea:_headerTrackingArea];
  }
  NSRect hdrRect = NSMakeRect(0.0, 0.0, self.bounds.size.width, 34.0);
  _headerTrackingArea = [[NSTrackingArea alloc]
      initWithRect:hdrRect
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_headerTrackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _headerHovered = YES;
  if (!_isRenaming) {
    _addTabButton.hidden = NO;
    _closeGroupButton.hidden = NO;
  }
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _headerHovered = NO;
  _addTabButton.hidden = YES;
  _closeGroupButton.hidden = YES;
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if (local.y > 34.0 || _isRenaming) {
    return;
  }
  if (event.clickCount == 2) {
    _isRenaming = YES;
    _didHandleRenameEnd = NO;
    _renameField.stringValue = _rawTitle ?: @"";
    _renameField.placeholderString = _displayLabel ?: @"Group Name";
    _renameField.hidden = NO;
    _titleLabel.hidden = YES;
    _chevronView.hidden = YES;
    _addTabButton.hidden = YES;
    _closeGroupButton.hidden = YES;
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    [self focusInlineRenameEditor];
    return;
  }
  if (_onToggleCollapse) {
    _onToggleCollapse(_groupToken);
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if (local.y <= 34.0 && _menuProvider) {
    return _menuProvider(_groupToken);
  }
  return nil;
}

- (void)controlTextDidEndEditing:(NSNotification*)obj {
  if (obj.object == _renameField && _isRenaming && !_didHandleRenameEnd) {
    _didHandleRenameEnd = YES;
    NSString* text = _renameField.stringValue ?: @"";
    _isRenaming = NO;
    if (_onCommitRename) {
      _onCommitRename(_groupToken, text);
    }
  }
}

- (BOOL)control:(NSControl*)control
               textView:(NSTextView*)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(insertNewline:)) {
    _didHandleRenameEnd = YES;
    NSString* text = _renameField.stringValue ?: @"";
    _isRenaming = NO;
    [self.window makeFirstResponder:nil];
    if (_onCommitRename) {
      _onCommitRename(_groupToken, text);
    }
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    _didHandleRenameEnd = YES;
    _isRenaming = NO;
    [self.window makeFirstResponder:nil];
    if (_onCancelRename) {
      _onCancelRename(_groupToken);
    }
    return YES;
  }
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSColor* gc = GroupColorForId(_colorId);
  NSRect inset = NSInsetRect(self.bounds, 0.25, 0.25);
  NSBezierPath* cardPath = [NSBezierPath bezierPathWithRoundedRect:inset
                                                           xRadius:12.0
                                                           yRadius:12.0];
  [[gc colorWithAlphaComponent:0.16] setFill];
  [cardPath fill];
  [[gc colorWithAlphaComponent:0.32] setStroke];
  cardPath.lineWidth = 0.5;
  [cardPath stroke];

  if (_headerHovered && !_isRenaming) {
    NSRect hdrRect = NSMakeRect(2.0, 2.0, self.bounds.size.width - 4.0, 30.0);
    NSBezierPath* hdrPath = [NSBezierPath bezierPathWithRoundedRect:hdrRect
                                                            xRadius:10.0
                                                            yRadius:10.0];
    [[NSColor.labelColor colorWithAlphaComponent:0.09] setFill];
    [hdrPath fill];
  }
}

@end

// -----------------------------------------------------------------------------
// Single vertical unpinned tab row inside the Liquid Glass sidebar.
// -----------------------------------------------------------------------------
@interface LightTabRowView : NSView
@property(nonatomic, assign) int tabIndex;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, assign) BOOL pinned;
@property(nonatomic, copy) void (^onSelect)(int index);
@property(nonatomic, copy) void (^onClose)(int index);
@property(nonatomic, copy) void (^onDragAtScreenPoint)(int index, NSPoint screenPt);
@property(nonatomic, copy) NSMenu* (^menuProvider)(int index);

- (void)configureWithTitle:(NSString*)title
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  selected:(BOOL)selected
                    pinned:(BOOL)pinned;
@end

@implementation LightTabRowView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _titleField;
  LightIconButton* __strong _closeButton;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  NSPoint _dragStartScreen;
  BOOL _dragging;
}

@synthesize tabIndex = _tabIndex;
@synthesize selected = _selected;
@synthesize pinned = _pinned;
@synthesize onSelect = _onSelect;
@synthesize onClose = _onClose;
@synthesize onDragAtScreenPoint = _onDragAtScreenPoint;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _titleField = [NSTextField labelWithString:@""];
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleField.maximumNumberOfLines = 1;
    _titleField.drawsBackground = NO;
    _titleField.bezeled = NO;
    _titleField.editable = NO;
    _titleField.selectable = NO;
    [self addSubview:_titleField];

    __weak __typeof(self) weakSelf = self;
    _closeButton = [[LightIconButton alloc] initWithSymbol:@"xmark"
                                                 pointSize:10.0
                                                    weight:NSFontWeightSemibold
                                                   toolTip:@"Close Tab"];
    _closeButton.cornerRadius = 5.0;
    _closeButton.hidden = YES;
    _closeButton.actionBlock = ^{
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf && strongSelf.onClose) {
        strongSelf.onClose(strongSelf.tabIndex);
      }
    };
    [self addSubview:_closeButton];
  }
  return self;
}

- (void)configureWithTitle:(NSString*)title
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  selected:(BOOL)selected
                    pinned:(BOOL)pinned {
  _selected = selected;
  _pinned = pinned;

  NSString* displayTitle = title.length > 0 ? title : @"New Tab";
  _titleField.stringValue = displayTitle;
  _titleField.font = [NSFont
      systemFontOfSize:13.0
                weight:selected ? NSFontWeightMedium : NSFontWeightRegular];
  _titleField.textColor =
      selected ? NSColor.labelColor : NSColor.secondaryLabelColor;

  if (isLoading) {
    _iconView.image = SymbolImage(@"arrow.trianglehead.2.clockwise", 12.0,
                                  NSFontWeightMedium);
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
  } else if (favicon) {
    _iconView.image = favicon;
    _iconView.contentTintColor = nil;
  } else {
    _iconView.image =
        SymbolImage(@"globe", 13.0,
                    selected ? NSFontWeightMedium : NSFontWeightRegular);
    _iconView.contentTintColor =
        selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
  }

  _closeButton.hidden = !(_hovered || _selected);
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  CGFloat w = self.bounds.size.width;

  _iconView.frame = NSMakeRect(9.0, std::floor((h - 16.0) * 0.5), 16.0, 16.0);

  BOOL showClose = !_closeButton.isHidden;
  CGFloat closeSize = 20.0;
  _closeButton.frame =
      NSMakeRect(w - closeSize - 6.0, std::floor((h - closeSize) * 0.5),
                 closeSize, closeSize);

  CGFloat titleX = 33.0;
  CGFloat titleRight = showClose ? (w - closeSize - 10.0) : (w - 8.0);
  NSSize fit = [_titleField sizeThatFits:NSMakeSize(1000.0, h)];
  CGFloat titleH = std::min(h, std::ceil(fit.height));
  _titleField.frame = NSMakeRect(titleX, std::floor((h - titleH) * 0.5),
                                 std::max<CGFloat>(0.0, titleRight - titleX),
                                 titleH);
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  _closeButton.hidden = NO;
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _closeButton.hidden = !_selected;
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
  _dragStartScreen = [self.window convertPointToScreen:event.locationInWindow];
  _dragging = NO;
  if (_onSelect) {
    _onSelect(_tabIndex);
  }
}

- (void)mouseDragged:(NSEvent*)event {
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (!_dragging && std::hypot(scr.x - _dragStartScreen.x,
                              scr.y - _dragStartScreen.y) >= 4.0) {
    _dragging = YES;
  }
  if (_dragging && _onDragAtScreenPoint) {
    _onDragAtScreenPoint(_tabIndex, scr);
  }
}

- (void)mouseUp:(NSEvent*)event {
  _dragging = NO;
}

- (void)otherMouseUp:(NSEvent*)event {
  if (event.buttonNumber == 2 && _onClose) {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(local, self.bounds)) {
      _onClose(_tabIndex);
    }
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider(_tabIndex) : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (!_selected && !_hovered) {
    return;
  }
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:9.0
                                                       yRadius:9.0];
  CGFloat fillAlpha = _selected ? 0.16 : 0.08;
  [[NSColor.labelColor colorWithAlphaComponent:fillAlpha] setFill];
  [path fill];

  if (_selected) {
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke];
    path.lineWidth = 0.5;
    [path stroke];
  }
}

@end

// -----------------------------------------------------------------------------
// Rounded address bar container inside the sidebar header (triggers the
// rightward-expanding Liquid Glass URL popup on click).
// -----------------------------------------------------------------------------
@interface LightAddressContainerView : NSView
@property(nonatomic, assign) BOOL focused;
@property(nonatomic, readonly) BOOL hovered;
@property(nonatomic, copy) void (^onActivate)(void);
@property(nonatomic, copy) void (^onHoverChanged)(BOOL hovered);
@end

@implementation LightAddressContainerView {
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
}

@synthesize focused = _focused;
@synthesize hovered = _hovered;
@synthesize onActivate = _onActivate;
@synthesize onHoverChanged = _onHoverChanged;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:self.bounds cursor:NSCursor.IBeamCursor];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self setNeedsDisplay:YES];
  if (_onHoverChanged) {
    _onHoverChanged(YES);
  }
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  [self setNeedsDisplay:YES];
  if (_onHoverChanged) {
    _onHoverChanged(NO);
  }
}

- (NSView*)hitTest:(NSPoint)point {
  if (self.isHidden) {
    return nil;
  }
  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (!NSPointInRect(local, self.bounds)) {
    return nil;
  }
  for (NSView* sub in self.subviews.reverseObjectEnumerator) {
    if (!sub.isHidden && [sub isKindOfClass:[LightIconButton class]]) {
      NSView* hit = [sub hitTest:local];
      if (hit) {
        return hit;
      }
    }
  }
  return self;
}

- (void)mouseDown:(NSEvent*)event {
  if (_onActivate) {
    _onActivate();
  }
}

- (void)setFocused:(BOOL)focused {
  if (_focused == focused) {
    return;
  }
  _focused = focused;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect inset = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:inset
                                                       xRadius:10.0
                                                       yRadius:10.0];
  CGFloat fillAlpha = _hovered ? 0.11 : 0.08;
  [[NSColor.labelColor colorWithAlphaComponent:fillAlpha] setFill];
  [path fill];

  [[NSColor.labelColor colorWithAlphaComponent:(_hovered ? 0.18 : 0.12)]
      setStroke];
  path.lineWidth = 0.5;
  [path stroke];
}

@end

// -----------------------------------------------------------------------------
// Content view inside the rightward + downward-expanding Liquid Glass URL popup
// (zero blue outline — pure Liquid Glass).
// -----------------------------------------------------------------------------
@interface LightExpandedUrlContentView : NSView
@property(nonatomic, copy) void (^onLayoutBlock)(void);
@property(nonatomic, assign) CGFloat cornerRadius;
@end

@implementation LightExpandedUrlContentView

@synthesize onLayoutBlock = _onLayoutBlock;
@synthesize cornerRadius = _cornerRadius;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)layout {
  [super layout];
  if (_onLayoutBlock) {
    _onLayoutBlock();
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  CGFloat r = _cornerRadius > 0.0 ? _cornerRadius : 12.0;
  NSRect inset = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:inset
                                                       xRadius:r
                                                       yRadius:r];
  [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Omnibox / Search Suggestion item & row inside the expanding Liquid Glass popup
// -----------------------------------------------------------------------------
@interface LightSuggestionItem : NSObject
@property(nonatomic, copy) NSString* primaryText;
@property(nonatomic, copy) NSString* secondaryText;
@property(nonatomic, copy) NSString* fillIntoEdit;
@property(nonatomic, copy) NSString* symbolName;
@property(nonatomic, copy) NSString* directUrlSpec;
@property(nonatomic, assign) int matchIndex;
@property(nonatomic, assign) BOOL accentIcon;
@end

@implementation LightSuggestionItem
@synthesize primaryText = _primaryText;
@synthesize secondaryText = _secondaryText;
@synthesize fillIntoEdit = _fillIntoEdit;
@synthesize symbolName = _symbolName;
@synthesize directUrlSpec = _directUrlSpec;
@synthesize matchIndex = _matchIndex;
@synthesize accentIcon = _accentIcon;
@end

@interface LightSuggestionRowView : NSView
@property(nonatomic, assign) NSInteger rowIndex;
@property(nonatomic, assign) BOOL keyboardSelected;
@property(nonatomic, copy) void (^onClick)(NSInteger rowIndex);
- (void)configureWithItem:(LightSuggestionItem*)item
                 selected:(BOOL)selected;
@end

@implementation LightSuggestionRowView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _textLabel;
  NSImageView* __strong _returnHintView;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
}

@synthesize rowIndex = _rowIndex;
@synthesize keyboardSelected = _keyboardSelected;
@synthesize onClick = _onClick;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_iconView];

    _textLabel = [NSTextField labelWithString:@""];
    _textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _textLabel.maximumNumberOfLines = 1;
    _textLabel.drawsBackground = NO;
    _textLabel.bezeled = NO;
    _textLabel.editable = NO;
    _textLabel.selectable = NO;
    [self addSubview:_textLabel];

    _returnHintView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _returnHintView.image =
        SymbolImage(@"return", 10.5, NSFontWeightSemibold);
    _returnHintView.contentTintColor = NSColor.secondaryLabelColor;
    _returnHintView.imageScaling = NSImageScaleProportionallyDown;
    _returnHintView.hidden = YES;
    [self addSubview:_returnHintView];
  }
  return self;
}

- (void)configureWithItem:(LightSuggestionItem*)item selected:(BOOL)selected {
  _keyboardSelected = selected;
  _iconView.image =
      SymbolImage(item.symbolName ?: @"magnifyingglass", 12.5,
                  NSFontWeightMedium);
  _iconView.contentTintColor =
      selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
  _returnHintView.hidden = !selected;

  NSMutableAttributedString* attr = [[NSMutableAttributedString alloc] init];
  NSDictionary* priAttrs = @{
    NSFontAttributeName :
        [NSFont systemFontOfSize:13.0
                          weight:(selected ? NSFontWeightMedium
                                           : NSFontWeightRegular)],
    NSForegroundColorAttributeName : NSColor.labelColor,
  };
  [attr appendAttributedString:[[NSAttributedString alloc]
                                   initWithString:(item.primaryText ?: @"")
                                       attributes:priAttrs]];

  if (item.secondaryText.length > 0) {
    NSDictionary* secAttrs = @{
      NSFontAttributeName :
          [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular],
      NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
    };
    NSString* suffix =
        [NSString stringWithFormat:@"  —  %@", item.secondaryText];
    [attr appendAttributedString:[[NSAttributedString alloc]
                                     initWithString:suffix
                                         attributes:secAttrs]];
  }
  NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  [attr addAttribute:NSParagraphStyleAttributeName
               value:ps
               range:NSMakeRange(0, attr.length)];
  _textLabel.attributedStringValue = attr;
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  _iconView.frame = NSMakeRect(10.0, std::floor((h - 15.0) * 0.5), 15.0, 15.0);
  _returnHintView.frame =
      NSMakeRect(std::max<CGFloat>(0.0, w - 24.0),
                 std::floor((h - 13.0) * 0.5), 13.0, 13.0);
  NSSize fit = [_textLabel sizeThatFits:NSMakeSize(1000.0, h)];
  CGFloat th = std::ceil(fit.height);
  CGFloat rightPad = _keyboardSelected ? 30.0 : 10.0;
  _textLabel.frame =
      NSMakeRect(32.0, std::floor((h - th) * 0.5),
                 std::max<CGFloat>(0.0, w - 32.0 - rightPad), th);
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
  if (_onClick) {
    _onClick(_rowIndex);
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  if (!_keyboardSelected && !_hovered) {
    return;
  }
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:9.0
                                                       yRadius:9.0];
  CGFloat alpha = _keyboardSelected ? 0.15 : 0.08;
  [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// "+ New Tab" footer row button (right-click opens Tab Group creation menu).
// -----------------------------------------------------------------------------
@interface LightNewTabButtonView : NSView
@property(nonatomic, copy) void (^actionBlock)(void);
@property(nonatomic, copy) NSMenu* (^menuProvider)(void);
@end

@implementation LightNewTabButtonView {
  NSImageView* __strong _plusIcon;
  NSTextField* __strong _label;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _pressed;
}

@synthesize actionBlock = _actionBlock;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    _plusIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _plusIcon.image = SymbolImage(@"plus", 12.5, NSFontWeightSemibold);
    _plusIcon.contentTintColor = NSColor.labelColor;
    [self addSubview:_plusIcon];

    _label = [NSTextField labelWithString:@"New Tab"];
    _label.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    _label.textColor = NSColor.labelColor;
    [self addSubview:_label];
  }
  return self;
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  _plusIcon.frame = NSMakeRect(10.0, std::floor((h - 20.0) * 0.5), 20.0, 20.0);
  NSSize fit = [_label sizeThatFits:NSMakeSize(200.0, h)];
  _label.frame = NSMakeRect(36.0, std::floor((h - fit.height) * 0.5),
                            std::ceil(fit.width), std::ceil(fit.height));
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _pressed = NO;
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent*)event {
  _pressed = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
  if (!_pressed) {
    return;
  }
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  BOOL inside = NSPointInRect(local, self.bounds);
  _pressed = NO;
  _hovered = inside;
  [self setNeedsDisplay:YES];
  if (inside && _actionBlock) {
    _actionBlock();
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider() : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath* badge = [NSBezierPath
      bezierPathWithOvalInRect:NSMakeRect(
                                   6.0,
                                   std::floor((self.bounds.size.height - 26.0) *
                                              0.5),
                                   26.0, 26.0)];
  [[NSColor.labelColor colorWithAlphaComponent:0.09] setFill];
  [badge fill];

  if (_hovered || _pressed) {
    NSBezierPath* row = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                        xRadius:9.0
                                                        yRadius:9.0];
    [[NSColor.labelColor colorWithAlphaComponent:(_pressed ? 0.16 : 0.08)]
        setFill];
    [row fill];
  }
}

@end

// -----------------------------------------------------------------------------
// Flipped content root inside NSGlassEffectView: double-click empty space opens
// New Tab; dragging empty space moves the window.
// -----------------------------------------------------------------------------
@interface LightSidebarContentView : NSView
@property(nonatomic, copy) void (^onLayoutBlock)(void);
@property(nonatomic, copy) void (^onDoubleClickEmpty)(void);
@end

@implementation LightSidebarContentView

@synthesize onLayoutBlock = _onLayoutBlock;
@synthesize onDoubleClickEmpty = _onDoubleClickEmpty;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)layout {
  [super layout];
  if (_onLayoutBlock) {
    _onLayoutBlock();
  }
}

- (void)mouseDown:(NSEvent*)event {
  if (event.clickCount == 2 && _onDoubleClickEmpty) {
    _onDoubleClickEmpty();
  }
}

- (void)mouseDragged:(NSEvent*)event {
  [self.window performWindowDragWithEvent:event];
}

@end

// -----------------------------------------------------------------------------
// Morphing "✕ Confirm" pill that expands out of the red close traffic light
// when attempting to quit (replacing Chrome's "Hold ⌘Q to Quit" HUD).
// -----------------------------------------------------------------------------
@interface LightConfirmQuitPillView : NSView
@property(nonatomic, copy) void (^onConfirmClicked)(void);
- (void)setExpandedVisuals:(BOOL)expanded;
@end

@implementation LightConfirmQuitPillView {
  NSImageView* __strong _redXIcon;
  NSTextField* __strong _confirmLabel;
  NSTrackingArea* __strong _trackingArea;
  BOOL _expanded;
  BOOL _hovered;
}

@synthesize onConfirmClicked = _onConfirmClicked;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;

    _redXIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _redXIcon.image = SymbolImage(@"xmark", 9.5, NSFontWeightBold);
    _redXIcon.contentTintColor =
        [NSColor colorWithSRGBRed:1.0 green:0.25 blue:0.21 alpha:1.0];
    _redXIcon.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_redXIcon];

    _confirmLabel = [NSTextField labelWithString:@"Confirm"];
    _confirmLabel.font =
        [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    _confirmLabel.textColor =
        [NSColor colorWithSRGBRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    _confirmLabel.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_confirmLabel];

    [self setExpandedVisuals:NO];
  }
  return self;
}

- (void)setExpandedVisuals:(BOOL)expanded {
  _expanded = expanded;
  _redXIcon.hidden = !expanded;
  _confirmLabel.hidden = !expanded;
  [self updatePillAppearance];
}

- (void)updatePillAppearance {
  if (!_expanded) {
    self.layer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.373 blue:0.341 alpha:1.0]
            .CGColor;
    self.layer.borderWidth = 0.0;
    self.layer.cornerRadius = 7.0;
  } else {
    CGFloat bgAlpha = _hovered ? 0.30 : 0.20;
    self.layer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.23 blue:0.19 alpha:bgAlpha]
            .CGColor;
    self.layer.borderColor =
        [NSColor colorWithSRGBRed:1.0 green:0.27 blue:0.23 alpha:0.85].CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.cornerRadius = self.bounds.size.height * 0.5;
  }
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  _redXIcon.frame = NSMakeRect(6.0, std::floor((h - 11.0) * 0.5), 11.0, 11.0);
  NSSize fit = [_confirmLabel sizeThatFits:NSMakeSize(100.0, h)];
  _confirmLabel.frame =
      NSMakeRect(19.0, std::floor((h - fit.height) * 0.5),
                 std::ceil(fit.width), std::ceil(fit.height));
  if (_expanded) {
    self.layer.cornerRadius = h * 0.5;
  }
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self updatePillAppearance];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  [self updatePillAppearance];
}

- (void)mouseDown:(NSEvent*)event {
  if (_expanded && _onConfirmClicked) {
    _onConfirmClicked();
  }
}

@end

// -----------------------------------------------------------------------------
// Native macOS traffic lights mounted directly ON the Liquid Glass sidebar so
// they slide, spring, and blur together with the panel in compact mode.
// -----------------------------------------------------------------------------
@interface LightTrafficLightsGroupView : NSView
@property(nonatomic, readonly) BOOL isConfirmingQuit;
@property(nonatomic, copy) void (^onConfirmStateChanged)(BOOL active);
@property(nonatomic, copy) void (^onConfirmQuitAccepted)(void);
- (instancetype)initWithTargetWindow:(NSWindow*)window;
- (void)refreshState;
- (void)presentConfirmQuitPill;
- (void)dismissConfirmQuitPillAnimated:(BOOL)animated;
- (BOOL)isEventInsideConfirmPill:(NSEvent*)event;
@end

@implementation LightTrafficLightsGroupView {
  NSWindow* __weak _targetWindow;
  NSButton* __strong _closeButton;
  NSButton* __strong _miniaturizeButton;
  NSButton* __strong _zoomButton;
  LightConfirmQuitPillView* __strong _confirmPill;
  NSTimer* __strong _confirmDismissTimer;
  NSUInteger _confirmGen;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _isConfirmingQuit;
}

@synthesize isConfirmingQuit = _isConfirmingQuit;
@synthesize onConfirmStateChanged = _onConfirmStateChanged;
@synthesize onConfirmQuitAccepted = _onConfirmQuitAccepted;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (instancetype)initWithTargetWindow:(NSWindow*)window {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 84, 24)])) {
    _targetWindow = window;
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;

    const NSWindowStyleMask kMask =
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    _closeButton = [NSWindow standardWindowButton:NSWindowCloseButton
                                     forStyleMask:kMask];
    _miniaturizeButton =
        [NSWindow standardWindowButton:NSWindowMiniaturizeButton
                          forStyleMask:kMask];
    _zoomButton = [NSWindow standardWindowButton:NSWindowZoomButton
                                    forStyleMask:kMask];

    _closeButton.target = self;
    _closeButton.action = @selector(handleClose:);
    _miniaturizeButton.target = self;
    _miniaturizeButton.action = @selector(handleMiniaturize:);
    _zoomButton.target = self;
    _zoomButton.action = @selector(handleZoom:);

    for (NSButton* btn in @[ _closeButton, _miniaturizeButton, _zoomButton ]) {
      btn.wantsLayer = YES;
      btn.layerUsesCoreImageFilters = YES;
    }

    [_closeButton setFrameOrigin:NSMakePoint(4.0, 5.0)];
    [_miniaturizeButton setFrameOrigin:NSMakePoint(24.0, 5.0)];
    [_zoomButton setFrameOrigin:NSMakePoint(44.0, 5.0)];

    [self addSubview:_closeButton];
    [self addSubview:_miniaturizeButton];
    [self addSubview:_zoomButton];

    __weak __typeof(self) weakSelf = self;
    _confirmPill = [[LightConfirmQuitPillView alloc]
        initWithFrame:NSMakeRect(4.0, 5.0, 14.0, 14.0)];
    _confirmPill.hidden = YES;
    _confirmPill.onConfirmClicked = ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s.onConfirmQuitAccepted) {
        s.onConfirmQuitAccepted();
      }
    };
    [self addSubview:_confirmPill];
  }
  return self;
}

- (void)dealloc {
  [_confirmDismissTimer invalidate];
}

// Private AppKit hook queried by _NSThemeWidgetCell to show all 3 hover glyphs.
- (BOOL)_mouseInGroup:(NSButton*)widget {
  return _hovered && !_isConfirmingQuit;
}

- (void)animateTrafficButtonsVisible:(BOOL)visible
                            duration:(NSTimeInterval)duration
                      timingFunction:(CAMediaTimingFunction*)timing
                                 gen:(NSUInteger)gen {
  NSArray<NSButton*>* buttons =
      @[ _closeButton, _miniaturizeButton, _zoomButton ];
  Class ciFilterClass = NSClassFromString(@"CIFilter");
  const CGFloat fromRadius = visible ? 6.0 : 0.0;
  const CGFloat toRadius = visible ? 0.0 : 6.0;
  const CGFloat toAlpha = visible ? 1.0 : 0.0;

  for (NSButton* btn in buttons) {
    btn.hidden = NO;
    if (visible && btn.alphaValue > 0.99 && btn.layer.filters.count == 0) {
      btn.alphaValue = 0.0;
    }
    if (ciFilterClass) {
      id blurFilter = [(id<LightCIFilterPrivate>)ciFilterClass
          filterWithName:@"CIGaussianBlur"];
      if (blurFilter) {
        [blurFilter setDefaults];
        [blurFilter setValue:@(fromRadius) forKey:@"inputRadius"];
        [blurFilter setValue:@"trafficBlur" forKey:@"name"];
        btn.layer.filters = @[ blurFilter ];

        CABasicAnimation* blurAnim = [CABasicAnimation
            animationWithKeyPath:@"filters.trafficBlur.inputRadius"];
        blurAnim.fromValue = @(fromRadius);
        blurAnim.toValue = @(toRadius);
        blurAnim.duration = duration;
        blurAnim.timingFunction = timing;
        blurAnim.fillMode = kCAFillModeForwards;
        blurAnim.removedOnCompletion = NO;
        [btn.layer removeAnimationForKey:@"trafficBlurAnim"];
        [btn.layer addAnimation:blurAnim forKey:@"trafficBlurAnim"];
        [btn.layer setValue:@(toRadius)
                 forKeyPath:@"filters.trafficBlur.inputRadius"];
      }
    }
  }

  __weak __typeof(self) weakSelf = self;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = duration;
    ctx.timingFunction = timing;
    for (NSButton* btn in buttons) {
      btn.animator.alphaValue = toAlpha;
    }
  }
      completionHandler:^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s || s->_confirmGen != gen) {
          return;
        }
        for (NSButton* btn in buttons) {
          [btn.layer removeAnimationForKey:@"trafficBlurAnim"];
          btn.layer.filters = nil;
          if (!visible) {
            btn.hidden = YES;
          } else {
            btn.alphaValue = 1.0;
            btn.hidden = NO;
          }
        }
      }];
}

- (void)presentConfirmQuitPill {
  [_confirmDismissTimer invalidate];
  _confirmDismissTimer = nil;

  NSUInteger gen = ++_confirmGen;
  _isConfirmingQuit = YES;
  if (_onConfirmStateChanged) {
    _onConfirmStateChanged(YES);
  }

  // Collapsed dot (matching red close button) -> Expanded pill (+smidge outward
  // in all directions and growing right over min/max).
  const NSRect startRect = NSMakeRect(4.0, 5.0, 14.0, 14.0);
  const NSRect endRect = NSMakeRect(1.5, 2.5, 76.0, 19.0);

  _confirmPill.frame = startRect;
  [_confirmPill setExpandedVisuals:YES];
  _confirmPill.hidden = NO;

  CAMediaTimingFunction* expandTiming =
      [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0];
  [self animateTrafficButtonsVisible:NO
                            duration:0.14
                      timingFunction:expandTiming
                                 gen:gen];

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.15;
    ctx.timingFunction = expandTiming;
    _confirmPill.animator.frame = endRect;
  }
                      completionHandler:nil];

  __weak __typeof(self) weakSelf = self;
  _confirmDismissTimer = [NSTimer
      scheduledTimerWithTimeInterval:2.1
                             repeats:NO
                               block:^(NSTimer* t) {
                                 __strong __typeof(weakSelf) s = weakSelf;
                                 if (s && s->_confirmGen == gen) {
                                   [s dismissConfirmQuitPillAnimated:YES];
                                 }
                               }];
}

- (BOOL)isEventInsideConfirmPill:(NSEvent*)event {
  if (!_isConfirmingQuit || !_confirmPill || _confirmPill.isHidden || !event ||
      event.window != self.window) {
    return NO;
  }
  NSPoint pt = [_confirmPill convertPoint:event.locationInWindow fromView:nil];
  return NSPointInRect(pt, _confirmPill.bounds);
}

- (void)dismissConfirmQuitPillAnimated:(BOOL)animated {
  [_confirmDismissTimer invalidate];
  _confirmDismissTimer = nil;
  if (!_isConfirmingQuit) {
    return;
  }
  NSUInteger gen = ++_confirmGen;
  _isConfirmingQuit = NO;
  if (_onConfirmStateChanged) {
    _onConfirmStateChanged(NO);
  }

  const NSRect collapsedRect = NSMakeRect(4.0, 5.0, 14.0, 14.0);
  [_confirmPill setExpandedVisuals:NO];

  if (!animated) {
    _confirmPill.frame = collapsedRect;
    _confirmPill.hidden = YES;
    for (NSButton* btn in @[ _closeButton, _miniaturizeButton, _zoomButton ]) {
      [btn.layer removeAnimationForKey:@"trafficBlurAnim"];
      btn.layer.filters = nil;
      btn.alphaValue = 1.0;
      btn.hidden = NO;
    }
    return;
  }

  CAMediaTimingFunction* dismissTiming =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [self animateTrafficButtonsVisible:YES
                            duration:0.16
                      timingFunction:dismissTiming
                                 gen:gen];

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.16;
    ctx.timingFunction = dismissTiming;
    _confirmPill.animator.frame = collapsedRect;
  }
                      completionHandler:^{
                        if (self->_confirmGen == gen) {
                          self->_confirmPill.hidden = YES;
                        }
                      }];
}

- (void)refreshState {
  NSArray<NSButton*>* buttons =
      @[ _closeButton, _miniaturizeButton, _zoomButton ];
  for (NSButton* b in buttons) {
    if ([b respondsToSelector:@selector(mouseEnteredOrExited)]) {
      [(id<LightThemeWidgetPrivate>)b mouseEnteredOrExited];
    }
    if ([b respondsToSelector:@selector(update)]) {
      [(id<LightThemeWidgetPrivate>)b update];
    }
    [b setNeedsDisplay:YES];
  }
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  [self refreshState];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  [self refreshState];
}

- (void)handleClose:(id)sender {
  [_targetWindow performClose:sender];
}

- (void)handleMiniaturize:(id)sender {
  [_targetWindow performMiniaturize:sender];
}

- (void)handleZoom:(id)sender {
  if (NSEvent.modifierFlags & NSEventModifierFlagOption) {
    [_targetWindow zoom:sender];
  } else {
    [_targetWindow toggleFullScreen:sender];
  }
}

@end

// -----------------------------------------------------------------------------
// Full-window transparent overlay view that hosts NSGlassEffectView while
// passing clicks outside the glass panel straight through to WebContents.
// -----------------------------------------------------------------------------
@interface LightSidebarPassthroughView : NSView
@property(nonatomic, strong) NSView* glassPanel;
@property(nonatomic, strong) NSView* expandedUrlPanel;
@property(nonatomic, assign) BOOL sidebarInteractive;
@property(nonatomic, copy) void (^onLayoutBlock)(void);
@property(nonatomic, copy) void (^onHoverLeftEdge)(void);
- (void)invalidateEdgeTrackingArea;
@end

@implementation LightSidebarPassthroughView {
  NSTrackingArea* __strong _edgeTrackingArea;
  NSRect _lastTrackedEdgeRect;
}

@synthesize glassPanel = _glassPanel;
@synthesize expandedUrlPanel = _expandedUrlPanel;
@synthesize sidebarInteractive = _sidebarInteractive;
@synthesize onLayoutBlock = _onLayoutBlock;
@synthesize onHoverLeftEdge = _onHoverLeftEdge;

- (void)layout {
  [super layout];
  if (_onLayoutBlock) {
    _onLayoutBlock();
  }
}

- (void)invalidateEdgeTrackingArea {
  _lastTrackedEdgeRect = NSZeroRect;
  [self updateTrackingAreas];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  CGFloat trigW =
      SidebarUDDouble(@"LightSidebarTriggerWidth", kDefaultHoverEdgeTriggerWidth);
  NSRect edgeRect = NSMakeRect(0.0, 0.0, trigW + 6.0, self.bounds.size.height);
  if (_edgeTrackingArea && NSEqualRects(_lastTrackedEdgeRect, edgeRect)) {
    return;
  }
  if (_edgeTrackingArea) {
    [self removeTrackingArea:_edgeTrackingArea];
  }
  _lastTrackedEdgeRect = edgeRect;
  _edgeTrackingArea = [[NSTrackingArea alloc]
      initWithRect:edgeRect
           options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingActiveAlways)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_edgeTrackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  if (_onHoverLeftEdge) {
    _onHoverLeftEdge();
  }
}

- (void)mouseMoved:(NSEvent*)event {
  if (_onHoverLeftEdge) {
    _onHoverLeftEdge();
  }
}

- (NSView*)hitTest:(NSPoint)point {
  if (!_sidebarInteractive || !_glassPanel || _glassPanel.isHidden) {
    return nil;
  }
  // `point` is in superview coordinates; convert to local coordinates.
  NSPoint local = [self convertPoint:point fromView:self.superview];
  BOOL inSidebar = NSPointInRect(local, _glassPanel.frame);
  BOOL inExpandedUrl = _expandedUrlPanel && !_expandedUrlPanel.isHidden &&
                       NSPointInRect(local, _expandedUrlPanel.frame);
  if (!inSidebar && !inExpandedUrl) {
    return nil;
  }
  NSView* hit = [super hitTest:point];
  return hit == self ? nil : hit;
}

@end

// -----------------------------------------------------------------------------
// Main Objective-C controller managing the Liquid Glass sidebar UI.
// -----------------------------------------------------------------------------
API_AVAILABLE(macos(26.0))
@interface LightGlassSidebarObjCController : NSObject <NSTextFieldDelegate>

- (instancetype)initWithBridge:(LightGlassSidebarBridgeImpl*)bridge
                        window:(NSWindow*)window;
- (void)teardown;
- (void)focusAddressBar:(BOOL)selectAll;
- (void)toggleCollapsed;
- (BOOL)isCollapsed;
- (void)reloadTabsAndNavigation;
- (void)updateNavigationStateOnly;
- (void)applyAutocompleteSuggestions:(NSArray<LightSuggestionItem*>*)items;
- (void)beginInlineRenameForGroupToken:(NSString*)token;
- (NSMenu*)buildNewTabButtonContextMenu;
- (BOOL)handleConfirmQuitAttempt;
- (void)cancelConfirmQuit;
- (NSWindow*)targetWindow;
- (BOOL)isPinned;
- (CGFloat)currentSidebarWidth;

@end

namespace {
std::unordered_map<const BrowserView*, LightGlassSidebarBridgeImpl*>&
ActiveSidebarBridges() {
  static auto* map =
      new std::unordered_map<const BrowserView*, LightGlassSidebarBridgeImpl*>();
  return *map;
}
NSHashTable<id>* ActiveSidebarControllers() {
  static NSHashTable<id>* table = nil;
  if (!table) {
    table = [NSHashTable weakObjectsHashTable];
  }
  return table;
}
bool g_confirm_quit_accepted_by_click = false;
}  // namespace

@interface LightConfirmQuitBridge : NSObject
+ (NSNumber*)handleConfirmQuitAttempt;
+ (void)cancelConfirmQuit;
@end

// -----------------------------------------------------------------------------
// C++ Bridge connecting BrowserView / TabStripModel / WebContents to AppKit.
// -----------------------------------------------------------------------------
class API_AVAILABLE(macos(26.0)) LightGlassSidebarBridgeImpl
    : public LightGlassSidebarBridge,
      public TabStripModelObserver,
      public content::WebContentsObserver,
      public CommandObserver,
      public AutocompleteController::Observer {
 public:
  LightGlassSidebarBridgeImpl(BrowserView* browser_view, NSWindow* window)
      : browser_view_(browser_view) {
    ActiveSidebarBridges()[browser_view_] = this;
    if (BrowserWindowInterface* b = this->browser()) {
      if (Profile* profile = b->GetProfile()) {
        AutocompleteControllerConfig config;
        config.provider_types =
            AutocompleteClassifier::DefaultOmniboxProviders();
        config.show_iph_matches = false;
        autocomplete_controller_ = std::make_unique<AutocompleteController>(
            std::make_unique<ChromeAutocompleteProviderClient>(profile),
            config);
        autocomplete_controller_->AddObserver(this);
      }
    }

    if (@available(macOS 26.0, *)) {
      controller_ =
          [[LightGlassSidebarObjCController alloc] initWithBridge:this
                                                           window:window];
    }

    if (BrowserWindowInterface* browser = this->browser()) {
      chrome::AddCommandObserver(browser, IDC_BACK, this);
      chrome::AddCommandObserver(browser, IDC_FORWARD, this);
      chrome::AddCommandObserver(browser, IDC_RELOAD, this);
      if (TabStripModel* model = browser->GetTabStripModel()) {
        model->AddObserver(this);
        Observe(model->GetActiveWebContents());
      }
    }

    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  ~LightGlassSidebarBridgeImpl() override {
    ActiveSidebarBridges().erase(browser_view_);
    if (autocomplete_controller_) {
      autocomplete_controller_->Stop(AutocompleteStopReason::kClobbered);
      autocomplete_controller_->RemoveObserver(this);
      autocomplete_controller_.reset();
    }
    Observe(nullptr);
    TabStripModelObserver::StopObservingAll(this);
    if (BrowserWindowInterface* browser = this->browser()) {
      chrome::RemoveCommandObserver(browser, IDC_BACK, this);
      chrome::RemoveCommandObserver(browser, IDC_FORWARD, this);
      chrome::RemoveCommandObserver(browser, IDC_RELOAD, this);
    }
    if (@available(macOS 26.0, *)) {
      [controller_ teardown];
      controller_ = nil;
    }
  }

  BrowserView* browser_view() const { return browser_view_; }
  BrowserWindowInterface* browser() const {
    return browser_view_ ? browser_view_->browser() : nullptr;
  }

  int GetPinnedSidebarWidth() const {
    if (@available(macOS 26.0, *)) {
      if (controller_ && [controller_ isPinned]) {
        return static_cast<int>(std::lround([controller_ currentSidebarWidth]));
      }
    }
    return 0;
  }

  void InvalidateBrowserLayout() {
    if (browser_view_) {
      browser_view_->InvalidateLayout();
    }
  }

  void EnsureActiveWebContentsTransparent() {
    if (content::WebContents* wc = web_contents()) {
      if (content::RenderWidgetHostView* rwhv = wc->GetRenderWidgetHostView()) {
        rwhv->SetBackgroundColor(SK_ColorTRANSPARENT);
      }
    }
  }

  // LightGlassSidebarBridge:
  void FocusAddressBar(bool select_all) override {
    if (@available(macOS 26.0, *)) {
      [controller_ focusAddressBar:select_all];
    }
  }

  void ToggleCollapsed() override {
    if (@available(macOS 26.0, *)) {
      [controller_ toggleCollapsed];
    }
  }

  bool IsCollapsed() const override {
    if (@available(macOS 26.0, *)) {
      return [controller_ isCollapsed];
    }
    return false;
  }

  // Actions invoked by ObjC UI:
  void GoBack() {
    if (BrowserWindowInterface* b = browser()) {
      if (content::WebContents* wc =
              b->GetTabStripModel()->GetActiveWebContents()) {
        if (wc->GetController().CanGoBack()) {
          chrome::GoBack(wc);
        }
      }
    }
  }

  void GoForward() {
    if (BrowserWindowInterface* b = browser()) {
      if (content::WebContents* wc =
              b->GetTabStripModel()->GetActiveWebContents()) {
        if (wc->GetController().CanGoForward()) {
          chrome::GoForward(wc);
        }
      }
    }
  }

  void ReloadOrStop() {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    content::WebContents* wc = b->GetTabStripModel()->GetActiveWebContents();
    if (wc && wc->IsLoading()) {
      chrome::Stop(b);
    } else {
      chrome::Reload(b, WindowOpenDisposition::kCurrentTab);
    }
  }

  void CreateNewTab() {
    if (BrowserWindowInterface* b = browser()) {
      chrome::ExecuteCommand(b, IDC_NEW_TAB);
    }
  }

  bool HasInstalledExtensions() {
    BrowserView* bv = browser_view_.get();
    if (!bv || !bv->GetProfile()) {
      return false;
    }
    ToolbarActionsModel* model = ToolbarActionsModel::Get(bv->GetProfile());
    return model && !model->action_ids().empty();
  }

  void GetInstalledExtensions(
      std::vector<std::tuple<std::string, std::u16string, NSImage*>>& out) {
    out.clear();
    BrowserView* bv = browser_view_.get();
    if (!bv || !bv->GetProfile()) {
      return;
    }
    ToolbarActionsModel* model = ToolbarActionsModel::Get(bv->GetProfile());
    if (!model || model->action_ids().empty()) {
      return;
    }
    ExtensionsToolbarDesktop* extToolbar =
        bv->toolbar() ? bv->toolbar()->extensions_container_for_testing()
                      : nullptr;
    ExtensionsToolbarViewModel* vm =
        extToolbar ? extToolbar->GetToolbarViewModel() : nullptr;
    content::WebContents* wc =
        bv->browser() ? bv->browser()->GetTabStripModel()->GetActiveWebContents()
                      : nullptr;
    auto* registry = extensions::ExtensionRegistry::Get(bv->GetProfile());
    for (const auto& action_id : model->action_ids()) {
      std::u16string name;
      NSImage* icon = nil;
      if (vm) {
        if (ToolbarActionViewModel* action = vm->GetActionForId(action_id)) {
          name = action->GetActionName();
          ui::ImageModel img = action->GetIcon(wc, gfx::Size(16, 16));
          if (!img.IsEmpty()) {
            icon = gfx::NSImageFromImageSkia(
                img.Rasterize(bv->GetColorProvider()));
          }
        }
      }
      if (name.empty() && registry) {
        if (const extensions::Extension* ext =
                registry->enabled_extensions().GetByID(action_id)) {
          name = base::UTF8ToUTF16(ext->name());
        }
      }
      if (!name.empty()) {
        out.emplace_back(action_id, std::move(name), icon);
      }
    }
  }

  void TriggerExtensionAction(const std::string& action_id) {
    BrowserView* bv = browser_view_.get();
    if (!bv || !bv->toolbar()) {
      return;
    }
    ExtensionsToolbarDesktop* extToolbar =
        bv->toolbar()->extensions_container_for_testing();
    ExtensionsToolbarViewModel* vm =
        extToolbar ? extToolbar->GetToolbarViewModel() : nullptr;
    if (vm) {
      if (ToolbarActionViewModel* action = vm->GetActionForId(action_id)) {
        action->ExecuteUserAction(
            ToolbarActionViewModel::InvocationSource::kMenuEntry);
      }
    }
  }

  void OpenManageExtensions() {
    if (BrowserWindowInterface* b = browser()) {
      NavigateParams params(b, GURL("chrome://extensions/"),
                            ui::PAGE_TRANSITION_LINK);
      params.disposition = WindowOpenDisposition::kNewForegroundTab;
      Navigate(&params);
    }
  }

  void OpenNativeSettings() {
    LightNativeSettingsController::ShowForBrowser(browser());
  }

  void ActivateTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      model->ActivateTabAt(
          index, TabStripUserGestureDetails(
                     TabStripUserGestureDetails::GestureType::kMouse));
    }
  }

  void MoveTabAt(int from_index, int to_index) {
    BrowserWindowInterface* b = browser();
    if (!b || from_index == to_index) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(from_index) ||
        !model->ContainsIndex(to_index)) {
      return;
    }
    if (model->IsTabPinned(from_index) != model->IsTabPinned(to_index)) {
      return;
    }
    model->MoveWebContentsAt(from_index, to_index,
                             /*select_after_move=*/false);
  }

  void CloseTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      model->CloseWebContentsAt(index,
                                TabCloseTypes::CLOSE_USER_GESTURE |
                                    TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    }
  }

  void TogglePinTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      content::WebContents* wc = model->GetWebContentsAt(index);
      const bool willPin = !model->IsTabPinned(index);
      if (wc) {
        if (willPin) {
          pinned_origin_urls_[wc] = wc->GetVisibleURL();
        } else {
          pinned_origin_urls_.erase(wc);
        }
      }
      model->SetTabPinned(index, willPin);
    }
  }

  bool IsPinnedTabAway(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return false;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(index) || !model->IsTabPinned(index)) {
      return false;
    }
    content::WebContents* wc = model->GetWebContentsAt(index);
    if (!wc) {
      return false;
    }
    auto it = pinned_origin_urls_.find(wc);
    if (it == pinned_origin_urls_.end()) {
      pinned_origin_urls_[wc] = wc->GetVisibleURL();
      return false;
    }
    return it->second.is_valid() && wc->GetVisibleURL() != it->second;
  }

  void ResetPinnedTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(index)) {
      return;
    }
    content::WebContents* wc = model->GetWebContentsAt(index);
    if (!wc) {
      return;
    }
    auto it = pinned_origin_urls_.find(wc);
    if (it != pinned_origin_urls_.end() && it->second.is_valid() &&
        wc->GetVisibleURL() != it->second) {
      model->ActivateTabAt(index);
      NavigateParams params(b, it->second, ui::PAGE_TRANSITION_AUTO_BOOKMARK);
      params.disposition = WindowOpenDisposition::kCurrentTab;
      Navigate(&params);
    }
  }

  void ReplacePinnedTabOriginAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      if (content::WebContents* wc = model->GetWebContentsAt(index)) {
        pinned_origin_urls_[wc] = wc->GetVisibleURL();
      }
    }
  }

  void DuplicateTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (b && chrome::CanDuplicateTabAt(b, index)) {
      chrome::DuplicateTabAt(b, index);
    }
  }

  void ToggleMuteTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      if (content::WebContents* wc = model->GetWebContentsAt(index)) {
        wc->SetAudioMuted(!wc->IsAudioMuted());
        if (@available(macOS 26.0, *)) {
          [controller_ reloadTabsAndNavigation];
        }
      }
    }
  }

  void CopyTabUrlAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      if (content::WebContents* wc = model->GetWebContentsAt(index)) {
        std::string spec = wc->GetVisibleURL().spec();
        if (base::StartsWith(spec, "chrome://",
                             base::CompareCase::INSENSITIVE_ASCII)) {
          spec = "light://" + spec.substr(9);
        }
        NSString* nsSpec = base::SysUTF8ToNSString(spec);
        if (nsSpec.length > 0) {
          [NSPasteboard.generalPasteboard clearContents];
          [NSPasteboard.generalPasteboard setString:nsSpec
                                            forType:NSPasteboardTypeString];
        }
      }
    }
  }

  std::optional<tab_groups::TabGroupId> FindGroupByToken(
      NSString* nsToken) const {
    if (nsToken.length == 0) {
      return std::nullopt;
    }
    BrowserWindowInterface* b = browser();
    if (!b) {
      return std::nullopt;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->SupportsTabGroups() || !model->group_model()) {
      return std::nullopt;
    }
    const std::string want = base::SysNSStringToUTF8(nsToken);
    for (const tab_groups::TabGroupId& gid :
         model->group_model()->ListTabGroups()) {
      if (gid.ToString() == want) {
        return gid;
      }
    }
    return std::nullopt;
  }

  void CreateNewTabInNewGroup(
      std::optional<tab_groups::TabGroupColorId> initial_color = std::nullopt) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->SupportsTabGroups()) {
      CreateNewTab();
      return;
    }
    content::WebContents* wc =
        chrome::AddAndReturnTabAt(b, GURL(), -1, /*foreground=*/true);
    if (!wc) {
      return;
    }
    int idx = model->GetIndexOfWebContents(wc);
    if (!model->ContainsIndex(idx)) {
      return;
    }
    tab_groups::TabGroupId gid = model->AddToNewGroup({idx});
    if (initial_color.has_value()) {
      model->ChangeTabGroupVisuals(
          gid, tab_groups::TabGroupVisualData(u"", *initial_color, false),
          /*is_customized=*/true);
    }
    if (@available(macOS 26.0, *)) {
      [controller_ beginInlineRenameForGroupToken:base::SysUTF8ToNSString(
                                                      gid.ToString())];
    }
  }

  void CreateNewTabInGroupToken(NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    auto gid = FindGroupByToken(nsToken);
    if (!gid.has_value()) {
      CreateNewTab();
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->group_model() &&
        model->group_model()->ContainsTabGroup(*gid)) {
      TabGroup* tg = model->group_model()->GetTabGroup(*gid);
      if (tg && tg->visual_data() && tg->visual_data()->is_collapsed()) {
        model->ChangeTabGroupVisuals(
            *gid,
            tab_groups::TabGroupVisualData(tg->visual_data()->title(),
                                           tg->visual_data()->color(), false),
            /*is_customized=*/true);
      }
    }
    chrome::AddAndReturnTabAt(b, GURL(), -1, /*foreground=*/true, gid);
    FocusAddressBar(/*select_all=*/true);
  }

  void CreateNewGroupWithTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->SupportsTabGroups() ||
        !model->ContainsIndex(index)) {
      return;
    }
    if (model->IsTabPinned(index)) {
      index = model->SetTabPinned(index, false);
    }
    tab_groups::TabGroupId gid = model->AddToNewGroup({index});
    if (@available(macOS 26.0, *)) {
      [controller_ beginInlineRenameForGroupToken:base::SysUTF8ToNSString(
                                                      gid.ToString())];
    }
  }

  void MoveTabAtToGroupToken(int index, NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    auto gid = FindGroupByToken(nsToken);
    if (!model || !model->ContainsIndex(index) || !gid.has_value()) {
      return;
    }
    if (model->IsTabPinned(index)) {
      index = model->SetTabPinned(index, false);
    }
    model->AddToExistingGroup({index}, *gid, /*add_to_end=*/true);
  }

  void RemoveTabAtFromGroup(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      model->RemoveFromGroup({index});
    }
  }

  void ToggleCollapseGroupToken(NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->group_model() ||
        !model->group_model()->ContainsTabGroup(*gid)) {
      return;
    }
    TabGroup* tg = model->group_model()->GetTabGroup(*gid);
    if (!tg || !tg->visual_data()) {
      return;
    }
    const auto* vd = tg->visual_data();
    model->ChangeTabGroupVisuals(
        *gid,
        tab_groups::TabGroupVisualData(vd->title(), vd->color(),
                                       !vd->is_collapsed()),
        /*is_customized=*/true);
  }

  void RenameGroupToken(NSString* nsToken, NSString* newTitle) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->group_model() ||
        !model->group_model()->ContainsTabGroup(*gid)) {
      return;
    }
    TabGroup* tg = model->group_model()->GetTabGroup(*gid);
    if (!tg || !tg->visual_data()) {
      return;
    }
    std::u16string uTitle;
    base::TrimWhitespace(base::SysNSStringToUTF16(newTitle ?: @""),
                         base::TRIM_ALL, &uTitle);
    const auto* vd = tg->visual_data();
    model->ChangeTabGroupVisuals(
        *gid,
        tab_groups::TabGroupVisualData(uTitle, vd->color(), vd->is_collapsed()),
        /*is_customized=*/true);
  }

  void RecolorGroupToken(NSString* nsToken,
                         tab_groups::TabGroupColorId newColor) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->group_model() ||
        !model->group_model()->ContainsTabGroup(*gid)) {
      return;
    }
    TabGroup* tg = model->group_model()->GetTabGroup(*gid);
    if (!tg || !tg->visual_data()) {
      return;
    }
    const auto* vd = tg->visual_data();
    model->ChangeTabGroupVisuals(
        *gid,
        tab_groups::TabGroupVisualData(vd->title(), newColor,
                                       vd->is_collapsed()),
        /*is_customized=*/true);
  }

  void UngroupToken(NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model) {
      return;
    }
    std::vector<int> indices;
    for (int i = 0; i < model->count(); ++i) {
      if (model->GetTabGroupForTab(i) == gid) {
        indices.push_back(i);
      }
    }
    if (!indices.empty()) {
      model->RemoveFromGroup(indices);
    }
  }

  void CloseGroupToken(NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model) {
      model->CloseAllTabsInGroup(*gid);
    }
  }

  void ReloadTabAt(int index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      if (content::WebContents* wc = model->GetWebContentsAt(index)) {
        wc->GetController().Reload(content::ReloadType::NORMAL, true);
      }
    }
  }

  void CloseOtherTabsAt(int keep_index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(keep_index)) {
      return;
    }
    model->ActivateTabAt(keep_index);
    for (int i = model->count() - 1; i >= 0; --i) {
      if (i != keep_index && !model->IsTabPinned(i)) {
        model->CloseWebContentsAt(
            i, TabCloseTypes::CLOSE_USER_GESTURE |
                   TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
      }
    }
  }

  void FocusActiveWebContents() {
    if (BrowserWindowInterface* b = browser()) {
      if (content::WebContents* wc =
              b->GetTabStripModel()->GetActiveWebContents()) {
        wc->Focus();
      }
    }
  }

  void NavigateToInput(const std::u16string& raw_input) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    std::u16string trimmed;
    base::TrimWhitespace(raw_input, base::TRIM_ALL, &trimmed);
    if (trimmed.empty()) {
      return;
    }

    GURL destination_url;
    ui::PageTransition transition = ui::PAGE_TRANSITION_TYPED;

    const std::string utf8_input = base::UTF16ToUTF8(trimmed);
    if (base::StartsWith(utf8_input, "light://",
                         base::CompareCase::INSENSITIVE_ASCII) ||
        base::EqualsCaseInsensitiveASCII(utf8_input, "chrome://about") ||
        base::EqualsCaseInsensitiveASCII(utf8_input, "chrome://about/")) {
      if (base::StartsWith(utf8_input, "chrome://about",
                           base::CompareCase::INSENSITIVE_ASCII)) {
        destination_url = GURL("light://about/");
      } else {
        destination_url = GURL(utf8_input);
      }
    }

    if (!destination_url.is_valid()) {
      if (Profile* profile = b->GetProfile()) {
        if (AutocompleteClassifier* classifier =
                AutocompleteClassifierFactory::GetForProfile(profile)) {
          AutocompleteMatch match;
          classifier->Classify(trimmed, /*in_keyword_mode=*/false,
                               /*allow_exact_keyword_match=*/true,
                               metrics::OmniboxEventProto::OTHER, &match,
                               nullptr);
          if (match.destination_url.is_valid()) {
            destination_url = match.destination_url;
            transition = match.transition;
          }
        }
      }
    }

    if (!destination_url.is_valid()) {
      destination_url =
          url_formatter::FixupURL(base::UTF16ToUTF8(trimmed), std::string());
    }
    if (!destination_url.is_valid()) {
      return;
    }

    NavigateParams params(b, destination_url, transition);
    params.disposition = WindowOpenDisposition::kCurrentTab;
    Navigate(&params);
    FocusActiveWebContents();
  }

  void StartAutocomplete(const std::u16string& raw_text) {
    if (!autocomplete_controller_) {
      return;
    }
    BrowserWindowInterface* b = browser();
    if (!b || !b->GetProfile()) {
      return;
    }
    std::u16string trimmed;
    base::TrimWhitespace(raw_text, base::TRIM_ALL, &trimmed);
    last_autocomplete_query_ = trimmed;
    if (trimmed.empty()) {
      autocomplete_controller_->Stop(AutocompleteStopReason::kClobbered);
      if (@available(macOS 26.0, *)) {
        [controller_ applyAutocompleteSuggestions:@[]];
      }
      return;
    }

    AutocompleteInput input(
        raw_text, metrics::OmniboxEventProto::OTHER,
        ChromeAutocompleteSchemeClassifier(b->GetProfile()));
    input.set_prevent_inline_autocomplete(true);
    if (content::WebContents* wc =
            b->GetTabStripModel()
                ? b->GetTabStripModel()->GetActiveWebContents()
                : nullptr) {
      input.set_current_url(wc->GetVisibleURL());
      input.set_current_title(wc->GetTitle());
    }
    autocomplete_controller_->Start(input);
  }

  void StopAutocomplete(bool clear_results) {
    if (!autocomplete_controller_) {
      return;
    }
    autocomplete_controller_->Stop(clear_results
                                       ? AutocompleteStopReason::kClobbered
                                       : AutocompleteStopReason::kInteraction);
  }

  void OpenSuggestionItem(LightSuggestionItem* item) {
    if (!item) {
      return;
    }
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    if (item.directUrlSpec.length > 0) {
      GURL url(base::SysNSStringToUTF8(item.directUrlSpec));
      if (url.is_valid()) {
        NavigateParams params(b, url, ui::PAGE_TRANSITION_TYPED);
        params.disposition = WindowOpenDisposition::kCurrentTab;
        Navigate(&params);
        FocusActiveWebContents();
        return;
      }
    }
    if (autocomplete_controller_ && item.matchIndex >= 0) {
      const AutocompleteResult& result = autocomplete_controller_->result();
      const size_t idx = static_cast<size_t>(item.matchIndex);
      if (idx < result.size()) {
        const AutocompleteMatch& match = result.match_at(idx);
        if (match.destination_url.is_valid()) {
          NavigateParams params(b, match.destination_url, match.transition);
          params.disposition = WindowOpenDisposition::kCurrentTab;
          Navigate(&params);
          FocusActiveWebContents();
          return;
        }
      }
    }
    if (item.fillIntoEdit.length > 0) {
      NavigateToInput(base::SysNSStringToUTF16(item.fillIntoEdit));
    }
  }

  // AutocompleteController::Observer:
  void OnResultChanged(AutocompleteController* controller,
                       bool default_match_changed) override {
    if (!controller || controller != autocomplete_controller_.get()) {
      return;
    }
    NSMutableArray<LightSuggestionItem*>* items = [NSMutableArray array];
    constexpr NSUInteger kMaxSuggestions = 7;

    // Prepend matching built-in light:// pages when typing "light..."
    const std::string qLower =
        base::ToLowerASCII(base::UTF16ToUTF8(last_autocomplete_query_));
    if (!qLower.empty() &&
        (base::StartsWith("light://", qLower, base::CompareCase::SENSITIVE) ||
         base::StartsWith(qLower, "light:", base::CompareCase::SENSITIVE))) {
      struct BuiltinLightPage {
        const char* url;
        const char* title;
      };
      static constexpr BuiltinLightPage kPages[] = {
          {"light://about", "Light URLs & Internal Pages"},
          {"light://version", "About Light Version"},
          {"light://flags", "Experimental Features"},
          {"light://gpu", "GPU Internals"},
          {"light://history", "Browsing History"},
          {"light://downloads", "Downloads"},
      };
      for (const auto& p : kPages) {
        if (items.count >= 4) {
          break;
        }
        std::string u(p.url);
        if (qLower == "light" || qLower == "light:" || qLower == "light://" ||
            u.find(qLower) != std::string::npos) {
          LightSuggestionItem* it = [[LightSuggestionItem alloc] init];
          it.primaryText = base::SysUTF8ToNSString(p.url);
          it.secondaryText = base::SysUTF8ToNSString(p.title);
          it.fillIntoEdit = it.primaryText;
          it.symbolName = @"sparkles";
          it.directUrlSpec = it.primaryText;
          it.matchIndex = -1;
          it.accentIcon = YES;
          [items addObject:it];
        }
      }
    }

    auto rebrandChromeScheme = [](std::u16string s) -> NSString* {
      std::string utf8 = base::UTF16ToUTF8(s);
      if (base::StartsWith(utf8, "chrome://",
                           base::CompareCase::INSENSITIVE_ASCII)) {
        utf8 = "light://" + utf8.substr(9);
      }
      return base::SysUTF8ToNSString(utf8);
    };

    const AutocompleteResult& result = controller->result();
    for (size_t i = 0; i < result.size() && items.count < kMaxSuggestions;
         ++i) {
      const AutocompleteMatch& m = result.match_at(i);
      if (!m.destination_url.is_valid()) {
        continue;
      }
      LightSuggestionItem* it = [[LightSuggestionItem alloc] init];
      it.matchIndex = static_cast<int>(i);
      it.fillIntoEdit = rebrandChromeScheme(m.fill_into_edit);

      const bool isSearch = AutocompleteMatch::IsSearchType(m.type);
      if (isSearch) {
        it.primaryText = base::SysUTF16ToNSString(m.contents);
        if (m.type == omnibox::AutocompleteMatchType::kCalculator) {
          it.secondaryText = base::SysUTF16ToNSString(m.description);
          it.symbolName = @"equal.circle.fill";
          it.accentIcon = YES;
        } else {
          it.secondaryText =
              (m.type == omnibox::AutocompleteMatchType::kSearchWhatYouTyped)
                  ? @"Search"
                  : @"";
          it.symbolName =
              (m.type == omnibox::AutocompleteMatchType::kSearchHistory)
                  ? @"clock.arrow.circlepath"
                  : @"magnifyingglass";
        }
      } else {
        if (!m.description.empty()) {
          it.primaryText = base::SysUTF16ToNSString(m.description);
          it.secondaryText = rebrandChromeScheme(m.contents);
        } else {
          it.primaryText = rebrandChromeScheme(m.contents);
          it.secondaryText = @"";
        }
        if (m.destination_url.SchemeIs("chrome") ||
            m.destination_url.SchemeIs("light")) {
          it.symbolName = @"sparkles";
          it.accentIcon = YES;
        } else if (m.type == omnibox::AutocompleteMatchType::kOpenTab) {
          it.symbolName = @"macwindow";
          it.accentIcon = YES;
        } else if (m.type == omnibox::AutocompleteMatchType::kHistoryUrl ||
                   m.type == omnibox::AutocompleteMatchType::kHistoryTitle ||
                   m.type == omnibox::AutocompleteMatchType::kHistoryBody ||
                   m.type == omnibox::AutocompleteMatchType::kHistoryKeyword) {
          it.symbolName = @"clock.arrow.circlepath";
        } else {
          it.symbolName = @"globe";
        }
      }
      [items addObject:it];
    }

    if (@available(macOS 26.0, *)) {
      [controller_ applyAutocompleteSuggestions:items];
    }
  }

  // TabStripModelObserver:
  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override {
    if (selection.active_tab_changed()) {
      Observe(selection.new_contents);
    }
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabChangedAt(tabs::TabInterface* tab,
                      TabChangeType change_type) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabPinnedStateChanged(tabs::TabHandle tab) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void TabGroupedStateChanged(TabStripModel* tab_strip_model,
                              std::optional<tab_groups::TabGroupId> old_group,
                              std::optional<tab_groups::TabGroupId> new_group,
                              tabs::TabHandle tab) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabGroupChanged(const TabGroupChange& change) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabGroupAdded(const tab_groups::TabGroupId& group_id) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabGroupWillBeRemoved(
      const tab_groups::TabGroupId& group_id) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabStripModelDestroyed(TabStripModel* tab_strip_model) override {
    Observe(nullptr);
  }

  // content::WebContentsObserver:
  void DidStartLoading() override {
    NotifyNavUpdate();
    EnsureActiveWebContentsTransparent();
  }
  void DidStopLoading() override {
    NotifyNavUpdate();
    EnsureActiveWebContentsTransparent();
    InjectWebStoreLightBranding();
  }
  void PrimaryPageChanged(content::Page& page) override {
    NotifyNavUpdate();
    EnsureActiveWebContentsTransparent();
  }
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    if (navigation_handle->IsInPrimaryMainFrame()) {
      NotifyNavUpdate();
      EnsureActiveWebContentsTransparent();
      if (navigation_handle->HasCommitted()) {
        InjectWebStoreLightBranding();
      }
    }
  }
  void TitleWasSet(content::NavigationEntry* entry) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }
  void OnAudioStateChanged(bool audible) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  // CommandObserver:
  void EnabledStateChangedForCommand(int id, bool enabled) override {
    NotifyNavUpdate();
  }

 private:
  void InjectWebStoreLightBranding() {
    content::WebContents* wc = web_contents();
    if (!wc) {
      return;
    }
    const GURL& url = wc->GetLastCommittedURL();
    if (!url.is_valid() || url.host() != "chromewebstore.google.com") {
      return;
    }
    content::RenderFrameHost* rfh = wc->GetPrimaryMainFrame();
    if (!rfh || !rfh->IsRenderFrameLive()) {
      return;
    }
    static constexpr char16_t kJs[] =
        u"(function(){"
        u"if(window.__lightWebStorePatched)return;"
        u"window.__lightWebStorePatched=true;"
        u"const rw=()=>{"
        u"  const w=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT);"
        u"  let n;while((n=w.nextNode())){"
        u"    if(!n.nodeValue)continue;"
        u"    if(n.nodeValue.includes('Add to Chrome'))n.nodeValue=n.nodeValue.replaceAll('Add to Chrome','Add to Light');"
        u"    else if(n.nodeValue.includes('Add to Chromium'))n.nodeValue=n.nodeValue.replaceAll('Add to Chromium','Add to Light');"
        u"    else if(n.nodeValue.includes('Remove from Chrome'))n.nodeValue=n.nodeValue.replaceAll('Remove from Chrome','Remove from Light');"
        u"    else if(n.nodeValue.includes('Remove from Chromium'))n.nodeValue=n.nodeValue.replaceAll('Remove from Chromium','Remove from Light');"
        u"  }"
        u"};"
        u"rw();"
        u"new MutationObserver(rw).observe(document.documentElement,{childList:true,subtree:true,characterData:true});"
        u"})();";
    rfh->ExecuteJavaScriptInIsolatedWorld(
        kJs, base::DoNothing(), content::ISOLATED_WORLD_ID_CONTENT_END + 1);
  }

  void NotifyNavUpdate() {
    if (@available(macOS 26.0, *)) {
      [controller_ updateNavigationStateOnly];
    }
  }

  raw_ptr<BrowserView> browser_view_;
  std::unique_ptr<AutocompleteController> autocomplete_controller_;
  std::u16string last_autocomplete_query_;
  std::unordered_map<const content::WebContents*, GURL> pinned_origin_urls_;
  LightGlassSidebarObjCController* __strong controller_;
};

// -----------------------------------------------------------------------------
// Implementation of LightGlassSidebarObjCController
// -----------------------------------------------------------------------------
@interface LightSidebarMenuTarget : NSObject
@property(nonatomic, copy) void (^handler)(void);
- (void)invoke:(id)sender;
@end

@implementation LightSidebarMenuTarget
@synthesize handler = _handler;
- (void)invoke:(id)sender {
  if (_handler) {
    _handler();
  }
}
@end

@implementation LightGlassSidebarObjCController {
  raw_ptr<LightGlassSidebarBridgeImpl> _bridge;
  NSWindow* __weak _window;
  LightSidebarPassthroughView* __strong _overlayView;
  NSView* __strong _slideHostView;
  NSGlassEffectView* __strong _glassView;
  LightSidebarContentView* __strong _contentView;

  LightTrafficLightsGroupView* __strong _trafficLightsGroup;
  LightIconButton* __strong _sidebarToggleButton;
  LightIconButton* __strong _backButton;
  LightIconButton* __strong _forwardButton;
  LightIconButton* __strong _reloadButton;

  LightAddressContainerView* __strong _addressContainer;
  NSImageView* __strong _securityIconView;
  LightAddressTextField* __strong _addressField;
  LightIconButton* __strong _extensionsButton;
  NSMutableArray* __strong _menuActionTargets;

  NSGlassEffectView* __strong _expandedUrlGlassView;
  LightExpandedUrlContentView* __strong _expandedUrlContent;
  NSImageView* __strong _expandedSecurityIconView;
  LightAddressTextField* __strong _expandedAddressField;
  LightIconButton* __strong _expandedClearButton;
  NSBox* __strong _suggestionsDivider;
  NSMutableArray<LightSuggestionRowView*>* __strong _suggestionRowViews;
  NSArray<LightSuggestionItem*>* __strong _suggestionItems;
  NSString* __strong _userTypedAddressString;
  NSInteger _selectedSuggestionIndex;
  NSUInteger _addressBarAnimGen;
  CFTimeInterval _ignoreEndEditingUntil;

  NSScrollView* __strong _scrollView;
  LightFlippedDocumentView* __strong _tabsDocumentView;
  NSMutableArray<LightPinnedTileView*>* __strong _pinnedTileViews;
  NSMutableArray<LightTabGroupBlockView*>* __strong _groupBlockViews;
  NSMutableArray<LightTabRowView*>* __strong _tabRowViews;
  NSString* __strong _renamingGroupToken;

  NSBox* __strong _footerDivider;
  LightNewTabButtonView* __strong _newTabButton;
  LightIconButton* __strong _settingsButton;

  NSString* __strong _fullAddressString;
  NSString* __strong _displayAddressString;
  id __strong _blurFilter;
  id __strong _localEventMonitor;
  NSTimer* __strong _hoverWatchTimer;
  NSTimeInterval _lastMouseMoveLogTime;
  NSUInteger _visibilityGeneration;
  NSPoint _lastInsideWindowLocalPt;
  BOOL _wasCursorInsideWindow;
  BOOL _editingAddress;
  BOOL _contextMenuOpen;
  BOOL _settingsPreviewForceOpen;
  BOOL _inLiveResize;
  BOOL _pinned;
  BOOL _sidebarVisible;
}

- (instancetype)initWithBridge:(LightGlassSidebarBridgeImpl*)bridge
                        window:(NSWindow*)window {
  if ((self = [super init])) {
    _bridge = bridge;
    _window = window;
    _pinnedTileViews = [NSMutableArray array];
    _groupBlockViews = [NSMutableArray array];
    _tabRowViews = [NSMutableArray array];
    _suggestionRowViews = [NSMutableArray array];
    _suggestionItems = @[];
    _userTypedAddressString = @"";
    _selectedSuggestionIndex = -1;
    _fullAddressString = @"";
    _displayAddressString = @"";
    _pinned = !SidebarUDBool(@"LightSidebarAutoHide", true);
    _sidebarVisible = NO;
    [ActiveSidebarControllers() addObject:self];

    [self buildViewHierarchy];
    [self hideNativeWindowFrameTrafficLights];

    __weak __typeof(self) weakSelf = self;
    _localEventMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:
            (NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
             NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
             NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown |
             NSEventMaskScrollWheel | NSEventMaskKeyDown)
                                     handler:^NSEvent*(NSEvent* event) {
                                       [weakSelf handleWindowMouseEvent:event];
                                       return event;
                                     }];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidChangeFullScreen:)
               name:NSWindowDidEnterFullScreenNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidChangeFullScreen:)
               name:NSWindowDidExitFullScreenNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowKeyStateDidChange:)
               name:NSWindowDidBecomeKeyNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowKeyStateDidChange:)
               name:NSWindowDidResignKeyNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidResizeNote:)
               name:NSWindowDidResizeNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowWillStartLiveResizeNote:)
               name:NSWindowWillStartLiveResizeNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidEndLiveResizeNote:)
               name:NSWindowDidEndLiveResizeNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(lightSettingsDidChange:)
               name:@"LightSettingsDidChangeNotification"
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(settingsSidebarPreviewHoverChanged:)
               name:@"LightSettingsSidebarPreviewHoverNotification"
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(contextMenuDidBeginTracking:)
               name:NSMenuDidBeginTrackingNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(contextMenuDidEndTracking:)
               name:NSMenuDidEndTrackingNotification
             object:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s) {
        return;
      }
      [s hideNativeWindowFrameTrafficLights];
      BOOL shouldShow = s->_pinned || [s isCursorInLeftTriggerOrSidebar];
      [s setSidebarVisible:shouldShow animated:NO];
    });
  }
  return self;
}

- (void)teardown {
  [ActiveSidebarControllers() removeObject:self];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_localEventMonitor) {
    [NSEvent removeMonitor:_localEventMonitor];
    _localEventMonitor = nil;
  }
  [_hoverWatchTimer invalidate];
  _hoverWatchTimer = nil;
  _bridge = nullptr;
  [_overlayView removeFromSuperview];
  _overlayView = nil;
  _slideHostView = nil;
  _glassView = nil;
}

- (CGFloat)currentSidebarWidth {
  return SidebarUDDouble(@"LightSidebarWidth", kDefaultSidebarWidth);
}

- (CGFloat)currentSidebarCornerRadius {
  return SidebarUDDouble(@"LightSidebarCornerRadius",
                         kDefaultSidebarCornerRadius);
}

- (CGFloat)currentBlurRadius {
  return SidebarUDDouble(@"LightSidebarBlurRadius",
                         kDefaultSidebarHiddenBlurRadius);
}

- (CGFloat)currentTriggerWidth {
  return SidebarUDDouble(@"LightSidebarTriggerWidth",
                         kDefaultHoverEdgeTriggerWidth);
}

- (void)applyGlassMaterialSettings {
  if (!_glassView) {
    return;
  }
  NSInteger styleIdx =
      std::clamp<NSInteger>(SidebarUDInt(@"LightSidebarGlassStyle", 0), 0, 1);
  NSGlassEffectViewStyle glassStyle = (styleIdx == 1)
                                          ? NSGlassEffectViewStyleClear
                                          : NSGlassEffectViewStyleRegular;
  _glassView.style = glassStyle;
  if (_expandedUrlGlassView) {
    _expandedUrlGlassView.style = glassStyle;
  }

  NSInteger adaptiveVal = std::clamp<NSInteger>(
      SidebarUDInt(@"LightSidebarGlassAdaptive", 2), 0, 2);
  SEL adaptiveSel = NSSelectorFromString(@"set_adaptiveAppearance:");
  if ([_glassView respondsToSelector:adaptiveSel]) {
    [_glassView setValue:@(adaptiveVal) forKey:@"_adaptiveAppearance"];
  }
  if (_expandedUrlGlassView &&
      [_expandedUrlGlassView respondsToSelector:adaptiveSel]) {
    [_expandedUrlGlassView setValue:@(adaptiveVal)
                             forKey:@"_adaptiveAppearance"];
  }

  if (@available(macOS 27.0, *)) {
    BOOL interactive = SidebarUDBool(@"LightSidebarGlassInteractive", true);
    _glassView.effectIsInteractive = interactive;
    if (_expandedUrlGlassView) {
      _expandedUrlGlassView.effectIsInteractive = interactive;
    }
  }

  CGFloat tintAlphaPct = std::clamp<CGFloat>(
      SidebarUDDouble(@"LightSidebarTintAlpha", 4.0), 0.0, 100.0);
  if (tintAlphaPct <= 0.1) {
    _glassView.tintColor = nil;
    if (_expandedUrlGlassView) {
      _expandedUrlGlassView.tintColor = nil;
    }
  } else {
    CGFloat tr = std::clamp<CGFloat>(
        SidebarUDDouble(@"LightSidebarTintR", 1.0), 0.0, 1.0);
    CGFloat tg = std::clamp<CGFloat>(
        SidebarUDDouble(@"LightSidebarTintG", 1.0), 0.0, 1.0);
    CGFloat tb = std::clamp<CGFloat>(
        SidebarUDDouble(@"LightSidebarTintB", 1.0), 0.0, 1.0);
    CGFloat alpha = tintAlphaPct / 100.0;
    NSColor* tint = [NSColor colorWithSRGBRed:tr green:tg blue:tb alpha:alpha];
    _glassView.tintColor = tint;
    if (_expandedUrlGlassView) {
      _expandedUrlGlassView.tintColor =
          [NSColor colorWithSRGBRed:tr
                              green:tg
                               blue:tb
                              alpha:std::min<CGFloat>(0.90, alpha + 0.02)];
    }
  }

  CGFloat shadowPct = std::clamp<CGFloat>(
      SidebarUDDouble(@"LightSidebarShadowAlpha", 28.0), 0.0, 80.0);
  if (shadowPct <= 0.1) {
    _glassView.shadow = nil;
  } else {
    NSShadow* shadow = [[NSShadow alloc] init];
    shadow.shadowColor =
        [NSColor.blackColor colorWithAlphaComponent:(shadowPct / 100.0)];
    shadow.shadowBlurRadius = 22.0;
    shadow.shadowOffset = NSMakeSize(0.0, -6.0);
    _glassView.shadow = shadow;
  }
}

- (void)buildViewHierarchy {
  NSView* root = _window.contentView;
  if (!root) {
    return;
  }
  root.layerUsesCoreImageFilters = YES;

  _overlayView = [[LightSidebarPassthroughView alloc] initWithFrame:root.bounds];
  _overlayView.wantsLayer = YES;
  _overlayView.layerUsesCoreImageFilters = YES;
  _overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // _slideHostView owns sublayerTransform so _glassView.frame is never mutated
  // by CALayer transforms during window resize!
  _slideHostView = [[NSView alloc] initWithFrame:_overlayView.bounds];
  _slideHostView.wantsLayer = YES;
  _slideHostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  _glassView = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
  _glassView.wantsLayer = YES;
  _glassView.layerUsesCoreImageFilters = YES;
  _glassView.style = NSGlassEffectViewStyleRegular;
  _glassView.cornerRadius = [self currentSidebarCornerRadius];
  _glassView.tintColor = [NSColor colorWithWhite:1.0 alpha:0.04];
  _glassView.layer.masksToBounds = NO;

  NSShadow* shadow = [[NSShadow alloc] init];
  shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.28];
  shadow.shadowBlurRadius = 22.0;
  shadow.shadowOffset = NSMakeSize(0.0, -6.0);
  _glassView.shadow = shadow;

  _contentView = [[LightSidebarContentView alloc] initWithFrame:NSZeroRect];
  _contentView.wantsLayer = YES;
  _contentView.layerUsesCoreImageFilters = YES;
  _contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // Prepare GPU Gaussian blur filter for _contentView.layer (leaving
  // NSGlassEffectView's CABackdropLayer un-isolated). Only keep it attached
  // while blurred/animating so open-sidebar live resizes avoid CoreImage
  // offscreen rasterization.
  Class ciFilterClass = NSClassFromString(@"CIFilter");
  if (ciFilterClass) {
    id blurFilter = [(id<LightCIFilterPrivate>)ciFilterClass
        filterWithName:@"CIGaussianBlur"];
    if (blurFilter) {
      [blurFilter setDefaults];
      [blurFilter setValue:@([self currentBlurRadius]) forKey:@"inputRadius"];
      [blurFilter setValue:@"sidebarBlur" forKey:@"name"];
      _blurFilter = blurFilter;
      _contentView.layer.filters = @[ blurFilter ];
    }
  }

  _glassView.contentView = _contentView;

  _overlayView.glassPanel = _glassView;
  [_slideHostView addSubview:_glassView];
  [_overlayView addSubview:_slideHostView];
  [root addSubview:_overlayView positioned:NSWindowAbove relativeTo:nil];

  __weak __typeof(self) weakSelf = self;
  _overlayView.onLayoutBlock = ^{
    [weakSelf layoutOuterGlassGeometryForce:NO];
  };
  _overlayView.onHoverLeftEdge = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || s->_sidebarVisible || ![NSApp isActive] ||
        s->_inLiveResize || s->_window.inLiveResize ||
        [NSEvent pressedMouseButtons] != 0 || !s->_window || !s->_overlayView) {
      return;
    }
    NSPoint winPt = [s->_window convertPointFromScreen:[NSEvent mouseLocation]];
    NSPoint local = [s->_overlayView convertPoint:winPt fromView:nil];
    if (![s isPointInHoverRevealZone:local]) {
      return;
    }
    LightLogSidebarDiag("EDGE-TRACK-ENTER", s->_window, local,
                        s->_sidebarVisible);
    [s setSidebarVisible:YES animated:YES];
  };
  _contentView.onLayoutBlock = ^{
    [weakSelf layoutInnerControls];
  };
  _contentView.onDoubleClickEmpty = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->CreateNewTab();
    }
  };

  // Native traffic lights mounted directly ON the sidebar.
  _trafficLightsGroup =
      [[LightTrafficLightsGroupView alloc] initWithTargetWindow:_window];
  _trafficLightsGroup.onConfirmStateChanged = ^(BOOL active) {
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    NSRect targetFrame = [s sidebarToggleButtonFrame];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = active ? 0.15 : 0.16;
      ctx.timingFunction = active
          ? [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0]
          : [CAMediaTimingFunction
                functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      s->_sidebarToggleButton.animator.frame = targetFrame;
    }
                        completionHandler:nil];
    if (!active && !s->_pinned && !s->_settingsPreviewForceOpen &&
        [s shouldAutoCloseForCurrentCursor]) {
      [s setSidebarVisible:NO animated:YES];
    }
  };
  _trafficLightsGroup.onConfirmQuitAccepted = ^{
    g_confirm_quit_accepted_by_click = true;
    [NSApp terminate:nil];
  };
  [_contentView addSubview:_trafficLightsGroup];

  // Top navigation buttons.
  _sidebarToggleButton = [[LightIconButton alloc]
      initWithSymbol:(_pinned ? @"pin.fill" : @"pin")
           pointSize:12.5
              weight:NSFontWeightMedium
             toolTip:(_pinned ? @"Auto-Hide Sidebar" : @"Pin Sidebar Open")];
  _sidebarToggleButton.actionBlock = ^{
    [weakSelf toggleCollapsed];
  };
  [_contentView addSubview:_sidebarToggleButton];

  _backButton = [[LightIconButton alloc] initWithSymbol:@"chevron.left"
                                              pointSize:13.0
                                                 weight:NSFontWeightSemibold
                                                toolTip:@"Back"];
  _backButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->GoBack();
    }
  };
  [_contentView addSubview:_backButton];

  _forwardButton = [[LightIconButton alloc] initWithSymbol:@"chevron.right"
                                                 pointSize:13.0
                                                    weight:NSFontWeightSemibold
                                                   toolTip:@"Forward"];
  _forwardButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->GoForward();
    }
  };
  [_contentView addSubview:_forwardButton];

  _reloadButton = [[LightIconButton alloc] initWithSymbol:@"arrow.clockwise"
                                                pointSize:12.5
                                                   weight:NSFontWeightSemibold
                                                  toolTip:@"Reload"];
  _reloadButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->ReloadOrStop();
    }
  };
  [_contentView addSubview:_reloadButton];

  // Collapsed address / search bar inside sidebar header.
  _addressContainer =
      [[LightAddressContainerView alloc] initWithFrame:NSZeroRect];
  _addressContainer.wantsLayer = YES;
  _addressContainer.onActivate = ^{
    [weakSelf presentExpandedAddressBarSelectAll:YES];
  };
  [_contentView addSubview:_addressContainer];

  _securityIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _securityIconView.imageScaling = NSImageScaleProportionallyDown;
  _securityIconView.image =
      SymbolImage(@"magnifyingglass", 11.5, NSFontWeightMedium);
  _securityIconView.contentTintColor = NSColor.secondaryLabelColor;
  [_addressContainer addSubview:_securityIconView];

  _addressField = [[LightAddressTextField alloc] initWithFrame:NSZeroRect];
  _addressField.bordered = NO;
  _addressField.bezeled = NO;
  _addressField.drawsBackground = NO;
  _addressField.editable = NO;
  _addressField.selectable = NO;
  _addressField.focusRingType = NSFocusRingTypeNone;
  _addressField.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
  _addressField.textColor = NSColor.labelColor;
  _addressField.placeholderString = @"Search or enter address";
  _addressField.lineBreakMode = NSLineBreakByTruncatingTail;
  _addressField.usesSingleLineMode = YES;
  [_addressContainer addSubview:_addressField];

  _extensionsButton = [[LightIconButton alloc]
      initWithSymbol:@"puzzlepiece.extension"
           pointSize:12.0
              weight:NSFontWeightMedium
             toolTip:@"Extensions"];
  _extensionsButton.cornerRadius = 6.0;
  _extensionsButton.hidden = YES;
  _extensionsButton.alphaValue = 0.0;
  _extensionsButton.actionBlock = ^{
    [weakSelf showExtensionsMenu];
  };
  [_addressContainer addSubview:_extensionsButton];

  _addressContainer.onHoverChanged = ^(BOOL hovered) {
    [weakSelf updateExtensionsButtonVisibilityAnimated:YES];
  };

  // Rightward-expanding Liquid Glass URL popup mounted in _slideHostView above
  // _glassView so it can expand past the sidebar panel over the live web page.
  _expandedUrlGlassView = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
  _expandedUrlGlassView.wantsLayer = YES;
  _expandedUrlGlassView.style = NSGlassEffectViewStyleRegular;
  _expandedUrlGlassView.cornerRadius = 12.0;
  _expandedUrlGlassView.tintColor = [NSColor colorWithWhite:1.0 alpha:0.06];
  _expandedUrlGlassView.layer.masksToBounds = NO;
  _expandedUrlGlassView.hidden = YES;

  NSShadow* urlShadow = [[NSShadow alloc] init];
  urlShadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.30];
  urlShadow.shadowBlurRadius = 20.0;
  urlShadow.shadowOffset = NSMakeSize(0.0, -5.0);
  _expandedUrlGlassView.shadow = urlShadow;

  _expandedUrlContent =
      [[LightExpandedUrlContentView alloc] initWithFrame:NSZeroRect];
  _expandedUrlContent.wantsLayer = YES;
  _expandedUrlContent.layer.masksToBounds = YES;
  _expandedUrlContent.cornerRadius = 12.0;
  _expandedUrlContent.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  _expandedUrlContent.onLayoutBlock = ^{
    [weakSelf layoutExpandedUrlInnerControls];
  };
  _expandedUrlGlassView.contentView = _expandedUrlContent;

  _expandedSecurityIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _expandedSecurityIconView.imageScaling = NSImageScaleProportionallyDown;
  _expandedSecurityIconView.image = _securityIconView.image;
  _expandedSecurityIconView.contentTintColor = NSColor.secondaryLabelColor;
  [_expandedUrlContent addSubview:_expandedSecurityIconView];

  _expandedAddressField =
      [[LightAddressTextField alloc] initWithFrame:NSZeroRect];
  _expandedAddressField.bordered = NO;
  _expandedAddressField.bezeled = NO;
  _expandedAddressField.drawsBackground = NO;
  _expandedAddressField.focusRingType = NSFocusRingTypeNone;
  _expandedAddressField.font =
      [NSFont systemFontOfSize:13.5 weight:NSFontWeightRegular];
  _expandedAddressField.textColor = NSColor.labelColor;
  _expandedAddressField.placeholderString = @"Search or enter address";
  _expandedAddressField.lineBreakMode = NSLineBreakByClipping;
  _expandedAddressField.usesSingleLineMode = YES;
  _expandedAddressField.cell.scrollable = YES;
  _expandedAddressField.cell.wraps = NO;
  _expandedAddressField.delegate = self;
  [_expandedUrlContent addSubview:_expandedAddressField];

  _expandedClearButton =
      [[LightIconButton alloc] initWithSymbol:@"xmark.circle.fill"
                                    pointSize:12.5
                                       weight:NSFontWeightMedium
                                      toolTip:@"Clear"];
  _expandedClearButton.cornerRadius = 11.0;
  _expandedClearButton.hidden = YES;
  _expandedClearButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    s->_expandedAddressField.stringValue = @"";
    s->_userTypedAddressString = @"";
    s->_selectedSuggestionIndex = -1;
    s->_expandedClearButton.hidden = YES;
    if (s->_bridge) {
      s->_bridge->StartAutocomplete(std::u16string());
    } else {
      [s applyAutocompleteSuggestions:@[]];
    }
    [s layoutExpandedUrlInnerControls];
    [s->_window makeFirstResponder:s->_expandedAddressField];
  };
  [_expandedUrlContent addSubview:_expandedClearButton];

  _suggestionsDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
  _suggestionsDivider.boxType = NSBoxCustom;
  _suggestionsDivider.borderWidth = 0.0;
  _suggestionsDivider.fillColor =
      [NSColor.labelColor colorWithAlphaComponent:0.10];
  _suggestionsDivider.hidden = YES;
  [_expandedUrlContent addSubview:_suggestionsDivider];

  _overlayView.expandedUrlPanel = _expandedUrlGlassView;
  [_slideHostView addSubview:_expandedUrlGlassView
                  positioned:NSWindowAbove
                  relativeTo:_glassView];

  // Scrollable vertical tab list.
  _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _scrollView.drawsBackground = NO;
  _scrollView.hasVerticalScroller = YES;
  _scrollView.autohidesScrollers = YES;
  _scrollView.scrollerStyle = NSScrollerStyleOverlay;
  _scrollView.borderType = NSNoBorder;

  _tabsDocumentView = [[LightFlippedDocumentView alloc] initWithFrame:NSZeroRect];
  _tabsDocumentView.onDoubleClickEmpty = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->CreateNewTab();
    }
  };
  _tabsDocumentView.menuProvider = ^NSMenu* {
    return [weakSelf buildNewTabButtonContextMenu];
  };
  _scrollView.documentView = _tabsDocumentView;
  [_contentView addSubview:_scrollView];

  // Footer with "+ New Tab" button.
  _footerDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
  _footerDivider.boxType = NSBoxCustom;
  _footerDivider.borderWidth = 0.0;
  _footerDivider.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
  [_contentView addSubview:_footerDivider];

  _newTabButton = [[LightNewTabButtonView alloc] initWithFrame:NSZeroRect];
  _newTabButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->CreateNewTab();
    }
  };
  _newTabButton.menuProvider = ^NSMenu* {
    return [weakSelf buildNewTabButtonContextMenu];
  };
  [_contentView addSubview:_newTabButton];

  _settingsButton = [[LightIconButton alloc] initWithSymbol:@"gearshape"
                                                  pointSize:14.0
                                                     weight:NSFontWeightMedium
                                                    toolTip:@"Settings (⌘,)"];
  _settingsButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->OpenNativeSettings();
    }
  };
  [_contentView addSubview:_settingsButton];

  [self applyGlassMaterialSettings];
  [self layoutOuterGlassGeometryForce:YES];
  [self setSidebarVisible:_pinned animated:NO];
}

- (void)hideNativeWindowFrameTrafficLights {
  if (!_window || [self isWindowFullScreen]) {
    return;
  }
  const NSWindowButton kButtons[] = {
      NSWindowCloseButton,
      NSWindowMiniaturizeButton,
      NSWindowZoomButton,
  };
  for (NSWindowButton type : kButtons) {
    NSButton* btn = [_window standardWindowButton:type];
    if (btn && !btn.isHidden) {
      btn.hidden = YES;
    }
  }
}

- (void)windowDidChangeFullScreen:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  [self layoutOuterGlassGeometryForce:YES];
}

- (void)windowKeyStateDidChange:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  if (!_window.isKeyWindow && _trafficLightsGroup.isConfirmingQuit) {
    [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
  }
  [_trafficLightsGroup refreshState];
}

- (void)windowWillStartLiveResizeNote:(NSNotification*)note {
  _inLiveResize = YES;
  if (_trafficLightsGroup.isConfirmingQuit) {
    [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
  }
  LightLogSidebarDiag("SIDEBAR-LIVERESIZE-START", _window, NSZeroPoint,
                      _sidebarVisible);
}

- (void)windowDidEndLiveResizeNote:(NSNotification*)note {
  _inLiveResize = NO;
  [self layoutOuterGlassGeometryForce:NO];
  LightLogSidebarDiag("SIDEBAR-LIVERESIZE-END", _window, NSZeroPoint,
                      _sidebarVisible);
}

- (void)windowDidResizeNote:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  LightLogSidebarDiag("SIDEBAR-WIN-RESIZE", _window, NSZeroPoint,
                      _sidebarVisible);
}

- (void)contextMenuDidBeginTracking:(NSNotification*)note {
  _contextMenuOpen = YES;
}

- (void)contextMenuDidEndTracking:(NSNotification*)note {
  _contextMenuOpen = NO;
  if (!_pinned && !_settingsPreviewForceOpen && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

- (void)settingsSidebarPreviewHoverChanged:(NSNotification*)note {
  BOOL hovering = [note.userInfo[@"hovering"] boolValue];
  if (_settingsPreviewForceOpen == hovering) {
    return;
  }
  _settingsPreviewForceOpen = hovering;
  if (hovering) {
    [self setSidebarVisible:YES animated:YES];
  } else if (!_pinned && !_editingAddress && _renamingGroupToken.length == 0 &&
             !_contextMenuOpen && !_trafficLightsGroup.isConfirmingQuit &&
             ![self isCursorInLeftTriggerOrSidebar]) {
    [self setSidebarVisible:NO animated:YES];
  }
}

- (void)lightSettingsDidChange:(NSNotification*)note {
  BOOL autoHide = SidebarUDBool(@"LightSidebarAutoHide", true);
  _pinned = !autoHide;
  [_sidebarToggleButton setSymbol:(_pinned ? @"pin.fill" : @"pin")
                        pointSize:12.5
                           weight:NSFontWeightMedium];
  _sidebarToggleButton.toolTip =
      _pinned ? @"Auto-Hide Sidebar" : @"Pin Sidebar Open";
  [self applyGlassMaterialSettings];
  [_overlayView invalidateEdgeTrackingArea];
  [self layoutOuterGlassGeometryForce:YES];
  if ((_pinned || _settingsPreviewForceOpen) && !_sidebarVisible) {
    [self setSidebarVisible:YES animated:YES];
  } else if (!_pinned && !_settingsPreviewForceOpen && _sidebarVisible &&
             ![self isCursorInLeftTriggerOrSidebar]) {
    [self setSidebarVisible:NO animated:YES];
  }
}

- (BOOL)isWindowFullScreen {
  return (_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

- (BOOL)isWindowTouchingLeftScreenEdge {
  if (!_window) {
    return NO;
  }
  NSScreen* scr = _window.screen ?: NSScreen.mainScreen;
  if (!scr) {
    return NO;
  }
  const CGFloat winMinX = NSMinX(_window.frame);
  return std::abs(winMinX - NSMinX(scr.visibleFrame)) <= 3.0 ||
         std::abs(winMinX - NSMinX(scr.frame)) <= 3.0;
}

// Excludes the outer 3.5pt left window-resize border and 10pt corners when the
// window is floating so grabbing the window border to resize never pops open
// the sidebar, while slamming the cursor to x=0 when flush with the screen
// edge still opens instantly.
- (BOOL)isPointInHoverRevealZone:(NSPoint)local {
  if (!_overlayView) {
    return NO;
  }
  const NSRect bounds = _overlayView.bounds;
  const CGFloat h = bounds.size.height;
  const BOOL flushLeft =
      [self isWindowFullScreen] || [self isWindowTouchingLeftScreenEdge];
  if (!flushLeft && !NSPointInRect(local, bounds)) {
    return NO;
  }
  const CGFloat minX = flushLeft ? -2.0 : 3.5;
  const CGFloat maxX =
      (flushLeft ? 0.0 : 3.5) + [self currentTriggerWidth];
  const CGFloat cornerExclude = flushLeft ? 0.0 : 10.0;
  return local.x >= minX && local.x <= maxX && local.y >= cornerExclude &&
         local.y <= (h - cornerExclude);
}

// Cursor-based auto-close ONLY fires when the cursor is actively hovering OVER
// the browser window and positioned on the web page outside the sidebar. When
// the cursor leaves the browser window (e.g. sweeping past the left edge onto
// the desktop), Light ignores cursor movement and leaves sidebar state as-is.
- (BOOL)shouldAutoCloseForWindowPoint:(NSPoint)local {
  if (!_overlayView || !NSPointInRect(local, _overlayView.bounds)) {
    return NO;
  }
  if (_expandedUrlGlassView && !_expandedUrlGlassView.isHidden &&
      NSPointInRect(local, NSInsetRect(_expandedUrlGlassView.frame, -6.0, -6.0))) {
    return NO;
  }
  const CGFloat maxX =
      kSidebarInset + [self currentSidebarWidth] + kKeepOpenExtraMargin;
  return local.x > maxX;
}

- (BOOL)shouldAutoCloseForCurrentCursor {
  if (!_window || !_overlayView) {
    return NO;
  }
  NSPoint winPt = [_window convertPointFromScreen:[NSEvent mouseLocation]];
  NSPoint local = [_overlayView convertPoint:winPt fromView:nil];
  return [self shouldAutoCloseForWindowPoint:local];
}

- (CGFloat)closedTranslationX {
  return -(kSidebarInset + [self currentSidebarWidth] + 32.0);
}

- (BOOL)isCursorInLeftTriggerOrSidebar {
  if (!_window || !_overlayView) {
    return NO;
  }
  NSPoint screenPt = [NSEvent mouseLocation];
  NSPoint winPt = [_window convertPointFromScreen:screenPt];
  NSPoint local = [_overlayView convertPoint:winPt fromView:nil];
  if (!NSPointInRect(local, _overlayView.bounds)) {
    return NO;
  }
  if (!_sidebarVisible) {
    return [self isPointInHoverRevealZone:local];
  }
  if (_expandedUrlGlassView && !_expandedUrlGlassView.isHidden &&
      NSPointInRect(local, NSInsetRect(_expandedUrlGlassView.frame, -6.0, -6.0))) {
    return YES;
  }
  CGFloat maxX =
      kSidebarInset + [self currentSidebarWidth] + kKeepOpenExtraMargin;
  return local.x <= maxX;
}

- (BOOL)isEventInsideExpandedUrlBar:(NSEvent*)event {
  if (!_expandedUrlGlassView || _expandedUrlGlassView.isHidden || !event ||
      event.window != _window) {
    return NO;
  }
  NSPoint pt =
      [_expandedUrlGlassView convertPoint:event.locationInWindow fromView:nil];
  return NSPointInRect(pt, _expandedUrlGlassView.bounds);
}

- (void)handleWindowMouseEvent:(NSEvent*)event {
  if (!_window || !_overlayView || !event) {
    return;
  }

  // Fast-cancel Confirm Quit if the user interacts with the browser in any way
  // (clicks anywhere outside the red Confirm pill, scrolls, or presses any key
  // other than Cmd+Q).
  const NSEventType evType = event.type;
  if (_trafficLightsGroup.isConfirmingQuit) {
    if (evType == NSEventTypeKeyDown) {
      NSEventModifierFlags mods =
          event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
      BOOL isCmdQ = (mods == NSEventModifierFlagCommand) &&
                    [[event.charactersIgnoringModifiers lowercaseString]
                        isEqualToString:@"q"];
      if (!isCmdQ) {
        [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
      }
      return;
    }
    if (evType == NSEventTypeScrollWheel) {
      if (event.window == _window) {
        [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
      }
      return;
    }
    if ((evType == NSEventTypeLeftMouseDown ||
         evType == NSEventTypeRightMouseDown ||
         evType == NSEventTypeOtherMouseDown) &&
        event.window != nil &&
        ![_trafficLightsGroup isEventInsideConfirmPill:event]) {
      [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
    }
  } else if (evType == NSEventTypeKeyDown || evType == NSEventTypeScrollWheel ||
             evType == NSEventTypeOtherMouseDown) {
    return;
  }

  if (event.window != _window) {
    return;
  }

  // Collapse the expanded Liquid Glass URL popup if the user clicks anywhere
  // outside of it.
  if (_editingAddress &&
      (evType == NSEventTypeLeftMouseDown ||
       evType == NSEventTypeRightMouseDown) &&
      ![self isEventInsideExpandedUrlBar:event]) {
    [_window makeFirstResponder:nil];
    [self dismissExpandedAddressBarAnimated:YES];
    if (!_pinned && !_settingsPreviewForceOpen &&
        [self shouldAutoCloseForCurrentCursor]) {
      [self setSidebarVisible:NO animated:YES];
    }
    return;
  }

  NSPoint local = [_overlayView convertPoint:event.locationInWindow
                                    fromView:nil];
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (event.type != NSEventTypeMouseMoved ||
      (now - _lastMouseMoveLogTime) >= 0.05) {
    _lastMouseMoveLogTime = now;
    char extra[64];
    std::snprintf(extra, sizeof(extra), "evType=%lu",
                  (unsigned long)event.type);
    LightLogSidebarDiag("MOUSE", _window, local, _sidebarVisible, extra);
  }

  // Never fight live window edge/corner resize!
  if (_inLiveResize || _window.inLiveResize) {
    return;
  }

  const NSRect bounds = _overlayView.bounds;
  const BOOL insideWindow = NSPointInRect(local, bounds);
  const BOOL flushLeft =
      [self isWindowFullScreen] || [self isWindowTouchingLeftScreenEdge];

  // If cursor was inside the window and swept fast out the left edge of a
  // floating window in one frame, catch the left-edge exit so the sidebar
  // opens and stays open while the cursor continues outside the window!
  if (!insideWindow) {
    if (!_sidebarVisible && _wasCursorInsideWindow &&
        [NSEvent pressedMouseButtons] == 0 && local.x < 3.5 &&
        _lastInsideWindowLocalPt.x <= 220.0 && local.y >= 10.0 &&
        local.y <= (bounds.size.height - 10.0)) {
      _wasCursorInsideWindow = NO;
      [self setSidebarVisible:YES animated:YES];
      return;
    }
    if (!flushLeft || local.x < -2.0 || local.y < 0.0 ||
        local.y > bounds.size.height) {
      _wasCursorInsideWindow = NO;
      return;
    }
  } else {
    _wasCursorInsideWindow = YES;
    _lastInsideWindowLocalPt = local;
  }

  if (!_sidebarVisible) {
    // Do not reveal if mouse button is down or sitting on the outer 3.5pt
    // window resize border of a floating window.
    if ([NSEvent pressedMouseButtons] == 0 &&
        [self isPointInHoverRevealZone:local]) {
      [self setSidebarVisible:YES animated:YES];
    }
  } else if (!_pinned && !_trafficLightsGroup.isConfirmingQuit &&
             !_settingsPreviewForceOpen && !_contextMenuOpen) {
    // Only auto-close when cursor is INSIDE the window and crosses onto the
    // web page.
    if (!_editingAddress && _renamingGroupToken.length == 0 &&
        [NSEvent pressedMouseButtons] == 0 &&
        [self shouldAutoCloseForWindowPoint:local]) {
      [self setSidebarVisible:NO animated:YES];
    } else {
      [self ensureHoverWatchTimerRunning];
    }
  }
}

- (void)ensureHoverWatchTimerRunning {
  if (_hoverWatchTimer) {
    return;
  }
  __weak __typeof(self) weakSelf = self;
  _hoverWatchTimer = [NSTimer
      scheduledTimerWithTimeInterval:0.035
                             repeats:YES
                               block:^(NSTimer* timer) {
                                 [weakSelf hoverWatchTick];
                               }];
}

- (void)hoverWatchTick {
  if (_pinned || !_sidebarVisible) {
    [_hoverWatchTimer invalidate];
    _hoverWatchTimer = nil;
    return;
  }
  if (_inLiveResize || _window.inLiveResize || _editingAddress ||
      _renamingGroupToken.length > 0 || _contextMenuOpen ||
      _trafficLightsGroup.isConfirmingQuit || _settingsPreviewForceOpen ||
      [NSEvent pressedMouseButtons] != 0) {
    return;
  }
  NSPoint winPt = [_window convertPointFromScreen:[NSEvent mouseLocation]];
  NSPoint local = [_overlayView convertPoint:winPt fromView:nil];
  if (!NSPointInRect(local, _overlayView.bounds)) {
    if (!_sidebarVisible && _wasCursorInsideWindow && local.x < 3.5 &&
        _lastInsideWindowLocalPt.x <= 220.0 && local.y >= 10.0 &&
        local.y <= (_overlayView.bounds.size.height - 10.0)) {
      _wasCursorInsideWindow = NO;
      [self setSidebarVisible:YES animated:YES];
      return;
    }
    _wasCursorInsideWindow = NO;
    // Cursor is outside the browser window — do NOT use cursor movement
    // outside the window to close the sidebar!
    return;
  }
  _wasCursorInsideWindow = YES;
  _lastInsideWindowLocalPt = local;
  if ([self shouldAutoCloseForWindowPoint:local]) {
    [_hoverWatchTimer invalidate];
    _hoverWatchTimer = nil;
    [self setSidebarVisible:NO animated:YES];
  }
}

- (BOOL)ensureBlurFilterAttachedWithRadius:(CGFloat)radius {
  if (_blurFilter && (!_contentView.layer.filters ||
                      _contentView.layer.filters.count == 0)) {
    [_blurFilter setValue:@(radius) forKey:@"inputRadius"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentView.layer.filters = @[ _blurFilter ];
    [CATransaction commit];
    return YES;
  }
  return NO;
}

- (void)setSidebarVisible:(BOOL)visible animated:(BOOL)animated {
  if (!_overlayView || !_slideHostView || !_glassView || !_contentView) {
    return;
  }
  if (_sidebarVisible == visible && animated) {
    return;
  }
  _sidebarVisible = visible;
  _overlayView.sidebarInteractive = visible;
  NSUInteger gen = ++_visibilityGeneration;
  LightLogSidebarDiag(visible ? "SIDEBAR-SHOW" : "SIDEBAR-HIDE", _window,
                      NSZeroPoint, visible, animated ? "anim=1" : "anim=0");

  if (visible && !_pinned) {
    [self ensureHoverWatchTimerRunning];
  } else if (!visible) {
    [_hoverWatchTimer invalidate];
    _hoverWatchTimer = nil;
  }

  const CGFloat targetX = visible ? 0.0 : [self closedTranslationX];
  const CGFloat hiddenBlur = [self currentBlurRadius];
  const CGFloat targetBlur = visible ? 0.0 : hiddenBlur;
  constexpr float kClosedContentOpacity = 0.68f;
  const float targetOpacity = visible ? 1.0f : kClosedContentOpacity;

  const BOOL wasHidden = _glassView.isHidden;
  const BOOL reattachedFromUnblurred =
      [self ensureBlurFilterAttachedWithRadius:(wasHidden ? hiddenBlur : 0.0)];

  if (visible && wasHidden) {
    [self layoutOuterGlassGeometryForce:NO];
    _glassView.hidden = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_slideHostView.layer setValue:@([self closedTranslationX])
                        forKeyPath:@"sublayerTransform.translation.x"];
    [_contentView.layer setValue:@(hiddenBlur)
                      forKeyPath:@"filters.sidebarBlur.inputRadius"];
    _contentView.layer.opacity = kClosedContentOpacity;
    [CATransaction commit];
  }

  if (!animated) {
    [_slideHostView.layer removeAnimationForKey:@"sidebarSpringMove"];
    [_contentView.layer removeAnimationForKey:@"sidebarSpringBlur"];
    [_contentView.layer removeAnimationForKey:@"sidebarSpringOpacity"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_slideHostView.layer setValue:@(targetX)
                        forKeyPath:@"sublayerTransform.translation.x"];
    [_contentView.layer setValue:@(targetBlur)
                      forKeyPath:@"filters.sidebarBlur.inputRadius"];
    _contentView.layer.opacity = targetOpacity;
    if (visible) {
      _contentView.layer.filters = nil;
    }
    [CATransaction commit];
    _glassView.hidden = !visible;
    return;
  }

  CALayer* movePres =
      _slideHostView.layer.presentationLayer ?: _slideHostView.layer;
  CALayer* blurPres =
      _contentView.layer.presentationLayer ?: _contentView.layer;
  CGFloat fromX =
      wasHidden
          ? [self closedTranslationX]
          : [[movePres valueForKeyPath:@"sublayerTransform.translation.x"]
                doubleValue];
  CGFloat fromBlur =
      wasHidden
          ? hiddenBlur
          : (reattachedFromUnblurred
                 ? 0.0
                 : [[blurPres valueForKeyPath:@"filters.sidebarBlur.inputRadius"]
                       doubleValue]);
  float fromOpacity = wasHidden ? kClosedContentOpacity : blurPres.opacity;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [CATransaction setCompletionBlock:^{
    if (self->_visibilityGeneration == gen) {
      if (!visible) {
        self->_glassView.hidden = YES;
      } else {
        // Detach CoreImage filter while open at rest so live resizes never
        // allocate offscreen filter textures.
        self->_contentView.layer.filters = nil;
      }
    }
  }];

  [_slideHostView.layer setValue:@(targetX)
                      forKeyPath:@"sublayerTransform.translation.x"];
  [_contentView.layer setValue:@(targetBlur)
                    forKeyPath:@"filters.sidebarBlur.inputRadius"];
  _contentView.layer.opacity = targetOpacity;

  const float animSpeed = static_cast<float>(
      visible ? SidebarUDDouble(@"LightSidebarOpenSpeed", 4.0)
              : SidebarUDDouble(@"LightSidebarCloseSpeed", 2.0));

  CASpringAnimation* moveAnim = [CASpringAnimation
      animationWithKeyPath:@"sublayerTransform.translation.x"];
  if (visible) {
    moveAnim.mass = 2.0;
    moveAnim.stiffness = 300.0;
    moveAnim.damping = 50.0;
    moveAnim.initialVelocity = 0.0;
  } else {
    moveAnim.mass = 1.0;
    moveAnim.stiffness = 133.212;
    moveAnim.damping = 23.0835;
    moveAnim.initialVelocity = 0.0;
  }
  moveAnim.fromValue = @(fromX);
  moveAnim.toValue = @(targetX);
  moveAnim.duration = moveAnim.settlingDuration;
  moveAnim.speed = animSpeed;
  moveAnim.fillMode = kCAFillModeBackwards;
  moveAnim.removedOnCompletion = YES;
  [_slideHostView.layer addAnimation:moveAnim forKey:@"sidebarSpringMove"];

  CASpringAnimation* blurAnim = [CASpringAnimation
      animationWithKeyPath:@"filters.sidebarBlur.inputRadius"];
  blurAnim.mass = moveAnim.mass;
  blurAnim.stiffness = moveAnim.stiffness;
  blurAnim.damping = moveAnim.damping;
  blurAnim.initialVelocity = 0.0;
  blurAnim.fromValue = @(fromBlur);
  blurAnim.toValue = @(targetBlur);
  blurAnim.duration = blurAnim.settlingDuration;
  blurAnim.speed = animSpeed;
  blurAnim.fillMode = kCAFillModeBackwards;
  blurAnim.removedOnCompletion = YES;
  [_contentView.layer addAnimation:blurAnim forKey:@"sidebarSpringBlur"];

  CASpringAnimation* opacityAnim =
      [CASpringAnimation animationWithKeyPath:@"opacity"];
  opacityAnim.mass = moveAnim.mass;
  opacityAnim.stiffness = moveAnim.stiffness;
  opacityAnim.damping = moveAnim.damping;
  opacityAnim.initialVelocity = 0.0;
  opacityAnim.fromValue = @(fromOpacity);
  opacityAnim.toValue = @(targetOpacity);
  opacityAnim.duration = opacityAnim.settlingDuration;
  opacityAnim.speed = animSpeed;
  opacityAnim.fillMode = kCAFillModeBackwards;
  opacityAnim.removedOnCompletion = YES;
  [_contentView.layer addAnimation:opacityAnim forKey:@"sidebarSpringOpacity"];

  [CATransaction commit];
}

- (void)layoutOuterGlassGeometryForce:(BOOL)force {
  if (!_overlayView || !_glassView) {
    return;
  }
  // Avoid resizing NSGlassEffectView's backdrop/SDF/shadow on every pixel of
  // vertical live resize when the sidebar is completely hidden off-screen.
  if (!force && _glassView.isHidden &&
      (_inLiveResize || _window.inLiveResize)) {
    return;
  }
  const BOOL docked = _pinned && ![self isWindowFullScreen];
  const CGFloat targetRadius =
      docked ? 0.0 : [self currentSidebarCornerRadius];
  const BOOL radiusChanged =
      std::abs(_glassView.cornerRadius - targetRadius) > 0.01;
  if (radiusChanged) {
    _glassView.cornerRadius = targetRadius;
  }

  NSRect bounds = _overlayView.bounds;
  CGFloat w = [self currentSidebarWidth];
  NSRect fixedFrame =
      docked ? NSMakeRect(0.0, 0.0, w, bounds.size.height)
             : NSMakeRect(kSidebarInset, kSidebarInset, w,
                          std::max<CGFloat>(60.0,
                                            bounds.size.height -
                                                kSidebarInset * 2.0));
  const BOOL frameChanged = !NSEqualRects(_glassView.frame, fixedFrame);
  if (!force && !frameChanged && !radiusChanged) {
    if (_editingAddress && _expandedUrlGlassView &&
        !_expandedUrlGlassView.isHidden) {
      _expandedUrlGlassView.frame = [self expandedUrlBarFrameInSlideHost];
    }
    return;
  }
  if (frameChanged) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glassView.frame = fixedFrame;
    _contentView.frame = _glassView.bounds;
    [CATransaction commit];
  }
  [self hideNativeWindowFrameTrafficLights];
  [self layoutInnerControls];
  if (_editingAddress && _expandedUrlGlassView &&
      !_expandedUrlGlassView.isHidden) {
    _expandedUrlGlassView.frame = [self expandedUrlBarFrameInSlideHost];
  }
}

- (NSRect)sidebarToggleButtonFrame {
  BOOL fullScreen = [self isWindowFullScreen];
  CGFloat toggleX =
      fullScreen ? 8.0 : (_trafficLightsGroup.isConfirmingQuit ? 92.0 : 74.0);
  return NSMakeRect(toggleX, 5.0, 28.0, 28.0);
}

- (void)layoutInnerControls {
  if (!_contentView) {
    return;
  }
  NSRect b = _contentView.bounds;
  CGFloat w = b.size.width;
  CGFloat h = b.size.height;

  BOOL fullScreen = [self isWindowFullScreen];
  _trafficLightsGroup.hidden = fullScreen;
  _trafficLightsGroup.frame = NSMakeRect(9.0, 7.0, 84.0, 24.0);

  CGFloat topBtnY = 5.0;
  CGFloat btnSize = 28.0;

  _sidebarToggleButton.frame = [self sidebarToggleButtonFrame];

  CGFloat rightEdge = w - 8.0;
  _reloadButton.frame =
      NSMakeRect(rightEdge - btnSize, topBtnY, btnSize, btnSize);
  _forwardButton.frame =
      NSMakeRect(rightEdge - btnSize * 2.0 - 2.0, topBtnY, btnSize, btnSize);
  _backButton.frame =
      NSMakeRect(rightEdge - btnSize * 3.0 - 4.0, topBtnY, btnSize, btnSize);

  // Address container.
  CGFloat addrX = 8.0;
  CGFloat addrY = 40.0;
  CGFloat addrW = std::max<CGFloat>(0.0, w - 16.0);
  CGFloat addrH = 34.0;
  _addressContainer.frame = NSMakeRect(addrX, addrY, addrW, addrH);

  _securityIconView.frame =
      NSMakeRect(9.0, std::floor((addrH - 14.0) * 0.5), 14.0, 14.0);
  CGFloat extBtnW = 24.0;
  _extensionsButton.frame =
      NSMakeRect(std::max<CGFloat>(0.0, addrW - extBtnW - 4.0),
                 std::floor((addrH - extBtnW) * 0.5), extBtnW, extBtnW);
  BOOL showExt = !_extensionsButton.isHidden && _extensionsButton.alphaValue > 0.05;
  CGFloat rightReserve = showExt ? (extBtnW + 10.0) : 8.0;
  NSSize fieldFit = [_addressField sizeThatFits:NSMakeSize(500.0, addrH)];
  CGFloat fieldH = std::ceil(fieldFit.height);
  _addressField.frame =
      NSMakeRect(27.0, std::floor((addrH - fieldH) * 0.5),
                 std::max<CGFloat>(0.0, addrW - 27.0 - rightReserve), fieldH);

  // Footer: "+ New Tab" on the left, Settings gear button on the right.
  CGFloat footerTop = std::max<CGFloat>(kHeaderHeight, h - kFooterHeight);
  _footerDivider.frame =
      NSMakeRect(10.0, footerTop, std::max<CGFloat>(0.0, w - 20.0), 0.5);
  _settingsButton.frame =
      NSMakeRect(w - 38.0, footerTop + 9.0, 28.0, 28.0);
  _newTabButton.frame =
      NSMakeRect(6.0, footerTop + 6.0, std::max<CGFloat>(0.0, w - 48.0), 34.0);

  // Scrollable tabs area between header and footer.
  CGFloat scrollY = kHeaderHeight;
  CGFloat scrollH = std::max<CGFloat>(0.0, footerTop - scrollY - 4.0);
  _scrollView.frame = NSMakeRect(0.0, scrollY, w, scrollH);

  [self layoutTabRows];
}

- (void)updateExtensionsButtonVisibilityAnimated:(BOOL)animated {
  if (!_extensionsButton || !_addressContainer) {
    return;
  }
  BOOL shouldShow =
      _addressContainer.hovered && _bridge && _bridge->HasInstalledExtensions();
  if (shouldShow) {
    _extensionsButton.hidden = NO;
  }
  CGFloat targetAlpha = shouldShow ? 1.0 : 0.0;
  if (!animated) {
    _extensionsButton.alphaValue = targetAlpha;
    _extensionsButton.hidden = !shouldShow;
    [self layoutInnerControls];
    return;
  }
  __weak __typeof(self) weakSelf = self;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.12;
    ctx.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    _extensionsButton.animator.alphaValue = targetAlpha;
  }
      completionHandler:^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s) {
          return;
        }
        BOOL stillShow = s->_addressContainer.hovered && s->_bridge &&
                         s->_bridge->HasInstalledExtensions();
        if (!stillShow) {
          s->_extensionsButton.hidden = YES;
        }
        [s layoutInnerControls];
      }];
  [self layoutInnerControls];
}

- (NSMenuItem*)menuItemWithTitle:(NSString*)title
                          symbol:(NSString*)symbol
                           image:(NSImage*)image
                         handler:(void (^)(void))handler {
  if (!_menuActionTargets) {
    _menuActionTargets = [NSMutableArray array];
  }
  LightSidebarMenuTarget* target = [[LightSidebarMenuTarget alloc] init];
  target.handler = handler;
  [_menuActionTargets addObject:target];

  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(invoke:)
                                         keyEquivalent:@""];
  item.target = target;
  if (image) {
    image.size = NSMakeSize(16.0, 16.0);
    item.image = image;
  } else if (symbol) {
    NSImage* symImg = SymbolImage(symbol, 13.0, NSFontWeightRegular);
    [symImg setTemplate:YES];
    item.image = symImg;
  }
  return item;
}

- (BOOL)isPinned {
  return _pinned;
}

- (void)beginInlineRenameForGroupToken:(NSString*)token {
  _renamingGroupToken = token ?: @"";
}

- (NSMenu*)buildNewTabButtonContextMenu {
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  __weak __typeof(self) weakSelf = self;

  [menu addItem:[self menuItemWithTitle:@"New Tab"
                                 symbol:@"plus"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->CreateNewTab();
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"New Window"
                                 symbol:@"macwindow.badge.plus"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge && s->_bridge->browser()) {
                                    chrome::ExecuteCommand(s->_bridge->browser(),
                                                           IDC_NEW_WINDOW);
                                  }
                                }]];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:(_pinned ? @"Auto-Hide Sidebar"
                                                 : @"Pin Sidebar Open")
                                 symbol:(_pinned ? @"pin.slash" : @"pin")
                                  image:nil
                                handler:^{
                                  [weakSelf toggleCollapsed];
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Settings…"
                                 symbol:@"gearshape"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->OpenNativeSettings();
                                  }
                                }]];
  return menu;
}

- (void)showExtensionsMenu {
  if (!_bridge || !_extensionsButton) {
    return;
  }
  std::vector<std::tuple<std::string, std::u16string, NSImage*>> extensions;
  _bridge->GetInstalledExtensions(extensions);
  if (extensions.empty()) {
    return;
  }
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Extensions"];
  __weak __typeof(self) weakSelf = self;
  for (const auto& [actionId, name, icon] : extensions) {
    std::string capturedId = actionId;
    NSString* title = base::SysUTF16ToNSString(name);
    [menu addItem:[self menuItemWithTitle:title
                                   symbol:@"puzzlepiece.extension"
                                    image:icon
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->TriggerExtensionAction(
                                          capturedId);
                                    }
                                  }]];
  }
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Manage Extensions…"
                                 symbol:@"slider.horizontal.3"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->OpenManageExtensions();
                                  }
                                }]];
  NSPoint pt = NSMakePoint(0.0, NSHeight(_extensionsButton.bounds) + 4.0);
  [menu popUpMenuPositioningItem:nil atLocation:pt inView:_extensionsButton];
}

- (NSMenu*)buildTabContextMenuForIndex:(int)index {
  if (!_bridge) {
    return nil;
  }
  BrowserWindowInterface* browser = _bridge->browser();
  if (!browser) {
    return nil;
  }
  TabStripModel* model = browser->GetTabStripModel();
  if (!model || !model->ContainsIndex(index)) {
    return nil;
  }
  tabs::TabInterface* tab = model->GetTabAtIndex(index);
  if (!tab) {
    return nil;
  }
  tabs::TabData data = tabs::TabData::FromTabInterface(tab);
  const BOOL isPinned = data.pinned;
  const BOOL isAway = isPinned && _bridge->IsPinnedTabAway(index);
  content::WebContents* wc = model->GetWebContentsAt(index);
  const BOOL isMuted = wc && wc->IsAudioMuted();

  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tab"];
  __weak __typeof(self) weakSelf = self;

  [menu addItem:[self menuItemWithTitle:(isPinned ? @"Unpin Tab" : @"Pin Tab")
                                 symbol:(isPinned ? @"pin.slash" : @"pin")
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->TogglePinTabAt(index);
                                  }
                                }]];

  if (isAway) {
    [menu addItem:[self menuItemWithTitle:@"Reset to Pinned URL"
                                   symbol:@"arrow.counterclockwise"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->ResetPinnedTabAt(index);
                                    }
                                  }]];
    [menu addItem:[self menuItemWithTitle:@"Set Current URL as Pinned"
                                   symbol:@"pin.circle"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->ReplacePinnedTabOriginAt(
                                          index);
                                    }
                                  }]];
  }

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Reload"
                                 symbol:@"arrow.clockwise"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->ReloadTabAt(index);
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:(isMuted ? @"Unmute Site" : @"Mute Site")
                                 symbol:(isMuted ? @"speaker.wave.2"
                                                 : @"speaker.slash")
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->ToggleMuteTabAt(index);
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Duplicate"
                                 symbol:@"plus.square.on.square"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->DuplicateTabAt(index);
                                  }
                                }]];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Close Tab"
                                 symbol:@"xmark"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->CloseTabAt(index);
                                  }
                                }]];
  if (!isPinned && model->count() > 1) {
    [menu addItem:[self menuItemWithTitle:@"Close Other Tabs"
                                   symbol:@"xmark.circle"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->CloseOtherTabsAt(index);
                                    }
                                  }]];
  }
  return menu;
}

- (void)layoutTabRows {
  if (!_scrollView || !_tabsDocumentView) {
    return;
  }
  CGFloat w = _scrollView.bounds.size.width;
  CGFloat y = 4.0;

  if (_pinnedTileViews.count > 0) {
    constexpr CGFloat kPadX = 6.0;
    constexpr CGFloat kGap = 6.0;
    constexpr CGFloat kTileH = 36.0;
    constexpr NSUInteger kMaxPerRow = 3;
    CGFloat contentW = std::max<CGFloat>(0.0, w - kPadX * 2.0);
    NSUInteger total = _pinnedTileViews.count;
    NSUInteger idx = 0;
    while (idx < total) {
      NSUInteger rowCount = std::min<NSUInteger>(kMaxPerRow, total - idx);
      CGFloat gaps = rowCount > 1 ? (rowCount - 1) * kGap : 0.0;
      CGFloat tileW = std::max<CGFloat>(0.0, (contentW - gaps) / rowCount);
      CGFloat x = kPadX;
      for (NSUInteger c = 0; c < rowCount; ++c) {
        LightPinnedTileView* tile = _pinnedTileViews[idx + c];
        tile.frame = NSMakeRect(x, y, tileW, kTileH);
        x += tileW + kGap;
      }
      y += kTileH + kGap;
      idx += rowCount;
    }
    y += 4.0;
  }

  for (LightTabRowView* row in _tabRowViews) {
    row.frame =
        NSMakeRect(6.0, y, std::max<CGFloat>(0.0, w - 12.0), kTabRowHeight);
    y += kTabRowHeight + kTabRowSpacing;
  }
  CGFloat docH = std::max<CGFloat>(_scrollView.bounds.size.height, y + 6.0);
  _tabsDocumentView.frame = NSMakeRect(0.0, 0.0, w, docH);
}

- (void)toggleCollapsed {
  _pinned = !_pinned;
  [NSUserDefaults.standardUserDefaults setBool:!_pinned
                                        forKey:@"LightSidebarAutoHide"];
  [_sidebarToggleButton setSymbol:(_pinned ? @"pin.fill" : @"pin")
                        pointSize:12.5
                           weight:NSFontWeightMedium];
  _sidebarToggleButton.toolTip =
      _pinned ? @"Auto-Hide Sidebar" : @"Pin Sidebar Open";
  if (_pinned) {
    [self setSidebarVisible:YES animated:YES];
  } else {
    [self ensureHoverWatchTimerRunning];
  }
  [self layoutOuterGlassGeometryForce:YES];
  if (_bridge) {
    _bridge->InvalidateBrowserLayout();
  }
}

- (BOOL)isCollapsed {
  return !_sidebarVisible;
}

- (NSRect)collapsedUrlBarFrameInSlideHost {
  if (!_slideHostView || !_contentView || !_addressContainer) {
    return NSZeroRect;
  }
  return [_slideHostView convertRect:_addressContainer.frame
                            fromView:_contentView];
}

- (NSRect)expandedUrlBarFrameInSlideHost {
  NSRect collapsed = [self collapsedUrlBarFrameInSlideHost];
  if (NSIsEmptyRect(collapsed) || !_overlayView) {
    return collapsed;
  }
  const CGFloat winW = _overlayView.bounds.size.width;
  const CGFloat startX = collapsed.origin.x - 2.0;
  CGFloat targetW = std::clamp<CGFloat>(winW * 0.44, 380.0, 500.0);
  targetW = std::min<CGFloat>(
      targetW,
      std::max<CGFloat>(collapsed.size.width + 60.0, winW - startX - 18.0));

  // Keep the top edge locked at the URL bar slot while expanding downward to
  // fit search & autocomplete suggestions!
  const CGFloat topY = NSMaxY(collapsed) + 2.0;
  const CGFloat kInputRowH = collapsed.size.height + 4.0;
  const NSUInteger suggCount = _suggestionItems.count;
  const CGFloat extraH =
      (suggCount > 0) ? (1.0 + 10.0 + static_cast<CGFloat>(suggCount) * 35.0)
                      : 0.0;
  const CGFloat maxAllowedH = std::max<CGFloat>(kInputRowH, topY - 12.0);
  const CGFloat totalH = std::min<CGFloat>(kInputRowH + extraH, maxAllowedH);
  return NSMakeRect(startX, topY - totalH, targetW, totalH);
}

- (void)layoutExpandedUrlInnerControls {
  if (!_expandedUrlContent) {
    return;
  }
  NSRect b = _expandedUrlContent.bounds;
  CGFloat w = b.size.width;
  // Pin input row controls to the top 38pt header so they never shift vertically
  // as the Liquid Glass panel expands/contracts downward below!
  const CGFloat headerH = 38.0;

  _expandedSecurityIconView.frame =
      NSMakeRect(11.0, std::floor((headerH - 15.0) * 0.5), 15.0, 15.0);

  BOOL hasText = (_expandedAddressField.stringValue.length > 0);
  _expandedClearButton.hidden = !hasText;
  _expandedClearButton.frame =
      NSMakeRect(std::max<CGFloat>(0.0, w - 30.0),
                 std::floor((headerH - 22.0) * 0.5), 22.0, 22.0);

  NSSize fieldFit =
      [_expandedAddressField sizeThatFits:NSMakeSize(600.0, headerH)];
  CGFloat fieldH = std::ceil(fieldFit.height);
  CGFloat rightPad = hasText ? 34.0 : 12.0;
  _expandedAddressField.frame =
      NSMakeRect(31.0, std::floor((headerH - fieldH) * 0.5),
                 std::max<CGFloat>(0.0, w - 31.0 - rightPad), fieldH);

  const BOOL showSuggestions = (_suggestionItems.count > 0);
  _suggestionsDivider.hidden = !showSuggestions;
  _suggestionsDivider.frame =
      NSMakeRect(10.0, headerH, std::max<CGFloat>(0.0, w - 20.0), 0.5);

  CGFloat rowY = headerH + 5.0;
  for (NSUInteger i = 0; i < _suggestionRowViews.count; ++i) {
    LightSuggestionRowView* row = _suggestionRowViews[i];
    if (i < _suggestionItems.count) {
      row.hidden = NO;
      row.frame =
          NSMakeRect(5.0, rowY, std::max<CGFloat>(0.0, w - 10.0), 34.0);
      rowY += 35.0;
    } else {
      row.hidden = YES;
    }
  }
}

- (void)acceptSuggestionAtIndex:(NSInteger)idx {
  if (idx < 0 || idx >= static_cast<NSInteger>(_suggestionItems.count)) {
    return;
  }
  LightSuggestionItem* item = _suggestionItems[idx];
  if (_bridge) {
    _bridge->StopAutocomplete(/*clear_results=*/false);
  }
  [self dismissExpandedAddressBarAnimated:YES];
  [_window makeFirstResponder:nil];
  if (_bridge) {
    _bridge->OpenSuggestionItem(item);
  }
  if (!_pinned && !_settingsPreviewForceOpen &&
      [self shouldAutoCloseForCurrentCursor]) {
    [self setSidebarVisible:NO animated:YES];
  }
}

- (void)applyAutocompleteSuggestions:(NSArray<LightSuggestionItem*>*)items {
  if (!_editingAddress || !_expandedUrlGlassView ||
      _expandedUrlGlassView.isHidden) {
    _suggestionItems = @[];
    return;
  }
  _suggestionItems = items ? [items copy] : @[];
  if (_selectedSuggestionIndex >=
      static_cast<NSInteger>(_suggestionItems.count)) {
    _selectedSuggestionIndex = -1;
  }

  __weak __typeof(self) weakSelf = self;
  while (_suggestionRowViews.count < _suggestionItems.count) {
    LightSuggestionRowView* row =
        [[LightSuggestionRowView alloc] initWithFrame:NSZeroRect];
    row.onClick = ^(NSInteger clickedIdx) {
      [weakSelf acceptSuggestionAtIndex:clickedIdx];
    };
    [_expandedUrlContent addSubview:row];
    [_suggestionRowViews addObject:row];
  }

  for (NSUInteger i = 0; i < _suggestionItems.count; ++i) {
    LightSuggestionRowView* row = _suggestionRowViews[i];
    row.rowIndex = static_cast<NSInteger>(i);
    [row configureWithItem:_suggestionItems[i]
                  selected:(static_cast<NSInteger>(i) ==
                            _selectedSuggestionIndex)];
  }
  [self layoutExpandedUrlInnerControls];

  NSRect targetRect = [self expandedUrlBarFrameInSlideHost];
  if (!NSEqualRects(_expandedUrlGlassView.frame, targetRect)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.16;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithControlPoints:0.18 :1.0 :0.32 :1.0];
      _expandedUrlGlassView.animator.frame = targetRect;
      [_expandedUrlContent setNeedsDisplay:YES];
    }
                        completionHandler:nil];
  }
}

- (void)refreshSelectionVisualsAndEditorText {
  for (NSUInteger i = 0; i < _suggestionItems.count; ++i) {
    [_suggestionRowViews[i]
        configureWithItem:_suggestionItems[i]
                 selected:(static_cast<NSInteger>(i) ==
                           _selectedSuggestionIndex)];
  }
  NSString* newText = (_selectedSuggestionIndex >= 0 &&
                       _selectedSuggestionIndex <
                           static_cast<NSInteger>(_suggestionItems.count))
                          ? (_suggestionItems[_selectedSuggestionIndex]
                                 .fillIntoEdit ?: @"")
                          : (_userTypedAddressString ?: @"");
  _expandedAddressField.stringValue = newText;
  if (NSText* editor = _expandedAddressField.currentEditor) {
    [editor setSelectedRange:NSMakeRange(newText.length, 0)];
  }
  [self layoutExpandedUrlInnerControls];
}

- (void)presentExpandedAddressBarSelectAll:(BOOL)selectAll {
  if (!_sidebarVisible) {
    [self setSidebarVisible:YES animated:YES];
  }
  if (!_expandedUrlGlassView || !_addressContainer) {
    return;
  }
  if (_editingAddress && !_expandedUrlGlassView.isHidden) {
    [_window makeFirstResponder:_expandedAddressField];
    if (selectAll && _expandedAddressField.currentEditor) {
      [_expandedAddressField.currentEditor selectAll:nil];
    }
    return;
  }

  NSUInteger gen = ++_addressBarAnimGen;
  (void)gen;
  _ignoreEndEditingUntil = CACurrentMediaTime() + 0.25;
  _editingAddress = YES;
  _suggestionItems = @[];
  _selectedSuggestionIndex = -1;
  _userTypedAddressString = _fullAddressString ?: @"";
  for (LightSuggestionRowView* row in _suggestionRowViews) {
    row.hidden = YES;
  }
  _suggestionsDivider.hidden = YES;

  NSRect startRect = [self collapsedUrlBarFrameInSlideHost];
  NSRect endRect = [self expandedUrlBarFrameInSlideHost];

  _expandedSecurityIconView.image = _securityIconView.image;
  _expandedAddressField.stringValue = _fullAddressString ?: @"";
  _expandedClearButton.hidden = (_expandedAddressField.stringValue.length == 0);

  _addressContainer.hidden = YES;
  _expandedUrlGlassView.cornerRadius = 10.0;
  _expandedUrlContent.cornerRadius = 10.0;
  _expandedUrlGlassView.frame = startRect;
  [self layoutExpandedUrlInnerControls];
  _expandedUrlGlassView.hidden = NO;

  [_window makeFirstResponder:_expandedAddressField];
  if (selectAll) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_editingAddress &&
          self->_window.firstResponder ==
              self->_expandedAddressField.currentEditor) {
        [self->_expandedAddressField.currentEditor selectAll:nil];
      }
    });
  }

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.20;
    ctx.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
    _expandedUrlGlassView.animator.frame = endRect;
    _expandedUrlGlassView.cornerRadius = 13.0;
    _expandedUrlContent.cornerRadius = 13.0;
    [_expandedUrlContent setNeedsDisplay:YES];
  }
                      completionHandler:nil];
}

- (void)dismissExpandedAddressBarAnimated:(BOOL)animated {
  if (_bridge) {
    _bridge->StopAutocomplete(/*clear_results=*/true);
  }
  if (!_editingAddress &&
      (!_expandedUrlGlassView || _expandedUrlGlassView.isHidden)) {
    _addressContainer.hidden = NO;
    return;
  }
  NSUInteger gen = ++_addressBarAnimGen;
  _editingAddress = NO;
  _suggestionItems = @[];
  _selectedSuggestionIndex = -1;
  _addressField.stringValue = _displayAddressString ?: @"";
  _expandedClearButton.hidden = YES;
  _suggestionsDivider.hidden = YES;
  for (LightSuggestionRowView* row in _suggestionRowViews) {
    row.hidden = YES;
  }

  NSRect targetRect = [self collapsedUrlBarFrameInSlideHost];
  if (!animated || !_expandedUrlGlassView || _expandedUrlGlassView.isHidden) {
    _expandedUrlGlassView.hidden = YES;
    _addressContainer.hidden = NO;
    return;
  }

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.16;
    ctx.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.25 :1.0 :0.40 :1.0];
    _expandedUrlGlassView.animator.frame = targetRect;
    _expandedUrlGlassView.cornerRadius = 10.0;
    _expandedUrlContent.cornerRadius = 10.0;
    [_expandedUrlContent setNeedsDisplay:YES];
  }
                      completionHandler:^{
                        if (self->_addressBarAnimGen == gen) {
                          self->_expandedUrlGlassView.hidden = YES;
                          self->_addressContainer.hidden = NO;
                        }
                      }];
}

- (void)focusAddressBar:(BOOL)selectAll {
  [self presentExpandedAddressBarSelectAll:selectAll];
}

- (void)controlTextDidChange:(NSNotification*)obj {
  if (obj.object == _expandedAddressField) {
    NSString* currentText = _expandedAddressField.stringValue ?: @"";
    _userTypedAddressString = currentText;
    _selectedSuggestionIndex = -1;
    [self layoutExpandedUrlInnerControls];
    if (_bridge) {
      _bridge->StartAutocomplete(base::SysNSStringToUTF16(currentText));
    }
  }
}

- (void)controlTextDidEndEditing:(NSNotification*)obj {
  if (obj.object == _expandedAddressField && _editingAddress) {
    if (CACurrentMediaTime() < _ignoreEndEditingUntil &&
        _window.isKeyWindow) {
      [_window makeFirstResponder:_expandedAddressField];
      return;
    }
    [self dismissExpandedAddressBarAnimated:YES];
    if (!_pinned && !_settingsPreviewForceOpen && _sidebarVisible) {
      [self ensureHoverWatchTimerRunning];
    }
  }
}

- (BOOL)control:(NSControl*)control
               textView:(NSTextView*)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(moveDown:)) {
    if (_suggestionItems.count == 0 && _bridge &&
        _expandedAddressField.stringValue.length > 0) {
      _bridge->StartAutocomplete(
          base::SysNSStringToUTF16(_expandedAddressField.stringValue));
      return YES;
    }
    if (_suggestionItems.count > 0) {
      if (_selectedSuggestionIndex + 1 <
          static_cast<NSInteger>(_suggestionItems.count)) {
        _selectedSuggestionIndex += 1;
      } else {
        _selectedSuggestionIndex = -1;
      }
      [self refreshSelectionVisualsAndEditorText];
      return YES;
    }
  }
  if (commandSelector == @selector(moveUp:)) {
    if (_suggestionItems.count > 0) {
      if (_selectedSuggestionIndex >= 0) {
        _selectedSuggestionIndex -= 1;
      } else {
        _selectedSuggestionIndex =
            static_cast<NSInteger>(_suggestionItems.count) - 1;
      }
      [self refreshSelectionVisualsAndEditorText];
      return YES;
    }
  }
  if (commandSelector == @selector(insertNewline:)) {
    if (_selectedSuggestionIndex >= 0 &&
        _selectedSuggestionIndex <
            static_cast<NSInteger>(_suggestionItems.count)) {
      [self acceptSuggestionAtIndex:_selectedSuggestionIndex];
      return YES;
    }
    NSString* input = _expandedAddressField.stringValue ?: @"";
    [self dismissExpandedAddressBarAnimated:YES];
    [_window makeFirstResponder:nil];
    if (_bridge) {
      _bridge->NavigateToInput(base::SysNSStringToUTF16(input));
    }
    if (!_pinned && !_settingsPreviewForceOpen &&
        [self shouldAutoCloseForCurrentCursor]) {
      [self setSidebarVisible:NO animated:YES];
    }
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    [self dismissExpandedAddressBarAnimated:YES];
    [_window makeFirstResponder:nil];
    if (_bridge) {
      _bridge->FocusActiveWebContents();
    }
    if (!_pinned && !_settingsPreviewForceOpen &&
        [self shouldAutoCloseForCurrentCursor]) {
      [self setSidebarVisible:NO animated:YES];
    }
    return YES;
  }
  return NO;
}

- (NSWindow*)targetWindow {
  return _window;
}

- (BOOL)handleConfirmQuitAttempt {
  if (_trafficLightsGroup.isConfirmingQuit) {
    return YES;
  }
  if ([self isWindowFullScreen]) {
    [_window toggleFullScreen:nil];
  }
  [self setSidebarVisible:YES animated:YES];
  [_trafficLightsGroup presentConfirmQuitPill];
  return NO;
}

- (void)cancelConfirmQuit {
  [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
}

- (void)updateNavigationStateOnly {
  if (!_bridge) {
    return;
  }
  BrowserWindowInterface* browser = _bridge->browser();
  if (!browser) {
    return;
  }

  TabStripModel* model = browser->GetTabStripModel();
  content::WebContents* activeWC =
      model ? model->GetActiveWebContents() : nullptr;

  _backButton.enabled = activeWC && activeWC->GetController().CanGoBack();
  _forwardButton.enabled =
      activeWC && activeWC->GetController().CanGoForward();

  BOOL isLoading = activeWC && activeWC->IsLoading();
  [_reloadButton setSymbol:(isLoading ? @"xmark" : @"arrow.clockwise")
                 pointSize:12.5
                    weight:NSFontWeightSemibold];
  _reloadButton.toolTip = isLoading ? @"Stop" : @"Reload";

  GURL url = activeWC ? activeWC->GetVisibleURL() : GURL();
  if (IsNewTabOrBlankURL(url)) {
    _fullAddressString = @"";
    _displayAddressString = @"";
    _securityIconView.image =
        SymbolImage(@"magnifyingglass", 11.5, NSFontWeightMedium);
  } else if (url.SchemeIs("light") || url.SchemeIs("chrome")) {
    std::string host = url.GetHost();
    if (host == "chrome-urls" || host == "about") {
      host = "about";
    }
    std::string lightSpec = "light://" + host + url.GetPath();
    if (lightSpec.size() > 8 && lightSpec.back() == '/' &&
        url.GetPath() == "/") {
      lightSpec.pop_back();
    }
    if (url.has_query()) {
      lightSpec += "?" + url.GetQuery();
    }
    _fullAddressString = base::SysUTF8ToNSString(lightSpec);
    _displayAddressString = _fullAddressString;
    _securityIconView.image =
        SymbolImage(@"sparkles", 11.0, NSFontWeightMedium);
  } else {
    _fullAddressString = base::SysUTF8ToNSString(url.spec());
    std::u16string formatted = url_formatter::FormatUrl(
        url,
        url_formatter::kFormatUrlOmitDefaults |
            url_formatter::kFormatUrlOmitHTTPS |
            url_formatter::kFormatUrlOmitTrivialSubdomains,
        base::UnescapeRule::SPACES, nullptr, nullptr, nullptr);
    _displayAddressString = base::SysUTF16ToNSString(formatted);
    NSString* secSymbol = url.SchemeIsCryptographic() ? @"lock.fill" : @"globe";
    _securityIconView.image = SymbolImage(secSymbol, 11.0, NSFontWeightMedium);
  }

  _expandedSecurityIconView.image = _securityIconView.image;
  if (!_editingAddress) {
    _addressField.stringValue = _displayAddressString ?: @"";
  }
}

- (void)reloadTabsAndNavigation {
  if (!_bridge) {
    return;
  }
  [self updateNavigationStateOnly];

  BrowserWindowInterface* browser = _bridge->browser();
  BrowserView* browserView = _bridge->browser_view();
  if (!browser || !browserView) {
    return;
  }
  TabStripModel* model = browser->GetTabStripModel();
  if (!model) {
    return;
  }

  const int count = model->count();
  const int activeIndex = model->active_index();
  const ui::ColorProvider* colorProvider = browserView->GetColorProvider();

  std::vector<int> pinnedIndices;
  std::vector<int> unpinnedIndices;
  pinnedIndices.reserve(count);
  unpinnedIndices.reserve(count);
  for (int i = 0; i < count; ++i) {
    if (model->IsTabPinned(i)) {
      pinnedIndices.push_back(i);
    } else {
      unpinnedIndices.push_back(i);
    }
  }

  while (_pinnedTileViews.count > pinnedIndices.size()) {
    LightPinnedTileView* last = _pinnedTileViews.lastObject;
    [last removeFromSuperview];
    [_pinnedTileViews removeLastObject];
  }

  __weak __typeof(self) weakSelf = self;
  while (_pinnedTileViews.count < pinnedIndices.size()) {
    LightPinnedTileView* tile =
        [[LightPinnedTileView alloc] initWithFrame:NSZeroRect];
    tile.onSelect = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s || !s->_bridge) {
        return;
      }
      BrowserWindowInterface* b = s->_bridge->browser();
      TabStripModel* m = b ? b->GetTabStripModel() : nullptr;
      if (m && m->active_index() == idx && s->_bridge->IsPinnedTabAway(idx)) {
        s->_bridge->ResetPinnedTabAt(idx);
      } else {
        s->_bridge->ActivateTabAt(idx);
      }
    };
    tile.onClose = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        s->_bridge->CloseTabAt(idx);
      }
    };
    tile.onResetPin = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        s->_bridge->ResetPinnedTabAt(idx);
      }
    };
    tile.onDragAtScreenPoint = ^(int idx, NSPoint scrPt) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s || !s->_bridge || !s->_window || !s->_tabsDocumentView) {
        return;
      }
      NSPoint winPt = [s->_window convertPointFromScreen:scrPt];
      NSPoint docPt = [s->_tabsDocumentView convertPoint:winPt fromView:nil];
      for (LightPinnedTileView* candidate in s->_pinnedTileViews) {
        if (NSPointInRect(docPt, candidate.frame) && candidate.tabIndex != idx) {
          s->_bridge->MoveTabAt(idx, candidate.tabIndex);
          break;
        }
      }
    };
    tile.menuProvider = ^NSMenu*(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      return s ? [s buildTabContextMenuForIndex:idx] : nil;
    };
    [_tabsDocumentView addSubview:tile];
    [_pinnedTileViews addObject:tile];
  }

  while (_tabRowViews.count > unpinnedIndices.size()) {
    LightTabRowView* last = _tabRowViews.lastObject;
    [last removeFromSuperview];
    [_tabRowViews removeLastObject];
  }

  while (_tabRowViews.count < unpinnedIndices.size()) {
    LightTabRowView* row = [[LightTabRowView alloc] initWithFrame:NSZeroRect];
    row.onSelect = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        s->_bridge->ActivateTabAt(idx);
      }
    };
    row.onClose = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        s->_bridge->CloseTabAt(idx);
      }
    };
    row.onDragAtScreenPoint = ^(int idx, NSPoint scrPt) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s || !s->_bridge || !s->_window || !s->_tabsDocumentView) {
        return;
      }
      NSPoint winPt = [s->_window convertPointFromScreen:scrPt];
      NSPoint docPt = [s->_tabsDocumentView convertPoint:winPt fromView:nil];
      for (LightTabRowView* candidate in s->_tabRowViews) {
        if (NSPointInRect(docPt, candidate.frame) && candidate.tabIndex != idx) {
          s->_bridge->MoveTabAt(idx, candidate.tabIndex);
          break;
        }
      }
    };
    row.menuProvider = ^NSMenu*(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      return s ? [s buildTabContextMenuForIndex:idx] : nil;
    };
    [_tabsDocumentView addSubview:row];
    [_tabRowViews addObject:row];
  }

  auto extractFavicon = [&](const tabs::TabData& data) -> NSImage* {
    if (data.should_display_favicon && !data.favicon.IsEmpty() &&
        colorProvider && !IsNewTabOrBlankURL(data.visible_url)) {
      gfx::ImageSkia skia = data.favicon.Rasterize(colorProvider);
      if (!skia.isNull()) {
        return gfx::NSImageFromImageSkia(skia);
      }
    }
    return nil;
  };

  for (size_t p = 0; p < pinnedIndices.size(); ++p) {
    int i = pinnedIndices[p];
    tabs::TabInterface* tab = model->GetTabAtIndex(i);
    if (!tab) {
      continue;
    }
    tabs::TabData data = tabs::TabData::FromTabInterface(tab);
    NSString* title = base::SysUTF16ToNSString(data.title);
    NSString* urlSpec = base::SysUTF8ToNSString(data.visible_url.spec());
    BOOL isLoading = data.network_state == tabs::TabNetworkState::kWaiting ||
                     data.network_state == tabs::TabNetworkState::kLoading;
    content::WebContents* wc = model->GetWebContentsAt(i);
    BOOL audible = wc && wc->IsCurrentlyAudible();
    BOOL muted = wc && wc->IsAudioMuted();

    LightPinnedTileView* tile = _pinnedTileViews[p];
    tile.tabIndex = i;
    [tile configureWithTitle:title
                     urlSpec:urlSpec
                     favicon:extractFavicon(data)
                   isLoading:isLoading
                    selected:(i == activeIndex)
                     audible:audible
                       muted:muted];
  }

  for (size_t u = 0; u < unpinnedIndices.size(); ++u) {
    int i = unpinnedIndices[u];
    tabs::TabInterface* tab = model->GetTabAtIndex(i);
    if (!tab) {
      continue;
    }
    tabs::TabData data = tabs::TabData::FromTabInterface(tab);
    NSString* title = base::SysUTF16ToNSString(data.title);
    BOOL isLoading = data.network_state == tabs::TabNetworkState::kWaiting ||
                     data.network_state == tabs::TabNetworkState::kLoading;

    LightTabRowView* row = _tabRowViews[u];
    row.tabIndex = i;
    [row configureWithTitle:title
                    favicon:extractFavicon(data)
                  isLoading:isLoading
                   selected:(i == activeIndex)
                     pinned:NO];
  }

  [self layoutTabRows];
}

@end

@implementation LightConfirmQuitBridge

+ (NSNumber*)handleConfirmQuitAttempt {
  if (g_confirm_quit_accepted_by_click) {
    g_confirm_quit_accepted_by_click = false;
    return @YES;
  }
  if (@available(macOS 26.0, *)) {
    LightGlassSidebarObjCController* target = nil;
    NSWindow* keyWin = NSApp.keyWindow ?: NSApp.mainWindow;
    for (id obj in ActiveSidebarControllers()) {
      LightGlassSidebarObjCController* ctrl =
          (LightGlassSidebarObjCController*)obj;
      if (ctrl.targetWindow == keyWin) {
        target = ctrl;
        break;
      }
      if (!target && ctrl.targetWindow.isVisible) {
        target = ctrl;
      }
    }
    if (!target) {
      return @YES;
    }
    BOOL confirmed = [target handleConfirmQuitAttempt];
    return @(confirmed);
  }
  return @YES;
}

+ (void)cancelConfirmQuit {
  g_confirm_quit_accepted_by_click = false;
  if (@available(macOS 26.0, *)) {
    for (id obj in ActiveSidebarControllers()) {
      LightGlassSidebarObjCController* ctrl =
          (LightGlassSidebarObjCController*)obj;
      [ctrl cancelConfirmQuit];
    }
  }
}

@end

// static
int LightGlassSidebarBridge::GetPinnedSidebarWidthForBrowserView(
    const BrowserView* browser_view) {
  auto it = ActiveSidebarBridges().find(browser_view);
  if (it == ActiveSidebarBridges().end() || !it->second) {
    return 0;
  }
  return it->second->GetPinnedSidebarWidth();
}

// static
std::unique_ptr<LightGlassSidebarBridge> LightGlassSidebarBridge::Create(
    BrowserView* browser_view,
    NSWindow* window) {
  if (@available(macOS 26.0, *)) {
    return std::make_unique<LightGlassSidebarBridgeImpl>(browser_view, window);
  }
  return nullptr;
}
