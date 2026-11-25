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
#include <unordered_set>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback_helpers.h"
#include "base/i18n/time_formatting.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/autocomplete/autocomplete_classifier_factory.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/command_observer.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
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
#include "chrome/browser/ui/tabs/tab_strip_model_delegate.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/tabs/tab_strip_user_gesture_details.h"
#include "components/favicon/core/favicon_service.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/browser/ui/extensions/extensions_toolbar_view_model.h"
#include "chrome/browser/ui/views/extensions/extensions_toolbar_desktop.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/contents_web_view.h"
#include "chrome/browser/ui/views/frame/light_extensions_manager_controller.h"
#include "chrome/browser/ui/views/frame/light_native_settings_controller.h"
#include "chrome/browser/ui/views/frame/light_tab_containers_mac.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/download/public/common/download_item.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_enums.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_match_type.h"
#include "components/omnibox/browser/autocomplete_provider.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "components/search_engines/template_url_service.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_id.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_group.h"
#include "components/tabs/public/tab_interface.h"
#include "components/tabs/public/tab_network_state.h"
#include "components/url_formatter/url_fixer.h"
#include "components/url_formatter/url_formatter.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/ssl_status.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/isolated_world_ids.h"
#include "extensions/browser/extension_icon_image.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "net/cert/cert_status_flags.h"
#include "net/cert/x509_certificate.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "third_party/skia/include/core/SkColor.h"
#import "ui/base/cocoa/macos27_sdk.h"
#include "ui/base/models/image_model.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "url/gurl.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

constexpr CGFloat kSidebarInset = 7.0;
constexpr CGFloat kAppFramePadding = 6.0;
constexpr CGFloat kDefaultSidebarWidth = 228.0;
constexpr CGFloat kDefaultSidebarCornerRadius = 20.0;
constexpr CGFloat kDefaultSidebarHiddenBlurRadius = 14.0;
constexpr CGFloat kDefaultHoverEdgeTriggerWidth = 4.0;
constexpr CGFloat kKeepOpenExtraMargin = 10.0;
constexpr CGFloat kHeaderHeight = 84.0;
constexpr CGFloat kFooterHeight = 46.0;
constexpr CGFloat kTabRowHeight = 34.0;
constexpr CGFloat kTabRowSpacing = 2.0;

bool IsLikelyURLInput(const std::string& utf8) {
  if (utf8.empty()) {
    return false;
  }
  for (unsigned char c : utf8) {
    if (std::isspace(c)) {
      return false;
    }
  }
  const std::string lower = base::ToLowerASCII(utf8);
  static constexpr const char* kSchemes[] = {
      "http://", "https://", "light://", "chrome://", "about:",
      "file://", "data:",    "javascript:", "view-source:", "ftp://",
  };
  for (const char* scheme : kSchemes) {
    if (base::StartsWith(lower, scheme, base::CompareCase::SENSITIVE)) {
      return true;
    }
  }
  if (lower == "localhost" ||
      base::StartsWith(lower, "localhost:", base::CompareCase::SENSITIVE) ||
      base::StartsWith(lower, "localhost/", base::CompareCase::SENSITIVE)) {
    return true;
  }
  // Host:port (e.g. myserver:3000 or 127.0.0.1:8080)
  const size_t slash = lower.find('/');
  const std::string authority =
      (slash == std::string::npos) ? lower : lower.substr(0, slash);
  const size_t colon = authority.rfind(':');
  if (colon != std::string::npos && colon > 0 && colon + 1 < authority.size()) {
    bool all_digits = true;
    for (size_t i = colon + 1; i < authority.size(); ++i) {
      if (!std::isdigit(static_cast<unsigned char>(authority[i]))) {
        all_digits = false;
        break;
      }
    }
    if (all_digits) {
      return true;
    }
  }
  // Domain with a dot and valid TLD (at least 2 alpha chars or numeric IPv4)
  const size_t dot = authority.rfind('.');
  if (dot != std::string::npos && dot > 0 && dot + 1 < authority.size()) {
    const std::string tld = authority.substr(dot + 1);
    if (tld.size() >= 2) {
      bool valid_tld = true;
      for (unsigned char c : tld) {
        if (!std::isalnum(c) && c != '-') {
          valid_tld = false;
          break;
        }
      }
      if (valid_tld && authority.find("..") == std::string::npos) {
        return true;
      }
    }
  }
  return false;
}

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

void LightLogSidebarDiag(const char* tag,
                         NSWindow* win,
                         NSPoint localPt,
                         BOOL sidebarVis,
                         const char* extra = "") {
  (void)tag;
  (void)win;
  (void)localPt;
  (void)sidebarVis;
  (void)extra;
}

void MakeMenuItemImageVisible(NSMenuItem* item) {
  if (!item || !item.image) {
    return;
  }
  if (@available(macOS 27, *)) {
    item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
  }
}

NSString* FormatByteSize(int64_t bytes) {
  if (bytes < 0) {
    return @"";
  }
  if (bytes < 1024) {
    return [NSString stringWithFormat:@"%lld B", bytes];
  }
  double kb = static_cast<double>(bytes) / 1024.0;
  if (kb < 1024.0) {
    return [NSString stringWithFormat:@"%.1f KB", kb];
  }
  double mb = kb / 1024.0;
  if (mb < 1024.0) {
    return [NSString stringWithFormat:@"%.1f MB", mb];
  }
  return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
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

NSColor* SidebarColorFromHex(const std::string& hex) {
  unsigned int rgb = 0x0A84FF;
  if (!hex.empty() && hex[0] == '#' && hex.size() == 7) {
    std::sscanf(hex.c_str() + 1, "%x", &rgb);
  }
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                             green:((rgb >> 8) & 0xFF) / 255.0
                              blue:(rgb & 0xFF) / 255.0
                             alpha:1.0];
}

}  // namespace

class LightGlassSidebarBridgeImpl;

// -----------------------------------------------------------------------------
// Hover-aware icon button used in header and tab rows.
// -----------------------------------------------------------------------------
@interface LightIconButton : NSView
@property(nonatomic, copy) void (^actionBlock)(void);
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
@property(nonatomic, assign) BOOL activeHighlight;
@property(nonatomic, assign) CGFloat cornerRadius;
@property(nonatomic, assign) BOOL showProgressRing;
@property(nonatomic, assign) CGFloat progressFraction;
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
  BOOL _activeHighlight;
  BOOL _showProgressRing;
  CGFloat _progressFraction;
}

@synthesize actionBlock = _actionBlock;
@synthesize enabled = _enabled;
@synthesize activeHighlight = _activeHighlight;
@synthesize cornerRadius = _cornerRadius;
@synthesize showProgressRing = _showProgressRing;
@synthesize progressFraction = _progressFraction;

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

- (void)setActiveHighlight:(BOOL)activeHighlight {
  if (_activeHighlight == activeHighlight) {
    return;
  }
  _activeHighlight = activeHighlight;
  [self setNeedsDisplay:YES];
}

- (void)setShowProgressRing:(BOOL)showProgressRing {
  if (_showProgressRing == showProgressRing) {
    return;
  }
  _showProgressRing = showProgressRing;
  [self setNeedsDisplay:YES];
}

- (void)setProgressFraction:(CGFloat)progressFraction {
  CGFloat clamped = std::clamp<CGFloat>(progressFraction, 0.0, 1.0);
  if (std::abs(_progressFraction - clamped) < 0.005) {
    return;
  }
  _progressFraction = clamped;
  if (_showProgressRing) {
    [self setNeedsDisplay:YES];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  if (_enabled && (_hovered || _pressed || _activeHighlight)) {
    CGFloat alpha = _pressed ? 0.18 : (_activeHighlight ? 0.16 : 0.10);
    [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                         xRadius:_cornerRadius
                                                         yRadius:_cornerRadius];
    [path fill];
  }
  if (_showProgressRing) {
    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    CGFloat radius =
        std::min(self.bounds.size.width, self.bounds.size.height) * 0.5 - 2.5;
    NSBezierPath* track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center
                                      radius:radius
                                  startAngle:0.0
                                    endAngle:360.0
                                   clockwise:NO];
    track.lineWidth = 2.0;
    [[NSColor.labelColor colorWithAlphaComponent:0.18] setStroke];
    [track stroke];

    CGFloat sweep = std::max<CGFloat>(0.08, _progressFraction) * 360.0;
    NSBezierPath* arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:center
                                    radius:radius
                                startAngle:90.0
                                  endAngle:90.0 - sweep
                                 clockwise:YES];
    arc.lineWidth = 2.0;
    arc.lineCapStyle = NSLineCapStyleRound;
    [NSColor.controlAccentColor setStroke];
    [arc stroke];
  }
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
  if (ok) {
    if ([self.currentEditor isKindOfClass:[NSTextView class]]) {
      NSTextView* tv = (NSTextView*)self.currentEditor;
      tv.automaticTextReplacementEnabled = NO;
      tv.automaticSpellingCorrectionEnabled = NO;
      tv.automaticQuoteSubstitutionEnabled = NO;
      tv.automaticDashSubstitutionEnabled = NO;
      tv.automaticLinkDetectionEnabled = NO;
      tv.continuousSpellCheckingEnabled = NO;
      if (@available(macOS 14.0, *)) {
        tv.inlinePredictionType = NSTextInputTraitTypeNo;
      }
    }
    if (_onFocusChanged) {
      _onFocusChanged(YES);
    }
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
@property(nonatomic, strong) NSColor* backgroundTintDark;
@property(nonatomic, strong) NSColor* backgroundTintLight;
@property(nonatomic, strong) id blurredCGImageObj;  // CFBridgingRelease(CGImageRef)
@property(nonatomic, assign) CGFloat singleLuma;
@property(nonatomic, strong) NSColor* singleMarkColor;
@property(nonatomic, strong) NSArray* conicCGColors;
@property(nonatomic, strong) NSArray<NSNumber*>* conicLocations;
+ (LightPinVisualAnalysis*)analysisForFavicon:(NSImage*)favicon
                                     cacheKey:(NSString*)cacheKey;
@end

@implementation LightPinVisualAnalysis {
  std::vector<NSColor*> _glowColors;    // [avg, dom0, dom1, dom2]
  std::vector<CGFloat> _glowCoverage;   // 36 bins normalized 0..1
}

@synthesize isMultiColor = _isMultiColor;
@synthesize backgroundTintDark = _backgroundTintDark;
@synthesize backgroundTintLight = _backgroundTintLight;
@synthesize blurredCGImageObj = _blurredCGImageObj;
@synthesize singleLuma = _singleLuma;
@synthesize singleMarkColor = _singleMarkColor;
@synthesize conicCGColors = _conicCGColors;
@synthesize conicLocations = _conicLocations;

+ (NSCache<NSString*, LightPinVisualAnalysis*>*)sharedCache {
  static NSCache<NSString*, LightPinVisualAnalysis*>* cache = nil;
  if (!cache) {
    cache = [[NSCache alloc] init];
    cache.countLimit = 192;
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
  if (!favicon) {
    return nil;
  }

  // Render favicon into an explicit sRGB premultiplied RGBA 64x64 bitmap so
  // pixel extraction is color-space accurate and we can hash pixels to detect
  // favicon updates on the same URL (avoiding stale placeholder caches!).
  constexpr int kDim = 64;
  std::vector<uint8_t> pixels(kDim * kDim * 4, 0);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(
      pixels.data(), kDim, kDim, 8, kDim * 4, srgb,
      static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
          static_cast<uint32_t>(kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(srgb);
  if (!bctx) {
    return nil;
  }
  CGContextSetInterpolationQuality(bctx, kCGInterpolationHigh);
  NSGraphicsContext* nsCtx =
      [NSGraphicsContext graphicsContextWithCGContext:bctx flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = nsCtx;
  [favicon drawInRect:NSMakeRect(0, 0, kDim, kDim)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:NO
                hints:nil];
  [NSGraphicsContext restoreGraphicsState];

  // Fast FNV-1a pixel hash (sampled every 4th pixel for ~1us speed).
  uint64_t hash = 14695981039346656037ULL;
  for (int i = 0; i < kDim * kDim; i += 4) {
    uint32_t px = (static_cast<uint32_t>(pixels[i * 4 + 0]) << 24) |
                  (static_cast<uint32_t>(pixels[i * 4 + 1]) << 16) |
                  (static_cast<uint32_t>(pixels[i * 4 + 2]) << 8) |
                  static_cast<uint32_t>(pixels[i * 4 + 3]);
    hash ^= px;
    hash *= 1099511628211ULL;
  }
  NSString* fullKey = [NSString stringWithFormat:@"%llx", hash];
  LightPinVisualAnalysis* cached = [[self sharedCache] objectForKey:fullKey];
  if (cached) {
    CGContextRelease(bctx);
    return cached;
  }

  const uint8_t* d = pixels.data();

  // 1) Opaque pixel spread test (monochrome / single-color vs multi-color)
  double sumR = 0, sumG = 0, sumB = 0;
  int opaqueCount = 0;
  for (int i = 0; i < kDim * kDim; ++i) {
    double a = d[i * 4 + 3] / 255.0;
    if (a >= 0.85) {
      double r = std::clamp((d[i * 4 + 0] / 255.0) / a, 0.0, 1.0);
      double g = std::clamp((d[i * 4 + 1] / 255.0) / a, 0.0, 1.0);
      double b = std::clamp((d[i * 4 + 2] / 255.0) / a, 0.0, 1.0);
      sumR += r;
      sumG += g;
      sumB += b;
      ++opaqueCount;
    }
  }
  if (opaqueCount == 0) {
    CGContextRelease(bctx);
    return nil;
  }
  const double meanR = sumR / opaqueCount;
  const double meanG = sumG / opaqueCount;
  const double meanB = sumB / opaqueCount;
  double spreadAcc = 0.0;
  for (int i = 0; i < kDim * kDim; ++i) {
    double a = d[i * 4 + 3] / 255.0;
    if (a >= 0.85) {
      double r = std::clamp((d[i * 4 + 0] / 255.0) / a, 0.0, 1.0) - meanR;
      double g = std::clamp((d[i * 4 + 1] / 255.0) / a, 0.0, 1.0) - meanG;
      double b = std::clamp((d[i * 4 + 2] / 255.0) / a, 0.0, 1.0) - meanB;
      spreadAcc += std::sqrt(r * r + g * g + b * b);
    }
  }
  const double spread = spreadAcc / opaqueCount;

  LightPinVisualAnalysis* out = [[LightPinVisualAnalysis alloc] init];

  if (spread < 0.055) {
    CGContextRelease(bctx);
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
    [[self sharedCache] setObject:out forKey:fullKey];
    return out;
  }

  // 2) Multi-color icon -> 6 hue buckets + 36 angular bins for GPU conic ring.
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
    CGContextRelease(bctx);
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
      if ((mx <= 0.0 ? 0.0 : (mx - mn) / mx) < 0.22) {
        continue;
      }
      if (best < 0 || score[h] > score[best] ||
          (score[h] == score[best] && h < best)) {
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
    NSColor* mixed = [NSColor colorWithSRGBRed:(dr * 0.85 + ar * 0.15)
                                         green:(dg * 0.85 + ag * 0.15)
                                          blue:(db * 0.85 + ab * 0.15)
                                         alpha:1.0];
    domCols.push_back([self cappedLight:mixed cap:0.92]);
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

  // Clean, non-muddy dominant-color backing tints for dark & light mode.
  NSColor* primaryTone = [self cappedLight:domCols[0] cap:0.82];
  out.backgroundTintDark = [primaryTone colorWithAlphaComponent:0.18];
  out.backgroundTintLight = [primaryTone colorWithAlphaComponent:0.13];

  // Precompute smooth 36-stop GPU conic gradient colors & locations.
  NSMutableArray* cgColors = [NSMutableArray arrayWithCapacity:37];
  NSMutableArray<NSNumber*>* locs = [NSMutableArray arrayWithCapacity:37];
  for (int s = 0; s <= 36; ++s) {
    CGFloat ang = (static_cast<CGFloat>(s) / 36.0) * 2.0 * M_PI;
    NSColor* cc = [out conicColorAtAngle:ang];
    CGFloat cv = out->_glowCoverage[s % 36];
    cv = std::clamp(cv, 0.0, 1.0);
    cv = cv * cv * (3.0 - 2.0 * cv);
    NSColor* stop = [cc colorWithAlphaComponent:(0.68 + 0.32 * cv)];
    [cgColors addObject:(__bridge id)stop.CGColor];
    [locs addObject:@(static_cast<double>(s) / 36.0)];
  }
  out.conicCGColors = cgColors;
  out.conicLocations = locs;

  // Clamped CIGaussianBlur cropped cleanly to (0, 0, kDim, kDim) so there are
  // no dark/transparent fringes around the tile backing.
  CGImageRef srcCG = CGBitmapContextCreateImage(bctx);
  CGContextRelease(bctx);
  if (srcCG) {
    CIImage* ciIn = [CIImage imageWithCGImage:srcCG];
    CGImageRelease(srcCG);
    CIImage* clamped = [ciIn imageByClampingToExtent];
    CIFilter* filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [filter setValue:clamped forKey:kCIInputImageKey];
    [filter setValue:@(10.0) forKey:kCIInputRadiusKey];
    CIImage* ciOut = filter.outputImage;
    if (ciOut) {
      CGImageRef blurredCG = [[self sharedCIContext]
          createCGImage:ciOut
               fromRect:CGRectMake(0, 0, kDim, kDim)];
      if (blurredCG) {
        out.blurredCGImageObj = CFBridgingRelease(blurredCG);
      }
    }
  }

  [[self sharedCache] setObject:out forKey:fullKey];
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

@end

// -----------------------------------------------------------------------------
// Netnyahoo Pinned Tile View (PinnedGrid.tsx + DockSelection.swift)
// -----------------------------------------------------------------------------
@interface LightPinnedTileView : NSView
@property(nonatomic, assign) int tabIndex;
@property(nonatomic, readonly) BOOL selected;
@property(nonatomic, readonly) BOOL multiSelected;
@property(nonatomic, copy) void (^onSelect)(int index,
                                            NSEventModifierFlags mods);
@property(nonatomic, copy) void (^onClose)(int index);
@property(nonatomic, copy) void (^onResetPin)(int index);
@property(nonatomic, copy) void (^onDragStart)(int index, NSView* view,
                                               NSPoint screenPt);
@property(nonatomic, copy) void (^onDragAtScreenPoint)(int index, NSPoint screenPt);
@property(nonatomic, copy) void (^onDragEnd)(int index, NSPoint screenPt);
@property(nonatomic, copy) NSMenu* (^menuProvider)(int index);
- (void)configureWithTitle:(NSString*)title
                   urlSpec:(NSString*)urlSpec
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  unloaded:(BOOL)unloaded
                  selected:(BOOL)selected
             multiSelected:(BOOL)multiSelected
                   audible:(BOOL)audible
                     muted:(BOOL)muted
            containerColor:(NSColor*)containerColor
        ephemeralContainer:(BOOL)ephemeralContainer;
- (void)animateBackingFadeInFast;
@end

@implementation LightPinnedTileView {
  CALayer* __strong _faceLayer;
  CALayer* __strong _clipTileLayer;
  CALayer* __strong _bgLayer;
  CALayer* __strong _blurredTintLayer;
  CALayer* __strong _borderRingLayer;
  CAGradientLayer* __strong _conicGlowLayer;
  CAShapeLayer* __strong _conicGlowMaskLayer;
  CAGradientLayer* __strong _conicGlowPressLayer;
  CAShapeLayer* __strong _conicGlowPressMaskLayer;
  CAShapeLayer* __strong _ephemeralActiveBorderLayer;
  NSColor* __strong _containerColor;
  BOOL _ephemeralContainer;
  BOOL _unloaded;
  NSImageView* __strong _iconView;
  NSImageView* __strong _audioBadgeView;
  LightPinVisualAnalysis* __strong _analysis;
  NSTrackingArea* __strong _trackingArea;
  BOOL _selected;
  BOOL _multiSelected;
  BOOL _hovered;
  BOOL _pressed;
  NSPoint _dragStartScreen;
  BOOL _dragging;
}

@synthesize tabIndex = _tabIndex;
@synthesize selected = _selected;
@synthesize multiSelected = _multiSelected;
@synthesize onSelect = _onSelect;
@synthesize onClose = _onClose;
@synthesize onResetPin = _onResetPin;
@synthesize onDragStart = _onDragStart;
@synthesize onDragAtScreenPoint = _onDragAtScreenPoint;
@synthesize onDragEnd = _onDragEnd;
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
    _blurredTintLayer.opacity = 0.24f;
    _blurredTintLayer.contentsGravity = kCAGravityResizeAspectFill;
    _blurredTintLayer.masksToBounds = YES;
    [_clipTileLayer addSublayer:_blurredTintLayer];

    _borderRingLayer = [CALayer layer];
    _borderRingLayer.cornerRadius = 10.0;
    _borderRingLayer.cornerCurve = kCACornerCurveContinuous;
    [_faceLayer addSublayer:_borderRingLayer];

    _conicGlowLayer = [CAGradientLayer layer];
    _conicGlowLayer.type = kCAGradientLayerConic;
    _conicGlowLayer.startPoint = CGPointMake(0.5, 0.5);
    _conicGlowLayer.endPoint = CGPointMake(1.0, 0.5);
    _conicGlowMaskLayer = [CAShapeLayer layer];
    _conicGlowMaskLayer.fillColor = nil;
    _conicGlowMaskLayer.strokeColor = NSColor.whiteColor.CGColor;
    _conicGlowMaskLayer.lineWidth = 2.0;
    _conicGlowMaskLayer.lineCap = kCALineCapRound;
    _conicGlowLayer.mask = _conicGlowMaskLayer;
    _conicGlowLayer.hidden = YES;
    [_faceLayer addSublayer:_conicGlowLayer];

    _conicGlowPressLayer = [CAGradientLayer layer];
    _conicGlowPressLayer.type = kCAGradientLayerConic;
    _conicGlowPressLayer.startPoint = CGPointMake(0.5, 0.5);
    _conicGlowPressLayer.endPoint = CGPointMake(1.0, 0.5);
    _conicGlowPressLayer.opacity = 0.0f;
    _conicGlowPressMaskLayer = [CAShapeLayer layer];
    _conicGlowPressMaskLayer.fillColor = nil;
    _conicGlowPressMaskLayer.strokeColor = NSColor.whiteColor.CGColor;
    _conicGlowPressMaskLayer.lineWidth = 3.0;
    _conicGlowPressMaskLayer.lineCap = kCALineCapRound;
    _conicGlowPressLayer.mask = _conicGlowPressMaskLayer;
    _conicGlowPressLayer.hidden = YES;
    [_faceLayer addSublayer:_conicGlowPressLayer];

    _ephemeralActiveBorderLayer = [CAShapeLayer layer];
    _ephemeralActiveBorderLayer.fillColor = NSColor.clearColor.CGColor;
    _ephemeralActiveBorderLayer.lineWidth = 2.0;
    _ephemeralActiveBorderLayer.lineCap = kCALineCapRound;
    _ephemeralActiveBorderLayer.lineDashPattern = @[ @5.0, @4.0 ];
    _ephemeralActiveBorderLayer.hidden = YES;
    [_faceLayer addSublayer:_ephemeralActiveBorderLayer];

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.wantsLayer = YES;
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
                  unloaded:(BOOL)unloaded
                  selected:(BOOL)selected
             multiSelected:(BOOL)multiSelected
                   audible:(BOOL)audible
                     muted:(BOOL)muted
            containerColor:(NSColor*)containerColor
        ephemeralContainer:(BOOL)ephemeralContainer {
  _selected = selected;
  _multiSelected = multiSelected;
  _containerColor = containerColor;
  _ephemeralContainer = ephemeralContainer;
  _unloaded = unloaded;
  self.toolTip = title.length > 0 ? title : (urlSpec ?: @"Pinned Tab");

  if (isLoading) {
    _iconView.image = SymbolImage(@"arrow.trianglehead.2.clockwise", 13.0,
                                  NSFontWeightMedium);
    _iconView.contentTintColor =
        selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
    // Preserve active conic glow while reloading if we already have the favicon.
    if (favicon) {
      _analysis = [LightPinVisualAnalysis
          analysisForFavicon:favicon
                    cacheKey:(urlSpec ?: title ?: @"pin")];
    } else {
      _analysis = nil;
    }
    if (_iconView.layer && ![_iconView.layer animationForKey:@"loadingSpin"]) {
      CABasicAnimation* spin =
          [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
      spin.fromValue = @(0.0);
      spin.toValue = @(2.0 * M_PI);
      spin.duration = 0.85;
      spin.repeatCount = HUGE_VALF;
      spin.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
      spin.removedOnCompletion = NO;
      [_iconView.layer addAnimation:spin forKey:@"loadingSpin"];
    }
  } else {
    [_iconView.layer removeAnimationForKey:@"loadingSpin"];
    if (favicon) {
      _iconView.image = favicon;
      _iconView.contentTintColor = nil;
      _analysis = [LightPinVisualAnalysis
          analysisForFavicon:favicon
                    cacheKey:(urlSpec ?: title ?: @"pin")];
    } else {
      _iconView.image = SymbolImage(
          @"globe", 14.0, selected ? NSFontWeightMedium : NSFontWeightRegular);
      _iconView.contentTintColor =
          selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
      _analysis = nil;
    }
  }
  _iconView.alphaValue = (unloaded && !selected && !isLoading) ? 0.52 : 1.0;

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
  NSRect iconRect = NSMakeRect(std::floor((w - 16.0) * 0.5),
                               std::floor((h - 16.0) * 0.5), 16.0, 16.0);
  _iconView.frame = iconRect;
  if (_iconView.layer) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _iconView.layer.anchorPoint = CGPointMake(0.5, 0.5);
    _iconView.layer.position =
        CGPointMake(NSMidX(iconRect), NSMidY(iconRect));
    [CATransaction commit];
  }
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
  _clipTileLayer.cornerCurve = kCACornerCurveContinuous;
  _bgLayer.frame = b;
  _blurredTintLayer.frame = b;
  _borderRingLayer.frame = b;
  _conicGlowLayer.frame = b;
  _conicGlowMaskLayer.frame = b;
  _conicGlowPressLayer.frame = b;
  _conicGlowPressMaskLayer.frame = b;
  _ephemeralActiveBorderLayer.frame = b;

  if (_selected) {
    if (_analysis && _analysis.isMultiColor &&
        _analysis.conicCGColors.count > 1) {
      // Native GPU conic glow ring + clean dominant-color backing!
      _bgLayer.backgroundColor =
          (dark ? _analysis.backgroundTintDark : _analysis.backgroundTintLight)
              .CGColor;
      _blurredTintLayer.contents = _analysis.blurredCGImageObj;
      _blurredTintLayer.hidden = (_analysis.blurredCGImageObj == nil);
      _borderRingLayer.hidden = YES;
      _borderRingLayer.borderWidth = 0.0;
      _ephemeralActiveBorderLayer.hidden = YES;

      _conicGlowLayer.colors = _analysis.conicCGColors;
      _conicGlowLayer.locations = _analysis.conicLocations;
      _conicGlowPressLayer.colors = _analysis.conicCGColors;
      _conicGlowPressLayer.locations = _analysis.conicLocations;

      NSArray<NSNumber*>* dash = _ephemeralContainer ? @[ @5.0, @4.0 ] : nil;
      _conicGlowMaskLayer.lineDashPattern = dash;
      _conicGlowPressMaskLayer.lineDashPattern = dash;
      CGPathRef p1 = CGPathCreateWithRoundedRect(
          CGRectInset(b, 1.0, 1.0), kRadius - 1.0, kRadius - 1.0, nullptr);
      _conicGlowMaskLayer.path = p1;
      CGPathRelease(p1);
      CGPathRef p2 = CGPathCreateWithRoundedRect(
          CGRectInset(b, 1.5, 1.5), kRadius - 1.5, kRadius - 1.5, nullptr);
      _conicGlowPressMaskLayer.path = p2;
      CGPathRelease(p2);

      _conicGlowLayer.hidden = NO;
      _conicGlowPressLayer.hidden = NO;
    } else if (_analysis) {
      // Single-color favicon -> contrasting tray + 2pt rim!
      _blurredTintLayer.hidden = YES;
      _conicGlowLayer.hidden = YES;
      _conicGlowPressLayer.hidden = YES;

      NSColor* fill = nil;
      NSColor* rim = nil;
      if (_analysis.singleLuma > 0.85) {
        fill = [NSColor colorWithWhite:0.0 alpha:0.24];
        rim = [NSColor colorWithWhite:(dark ? 1.0 : 0.0) alpha:0.55];
      } else if (_analysis.singleLuma < 0.15 && dark) {
        fill = [NSColor colorWithWhite:1.0 alpha:0.16];
        rim = [NSColor colorWithWhite:1.0 alpha:0.52];
      } else {
        fill = [_analysis.singleMarkColor colorWithAlphaComponent:(dark ? 0.18 : 0.14)];
        rim = [_analysis.singleMarkColor colorWithAlphaComponent:0.85];
      }
      _bgLayer.backgroundColor = fill.CGColor;
      if (_ephemeralContainer) {
        _borderRingLayer.hidden = YES;
        _borderRingLayer.borderWidth = 0.0;
        _ephemeralActiveBorderLayer.hidden = NO;
        _ephemeralActiveBorderLayer.strokeColor = rim.CGColor;
        CGPathRef dashPath = CGPathCreateWithRoundedRect(
            CGRectInset(b, 1.0, 1.0), kRadius - 1.0, kRadius - 1.0, nullptr);
        _ephemeralActiveBorderLayer.path = dashPath;
        CGPathRelease(dashPath);
      } else {
        _ephemeralActiveBorderLayer.hidden = YES;
        _borderRingLayer.hidden = NO;
        _borderRingLayer.borderWidth = 2.0;
        _borderRingLayer.borderColor = rim.CGColor;
      }
    } else {
      // Fallback active tile (globe / NTP)
      _blurredTintLayer.hidden = YES;
      _conicGlowLayer.hidden = YES;
      _conicGlowPressLayer.hidden = YES;
      _bgLayer.backgroundColor =
          [NSColor colorWithWhite:1.0 alpha:(dark ? 0.22 : 0.65)].CGColor;
      NSColor* fallbackRim =
          [NSColor colorWithWhite:(dark ? 1.0 : 0.0)
                            alpha:(dark ? 0.30 : 0.16)];
      if (_ephemeralContainer) {
        _borderRingLayer.hidden = YES;
        _borderRingLayer.borderWidth = 0.0;
        _ephemeralActiveBorderLayer.hidden = NO;
        _ephemeralActiveBorderLayer.strokeColor = fallbackRim.CGColor;
        CGPathRef dashPath = CGPathCreateWithRoundedRect(
            CGRectInset(b, 1.0, 1.0), kRadius - 1.0, kRadius - 1.0, nullptr);
        _ephemeralActiveBorderLayer.path = dashPath;
        CGPathRelease(dashPath);
      } else {
        _ephemeralActiveBorderLayer.hidden = YES;
        _borderRingLayer.hidden = NO;
        _borderRingLayer.borderWidth = 2.0;
        _borderRingLayer.borderColor = fallbackRim.CGColor;
      }
    }
  } else {
    // Resting / Pressed unselected pinned tile
    _blurredTintLayer.hidden = YES;
    _conicGlowLayer.hidden = YES;
    _conicGlowPressLayer.hidden = YES;
    _ephemeralActiveBorderLayer.hidden = YES;
    _borderRingLayer.hidden = NO;
    if (_multiSelected) {
      _borderRingLayer.borderWidth = 1.5;
      _borderRingLayer.borderColor =
          [NSColor.controlAccentColor colorWithAlphaComponent:0.85].CGColor;
      _bgLayer.backgroundColor =
          [NSColor.controlAccentColor colorWithAlphaComponent:0.20].CGColor;
    } else {
      _borderRingLayer.borderWidth = 0.5;
      _borderRingLayer.borderColor =
          (dark ? [NSColor colorWithWhite:1.0 alpha:0.14]
                : [NSColor colorWithWhite:0.0 alpha:0.18])
              .CGColor;

      // Hover highlight is driven by LightHoverTrailController on the GPU canvas.
      NSColor* restingFill = nil;
      if (_pressed) {
        restingFill = dark ? [NSColor colorWithWhite:1.0 alpha:0.31]
                           : [NSColor colorWithWhite:1.0 alpha:0.70];
      } else {
        restingFill = dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
                           : [NSColor colorWithWhite:0.0 alpha:0.05];
      }
      _bgLayer.backgroundColor = restingFill.CGColor;
    }
  }

  [CATransaction commit];
}

- (void)animateBackingFadeInFast {
  if (!_faceLayer) {
    return;
  }
  [_faceLayer removeAnimationForKey:@"dropBackingFadeIn"];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _faceLayer.opacity = 1.0f;
  [CATransaction setDisableActions:NO];
  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @(0.0f);
  fade.toValue = @(1.0f);
  fade.duration = 0.14;
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  fade.removedOnCompletion = YES;
  [_faceLayer addAnimation:fade forKey:@"dropBackingFadeIn"];
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
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (event.clickCount == 2 &&
      !(mods & (NSEventModifierFlagShift | NSEventModifierFlagCommand))) {
    if (_onResetPin) {
      _onResetPin(_tabIndex);
    }
  } else if (_onSelect) {
    _onSelect(_tabIndex, mods);
  }
}

- (void)mouseDragged:(NSEvent*)event {
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (!_dragging && std::hypot(scr.x - _dragStartScreen.x,
                              scr.y - _dragStartScreen.y) >= 5.0) {
    _dragging = YES;
    [self animatePressState:NO];
    if (_onDragStart) {
      _onDragStart(_tabIndex, self, scr);
    }
  }
  if (_dragging && _onDragAtScreenPoint) {
    _onDragAtScreenPoint(_tabIndex, scr);
  }
}

- (void)mouseUp:(NSEvent*)event {
  if (_dragging && _onDragEnd) {
    NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
    _dragging = NO;
    _onDragEnd(_tabIndex, scr);
  } else {
    _dragging = NO;
  }
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
@property(nonatomic, assign) BOOL multiSelected;
@property(nonatomic, assign) BOOL pinned;
@property(nonatomic, copy) void (^onSelect)(int index,
                                            NSEventModifierFlags mods);
@property(nonatomic, copy) void (^onClose)(int index);
@property(nonatomic, copy) void (^onDragStart)(int index, NSView* view,
                                               NSPoint screenPt);
@property(nonatomic, copy) void (^onDragAtScreenPoint)(int index, NSPoint screenPt);
@property(nonatomic, copy) void (^onDragEnd)(int index, NSPoint screenPt);
@property(nonatomic, copy) NSMenu* (^menuProvider)(int index);

- (void)configureWithTitle:(NSString*)title
                   favicon:(NSImage*)favicon
                 isLoading:(BOOL)isLoading
                  selected:(BOOL)selected
             multiSelected:(BOOL)multiSelected
                    pinned:(BOOL)pinned
           containerSymbol:(NSString*)containerSymbol
            containerColor:(NSColor*)containerColor;
@end

@implementation LightTabRowView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _titleField;
  NSColor* __strong _containerColor;
  LightIconButton* __strong _closeButton;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  NSPoint _dragStartScreen;
  BOOL _dragging;
}

@synthesize tabIndex = _tabIndex;
@synthesize selected = _selected;
@synthesize multiSelected = _multiSelected;
@synthesize pinned = _pinned;
@synthesize onSelect = _onSelect;
@synthesize onClose = _onClose;
@synthesize onDragStart = _onDragStart;
@synthesize onDragAtScreenPoint = _onDragAtScreenPoint;
@synthesize onDragEnd = _onDragEnd;
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
    _iconView.wantsLayer = YES;
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
             multiSelected:(BOOL)multiSelected
                    pinned:(BOOL)pinned
           containerSymbol:(NSString*)containerSymbol
            containerColor:(NSColor*)containerColor {
  (void)containerSymbol;
  _selected = selected;
  _multiSelected = multiSelected;
  _pinned = pinned;
  _containerColor = containerColor;

  NSString* displayTitle = title.length > 0 ? title : @"New Tab";
  NSFont* titleFont = [NSFont
      systemFontOfSize:13.0
                weight:selected ? NSFontWeightMedium : NSFontWeightRegular];
  NSColor* titleColor =
      selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
  NSMutableParagraphStyle* titlePS = [[NSMutableParagraphStyle alloc] init];
  titlePS.lineBreakMode = NSLineBreakByTruncatingTail;
  NSMutableAttributedString* attrTitle = [[NSMutableAttributedString alloc]
      initWithString:displayTitle
          attributes:@{
            NSFontAttributeName : titleFont,
            NSForegroundColorAttributeName : titleColor,
            NSParagraphStyleAttributeName : titlePS,
          }];
  // Use native semantic vibrant colors so the separator stays subtly dimmer
  // than titleColor in both selected and unselected / out-of-focus states.
  NSColor* pipeGray =
      selected ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor;
  NSRange searchRange = NSMakeRange(0, displayTitle.length);
  while (searchRange.length > 0) {
    NSRange found = [displayTitle rangeOfString:@" | "
                                        options:0
                                          range:searchRange];
    if (found.location == NSNotFound) {
      break;
    }
    [attrTitle addAttribute:NSForegroundColorAttributeName
                      value:pipeGray
                      range:NSMakeRange(found.location + 1, 1)];
    NSUInteger nextStart = NSMaxRange(found);
    searchRange = NSMakeRange(nextStart, displayTitle.length - nextStart);
  }
  _titleField.attributedStringValue = attrTitle;

  if (isLoading) {
    _iconView.image = SymbolImage(@"arrow.trianglehead.2.clockwise", 12.0,
                                  NSFontWeightMedium);
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
  } else if (favicon) {
    _iconView.image = favicon;
    _iconView.contentTintColor = favicon.isTemplate
                                     ? (selected ? NSColor.labelColor
                                                 : NSColor.secondaryLabelColor)
                                     : nil;
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

  BOOL showClose = !_closeButton.isHidden;
  CGFloat closeSize = 20.0;
  _closeButton.frame =
      NSMakeRect(w - closeSize - 6.0, std::floor((h - closeSize) * 0.5),
                 closeSize, closeSize);

  CGFloat titleX = _containerColor ? 36.0 : 33.0;
  _iconView.frame = NSMakeRect(_containerColor ? 12.0 : 9.0,
                               std::floor((h - 16.0) * 0.5), 16.0, 16.0);
  CGFloat rightBound = showClose ? (w - closeSize - 10.0) : (w - 8.0);
  CGFloat titleRight = rightBound;
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
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _closeButton.hidden = !_selected;
  [self setNeedsLayout:YES];
}

- (void)mouseDown:(NSEvent*)event {
  _dragStartScreen = [self.window convertPointToScreen:event.locationInWindow];
  _dragging = NO;
  if (_onSelect) {
    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    _onSelect(_tabIndex, mods);
  }
}

- (void)mouseDragged:(NSEvent*)event {
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (!_dragging && std::hypot(scr.x - _dragStartScreen.x,
                              scr.y - _dragStartScreen.y) >= 5.0) {
    _dragging = YES;
    if (_onDragStart) {
      _onDragStart(_tabIndex, self, scr);
    }
  }
  if (_dragging && _onDragAtScreenPoint) {
    _onDragAtScreenPoint(_tabIndex, scr);
  }
}

- (void)mouseUp:(NSEvent*)event {
  if (_dragging && _onDragEnd) {
    NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
    _dragging = NO;
    _onDragEnd(_tabIndex, scr);
  } else {
    _dragging = NO;
  }
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
  // Unselected hover fill is rendered by LightHoverTrailController on the GPU
  // canvas strictly below row content.
  if (_selected || _multiSelected) {
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                         xRadius:9.0
                                                         yRadius:9.0];
    if (_multiSelected && !_selected) {
      [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
      [path fill];
      [[NSColor.controlAccentColor colorWithAlphaComponent:0.45] setStroke];
      path.lineWidth = 0.75;
      [path stroke];
    } else {
      if (_containerColor) {
        const bool dark = IsViewDarkAppearance(self);
        [[NSColor.labelColor colorWithAlphaComponent:(dark ? 0.10 : 0.07)] setFill];
        [path fill];
        [NSGraphicsContext saveGraphicsState];
        [path addClip];
        NSColor* c = [_containerColor
                         colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
                         ?: _containerColor;
        NSColor* leftCol = [c colorWithAlphaComponent:(dark ? 0.23 : 0.18)];
        NSColor* midCol = [c colorWithAlphaComponent:(dark ? 0.11 : 0.08)];
        NSColor* tailCol = [c colorWithAlphaComponent:(dark ? 0.025 : 0.015)];
        NSColor* rightCol = [c colorWithAlphaComponent:0.0];
        const CGFloat locs[4] = {0.0, 0.42, 0.82, 1.0};
        NSGradient* grad = [[NSGradient alloc]
            initWithColors:@[ leftCol, midCol, tailCol, rightCol ]
               atLocations:locs
                colorSpace:NSColorSpace.sRGBColorSpace];
        [grad drawInRect:self.bounds angle:0.0];
        [NSGraphicsContext restoreGraphicsState];
      } else {
        [[NSColor.labelColor colorWithAlphaComponent:0.16] setFill];
        [path fill];
      }
      if (_multiSelected) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.55] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
      }
    }
  }
  if (_containerColor) {
    NSRect barRect = NSMakeRect(3.0, 7.0, 2.5,
                                std::max<CGFloat>(4.0, self.bounds.size.height - 14.0));
    NSBezierPath* bar = [NSBezierPath bezierPathWithRoundedRect:barRect
                                                        xRadius:1.25
                                                        yRadius:1.25];
    [_containerColor setFill];
    [bar fill];
  }
}

@end

// -----------------------------------------------------------------------------
// Compact inline "+" button placed directly underneath all tabs in the sidebar.
// Left-click opens a new tab; right-click opens the Tab Containers menu.
// -----------------------------------------------------------------------------
@interface LightInlinePlusButtonView : NSView
@property(nonatomic, copy) void (^actionBlock)(void);
@property(nonatomic, copy) NSMenu* (^menuProvider)(void);
@end

@implementation LightInlinePlusButtonView {
  NSImageView* __strong _plusIcon;
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
    self.toolTip = @"New Tab (Right-click for Containers)";
    _plusIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _plusIcon.image = SymbolImage(@"plus", 13.0, NSFontWeightMedium);
    _plusIcon.contentTintColor = NSColor.secondaryLabelColor;
    _plusIcon.imageScaling = NSImageScaleNone;
    _plusIcon.imageAlignment = NSImageAlignCenter;
    [self addSubview:_plusIcon];
  }
  return self;
}

- (void)layout {
  [super layout];
  _plusIcon.frame = self.bounds;
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
  _plusIcon.contentTintColor = NSColor.labelColor;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _pressed = NO;
  _plusIcon.contentTintColor = NSColor.secondaryLabelColor;
  [self setNeedsDisplay:YES];
}

- (NSView*)hitTest:(NSPoint)point {
  NSPoint local = [self convertPoint:point fromView:self.superview];
  return NSPointInRect(local, self.bounds) ? self : nil;
}

- (void)mouseDown:(NSEvent*)event {
  if ((event.modifierFlags & NSEventModifierFlagControl) != 0) {
    [self rightMouseDown:event];
    return;
  }
  _pressed = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
  if (!_pressed) {
    return;
  }
  BOOL inside = NSPointInRect(
      [self convertPoint:event.locationInWindow fromView:nil], self.bounds);
  _pressed = NO;
  [self setNeedsDisplay:YES];
  if (inside && _actionBlock) {
    _actionBlock();
  }
}

- (void)rightMouseDown:(NSEvent*)event {
  _pressed = NO;
  [self setNeedsDisplay:YES];
  NSMenu* menu = _menuProvider ? _menuProvider() : nil;
  if (menu) {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    [menu popUpMenuPositioningItem:nil atLocation:local inView:self];
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider() : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
  CGFloat alpha = _pressed ? 0.19 : (_hovered ? 0.13 : 0.065);
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:9.0
                                                       yRadius:9.0];
  [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Spotlight / Raycast-style centered Liquid Glass Command/URL Panel (Cmd+T)
// -----------------------------------------------------------------------------
@interface LightSpotlightOverlayPanel : NSPanel
@property(nonatomic, copy) void (^onDismiss)(void);
@end

@implementation LightSpotlightOverlayPanel
@synthesize onDismiss = _onDismiss;

- (BOOL)canBecomeKeyWindow {
  return YES;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

- (void)resignKeyWindow {
  [super resignKeyWindow];
  if (self.isVisible && _onDismiss) {
    _onDismiss();
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
@property(nonatomic, assign) BOOL securityIconInteractive;
@property(nonatomic, copy) void (^onActivate)(void);
@property(nonatomic, copy) void (^onSecurityIconClick)(void);
@property(nonatomic, copy) void (^onHoverChanged)(BOOL hovered);
@end

@implementation LightAddressContainerView {
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _securityHovered;
}

@synthesize focused = _focused;
@synthesize hovered = _hovered;
@synthesize securityIconInteractive = _securityIconInteractive;
@synthesize onActivate = _onActivate;
@synthesize onSecurityIconClick = _onSecurityIconClick;
@synthesize onHoverChanged = _onHoverChanged;

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (NSRect)securityHitRect {
  return NSMakeRect(2.0, 2.0, 24.0, std::max<CGFloat>(0.0, self.bounds.size.height - 4.0));
}

- (void)resetCursorRects {
  [super resetCursorRects];
  if (_securityIconInteractive) {
    NSRect secRect = [self securityHitRect];
    [self addCursorRect:secRect cursor:NSCursor.pointingHandCursor];
    NSRect rest = NSMakeRect(NSMaxX(secRect), 0.0,
                             std::max<CGFloat>(0.0, self.bounds.size.width - NSMaxX(secRect)),
                             self.bounds.size.height);
    [self addCursorRect:rest cursor:NSCursor.IBeamCursor];
  } else {
    [self addCursorRect:self.bounds cursor:NSCursor.IBeamCursor];
  }
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingActiveAlways | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  _securityHovered = _securityIconInteractive && NSPointInRect(local, [self securityHitRect]);
  [self setNeedsDisplay:YES];
  if (_onHoverChanged) {
    _onHoverChanged(YES);
  }
}

- (void)mouseMoved:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  BOOL sec = _securityIconInteractive && NSPointInRect(local, [self securityHitRect]);
  if (sec != _securityHovered) {
    _securityHovered = sec;
    [self setNeedsDisplay:YES];
  }
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _securityHovered = NO;
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
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if (_securityIconInteractive && _onSecurityIconClick &&
      NSPointInRect(local, [self securityHitRect])) {
    _onSecurityIconClick();
    return;
  }
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
  // Hover drift highlight is rendered on the GPU canvas behind this pill by
  // LightHoverTrailController; keep base fill/stroke steady here.
  [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
  [path fill];

  [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke];
  path.lineWidth = 0.5;
  [path stroke];

  if (_securityHovered) {
    NSRect secBg = NSInsetRect([self securityHitRect], 1.5, 3.0);
    NSBezierPath* sp = [NSBezierPath bezierPathWithRoundedRect:secBg
                                                       xRadius:6.0
                                                       yRadius:6.0];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [sp fill];
  }
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
@property(nonatomic, copy) NSString* faviconCacheKey;
@property(nonatomic, copy) NSString* faviconHostKey;
@property(nonatomic, strong) NSImage* favicon;
@property(nonatomic, assign) int matchIndex;
@property(nonatomic, assign) BOOL accentIcon;
@property(nonatomic, assign) BOOL isInlineTopCandidate;
@property(nonatomic, assign) BOOL isSearchQuery;
@end

@implementation LightSuggestionItem
@synthesize primaryText = _primaryText;
@synthesize secondaryText = _secondaryText;
@synthesize fillIntoEdit = _fillIntoEdit;
@synthesize symbolName = _symbolName;
@synthesize directUrlSpec = _directUrlSpec;
@synthesize faviconCacheKey = _faviconCacheKey;
@synthesize faviconHostKey = _faviconHostKey;
@synthesize favicon = _favicon;
@synthesize matchIndex = _matchIndex;
@synthesize accentIcon = _accentIcon;
@synthesize isInlineTopCandidate = _isInlineTopCandidate;
@synthesize isSearchQuery = _isSearchQuery;
@end

@interface LightSuggestionRowView : NSView
@property(nonatomic, assign) NSInteger rowIndex;
@property(nonatomic, assign) BOOL keyboardSelected;
@property(nonatomic, assign) BOOL useHoverTrail;
@property(nonatomic, copy) NSString* faviconCacheKey;
@property(nonatomic, copy) void (^onClick)(NSInteger rowIndex);
- (void)configureWithItem:(LightSuggestionItem*)item
                 selected:(BOOL)selected;
- (void)updateFavicon:(NSImage*)favicon;
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
@synthesize useHoverTrail = _useHoverTrail;
@synthesize faviconCacheKey = _faviconCacheKey;
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
    _iconView.wantsLayer = YES;
    _iconView.layer.cornerRadius = 3.0;
    _iconView.layer.masksToBounds = YES;
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

- (void)updateFavicon:(NSImage*)favicon {
  if (!favicon) {
    return;
  }
  _iconView.image = favicon;
  _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  _iconView.contentTintColor = favicon.isTemplate ? NSColor.labelColor : nil;
  _iconView.layer.cornerRadius = 3.0;
  [_iconView setNeedsDisplay:YES];
  [self setNeedsDisplay:YES];
}

- (void)configureWithItem:(LightSuggestionItem*)item selected:(BOOL)selected {
  _keyboardSelected = selected;
  _faviconCacheKey = item.faviconCacheKey;
  if (item.favicon) {
    [self updateFavicon:item.favicon];
  } else {
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    _iconView.layer.cornerRadius = 0.0;
    _iconView.image =
        SymbolImage(item.symbolName ?: @"magnifyingglass", 12.5,
                    NSFontWeightMedium);
    _iconView.contentTintColor =
        selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
  }
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
  BOOL drawHover = _hovered && !_useHoverTrail;
  if (!_keyboardSelected && !drawHover) {
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
- (void)setHoldProgress:(CGFloat)progress holding:(BOOL)holding;
@end

@implementation LightConfirmQuitPillView {
  CALayer* __strong _progressLayer;
  NSImageView* __strong _redXIcon;
  NSTextField* __strong _confirmLabel;
  NSTrackingArea* __strong _trackingArea;
  BOOL _expanded;
  BOOL _hovered;
  BOOL _holding;
  CGFloat _holdProgress;
  NSUInteger _progressAnimGen;
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

    _progressLayer = [CALayer layer];
    _progressLayer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.30 blue:0.25 alpha:0.46].CGColor;
    _progressLayer.anchorPoint = CGPointMake(0.0, 0.0);
    _progressLayer.position = CGPointZero;
    _progressLayer.bounds = CGRectZero;
    _progressLayer.hidden = YES;
    [self.layer addSublayer:_progressLayer];

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
  if (!expanded) {
    _holding = NO;
    _holdProgress = 0.0;
    _progressAnimGen += 1;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_progressLayer removeAnimationForKey:@"progressRetreat"];
    _progressLayer.hidden = YES;
    _progressLayer.position = CGPointZero;
    _progressLayer.bounds = CGRectZero;
    [CATransaction commit];
  }
  _redXIcon.hidden = !expanded;
  _confirmLabel.hidden = !expanded;
  [self updatePillAppearance];
}

- (void)setHoldProgress:(CGFloat)progress holding:(BOOL)holding {
  CGFloat clamped = std::clamp<CGFloat>(progress, 0.0, 1.0);
  BOOL holdingChanged = (_holding != holding);
  _holding = holding;
  _holdProgress = clamped;

  if (holdingChanged) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:holding ? 0.09 : 0.14];
    [self updatePillAppearance];
    [CATransaction commit];
  }

  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  if (!holding && clamped <= 0.001) {
    CALayer* pres = _progressLayer.presentationLayer ?: _progressLayer;
    CGFloat fromW = pres.bounds.size.width;
    NSUInteger gen = ++_progressAnimGen;
    if (_expanded && !_progressLayer.isHidden && fromW > 0.5) {
      __weak __typeof(self) weakSelf = self;
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [CATransaction setCompletionBlock:^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_progressAnimGen == gen && !s->_holding &&
            s->_holdProgress <= 0.001) {
          [CATransaction begin];
          [CATransaction setDisableActions:YES];
          s->_progressLayer.hidden = YES;
          [CATransaction commit];
        }
      }];
      [_progressLayer removeAnimationForKey:@"progressRetreat"];
      _progressLayer.hidden = NO;
      _progressLayer.position = CGPointZero;
      CGRect fromBounds = CGRectMake(0.0, 0.0, fromW, h);
      CGRect toBounds = CGRectMake(0.0, 0.0, 0.0, h);
      _progressLayer.bounds = toBounds;

      CABasicAnimation* retreat =
          [CABasicAnimation animationWithKeyPath:@"bounds"];
      retreat.fromValue = [NSValue valueWithRect:NSRectFromCGRect(fromBounds)];
      retreat.toValue = [NSValue valueWithRect:NSRectFromCGRect(toBounds)];
      retreat.duration = 0.13;
      retreat.timingFunction = [CAMediaTimingFunction
          functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      retreat.removedOnCompletion = YES;
      [_progressLayer addAnimation:retreat forKey:@"progressRetreat"];
      [CATransaction commit];
    } else {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [_progressLayer removeAnimationForKey:@"progressRetreat"];
      _progressLayer.hidden = YES;
      _progressLayer.position = CGPointZero;
      _progressLayer.bounds = CGRectMake(0.0, 0.0, 0.0, h);
      [CATransaction commit];
    }
    return;
  }

  _progressAnimGen += 1;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [_progressLayer removeAnimationForKey:@"progressRetreat"];
  _progressLayer.hidden = (!_expanded || clamped <= 0.001);
  _progressLayer.position = CGPointZero;
  _progressLayer.bounds = CGRectMake(0.0, 0.0, w * clamped, h);
  [CATransaction commit];
}

- (void)updatePillAppearance {
  if (!_expanded) {
    self.layer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.373 blue:0.341 alpha:1.0]
            .CGColor;
    self.layer.borderWidth = 0.0;
    self.layer.cornerRadius = 7.0;
  } else {
    CGFloat bgAlpha = _holding ? 0.42 : (_hovered ? 0.36 : 0.30);
    CGFloat borderAlpha = _holding ? 0.98 : 0.90;
    self.layer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.25 blue:0.21 alpha:bgAlpha]
            .CGColor;
    self.layer.borderColor =
        [NSColor colorWithSRGBRed:1.0 green:0.30 blue:0.26 alpha:borderAlpha]
            .CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.cornerRadius = self.bounds.size.height * 0.5;
    _confirmLabel.textColor =
        [NSColor colorWithSRGBRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    _redXIcon.contentTintColor =
        [NSColor colorWithSRGBRed:1.0 green:0.25 blue:0.21 alpha:1.0];
  }
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  CGFloat w = self.bounds.size.width;
  _redXIcon.frame = NSMakeRect(6.0, std::floor((h - 11.0) * 0.5), 11.0, 11.0);
  NSSize fit = [_confirmLabel sizeThatFits:NSMakeSize(100.0, h)];
  _confirmLabel.frame =
      NSMakeRect(19.0, std::floor((h - fit.height) * 0.5),
                 std::ceil(fit.width), std::ceil(fit.height));
  if (_expanded) {
    self.layer.cornerRadius = h * 0.5;
    if (!_progressLayer.isHidden && (_holding || _holdProgress > 0.001)) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      _progressLayer.position = CGPointZero;
      _progressLayer.bounds = CGRectMake(0.0, 0.0, w * _holdProgress, h);
      [CATransaction commit];
    }
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
@property(nonatomic, readonly) BOOL qWasReleasedSincePresent;
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
  NSTimer* __strong _confirmHoldTimer;
  CFTimeInterval _holdStartTime;
  NSUInteger _confirmGen;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _isConfirmingQuit;
  BOOL _qWasReleasedSincePresent;
}

@synthesize isConfirmingQuit = _isConfirmingQuit;
@synthesize qWasReleasedSincePresent = _qWasReleasedSincePresent;
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
  [_confirmHoldTimer invalidate];
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
  [_confirmHoldTimer invalidate];
  _confirmHoldTimer = nil;

  NSUInteger gen = ++_confirmGen;
  _isConfirmingQuit = YES;
  _qWasReleasedSincePresent = NO;
  _holdStartTime = CACurrentMediaTime();
  if (_onConfirmStateChanged) {
    _onConfirmStateChanged(YES);
  }

  // Collapsed dot (matching red close button) -> Expanded pill (+smidge outward
  // in all directions and growing right over min/max).
  const NSRect startRect = NSMakeRect(4.0, 5.0, 14.0, 14.0);
  const NSRect endRect = NSMakeRect(1.5, 2.5, 76.0, 19.0);

  _confirmPill.frame = startRect;
  [_confirmPill setExpandedVisuals:YES];
  [_confirmPill setHoldProgress:0.0 holding:NO];
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

  // Track continuous Cmd+Q hold at 60fps: immediately brighten background and
  // sweep a left-to-right progress fill across the pill until quit threshold.
  constexpr CFTimeInterval kHoldQuitDuration = 0.70;
  constexpr unsigned short kVK_ANSI_Q = 12;
  __weak __typeof(self) weakSelf = self;
  _confirmHoldTimer = [NSTimer
      scheduledTimerWithTimeInterval:(1.0 / 60.0)
                             repeats:YES
                               block:^(NSTimer* t) {
                                 __strong __typeof(weakSelf) s = weakSelf;
                                 if (!s || !s->_isConfirmingQuit ||
                                     s->_confirmGen != gen) {
                                   [t invalidate];
                                   return;
                                 }
                                 BOOL qDown = CGEventSourceKeyState(
                                     kCGEventSourceStateCombinedSessionState,
                                     kVK_ANSI_Q);
                                 BOOL cmdDown =
                                     (NSEvent.modifierFlags &
                                      NSEventModifierFlagCommand) != 0;
                                 if (qDown && cmdDown &&
                                     !s->_qWasReleasedSincePresent) {
                                   CFTimeInterval elapsed =
                                       CACurrentMediaTime() - s->_holdStartTime;
                                   CGFloat p = std::clamp<CGFloat>(
                                       elapsed / kHoldQuitDuration, 0.0, 1.0);
                                   [s->_confirmPill setHoldProgress:p
                                                            holding:YES];
                                   if (p >= 1.0) {
                                     [t invalidate];
                                     s->_confirmHoldTimer = nil;
                                     if (s.onConfirmQuitAccepted) {
                                       s.onConfirmQuitAccepted();
                                     }
                                   }
                                 } else {
                                   if (!qDown) {
                                     s->_qWasReleasedSincePresent = YES;
                                   }
                                   [s->_confirmPill setHoldProgress:0.0
                                                            holding:NO];
                                   [t invalidate];
                                   s->_confirmHoldTimer = nil;
                                 }
                               }];

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
  [_confirmHoldTimer invalidate];
  _confirmHoldTimer = nil;
  if (!_isConfirmingQuit) {
    return;
  }
  NSUInteger gen = ++_confirmGen;
  _isConfirmingQuit = NO;
  _qWasReleasedSincePresent = NO;
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
@interface LightSidebarResizeHandleView : NSView
@property(nonatomic, copy) void (^onDragWidthDelta)(CGFloat screenX, BOOL started, BOOL ended);
@end

@implementation LightSidebarResizeHandleView {
  BOOL _dragging;
  BOOL _hovered;
  NSTrackingArea* __strong _trackingArea;
}
@synthesize onDragWidthDelta = _onDragWidthDelta;

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];
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
  _dragging = YES;
  [NSCursor.resizeLeftRightCursor push];
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (_onDragWidthDelta) {
    _onDragWidthDelta(scr.x, YES, NO);
  }
}

- (void)mouseDragged:(NSEvent*)event {
  if (!_dragging) {
    return;
  }
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (_onDragWidthDelta) {
    _onDragWidthDelta(scr.x, NO, NO);
  }
}

- (void)mouseUp:(NSEvent*)event {
  if (!_dragging) {
    return;
  }
  _dragging = NO;
  [NSCursor pop];
  NSPoint scr = [self.window convertPointToScreen:event.locationInWindow];
  if (_onDragWidthDelta) {
    _onDragWidthDelta(scr.x, NO, YES);
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  // Invisible handle — cursor changes to resizeLeftRightCursor on hover/drag.
}
@end

@interface LightSidebarPassthroughView : NSView
@property(nonatomic, strong) NSView* glassPanel;
@property(nonatomic, weak) NSView* sidebarContentView;
@property(nonatomic, strong) NSView* expandedUrlPanel;
@property(nonatomic, strong) NSView* findBarPanel;
@property(nonatomic, strong) NSView* resizeHandleView;
@property(nonatomic, assign) BOOL sidebarInteractive;
@property(nonatomic, assign) CGFloat appFramePadding;
@property(nonatomic, copy) void (^onLayoutBlock)(void);
@property(nonatomic, copy) void (^onHoverLeftEdge)(void);
- (void)invalidateEdgeTrackingArea;
@end

@implementation LightSidebarPassthroughView {
  NSTrackingArea* __strong _edgeTrackingArea;
  NSRect _lastTrackedEdgeRect;
}

@synthesize glassPanel = _glassPanel;
@synthesize sidebarContentView = _sidebarContentView;
@synthesize expandedUrlPanel = _expandedUrlPanel;
@synthesize findBarPanel = _findBarPanel;
@synthesize resizeHandleView = _resizeHandleView;
@synthesize sidebarInteractive = _sidebarInteractive;
@synthesize appFramePadding = _appFramePadding;
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
  CGFloat trigW = kDefaultHoverEdgeTriggerWidth;
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

- (BOOL)isPointInDraggableFrameBorder:(NSPoint)local {
  if (_appFramePadding <= 1.0) {
    return NO;
  }
  NSRect b = self.bounds;
  // Leave the outer 4pt edge to macOS native window resize handles, while the
  // inner translucent frame padding drags the window cleanly.
  const CGFloat pad = _appFramePadding;
  const BOOL inTop = local.y >= (NSMaxY(b) - pad) && local.y <= (NSMaxY(b) - 3.0);
  const BOOL inBottom = local.y >= 3.0 && local.y <= pad;
  const BOOL inRight = local.x >= (NSMaxX(b) - pad) && local.x <= (NSMaxX(b) - 3.0);
  const BOOL inLeft = local.x >= 3.0 && local.x <= pad;
  return inTop || inBottom || inRight || inLeft;
}

- (void)mouseDown:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if ([self isPointInDraggableFrameBorder:local] && self.window &&
      (self.window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
    [self.window performWindowDragWithEvent:event];
    return;
  }
  [super mouseDown:event];
}

- (NSView*)hitTest:(NSPoint)point {
  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (_findBarPanel && !_findBarPanel.isHidden &&
      NSPointInRect(local, _findBarPanel.frame)) {
    NSView* hit = [super hitTest:point];
    return hit == self ? nil : hit;
  }
  if (_resizeHandleView && !_resizeHandleView.isHidden &&
      NSPointInRect(local, _resizeHandleView.frame)) {
    return _resizeHandleView;
  }
  NSView* activeSidebar =
      (_glassPanel && !_glassPanel.isHidden)
          ? _glassPanel
          : ((_sidebarContentView && !_sidebarContentView.isHidden)
                 ? _sidebarContentView
                 : nil);
  if (_sidebarInteractive && activeSidebar) {
    BOOL inSidebar = NSPointInRect(local, activeSidebar.frame);
    BOOL inExpandedUrl = _expandedUrlPanel && !_expandedUrlPanel.isHidden &&
                         NSPointInRect(local, _expandedUrlPanel.frame);
    if (inSidebar || inExpandedUrl) {
      NSView* hit = [super hitTest:point];
      return hit == self ? nil : hit;
    }
  }
  if ([self isPointInDraggableFrameBorder:local]) {
    return self;
  }
  return nil;
}

@end

// -----------------------------------------------------------------------------
// GPU Hover Trail ("Drift") Effect — exact mechanics:
//   * Instant ON (0ms), 70ms linear fade-out on CALayer opacity (1 -> 0)
//   * 18pt / 48-step pointer path interpolation on mouseMoved
//   * Selected-row exclusion & 3pt arming slop
//   * Immediate (animate:NO) cancellation on scroll, click, key, resignKey
//   * Non-hit-testing canvas mounted strictly below rows in scroll documentView
// -----------------------------------------------------------------------------
@interface LightHoverTrailCanvasView : NSView
@end

@implementation LightHoverTrailCanvasView
- (BOOL)isFlipped {
  return YES;
}
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
@end

@interface LightHoverTrailController : NSObject
@property(nonatomic, assign) CGFloat cornerRadius;
@property(nonatomic, assign) CGFloat hoverAlpha;
@property(nonatomic, copy) NSArray<NSView*>* (^rowsProvider)(void);
@property(nonatomic, copy) BOOL (^isRowSelected)(NSView* row);
- (instancetype)initWithScrollView:(NSScrollView*)scrollView
                      documentView:(NSView*)documentView;
- (instancetype)initWithContainerView:(NSView*)containerView;
- (void)syncCanvasBounds;
- (void)handleMouseMovedInWindow:(NSPoint)winPt;
- (void)cancelPillForRow:(NSView*)row;
- (void)cancelAllAnimated:(BOOL)animated;
- (void)teardown;
@end

@implementation LightHoverTrailController {
  NSScrollView* __weak _scrollView;
  NSView* __weak _documentView;
  LightHoverTrailCanvasView* __strong _canvas;
  NSMapTable<NSView*, CALayer*>* __strong _activePills;
  NSView* __weak _hoveredRow;
  BOOL _hasLastPointer;
  NSPoint _lastDocPoint;
  BOOL _armed;
  BOOL _hasArmOrigin;
  NSPoint _armOrigin;
}

@synthesize cornerRadius = _cornerRadius;
@synthesize hoverAlpha = _hoverAlpha;
@synthesize rowsProvider = _rowsProvider;
@synthesize isRowSelected = _isRowSelected;

- (instancetype)initWithScrollView:(NSScrollView*)scrollView
                      documentView:(NSView*)documentView {
  if ((self = [super init])) {
    _scrollView = scrollView;
    _documentView = documentView;
    _cornerRadius = 9.0;
    _hoverAlpha = 0.08;
    _activePills = [NSMapTable weakToStrongObjectsMapTable];

    _canvas = [[LightHoverTrailCanvasView alloc] initWithFrame:documentView.bounds];
    _canvas.wantsLayer = YES;
    _canvas.layer.masksToBounds = YES;
    _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [documentView addSubview:_canvas positioned:NSWindowBelow relativeTo:nil];

    scrollView.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(clipBoundsDidChange:)
               name:NSViewBoundsDidChangeNotification
             object:scrollView.contentView];
  }
  return self;
}

- (instancetype)initWithContainerView:(NSView*)containerView {
  if ((self = [super init])) {
    _scrollView = nil;
    _documentView = containerView;
    _cornerRadius = 9.0;
    _hoverAlpha = 0.08;
    _activePills = [NSMapTable weakToStrongObjectsMapTable];

    _canvas = [[LightHoverTrailCanvasView alloc] initWithFrame:containerView.bounds];
    _canvas.wantsLayer = YES;
    _canvas.layer.masksToBounds = YES;
    _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [containerView addSubview:_canvas positioned:NSWindowBelow relativeTo:nil];
  }
  return self;
}

- (void)teardown {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self cancelAllAnimated:NO];
  [_canvas removeFromSuperview];
  _canvas = nil;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)clipBoundsDidChange:(NSNotification*)note {
  [self cancelAllAnimated:NO];
}

- (void)syncCanvasBounds {
  NSView* doc = _documentView;
  if (!doc || !_canvas) {
    return;
  }
  _canvas.frame = doc.bounds;
  // Keep canvas strictly below all row subviews (and above tab group cards if
  // any, or behind rows). Re-ordering behind the first non-canvas view ensures
  // rows always draw on top.
  if (doc.subviews.firstObject != _canvas) {
    [_canvas removeFromSuperview];
    [doc addSubview:_canvas positioned:NSWindowBelow relativeTo:nil];
  }
}

- (CGColorRef)currentHoverCGColor {
  return [NSColor.labelColor colorWithAlphaComponent:_hoverAlpha].CGColor;
}

- (CALayer*)ensureActivePillForRow:(NSView*)row {
  if (!row || !_canvas.layer) {
    return nil;
  }
  CALayer* pill = [_activePills objectForKey:row];
  if (!pill) {
    pill = [CALayer layer];
    pill.cornerRadius = _cornerRadius;
    pill.cornerCurve = kCACornerCurveContinuous;
    [_canvas.layer addSublayer:pill];
    [_activePills setObject:pill forKey:row];
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [pill removeAnimationForKey:@"hoverTrailFade"];
  pill.frame = row.frame;
  pill.cornerRadius = _cornerRadius;
  pill.backgroundColor = [self currentHoverCGColor];
  pill.opacity = 1.0f;
  [CATransaction commit];
  return pill;
}

- (void)startFadeOutForRow:(NSView*)row {
  if (!row) {
    return;
  }
  CALayer* pill = [_activePills objectForKey:row];
  if (!pill) {
    return;
  }
  float fromOpacity = 1.0f;
  if (CALayer* pres = pill.presentationLayer) {
    fromOpacity = pres.opacity;
  } else {
    fromOpacity = pill.opacity;
  }
  [pill removeAnimationForKey:@"hoverTrailFade"];

  __weak __typeof(self) weakSelf = self;
  __weak NSView* weakRow = row;
  [CATransaction begin];
  [CATransaction setCompletionBlock:^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    if (pill.opacity <= 0.001f && ![pill animationForKey:@"hoverTrailFade"]) {
      [pill removeFromSuperlayer];
      NSView* r = weakRow;
      if (r && [s->_activePills objectForKey:r] == pill) {
        [s->_activePills removeObjectForKey:r];
      }
    }
  }];
  [CATransaction setDisableActions:YES];
  pill.opacity = 0.0f;
  [CATransaction setDisableActions:NO];

  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @(fromOpacity);
  fade.toValue = @(0.0f);
  fade.duration = 0.070;  // Exact 70ms linear fade-out
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  fade.removedOnCompletion = YES;
  [pill addAnimation:fade forKey:@"hoverTrailFade"];
  [CATransaction commit];
}

- (void)cancelPillForRow:(NSView*)row {
  if (!row) {
    return;
  }
  if (_hoveredRow == row) {
    _hoveredRow = nil;
  }
  CALayer* pill = [_activePills objectForKey:row];
  if (pill) {
    [pill removeAllAnimations];
    [pill removeFromSuperlayer];
    [_activePills removeObjectForKey:row];
  }
}

- (void)cancelAllAnimated:(BOOL)animated {
  if (animated && _hoveredRow) {
    NSView* prev = _hoveredRow;
    _hoveredRow = nil;
    [self startFadeOutForRow:prev];
  } else {
    _hoveredRow = nil;
    for (CALayer* sub in [_canvas.layer.sublayers copy]) {
      [sub removeAllAnimations];
      [sub removeFromSuperlayer];
    }
    [_activePills removeAllObjects];
  }
  _hasLastPointer = NO;
  _armed = NO;
  _hasArmOrigin = NO;
}

- (NSView*)hitRowAtDocPoint:(NSPoint)docPt rows:(NSArray<NSView*>*)rows {
  for (NSView* row in rows) {
    if (row.isHidden || row.alphaValue < 0.05) {
      continue;
    }
    if (_isRowSelected && _isRowSelected(row)) {
      continue;
    }
    if (NSPointInRect(docPt, row.frame)) {
      return row;
    }
  }
  return nil;
}

- (void)handleMouseMovedInWindow:(NSPoint)winPt {
  NSScrollView* sv = _scrollView;
  NSView* doc = _documentView;
  if (!doc || !doc.window) {
    return;
  }
  if (sv) {
    if (sv.isHidden) {
      return;
    }
    NSPoint clipPt = [sv.contentView convertPoint:winPt fromView:nil];
    if (!NSPointInRect(clipPt, sv.contentView.bounds)) {
      if (_hoveredRow || _hasLastPointer) {
        [self cancelAllAnimated:YES];
      }
      return;
    }
  } else {
    if (doc.isHidden) {
      return;
    }
    NSPoint localPt = [doc convertPoint:winPt fromView:nil];
    if (!NSPointInRect(localPt, doc.bounds)) {
      if (_hoveredRow || _hasLastPointer) {
        [self cancelAllAnimated:YES];
      }
      return;
    }
  }
  NSPoint docPt = [doc convertPoint:winPt fromView:nil];

  // 3pt hover arming slop so layout shifts / appearance don't falsely arm hover.
  if (!_armed) {
    if (!_hasArmOrigin) {
      _armOrigin = docPt;
      _hasArmOrigin = YES;
      return;
    }
    if (std::hypot(docPt.x - _armOrigin.x, docPt.y - _armOrigin.y) < 3.0) {
      return;
    }
    _armed = YES;
  }

  NSArray<NSView*>* rows = _rowsProvider ? _rowsProvider() : @[];
  NSMutableArray<NSView*>* visited = [NSMutableArray array];

  if (!_hasLastPointer) {
    NSView* hit = [self hitRowAtDocPoint:docPt rows:rows];
    if (hit) {
      [visited addObject:hit];
    }
  } else {
    CGFloat dx = docPt.x - _lastDocPoint.x;
    CGFloat dy = docPt.y - _lastDocPoint.y;
    CGFloat dist = std::hypot(dx, dy);
    int steps = (dist <= 18.0) ? 1 : std::min<int>(48, static_cast<int>(std::ceil(dist / 18.0)));
    NSView* lastSeen = nil;
    for (int i = 1; i <= steps; ++i) {
      CGFloat t = static_cast<CGFloat>(i) / static_cast<CGFloat>(steps);
      NSPoint sample = NSMakePoint(_lastDocPoint.x + dx * t,
                                   _lastDocPoint.y + dy * t);
      NSView* hit = [self hitRowAtDocPoint:sample rows:rows];
      if (hit && hit != lastSeen) {
        [visited addObject:hit];
        lastSeen = hit;
      }
    }
  }
  _lastDocPoint = docPt;
  _hasLastPointer = YES;

  NSView* finalTarget = [self hitRowAtDocPoint:docPt rows:rows];
  NSView* prevHovered = _hoveredRow;

  if (prevHovered && prevHovered != finalTarget) {
    [self startFadeOutForRow:prevHovered];
  }

  // Intermediate rows crossed in this fast move flash ON (1.0) and immediately
  // begin their 70ms linear fade-out.
  for (NSView* r in visited) {
    if (r == finalTarget || r == prevHovered) {
      continue;
    }
    [self ensureActivePillForRow:r];
    [self startFadeOutForRow:r];
  }

  if (finalTarget) {
    [self ensureActivePillForRow:finalTarget];
    _hoveredRow = finalTarget;
  } else {
    _hoveredRow = nil;
  }
}

@end

// -----------------------------------------------------------------------------
// Pinned-tile Extensions popover panel & Cert/Site Info Liquid Glass panel.
// -----------------------------------------------------------------------------
@interface LightExtensionTileView : NSView
@property(nonatomic, copy) NSString* extensionId;
@property(nonatomic, copy) void (^onLeftClick)(NSString* extId);
@property(nonatomic, copy) NSMenu* (^menuProvider)(NSString* extId);
- (void)configureWithId:(NSString*)extId
                   name:(NSString*)name
                   icon:(NSImage*)icon;
@end

@implementation LightExtensionTileView {
  NSImageView* __strong _iconView;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _pressed;
}
@synthesize extensionId = _extensionId;
@synthesize onLeftClick = _onLeftClick;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.wantsLayer = YES;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];
  }
  return self;
}

- (void)configureWithId:(NSString*)extId
                   name:(NSString*)name
                   icon:(NSImage*)icon {
  _extensionId = [extId copy];
  self.toolTip = name ?: @"Extension";
  if (icon) {
    _iconView.image = icon;
    _iconView.contentTintColor = nil;
  } else {
    _iconView.image = SymbolImage(@"puzzlepiece.extension", 16.0, NSFontWeightMedium);
    _iconView.contentTintColor = NSColor.labelColor;
  }
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  NSRect b = self.bounds;
  _iconView.frame = NSMakeRect(std::floor((b.size.width - 20.0) * 0.5),
                               std::floor((b.size.height - 20.0) * 0.5),
                               20.0, 20.0);
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
  BOOL wasPressed = _pressed;
  _pressed = NO;
  [self setNeedsDisplay:YES];
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if (wasPressed && NSPointInRect(local, self.bounds) && _onLeftClick) {
    _onLeftClick(_extensionId);
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider(_extensionId) : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
  // Hover drift highlight is rendered by LightHoverTrailController below tiles.
  NSRect inset = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:inset
                                                       xRadius:10.0
                                                       yRadius:10.0];
  CGFloat alpha = _pressed ? 0.22 : 0.07;
  [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
  [path fill];
}
@end

@interface LightPopoverGlassPanel : NSPanel
@property(nonatomic, copy) void (^onDismiss)(void);
@property(nonatomic, assign) BOOL suppressResignDismiss;
@end

@implementation LightPopoverGlassPanel
@synthesize onDismiss = _onDismiss;
@synthesize suppressResignDismiss = _suppressResignDismiss;

- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
- (void)cancelOperation:(id)sender {
  if (_onDismiss) {
    _onDismiss();
  }
}
- (void)keyDown:(NSEvent*)event {
  if (event.keyCode == 53 && _onDismiss) {
    _onDismiss();
    return;
  }
  [super keyDown:event];
}
- (void)resignKeyWindow {
  [super resignKeyWindow];
  if (!_suppressResignDismiss && _onDismiss) {
    _onDismiss();
  }
}
@end

// -----------------------------------------------------------------------------
// Liquid Glass Downloads popup views (anchored to right of sidebar footer).
// -----------------------------------------------------------------------------
@interface LightDownloadEntry : NSObject
@property(nonatomic, assign) uint32_t downloadId;
@property(nonatomic, copy) NSString* fileName;
@property(nonatomic, copy) NSString* fileExtension;
@property(nonatomic, copy) NSString* statusText;
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, assign) BOOL inProgress;
@property(nonatomic, assign) BOOL completed;
@property(nonatomic, assign) BOOL canOpen;
@end

@implementation LightDownloadEntry
@synthesize downloadId = _downloadId;
@synthesize fileName = _fileName;
@synthesize fileExtension = _fileExtension;
@synthesize statusText = _statusText;
@synthesize progress = _progress;
@synthesize inProgress = _inProgress;
@synthesize completed = _completed;
@synthesize canOpen = _canOpen;
@end

@interface LightDownloadsOverlayPanel : NSPanel
@property(nonatomic, copy) void (^onDismiss)(void);
@end

@implementation LightDownloadsOverlayPanel
@synthesize onDismiss = _onDismiss;

- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
- (void)cancelOperation:(id)sender {
  if (_onDismiss) {
    _onDismiss();
  }
}
- (void)keyDown:(NSEvent*)event {
  if (event.keyCode == 53 && _onDismiss) {
    _onDismiss();
    return;
  }
  [super keyDown:event];
}
- (void)resignKeyWindow {
  [super resignKeyWindow];
  if (_onDismiss) {
    _onDismiss();
  }
}
@end

@interface LightDownloadRowView : NSView
@property(nonatomic, assign) uint32_t downloadId;
@property(nonatomic, copy) void (^onOpen)(uint32_t downloadId);
@property(nonatomic, copy) void (^onShowInFinder)(uint32_t downloadId);
@property(nonatomic, copy) void (^onCancel)(uint32_t downloadId);
@property(nonatomic, copy) NSMenu* (^menuProvider)(uint32_t downloadId);
- (void)configureWithEntry:(LightDownloadEntry*)entry;
@end

@implementation LightDownloadRowView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _nameLabel;
  NSTextField* __strong _statusLabel;
  LightIconButton* __strong _finderButton;
  LightIconButton* __strong _cancelButton;
  CGFloat _progress;
  BOOL _inProgress;
  BOOL _canOpen;
}

@synthesize downloadId = _downloadId;
@synthesize onOpen = _onOpen;
@synthesize onShowInFinder = _onShowInFinder;
@synthesize onCancel = _onCancel;
@synthesize menuProvider = _menuProvider;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.wantsLayer = YES;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    _nameLabel.textColor = NSColor.labelColor;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _nameLabel.maximumNumberOfLines = 1;
    [self addSubview:_nameLabel];

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _statusLabel.maximumNumberOfLines = 1;
    [self addSubview:_statusLabel];

    __weak __typeof(self) weakSelf = self;
    _finderButton = [[LightIconButton alloc] initWithSymbol:@"folder"
                                                  pointSize:12.0
                                                     weight:NSFontWeightMedium
                                                    toolTip:@"Show in Finder"];
    _finderButton.cornerRadius = 6.0;
    _finderButton.actionBlock = ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s.onShowInFinder) {
        s.onShowInFinder(s.downloadId);
      }
    };
    [self addSubview:_finderButton];

    _cancelButton = [[LightIconButton alloc] initWithSymbol:@"xmark"
                                                  pointSize:10.5
                                                     weight:NSFontWeightSemibold
                                                    toolTip:@"Cancel Download"];
    _cancelButton.cornerRadius = 6.0;
    _cancelButton.actionBlock = ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s.onCancel) {
        s.onCancel(s.downloadId);
      }
    };
    [self addSubview:_cancelButton];
  }
  return self;
}

- (void)configureWithEntry:(LightDownloadEntry*)entry {
  _downloadId = entry.downloadId;
  _progress = entry.progress;
  _inProgress = entry.inProgress;
  _canOpen = entry.canOpen;

  _nameLabel.stringValue = entry.fileName ?: @"Download";
  _statusLabel.stringValue = entry.statusText ?: @"";

  NSImage* fileIcon = nil;
  if (entry.fileExtension.length > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    fileIcon = [NSWorkspace.sharedWorkspace iconForFileType:entry.fileExtension];
#pragma clang diagnostic pop
  }
  if (fileIcon) {
    _iconView.image = fileIcon;
    _iconView.contentTintColor = nil;
  } else {
    _iconView.image = SymbolImage(@"doc.fill", 18.0, NSFontWeightRegular);
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
  }

  _cancelButton.hidden = !_inProgress;
  _finderButton.hidden = _inProgress || !entry.completed;
  [self setNeedsLayout:YES];
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  _iconView.frame = NSMakeRect(10.0, std::floor((h - 26.0) * 0.5), 26.0, 26.0);

  CGFloat rightBound = w - 8.0;
  if (!_cancelButton.isHidden) {
    _cancelButton.frame = NSMakeRect(rightBound - 24.0, std::floor((h - 24.0) * 0.5), 24.0, 24.0);
    rightBound -= 28.0;
  }
  if (!_finderButton.isHidden) {
    _finderButton.frame = NSMakeRect(rightBound - 24.0, std::floor((h - 24.0) * 0.5), 24.0, 24.0);
    rightBound -= 28.0;
  }
  CGFloat textX = 44.0;
  CGFloat textW = std::max<CGFloat>(0.0, rightBound - textX);
  _nameLabel.frame = NSMakeRect(textX, _inProgress ? 8.0 : 10.0, textW, 16.0);
  _statusLabel.frame = NSMakeRect(textX, _inProgress ? 25.0 : 28.0, textW, 14.0);
}

- (void)mouseUp:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(local, self.bounds) && _canOpen && _onOpen) {
    _onOpen(_downloadId);
  }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  return _menuProvider ? _menuProvider(_downloadId) : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
  // Hover background is rendered by LightHoverTrailController on the GPU canvas.
  if (_inProgress) {
    CGFloat barX = 44.0;
    CGFloat barW = std::max<CGFloat>(20.0, self.bounds.size.width - 80.0);
    CGFloat barY = self.bounds.size.height - 8.0;
    NSRect trackRect = NSMakeRect(barX, barY, barW, 3.0);
    [[NSColor.labelColor colorWithAlphaComponent:0.14] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:trackRect xRadius:1.5 yRadius:1.5]
        fill];

    CGFloat fillW = barW * std::clamp<CGFloat>(_progress, 0.05, 1.0);
    NSRect fillRect = NSMakeRect(barX, barY, fillW, 3.0);
    [NSColor.controlAccentColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.5 yRadius:1.5]
        fill];
  }
}

@end

// -----------------------------------------------------------------------------
// Physical elevated frosted Liquid Glass tab drag ghost that smoothly morphs
// between a full unpinned tab row and a compact pinned tile across zones.
// -----------------------------------------------------------------------------
API_AVAILABLE(macos(26.0))
@interface LightDragGhostView : NSView
@property(nonatomic, readonly) BOOL morphedAsPinned;
@property(nonatomic, readonly) NSSize targetCardSize;
- (instancetype)initWithCardRect:(NSRect)cardRectInOverlay
                           title:(NSString*)title
                         urlSpec:(NSString*)urlSpec
                         favicon:(NSImage*)favicon
                  containerColor:(NSColor*)containerColor
                        selected:(BOOL)selected
              ephemeralContainer:(BOOL)ephemeralContainer
                        asPinned:(BOOL)asPinned;
- (void)moveCenterToOverlayPoint:(NSPoint)center;
- (void)setMorphedAsPinned:(BOOL)asPinned
                targetSize:(NSSize)size
             anchorCenter:(NSPoint)center
                  animated:(BOOL)animated;
- (void)animateLandingToOverlayRect:(NSRect)landingInOverlay
                           duration:(NSTimeInterval)duration
                         completion:(void (^)(void))completion;
@end

@implementation LightDragGhostView {
  // Fixed-size outer stage so mouse moves only call setFrameOrigin: and NEVER
  // cancel in-flight card morph, title blur-fade, or conic glow animations!
  NSView* __strong _cardView;
  NSGlassEffectView* __strong _glassView;
  // Exact resting backing (unselected pinned tile or selected unpinned row)
  // that cross-fades in as _glassView dissolves out during drop landing.
  NSView* __strong _restingBackingView;
  CALayer* __strong _restingBgLayer;
  CAGradientLayer* __strong _restingGradientLayer;
  NSView* __strong _pinnedStyleView;
  CALayer* __strong _pinClipLayer;
  CALayer* __strong _pinBgLayer;
  CALayer* __strong _pinBlurredTintLayer;
  CALayer* __strong _pinBorderRingLayer;
  CAShapeLayer* __strong _pinEphemeralBorderLayer;
  CAGradientLayer* __strong _pinConicGlowLayer;
  CAShapeLayer* __strong _pinConicGlowMaskLayer;
  NSView* __strong _contentOverlayView;
  CALayer* __strong _containerBarLayer;
  NSImageView* __strong _iconView;
  NSTextField* __strong _titleLabel;
  NSColor* __strong _containerColor;
  LightPinVisualAnalysis* __strong _analysis;
  NSSize _targetCardSize;
  NSSize _lastRingSize;
  BOOL _isSelected;
  BOOL _ephemeralContainer;
  BOOL _morphedAsPinned;
}

@synthesize morphedAsPinned = _morphedAsPinned;
@synthesize targetCardSize = _targetCardSize;

- (BOOL)isFlipped {
  return YES;
}

- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (NSRect)centeredCardRectForSize:(NSSize)sz {
  CGFloat sw = self.bounds.size.width;
  CGFloat sh = self.bounds.size.height;
  return NSMakeRect(std::round((sw - sz.width) * 0.5),
                    std::round((sh - sz.height) * 0.5), sz.width, sz.height);
}

- (instancetype)initWithCardRect:(NSRect)cardRectInOverlay
                           title:(NSString*)title
                         urlSpec:(NSString*)urlSpec
                         favicon:(NSImage*)favicon
                  containerColor:(NSColor*)containerColor
                        selected:(BOOL)selected
              ephemeralContainer:(BOOL)ephemeralContainer
                        asPinned:(BOOL)asPinned {
  constexpr CGFloat kStageW = 420.0;
  constexpr CGFloat kStageH = 110.0;
  NSPoint center = NSMakePoint(NSMidX(cardRectInOverlay),
                               NSMidY(cardRectInOverlay));
  NSRect stageRect = NSMakeRect(std::round(center.x - kStageW * 0.5),
                                std::round(center.y - kStageH * 0.5),
                                kStageW, kStageH);
  if ((self = [super initWithFrame:stageRect])) {
    _morphedAsPinned = asPinned;
    _containerColor = containerColor;
    _isSelected = selected;
    _ephemeralContainer = ephemeralContainer;
    _targetCardSize = cardRectInOverlay.size;
    _lastRingSize = NSZeroSize;
    if (favicon && !favicon.isTemplate) {
      _analysis =
          [LightPinVisualAnalysis analysisForFavicon:favicon
                                            cacheKey:(urlSpec ?: title ?: @"pin")];
    }
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;

    NSRect cardRect = [self centeredCardRectForSize:_targetCardSize];
    _cardView = [[LightFlippedDocumentView alloc] initWithFrame:cardRect];
    _cardView.autoresizesSubviews = NO;
    _cardView.wantsLayer = YES;
    _cardView.layer.masksToBounds = NO;
    _cardView.layer.shadowColor = NSColor.blackColor.CGColor;
    _cardView.layer.shadowRadius = 14.0;
    _cardView.layer.shadowOffset = CGSizeMake(0.0, 5.0);
    _cardView.layer.shadowOpacity = 0.28f;
    [self addSubview:_cardView];

    _glassView = [[NSGlassEffectView alloc] initWithFrame:_cardView.bounds];
    _glassView.wantsLayer = YES;
    _glassView.style = NSGlassEffectViewStyleRegular;
    _glassView.cornerRadius = asPinned ? 10.0 : 9.0;
    [_cardView addSubview:_glassView];

    // Exact resting backing layer (fades in smoothly during landing as
    // _glassView dissolves out so drop handoff has zero brightness snap).
    _restingBackingView =
        [[LightFlippedDocumentView alloc] initWithFrame:_cardView.bounds];
    _restingBackingView.wantsLayer = YES;
    _restingBackingView.layer.masksToBounds = NO;
    _restingBackingView.layer.opacity = 0.0f;
    [_cardView addSubview:_restingBackingView];

    _restingBgLayer = [CALayer layer];
    _restingBgLayer.masksToBounds = YES;
    _restingBgLayer.cornerCurve = kCACornerCurveContinuous;
    [_restingBackingView.layer addSublayer:_restingBgLayer];

    _restingGradientLayer = [CAGradientLayer layer];
    _restingGradientLayer.startPoint = CGPointMake(0.0, 0.5);
    _restingGradientLayer.endPoint = CGPointMake(1.0, 0.5);
    _restingGradientLayer.locations = @[ @0.0, @0.42, @0.82, @1.0 ];
    _restingGradientLayer.hidden = YES;
    [_restingBgLayer addSublayer:_restingGradientLayer];

    // Active-pinned visual backing + conic glow ring mounted ABOVE _glassView
    // and BELOW _contentOverlayView so NSGlassEffectView never clips/hides it!
    _pinnedStyleView =
        [[LightFlippedDocumentView alloc] initWithFrame:_cardView.bounds];
    _pinnedStyleView.wantsLayer = YES;
    _pinnedStyleView.layerUsesCoreImageFilters = YES;
    _pinnedStyleView.layer.masksToBounds = NO;
    _pinnedStyleView.layer.opacity = (asPinned && selected) ? 1.0f : 0.0f;
    CIFilter* pinBlur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [pinBlur setDefaults];
    pinBlur.name = @"pinStyleBlur";
    [pinBlur setValue:@((asPinned && selected) ? 0.0 : 6.0)
               forKey:@"inputRadius"];
    _pinnedStyleView.layer.filters = @[ pinBlur ];
    [_cardView addSubview:_pinnedStyleView];

    _pinClipLayer = [CALayer layer];
    _pinClipLayer.masksToBounds = YES;
    _pinClipLayer.cornerRadius = 10.0;
    _pinClipLayer.cornerCurve = kCACornerCurveContinuous;
    [_pinnedStyleView.layer addSublayer:_pinClipLayer];

    _pinBgLayer = [CALayer layer];
    [_pinClipLayer addSublayer:_pinBgLayer];

    _pinBlurredTintLayer = [CALayer layer];
    _pinBlurredTintLayer.opacity = 0.24f;
    _pinBlurredTintLayer.contentsGravity = kCAGravityResizeAspectFill;
    _pinBlurredTintLayer.masksToBounds = YES;
    [_pinClipLayer addSublayer:_pinBlurredTintLayer];

    _pinBorderRingLayer = [CALayer layer];
    _pinBorderRingLayer.cornerRadius = 10.0;
    _pinBorderRingLayer.cornerCurve = kCACornerCurveContinuous;
    [_pinnedStyleView.layer addSublayer:_pinBorderRingLayer];

    _pinEphemeralBorderLayer = [CAShapeLayer layer];
    _pinEphemeralBorderLayer.fillColor = NSColor.clearColor.CGColor;
    _pinEphemeralBorderLayer.lineWidth = 2.0;
    _pinEphemeralBorderLayer.lineCap = kCALineCapRound;
    _pinEphemeralBorderLayer.lineDashPattern = @[ @5.0, @4.0 ];
    _pinEphemeralBorderLayer.hidden = YES;
    [_pinnedStyleView.layer addSublayer:_pinEphemeralBorderLayer];

    _pinConicGlowLayer = [CAGradientLayer layer];
    _pinConicGlowLayer.type = kCAGradientLayerConic;
    _pinConicGlowLayer.startPoint = CGPointMake(0.5, 0.5);
    _pinConicGlowLayer.endPoint = CGPointMake(1.0, 0.5);
    _pinConicGlowMaskLayer = [CAShapeLayer layer];
    _pinConicGlowMaskLayer.fillColor = nil;
    _pinConicGlowMaskLayer.strokeColor = NSColor.whiteColor.CGColor;
    _pinConicGlowMaskLayer.lineWidth = 2.0;
    _pinConicGlowMaskLayer.lineCap = kCALineCapRound;
    _pinConicGlowLayer.mask = _pinConicGlowMaskLayer;
    _pinConicGlowLayer.hidden = YES;
    [_pinnedStyleView.layer addSublayer:_pinConicGlowLayer];

    // Foreground icon + title + container accent bar mounted cleanly on top.
    _contentOverlayView =
        [[LightFlippedDocumentView alloc] initWithFrame:_cardView.bounds];
    _contentOverlayView.wantsLayer = YES;
    _contentOverlayView.layer.masksToBounds = YES;
    _contentOverlayView.layer.cornerRadius = asPinned ? 10.0 : 9.0;
    _contentOverlayView.layer.cornerCurve = kCACornerCurveContinuous;
    [_cardView addSubview:_contentOverlayView];

    _containerBarLayer = [CALayer layer];
    _containerBarLayer.cornerRadius = 1.25;
    _containerBarLayer.opacity = (containerColor == nil || asPinned) ? 0.0f : 1.0f;
    if (containerColor) {
      _containerBarLayer.backgroundColor = containerColor.CGColor;
    }
    [_contentOverlayView.layer addSublayer:_containerBarLayer];

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.wantsLayer = YES;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    if (favicon) {
      _iconView.image = favicon;
      _iconView.contentTintColor = favicon.isTemplate ? NSColor.labelColor : nil;
    } else {
      _iconView.image = SymbolImage(@"globe", 13.5, NSFontWeightMedium);
      _iconView.contentTintColor = NSColor.labelColor;
    }
    [_contentOverlayView addSubview:_iconView];

    _titleLabel =
        [NSTextField labelWithString:(title.length > 0 ? title : @"New Tab")];
    _titleLabel.wantsLayer = YES;
    _titleLabel.layerUsesCoreImageFilters = YES;
    _titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    _titleLabel.textColor = NSColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.maximumNumberOfLines = 1;
    _titleLabel.layer.opacity = asPinned ? 0.0f : 1.0f;
    CIFilter* titleBlur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [titleBlur setDefaults];
    titleBlur.name = @"titleBlur";
    [titleBlur setValue:@(asPinned ? 7.5 : 0.0) forKey:@"inputRadius"];
    _titleLabel.layer.filters = @[ titleBlur ];
    [_contentOverlayView addSubview:_titleLabel];

    [self updateGlassTint];
    [self updateShadowPathForSize:_targetCardSize
                           radius:(asPinned ? 10.0 : 9.0)
                         duration:0.0
                         animated:NO];
    [self updateRestingBackingLayersForSize:_targetCardSize
                                   duration:0.0
                                   animated:NO];
    [self updatePinnedStyleLayersForSize:_targetCardSize
                                ringSize:_targetCardSize
                                duration:0.0
                                animated:NO];
    [self layoutInnerForSize:_targetCardSize duration:0.0 animated:NO];

    // Smoothly fade the elevated drag drop shadow and Liquid Glass in on
    // pickup while dissolving the resting backing away so pickup never snaps!
    CAMediaTimingFunction* pickupEase =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    CABasicAnimation* shIn =
        [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    shIn.fromValue = @(0.0f);
    shIn.toValue = @(0.28f);
    shIn.duration = 0.12;
    shIn.timingFunction = pickupEase;
    [_cardView.layer addAnimation:shIn forKey:@"dragShadowFade"];

    _glassView.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.12;
      ctx.timingFunction = pickupEase;
      _glassView.animator.alphaValue = 1.0;
    }
                        completionHandler:nil];

    if (_restingBackingView.layer && !_restingBgLayer.hidden) {
      _restingBackingView.layer.opacity = 0.0f;
      CABasicAnimation* restOut =
          [CABasicAnimation animationWithKeyPath:@"opacity"];
      restOut.fromValue = @(1.0f);
      restOut.toValue = @(0.0f);
      restOut.duration = 0.12;
      restOut.timingFunction = pickupEase;
      restOut.removedOnCompletion = YES;
      [_restingBackingView.layer addAnimation:restOut
                                       forKey:@"restingBackingFade"];
    }
  }
  return self;
}

- (void)moveCenterToOverlayPoint:(NSPoint)center {
  // Only translates origin — never triggers subview layout or interrupts
  // active card morph / title blur-fade / conic glow animations!
  NSPoint origin =
      NSMakePoint(std::round(center.x - self.bounds.size.width * 0.5),
                  std::round(center.y - self.bounds.size.height * 0.5));
  [self setFrameOrigin:origin];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateGlassTint];
  [self updateRestingBackingLayersForSize:_targetCardSize
                                 duration:0.0
                                 animated:NO];
  [self updatePinnedStyleLayersForSize:_targetCardSize
                              ringSize:_targetCardSize
                              duration:0.0
                              animated:NO];
}

- (void)updateGlassTint {
  const bool dark = IsViewDarkAppearance(self);
  if (_isSelected && _morphedAsPinned) {
    _glassView.tintColor =
        dark ? [NSColor colorWithWhite:1.0 alpha:0.02]
             : [NSColor colorWithWhite:1.0 alpha:0.08];
  } else {
    _glassView.tintColor =
        dark ? [NSColor colorWithWhite:1.0 alpha:0.06]
             : [NSColor colorWithWhite:1.0 alpha:0.22];
  }
}

- (void)updateRestingBackingLayersForSize:(NSSize)sz
                                 duration:(CFTimeInterval)duration
                                 animated:(BOOL)animated {
  if (sz.width < 1.0 || sz.height < 1.0 || !_restingBgLayer) {
    return;
  }
  NSRect b = NSMakeRect(0.0, 0.0, sz.width, sz.height);
  const bool dark = IsViewDarkAppearance(self);
  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:duration];
    [CATransaction
        setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  }
  _restingBgLayer.frame = b;
  _restingGradientLayer.frame = b;
  if (_morphedAsPinned && !_isSelected) {
    // Matches resting unselected LightPinnedTileView pixel-for-pixel.
    _restingBgLayer.hidden = NO;
    _restingBgLayer.cornerRadius = 10.0;
    _restingBgLayer.borderWidth = 0.5;
    _restingBgLayer.borderColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.14]
              : [NSColor colorWithWhite:0.0 alpha:0.18])
            .CGColor;
    _restingBgLayer.backgroundColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
              : [NSColor colorWithWhite:0.0 alpha:0.05])
            .CGColor;
    _restingGradientLayer.hidden = YES;
  } else if (!_morphedAsPinned && _isSelected) {
    // Matches active unpinned LightTabRowView pixel-for-pixel.
    _restingBgLayer.hidden = NO;
    _restingBgLayer.cornerRadius = 9.0;
    _restingBgLayer.borderWidth = 0.0;
    if (_containerColor) {
      _restingBgLayer.backgroundColor =
          [NSColor.labelColor colorWithAlphaComponent:(dark ? 0.10 : 0.07)]
              .CGColor;
      NSColor* c = [_containerColor
                       colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
                       ?: _containerColor;
      _restingGradientLayer.colors = @[
        (__bridge id)[c colorWithAlphaComponent:(dark ? 0.23 : 0.18)].CGColor,
        (__bridge id)[c colorWithAlphaComponent:(dark ? 0.11 : 0.08)].CGColor,
        (__bridge id)[c colorWithAlphaComponent:(dark ? 0.025 : 0.015)].CGColor,
        (__bridge id)[c colorWithAlphaComponent:0.0].CGColor,
      ];
      _restingGradientLayer.hidden = NO;
    } else {
      _restingBgLayer.backgroundColor =
          [NSColor.labelColor colorWithAlphaComponent:0.16].CGColor;
      _restingGradientLayer.hidden = YES;
    }
  } else {
    _restingBgLayer.hidden = YES;
    _restingGradientLayer.hidden = YES;
  }
  [CATransaction commit];
}

- (void)updateShadowPathForSize:(NSSize)sz
                         radius:(CGFloat)radius
                       duration:(CFTimeInterval)duration
                       animated:(BOOL)animated {
  if (sz.width < 1.0 || sz.height < 1.0 || !_cardView.layer) {
    return;
  }
  NSRect rect = NSMakeRect(0.0, 0.0, sz.width, sz.height);
  CGPathRef newPath =
      CGPathCreateWithRoundedRect(rect, radius, radius, nullptr);
  if (animated && _cardView.layer.shadowPath) {
    CABasicAnimation* anim =
        [CABasicAnimation animationWithKeyPath:@"shadowPath"];
    anim.fromValue = (__bridge id)_cardView.layer.shadowPath;
    anim.toValue = (__bridge id)newPath;
    anim.duration = duration;
    anim.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
    [_cardView.layer addAnimation:anim forKey:@"shadowPathMorph"];
  }
  _cardView.layer.shadowPath = newPath;
  CGPathRelease(newPath);
}

- (void)updatePinnedStyleLayersForSize:(NSSize)sz
                              ringSize:(NSSize)ringSize
                              duration:(CFTimeInterval)duration
                              animated:(BOOL)animated {
  if (sz.width < 1.0 || sz.height < 1.0) {
    return;
  }
  NSRect b = NSMakeRect(0.0, 0.0, sz.width, sz.height);
  const bool dark = IsViewDarkAppearance(self);
  constexpr CGFloat kRadius = 10.0;

  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:duration];
    [CATransaction
        setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  }
  _pinClipLayer.frame = b;
  _pinClipLayer.cornerCurve = kCACornerCurveContinuous;
  _pinBgLayer.frame = b;
  _pinBlurredTintLayer.frame = b;
  _pinBorderRingLayer.frame = b;
  _pinConicGlowLayer.frame = b;
  _pinConicGlowMaskLayer.frame = b;
  _pinEphemeralBorderLayer.frame = b;

  auto applyShapePath = ^(CAShapeLayer* layer, NSString* animKey) {
    CGPathRef dp = CGPathCreateWithRoundedRect(
        CGRectInset(b, 1.0, 1.0), kRadius - 1.0, kRadius - 1.0, nullptr);
    if (animated && layer.path) {
      CABasicAnimation* pa = [CABasicAnimation animationWithKeyPath:@"path"];
      pa.fromValue = (__bridge id)layer.path;
      pa.toValue = (__bridge id)dp;
      pa.duration = duration;
      pa.timingFunction = [CAMediaTimingFunction
          functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      [layer addAnimation:pa forKey:animKey];
    }
    layer.path = dp;
    CGPathRelease(dp);
  };

  CAShapeLayer* ephemeralLayer = _pinEphemeralBorderLayer;
  auto applyEphemeralPath = ^(CGColorRef strokeColor) {
    ephemeralLayer.hidden = NO;
    ephemeralLayer.strokeColor = strokeColor;
    applyShapePath(ephemeralLayer, @"ephemeralPathMorph");
  };

  if (_isSelected) {
    if (_analysis && _analysis.isMultiColor &&
        _analysis.conicCGColors.count > 1) {
      _pinBgLayer.backgroundColor =
          (dark ? _analysis.backgroundTintDark : _analysis.backgroundTintLight)
              .CGColor;
      _pinBlurredTintLayer.contents = _analysis.blurredCGImageObj;
      _pinBlurredTintLayer.hidden = (_analysis.blurredCGImageObj == nil);
      _pinBorderRingLayer.hidden = YES;
      _pinBorderRingLayer.borderWidth = 0.0;
      _pinEphemeralBorderLayer.hidden = YES;
      _pinConicGlowLayer.colors = _analysis.conicCGColors;
      _pinConicGlowLayer.locations = _analysis.conicLocations;
      _pinConicGlowMaskLayer.lineDashPattern =
          _ephemeralContainer ? @[ @5.0, @4.0 ] : nil;
      applyShapePath(_pinConicGlowMaskLayer, @"conicMaskPathMorph");
      _pinConicGlowLayer.hidden = NO;
    } else if (_analysis) {
      _pinBlurredTintLayer.hidden = YES;
      _pinConicGlowLayer.hidden = YES;
      NSColor* fill = nil;
      NSColor* rim = nil;
      if (_analysis.singleLuma > 0.85) {
        fill = [NSColor colorWithWhite:0.0 alpha:0.24];
        rim = [NSColor colorWithWhite:(dark ? 1.0 : 0.0) alpha:0.55];
      } else if (_analysis.singleLuma < 0.15 && dark) {
        fill = [NSColor colorWithWhite:1.0 alpha:0.16];
        rim = [NSColor colorWithWhite:1.0 alpha:0.52];
      } else {
        fill = [_analysis.singleMarkColor colorWithAlphaComponent:(dark ? 0.18 : 0.14)];
        rim = [_analysis.singleMarkColor colorWithAlphaComponent:0.85];
      }
      _pinBgLayer.backgroundColor = fill.CGColor;
      if (_ephemeralContainer) {
        _pinBorderRingLayer.hidden = YES;
        _pinBorderRingLayer.borderWidth = 0.0;
        applyEphemeralPath(rim.CGColor);
      } else {
        _pinEphemeralBorderLayer.hidden = YES;
        _pinBorderRingLayer.hidden = NO;
        _pinBorderRingLayer.borderWidth = 2.0;
        _pinBorderRingLayer.borderColor = rim.CGColor;
      }
    } else {
      _pinBlurredTintLayer.hidden = YES;
      _pinConicGlowLayer.hidden = YES;
      _pinBgLayer.backgroundColor =
          [NSColor colorWithWhite:1.0 alpha:(dark ? 0.22 : 0.65)].CGColor;
      NSColor* fallbackRim =
          [NSColor colorWithWhite:(dark ? 1.0 : 0.0)
                            alpha:(dark ? 0.30 : 0.16)];
      if (_ephemeralContainer) {
        _pinBorderRingLayer.hidden = YES;
        _pinBorderRingLayer.borderWidth = 0.0;
        applyEphemeralPath(fallbackRim.CGColor);
      } else {
        _pinEphemeralBorderLayer.hidden = YES;
        _pinBorderRingLayer.hidden = NO;
        _pinBorderRingLayer.borderWidth = 2.0;
        _pinBorderRingLayer.borderColor = fallbackRim.CGColor;
      }
    }
  }
  [CATransaction commit];
}

- (void)layoutInnerForSize:(NSSize)sz
                  duration:(CFTimeInterval)duration
                  animated:(BOOL)animated {
  CGFloat w = sz.width;
  CGFloat h = sz.height;

  NSRect iconFrame = _morphedAsPinned
                         ? NSMakeRect(std::floor((w - 16.0) * 0.5),
                                      std::floor((h - 16.0) * 0.5), 16.0, 16.0)
                         : NSMakeRect(_containerColor ? 12.0 : 9.0,
                                      std::floor((h - 16.0) * 0.5), 16.0, 16.0);
  CGFloat titleX = _containerColor ? 36.0 : 33.0;
  NSSize fit = [_titleLabel sizeThatFits:NSMakeSize(500.0, h)];
  CGFloat th = std::min(h, std::ceil(fit.height));
  CGFloat titleW = _morphedAsPinned
                       ? std::max<CGFloat>(100.0, _titleLabel.frame.size.width)
                       : std::max<CGFloat>(0.0, w - titleX - 10.0);
  NSRect titleFrame =
      NSMakeRect(_morphedAsPinned ? (titleX - 10.0) : titleX,
                 std::floor((h - th) * 0.5), titleW, th);

  _glassView.cornerRadius = _morphedAsPinned ? 10.0 : 9.0;
  _contentOverlayView.layer.cornerRadius = _morphedAsPinned ? 10.0 : 9.0;

  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:duration];
    [CATransaction
        setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  }
  _containerBarLayer.opacity =
      (_containerColor == nil || _morphedAsPinned) ? 0.0f : 1.0f;
  _containerBarLayer.frame =
      CGRectMake(3.0, 7.0, 2.5, std::max<CGFloat>(4.0, h - 14.0));
  [CATransaction commit];

  // Smooth fade + Gaussian blur dissolve on tab title!
  const float targetTitleAlpha = _morphedAsPinned ? 0.0f : 1.0f;
  const CGFloat targetTitleBlur = _morphedAsPinned ? 7.5 : 0.0;
  if (_titleLabel.layer) {
    float fromAlpha = _titleLabel.layer.opacity;
    CGFloat fromBlur = _morphedAsPinned ? 0.0 : 7.5;
    if (CALayer* pres = _titleLabel.layer.presentationLayer) {
      fromAlpha = pres.opacity;
      if (NSNumber* br = [pres valueForKeyPath:@"filters.titleBlur.inputRadius"]) {
        fromBlur = br.doubleValue;
      }
    }
    const bool titleNeedsAnim =
        animated && (std::abs(targetTitleAlpha - fromAlpha) > 0.001f ||
                     std::abs(targetTitleBlur - fromBlur) > 0.05);
    [_titleLabel.layer removeAnimationForKey:@"titleFade"];
    [_titleLabel.layer removeAnimationForKey:@"titleBlurAnim"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _titleLabel.layer.opacity = targetTitleAlpha;
    [_titleLabel.layer setValue:@(targetTitleBlur)
                     forKeyPath:@"filters.titleBlur.inputRadius"];
    if (titleNeedsAnim) {
      [CATransaction setDisableActions:NO];
      CAMediaTimingFunction* fn =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      CFTimeInterval titleDur = _morphedAsPinned ? std::min(duration, 0.17) : duration;
      CABasicAnimation* op = [CABasicAnimation animationWithKeyPath:@"opacity"];
      op.fromValue = @(fromAlpha);
      op.toValue = @(targetTitleAlpha);
      op.duration = titleDur;
      op.timingFunction = fn;
      op.removedOnCompletion = YES;
      [_titleLabel.layer addAnimation:op forKey:@"titleFade"];

      CABasicAnimation* bl = [CABasicAnimation
          animationWithKeyPath:@"filters.titleBlur.inputRadius"];
      bl.fromValue = @(fromBlur);
      bl.toValue = @(targetTitleBlur);
      bl.duration = titleDur;
      bl.timingFunction = fn;
      bl.removedOnCompletion = YES;
      [_titleLabel.layer addAnimation:bl forKey:@"titleBlurAnim"];
    }
    [CATransaction commit];
  }

  if (animated) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = duration;
      ctx.timingFunction =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      _iconView.animator.frame = iconFrame;
      _titleLabel.animator.frame = titleFrame;
    }
                        completionHandler:nil];
  } else {
    _iconView.frame = iconFrame;
    _titleLabel.frame = titleFrame;
  }
}

- (void)setMorphedAsPinned:(BOOL)asPinned
                targetSize:(NSSize)size
             anchorCenter:(NSPoint)center
                  animated:(BOOL)animated {
  constexpr CFTimeInterval kMorphDur = 0.22;
  _morphedAsPinned = asPinned;
  _targetCardSize = size;
  [self updateGlassTint];

  NSRect targetCardRect = [self centeredCardRectForSize:size];
  NSRect targetChildBounds = NSMakeRect(0.0, 0.0, size.width, size.height);
  [self updateRestingBackingLayersForSize:size
                                 duration:kMorphDur
                                 animated:animated];
  [self updatePinnedStyleLayersForSize:size
                              ringSize:size
                              duration:kMorphDur
                              animated:animated];

  // Animate active pinned tile styling (conic outline + blurred tint + custom
  // backing) with opacity + crisp Gaussian unblur + subtle scale-in!
  const float targetPinAlpha = (asPinned && _isSelected) ? 1.0f : 0.0f;
  const CGFloat targetPinBlur = (asPinned && _isSelected) ? 0.0 : 6.0;
  const CGFloat targetPinScale = (asPinned && _isSelected) ? 1.0 : 0.90;
  if (_pinnedStyleView.layer) {
    float fromAlpha = _pinnedStyleView.layer.opacity;
    CGFloat fromBlur = (asPinned && _isSelected) ? 6.0 : 0.0;
    CATransform3D fromTf = _pinnedStyleView.layer.transform;
    if (CALayer* pres = _pinnedStyleView.layer.presentationLayer) {
      fromAlpha = pres.opacity;
      fromTf = pres.transform;
      if (NSNumber* br =
              [pres valueForKeyPath:@"filters.pinStyleBlur.inputRadius"]) {
        fromBlur = br.doubleValue;
      }
    }
    CATransform3D toTf =
        CATransform3DMakeScale(targetPinScale, targetPinScale, 1.0);
    [_pinnedStyleView.layer removeAnimationForKey:@"pinnedStyleFade"];
    [_pinnedStyleView.layer removeAnimationForKey:@"pinnedStyleBlur"];
    [_pinnedStyleView.layer removeAnimationForKey:@"pinnedStyleScale"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _pinnedStyleView.layer.opacity = targetPinAlpha;
    [_pinnedStyleView.layer setValue:@(targetPinBlur)
                          forKeyPath:@"filters.pinStyleBlur.inputRadius"];
    _pinnedStyleView.layer.transform = toTf;
    if (animated &&
        (std::abs(targetPinAlpha - fromAlpha) > 0.001f ||
         std::abs(targetPinBlur - fromBlur) > 0.05)) {
      [CATransaction setDisableActions:NO];
      CAMediaTimingFunction* fn =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      CFTimeInterval dur = asPinned ? 0.22 : 0.16;

      CABasicAnimation* op = [CABasicAnimation animationWithKeyPath:@"opacity"];
      op.fromValue = @(fromAlpha);
      op.toValue = @(targetPinAlpha);
      op.duration = dur;
      op.timingFunction = fn;
      op.removedOnCompletion = YES;
      [_pinnedStyleView.layer addAnimation:op forKey:@"pinnedStyleFade"];

      CABasicAnimation* bl = [CABasicAnimation
          animationWithKeyPath:@"filters.pinStyleBlur.inputRadius"];
      bl.fromValue = @(fromBlur);
      bl.toValue = @(targetPinBlur);
      bl.duration = dur;
      bl.timingFunction = fn;
      bl.removedOnCompletion = YES;
      [_pinnedStyleView.layer addAnimation:bl forKey:@"pinnedStyleBlur"];

      CABasicAnimation* sc =
          [CABasicAnimation animationWithKeyPath:@"transform"];
      sc.fromValue = [NSValue valueWithCATransform3D:fromTf];
      sc.toValue = [NSValue valueWithCATransform3D:toTf];
      sc.duration = dur;
      sc.timingFunction = fn;
      sc.removedOnCompletion = YES;
      [_pinnedStyleView.layer addAnimation:sc forKey:@"pinnedStyleScale"];
    }
    [CATransaction commit];
  }

  NSPoint targetStageOrigin =
      NSMakePoint(std::round(center.x - self.bounds.size.width * 0.5),
                  std::round(center.y - self.bounds.size.height * 0.5));
  NSRect targetStageFrame =
      NSMakeRect(targetStageOrigin.x, targetStageOrigin.y,
                 self.bounds.size.width, self.bounds.size.height);

  if (animated) {
    [self updateShadowPathForSize:size
                           radius:(asPinned ? 10.0 : 9.0)
                         duration:kMorphDur
                         animated:YES];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = kMorphDur;
      ctx.timingFunction =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      self.animator.frame = targetStageFrame;
      _cardView.animator.frame = targetCardRect;
      _glassView.animator.frame = targetChildBounds;
      _restingBackingView.animator.frame = targetChildBounds;
      _pinnedStyleView.animator.frame = targetChildBounds;
      _contentOverlayView.animator.frame = targetChildBounds;
    }
                        completionHandler:nil];
    [self layoutInnerForSize:size duration:kMorphDur animated:YES];
  } else {
    [self setFrameOrigin:targetStageOrigin];
    _cardView.frame = targetCardRect;
    _glassView.frame = targetChildBounds;
    _restingBackingView.frame = targetChildBounds;
    _pinnedStyleView.frame = targetChildBounds;
    _contentOverlayView.frame = targetChildBounds;
    [self updateShadowPathForSize:size
                           radius:(asPinned ? 10.0 : 9.0)
                         duration:0.0
                         animated:NO];
    [self layoutInnerForSize:size duration:0.0 animated:NO];
  }
}

- (void)animateLandingToOverlayRect:(NSRect)landingInOverlay
                           duration:(NSTimeInterval)duration
                         completion:(void (^)(void))completion {
  _targetCardSize = landingInOverlay.size;
  CAMediaTimingFunction* easeOut =
      [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];

  if (_cardView.layer) {
    float fromShadow = _cardView.layer.shadowOpacity;
    if (CALayer* pres = _cardView.layer.presentationLayer) {
      fromShadow = pres.shadowOpacity;
    }
    [_cardView.layer removeAnimationForKey:@"dragShadowFade"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cardView.layer.shadowOpacity = 0.0f;
    [CATransaction setDisableActions:NO];
    CABasicAnimation* shOut =
        [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    shOut.fromValue = @(fromShadow);
    shOut.toValue = @(0.0f);
    shOut.duration = duration;
    shOut.timingFunction = easeOut;
    shOut.removedOnCompletion = YES;
    [_cardView.layer addAnimation:shOut forKey:@"dragShadowFade"];
    [CATransaction commit];
  }

  // Compute pixel-exact stage & card rects so stage.origin + card.origin ==
  // landingInOverlay.origin with zero subpixel drift on handoff!
  NSPoint landCenter = NSMakePoint(NSMidX(landingInOverlay),
                                   NSMidY(landingInOverlay));
  CGFloat stageOriginX =
      std::round(landCenter.x - self.bounds.size.width * 0.5);
  CGFloat stageOriginY =
      std::round(landCenter.y - self.bounds.size.height * 0.5);
  NSRect landStageFrame = NSMakeRect(
      stageOriginX, stageOriginY, self.bounds.size.width,
      self.bounds.size.height);
  NSRect landCardRect = NSMakeRect(
      landingInOverlay.origin.x - stageOriginX,
      landingInOverlay.origin.y - stageOriginY,
      landingInOverlay.size.width,
      landingInOverlay.size.height);
  NSRect landChildBounds =
      NSMakeRect(0.0, 0.0, landingInOverlay.size.width,
                 landingInOverlay.size.height);

  // Sync resting backing & pinned style layers to final target size using the
  // exact landing duration so nothing snaps or lags when expanding (e.g. 1/3
  // pinned hover preview -> 1/2 or 1/1 pinned slot!).
  [self updateRestingBackingLayersForSize:landingInOverlay.size
                                 duration:duration
                                 animated:YES];
  [self updatePinnedStyleLayersForSize:landingInOverlay.size
                              ringSize:landingInOverlay.size
                              duration:duration
                              animated:YES];
  [self updateShadowPathForSize:landingInOverlay.size
                         radius:(_morphedAsPinned ? 10.0 : 9.0)
                       duration:duration
                       animated:YES];
  // Smoothly glide icon (and title) to the target slot's exact layout!
  [self layoutInnerForSize:landingInOverlay.size
                  duration:duration
                  animated:YES];

  // Cross-fade the exact resting backing in as the elevated Liquid Glass
  // dissolves away — eliminates any brightness jump or abrupt pop on drop!
  if (_restingBackingView.layer && !_restingBgLayer.hidden) {
    float fromAlpha = _restingBackingView.layer.opacity;
    if (CALayer* pres = _restingBackingView.layer.presentationLayer) {
      fromAlpha = pres.opacity;
    }
    [_restingBackingView.layer removeAnimationForKey:@"restingBackingFade"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _restingBackingView.layer.opacity = 1.0f;
    [CATransaction setDisableActions:NO];
    CABasicAnimation* restIn =
        [CABasicAnimation animationWithKeyPath:@"opacity"];
    restIn.fromValue = @(fromAlpha);
    restIn.toValue = @(1.0f);
    restIn.duration = duration;
    restIn.timingFunction = easeOut;
    restIn.removedOnCompletion = YES;
    [_restingBackingView.layer addAnimation:restIn
                                     forKey:@"restingBackingFade"];
    [CATransaction commit];
  }

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = duration;
    ctx.timingFunction = easeOut;
    self.animator.frame = landStageFrame;
    _cardView.animator.frame = landCardRect;
    _glassView.animator.frame = landChildBounds;
    _glassView.animator.alphaValue = 0.0;
    _restingBackingView.animator.frame = landChildBounds;
    _pinnedStyleView.animator.frame = landChildBounds;
    _contentOverlayView.animator.frame = landChildBounds;
  }
                      completionHandler:completion];
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
- (void)showSpotlightCommandBar;
- (void)showFindBar;
- (void)findNext:(BOOL)forward;
- (void)updateFindBarActiveMatch:(int)active totalMatches:(int)total;
- (void)toggleCollapsed;
- (BOOL)isCollapsed;
- (void)reloadTabsAndNavigation;
- (void)updateNavigationStateOnly;
- (void)downloadsDidUpdate;
- (void)applyAutocompleteSuggestions:(NSArray<LightSuggestionItem*>*)items;
- (void)applySuggestionFavicon:(NSImage*)favicon
                   forCacheKey:(NSString*)key
                       hostKey:(NSString*)hostKey;
- (void)beginInlineRenameForGroupToken:(NSString*)token;
- (NSMenu*)buildNewTabButtonContextMenu;
- (NSMenu*)buildInlinePlusContextMenu;
- (NSRect)beginExtensionPopup;
- (void)endExtensionPopup;
- (void)populateExtensionsMenu:(NSMenu*)menu;
- (BOOL)handleConfirmQuitAttempt;
- (void)cancelConfirmQuit;
- (NSWindow*)targetWindow;
- (BOOL)isPinned;
- (CGFloat)currentSidebarWidth;
- (gfx::Insets)currentContentFrameInsets;

@end

namespace {
std::unordered_map<std::string, std::unordered_set<int>>&
AskedSitePermissionsByOrigin() {
  static auto* map =
      new std::unordered_map<std::string, std::unordered_set<int>>();
  return *map;
}

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
      public AutocompleteController::Observer,
      public content::DownloadManager::Observer,
      public download::DownloadItem::Observer,
      public find_in_page::FindResultObserver {
 public:
  LightGlassSidebarBridgeImpl(BrowserView* browser_view, NSWindow* window)
      : browser_view_(browser_view) {
    ActiveSidebarBridges()[browser_view_] = this;
    if (BrowserWindowInterface* b = this->browser()) {
      if (Profile* profile = b->GetProfile()) {
        // Strictly local, non-AI autocomplete providers only.
        AutocompleteControllerConfig config;
        config.provider_types = static_cast<int>(
            AutocompleteProvider::Type::kKeyword |
            AutocompleteProvider::Type::kOpenTab |
            AutocompleteProvider::Type::kZeroSuggestLocalHistory |
            AutocompleteProvider::Type::kBookmark |
            AutocompleteProvider::Type::kBuiltin |
            AutocompleteProvider::Type::kHistoryQuick |
            AutocompleteProvider::Type::kHistoryUrl |
            AutocompleteProvider::Type::kShortcuts |
            AutocompleteProvider::Type::kHistoryFuzzy |
            AutocompleteProvider::Type::kCalculator |
            AutocompleteProvider::Type::kVerbatimMatch);
        config.show_iph_matches = false;
        autocomplete_controller_ = std::make_unique<AutocompleteController>(
            std::make_unique<ChromeAutocompleteProviderClient>(profile),
            config);
        autocomplete_controller_->AddObserver(this);

        if (content::DownloadManager* dm = profile->GetDownloadManager()) {
          download_manager_ = dm;
          download_manager_->AddObserver(this);
          content::DownloadManager::DownloadVector items;
          download_manager_->GetAllDownloads(&items);
          for (download::DownloadItem* item : items) {
            ObserveDownloadItem(item);
          }
        }
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
        ObserveFindForWebContents(model->GetActiveWebContents());
      }
    }

    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
      [controller_ downloadsDidUpdate];
    }
  }

  ~LightGlassSidebarBridgeImpl() override {
    ActiveSidebarBridges().erase(browser_view_);
    ClearObservedDownloads();
    if (download_manager_) {
      download_manager_->RemoveObserver(this);
      download_manager_ = nullptr;
    }
    if (autocomplete_controller_) {
      autocomplete_controller_->Stop(AutocompleteStopReason::kClobbered);
      autocomplete_controller_->RemoveObserver(this);
      autocomplete_controller_.reset();
    }
    ObserveFindForWebContents(nullptr);
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

  gfx::Insets GetContentFrameInsets() const {
    if (@available(macOS 26.0, *)) {
      if (controller_) {
        return [controller_ currentContentFrameInsets];
      }
    }
    return gfx::Insets();
  }

  void InvalidateBrowserLayout() {
    if (browser_view_) {
      browser_view_->InvalidateLayout();
    }
  }

  void EnsureActiveWebContentsTransparent() {
    if (browser_view_) {
      for (ContentsWebView* cwv : browser_view_->GetAllVisibleContentsWebViews()) {
        if (cwv) {
          cwv->SetBackgroundVisible(false);
        }
      }
    }
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

  void ShowSpotlightCommandBar() override {
    if (@available(macOS 26.0, *)) {
      [controller_ showSpotlightCommandBar];
    }
  }

  void ShowFindBar() override {
    if (@available(macOS 26.0, *)) {
      [controller_ showFindBar];
    }
  }

  void FindNext(bool forward) override {
    if (@available(macOS 26.0, *)) {
      [controller_ findNext:(forward ? YES : NO)];
    }
  }

  void ObserveFindForWebContents(content::WebContents* wc) {
    if (observed_find_helper_) {
      observed_find_helper_->RemoveObserver(this);
      observed_find_helper_ = nullptr;
    }
    if (wc) {
      if (auto* helper = find_in_page::FindTabHelper::FromWebContents(wc)) {
        helper->AddObserver(this);
        observed_find_helper_ = helper;
      }
    }
  }

  void StartFindInPage(const std::u16string& text,
                       bool forward,
                       bool find_match) {
    BrowserWindowInterface* b = browser();
    content::WebContents* wc =
        b ? b->GetTabStripModel()->GetActiveWebContents() : nullptr;
    if (!wc) {
      return;
    }
    auto* helper = find_in_page::FindTabHelper::FromWebContents(wc);
    if (!helper) {
      return;
    }
    if (observed_find_helper_ != helper) {
      ObserveFindForWebContents(wc);
    }
    if (text.empty()) {
      helper->StopFinding(find_in_page::SelectionAction::kClear);
      if (@available(macOS 26.0, *)) {
        [controller_ updateFindBarActiveMatch:0 totalMatches:0];
      }
      return;
    }
    helper->set_find_ui_active(true);
    helper->StartFinding(text, forward, /*case_sensitive=*/false, find_match);
  }

  void StopFindInPage(bool clear_selection) {
    BrowserWindowInterface* b = browser();
    content::WebContents* wc =
        b ? b->GetTabStripModel()->GetActiveWebContents() : nullptr;
    if (!wc) {
      return;
    }
    if (auto* helper = find_in_page::FindTabHelper::FromWebContents(wc)) {
      helper->set_find_ui_active(false);
      helper->StopFinding(clear_selection
                              ? find_in_page::SelectionAction::kClear
                              : find_in_page::SelectionAction::kKeep);
    }
  }

  // find_in_page::FindResultObserver:
  void OnFindResultAvailable(content::WebContents* web_contents) override {
    if (!web_contents) {
      return;
    }
    if (auto* helper =
            find_in_page::FindTabHelper::FromWebContents(web_contents)) {
      const auto& details = helper->find_result();
      if (@available(macOS 26.0, *)) {
        [controller_ updateFindBarActiveMatch:details.active_match_ordinal()
                                 totalMatches:details.number_of_matches()];
      }
    }
  }

  void OnFindEmptyText(content::WebContents* web_contents) override {
    if (@available(macOS 26.0, *)) {
      [controller_ updateFindBarActiveMatch:0 totalMatches:0];
    }
  }

  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override {
    if (observed_find_helper_ == helper) {
      observed_find_helper_->RemoveObserver(this);
      observed_find_helper_ = nullptr;
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
      if (LightNewTabInheritsActiveContainer()) {
        if (content::WebContents* active =
                b->GetTabStripModel()->GetActiveWebContents()) {
          const std::string cid = LightGetTabContainerIdForWebContents(active);
          if (!cid.empty() && LightOpenNewTabInContainer(b, cid)) {
            return;
          }
        }
      }
      NavigateParams params(b, GURL("chrome://newtab/"),
                            ui::PAGE_TRANSITION_TYPED);
      params.disposition = WindowOpenDisposition::kNewForegroundTab;
      params.source_contents = nullptr;
      params.suppress_light_container_inheritance = true;
      Navigate(&params);
    }
  }

  void OpenNewTabInContainer(const std::string& container_id) {
    if (BrowserWindowInterface* b = browser()) {
      if (LightOpenNewTabInContainer(b, container_id)) {
        if (@available(macOS 26.0, *)) {
          [controller_ reloadTabsAndNavigation];
          [controller_ focusAddressBar:YES];
        }
      }
    }
  }

  void OpenContainersSettings() {
    LightNativeSettingsController::ShowForBrowserToCategory(browser(),
                                                            "Containers");
  }

  void OpenChromeWebStore() {
    if (BrowserWindowInterface* b = browser()) {
      NavigateParams params(b, GURL("https://chromewebstore.google.com/"),
                            ui::PAGE_TRANSITION_LINK);
      params.disposition = WindowOpenDisposition::kNewForegroundTab;
      params.suppress_light_container_inheritance = true;
      Navigate(&params);
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
          ui::ImageModel img = action->GetIcon(wc, gfx::Size(32, 32));
          if (!img.IsEmpty()) {
            gfx::ImageSkia skia = img.Rasterize(bv->GetColorProvider());
            skia.EnsureRepsForSupportedScales();
            if (!skia.isNull()) {
              icon = gfx::NSImageFromImageSkia(skia);
            }
          }
        }
      }
      if (registry) {
        if (const extensions::Extension* ext =
                registry->enabled_extensions().GetByID(action_id)) {
          if (name.empty()) {
            name = base::UTF8ToUTF16(ext->name());
          }
          auto tryIconRelPath = [&](const base::FilePath& rel) -> NSImage* {
            if (rel.empty()) {
              return nil;
            }
            base::FilePath full = ext->path().Append(rel);
            NSString* nsPath = base::SysUTF8ToNSString(full.AsUTF8Unsafe());
            if (nsPath.length == 0) {
              return nil;
            }
            NSImage* diskImg = [[NSImage alloc] initWithContentsOfFile:nsPath];
            return (diskImg && diskImg.isValid && diskImg.size.width > 0)
                       ? diskImg
                       : nil;
          };
          NSImage* diskIcon = nil;
          extensions::ExtensionResource res =
              extensions::IconsInfo::GetIconResource(
                  ext, extension_misc::EXTENSION_ICON_LARGE,
                  ExtensionIconSet::Match::kBigger);
          if (res.empty()) {
            res = extensions::IconsInfo::GetIconResource(
                ext, extension_misc::EXTENSION_ICON_MEDIUM,
                ExtensionIconSet::Match::kSmaller);
          }
          if (!res.empty()) {
            diskIcon = tryIconRelPath(res.relative_path());
          }
          if (!diskIcon && ext->manifest()) {
            static constexpr const char* kActionKeys[] = {
                "action", "browser_action", "page_action"};
            for (const char* key : kActionKeys) {
              const base::DictValue* dict = ext->manifest()->FindDictPath(key);
              if (!dict) {
                continue;
              }
              if (const std::string* s = dict->FindString("default_icon")) {
                diskIcon = tryIconRelPath(base::FilePath::FromUTF8Unsafe(*s));
              } else if (const base::DictValue* idict =
                             dict->FindDict("default_icon")) {
                std::string bestPath;
                int bestSz = -1;
                for (const auto [szKey, val] : *idict) {
                  if (val.is_string()) {
                    int sz = std::atoi(szKey.c_str());
                    if (sz > bestSz) {
                      bestSz = sz;
                      bestPath = val.GetString();
                    }
                  }
                }
                if (!bestPath.empty()) {
                  diskIcon =
                      tryIconRelPath(base::FilePath::FromUTF8Unsafe(bestPath));
                }
              }
              if (diskIcon) {
                break;
              }
            }
          }
          if (diskIcon) {
            icon = diskIcon;
          }
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
    LightExtensionsManagerController::ShowForBrowser(browser());
  }

  bool HasExtensionOptionsPage(const std::string& extension_id) const {
    BrowserView* bv = browser_view_.get();
    Profile* profile = bv ? bv->GetProfile() : nullptr;
    if (!profile) {
      return false;
    }
    auto* registry = extensions::ExtensionRegistry::Get(profile);
    if (!registry) {
      return false;
    }
    const extensions::Extension* ext =
        registry->GetInstalledExtension(extension_id);
    return ext && extensions::OptionsPageInfo::HasOptionsPage(ext);
  }

  void OpenExtensionOptionsPage(const std::string& extension_id) {
    BrowserView* bv = browser_view_.get();
    BrowserWindowInterface* b = browser();
    Profile* profile = bv ? bv->GetProfile() : nullptr;
    if (!b || !profile) {
      return;
    }
    auto* registry = extensions::ExtensionRegistry::Get(profile);
    const extensions::Extension* ext =
        registry ? registry->GetInstalledExtension(extension_id) : nullptr;
    if (!ext || !extensions::OptionsPageInfo::HasOptionsPage(ext)) {
      return;
    }
    GURL url = extensions::OptionsPageInfo::GetOptionsPage(ext);
    if (url.is_valid()) {
      NavigateParams params(b, url, ui::PAGE_TRANSITION_LINK);
      params.disposition = WindowOpenDisposition::kNewForegroundTab;
      Navigate(&params);
    }
  }

  void DisableExtensionById(const std::string& extension_id) {
    BrowserView* bv = browser_view_.get();
    Profile* profile = bv ? bv->GetProfile() : nullptr;
    if (!profile) {
      return;
    }
    if (auto* registrar = extensions::ExtensionRegistrar::Get(profile)) {
      registrar->DisableExtension(
          extension_id,
          {extensions::disable_reason::DISABLE_USER_ACTION});
    }
  }

  void UninstallExtensionById(const std::string& extension_id) {
    BrowserView* bv = browser_view_.get();
    Profile* profile = bv ? bv->GetProfile() : nullptr;
    if (!profile) {
      return;
    }
    if (auto* registrar = extensions::ExtensionRegistrar::Get(profile)) {
      registrar->UninstallExtension(
          extension_id, extensions::UNINSTALL_REASON_USER_INITIATED, nullptr);
    }
  }

  NSDictionary* GetActiveSiteSecurityInfo() const {
    BrowserWindowInterface* b = browser();
    content::WebContents* wc =
        (b && b->GetTabStripModel())
            ? b->GetTabStripModel()->GetActiveWebContents()
            : nullptr;
    if (!wc) {
      return nil;
    }
    GURL url = wc->GetVisibleURL();
    NSString* host =
        url.has_host() ? base::SysUTF8ToNSString(url.host())
                       : base::SysUTF8ToNSString(url.spec());
    BOOL isInternal = url.SchemeIs("chrome") || url.SchemeIs("light") ||
                      url.SchemeIs("about");
    BOOL isHttps = url.SchemeIsCryptographic();
    BOOL isSecure = isHttps;
    NSString* statusTitle = @"Not Secure";
    NSString* statusDetail = @"Your connection to this site is not encrypted.";
    NSString* symbolName = @"lock.open.fill";
    NSString* certSubject = @"";
    NSString* certIssuer = @"";
    NSString* certValidRange = @"";

    if (isInternal) {
      statusTitle = @"Light Internal Page";
      statusDetail = @"You are viewing a built-in Light browser page.";
      symbolName = @"sparkles";
      isSecure = YES;
    } else if (content::NavigationEntry* entry =
                   wc->GetController().GetVisibleEntry()) {
      const content::SSLStatus& ssl = entry->GetSSL();
      if (isHttps) {
        if (net::IsCertStatusError(ssl.cert_status)) {
          isSecure = NO;
          statusTitle = @"Certificate Error";
          statusDetail =
              @"This site's security certificate could not be verified.";
          symbolName = @"exclamationmark.triangle.fill";
        } else {
          isSecure = YES;
          statusTitle = @"Connection is Secure";
          statusDetail =
              @"Your information (for example, passwords or credit card numbers) is private when sent to this site.";
          symbolName = @"lock.fill";
        }
      }
      if (ssl.certificate) {
        certSubject =
            base::SysUTF8ToNSString(ssl.certificate->subject().GetDisplayName());
        certIssuer =
            base::SysUTF8ToNSString(ssl.certificate->issuer().GetDisplayName());
        std::u16string startStr =
            base::TimeFormatShortDateNumeric(ssl.certificate->valid_start());
        std::u16string endStr =
            base::TimeFormatShortDateNumeric(ssl.certificate->valid_expiry());
        certValidRange = [NSString
            stringWithFormat:@"%@  –  %@", base::SysUTF16ToNSString(startStr),
                             base::SysUTF16ToNSString(endStr)];
      }
    }

    return @{
      @"host" : host ?: @"",
      @"url" : base::SysUTF8ToNSString(url.spec()) ?: @"",
      @"isSecure" : @(isSecure),
      @"isInternal" : @(isInternal),
      @"statusTitle" : statusTitle,
      @"statusDetail" : statusDetail,
      @"symbolName" : symbolName,
      @"certSubject" : certSubject,
      @"certIssuer" : certIssuer,
      @"certValidRange" : certValidRange,
    };
  }

  NSArray<NSDictionary*>* GetActiveSitePermissions() const {
    NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
    BrowserWindowInterface* b = browser();
    Profile* profile = b ? b->GetProfile() : nullptr;
    content::WebContents* wc =
        (b && b->GetTabStripModel())
            ? b->GetTabStripModel()->GetActiveWebContents()
            : nullptr;
    if (!profile || !wc) {
      return out;
    }
    GURL url = wc->GetVisibleURL();
    if (!url.is_valid() || url.SchemeIs("chrome") || url.SchemeIs("light") ||
        url.SchemeIs("about")) {
      return out;
    }
    HostContentSettingsMap* map =
        HostContentSettingsMapFactory::GetForProfile(profile);
    if (!map) {
      return out;
    }

    struct PermSpec {
      ContentSettingsType type;
      const char* name;
      const char* symbol;
    };
    static constexpr PermSpec kPerms[] = {
        {ContentSettingsType::MEDIASTREAM_CAMERA, "Camera", "video.fill"},
        {ContentSettingsType::MEDIASTREAM_MIC, "Microphone", "mic.fill"},
        {ContentSettingsType::GEOLOCATION, "Location", "location.fill"},
        {ContentSettingsType::NOTIFICATIONS, "Notifications", "bell.fill"},
        {ContentSettingsType::CLIPBOARD_READ_WRITE, "Clipboard",
         "doc.on.clipboard.fill"},
        {ContentSettingsType::POPUPS, "Pop-ups & Redirects",
         "macwindow.on.rectangle"},
        {ContentSettingsType::AUTOMATIC_DOWNLOADS, "Automatic Downloads",
         "arrow.down.circle.fill"},
        {ContentSettingsType::SOUND, "Sound", "speaker.wave.2.fill"},
        {ContentSettingsType::MIDI_SYSEX, "MIDI Devices", "pianokeys"},
        {ContentSettingsType::SENSORS, "Motion Sensors", "gyroscope"},
    };

    const std::string originKey = url.DeprecatedGetOriginAsURL().spec();
    const auto askedIt = AskedSitePermissionsByOrigin().find(originKey);

    for (const auto& spec : kPerms) {
      content_settings::SettingInfo info;
      ContentSetting current =
          map->GetContentSetting(url, url, spec.type, &info);
      const bool hasExplicitOverride =
          info.primary_pattern != ContentSettingsPattern::Wildcard();
      const bool wasAsked =
          askedIt != AskedSitePermissionsByOrigin().end() &&
          askedIt->second.contains(static_cast<int>(spec.type));
      if (!hasExplicitOverride && !wasAsked) {
        continue;
      }
      int uiState = 1;  // 0=Allow, 1=Ask/Default, 2=Block
      if (hasExplicitOverride) {
        if (current == CONTENT_SETTING_ALLOW) {
          uiState = 0;
        } else if (current == CONTENT_SETTING_BLOCK) {
          uiState = 2;
        }
      }
      [out addObject:@{
        @"type" : @(static_cast<int>(spec.type)),
        @"name" : base::SysUTF8ToNSString(spec.name),
        @"symbol" : base::SysUTF8ToNSString(spec.symbol),
        @"state" : @(uiState),
        @"hasOverride" : @(hasExplicitOverride),
      }];
    }
    return out;
  }

  void SetActiveSitePermission(int content_settings_type_int, int ui_state) {
    BrowserWindowInterface* b = browser();
    Profile* profile = b ? b->GetProfile() : nullptr;
    content::WebContents* wc =
        (b && b->GetTabStripModel())
            ? b->GetTabStripModel()->GetActiveWebContents()
            : nullptr;
    if (!profile || !wc) {
      return;
    }
    GURL url = wc->GetVisibleURL();
    if (!url.is_valid()) {
      return;
    }
    HostContentSettingsMap* map =
        HostContentSettingsMapFactory::GetForProfile(profile);
    if (!map) {
      return;
    }
    ContentSettingsType type =
        static_cast<ContentSettingsType>(content_settings_type_int);
    ContentSetting setting = CONTENT_SETTING_DEFAULT;
    if (ui_state == 0) {
      setting = CONTENT_SETTING_ALLOW;
    } else if (ui_state == 2) {
      setting = CONTENT_SETTING_BLOCK;
    }
    map->SetContentSettingDefaultScope(url, url, type, setting);
  }

  void OpenNativeSettings() {
    LightNativeSettingsController::ShowForBrowser(browser());
  }

  void ActivateTabAt(int index) {
    SelectTabAt(index, /*extend_shift=*/false, /*toggle_cmd=*/false);
  }

  void SelectTabAt(int index, bool extend_shift, bool toggle_cmd) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(index)) {
      return;
    }
    if (extend_shift) {
      model->ExtendSelectionTo(index);
    } else if (toggle_cmd) {
      if (model->IsTabSelected(index)) {
        model->DeselectTabAt(index);
      } else {
        model->SelectTabAt(index);
      }
    } else {
      model->ActivateTabAt(
          index, TabStripUserGestureDetails(
                     TabStripUserGestureDetails::GestureType::kMouse));
    }
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  std::vector<int> GetTargetTabIndicesForContextMenu(int clicked_index) const {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return {clicked_index};
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(clicked_index)) {
      return {};
    }
    if (model->IsTabSelected(clicked_index)) {
      std::vector<int> selected;
      for (int i = 0; i < model->count(); ++i) {
        if (model->IsTabSelected(i)) {
          selected.push_back(i);
        }
      }
      if (!selected.empty()) {
        return selected;
      }
    }
    return {clicked_index};
  }

  void CloseSelectedTabs() {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    chrome::CloseTab(b);
  }

  void AddTabsToNewGroup(const std::vector<int>& indices) {
    BrowserWindowInterface* b = browser();
    if (!b || indices.empty()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->SupportsTabGroups()) {
      return;
    }
    std::vector<int> unpinned;
    for (int idx : indices) {
      if (!model->ContainsIndex(idx)) {
        continue;
      }
      if (model->IsTabPinned(idx)) {
        idx = model->SetTabPinned(idx, false);
      }
      unpinned.push_back(idx);
    }
    if (unpinned.empty()) {
      return;
    }
    tab_groups::TabGroupId gid = model->AddToNewGroup(unpinned);
    if (@available(macOS 26.0, *)) {
      [controller_ beginInlineRenameForGroupToken:base::SysUTF8ToNSString(
                                                      gid.ToString())];
    }
  }

  void AddTabsToGroupToken(const std::vector<int>& indices, NSString* nsToken) {
    BrowserWindowInterface* b = browser();
    auto gid = FindGroupByToken(nsToken);
    if (!b || !gid.has_value() || indices.empty()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model) {
      return;
    }
    std::vector<int> unpinned;
    for (int idx : indices) {
      if (!model->ContainsIndex(idx)) {
        continue;
      }
      if (model->IsTabPinned(idx)) {
        idx = model->SetTabPinned(idx, false);
      }
      unpinned.push_back(idx);
    }
    if (!unpinned.empty()) {
      model->AddToExistingGroup(unpinned, *gid, /*add_to_end=*/true);
    }
  }

  void RemoveTabsFromGroup(const std::vector<int>& indices) {
    BrowserWindowInterface* b = browser();
    if (!b || indices.empty()) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model) {
      model->RemoveFromGroup(indices);
    }
  }

  // Downloads integration:
  void ObserveDownloadItem(download::DownloadItem* item) {
    if (!item || observed_downloads_.contains(item)) {
      return;
    }
    item->AddObserver(this);
    observed_downloads_.insert(item);
  }

  void ClearObservedDownloads() {
    for (download::DownloadItem* item : observed_downloads_) {
      item->RemoveObserver(this);
    }
    observed_downloads_.clear();
  }

  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    ObserveDownloadItem(item);
    NotifyDownloadsUpdated();
  }

  void ManagerGoingDown(content::DownloadManager* manager) override {
    ClearObservedDownloads();
    if (download_manager_) {
      download_manager_->RemoveObserver(this);
      download_manager_ = nullptr;
    }
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    NotifyDownloadsUpdated();
  }

  void OnDownloadRemoved(download::DownloadItem* item) override {
    if (observed_downloads_.erase(item) > 0) {
      item->RemoveObserver(this);
    }
    NotifyDownloadsUpdated();
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    observed_downloads_.erase(item);
    NotifyDownloadsUpdated();
  }

  void NotifyDownloadsUpdated() {
    if (@available(macOS 26.0, *)) {
      if (controller_) {
        [controller_ downloadsDidUpdate];
      }
    }
  }

  void GetDownloadProgressSummary(bool* any_in_progress,
                                  CGFloat* aggregate_progress) const {
    *any_in_progress = false;
    *aggregate_progress = 0.0;
    if (!download_manager_) {
      return;
    }
    content::DownloadManager::DownloadVector items;
    download_manager_->GetAllDownloads(&items);
    int64_t received = 0;
    int64_t total = 0;
    int active_count = 0;
    for (download::DownloadItem* item : items) {
      if (!item || item->IsTransient() ||
          item->GetState() != download::DownloadItem::IN_PROGRESS) {
        continue;
      }
      *any_in_progress = true;
      active_count++;
      received += item->GetReceivedBytes();
      if (item->GetTotalBytes() > 0) {
        total += item->GetTotalBytes();
      }
    }
    if (*any_in_progress) {
      if (total > 0) {
        *aggregate_progress =
            std::clamp<CGFloat>(static_cast<CGFloat>(received) /
                                    static_cast<CGFloat>(total),
                                0.0, 1.0);
      } else {
        *aggregate_progress = active_count > 0 ? 0.25 : 0.0;
      }
    }
  }

  NSArray<LightDownloadEntry*>* GetRecentDownloads() const {
    NSMutableArray<LightDownloadEntry*>* out = [NSMutableArray array];
    if (!download_manager_) {
      return out;
    }
    content::DownloadManager::DownloadVector items;
    download_manager_->GetAllDownloads(&items);
    std::sort(items.begin(), items.end(),
              [](download::DownloadItem* a, download::DownloadItem* b) {
                return a->GetStartTime() > b->GetStartTime();
              });
    for (download::DownloadItem* item : items) {
      if (!item || item->IsTransient() ||
          hidden_download_ids_.contains(item->GetId())) {
        continue;
      }
      base::FilePath file_path = item->GetFileNameToReportUser();
      if (file_path.empty()) {
        file_path = item->GetTargetFilePath().BaseName();
      }
      std::string fname = file_path.AsUTF8Unsafe();
      if (fname.empty()) {
        fname = item->GetURL().ExtractFileName();
      }
      if (fname.empty()) {
        fname = "Download";
      }
      std::string ext = file_path.Extension();
      if (!ext.empty() && ext[0] == '.') {
        ext.erase(0, 1);
      }

      LightDownloadEntry* e = [[LightDownloadEntry alloc] init];
      e.downloadId = item->GetId();
      e.fileName = base::SysUTF8ToNSString(fname);
      e.fileExtension = base::SysUTF8ToNSString(ext);

      const auto state = item->GetState();
      if (state == download::DownloadItem::IN_PROGRESS) {
        e.inProgress = YES;
        int pct = item->PercentComplete();
        e.progress = pct >= 0 ? (static_cast<CGFloat>(pct) / 100.0) : 0.25;
        NSString* recvStr = FormatByteSize(item->GetReceivedBytes());
        if (item->GetTotalBytes() > 0) {
          e.statusText = [NSString
              stringWithFormat:@"%@ / %@  •  %d%%", recvStr,
                               FormatByteSize(item->GetTotalBytes()),
                               std::max(0, pct)];
        } else {
          e.statusText = [NSString stringWithFormat:@"%@ downloaded", recvStr];
        }
      } else if (state == download::DownloadItem::COMPLETE) {
        e.completed = YES;
        e.canOpen = !item->GetFileExternallyRemoved();
        e.progress = 1.0;
        e.statusText =
            item->GetFileExternallyRemoved()
                ? @"Removed"
                : [NSString stringWithFormat:@"%@  •  Done",
                                             FormatByteSize(item->GetReceivedBytes())];
      } else if (state == download::DownloadItem::CANCELLED) {
        e.statusText = @"Cancelled";
      } else {
        e.statusText = @"Interrupted";
      }
      [out addObject:e];
      if (out.count >= 25) {
        break;
      }
    }
    return out;
  }

  void OpenDownloadById(uint32_t download_id) {
    if (!download_manager_) {
      return;
    }
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      if (item->CanOpenDownload()) {
        item->OpenDownload();
      }
    }
  }

  void ShowDownloadInFolderById(uint32_t download_id) {
    if (!download_manager_) {
      return;
    }
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      item->ShowDownloadInShell();
    }
  }

  void CancelDownloadById(uint32_t download_id) {
    if (!download_manager_) {
      return;
    }
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) {
        item->Cancel(/*user_cancel=*/true);
      }
    }
  }

  void DeleteDownloadFileById(uint32_t download_id) {
    if (!download_manager_) {
      return;
    }
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) {
        item->Cancel(/*user_cancel=*/true);
      }
      if (item->GetState() == download::DownloadItem::COMPLETE &&
          !item->GetFileExternallyRemoved()) {
        item->DeleteFile(base::DoNothing());
      }
      hidden_download_ids_.insert(download_id);
      item->Remove();
      NotifyDownloadsUpdated();
    }
  }

  void RemoveDownloadFromListById(uint32_t download_id) {
    if (!download_manager_) {
      return;
    }
    hidden_download_ids_.insert(download_id);
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      if (item->GetState() != download::DownloadItem::IN_PROGRESS) {
        item->Remove();
      }
    }
    NotifyDownloadsUpdated();
  }

  NSString* GetDownloadUrlSpecById(uint32_t download_id) const {
    if (!download_manager_) {
      return nil;
    }
    if (download::DownloadItem* item =
            download_manager_->GetDownload(download_id)) {
      if (item->GetURL().is_valid()) {
        return base::SysUTF8ToNSString(item->GetURL().spec());
      }
    }
    return nil;
  }

  void DropTabAt(int from_index, bool target_pinned, int target_index) {
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (!model || !model->ContainsIndex(from_index)) {
      return;
    }
    int current_index = from_index;
    bool was_pinned = model->IsTabPinned(current_index);
    if (was_pinned != target_pinned) {
      if (target_pinned) {
        // Record pinned origin URL before pinning.
        if (content::WebContents* wc = model->GetWebContentsAt(current_index)) {
          const GURL& u = wc->GetVisibleURL();
          if (u.is_valid()) {
            pinned_origin_urls_[wc] = u;
          }
        }
      } else {
        if (content::WebContents* wc = model->GetWebContentsAt(current_index)) {
          pinned_origin_urls_.erase(wc);
        }
      }
      current_index = model->SetTabPinned(current_index, target_pinned);
    }

    int pinned_count = model->IndexOfFirstNonPinnedTab();
    int min_idx = target_pinned ? 0 : pinned_count;
    int max_idx = target_pinned ? std::max(0, pinned_count - 1)
                                : std::max(pinned_count, model->count() - 1);
    int clamped = std::clamp(target_index, min_idx, max_idx);
    if (clamped != current_index && model->ContainsIndex(clamped)) {
      model->MoveWebContentsAt(current_index, clamped, /*select_after_move=*/false);
    }
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void ClearCompletedDownloads() {
    if (!download_manager_) {
      return;
    }
    content::DownloadManager::DownloadVector items;
    download_manager_->GetAllDownloads(&items);
    for (download::DownloadItem* item : items) {
      if (item && item->GetState() != download::DownloadItem::IN_PROGRESS) {
        hidden_download_ids_.insert(item->GetId());
      }
    }
    NotifyDownloadsUpdated();
  }

  void OpenAllDownloadsPage() {
    if (BrowserWindowInterface* b = browser()) {
      NavigateParams params(b, GURL("chrome://downloads/"),
                            ui::PAGE_TRANSITION_LINK);
      params.disposition = WindowOpenDisposition::kNewForegroundTab;
      Navigate(&params);
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
    if (!model || !model->ContainsIndex(index)) {
      return;
    }
    tabs::TabInterface* tab = model->GetTabAtIndex(index);
    content::WebContents* wc = model->GetWebContentsAt(index);
    if (!tab || !wc) {
      return;
    }
    base::WeakPtr<content::WebContents> weak_wc = wc->GetWeakPtr();
    // Defer the actual close off the current NSEvent mouseUp: stack so removing
    // the clicked tab's NSView never destroys the view mid-dispatch, and route
    // through TabStripModelDelegate::CloseTab (Chromium's official close path).
    dispatch_async(dispatch_get_main_queue(), ^{
      BrowserWindowInterface* cur_b = this->browser();
      if (!cur_b || !weak_wc) {
        return;
      }
      TabStripModel* cur_model = cur_b->GetTabStripModel();
      if (!cur_model) {
        return;
      }
      int cur_idx = cur_model->GetIndexOfWebContents(weak_wc.get());
      if (cur_idx == TabStripModel::kNoTab) {
        return;
      }
      // Pinned tabs are persistent URL pins: closing them unloads the tab
      // while keeping the pin in place so clicking it loads it back up.
      if (cur_model->IsTabPinned(cur_idx)) {
        chrome::UnloadPinnedTab(cur_b, cur_idx);
        return;
      }
      tabs::TabInterface* cur_tab = cur_model->GetTabAtIndex(cur_idx);
      if (cur_tab && cur_model->delegate() && !weak_wc->IsCrashed()) {
        cur_model->delegate()->CloseTab(cur_tab, CloseTabSource::kFromMouse,
                                        base::DoNothing());
      } else {
        cur_model->CloseWebContentsAt(
            cur_idx, TabCloseTypes::CLOSE_USER_GESTURE |
                         TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
      }
    });
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
    model->ActivateTabAt(index);
    if (it != pinned_origin_urls_.end() && it->second.is_valid() &&
        wc->GetVisibleURL() != it->second) {
      NavigateParams params(b, it->second, ui::PAGE_TRANSITION_AUTO_BOOKMARK);
      params.disposition = WindowOpenDisposition::kCurrentTab;
      Navigate(&params);
    } else {
      // Already on the pinned origin URL -> reload it!
      wc->GetController().Reload(content::ReloadType::NORMAL,
                                 /*check_for_repost=*/true);
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
    if (!b) {
      return;
    }
    TabStripModel* model = b->GetTabStripModel();
    if (model && model->ContainsIndex(index)) {
      if (content::WebContents* wc = model->GetWebContentsAt(index)) {
        const std::string cid = LightGetTabContainerIdForWebContents(wc);
        if (!cid.empty()) {
          LightOpenNewTabInContainer(b, cid, wc->GetVisibleURL());
          return;
        }
      }
    }
    if (chrome::CanDuplicateTabAt(b, index)) {
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

  void NavigateToInput(const std::u16string& raw_input, bool new_tab = false) {
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
      Profile* profile = b->GetProfile();
      if (IsLikelyURLInput(utf8_input)) {
        // Resolve typed URLs directly without HistoryURLProvider hijacking
        // partial domains to unrelated history URLs.
        destination_url = url_formatter::FixupURL(utf8_input, std::string());
      } else {
        // Local default-search-engine fallback (zero remote suggest/telemetry).
        if (profile) {
          if (TemplateURLService* turl_service =
                  TemplateURLServiceFactory::GetForProfile(profile)) {
            GURL search_url =
                turl_service->GenerateSearchURLForDefaultSearchProvider(trimmed);
            if (search_url.is_valid()) {
              destination_url = search_url;
              transition = ui::PAGE_TRANSITION_GENERATED;
            }
          }
        }
      }
    }

    if (!destination_url.is_valid()) {
      destination_url = url_formatter::FixupURL(utf8_input, std::string());
    }
    if (!destination_url.is_valid()) {
      return;
    }

    NavigateParams params(b, destination_url, transition);
    params.disposition = new_tab ? WindowOpenDisposition::kNewForegroundTab
                                 : WindowOpenDisposition::kCurrentTab;
    if (new_tab && !LightNewTabInheritsActiveContainer()) {
      params.suppress_light_container_inheritance = true;
    }
    Navigate(&params);
    FocusActiveWebContents();
  }

  void StartSpotlightZeroSuggest() {
    if (!autocomplete_controller_) {
      return;
    }
    BrowserWindowInterface* b = browser();
    if (!b || !b->GetProfile()) {
      return;
    }
    last_autocomplete_query_.clear();
    AutocompleteInput input(
        std::u16string(), metrics::OmniboxEventProto::NTP,
        ChromeAutocompleteSchemeClassifier(b->GetProfile()));
    input.set_focus_type(metrics::OmniboxFocusType::INTERACTION_FOCUS);
    input.set_prevent_inline_autocomplete(true);
    autocomplete_controller_->Start(input);
  }

  void StartAutocomplete(const std::u16string& raw_text,
                         bool allow_zero_suggest = false) {
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
      if (allow_zero_suggest) {
        StartSpotlightZeroSuggest();
        return;
      }
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

  void OpenSuggestionItem(LightSuggestionItem* item, bool new_tab = false) {
    if (!item) {
      return;
    }
    BrowserWindowInterface* b = browser();
    if (!b) {
      return;
    }
    const WindowOpenDisposition disp =
        new_tab ? WindowOpenDisposition::kNewForegroundTab
                : WindowOpenDisposition::kCurrentTab;
    const bool suppressContainer =
        new_tab && !LightNewTabInheritsActiveContainer();
    if (item.directUrlSpec.length > 0) {
      GURL url(base::SysNSStringToUTF8(item.directUrlSpec));
      if (url.is_valid()) {
        NavigateParams params(b, url, ui::PAGE_TRANSITION_TYPED);
        params.disposition = disp;
        params.suppress_light_container_inheritance = suppressContainer;
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
          params.disposition = disp;
          params.suppress_light_container_inheritance = suppressContainer;
          Navigate(&params);
          FocusActiveWebContents();
          return;
        }
      }
    }
    if (item.fillIntoEdit.length > 0) {
      NavigateToInput(base::SysNSStringToUTF16(item.fillIntoEdit), new_tab);
    }
  }

  static std::string NormalizedHostKey(const GURL& url) {
    if (!url.is_valid()) {
      return std::string();
    }
    std::string h = base::ToLowerASCII(url.host());
    if (base::StartsWith(h, "www.", base::CompareCase::SENSITIVE) &&
        h.size() > 4) {
      h.erase(0, 4);
    }
    return h;
  }

  static NSCache<NSString*, NSImage*>* SuggestionFaviconCache() {
    static NSCache<NSString*, NSImage*>* cache = nil;
    if (!cache) {
      cache = [[NSCache alloc] init];
      cache.countLimit = 256;
    }
    return cache;
  }

  NSImage* LookupCachedFaviconSync(const GURL& page_url,
                                   const GURL& icon_url) {
    NSCache<NSString*, NSImage*>* cache = SuggestionFaviconCache();
    const std::string normHost = NormalizedHostKey(page_url);
    if (page_url.is_valid()) {
      NSString* exactKey = base::SysUTF8ToNSString(page_url.spec());
      if (NSImage* img = [cache objectForKey:exactKey]) {
        return img;
      }
      GURL origin = page_url.DeprecatedGetOriginAsURL();
      if (origin.is_valid()) {
        NSString* originKey = base::SysUTF8ToNSString(origin.spec());
        if (NSImage* img = [cache objectForKey:originKey]) {
          return img;
        }
      }
      if (!normHost.empty()) {
        NSString* hostKey =
            [NSString stringWithFormat:@"host:%@",
                                       base::SysUTF8ToNSString(normHost)];
        if (NSImage* img = [cache objectForKey:hostKey]) {
          return img;
        }
      }
    }
    if (icon_url.is_valid()) {
      NSString* iconKey = base::SysUTF8ToNSString(icon_url.spec());
      if (NSImage* img = [cache objectForKey:iconKey]) {
        return img;
      }
    }
    // Check live open tabs in this browser window for an instant match!
    if (BrowserWindowInterface* b = browser()) {
      TabStripModel* model = b->GetTabStripModel();
      const ui::ColorProvider* cp =
          browser_view_ ? browser_view_->GetColorProvider() : nullptr;
      if (model && cp && !normHost.empty()) {
        for (int i = 0; i < model->count(); ++i) {
          tabs::TabInterface* tab = model->GetTabAtIndex(i);
          if (!tab) {
            continue;
          }
          tabs::TabData td = tabs::TabData::FromTabInterface(tab);
          if (td.should_display_favicon && !td.favicon.IsEmpty() &&
              td.visible_url.is_valid() &&
              NormalizedHostKey(td.visible_url) == normHost) {
            gfx::ImageSkia skia = td.favicon.Rasterize(cp);
            if (!skia.isNull()) {
              if (NSImage* img = gfx::NSImageFromImageSkia(skia)) {
                [cache setObject:img
                          forKey:[NSString
                                     stringWithFormat:
                                         @"host:%@",
                                         base::SysUTF8ToNSString(normHost)]];
                return img;
              }
            }
          }
        }
      }
    }
    return nil;
  }

  static void StoreAndDeliverFavicon(
      __weak LightGlassSidebarObjCController* weakCtrl,
      const std::string& keyUtf8,
      const std::string& originKeyUtf8,
      const std::string& normHostUtf8,
      NSImage* img) {
    if (!img || !img.isValid || img.size.width <= 0) {
      return;
    }
    NSString* keyNS = base::SysUTF8ToNSString(keyUtf8);
    NSString* hostNS =
        normHostUtf8.empty() ? nil : base::SysUTF8ToNSString(normHostUtf8);
    NSCache<NSString*, NSImage*>* cache = SuggestionFaviconCache();
    if (keyNS.length > 0) {
      [cache setObject:img forKey:keyNS];
    }
    if (!originKeyUtf8.empty()) {
      NSString* originNS = base::SysUTF8ToNSString(originKeyUtf8);
      if (originNS.length > 0) {
        [cache setObject:img forKey:originNS];
      }
    }
    if (hostNS.length > 0) {
      [cache setObject:img
                forKey:[NSString stringWithFormat:@"host:%@", hostNS]];
    }
    if (@available(macOS 26.0, *)) {
      [weakCtrl applySuggestionFavicon:img forCacheKey:keyNS hostKey:hostNS];
    }
  }

  static void OnFaviconImageLoaded(
      __weak LightGlassSidebarObjCController* weakCtrl,
      std::string keyUtf8,
      std::string originKeyUtf8,
      std::string normHostUtf8,
      const favicon_base::FaviconImageResult& res) {
    if (res.image.IsEmpty()) {
      return;
    }
    gfx::ImageSkia skia = res.image.AsImageSkia();
    if (skia.isNull()) {
      return;
    }
    NSImage* img = gfx::NSImageFromImageSkia(skia);
    StoreAndDeliverFavicon(weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8, img);
  }

  static void OnFaviconRawBitmapLoaded(
      __weak LightGlassSidebarObjCController* weakCtrl,
      std::string keyUtf8,
      std::string originKeyUtf8,
      std::string normHostUtf8,
      const favicon_base::FaviconRawBitmapResult& res) {
    if (!res.is_valid() || !res.bitmap_data || res.bitmap_data->size() == 0) {
      return;
    }
    NSData* data = [NSData dataWithBytes:res.bitmap_data->data()
                                  length:res.bitmap_data->size()];
    NSImage* img = [[NSImage alloc] initWithData:data];
    StoreAndDeliverFavicon(weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8, img);
  }

  void RequestCachedFaviconAsync(Profile* profile,
                                 const GURL& page_url,
                                 const GURL& icon_url,
                                 NSString* cacheKey) {
    if (!profile || cacheKey.length == 0) {
      return;
    }
    favicon::FaviconService* fav_service = FaviconServiceFactory::GetForProfile(
        profile, ServiceAccessType::EXPLICIT_ACCESS);
    if (!fav_service) {
      return;
    }
    __weak LightGlassSidebarObjCController* weakCtrl = controller_;
    std::string keyUtf8 = base::SysNSStringToUTF8(cacheKey);
    std::string originKeyUtf8 =
        (page_url.is_valid() && page_url.DeprecatedGetOriginAsURL().is_valid())
            ? page_url.DeprecatedGetOriginAsURL().spec()
            : std::string();
    std::string normHostUtf8 = NormalizedHostKey(page_url);

    const favicon_base::IconTypeSet icon_types = {
        favicon_base::IconType::kFavicon, favicon_base::IconType::kTouchIcon,
        favicon_base::IconType::kTouchPrecomposedIcon};

    if (page_url.is_valid() && page_url.SchemeIsHTTPOrHTTPS()) {
      // Exact Omnibox FaviconCache API + host-fallback raw lookup (size 0 =
      // largest cached bitmap) + www/non-www alternate host fallback.
      fav_service->GetFaviconImageForPageURL(
          page_url,
          base::BindOnce(&LightGlassSidebarBridgeImpl::OnFaviconImageLoaded,
                         weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8),
          &favicon_task_tracker_);
      fav_service->GetRawFaviconForPageURL(
          page_url, icon_types, /*desired_size_in_pixel=*/0,
          /*fallback_to_host=*/true,
          base::BindOnce(&LightGlassSidebarBridgeImpl::OnFaviconRawBitmapLoaded,
                         weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8),
          &favicon_task_tracker_);

      std::string hostStr(page_url.host());
      if (!hostStr.empty()) {
        std::string altHost =
            base::StartsWith(hostStr, "www.", base::CompareCase::INSENSITIVE_ASCII)
                ? hostStr.substr(4)
                : ("www." + hostStr);
        GURL altOrigin("https://" + altHost + "/");
        if (altOrigin.is_valid()) {
          fav_service->GetRawFaviconForPageURL(
              altOrigin, icon_types, /*desired_size_in_pixel=*/0,
              /*fallback_to_host=*/true,
              base::BindOnce(
                  &LightGlassSidebarBridgeImpl::OnFaviconRawBitmapLoaded,
                  weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8),
              &favicon_task_tracker_);
        }
      }
    }
    if (icon_url.is_valid() && icon_url.SchemeIsHTTPOrHTTPS()) {
      fav_service->GetFaviconImage(
          icon_url,
          base::BindOnce(&LightGlassSidebarBridgeImpl::OnFaviconImageLoaded,
                         weakCtrl, keyUtf8, originKeyUtf8, normHostUtf8),
          &favicon_task_tracker_);
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
    Profile* active_profile = browser() ? browser()->GetProfile() : nullptr;

    // Prepend either the direct typed URL (when the user explicitly typed a
    // URL/localhost) or the local default-search-engine item so pressing Enter
    // NEVER snaps to an unselected history URL.
    const std::string qUtf8 = base::UTF16ToUTF8(last_autocomplete_query_);
    const std::string qLower = base::ToLowerASCII(qUtf8);
    const bool isLightSchemeQuery =
        base::StartsWith(qLower, "light:", base::CompareCase::SENSITIVE);
    if (!last_autocomplete_query_.empty() && IsLikelyURLInput(qUtf8) &&
        !isLightSchemeQuery) {
      GURL fixed_url = url_formatter::FixupURL(qUtf8, std::string());
      if (fixed_url.is_valid()) {
        LightSuggestionItem* urlItem = [[LightSuggestionItem alloc] init];
        urlItem.primaryText = base::SysUTF16ToNSString(last_autocomplete_query_);
        urlItem.secondaryText = @"Go to URL";
        urlItem.fillIntoEdit = urlItem.primaryText;
        urlItem.symbolName = @"globe";
        urlItem.directUrlSpec = base::SysUTF8ToNSString(fixed_url.spec());
        urlItem.matchIndex = -1;
        urlItem.accentIcon = YES;
        urlItem.isInlineTopCandidate = YES;
        if (fixed_url.SchemeIsHTTPOrHTTPS()) {
          NSString* key = base::SysUTF8ToNSString(fixed_url.spec());
          urlItem.faviconCacheKey = key;
          std::string urlHost = NormalizedHostKey(fixed_url);
          urlItem.faviconHostKey =
              urlHost.empty() ? nil : base::SysUTF8ToNSString(urlHost);
          if (NSImage* cached = LookupCachedFaviconSync(fixed_url, GURL())) {
            urlItem.favicon = cached;
          } else if (active_profile && key.length > 0) {
            RequestCachedFaviconAsync(active_profile, fixed_url, GURL(), key);
          }
        }
        [items addObject:urlItem];
      }
    } else if (!last_autocomplete_query_.empty() && !IsLikelyURLInput(qUtf8) &&
               !isLightSchemeQuery) {
      if (active_profile) {
        if (TemplateURLService* turl_service =
                TemplateURLServiceFactory::GetForProfile(active_profile)) {
          GURL search_url =
              turl_service->GenerateSearchURLForDefaultSearchProvider(
                  last_autocomplete_query_);
          if (search_url.is_valid()) {
            LightSuggestionItem* searchItem =
                [[LightSuggestionItem alloc] init];
            searchItem.primaryText =
                base::SysUTF16ToNSString(last_autocomplete_query_);
            const TemplateURL* defProvider =
                turl_service->GetDefaultSearchProvider();
            NSString* engineName =
                defProvider
                    ? base::SysUTF16ToNSString(defProvider->short_name())
                    : @"Web";
            searchItem.secondaryText =
                [NSString stringWithFormat:@"Search with %@", engineName];
            searchItem.fillIntoEdit = searchItem.primaryText;
            searchItem.symbolName = @"magnifyingglass";
            searchItem.directUrlSpec =
                base::SysUTF8ToNSString(search_url.spec());
            searchItem.matchIndex = -1;
            searchItem.accentIcon = YES;
            searchItem.isInlineTopCandidate = YES;
            searchItem.isSearchQuery = YES;

            GURL engineOrigin = search_url.DeprecatedGetOriginAsURL();
            GURL engineFavUrl =
                defProvider ? defProvider->favicon_url() : GURL();
            NSString* key =
                engineOrigin.is_valid()
                    ? base::SysUTF8ToNSString(engineOrigin.spec())
                    : (engineFavUrl.is_valid()
                           ? base::SysUTF8ToNSString(engineFavUrl.spec())
                           : nil);
            searchItem.faviconCacheKey = key;
            std::string engHost = NormalizedHostKey(engineOrigin);
            searchItem.faviconHostKey =
                engHost.empty() ? nil : base::SysUTF8ToNSString(engHost);
            if (NSImage* cached =
                    LookupCachedFaviconSync(engineOrigin, engineFavUrl)) {
              searchItem.favicon = cached;
            } else if (key.length > 0) {
              RequestCachedFaviconAsync(active_profile, engineOrigin,
                                        engineFavUrl, key);
            }
            [items addObject:searchItem];
          }
        }
      }
    }

    // Prepend matching built-in light:// pages only when explicitly typing
    // "light:..." (never when typing normal words starting with "l"/"light").
    if (isLightSchemeQuery) {
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
          it.isInlineTopCandidate = YES;
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
      // Strictly reject any AI / starter-pack / remote-generated search
      // suggestions so Cmd+T and the URL bar never show AI prompts.
      if (m.type == omnibox::AutocompleteMatchType::kStarterPack ||
          m.type == omnibox::AutocompleteMatchType::kFeaturedEnterpriseSearch ||
          m.type == omnibox::AutocompleteMatchType::kSearchSuggestPersonalized ||
          m.type == omnibox::AutocompleteMatchType::kSearchSuggestTail ||
          m.type == omnibox::AutocompleteMatchType::kSearchSuggestEntity ||
          m.type == omnibox::AutocompleteMatchType::kSearchSuggestProfile ||
          m.type == omnibox::AutocompleteMatchType::kHistoryCluster ||
          m.type == omnibox::AutocompleteMatchType::kVoiceSuggest ||
          m.type == omnibox::AutocompleteMatchType::kDocumentSuggestion ||
          m.type == omnibox::AutocompleteMatchType::kTileSuggestion ||
          m.type == omnibox::AutocompleteMatchType::kTileRepeatableQuery) {
        continue;
      }
      if (m.provider &&
          (m.provider->type() == AutocompleteProvider::Type::kZeroSuggest ||
           m.provider->type() == AutocompleteProvider::Type::kContextualSearch ||
           m.provider->type() == AutocompleteProvider::Type::kFeaturedSearch ||
           m.provider->type() == AutocompleteProvider::Type::kOnDeviceHead)) {
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
          if (m.type == omnibox::AutocompleteMatchType::kSearchWhatYouTyped &&
              m.destination_url.SchemeIsHTTPOrHTTPS()) {
            GURL engineOrigin = m.destination_url.DeprecatedGetOriginAsURL();
            NSString* key =
                engineOrigin.is_valid()
                    ? base::SysUTF8ToNSString(engineOrigin.spec())
                    : nil;
            it.faviconCacheKey = key;
            std::string engHost = NormalizedHostKey(engineOrigin);
            it.faviconHostKey =
                engHost.empty() ? nil : base::SysUTF8ToNSString(engHost);
            if (NSImage* cached =
                    LookupCachedFaviconSync(engineOrigin, GURL())) {
              it.favicon = cached;
            } else if (active_profile && key.length > 0) {
              RequestCachedFaviconAsync(active_profile, engineOrigin, GURL(),
                                        key);
            }
          }
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
        if (m.destination_url.SchemeIsHTTPOrHTTPS()) {
          NSString* key = base::SysUTF8ToNSString(m.destination_url.spec());
          it.faviconCacheKey = key;
          std::string urlHost = NormalizedHostKey(m.destination_url);
          it.faviconHostKey =
              urlHost.empty() ? nil : base::SysUTF8ToNSString(urlHost);
          if (NSImage* cached =
                  LookupCachedFaviconSync(m.destination_url, GURL())) {
            it.favicon = cached;
          } else if (active_profile && key.length > 0) {
            RequestCachedFaviconAsync(active_profile, m.destination_url, GURL(),
                                      key);
          }
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
    if (change.type() == TabStripModelChange::kRemoved) {
      if (BrowserWindowInterface* b = browser()) {
        if (Profile* profile = b->GetProfile()) {
          for (const auto& removed : change.GetRemove()->contents) {
            if (!removed.contents) {
              continue;
            }
            const std::string cid =
                LightGetTabContainerIdForWebContents(removed.contents);
            if (!cid.empty()) {
              auto container = LightFindTabContainer(cid);
              const bool clear_on_close =
                  container &&
                  container->clear_behavior ==
                      LightContainerClearBehavior::kOnAllTabsClosed;
              if (clear_on_close) {
                bool still_open = false;
                for (int i = 0; i < tab_strip_model->count(); ++i) {
                  if (LightGetTabContainerIdForWebContents(
                          tab_strip_model->GetWebContentsAt(i)) == cid) {
                    still_open = true;
                    break;
                  }
                }
                if (!still_open) {
                  LightClearTabContainerData(profile, cid);
                }
              }
            }
          }
        }
      }
    }
    if (selection.active_tab_changed()) {
      Observe(selection.new_contents);
      ObserveFindForWebContents(selection.new_contents);
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

  void OnTabCloseCancelled(tabs::TabHandle tab) override {
    if (@available(macOS 26.0, *)) {
      [controller_ reloadTabsAndNavigation];
    }
  }

  void OnTabStripModelDestroyed(TabStripModel* tab_strip_model) override {
    ObserveFindForWebContents(nullptr);
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
  raw_ptr<content::DownloadManager> download_manager_ = nullptr;
  std::unordered_set<download::DownloadItem*> observed_downloads_;
  std::unordered_set<uint32_t> hidden_download_ids_;
  std::unique_ptr<AutocompleteController> autocomplete_controller_;
  std::u16string last_autocomplete_query_;
  base::CancelableTaskTracker favicon_task_tracker_;
  raw_ptr<find_in_page::FindTabHelper> observed_find_helper_ = nullptr;
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
  NSMutableArray* __strong _layoutEntries;
  LightInlinePlusButtonView* __strong _inlinePlusButton;
  NSString* __strong _renamingGroupToken;

  NSBox* __strong _footerDivider;
  LightIconButton* __strong _settingsButton;
  LightIconButton* __strong _downloadsButton;

  // Liquid Glass Downloads popup anchored right of sidebar footer
  LightDownloadsOverlayPanel* __strong _downloadsPanel;
  NSGlassEffectView* __strong _downloadsGlassView;
  NSView* __strong _downloadsContent;
  NSScrollView* __strong _downloadsScrollView;
  LightFlippedDocumentView* __strong _downloadsDocView;
  NSTextField* __strong _downloadsEmptyLabel;
  NSButton* __strong _downloadsClearButton;
  NSButton* __strong _downloadsShowAllButton;
  BOOL _downloadsPopupOpen;

  // Spotlight / Raycast-style centered Liquid Glass Command/URL overlay (Cmd+T)
  LightSpotlightOverlayPanel* __strong _spotlightPanel;
  NSGlassEffectView* __strong _spotlightGlassView;
  LightExpandedUrlContentView* __strong _spotlightContent;
  NSImageView* __strong _spotlightIconView;
  LightAddressTextField* __strong _spotlightField;
  NSTextField* __strong _spotlightInlineHintLabel;
  LightSuggestionItem* __strong _spotlightInlineTopItem;
  LightIconButton* __strong _spotlightClearButton;
  NSBox* __strong _spotlightDivider;
  NSMutableArray<LightSuggestionRowView*>* __strong _spotlightSuggestionRows;
  NSArray<LightSuggestionItem*>* __strong _spotlightSuggestionItems;
  NSString* __strong _spotlightUserTyped;
  NSInteger _spotlightSelectedIndex;
  BOOL _spotlightActive;

  NSInteger _extensionPopupCount;
  NSMutableArray* __strong _menuBarExtTargets;
  BOOL _extensionsIconFilled;

  // Backmost glass darken/lighten layer (animates when overlay glass opens).
  CALayer* __strong _backmostTintLayer;
  BOOL _backmostTinted;

  // Sidebar edge resize handle (works in both pinned and compact modes).
  LightSidebarResizeHandleView* __strong _resizeHandleView;
  CGFloat _resizeDragStartScreenX;
  CGFloat _resizeDragStartWidth;
  BOOL _resizingSidebar;

  // Animated translucent app frame padding (1.0 = shown, 0.0 = hidden).
  CGFloat _framePaddingProgress;
  CGFloat _framePaddingTarget;
  CFTimeInterval _framePaddingAnimStart;
  CGFloat _framePaddingAnimFrom;
  NSTimer* __strong _framePaddingTimer;

  // Hover Trail ("Drift") controllers.
  LightHoverTrailController* __strong _urlBarHoverTrail;
  LightHoverTrailController* __strong _expandedUrlHoverTrail;
  LightHoverTrailController* __strong _tabHoverTrail;
  LightHoverTrailController* __strong _pinnedHoverTrail;
  LightHoverTrailController* __strong _downloadsHoverTrail;
  LightHoverTrailController* __strong _spotlightHoverTrail;
  LightHoverTrailController* __strong _extensionsHoverTrail;

  // Pinned-tile Extensions Liquid Glass popover.
  LightPopoverGlassPanel* __strong _extensionsPanel;
  NSGlassEffectView* __strong _extensionsGlassView;
  NSView* __strong _extensionsContent;
  BOOL _extensionsPopoverOpen;

  // Lock-icon Cert / Site Info Liquid Glass popover.
  LightPopoverGlassPanel* __strong _siteInfoPanel;
  NSGlassEffectView* __strong _siteInfoGlassView;
  NSView* __strong _siteInfoContent;
  BOOL _siteInfoPopoverOpen;

  // Native Liquid Glass Cmd+F Find-in-Page floating bar (top-right).
  NSGlassEffectView* __strong _findBarGlassView;
  LightFlippedDocumentView* __strong _findBarContent;
  NSImageView* __strong _findSearchIcon;
  LightAddressTextField* __strong _findField;
  NSTextField* __strong _findCountLabel;
  NSBox* __strong _findSep;
  LightIconButton* __strong _findPrevBtn;
  LightIconButton* __strong _findNextBtn;
  LightIconButton* __strong _findCloseBtn;
  BOOL _findBarVisible;
  NSUInteger _findBarAnimGen;

  // Physical Tab Drag-and-Drop (pick up tab + live reflow + Pin/Unpin morph).
  int _draggedTabIndex;
  BOOL _draggedFromPinned;
  NSView* __weak _dragSourceView;
  LightDragGhostView* __strong _dragGhostView;
  NSPoint _dragGrabOffset;
  BOOL _dragDropTargetPinned;
  int _dragOriginSlot;
  int _dragDropTargetSlot;
  int _dragDropTargetIndex;
  NSRect _dragPreviewSlotFrameInDoc;
  uintptr_t _recentlyDroppedPinnedWC;
  BOOL _recentlyDroppedPinnedWasSelected;

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
  NSInteger _openMenuCount;
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
    _layoutEntries = [NSMutableArray array];
    _suggestionRowViews = [NSMutableArray array];
    _suggestionItems = @[];
    _spotlightSuggestionRows = [NSMutableArray array];
    _spotlightSuggestionItems = @[];
    _spotlightUserTyped = @"";
    _spotlightSelectedIndex = -1;
    _userTypedAddressString = @"";
    _selectedSuggestionIndex = -1;
    _fullAddressString = @"";
    _displayAddressString = @"";
    _draggedTabIndex = -1;
    _pinned = !SidebarUDBool(@"LightSidebarAutoHide", true);
    _sidebarVisible = NO;
    _framePaddingProgress = [self shouldShowAppFramePadding] ? 1.0 : 0.0;
    _framePaddingTarget = _framePaddingProgress;
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
           selector:@selector(windowDidMoveNote:)
               name:NSWindowDidMoveNotification
             object:window];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(windowDidMoveNote:)
               name:NSWindowDidChangeScreenNotification
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
           selector:@selector(lightTabContainersDidChange:)
               name:@"LightTabContainersDidChangeNotification"
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
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(lightPermissionAsked:)
               name:@"LightPermissionAskedNotification"
             object:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s) {
        return;
      }
      [s hideNativeWindowFrameTrafficLights];
      CGFloat initPad = [s shouldShowAppFramePadding] ? 1.0 : 0.0;
      s->_framePaddingProgress = initPad;
      s->_framePaddingTarget = initPad;
      [s layoutOuterGlassGeometryForce:YES];
      if (s->_bridge) {
        s->_bridge->InvalidateBrowserLayout();
      }
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
  [_framePaddingTimer invalidate];
  _framePaddingTimer = nil;
  [_urlBarHoverTrail teardown];
  _urlBarHoverTrail = nil;
  [_expandedUrlHoverTrail teardown];
  _expandedUrlHoverTrail = nil;
  [_tabHoverTrail teardown];
  _tabHoverTrail = nil;
  [_pinnedHoverTrail teardown];
  _pinnedHoverTrail = nil;
  [_downloadsHoverTrail teardown];
  _downloadsHoverTrail = nil;
  [_spotlightHoverTrail teardown];
  _spotlightHoverTrail = nil;
  [_extensionsHoverTrail teardown];
  _extensionsHoverTrail = nil;
  [self dismissSpotlight];
  if (_spotlightPanel) {
    [_spotlightPanel orderOut:nil];
    _spotlightPanel = nil;
  }
  [self dismissDownloadsPopup];
  if (_downloadsPanel) {
    [_downloadsPanel orderOut:nil];
    _downloadsPanel = nil;
  }
  [self dismissExtensionsPopover];
  if (_extensionsPanel) {
    [_extensionsPanel orderOut:nil];
    _extensionsPanel = nil;
  }
  [self dismissSiteInfoPopover];
  if (_siteInfoPanel) {
    [_siteInfoPanel orderOut:nil];
    _siteInfoPanel = nil;
  }
  [_dragGhostView removeFromSuperview];
  _dragGhostView = nil;
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
  return kDefaultHoverEdgeTriggerWidth;
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
  if (_spotlightGlassView) {
    _spotlightGlassView.style = glassStyle;
  }
  if (_downloadsGlassView) {
    _downloadsGlassView.style = glassStyle;
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
  if (_spotlightGlassView &&
      [_spotlightGlassView respondsToSelector:adaptiveSel]) {
    [_spotlightGlassView setValue:@(adaptiveVal)
                           forKey:@"_adaptiveAppearance"];
  }
  if (_downloadsGlassView &&
      [_downloadsGlassView respondsToSelector:adaptiveSel]) {
    [_downloadsGlassView setValue:@(adaptiveVal)
                           forKey:@"_adaptiveAppearance"];
  }

  if (@available(macOS 27.0, *)) {
    BOOL interactive = SidebarUDBool(@"LightSidebarGlassInteractive", true);
    _glassView.effectIsInteractive = interactive;
    if (_expandedUrlGlassView) {
      _expandedUrlGlassView.effectIsInteractive = interactive;
    }
    if (_spotlightGlassView) {
      _spotlightGlassView.effectIsInteractive = interactive;
    }
    if (_downloadsGlassView) {
      _downloadsGlassView.effectIsInteractive = interactive;
    }
    if (_extensionsGlassView) {
      _extensionsGlassView.effectIsInteractive = interactive;
    }
    if (_siteInfoGlassView) {
      _siteInfoGlassView.effectIsInteractive = interactive;
    }
  }

  CGFloat tintAlphaPct = std::clamp<CGFloat>(
      SidebarUDDouble(@"LightSidebarTintAlpha", 4.0), 0.0, 100.0);
  const bool darkMode = IsViewDarkAppearance(_overlayView ?: _glassView);
  if (tintAlphaPct <= 0.1) {
    _glassView.tintColor = nil;
    if (_expandedUrlGlassView) {
      _expandedUrlGlassView.tintColor = nil;
    }
    if (_spotlightGlassView) {
      _spotlightGlassView.tintColor =
          darkMode ? [NSColor colorWithSRGBRed:0.03 green:0.03 blue:0.05 alpha:0.46]
                   : [NSColor colorWithWhite:0.95 alpha:0.54];
    }
    if (_findBarGlassView) {
      _findBarGlassView.tintColor =
          darkMode ? [NSColor colorWithSRGBRed:0.04 green:0.04 blue:0.06 alpha:0.38]
                   : [NSColor colorWithWhite:0.96 alpha:0.46];
    }
    if (_downloadsGlassView) {
      _downloadsGlassView.tintColor =
          [NSColor colorWithWhite:1.0 alpha:0.04];
    }
    if (_extensionsGlassView) {
      _extensionsGlassView.tintColor =
          [NSColor colorWithWhite:1.0 alpha:0.04];
    }
    if (_siteInfoGlassView) {
      _siteInfoGlassView.tintColor =
          [NSColor colorWithWhite:1.0 alpha:0.04];
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
    if (_spotlightGlassView) {
      // Slightly dimmer overlay tint so Spotlight stays crisp over web content.
      NSColor* baseDim =
          darkMode ? [NSColor colorWithSRGBRed:0.03 green:0.03 blue:0.05 alpha:0.46]
                   : [NSColor colorWithWhite:0.95 alpha:0.54];
      NSColor* userTint =
          [NSColor colorWithSRGBRed:tr
                              green:tg
                               blue:tb
                              alpha:std::min<CGFloat>(0.85, alpha + 0.14)];
      _spotlightGlassView.tintColor =
          [baseDim blendedColorWithFraction:0.35 ofColor:userTint] ?: baseDim;
    }
    if (_findBarGlassView) {
      _findBarGlassView.tintColor =
          darkMode ? [NSColor colorWithSRGBRed:0.04 green:0.04 blue:0.06 alpha:0.38]
                   : [NSColor colorWithWhite:0.96 alpha:0.46];
    }
    if (_downloadsGlassView) {
      _downloadsGlassView.tintColor =
          [NSColor colorWithSRGBRed:tr
                              green:tg
                               blue:tb
                              alpha:std::min<CGFloat>(0.90, alpha + 0.03)];
    }
    if (_extensionsGlassView) {
      _extensionsGlassView.tintColor =
          [NSColor colorWithSRGBRed:tr
                              green:tg
                               blue:tb
                              alpha:std::min<CGFloat>(0.90, alpha + 0.03)];
    }
    if (_siteInfoGlassView) {
      _siteInfoGlassView.tintColor =
          [NSColor colorWithSRGBRed:tr
                              green:tg
                               blue:tb
                              alpha:std::min<CGFloat>(0.90, alpha + 0.03)];
    }
  }

  // Sidebar drop shadow removed entirely per Light design.
  _glassView.shadow = nil;
  [self updateBackmostOverlayTintAnimated:NO];
}

- (void)buildViewHierarchy {
  NSView* root = _window.contentView;
  if (!root) {
    return;
  }
  root.layerUsesCoreImageFilters = YES;

  _overlayView = [[LightSidebarPassthroughView alloc] initWithFrame:root.bounds];
  _overlayView.identifier = @"LightGlassSidebarOverlay";
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

  _backmostTintLayer = [CALayer layer];
  _backmostTintLayer.zPosition = 999.0;
  _backmostTintLayer.opacity = 0.0f;
  _backmostTintLayer.masksToBounds = YES;
  _backmostTintLayer.cornerCurve = kCACornerCurveContinuous;
  [_contentView.layer addSublayer:_backmostTintLayer];

  _overlayView.glassPanel = _glassView;
  _overlayView.sidebarContentView = _contentView;
  [_slideHostView addSubview:_glassView];
  [_overlayView addSubview:_slideHostView];

  __weak __typeof(self) weakSelf = self;
  _resizeHandleView =
      [[LightSidebarResizeHandleView alloc] initWithFrame:NSZeroRect];
  _resizeHandleView.hidden = YES;
  _resizeHandleView.onDragWidthDelta =
      ^(CGFloat screenX, BOOL started, BOOL ended) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s) {
          return;
        }
        if (started) {
          s->_resizingSidebar = YES;
          s->_resizeDragStartScreenX = screenX;
          s->_resizeDragStartWidth = [s currentSidebarWidth];
          return;
        }
        CGFloat delta = screenX - s->_resizeDragStartScreenX;
        CGFloat newW = std::clamp<CGFloat>(
            std::round(s->_resizeDragStartWidth + delta), 180.0, 360.0);
        [NSUserDefaults.standardUserDefaults setDouble:newW
                                                forKey:@"LightSidebarWidth"];
        [s layoutOuterGlassGeometryForce:YES];
        if (s->_pinned && s->_bridge) {
          s->_bridge->InvalidateBrowserLayout();
        }
        if (ended) {
          s->_resizingSidebar = NO;
          [NSNotificationCenter.defaultCenter
              postNotificationName:@"LightSettingsDidChangeNotification"
                            object:nil];
          if (![s isSidebarLockedOpen] && s->_sidebarVisible) {
            [s ensureHoverWatchTimerRunning];
          }
        }
      };
  _overlayView.resizeHandleView = _resizeHandleView;
  [_overlayView addSubview:_resizeHandleView
                positioned:NSWindowAbove
                relativeTo:_slideHostView];

  [root addSubview:_overlayView positioned:NSWindowAbove relativeTo:nil];
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
  _addressContainer.onSecurityIconClick = ^{
    [weakSelf toggleSiteInfoPopover];
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
    [weakSelf toggleExtensionsPopover];
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
  _scrollView.automaticallyAdjustsContentInsets = NO;
  _scrollView.contentView.automaticallyAdjustsContentInsets = NO;

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
  _inlinePlusButton =
      [[LightInlinePlusButtonView alloc] initWithFrame:NSZeroRect];
  _inlinePlusButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s) {
      [s showSpotlightCommandBar];
    }
  };
  _inlinePlusButton.menuProvider = ^NSMenu* {
    return [weakSelf buildInlinePlusContextMenu];
  };
  [_tabsDocumentView addSubview:_inlinePlusButton];
  _scrollView.documentView = _tabsDocumentView;
  [_contentView addSubview:_scrollView];

  _urlBarHoverTrail =
      [[LightHoverTrailController alloc] initWithContainerView:_contentView];
  _urlBarHoverTrail.cornerRadius = 10.0;
  _urlBarHoverTrail.hoverAlpha = 0.06;
  _urlBarHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return (s && s->_addressContainer && !s->_addressContainer.isHidden)
               ? @[ s->_addressContainer ]
               : @[];
  };
  _urlBarHoverTrail.isRowSelected = ^BOOL(NSView* row) {
    (void)row;
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? s->_editingAddress : NO;
  };

  _expandedUrlHoverTrail = [[LightHoverTrailController alloc]
      initWithContainerView:_expandedUrlContent];
  _expandedUrlHoverTrail.cornerRadius = 8.0;
  _expandedUrlHoverTrail.hoverAlpha = 0.09;
  _expandedUrlHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_suggestionRowViews : @[];
  };
  _expandedUrlHoverTrail.isRowSelected = ^BOOL(NSView* row) {
    if ([row isKindOfClass:[LightSuggestionRowView class]]) {
      return ((LightSuggestionRowView*)row).keyboardSelected;
    }
    return NO;
  };

  _tabHoverTrail = [[LightHoverTrailController alloc]
      initWithScrollView:_scrollView
            documentView:_tabsDocumentView];
  _tabHoverTrail.cornerRadius = 9.0;
  _tabHoverTrail.hoverAlpha = 0.08;
  _tabHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_tabRowViews : @[];
  };
  _tabHoverTrail.isRowSelected = ^BOOL(NSView* row) {
    if ([row isKindOfClass:[LightTabRowView class]]) {
      LightTabRowView* tabRow = (LightTabRowView*)row;
      return tabRow.selected || tabRow.multiSelected;
    }
    return NO;
  };

  _pinnedHoverTrail = [[LightHoverTrailController alloc]
      initWithScrollView:_scrollView
            documentView:_tabsDocumentView];
  _pinnedHoverTrail.cornerRadius = 10.0;
  _pinnedHoverTrail.hoverAlpha = 0.12;
  _pinnedHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_pinnedTileViews : @[];
  };
  _pinnedHoverTrail.isRowSelected = ^BOOL(NSView* row) {
    if ([row isKindOfClass:[LightPinnedTileView class]]) {
      LightPinnedTileView* tile = (LightPinnedTileView*)row;
      return tile.selected || tile.multiSelected;
    }
    return NO;
  };

  // Compact footer: Settings on left, Downloads on right.
  _footerDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
  _footerDivider.boxType = NSBoxCustom;
  _footerDivider.borderWidth = 0.0;
  _footerDivider.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
  [_contentView addSubview:_footerDivider];

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

  _downloadsButton = [[LightIconButton alloc]
      initWithSymbol:@"arrow.down.circle"
           pointSize:14.0
              weight:NSFontWeightMedium
             toolTip:@"Downloads"];
  _downloadsButton.actionBlock = ^{
    [weakSelf toggleDownloadsPopup];
  };
  [_contentView addSubview:_downloadsButton];

  [self applyGlassMaterialSettings];
  [self layoutOuterGlassGeometryForce:YES];
  [self setSidebarVisible:_pinned animated:NO];
}

- (void)hideNativeWindowFrameTrafficLights {
  if (!_window) {
    return;
  }
  _window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
  if ([self isWindowFullScreen]) {
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

- (BOOL)isWindowFillingScreen {
  if (!_window) {
    return NO;
  }
  if ([self isWindowFullScreen]) {
    return YES;
  }
  NSScreen* scr = _window.screen ?: NSScreen.mainScreen;
  if (!scr) {
    return NO;
  }
  NSRect winF = _window.frame;
  NSRect vf = scr.visibleFrame;
  NSRect sf = scr.frame;
  const BOOL fillsVisible =
      std::abs(winF.size.width - vf.size.width) <= 4.0 &&
      std::abs(winF.size.height - vf.size.height) <= 4.0 &&
      std::abs(NSMinX(winF) - NSMinX(vf)) <= 4.0 &&
      std::abs(NSMinY(winF) - NSMinY(vf)) <= 4.0;
  const BOOL fillsFull =
      std::abs(winF.size.width - sf.size.width) <= 4.0 &&
      std::abs(winF.size.height - sf.size.height) <= 4.0;
  return fillsVisible || fillsFull;
}

- (BOOL)shouldShowAppFramePadding {
  return _pinned || ![self isWindowFillingScreen];
}

- (gfx::Insets)currentContentFrameInsets {
  const int pad = static_cast<int>(
      std::lround(kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0)));
  if (_pinned) {
    const int sideW = static_cast<int>(std::lround([self currentSidebarWidth]));
    return gfx::Insets::TLBR(pad, sideW + pad * 2, pad, pad);
  }
  if (pad <= 0) {
    return gfx::Insets();
  }
  return gfx::Insets::TLBR(pad, pad, pad, pad);
}

- (void)animateAppFramePaddingToTarget {
  CGFloat target = [self shouldShowAppFramePadding] ? 1.0 : 0.0;
  if (std::abs(_framePaddingTarget - target) < 0.001 &&
      std::abs(_framePaddingProgress - target) < 0.001) {
    return;
  }
  _framePaddingTarget = target;
  _framePaddingAnimFrom = _framePaddingProgress;
  _framePaddingAnimStart = CACurrentMediaTime();
  if (!_framePaddingTimer) {
    __weak __typeof(self) weakSelf = self;
    _framePaddingTimer = [NSTimer
        scheduledTimerWithTimeInterval:(1.0 / 60.0)
                               repeats:YES
                                 block:^(NSTimer* timer) {
                                   [weakSelf tickAppFramePaddingAnimation];
                                 }];
  }
}

- (void)tickAppFramePaddingAnimation {
  const CFTimeInterval kDur =
      (_framePaddingTarget < _framePaddingAnimFrom) ? 0.13 : 0.17;
  CFTimeInterval elapsed = CACurrentMediaTime() - _framePaddingAnimStart;
  CGFloat t = std::clamp<CGFloat>(elapsed / kDur, 0.0, 1.0);
  // Cubic ease-out matching window corner animation smoothness.
  CGFloat eased = 1.0 - std::pow(1.0 - t, 3.0);
  _framePaddingProgress =
      _framePaddingAnimFrom + (_framePaddingTarget - _framePaddingAnimFrom) * eased;
  [self layoutOuterGlassGeometryForce:YES];
  if (_bridge) {
    _bridge->InvalidateBrowserLayout();
  }
  if (t >= 1.0) {
    _framePaddingProgress = _framePaddingTarget;
    [_framePaddingTimer invalidate];
    _framePaddingTimer = nil;
    [self layoutOuterGlassGeometryForce:YES];
    if (_bridge) {
      _bridge->InvalidateBrowserLayout();
    }
  }
}

- (void)syncBackmostTintLayerHosting {
  if (!_backmostTintLayer || !_contentView || !_slideHostView) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (_pinned) {
    // Dim/lighten the ENTIRE background window smoothly (below overlays, no
    // cut-off seam on the left!).
    if (_backmostTintLayer.superlayer != _slideHostView.layer) {
      [_backmostTintLayer removeFromSuperlayer];
      if (_expandedUrlGlassView && _expandedUrlGlassView.layer &&
          _expandedUrlGlassView.layer.superlayer == _slideHostView.layer) {
        [_slideHostView.layer insertSublayer:_backmostTintLayer
                                       below:_expandedUrlGlassView.layer];
      } else {
        [_slideHostView.layer addSublayer:_backmostTintLayer];
      }
    }
    _backmostTintLayer.zPosition = 0.0;
    if (_expandedUrlGlassView && _expandedUrlGlassView.layer) {
      _expandedUrlGlassView.layer.zPosition = 100.0;
    }
    _backmostTintLayer.frame = _slideHostView.bounds;
    _backmostTintLayer.cornerRadius = 0.0;
  } else {
    if (_backmostTintLayer.superlayer != _contentView.layer) {
      [_backmostTintLayer removeFromSuperlayer];
      [_contentView.layer addSublayer:_backmostTintLayer];
    }
    _backmostTintLayer.zPosition = 999.0;
    _backmostTintLayer.frame = _contentView.bounds;
    _backmostTintLayer.cornerRadius = _glassView.cornerRadius;
  }
  [CATransaction commit];
}

- (void)updateBackmostOverlayTintAnimated:(BOOL)animated {
  if (!_backmostTintLayer || !_glassView) {
    return;
  }
  [self syncBackmostTintLayerHosting];
  const BOOL shouldTint =
      _editingAddress || _downloadsPopupOpen || _extensionsPopoverOpen ||
      _siteInfoPopoverOpen || _extensionPopupCount > 0;
  const bool dark = IsViewDarkAppearance(_overlayView ?: _glassView);
  // Glass-on-glass depth separation: darken backmost glass in Dark Mode,
  // lighten backmost glass in Light Mode.
  CGColorRef targetColor =
      dark ? [NSColor colorWithSRGBRed:0.0 green:0.0 blue:0.0 alpha:0.24].CGColor
           : [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.28].CGColor;

  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:shouldTint ? 0.18 : 0.15];
    [CATransaction
        setAnimationTimingFunction:[CAMediaTimingFunction
                                       functionWithName:
                                           kCAMediaTimingFunctionEaseInEaseOut]];
  }
  _backmostTintLayer.backgroundColor = targetColor;
  _backmostTintLayer.opacity = shouldTint ? 1.0f : 0.0f;
  [CATransaction commit];
  _backmostTinted = shouldTint;
}

- (void)windowDidChangeFullScreen:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  [self animateAppFramePaddingToTarget];
  [self layoutOuterGlassGeometryForce:YES];
}

- (void)windowKeyStateDidChange:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  if (!_window.isKeyWindow) {
    [_urlBarHoverTrail cancelAllAnimated:NO];
    [_expandedUrlHoverTrail cancelAllAnimated:NO];
    [_tabHoverTrail cancelAllAnimated:NO];
    [_pinnedHoverTrail cancelAllAnimated:NO];
    if (_trafficLightsGroup.isConfirmingQuit) {
      [_trafficLightsGroup dismissConfirmQuitPillAnimated:YES];
    }
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
  [self animateAppFramePaddingToTarget];
  [self layoutOuterGlassGeometryForce:NO];
  LightLogSidebarDiag("SIDEBAR-LIVERESIZE-END", _window, NSZeroPoint,
                      _sidebarVisible);
}

- (void)windowDidResizeNote:(NSNotification*)note {
  [self hideNativeWindowFrameTrafficLights];
  [self animateAppFramePaddingToTarget];
  LightLogSidebarDiag("SIDEBAR-WIN-RESIZE", _window, NSZeroPoint,
                      _sidebarVisible);
}

- (void)windowDidMoveNote:(NSNotification*)note {
  [self animateAppFramePaddingToTarget];
}

- (BOOL)isSidebarLockedOpen {
  return _pinned || _editingAddress || _renamingGroupToken.length > 0 ||
         _openMenuCount > 0 || _trafficLightsGroup.isConfirmingQuit ||
         _settingsPreviewForceOpen || _extensionPopupCount > 0 ||
         _downloadsPopupOpen || _extensionsPopoverOpen ||
         _siteInfoPopoverOpen || _spotlightActive || _draggedTabIndex >= 0 ||
         _resizingSidebar;
}

- (void)contextMenuDidBeginTracking:(NSNotification*)note {
  _openMenuCount += 1;
  if (_siteInfoPanel) {
    _siteInfoPanel.suppressResignDismiss = YES;
  }
}

- (void)contextMenuDidEndTracking:(NSNotification*)note {
  if (_openMenuCount > 0) {
    _openMenuCount -= 1;
  }
  if (_siteInfoPanel) {
    _siteInfoPanel.suppressResignDismiss = NO;
  }
  if (![self isSidebarLockedOpen] && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

- (void)lightPermissionAsked:(NSNotification*)note {
  NSString* origin = note.userInfo[@"origin"];
  NSNumber* typeNum = note.userInfo[@"type"];
  if (origin.length > 0 && typeNum) {
    GURL gurl(base::SysNSStringToUTF8(origin));
    if (gurl.is_valid()) {
      AskedSitePermissionsByOrigin()[gurl.DeprecatedGetOriginAsURL().spec()]
          .insert(typeNum.intValue);
    }
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
  } else if (![self isSidebarLockedOpen] &&
             ![self isCursorInLeftTriggerOrSidebar]) {
    [self setSidebarVisible:NO animated:YES];
  }
}

- (void)lightTabContainersDidChange:(NSNotification*)note {
  [self reloadTabsAndNavigation];
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
  [self animateAppFramePaddingToTarget];
  [self layoutOuterGlassGeometryForce:YES];
  if (_bridge) {
    _bridge->InvalidateBrowserLayout();
  }
  if ([self isSidebarLockedOpen] && !_sidebarVisible) {
    [self setSidebarVisible:YES animated:YES];
  } else if (![self isSidebarLockedOpen] && _sidebarVisible &&
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

  const NSEventType evType = event.type;

  // Forward hover trail pointer tracking & clean non-pointer cancellation.
  if (evType == NSEventTypeMouseMoved) {
    NSPoint scrPt = NSEvent.mouseLocation;
    if (event.window == _window && _sidebarVisible && _draggedTabIndex < 0) {
      if (_editingAddress && _expandedUrlGlassView &&
          !_expandedUrlGlassView.isHidden) {
        [_expandedUrlHoverTrail handleMouseMovedInWindow:event.locationInWindow];
      } else {
        [_urlBarHoverTrail handleMouseMovedInWindow:event.locationInWindow];
        [_tabHoverTrail handleMouseMovedInWindow:event.locationInWindow];
        [_pinnedHoverTrail handleMouseMovedInWindow:event.locationInWindow];
      }
    }
    if (_downloadsPopupOpen && _downloadsPanel) {
      NSPoint dlPt = [_downloadsPanel convertPointFromScreen:scrPt];
      [_downloadsHoverTrail handleMouseMovedInWindow:dlPt];
    }
    if (_spotlightActive && _spotlightPanel) {
      NSPoint spPt = [_spotlightPanel convertPointFromScreen:scrPt];
      [_spotlightHoverTrail handleMouseMovedInWindow:spPt];
    }
    if (_extensionsPopoverOpen && _extensionsPanel) {
      NSPoint extPt = [_extensionsPanel convertPointFromScreen:scrPt];
      [_extensionsHoverTrail handleMouseMovedInWindow:extPt];
    }
  } else if (evType == NSEventTypeScrollWheel || evType == NSEventTypeKeyDown ||
             evType == NSEventTypeLeftMouseDown ||
             evType == NSEventTypeRightMouseDown ||
             evType == NSEventTypeOtherMouseDown) {
    [_urlBarHoverTrail cancelAllAnimated:NO];
    [_expandedUrlHoverTrail cancelAllAnimated:NO];
    [_tabHoverTrail cancelAllAnimated:NO];
    [_pinnedHoverTrail cancelAllAnimated:NO];
    [_downloadsHoverTrail cancelAllAnimated:NO];
    [_spotlightHoverTrail cancelAllAnimated:NO];
    [_extensionsHoverTrail cancelAllAnimated:NO];
  }

  // Fast-cancel Confirm Quit if the user interacts with the browser in any way
  // (clicks anywhere outside the red Confirm pill, scrolls, or presses any key
  // other than Cmd+Q).
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
  } else if (![self isSidebarLockedOpen]) {
    // Only auto-close when cursor is INSIDE the window and crosses onto the
    // web page.
    if ([NSEvent pressedMouseButtons] == 0 &&
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
  if (_inLiveResize || _window.inLiveResize || [self isSidebarLockedOpen] ||
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

- (void)syncContentViewHostingForPinnedState {
  if (!_slideHostView || !_glassView || !_contentView) {
    return;
  }
  if (_pinned) {
    // In pinned mode, tab elements sit directly on the window's behind-window
    // glass — no second floating NSGlassEffectView card on top!
    if (_contentView.superview != _slideHostView) {
      _glassView.contentView = nil;
      // NSGlassEffectView sets translatesAutoresizingMaskIntoConstraints = NO
      // when hosting its contentView; restore YES so manual frame layout works
      // and _contentView doesn't collapse to 0x0!
      _contentView.translatesAutoresizingMaskIntoConstraints = YES;
      _contentView.autoresizingMask = 0;
      if (_expandedUrlGlassView && _expandedUrlGlassView.superview == _slideHostView) {
        [_slideHostView addSubview:_contentView
                        positioned:NSWindowBelow
                        relativeTo:_expandedUrlGlassView];
      } else {
        [_slideHostView addSubview:_contentView];
      }
      _glassView.hidden = YES;
      _contentView.hidden = !_sidebarVisible;
      _contentView.alphaValue = 1.0;
      _contentView.layer.opacity = 1.0f;
      _contentView.layer.filters = nil;
    }
  } else {
    if (_glassView.contentView != _contentView) {
      [_contentView removeFromSuperview];
      _contentView.translatesAutoresizingMaskIntoConstraints = YES;
      _contentView.hidden = NO;
      _contentView.alphaValue = 1.0;
      _contentView.layer.opacity = 1.0f;
      _contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      _glassView.contentView = _contentView;
      _glassView.hidden = !_sidebarVisible;
    }
  }
  [self syncBackmostTintLayerHosting];
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
  if (_resizeHandleView) {
    _resizeHandleView.hidden = !visible;
  }
  NSUInteger gen = ++_visibilityGeneration;
  LightLogSidebarDiag(visible ? "SIDEBAR-SHOW" : "SIDEBAR-HIDE", _window,
                      NSZeroPoint, visible, animated ? "anim=1" : "anim=0");

  if (visible && !_pinned) {
    [self ensureHoverWatchTimerRunning];
  } else if (!visible) {
    [_hoverWatchTimer invalidate];
    _hoverWatchTimer = nil;
  }

  [self syncContentViewHostingForPinnedState];
  NSView* activeHost = _pinned ? (NSView*)_contentView : (NSView*)_glassView;

  const CGFloat targetX = visible ? 0.0 : [self closedTranslationX];
  const CGFloat hiddenBlur = [self currentBlurRadius];
  const CGFloat targetBlur = visible ? 0.0 : hiddenBlur;
  constexpr float kClosedContentOpacity = 0.68f;
  const float targetOpacity = visible ? 1.0f : kClosedContentOpacity;

  const BOOL wasHidden = activeHost.isHidden;
  const BOOL reattachedFromUnblurred =
      [self ensureBlurFilterAttachedWithRadius:(wasHidden ? hiddenBlur : 0.0)];

  if (visible && wasHidden) {
    [self layoutOuterGlassGeometryForce:NO];
    activeHost.hidden = NO;
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
    activeHost.hidden = !visible;
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
        if (self->_pinned) {
          self->_contentView.hidden = YES;
        } else {
          self->_glassView.hidden = YES;
        }
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
  if (!_overlayView || !_glassView || !_contentView) {
    return;
  }
  [self syncContentViewHostingForPinnedState];

  // Avoid resizing NSGlassEffectView's backdrop/SDF/shadow on every pixel of
  // vertical live resize when the sidebar is completely hidden off-screen.
  if (!force && !_sidebarVisible && (_inLiveResize || _window.inLiveResize)) {
    return;
  }
  const CGFloat pad =
      std::round(kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0));
  _overlayView.appFramePadding = pad;

  const BOOL pinnedMode = _pinned;
  const CGFloat targetRadius =
      pinnedMode ? 0.0 : [self currentSidebarCornerRadius];
  const BOOL radiusChanged =
      std::abs(_glassView.cornerRadius - targetRadius) > 0.01;
  if (radiusChanged) {
    _glassView.cornerRadius = targetRadius;
  }

  NSRect bounds = _overlayView.bounds;
  CGFloat w = [self currentSidebarWidth];
  const CGFloat inset = pinnedMode ? pad : kSidebarInset;
  NSRect fixedFrame = NSMakeRect(
      inset, inset, w,
      std::max<CGFloat>(60.0, bounds.size.height - inset * 2.0));
  const BOOL frameChanged =
      !NSEqualRects(_glassView.frame, fixedFrame) ||
      (pinnedMode && !NSEqualRects(_contentView.frame, fixedFrame));

  if (_resizeHandleView) {
    _resizeHandleView.hidden = !_sidebarVisible;
    if (_sidebarVisible) {
      _resizeHandleView.frame = NSMakeRect(
          NSMaxX(fixedFrame) - 3.0, inset, 7.0,
          std::max<CGFloat>(60.0, fixedFrame.size.height));
    }
  }

  if (!force && !frameChanged && !radiusChanged) {
    if (_editingAddress && _expandedUrlGlassView &&
        !_expandedUrlGlassView.isHidden) {
      _expandedUrlGlassView.frame = [self expandedUrlBarFrameInSlideHost];
    }
    return;
  }
  if (frameChanged || force) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glassView.frame = fixedFrame;
    _contentView.frame = pinnedMode ? fixedFrame : _glassView.bounds;
    [self syncBackmostTintLayerHosting];
    [CATransaction commit];
  }
  [self hideNativeWindowFrameTrafficLights];
  [self layoutInnerControls];
  if (_editingAddress && _expandedUrlGlassView &&
      !_expandedUrlGlassView.isHidden) {
    _expandedUrlGlassView.frame = [self expandedUrlBarFrameInSlideHost];
  }
  if (_findBarGlassView && !_findBarGlassView.isHidden) {
    _findBarGlassView.frame = [self findBarFrameInOverlay];
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

  // Compact footer: Settings on left, Downloads on right.
  CGFloat footerTop = std::max<CGFloat>(kHeaderHeight, h - kFooterHeight);
  _footerDivider.frame =
      NSMakeRect(10.0, footerTop, std::max<CGFloat>(0.0, w - 20.0), 0.5);
  _settingsButton.frame = NSMakeRect(10.0, footerTop + 9.0, 28.0, 28.0);
  _downloadsButton.frame = NSMakeRect(w - 38.0, footerTop + 9.0, 28.0, 28.0);

  // Scrollable tabs area between header and footer.
  CGFloat scrollY = kHeaderHeight;
  CGFloat scrollH = std::max<CGFloat>(0.0, footerTop - scrollY - 4.0);
  _scrollView.frame = NSMakeRect(0.0, scrollY, w, scrollH);
  [_urlBarHoverTrail syncCanvasBounds];

  [self layoutTabRows];
}

- (void)updateExtensionsButtonVisibilityAnimated:(BOOL)animated {
  if (!_extensionsButton || !_addressContainer) {
    return;
  }
  const BOOL popupForced = (_extensionPopupCount > 0) || _extensionsPopoverOpen;
  BOOL shouldShow =
      popupForced || (_addressContainer.hovered && _bridge &&
                      _bridge->HasInstalledExtensions());
  if (popupForced != _extensionsIconFilled) {
    _extensionsIconFilled = popupForced;
    if (animated && _extensionsButton.layer) {
      CATransition* fade = [CATransition animation];
      fade.type = kCATransitionFade;
      fade.duration = 0.18;
      fade.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [_extensionsButton.layer addAnimation:fade forKey:@"extFillCrossfade"];

      CAKeyframeAnimation* pulse =
          [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
      pulse.values = @[ @1.0, @(popupForced ? 1.15 : 0.90), @1.0 ];
      pulse.keyTimes = @[ @0.0, @0.45, @1.0 ];
      pulse.duration = 0.22;
      pulse.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [_extensionsButton.layer addAnimation:pulse forKey:@"extFillPulse"];
    }
  }
  [_extensionsButton
      setSymbol:(popupForced ? @"puzzlepiece.extension.fill"
                             : @"puzzlepiece.extension")
      pointSize:12.0
         weight:NSFontWeightMedium];
  _extensionsButton.activeHighlight = popupForced;
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
    ctx.duration = 0.14;
    ctx.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    _extensionsButton.animator.alphaValue = targetAlpha;
  }
      completionHandler:^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s) {
          return;
        }
        BOOL stillShow = (s->_extensionPopupCount > 0) ||
                         s->_extensionsPopoverOpen ||
                         (s->_addressContainer.hovered && s->_bridge &&
                          s->_bridge->HasInstalledExtensions());
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
  MakeMenuItemImageVisible(item);
  return item;
}

- (BOOL)isPinned {
  return _pinned;
}

- (void)beginInlineRenameForGroupToken:(NSString*)token {
  _renamingGroupToken = token ?: @"";
}

- (NSMenu*)buildInlinePlusContextMenu {
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"New Container Tab"];
  __weak __typeof(self) weakSelf = self;

  NSMenuItem* header =
      [NSMenuItem sectionHeaderWithTitle:@"Open Tab in Container"];
  [menu addItem:header];

  std::vector<LightTabContainer> containers = LightGetTabContainers();
  for (const auto& c : containers) {
    std::string cid = c.id;
    NSString* title = base::SysUTF8ToNSString(c.name);
    NSString* sym = base::SysUTF8ToNSString(c.symbol);
    NSColor* col = SidebarColorFromHex(c.color_hex);

    NSImage* tinted = nil;
    if (NSImage* baseImg = SymbolImage(sym, 13.0, NSFontWeightMedium)) {
      tinted = [NSImage imageWithSize:NSMakeSize(16.0, 16.0)
                              flipped:NO
                       drawingHandler:^BOOL(NSRect dstRect) {
                         [col set];
                         NSSize sz = baseImg.size;
                         NSRect r = NSMakeRect(
                             std::floor((dstRect.size.width - sz.width) * 0.5),
                             std::floor((dstRect.size.height - sz.height) * 0.5),
                             sz.width, sz.height);
                         [baseImg drawInRect:r];
                         NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
                         return YES;
                       }];
      [tinted setTemplate:NO];
    }

    [menu addItem:[self menuItemWithTitle:title
                                   symbol:nil
                                    image:tinted
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->OpenNewTabInContainer(cid);
                                    }
                                  }]];
  }

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Manage Containers…"
                                 symbol:@"square.stack.3d.up"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->OpenContainersSettings();
                                  }
                                }]];
  return menu;
}

- (NSRect)beginExtensionPopup {
  _extensionPopupCount += 1;
  [self setSidebarVisible:YES animated:YES];
  [self updateExtensionsButtonVisibilityAnimated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  [self layoutOuterGlassGeometryForce:YES];

  if (!_window) {
    return NSZeroRect;
  }
  NSRect winFrame = _window.frame;
  CGFloat sidebarW = [self currentSidebarWidth];
  const CGFloat pad =
      std::round(kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0));
  CGFloat rightEdgeInWin = (_pinned ? pad : kSidebarInset) + sidebarW;
  CGFloat extTopFromWindowTop = 44.0;
  CGFloat extHeight = 28.0;
  if (_extensionsButton && _extensionsButton.superview) {
    NSRect extInWin =
        [_extensionsButton convertRect:_extensionsButton.bounds toView:nil];
    if (extInWin.size.height > 1.0) {
      return NSMakeRect(winFrame.origin.x + rightEdgeInWin,
                        winFrame.origin.y + extInWin.origin.y, 0.0,
                        extInWin.size.height);
    }
  }
  return NSMakeRect(
      winFrame.origin.x + rightEdgeInWin,
      winFrame.origin.y + winFrame.size.height - extTopFromWindowTop - extHeight,
      0.0, extHeight);
}

- (void)endExtensionPopup {
  if (_extensionPopupCount > 0) {
    _extensionPopupCount -= 1;
  }
  [self updateExtensionsButtonVisibilityAnimated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  if (![self isSidebarLockedOpen] && [self shouldAutoCloseForCurrentCursor]) {
    [self setSidebarVisible:NO animated:YES];
  } else if (![self isSidebarLockedOpen] && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

// -----------------------------------------------------------------------------
// Liquid Glass Downloads popup anchored immediately right of the sidebar footer.
// -----------------------------------------------------------------------------
- (void)downloadsDidUpdate {
  if (!_bridge || !_downloadsButton) {
    return;
  }
  bool anyActive = false;
  CGFloat progress = 0.0;
  _bridge->GetDownloadProgressSummary(&anyActive, &progress);
  _downloadsButton.showProgressRing = anyActive ? YES : NO;
  _downloadsButton.progressFraction = progress;
  [_downloadsButton
      setSymbol:(_downloadsPopupOpen ? @"arrow.down.circle.fill"
                                     : @"arrow.down.circle")
      pointSize:14.0
         weight:NSFontWeightMedium];
  _downloadsButton.activeHighlight = _downloadsPopupOpen;
  if (_downloadsPopupOpen) {
    [self reloadDownloadsPopupContents];
  }
}

- (void)ensureDownloadsPanelCreated {
  if (_downloadsPanel) {
    return;
  }
  constexpr CGFloat kW = 320.0;
  constexpr CGFloat kH = 260.0;

  _downloadsPanel = [[LightDownloadsOverlayPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, kW, kH)
                styleMask:NSWindowStyleMaskBorderless
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _downloadsPanel.opaque = NO;
  _downloadsPanel.backgroundColor = [NSColor clearColor];
  _downloadsPanel.hasShadow = YES;
  _downloadsPanel.level = NSFloatingWindowLevel;
  _downloadsPanel.collectionBehavior =
      NSWindowCollectionBehaviorMoveToActiveSpace;
  _downloadsPanel.releasedWhenClosed = NO;

  __weak __typeof(self) weakSelf = self;
  _downloadsPanel.onDismiss = ^{
    [weakSelf dismissDownloadsPopup];
  };

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = 15.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _downloadsPanel.contentView = root;

  _downloadsGlassView = [[NSGlassEffectView alloc] initWithFrame:root.bounds];
  _downloadsGlassView.wantsLayer = YES;
  _downloadsGlassView.cornerRadius = 15.0;
  _downloadsGlassView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_downloadsGlassView];

  _downloadsContent = [[LightFlippedDocumentView alloc] initWithFrame:root.bounds];
  _downloadsContent.wantsLayer = YES;
  _downloadsContent.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  _downloadsGlassView.contentView = _downloadsContent;

  NSTextField* titleLbl = [NSTextField labelWithString:@"Downloads"];
  titleLbl.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
  titleLbl.textColor = NSColor.labelColor;
  titleLbl.frame = NSMakeRect(16.0, 13.0, 120.0, 18.0);
  [_downloadsContent addSubview:titleLbl];

  _downloadsClearButton = [NSButton buttonWithTitle:@"Clear"
                                             target:self
                                             action:@selector(handleDownloadsClear:)];
  _downloadsClearButton.bordered = NO;
  _downloadsClearButton.font =
      [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
  _downloadsClearButton.contentTintColor = NSColor.secondaryLabelColor;
  _downloadsClearButton.frame = NSMakeRect(kW - 122.0, 12.0, 44.0, 20.0);
  [_downloadsContent addSubview:_downloadsClearButton];

  _downloadsShowAllButton =
      [NSButton buttonWithTitle:@"Show All"
                         target:self
                         action:@selector(handleDownloadsShowAll:)];
  _downloadsShowAllButton.bordered = NO;
  _downloadsShowAllButton.font =
      [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
  _downloadsShowAllButton.contentTintColor = NSColor.controlAccentColor;
  _downloadsShowAllButton.frame = NSMakeRect(kW - 74.0, 12.0, 62.0, 20.0);
  [_downloadsContent addSubview:_downloadsShowAllButton];

  NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(14.0, 40.0, kW - 28.0, 0.5)];
  sep.boxType = NSBoxCustom;
  sep.borderWidth = 0.0;
  sep.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
  [_downloadsContent addSubview:sep];

  _downloadsScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _downloadsScrollView.drawsBackground = NO;
  _downloadsScrollView.hasVerticalScroller = YES;
  _downloadsScrollView.autohidesScrollers = YES;
  _downloadsScrollView.scrollerStyle = NSScrollerStyleOverlay;
  _downloadsScrollView.borderType = NSNoBorder;
  _downloadsDocView = [[LightFlippedDocumentView alloc] initWithFrame:NSZeroRect];
  _downloadsScrollView.documentView = _downloadsDocView;
  [_downloadsContent addSubview:_downloadsScrollView];

  _downloadsHoverTrail = [[LightHoverTrailController alloc]
      initWithScrollView:_downloadsScrollView
            documentView:_downloadsDocView];
  _downloadsHoverTrail.cornerRadius = 9.0;
  _downloadsHoverTrail.hoverAlpha = 0.09;
  _downloadsHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || !s->_downloadsDocView) {
      return @[];
    }
    NSMutableArray<NSView*>* out = [NSMutableArray array];
    for (NSView* sub in s->_downloadsDocView.subviews) {
      if ([sub isKindOfClass:[LightDownloadRowView class]]) {
        [out addObject:sub];
      }
    }
    return out;
  };
  _downloadsHoverTrail.isRowSelected = ^BOOL(NSView* row) { return NO; };

  _downloadsEmptyLabel = [NSTextField labelWithString:@"No recent downloads"];
  _downloadsEmptyLabel.font =
      [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
  _downloadsEmptyLabel.textColor = NSColor.secondaryLabelColor;
  _downloadsEmptyLabel.alignment = NSTextAlignmentCenter;
  [_downloadsContent addSubview:_downloadsEmptyLabel];

  [self applyGlassMaterialSettings];
}

- (void)handleDownloadsClear:(id)sender {
  if (_bridge) {
    _bridge->ClearCompletedDownloads();
  }
}

- (void)handleDownloadsShowAll:(id)sender {
  [self dismissDownloadsPopup];
  if (_bridge) {
    _bridge->OpenAllDownloadsPage();
  }
}

- (NSMenu*)buildDownloadRowContextMenuForId:(uint32_t)downloadId
                                    canOpen:(BOOL)canOpen
                                  completed:(BOOL)completed {
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Download"];
  __weak __typeof(self) weakSelf = self;

  if (canOpen) {
    [menu addItem:[self menuItemWithTitle:@"Open"
                                   symbol:@"arrow.up.forward.app"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->OpenDownloadById(downloadId);
                                    }
                                  }]];
  }
  if (completed) {
    [menu addItem:[self menuItemWithTitle:@"Show in Finder"
                                   symbol:@"folder"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->ShowDownloadInFolderById(
                                          downloadId);
                                    }
                                  }]];
  }
  [menu addItem:[self menuItemWithTitle:@"Copy Download Link"
                                 symbol:@"link"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    NSString* urlStr =
                                        s->_bridge->GetDownloadUrlSpecById(
                                            downloadId);
                                    if (urlStr.length > 0) {
                                      [NSPasteboard.generalPasteboard clearContents];
                                      [NSPasteboard.generalPasteboard
                                          setString:urlStr
                                            forType:NSPasteboardTypeString];
                                    }
                                  }
                                }]];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Remove from List"
                                 symbol:@"minus.circle"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->RemoveDownloadFromListById(
                                        downloadId);
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Delete File & Remove"
                                 symbol:@"trash"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->DeleteDownloadFileById(
                                        downloadId);
                                  }
                                }]];
  return menu;
}

- (void)reloadDownloadsPopupContents {
  if (!_downloadsPanel || !_bridge) {
    return;
  }
  [_downloadsHoverTrail cancelAllAnimated:NO];
  NSArray<LightDownloadEntry*>* entries = _bridge->GetRecentDownloads();
  for (NSView* sub in [_downloadsDocView.subviews copy]) {
    if ([sub isKindOfClass:[LightDownloadRowView class]]) {
      [sub removeFromSuperview];
    }
  }

  CGFloat sidebarW = [self currentSidebarWidth];
  const CGFloat kW = std::max<CGFloat>(248.0, sidebarW - 12.0);
  constexpr CGFloat kHeaderH = 42.0;
  constexpr CGFloat kRowH = 52.0;
  constexpr CGFloat kRowGap = 2.0;

  _downloadsClearButton.frame = NSMakeRect(kW - 116.0, 12.0, 42.0, 20.0);
  _downloadsShowAllButton.frame = NSMakeRect(kW - 70.0, 12.0, 60.0, 20.0);

  CGFloat contentH = 0.0;
  if (entries.count == 0) {
    _downloadsEmptyLabel.hidden = NO;
    _downloadsScrollView.hidden = YES;
    contentH = 88.0;
  } else {
    _downloadsEmptyLabel.hidden = YES;
    _downloadsScrollView.hidden = NO;
    __weak __typeof(self) weakSelf = self;
    CGFloat y = 6.0;
    for (LightDownloadEntry* e in entries) {
      BOOL canOpen = e.canOpen;
      BOOL completed = e.completed;
      LightDownloadRowView* row = [[LightDownloadRowView alloc]
          initWithFrame:NSMakeRect(6.0, y, kW - 12.0, kRowH)];
      [row configureWithEntry:e];
      row.onOpen = ^(uint32_t did) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->OpenDownloadById(did);
        }
      };
      row.onShowInFinder = ^(uint32_t did) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->ShowDownloadInFolderById(did);
        }
      };
      row.onCancel = ^(uint32_t did) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->CancelDownloadById(did);
        }
      };
      row.menuProvider = ^NSMenu*(uint32_t did) {
        __strong __typeof(weakSelf) s = weakSelf;
        return s ? [s buildDownloadRowContextMenuForId:did
                                               canOpen:canOpen
                                             completed:completed]
                 : nil;
      };
      [_downloadsDocView addSubview:row];
      y += kRowH + kRowGap;
    }
    y += 6.0;
    contentH = std::min<CGFloat>(310.0, y);
    _downloadsDocView.frame = NSMakeRect(0, 0, kW, y);
    [_downloadsHoverTrail syncCanvasBounds];
  }

  CGFloat totalH = kHeaderH + contentH;
  // Overlay directly over the bottom-left area of the sidebar (above footer).
  NSRect winFrame = _window ? _window.frame : NSScreen.mainScreen.visibleFrame;
  const CGFloat pad =
      std::round(kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0));
  const CGFloat sideLeft = _pinned ? pad : kSidebarInset;
  const CGFloat sideBottom = _pinned ? pad : kSidebarInset;
  CGFloat x = std::floor(winFrame.origin.x + sideLeft + 6.0);
  CGFloat y = std::floor(winFrame.origin.y + sideBottom + kFooterHeight + 4.0);
  NSScreen* scr = (_window && _window.screen) ? _window.screen : NSScreen.mainScreen;
  if (scr) {
    NSRect vf = scr.visibleFrame;
    if (x + kW > NSMaxX(vf) - 10.0) {
      x = NSMaxX(vf) - kW - 10.0;
    }
    if (y + totalH > NSMaxY(vf) - 12.0) {
      y = NSMaxY(vf) - totalH - 12.0;
    }
    y = std::max<CGFloat>(NSMinY(vf) + 10.0, y);
  }
  [_downloadsPanel setFrame:NSMakeRect(x, y, kW, totalH) display:YES];
  _downloadsScrollView.frame = NSMakeRect(0.0, kHeaderH, kW, contentH);
  _downloadsEmptyLabel.frame =
      NSMakeRect(16.0, kHeaderH + std::floor((contentH - 18.0) * 0.5),
                 kW - 32.0, 18.0);
}

- (void)toggleDownloadsPopup {
  if (_downloadsPopupOpen) {
    [self dismissDownloadsPopup];
  } else {
    [self showDownloadsPopup];
  }
}

- (void)showDownloadsPopup {
  [self dismissExtensionsPopover];
  [self dismissSiteInfoPopover];
  [self ensureDownloadsPanelCreated];
  [self applyGlassMaterialSettings];
  _downloadsPopupOpen = YES;
  [self setSidebarVisible:YES animated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  [self downloadsDidUpdate];
  [self reloadDownloadsPopupContents];
  if (_window && _downloadsPanel.parentWindow != _window) {
    [_window addChildWindow:_downloadsPanel ordered:NSWindowAbove];
  }
  [_downloadsPanel makeKeyAndOrderFront:nil];
}

- (void)dismissDownloadsPopup {
  if (!_downloadsPopupOpen && (!_downloadsPanel || !_downloadsPanel.isVisible)) {
    return;
  }
  [_downloadsHoverTrail cancelAllAnimated:NO];
  _downloadsPopupOpen = NO;
  if (_downloadsPanel) {
    if (_window && _downloadsPanel.parentWindow == _window) {
      [_window removeChildWindow:_downloadsPanel];
    }
    [_downloadsPanel orderOut:nil];
  }
  [self downloadsDidUpdate];
  [self updateBackmostOverlayTintAnimated:YES];
  if (![self isSidebarLockedOpen] && [self shouldAutoCloseForCurrentCursor]) {
    [self setSidebarVisible:NO animated:YES];
  } else if (![self isSidebarLockedOpen] && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

- (void)populateExtensionsMenu:(NSMenu*)menu {
  if (!menu) {
    return;
  }
  [menu removeAllItems];
  _menuBarExtTargets = [NSMutableArray array];
  __weak __typeof(self) weakSelf = self;

  auto addItem = ^(NSString* title, NSString* symbol, NSImage* img,
                   void (^handler)(void)) {
    LightSidebarMenuTarget* target = [[LightSidebarMenuTarget alloc] init];
    target.handler = handler;
    [self->_menuBarExtTargets addObject:target];
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(invoke:)
                                           keyEquivalent:@""];
    item.target = target;
    if (img) {
      img.size = NSMakeSize(16.0, 16.0);
      item.image = img;
    } else if (symbol) {
      NSImage* symImg = SymbolImage(symbol, 13.0, NSFontWeightRegular);
      [symImg setTemplate:YES];
      item.image = symImg;
    }
    MakeMenuItemImageVisible(item);
    [menu addItem:item];
  };

  std::vector<std::tuple<std::string, std::u16string, NSImage*>> extensions;
  if (_bridge) {
    _bridge->GetInstalledExtensions(extensions);
  }
  if (!extensions.empty()) {
    for (const auto& [actionId, name, icon] : extensions) {
      std::string capturedId = actionId;
      NSString* title = base::SysUTF16ToNSString(name);
      addItem(title, @"puzzlepiece.extension", icon, ^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->TriggerExtensionAction(capturedId);
        }
      });
    }
    [menu addItem:[NSMenuItem separatorItem]];
  } else {
    NSMenuItem* emptyItem =
        [[NSMenuItem alloc] initWithTitle:@"No Extensions Installed"
                                   action:nil
                            keyEquivalent:@""];
    emptyItem.enabled = NO;
    [menu addItem:emptyItem];
    [menu addItem:[NSMenuItem separatorItem]];
  }

  addItem(@"Manage Extensions…", @"slider.horizontal.3", nil, ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->OpenManageExtensions();
    }
  });
  addItem(@"Visit Chrome Web Store", @"bag", nil, ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (s && s->_bridge) {
      s->_bridge->OpenChromeWebStore();
    }
  });
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

- (NSMenu*)buildExtensionTileContextMenuForId:(NSString*)extId
                                         name:(NSString*)name {
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:(name ?: @"Extension")];
  std::string capturedId = base::SysNSStringToUTF8(extId ?: @"");
  __weak __typeof(self) weakSelf = self;

  if (name.length > 0) {
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:name]];
  }
  if (_bridge && _bridge->HasExtensionOptionsPage(capturedId)) {
    [menu addItem:[self menuItemWithTitle:@"Extension Options…"
                                   symbol:@"gearshape"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      [s dismissExtensionsPopover];
                                      s->_bridge->OpenExtensionOptionsPage(
                                          capturedId);
                                    }
                                  }]];
  }
  [menu addItem:[self menuItemWithTitle:@"Disable Extension"
                                 symbol:@"pause.circle"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->DisableExtensionById(capturedId);
                                    [s reloadExtensionsPopoverContents];
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Remove Extension"
                                 symbol:@"trash"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->UninstallExtensionById(
                                        capturedId);
                                    [s reloadExtensionsPopoverContents];
                                  }
                                }]];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Manage Extensions…"
                                 symbol:@"slider.horizontal.3"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    [s dismissExtensionsPopover];
                                    s->_bridge->OpenManageExtensions();
                                  }
                                }]];
  return menu;
}

- (void)ensureExtensionsPanelCreated {
  if (_extensionsPanel) {
    return;
  }
  _extensionsPanel = [[LightPopoverGlassPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 232, 160)
                styleMask:NSWindowStyleMaskBorderless
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _extensionsPanel.opaque = NO;
  _extensionsPanel.backgroundColor = [NSColor clearColor];
  _extensionsPanel.hasShadow = YES;
  _extensionsPanel.level = NSFloatingWindowLevel;
  _extensionsPanel.collectionBehavior =
      NSWindowCollectionBehaviorMoveToActiveSpace;
  _extensionsPanel.releasedWhenClosed = NO;
  _extensionsPanel.acceptsMouseMovedEvents = YES;

  __weak __typeof(self) weakSelf = self;
  _extensionsPanel.onDismiss = ^{
    [weakSelf dismissExtensionsPopover];
  };

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 232, 160)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = 15.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _extensionsPanel.contentView = root;

  _extensionsGlassView = [[NSGlassEffectView alloc] initWithFrame:root.bounds];
  _extensionsGlassView.wantsLayer = YES;
  _extensionsGlassView.cornerRadius = 15.0;
  _extensionsGlassView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_extensionsGlassView];

  _extensionsContent =
      [[LightFlippedDocumentView alloc] initWithFrame:root.bounds];
  _extensionsContent.wantsLayer = YES;
  _extensionsContent.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  _extensionsGlassView.contentView = _extensionsContent;

  _extensionsHoverTrail =
      [[LightHoverTrailController alloc] initWithContainerView:_extensionsContent];
  _extensionsHoverTrail.cornerRadius = 10.0;
  _extensionsHoverTrail.hoverAlpha = 0.14;
  _extensionsHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s || !s->_extensionsContent) {
      return @[];
    }
    NSMutableArray<NSView*>* tiles = [NSMutableArray array];
    for (NSView* sub in s->_extensionsContent.subviews) {
      if ([sub isKindOfClass:[LightExtensionTileView class]]) {
        [tiles addObject:sub];
      }
    }
    return tiles;
  };
  _extensionsHoverTrail.isRowSelected = ^BOOL(NSView* row) { return NO; };

  [self applyGlassMaterialSettings];
}

- (void)reloadExtensionsPopoverContents {
  if (!_extensionsPanel || !_extensionsContent || !_bridge) {
    return;
  }
  [_extensionsHoverTrail cancelAllAnimated:NO];
  for (NSView* sub in [_extensionsContent.subviews copy]) {
    if (![sub isKindOfClass:[LightHoverTrailCanvasView class]]) {
      [sub removeFromSuperview];
    }
  }

  std::vector<std::tuple<std::string, std::u16string, NSImage*>> extensions;
  _bridge->GetInstalledExtensions(extensions);

  constexpr CGFloat kPad = 12.0;
  constexpr CGFloat kGap = 8.0;
  constexpr CGFloat kTileW = 62.0;
  constexpr CGFloat kTileH = 44.0;
  constexpr int kCols = 3;
  constexpr CGFloat kPanelW = kPad * 2.0 + kTileW * kCols + kGap * (kCols - 1);

  NSTextField* hdr = [NSTextField labelWithString:@"Extensions"];
  hdr.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
  hdr.textColor = NSColor.labelColor;
  hdr.frame = NSMakeRect(kPad, 11.0, 120.0, 18.0);
  [_extensionsContent addSubview:hdr];

  NSButton* manageBtn = [NSButton buttonWithTitle:@"Manage…"
                                           target:self
                                           action:@selector(handleOpenManageExtensions:)];
  manageBtn.bordered = NO;
  NSAttributedString* manageAttr = [[NSAttributedString alloc]
      initWithString:@"Manage…"
          attributes:@{
            NSFontAttributeName :
                [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
            NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
          }];
  manageBtn.attributedTitle = manageAttr;
  manageBtn.alignment = NSTextAlignmentRight;
  manageBtn.frame = NSMakeRect(kPanelW - kPad - 70.0, 10.0, 70.0, 20.0);
  [_extensionsContent addSubview:manageBtn];

  CGFloat y = 38.0;
  __weak __typeof(self) weakSelf = self;
  if (extensions.empty()) {
    NSTextField* empty = [NSTextField labelWithString:@"No extensions enabled"];
    empty.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    empty.textColor = NSColor.secondaryLabelColor;
    empty.alignment = NSTextAlignmentCenter;
    empty.frame = NSMakeRect(kPad, y + 8.0, kPanelW - kPad * 2.0, 18.0);
    [_extensionsContent addSubview:empty];
    y += 40.0;
  } else {
    for (size_t i = 0; i < extensions.size(); ++i) {
      const auto& [actionId, nameU16, icon] = extensions[i];
      NSString* extId = base::SysUTF8ToNSString(actionId);
      NSString* extName = base::SysUTF16ToNSString(nameU16);
      int row = static_cast<int>(i) / kCols;
      int col = static_cast<int>(i) % kCols;
      CGFloat tx = kPad + col * (kTileW + kGap);
      CGFloat ty = y + row * (kTileH + kGap);

      LightExtensionTileView* tile = [[LightExtensionTileView alloc]
          initWithFrame:NSMakeRect(tx, ty, kTileW, kTileH)];
      [tile configureWithId:extId name:extName icon:icon];
      tile.onLeftClick = ^(NSString* eid) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          std::string cid = base::SysNSStringToUTF8(eid ?: @"");
          [s dismissExtensionsPopover];
          s->_bridge->TriggerExtensionAction(cid);
        }
      };
      tile.menuProvider = ^NSMenu*(NSString* eid) {
        __strong __typeof(weakSelf) s = weakSelf;
        return s ? [s buildExtensionTileContextMenuForId:eid name:extName] : nil;
      };
      [_extensionsContent addSubview:tile];
    }
    int rows = (static_cast<int>(extensions.size()) + kCols - 1) / kCols;
    y += rows * kTileH + std::max(0, rows - 1) * kGap + 12.0;
  }

  CGFloat totalH = y;
  NSRect winFrame = _window ? _window.frame : NSScreen.mainScreen.visibleFrame;
  const CGFloat pad =
      std::round(kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0));
  const CGFloat rightEdgeInWin =
      (_pinned ? pad : kSidebarInset) + [self currentSidebarWidth];
  NSRect extInWin =
      (_extensionsButton && _extensionsButton.superview)
          ? [_extensionsButton convertRect:_extensionsButton.bounds toView:nil]
          : NSMakeRect(160.0, winFrame.size.height - 76.0, 24.0, 24.0);
  // Always anchor strictly to the RIGHT of the sidebar.
  CGFloat x = std::floor(winFrame.origin.x + rightEdgeInWin + 10.0);
  CGFloat topY = std::floor(winFrame.origin.y + NSMaxY(extInWin) + 4.0);
  CGFloat panelY = topY - totalH;
  NSScreen* scr = (_window && _window.screen) ? _window.screen : NSScreen.mainScreen;
  if (scr) {
    NSRect vf = scr.visibleFrame;
    x = std::clamp<CGFloat>(x, NSMinX(vf) + 8.0, NSMaxX(vf) - kPanelW - 8.0);
    panelY = std::max<CGFloat>(NSMinY(vf) + 10.0, panelY);
  }
  [_extensionsPanel setFrame:NSMakeRect(x, panelY, kPanelW, totalH) display:YES];
  [_extensionsHoverTrail syncCanvasBounds];
}

- (void)handleOpenManageExtensions:(id)sender {
  [self dismissExtensionsPopover];
  if (_bridge) {
    _bridge->OpenManageExtensions();
  }
}

- (void)handleOpenWebStore:(id)sender {
  [self dismissExtensionsPopover];
  if (_bridge) {
    _bridge->OpenChromeWebStore();
  }
}

- (void)toggleExtensionsPopover {
  if (_extensionsPopoverOpen) {
    [self dismissExtensionsPopover];
  } else {
    [self showExtensionsPopover];
  }
}

- (void)showExtensionsPopover {
  [self dismissDownloadsPopup];
  [self dismissSiteInfoPopover];
  [self ensureExtensionsPanelCreated];
  [self applyGlassMaterialSettings];
  _extensionsPopoverOpen = YES;
  [self setSidebarVisible:YES animated:YES];
  [self updateExtensionsButtonVisibilityAnimated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  [self reloadExtensionsPopoverContents];
  if (_window && _extensionsPanel.parentWindow != _window) {
    [_window addChildWindow:_extensionsPanel ordered:NSWindowAbove];
  }
  [_extensionsPanel makeKeyAndOrderFront:nil];
}

- (void)dismissExtensionsPopover {
  if (!_extensionsPopoverOpen &&
      (!_extensionsPanel || !_extensionsPanel.isVisible)) {
    return;
  }
  [_extensionsHoverTrail cancelAllAnimated:NO];
  _extensionsPopoverOpen = NO;
  if (_extensionsPanel) {
    if (_window && _extensionsPanel.parentWindow == _window) {
      [_window removeChildWindow:_extensionsPanel];
    }
    [_extensionsPanel orderOut:nil];
  }
  [self updateExtensionsButtonVisibilityAnimated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  if (![self isSidebarLockedOpen] && [self shouldAutoCloseForCurrentCursor]) {
    [self setSidebarVisible:NO animated:YES];
  } else if (![self isSidebarLockedOpen] && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

// -----------------------------------------------------------------------------
// Clickable Lock Icon -> Liquid Glass Certificate & Site Security Info popup
// -----------------------------------------------------------------------------
- (void)ensureSiteInfoPanelCreated {
  if (_siteInfoPanel) {
    return;
  }
  _siteInfoPanel = [[LightPopoverGlassPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 296, 180)
                styleMask:NSWindowStyleMaskBorderless
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _siteInfoPanel.opaque = NO;
  _siteInfoPanel.backgroundColor = [NSColor clearColor];
  _siteInfoPanel.hasShadow = YES;
  _siteInfoPanel.level = NSFloatingWindowLevel;
  _siteInfoPanel.collectionBehavior =
      NSWindowCollectionBehaviorMoveToActiveSpace;
  _siteInfoPanel.releasedWhenClosed = NO;

  __weak __typeof(self) weakSelf = self;
  _siteInfoPanel.onDismiss = ^{
    [weakSelf dismissSiteInfoPopover];
  };

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 296, 180)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = 15.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _siteInfoPanel.contentView = root;

  _siteInfoGlassView = [[NSGlassEffectView alloc] initWithFrame:root.bounds];
  _siteInfoGlassView.wantsLayer = YES;
  _siteInfoGlassView.cornerRadius = 15.0;
  _siteInfoGlassView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_siteInfoGlassView];

  _siteInfoContent =
      [[LightFlippedDocumentView alloc] initWithFrame:root.bounds];
  _siteInfoContent.wantsLayer = YES;
  _siteInfoContent.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  _siteInfoGlassView.contentView = _siteInfoContent;

  [self applyGlassMaterialSettings];
}

- (void)reloadSiteInfoPopoverContents {
  if (!_siteInfoPanel || !_siteInfoContent || !_bridge) {
    return;
  }
  for (NSView* sub in [_siteInfoContent.subviews copy]) {
    [sub removeFromSuperview];
  }
  NSDictionary* info = _bridge->GetActiveSiteSecurityInfo();
  if (!info) {
    return;
  }

  constexpr CGFloat kW = 300.0;
  constexpr CGFloat kPad = 14.0;
  __block CGFloat y = 14.0;

  BOOL isSecure = [info[@"isSecure"] boolValue];
  BOOL isInternal = [info[@"isInternal"] boolValue];
  NSString* host = info[@"host"] ?: @"";
  NSString* statusTitle = info[@"statusTitle"] ?: @"";
  NSString* statusDetail = info[@"statusDetail"] ?: @"";
  NSString* sym = info[@"symbolName"] ?: @"lock.fill";
  NSString* certSubject = info[@"certSubject"] ?: @"";
  NSString* certIssuer = info[@"certIssuer"] ?: @"";
  NSString* certValid = info[@"certValidRange"] ?: @"";

  NSImageView* badge =
      [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, y + 1.0, 18.0, 18.0)];
  badge.image = SymbolImage(sym, 14.0, NSFontWeightSemibold);
  badge.contentTintColor = isInternal ? NSColor.controlAccentColor
                                      : (isSecure ? NSColor.systemGreenColor
                                                  : NSColor.systemOrangeColor);
  [_siteInfoContent addSubview:badge];

  NSTextField* titleLbl = [NSTextField labelWithString:statusTitle];
  titleLbl.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
  titleLbl.textColor = NSColor.labelColor;
  titleLbl.frame = NSMakeRect(kPad + 24.0, y, kW - kPad * 2.0 - 24.0, 18.0);
  [_siteInfoContent addSubview:titleLbl];
  y += 20.0;

  if (host.length > 0) {
    NSTextField* hostLbl = [NSTextField labelWithString:host];
    hostLbl.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    hostLbl.textColor = NSColor.secondaryLabelColor;
    hostLbl.lineBreakMode = NSLineBreakByTruncatingMiddle;
    hostLbl.frame = NSMakeRect(kPad + 24.0, y, kW - kPad * 2.0 - 24.0, 15.0);
    [_siteInfoContent addSubview:hostLbl];
    y += 20.0;
  }

  NSTextField* detailLbl = [NSTextField wrappingLabelWithString:statusDetail];
  detailLbl.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
  detailLbl.textColor = NSColor.secondaryLabelColor;
  NSSize fit = [detailLbl sizeThatFits:NSMakeSize(kW - kPad * 2.0, 80.0)];
  CGFloat detailH = std::ceil(fit.height);
  detailLbl.frame = NSMakeRect(kPad, y, kW - kPad * 2.0, detailH);
  [_siteInfoContent addSubview:detailLbl];
  y += detailH + 12.0;

  if (certSubject.length > 0 || certIssuer.length > 0) {
    NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kW - kPad * 2.0, 0.5)];
    sep.boxType = NSBoxCustom;
    sep.borderWidth = 0.0;
    sep.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
    [_siteInfoContent addSubview:sep];
    y += 10.0;

    NSTextField* certHdr = [NSTextField labelWithString:@"CERTIFICATE"];
    certHdr.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
    certHdr.textColor = NSColor.tertiaryLabelColor;
    certHdr.frame = NSMakeRect(kPad, y, kW - kPad * 2.0, 13.0);
    [_siteInfoContent addSubview:certHdr];
    y += 16.0;

    auto addRow = ^(NSString* key, NSString* val) {
      if (val.length == 0) {
        return;
      }
      NSTextField* kl = [NSTextField labelWithString:key];
      kl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
      kl.textColor = NSColor.secondaryLabelColor;
      kl.frame = NSMakeRect(kPad, y, 70.0, 15.0);
      [self->_siteInfoContent addSubview:kl];

      NSTextField* vl = [NSTextField labelWithString:val];
      vl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
      vl.textColor = NSColor.labelColor;
      vl.lineBreakMode = NSLineBreakByTruncatingTail;
      vl.frame = NSMakeRect(kPad + 72.0, y, kW - kPad * 2.0 - 72.0, 15.0);
      [self->_siteInfoContent addSubview:vl];
      y += 18.0;
    };
    addRow(@"Issued To", certSubject);
    addRow(@"Issued By", certIssuer);
    addRow(@"Validity", certValid);
    y += 6.0;
  }

  // Site Permissions section (any permission granted, blocked, or asked for).
  NSArray<NSDictionary*>* perms = _bridge->GetActiveSitePermissions();
  if (perms.count > 0) {
    NSBox* psep =
        [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kW - kPad * 2.0, 0.5)];
    psep.boxType = NSBoxCustom;
    psep.borderWidth = 0.0;
    psep.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
    [_siteInfoContent addSubview:psep];
    y += 10.0;

    NSTextField* permHdr = [NSTextField labelWithString:@"PERMISSIONS"];
    permHdr.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
    permHdr.textColor = NSColor.tertiaryLabelColor;
    permHdr.frame = NSMakeRect(kPad, y, kW - kPad * 2.0, 13.0);
    [_siteInfoContent addSubview:permHdr];
    y += 18.0;

    _menuActionTargets = [NSMutableArray array];
    __weak __typeof(self) weakSelf = self;
    for (NSDictionary* p in perms) {
      int permType = [p[@"type"] intValue];
      NSString* permName = p[@"name"] ?: @"Permission";
      NSString* permSym = p[@"symbol"] ?: @"hand.raised.fill";
      NSInteger uiState = [p[@"state"] integerValue];

      NSImageView* pIcon =
          [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, y + 4.0, 14.0, 14.0)];
      pIcon.image = SymbolImage(permSym, 11.5, NSFontWeightMedium);
      pIcon.contentTintColor =
          (uiState == 0) ? NSColor.systemGreenColor
                         : (uiState == 2 ? NSColor.systemRedColor
                                         : NSColor.secondaryLabelColor);
      [_siteInfoContent addSubview:pIcon];

      NSTextField* pLbl = [NSTextField labelWithString:permName];
      pLbl.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
      pLbl.textColor = NSColor.labelColor;
      pLbl.lineBreakMode = NSLineBreakByTruncatingTail;
      pLbl.frame = NSMakeRect(kPad + 20.0, y + 3.0, kW - kPad * 2.0 - 114.0, 16.0);
      [_siteInfoContent addSubview:pLbl];

      NSPopUpButton* pop = [[NSPopUpButton alloc]
          initWithFrame:NSMakeRect(kW - kPad - 90.0, y, 90.0, 22.0)
              pullsDown:NO];
      pop.controlSize = NSControlSizeSmall;
      pop.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
      [pop addItemsWithTitles:@[ @"Allow", @"Ask", @"Block" ]];
      [pop selectItemAtIndex:std::clamp<NSInteger>(uiState, 0, 2)];

      LightSidebarMenuTarget* tgt = [[LightSidebarMenuTarget alloc] init];
      __weak NSPopUpButton* weakPop = pop;
      tgt.handler = ^{
        __strong __typeof(weakSelf) s = weakSelf;
        NSPopUpButton* sp = weakPop;
        if (s && s->_bridge && sp) {
          s->_bridge->SetActiveSitePermission(
              permType, static_cast<int>(sp.indexOfSelectedItem));
          [s reloadSiteInfoPopoverContents];
        }
      };
      [_menuActionTargets addObject:tgt];
      pop.target = tgt;
      pop.action = @selector(invoke:);
      [_siteInfoContent addSubview:pop];

      y += 28.0;
    }
    y += 4.0;
  }

  CGFloat totalH = y + 8.0;
  NSRect winFrame = _window ? _window.frame : NSScreen.mainScreen.visibleFrame;
  NSRect secInWin =
      (_addressContainer && _addressContainer.superview)
          ? [_addressContainer convertRect:_addressContainer.bounds toView:nil]
          : NSMakeRect(14.0, winFrame.size.height - 76.0, 200.0, 34.0);
  CGFloat x = std::floor(winFrame.origin.x + NSMinX(secInWin));
  CGFloat topY = std::floor(winFrame.origin.y + NSMinY(secInWin) - 6.0);
  CGFloat panelY = topY - totalH;
  NSScreen* scr = (_window && _window.screen) ? _window.screen : NSScreen.mainScreen;
  if (scr) {
    NSRect vf = scr.visibleFrame;
    x = std::clamp<CGFloat>(x, NSMinX(vf) + 8.0, NSMaxX(vf) - kW - 8.0);
    panelY = std::max<CGFloat>(NSMinY(vf) + 10.0, panelY);
  }
  [_siteInfoPanel setFrame:NSMakeRect(x, panelY, kW, totalH) display:YES];
}

- (void)toggleSiteInfoPopover {
  if (_siteInfoPopoverOpen) {
    [self dismissSiteInfoPopover];
  } else {
    [self showSiteInfoPopover];
  }
}

- (void)showSiteInfoPopover {
  [self dismissDownloadsPopup];
  [self dismissExtensionsPopover];
  [self ensureSiteInfoPanelCreated];
  [self applyGlassMaterialSettings];
  _siteInfoPopoverOpen = YES;
  [self setSidebarVisible:YES animated:YES];
  [self updateBackmostOverlayTintAnimated:YES];
  [self reloadSiteInfoPopoverContents];
  if (_window && _siteInfoPanel.parentWindow != _window) {
    [_window addChildWindow:_siteInfoPanel ordered:NSWindowAbove];
  }
  [_siteInfoPanel makeKeyAndOrderFront:nil];
}

- (void)dismissSiteInfoPopover {
  if (!_siteInfoPopoverOpen &&
      (!_siteInfoPanel || !_siteInfoPanel.isVisible)) {
    return;
  }
  _siteInfoPopoverOpen = NO;
  if (_siteInfoPanel) {
    if (_window && _siteInfoPanel.parentWindow == _window) {
      [_window removeChildWindow:_siteInfoPanel];
    }
    [_siteInfoPanel orderOut:nil];
  }
  [self updateBackmostOverlayTintAnimated:YES];
  if (![self isSidebarLockedOpen] && [self shouldAutoCloseForCurrentCursor]) {
    [self setSidebarVisible:NO animated:YES];
  } else if (![self isSidebarLockedOpen] && _sidebarVisible) {
    [self ensureHoverWatchTimerRunning];
  }
}

- (void)showExtensionsMenu {
  [self toggleExtensionsPopover];
}

- (NSMenu*)buildGroupContextMenuForToken:(NSString*)token {
  if (!_bridge || token.length == 0) {
    return nil;
  }
  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tab Group"];
  __weak __typeof(self) weakSelf = self;
  NSString* capturedToken = [token copy];

  [menu addItem:[self menuItemWithTitle:@"New Tab in Group"
                                 symbol:@"plus"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->CreateNewTabInGroupToken(
                                        capturedToken);
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Rename Group"
                                 symbol:@"pencil"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s) {
                                    s->_renamingGroupToken = capturedToken;
                                    [s reloadTabsAndNavigation];
                                  }
                                }]];

  NSMenuItem* colorParent = [[NSMenuItem alloc] initWithTitle:@"Color"
                                                       action:nil
                                                keyEquivalent:@""];
  NSImage* paletteImg = SymbolImage(@"paintpalette", 13.0, NSFontWeightRegular);
  [paletteImg setTemplate:YES];
  colorParent.image = paletteImg;
  MakeMenuItemImageVisible(colorParent);
  NSMenu* colorMenu = [[NSMenu alloc] initWithTitle:@"Color"];
  for (const auto& entry : kLightGroupColors) {
    tab_groups::TabGroupColorId cid = entry.id;
    NSColor* col = [NSColor colorWithSRGBRed:entry.r
                                       green:entry.g
                                        blue:entry.b
                                       alpha:1.0];
    NSImage* swatch = GroupSwatchImage(col, 12.0);
    [swatch setTemplate:NO];
    [colorMenu addItem:[self menuItemWithTitle:base::SysUTF8ToNSString(entry.name)
                                        symbol:nil
                                         image:swatch
                                       handler:^{
                                         __strong __typeof(weakSelf) s = weakSelf;
                                         if (s && s->_bridge) {
                                           s->_bridge->RecolorGroupToken(
                                               capturedToken, cid);
                                         }
                                       }]];
  }
  colorParent.submenu = colorMenu;
  [menu addItem:colorParent];

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Ungroup"
                                 symbol:@"rectangle.stack.badge.minus"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->UngroupToken(capturedToken);
                                  }
                                }]];
  [menu addItem:[self menuItemWithTitle:@"Close Group"
                                 symbol:@"xmark.circle"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    s->_bridge->CloseGroupToken(capturedToken);
                                  }
                                }]];
  return menu;
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

  std::vector<int> targetIndices =
      _bridge->GetTargetTabIndicesForContextMenu(index);
  const bool multiSelect = targetIndices.size() > 1;
  const auto tabGroup = model->GetTabGroupForTab(index);
  bool anyInGroup = tabGroup.has_value();
  if (!anyInGroup) {
    for (int ti : targetIndices) {
      if (model->ContainsIndex(ti) && model->GetTabGroupForTab(ti).has_value()) {
        anyInGroup = true;
        break;
      }
    }
  }

  _menuActionTargets = [NSMutableArray array];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tab"];
  __weak __typeof(self) weakSelf = self;

  if (!multiSelect) {
    [menu addItem:[self menuItemWithTitle:(isPinned ? @"Unpin Tab" : @"Pin Tab")
                                   symbol:(isPinned ? @"pin.slash" : @"pin")
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->TogglePinTabAt(index);
                                    }
                                  }]];

    if (isPinned) {
      [menu addItem:[self menuItemWithTitle:@"Replace Pin with Current"
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
    }
  }

  // Tab Groups section
  if (model->SupportsTabGroups()) {
    NSString* newGrpTitle =
        multiSelect
            ? [NSString stringWithFormat:@"Add %zu Tabs to New Group",
                                         targetIndices.size()]
            : @"Add Tab to New Group";
    [menu addItem:[self menuItemWithTitle:newGrpTitle
                                   symbol:@"rectangle.stack.badge.plus"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->AddTabsToNewGroup(
                                          targetIndices);
                                    }
                                  }]];

    if (model->group_model()) {
      auto groups = model->group_model()->ListTabGroups();
      if (!groups.empty()) {
        NSMenuItem* addToExisting = [[NSMenuItem alloc]
            initWithTitle:(multiSelect ? @"Add Tabs to Group"
                                       : @"Add Tab to Group")
                   action:nil
            keyEquivalent:@""];
        NSImage* grpImg =
            SymbolImage(@"rectangle.stack", 13.0, NSFontWeightRegular);
        [grpImg setTemplate:YES];
        addToExisting.image = grpImg;
        MakeMenuItemImageVisible(addToExisting);

        NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Groups"];
        for (const tab_groups::TabGroupId& gid : groups) {
          TabGroup* tg = model->group_model()->GetTabGroup(gid);
          if (!tg || !tg->visual_data()) {
            continue;
          }
          NSString* tok = base::SysUTF8ToNSString(gid.ToString());
          NSString* gtitle = base::SysUTF16ToNSString(tg->visual_data()->title());
          if (gtitle.length == 0) {
            gtitle = @"Untitled Group";
          }
          NSColor* col = GroupColorForId(tg->visual_data()->color());
          NSImage* swatch = GroupSwatchImage(col, 11.0);
          [swatch setTemplate:NO];
          [sub addItem:[self menuItemWithTitle:gtitle
                                        symbol:nil
                                         image:swatch
                                       handler:^{
                                         __strong __typeof(weakSelf) s = weakSelf;
                                         if (s && s->_bridge) {
                                           s->_bridge->AddTabsToGroupToken(
                                               targetIndices, tok);
                                         }
                                       }]];
        }
        addToExisting.submenu = sub;
        [menu addItem:addToExisting];
      }
    }

    if (anyInGroup) {
      [menu addItem:[self menuItemWithTitle:@"Remove from Group"
                                     symbol:@"rectangle.stack.badge.minus"
                                      image:nil
                                    handler:^{
                                      __strong __typeof(weakSelf) s = weakSelf;
                                      if (s && s->_bridge) {
                                        s->_bridge->RemoveTabsFromGroup(
                                            targetIndices);
                                      }
                                    }]];
    }
  }

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self menuItemWithTitle:@"Reload"
                                 symbol:@"arrow.clockwise"
                                  image:nil
                                handler:^{
                                  __strong __typeof(weakSelf) s = weakSelf;
                                  if (s && s->_bridge) {
                                    for (int ti : targetIndices) {
                                      s->_bridge->ReloadTabAt(ti);
                                    }
                                  }
                                }]];
  if (!multiSelect) {
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
    [menu addItem:[self menuItemWithTitle:@"Copy URL"
                                   symbol:@"link"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->CopyTabUrlAt(index);
                                    }
                                  }]];
  }

  [menu addItem:[NSMenuItem separatorItem]];
  if (multiSelect) {
    NSString* closeMultiTitle =
        [NSString stringWithFormat:@"Close %zu Selected Tabs",
                                   targetIndices.size()];
    [menu addItem:[self menuItemWithTitle:closeMultiTitle
                                   symbol:@"xmark"
                                    image:nil
                                  handler:^{
                                    __strong __typeof(weakSelf) s = weakSelf;
                                    if (s && s->_bridge) {
                                      s->_bridge->CloseSelectedTabs();
                                    }
                                  }]];
  } else {
    [menu addItem:[self menuItemWithTitle:(isPinned ? @"Unload Tab" : @"Close Tab")
                                   symbol:(isPinned ? @"moon.zzz" : @"xmark")
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
  }
  return menu;
}

- (CGFloat)pinnedTileHeightForWidth:(CGFloat)sidebarW {
  return std::clamp<CGFloat>(std::round(36.0 + (sidebarW - 180.0) * 0.055),
                             36.0, 46.0);
}

- (void)layoutTabRows {
  [self layoutTabRowsAnimated:NO];
}

- (void)layoutTabRowsAnimated:(BOOL)animated {
  if (!_scrollView || !_tabsDocumentView) {
    return;
  }
  CGFloat w = _scrollView.bounds.size.width;
  CGFloat y = 4.0;
  const BOOL isDragging = (_draggedTabIndex >= 0 && _dragSourceView != nil);

  // Build visual lists: when dragging, remove the picked-up view and insert an
  // NSNull placeholder at the active drop slot so siblings glide out of the way.
  NSMutableArray* pinnedVisual = [NSMutableArray array];
  for (LightPinnedTileView* tile in _pinnedTileViews) {
    if (isDragging && tile == _dragSourceView) {
      continue;
    }
    [pinnedVisual addObject:tile];
  }
  if (isDragging && _dragDropTargetPinned) {
    NSUInteger slot = static_cast<NSUInteger>(
        std::clamp<int>(_dragDropTargetSlot, 0,
                        static_cast<int>(pinnedVisual.count)));
    [pinnedVisual insertObject:[NSNull null] atIndex:slot];
  }

  NSMutableArray* unpinnedVisual = [NSMutableArray array];
  for (id entry in _layoutEntries) {
    if (isDragging && entry == _dragSourceView) {
      continue;
    }
    [unpinnedVisual addObject:entry];
  }
  if (isDragging && !_dragDropTargetPinned) {
    NSUInteger slot = static_cast<NSUInteger>(
        std::clamp<int>(_dragDropTargetSlot, 0,
                        static_cast<int>(unpinnedVisual.count)));
    [unpinnedVisual insertObject:[NSNull null] atIndex:slot];
  }

  _dragPreviewSlotFrameInDoc = NSZeroRect;
  NSMutableArray<NSView*>* viewsToPlace = [NSMutableArray array];
  NSMutableArray<NSValue*>* framesToPlace = [NSMutableArray array];

  if (pinnedVisual.count > 0) {
    constexpr CGFloat kPadX = 6.0;
    constexpr CGFloat kGap = 6.0;
    const CGFloat kTileH = [self pinnedTileHeightForWidth:w];
    constexpr NSUInteger kMaxPerRow = 3;
    CGFloat contentW = std::max<CGFloat>(0.0, w - kPadX * 2.0);
    NSUInteger total = pinnedVisual.count;
    NSUInteger idx = 0;
    while (idx < total) {
      NSUInteger rowCount = std::min<NSUInteger>(kMaxPerRow, total - idx);
      CGFloat gaps = rowCount > 1 ? (rowCount - 1) * kGap : 0.0;
      CGFloat tileW = std::max<CGFloat>(0.0, (contentW - gaps) / rowCount);
      CGFloat x = kPadX;
      for (NSUInteger c = 0; c < rowCount; ++c) {
        id item = pinnedVisual[idx + c];
        NSRect frame = NSMakeRect(x, y, tileW, kTileH);
        if (item == [NSNull null]) {
          _dragPreviewSlotFrameInDoc = frame;
        } else {
          [viewsToPlace addObject:(NSView*)item];
          [framesToPlace addObject:[NSValue valueWithRect:frame]];
        }
        x += tileW + kGap;
      }
      y += kTileH + kGap;
      idx += rowCount;
    }
    y += 4.0;
  }

  for (id entry in unpinnedVisual) {
    if (entry == [NSNull null]) {
      _dragPreviewSlotFrameInDoc =
          NSMakeRect(6.0, y, std::max<CGFloat>(0.0, w - 12.0), kTabRowHeight);
      y += kTabRowHeight + kTabRowSpacing;
    } else if ([entry isKindOfClass:[LightTabRowView class]]) {
      LightTabRowView* row = (LightTabRowView*)entry;
      row.hidden = NO;
      NSRect frame =
          NSMakeRect(6.0, y, std::max<CGFloat>(0.0, w - 12.0), kTabRowHeight);
      [viewsToPlace addObject:row];
      [framesToPlace addObject:[NSValue valueWithRect:frame]];
      y += kTabRowHeight + kTabRowSpacing;
    } else if ([entry isKindOfClass:[NSDictionary class]]) {
      NSDictionary* dict = (NSDictionary*)entry;
      LightTabGroupBlockView* block = dict[@"block"];
      NSArray<LightTabRowView*>* rows = dict[@"rows"];
      BOOL collapsed = [dict[@"collapsed"] boolValue];
      constexpr CGFloat kGroupHdrH = 34.0;
      CGFloat blockX = 6.0;
      CGFloat blockW = std::max<CGFloat>(0.0, w - 12.0);
      if (collapsed) {
        [viewsToPlace addObject:block];
        [framesToPlace
            addObject:[NSValue valueWithRect:NSMakeRect(blockX, y, blockW,
                                                        kGroupHdrH)]];
        for (LightTabRowView* r in rows) {
          r.hidden = YES;
        }
        y += kGroupHdrH + 4.0;
      } else {
        CGFloat innerY = y + kGroupHdrH + 2.0;
        for (LightTabRowView* r in rows) {
          if (isDragging && r == _dragSourceView) {
            continue;
          }
          r.hidden = NO;
          [viewsToPlace addObject:r];
          [framesToPlace
              addObject:[NSValue valueWithRect:NSMakeRect(
                                                   blockX + 4.0, innerY,
                                                   std::max<CGFloat>(
                                                       0.0, blockW - 8.0),
                                                   kTabRowHeight)]];
          innerY += kTabRowHeight + kTabRowSpacing;
        }
        CGFloat blockH = (innerY - y) + 3.0;
        [viewsToPlace addObject:block];
        [framesToPlace
            addObject:[NSValue valueWithRect:NSMakeRect(blockX, y, blockW,
                                                        blockH)]];
        y += blockH + 4.0;
      }
    }
  }
  if (_inlinePlusButton) {
    y += 2.0;
    [viewsToPlace addObject:_inlinePlusButton];
    [framesToPlace
        addObject:[NSValue valueWithRect:NSMakeRect(6.0, y,
                                                    std::max<CGFloat>(0.0,
                                                                      w - 12.0),
                                                    30.0)]];
    y += 30.0 + 4.0;
  }

  if (animated) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.18;
      ctx.timingFunction =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      for (NSUInteger i = 0; i < viewsToPlace.count; ++i) {
        NSRect target = framesToPlace[i].rectValue;
        if (!NSEqualRects(viewsToPlace[i].frame, target)) {
          viewsToPlace[i].animator.frame = target;
        }
      }
    }
                        completionHandler:nil];
  } else {
    for (NSUInteger i = 0; i < viewsToPlace.count; ++i) {
      viewsToPlace[i].frame = framesToPlace[i].rectValue;
    }
  }

  // Keep the opened landing space completely clean & empty (no dropper outline).
  CGFloat docH = std::max<CGFloat>(_scrollView.bounds.size.height, y + 6.0);
  _tabsDocumentView.frame = NSMakeRect(0.0, 0.0, w, docH);
  [_tabHoverTrail syncCanvasBounds];
  [_pinnedHoverTrail syncCanvasBounds];
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
    [self setSidebarVisible:YES animated:NO];
  } else {
    [self ensureHoverWatchTimerRunning];
  }
  [self animateAppFramePaddingToTarget];
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
  const NSUInteger suggCount = _suggestionItems.count;
  // Do NOT widen past the sidebar itself when no suggestions are present.
  CGFloat targetW = collapsed.size.width + 4.0;
  if (suggCount > 0) {
    targetW = std::clamp<CGFloat>(winW * 0.44, 380.0, 500.0);
    targetW = std::min<CGFloat>(
        targetW,
        std::max<CGFloat>(collapsed.size.width + 60.0, winW - startX - 18.0));
  }

  // Keep the top edge locked at the URL bar slot while expanding downward to
  // fit search & autocomplete suggestions!
  const CGFloat topY = NSMaxY(collapsed) + 2.0;
  const CGFloat kInputRowH = collapsed.size.height + 4.0;
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
  [_expandedUrlHoverTrail syncCanvasBounds];
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

- (void)ensureSpotlightPanelCreated {
  if (_spotlightPanel) {
    return;
  }
  constexpr CGFloat kW = 660.0;
  constexpr CGFloat kHeaderH = 52.0;

  _spotlightPanel = [[LightSpotlightOverlayPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, kW, kHeaderH)
                styleMask:NSWindowStyleMaskBorderless
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _spotlightPanel.opaque = NO;
  _spotlightPanel.backgroundColor = [NSColor clearColor];
  _spotlightPanel.hasShadow = YES;
  _spotlightPanel.level = NSFloatingWindowLevel;
  _spotlightPanel.collectionBehavior =
      NSWindowCollectionBehaviorMoveToActiveSpace;
  _spotlightPanel.releasedWhenClosed = NO;

  __weak __typeof(self) weakSelf = self;
  _spotlightPanel.onDismiss = ^{
    [weakSelf dismissSpotlight];
  };

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kHeaderH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = 16.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _spotlightPanel.contentView = root;

  _spotlightGlassView =
      [[NSGlassEffectView alloc] initWithFrame:root.bounds];
  _spotlightGlassView.wantsLayer = YES;
  _spotlightGlassView.cornerRadius = 16.0;
  _spotlightGlassView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_spotlightGlassView];

  _spotlightContent =
      [[LightExpandedUrlContentView alloc] initWithFrame:root.bounds];
  _spotlightContent.wantsLayer = YES;
  _spotlightContent.layer.masksToBounds = YES;
  _spotlightContent.cornerRadius = 16.0;
  _spotlightContent.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  _spotlightContent.onLayoutBlock = ^{
    [weakSelf layoutSpotlightInnerControls];
  };
  _spotlightGlassView.contentView = _spotlightContent;

  _spotlightIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _spotlightIconView.wantsLayer = YES;
  _spotlightIconView.layer.cornerRadius = 4.0;
  _spotlightIconView.layer.masksToBounds = YES;
  _spotlightIconView.imageScaling = NSImageScaleProportionallyDown;
  _spotlightIconView.imageAlignment = NSImageAlignCenter;
  _spotlightIconView.image =
      SymbolImage(@"magnifyingglass", 17.0, NSFontWeightMedium);
  _spotlightIconView.contentTintColor = NSColor.secondaryLabelColor;
  [_spotlightContent addSubview:_spotlightIconView];

  _spotlightField = [[LightAddressTextField alloc] initWithFrame:NSZeroRect];
  _spotlightField.bordered = NO;
  _spotlightField.bezeled = NO;
  _spotlightField.drawsBackground = NO;
  _spotlightField.focusRingType = NSFocusRingTypeNone;
  _spotlightField.font =
      [NSFont systemFontOfSize:17.0 weight:NSFontWeightRegular];
  _spotlightField.textColor = NSColor.labelColor;
  _spotlightField.placeholderString = @"Search or enter address…";
  _spotlightField.lineBreakMode = NSLineBreakByClipping;
  _spotlightField.usesSingleLineMode = YES;
  _spotlightField.cell.scrollable = YES;
  _spotlightField.cell.wraps = NO;
  _spotlightField.delegate = self;
  [_spotlightContent addSubview:_spotlightField];

  _spotlightInlineHintLabel = [NSTextField labelWithString:@""];
  _spotlightInlineHintLabel.font =
      [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
  _spotlightInlineHintLabel.textColor = NSColor.secondaryLabelColor;
  _spotlightInlineHintLabel.alignment = NSTextAlignmentRight;
  _spotlightInlineHintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  _spotlightInlineHintLabel.hidden = YES;
  [_spotlightContent addSubview:_spotlightInlineHintLabel];

  _spotlightClearButton =
      [[LightIconButton alloc] initWithSymbol:@"xmark.circle.fill"
                                    pointSize:14.0
                                       weight:NSFontWeightMedium
                                      toolTip:@"Clear"];
  _spotlightClearButton.cornerRadius = 12.0;
  _spotlightClearButton.hidden = YES;
  _spotlightClearButton.actionBlock = ^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    s->_spotlightField.stringValue = @"";
    s->_spotlightUserTyped = @"";
    s->_spotlightInlineTopItem = nil;
    s->_spotlightSelectedIndex = -1;
    s->_spotlightClearButton.hidden = YES;
    [s updateSpotlightLeadingIconAndHint];
    if (s->_bridge) {
      s->_bridge->StartSpotlightZeroSuggest();
    }
    [s layoutSpotlightInnerControls];
    [s->_spotlightPanel makeFirstResponder:s->_spotlightField];
  };
  [_spotlightContent addSubview:_spotlightClearButton];

  _spotlightDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
  _spotlightDivider.boxType = NSBoxCustom;
  _spotlightDivider.borderWidth = 0.0;
  _spotlightDivider.fillColor =
      [NSColor.labelColor colorWithAlphaComponent:0.10];
  _spotlightDivider.hidden = YES;
  [_spotlightContent addSubview:_spotlightDivider];

  _spotlightHoverTrail =
      [[LightHoverTrailController alloc] initWithContainerView:_spotlightContent];
  _spotlightHoverTrail.cornerRadius = 9.0;
  _spotlightHoverTrail.hoverAlpha = 0.08;
  _spotlightHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_spotlightSuggestionRows : @[];
  };
  _spotlightHoverTrail.isRowSelected = ^BOOL(NSView* row) {
    if ([row isKindOfClass:[LightSuggestionRowView class]]) {
      return ((LightSuggestionRowView*)row).keyboardSelected;
    }
    return NO;
  };

  [self applyGlassMaterialSettings];
}

- (NSRect)spotlightFrameForSuggestionCount:(NSUInteger)count {
  constexpr CGFloat kW = 660.0;
  constexpr CGFloat kHeaderH = 52.0;
  const CGFloat extraH =
      count > 0 ? (1.0 + 12.0 + static_cast<CGFloat>(count) * 38.0) : 0.0;
  const CGFloat totalH = kHeaderH + extraH;

  NSRect ref = _window ? _window.frame : NSScreen.mainScreen.visibleFrame;
  CGFloat x = std::floor(NSMidX(ref) - kW * 0.5);
  CGFloat topY = std::floor(NSMinY(ref) + ref.size.height * 0.62);
  NSScreen* scr = (_window && _window.screen) ? _window.screen : NSScreen.mainScreen;
  if (scr) {
    NSRect vf = scr.visibleFrame;
    topY = std::min<CGFloat>(topY, NSMaxY(vf) - 40.0);
    if (topY - totalH < NSMinY(vf) + 24.0) {
      topY = NSMinY(vf) + 24.0 + totalH;
    }
  }
  return NSMakeRect(x, topY - totalH, kW, totalH);
}

- (void)updateSpotlightLeadingIconAndHint {
  LightSuggestionItem* activeItem = nil;
  if (_spotlightSelectedIndex >= 0 &&
      _spotlightSelectedIndex <
          static_cast<NSInteger>(_spotlightSuggestionItems.count)) {
    activeItem = _spotlightSuggestionItems[_spotlightSelectedIndex];
  } else {
    activeItem = _spotlightInlineTopItem;
  }

  if (activeItem && activeItem.favicon) {
    _spotlightIconView.image = activeItem.favicon;
    _spotlightIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _spotlightIconView.contentTintColor =
        activeItem.favicon.isTemplate ? NSColor.labelColor : nil;
    _spotlightIconView.layer.cornerRadius = 4.0;
  } else if (activeItem && activeItem.symbolName.length > 0) {
    _spotlightIconView.image =
        SymbolImage(activeItem.symbolName, 17.0, NSFontWeightMedium);
    _spotlightIconView.imageScaling = NSImageScaleProportionallyDown;
    _spotlightIconView.contentTintColor = NSColor.secondaryLabelColor;
    _spotlightIconView.layer.cornerRadius = 0.0;
  } else {
    _spotlightIconView.image =
        SymbolImage(@"magnifyingglass", 17.0, NSFontWeightMedium);
    _spotlightIconView.imageScaling = NSImageScaleProportionallyDown;
    _spotlightIconView.contentTintColor = NSColor.secondaryLabelColor;
    _spotlightIconView.layer.cornerRadius = 0.0;
  }

  if (_spotlightSelectedIndex < 0 && _spotlightInlineTopItem &&
      _spotlightField.stringValue.length > 0) {
    NSString* hint = nil;
    if (_spotlightInlineTopItem.isSearchQuery) {
      hint = _spotlightInlineTopItem.secondaryText.length > 0
                 ? _spotlightInlineTopItem.secondaryText
                 : @"Search";
    } else if (_spotlightInlineTopItem.primaryText.length > 0 &&
               ![_spotlightInlineTopItem.primaryText
                   isEqualToString:_spotlightField.stringValue]) {
      hint = _spotlightInlineTopItem.primaryText;
    } else if (_spotlightInlineTopItem.secondaryText.length > 0) {
      hint = _spotlightInlineTopItem.secondaryText;
    } else {
      hint = @"Open";
    }
    _spotlightInlineHintLabel.stringValue =
        [NSString stringWithFormat:@"%@  ↵", hint];
    _spotlightInlineHintLabel.hidden = NO;
  } else {
    _spotlightInlineHintLabel.stringValue = @"";
    _spotlightInlineHintLabel.hidden = YES;
  }
}

- (void)layoutSpotlightInnerControls {
  if (!_spotlightContent) {
    return;
  }
  NSRect b = _spotlightContent.bounds;
  CGFloat w = b.size.width;
  constexpr CGFloat kHeaderH = 52.0;

  _spotlightIconView.frame =
      NSMakeRect(17.0, std::floor((kHeaderH - 20.0) * 0.5), 20.0, 20.0);

  BOOL hasText = (_spotlightField.stringValue.length > 0);
  _spotlightClearButton.hidden = !hasText;
  _spotlightClearButton.frame =
      NSMakeRect(w - 38.0, std::floor((kHeaderH - 24.0) * 0.5), 24.0, 24.0);

  CGFloat rightPad = hasText ? 46.0 : 18.0;
  if (!_spotlightInlineHintLabel.isHidden &&
      _spotlightInlineHintLabel.stringValue.length > 0) {
    NSSize hintFit =
        [_spotlightInlineHintLabel sizeThatFits:NSMakeSize(220.0, kHeaderH)];
    CGFloat hintW = std::min<CGFloat>(210.0, std::ceil(hintFit.width) + 4.0);
    CGFloat hintH = std::ceil(hintFit.height);
    CGFloat hintX = w - rightPad - hintW - 4.0;
    _spotlightInlineHintLabel.frame =
        NSMakeRect(hintX, std::floor((kHeaderH - hintH) * 0.5), hintW, hintH);
    rightPad += hintW + 12.0;
  }

  NSSize fit = [_spotlightField sizeThatFits:NSMakeSize(500.0, kHeaderH)];
  CGFloat fh = std::ceil(fit.height);
  _spotlightField.frame =
      NSMakeRect(46.0, std::floor((kHeaderH - fh) * 0.5),
                 std::max<CGFloat>(80.0, w - 46.0 - rightPad), fh);

  const BOOL showSuggestions = (_spotlightSuggestionItems.count > 0);
  _spotlightDivider.hidden = !showSuggestions;
  _spotlightDivider.frame =
      NSMakeRect(14.0, kHeaderH, std::max<CGFloat>(0.0, w - 28.0), 0.5);

  CGFloat rowY = kHeaderH + 6.0;
  for (NSUInteger i = 0; i < _spotlightSuggestionRows.count; ++i) {
    LightSuggestionRowView* row = _spotlightSuggestionRows[i];
    if (i < _spotlightSuggestionItems.count) {
      row.hidden = NO;
      row.frame = NSMakeRect(8.0, rowY, std::max<CGFloat>(0.0, w - 16.0), 36.0);
      rowY += 38.0;
    } else {
      row.hidden = YES;
    }
  }
  [_spotlightHoverTrail syncCanvasBounds];
}

- (void)showSpotlightCommandBar {
  if (_editingAddress) {
    [self dismissExpandedAddressBarAnimated:NO];
  }
  [self ensureSpotlightPanelCreated];
  [self applyGlassMaterialSettings];

  _spotlightActive = YES;
  _spotlightSuggestionItems = @[];
  _spotlightInlineTopItem = nil;
  _spotlightSelectedIndex = -1;
  _spotlightUserTyped = @"";
  _spotlightField.stringValue = @"";
  _spotlightClearButton.hidden = YES;
  _spotlightDivider.hidden = YES;
  [self updateSpotlightLeadingIconAndHint];
  for (LightSuggestionRowView* row in _spotlightSuggestionRows) {
    row.hidden = YES;
  }

  NSRect frame = [self spotlightFrameForSuggestionCount:0];
  [_spotlightPanel setFrame:frame display:YES];
  [self layoutSpotlightInnerControls];

  if (_window && _spotlightPanel.parentWindow != _window) {
    [_window addChildWindow:_spotlightPanel ordered:NSWindowAbove];
  }
  [_spotlightPanel makeKeyAndOrderFront:nil];
  [_spotlightPanel makeFirstResponder:_spotlightField];

  if (_bridge) {
    _bridge->StartSpotlightZeroSuggest();
  }
}

- (void)dismissSpotlight {
  if (!_spotlightActive && (!_spotlightPanel || !_spotlightPanel.isVisible)) {
    return;
  }
  [_spotlightHoverTrail cancelAllAnimated:NO];
  _spotlightActive = NO;
  _spotlightSuggestionItems = @[];
  _spotlightInlineTopItem = nil;
  _spotlightSelectedIndex = -1;
  if (_bridge) {
    _bridge->StopAutocomplete(/*clear_results=*/true);
  }
  if (_spotlightPanel) {
    if (_window && _spotlightPanel.parentWindow == _window) {
      [_window removeChildWindow:_spotlightPanel];
    }
    [_spotlightPanel orderOut:nil];
  }
  if (_window) {
    [_window makeKeyAndOrderFront:nil];
  }
}

- (void)acceptSpotlightSuggestionAtIndex:(NSInteger)idx {
  if (idx < 0 || idx >= static_cast<NSInteger>(_spotlightSuggestionItems.count)) {
    return;
  }
  LightSuggestionItem* item = _spotlightSuggestionItems[idx];
  if (_bridge) {
    _bridge->StopAutocomplete(/*clear_results=*/false);
  }
  [self dismissSpotlight];
  if (_bridge) {
    _bridge->OpenSuggestionItem(item, /*new_tab=*/true);
  }
}

- (void)refreshSpotlightSelection {
  for (NSUInteger i = 0; i < _spotlightSuggestionItems.count; ++i) {
    [_spotlightSuggestionRows[i]
        configureWithItem:_spotlightSuggestionItems[i]
                 selected:(static_cast<NSInteger>(i) ==
                           _spotlightSelectedIndex)];
  }
  NSString* newText =
      (_spotlightSelectedIndex >= 0 &&
       _spotlightSelectedIndex <
           static_cast<NSInteger>(_spotlightSuggestionItems.count))
          ? (_spotlightSuggestionItems[_spotlightSelectedIndex].fillIntoEdit ?: @"")
          : (_spotlightUserTyped ?: @"");
  _spotlightField.stringValue = newText;
  if (NSText* editor = _spotlightField.currentEditor) {
    [editor setSelectedRange:NSMakeRange(newText.length, 0)];
  }
  [self updateSpotlightLeadingIconAndHint];
  [self layoutSpotlightInnerControls];
}

- (void)applySpotlightSuggestions:(NSArray<LightSuggestionItem*>*)items {
  if (!_spotlightActive || !_spotlightPanel || !_spotlightPanel.isVisible) {
    _spotlightSuggestionItems = @[];
    _spotlightInlineTopItem = nil;
    return;
  }
  NSArray<LightSuggestionItem*>* incoming = items ? [items copy] : @[];
  // Integrate the confident top result ("Search with Google" or direct URL /
  // localhost match) right into the typing row (icon + inline hint) instead of
  // duplicating it as row 0 below!
  if (_spotlightUserTyped.length > 0 && incoming.count > 0 &&
      incoming[0].isInlineTopCandidate) {
    _spotlightInlineTopItem = incoming[0];
    _spotlightSuggestionItems =
        incoming.count > 1
            ? [incoming subarrayWithRange:NSMakeRange(1, incoming.count - 1)]
            : @[];
  } else {
    _spotlightInlineTopItem = nil;
    _spotlightSuggestionItems = incoming;
  }
  if (_spotlightSelectedIndex >=
      static_cast<NSInteger>(_spotlightSuggestionItems.count)) {
    _spotlightSelectedIndex = -1;
  }
  [self updateSpotlightLeadingIconAndHint];

  [_spotlightHoverTrail cancelAllAnimated:NO];
  __weak __typeof(self) weakSelf = self;
  while (_spotlightSuggestionRows.count < _spotlightSuggestionItems.count) {
    LightSuggestionRowView* row =
        [[LightSuggestionRowView alloc] initWithFrame:NSZeroRect];
    row.useHoverTrail = YES;
    row.onClick = ^(NSInteger clickedIdx) {
      [weakSelf acceptSpotlightSuggestionAtIndex:clickedIdx];
    };
    [_spotlightContent addSubview:row];
    [_spotlightSuggestionRows addObject:row];
  }

  for (NSUInteger i = 0; i < _spotlightSuggestionItems.count; ++i) {
    LightSuggestionRowView* row = _spotlightSuggestionRows[i];
    row.rowIndex = static_cast<NSInteger>(i);
    [row configureWithItem:_spotlightSuggestionItems[i]
                  selected:(static_cast<NSInteger>(i) ==
                            _spotlightSelectedIndex)];
  }

  NSRect targetFrame =
      [self spotlightFrameForSuggestionCount:_spotlightSuggestionItems.count];
  if (!NSEqualRects(_spotlightPanel.frame, targetFrame)) {
    [_spotlightPanel setFrame:targetFrame display:YES animate:NO];
  }
  [self layoutSpotlightInnerControls];
}

- (void)applySuggestionFavicon:(NSImage*)favicon
                   forCacheKey:(NSString*)key
                       hostKey:(NSString*)hostKey {
  if (!favicon || (key.length == 0 && hostKey.length == 0)) {
    return;
  }
  auto matchesItem = ^BOOL(LightSuggestionItem* item) {
    if (key.length > 0 && [item.faviconCacheKey isEqualToString:key]) {
      return YES;
    }
    if (hostKey.length > 0 && [item.faviconHostKey isEqualToString:hostKey]) {
      return YES;
    }
    return NO;
  };
  for (NSUInteger i = 0; i < _suggestionItems.count; ++i) {
    LightSuggestionItem* item = _suggestionItems[i];
    if (matchesItem(item)) {
      item.favicon = favicon;
      if (i < _suggestionRowViews.count) {
        [_suggestionRowViews[i] updateFavicon:favicon];
      }
    }
  }
  if (_spotlightInlineTopItem && matchesItem(_spotlightInlineTopItem)) {
    _spotlightInlineTopItem.favicon = favicon;
    [self updateSpotlightLeadingIconAndHint];
  }
  for (NSUInteger i = 0; i < _spotlightSuggestionItems.count; ++i) {
    LightSuggestionItem* item = _spotlightSuggestionItems[i];
    if (matchesItem(item)) {
      item.favicon = favicon;
      if (i < _spotlightSuggestionRows.count) {
        [_spotlightSuggestionRows[i] updateFavicon:favicon];
      }
      if (static_cast<NSInteger>(i) == _spotlightSelectedIndex) {
        [self updateSpotlightLeadingIconAndHint];
      }
    }
  }
}

- (void)applyAutocompleteSuggestions:(NSArray<LightSuggestionItem*>*)items {
  if (_spotlightActive) {
    [self applySpotlightSuggestions:items];
    return;
  }
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

  [_expandedUrlHoverTrail cancelAllAnimated:NO];
  __weak __typeof(self) weakSelf = self;
  while (_suggestionRowViews.count < _suggestionItems.count) {
    LightSuggestionRowView* row =
        [[LightSuggestionRowView alloc] initWithFrame:NSZeroRect];
    row.useHoverTrail = YES;
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
  [self updateBackmostOverlayTintAnimated:YES];
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
  [_urlBarHoverTrail cancelAllAnimated:NO];
  _expandedUrlGlassView.cornerRadius = 10.0;
  _expandedUrlContent.cornerRadius = 10.0;
  _expandedUrlGlassView.frame = startRect;
  [self layoutExpandedUrlInnerControls];
  _expandedUrlGlassView.hidden = NO;

  // Populate suggestions immediately on click (local history/bookmarks/tabs;
  // stays at sidebar width automatically if zero suggestions are returned).
  if (_bridge) {
    _bridge->StartAutocomplete(
        base::SysNSStringToUTF16(_fullAddressString ?: @""),
        /*allow_zero_suggest=*/true);
  }
  endRect = [self expandedUrlBarFrameInSlideHost];

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
  [_expandedUrlHoverTrail cancelAllAnimated:NO];
  [self updateBackmostOverlayTintAnimated:YES];
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

// -----------------------------------------------------------------------------
// Native Liquid Glass Cmd+F Find-in-Page Floating Bar
// -----------------------------------------------------------------------------
- (NSRect)findBarFrameInOverlay {
  if (!_overlayView) {
    return NSMakeRect(0, 0, 344.0, 40.0);
  }
  NSRect b = _overlayView.bounds;
  const CGFloat pad = std::round(
      kAppFramePadding * std::clamp<CGFloat>(_framePaddingProgress, 0.0, 1.0));
  constexpr CGFloat kW = 344.0;
  constexpr CGFloat kH = 40.0;
  CGFloat x = std::max<CGFloat>(12.0, b.size.width - kW - pad - 12.0);
  CGFloat y = std::max<CGFloat>(12.0, b.size.height - kH - pad - 10.0);
  return NSMakeRect(std::round(x), std::round(y), kW, kH);
}

- (void)ensureFindBarCreated {
  if (_findBarGlassView || !_overlayView) {
    return;
  }
  NSRect f = [self findBarFrameInOverlay];
  _findBarGlassView = [[NSGlassEffectView alloc] initWithFrame:f];
  _findBarGlassView.wantsLayer = YES;
  _findBarGlassView.layerUsesCoreImageFilters = YES;
  _findBarGlassView.style = NSGlassEffectViewStyleRegular;
  _findBarGlassView.cornerRadius = 12.0;
  _findBarGlassView.hidden = YES;

  NSShadow* sh = [[NSShadow alloc] init];
  sh.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.26];
  sh.shadowBlurRadius = 18.0;
  sh.shadowOffset = NSMakeSize(0.0, -5.0);
  _findBarGlassView.shadow = sh;

  _findBarContent =
      [[LightFlippedDocumentView alloc] initWithFrame:_findBarGlassView.bounds];
  _findBarContent.wantsLayer = YES;
  _findBarContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _findBarGlassView.contentView = _findBarContent;

  _findSearchIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(12, 13, 14, 14)];
  _findSearchIcon.image = SymbolImage(@"magnifyingglass", 12.5, NSFontWeightMedium);
  _findSearchIcon.contentTintColor = NSColor.secondaryLabelColor;
  _findSearchIcon.imageScaling = NSImageScaleProportionallyDown;
  [_findBarContent addSubview:_findSearchIcon];

  _findField = [[LightAddressTextField alloc] initWithFrame:NSMakeRect(32, 10, 152, 20)];
  _findField.bordered = NO;
  _findField.bezeled = NO;
  _findField.drawsBackground = NO;
  _findField.focusRingType = NSFocusRingTypeNone;
  _findField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
  _findField.textColor = NSColor.labelColor;
  _findField.placeholderString = @"Find in page…";
  _findField.usesSingleLineMode = YES;
  _findField.cell.scrollable = YES;
  _findField.cell.wraps = NO;
  _findField.delegate = self;
  [_findBarContent addSubview:_findField];

  _findCountLabel = [NSTextField labelWithString:@""];
  _findCountLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0
                                                          weight:NSFontWeightMedium];
  _findCountLabel.textColor = NSColor.secondaryLabelColor;
  _findCountLabel.alignment = NSTextAlignmentRight;
  _findCountLabel.frame = NSMakeRect(186, 12, 58, 16);
  [_findBarContent addSubview:_findCountLabel];

  _findSep = [[NSBox alloc] initWithFrame:NSMakeRect(250, 10, 0.5, 20)];
  _findSep.boxType = NSBoxCustom;
  _findSep.borderWidth = 0.0;
  _findSep.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.14];
  [_findBarContent addSubview:_findSep];

  __weak __typeof(self) weakSelf = self;
  _findPrevBtn = [[LightIconButton alloc] initWithSymbol:@"chevron.up"
                                               pointSize:11.0
                                                  weight:NSFontWeightSemibold
                                                 toolTip:@"Previous Match (⇧↩)"];
  _findPrevBtn.cornerRadius = 6.0;
  _findPrevBtn.frame = NSMakeRect(256, 8, 24, 24);
  _findPrevBtn.actionBlock = ^{
    [weakSelf findNext:NO];
  };
  [_findBarContent addSubview:_findPrevBtn];

  _findNextBtn = [[LightIconButton alloc] initWithSymbol:@"chevron.down"
                                               pointSize:11.0
                                                  weight:NSFontWeightSemibold
                                                 toolTip:@"Next Match (↩)"];
  _findNextBtn.cornerRadius = 6.0;
  _findNextBtn.frame = NSMakeRect(282, 8, 24, 24);
  _findNextBtn.actionBlock = ^{
    [weakSelf findNext:YES];
  };
  [_findBarContent addSubview:_findNextBtn];

  _findCloseBtn = [[LightIconButton alloc] initWithSymbol:@"xmark"
                                                pointSize:10.5
                                                   weight:NSFontWeightSemibold
                                                  toolTip:@"Close (Esc)"];
  _findCloseBtn.cornerRadius = 6.0;
  _findCloseBtn.frame = NSMakeRect(310, 8, 24, 24);
  _findCloseBtn.actionBlock = ^{
    [weakSelf dismissFindBarAnimated:YES clearSelection:YES];
  };
  [_findBarContent addSubview:_findCloseBtn];

  _overlayView.findBarPanel = _findBarGlassView;
  [_overlayView addSubview:_findBarGlassView
                positioned:NSWindowAbove
                relativeTo:nil];
  [self applyGlassMaterialSettings];
}

- (void)showFindBar {
  [self ensureFindBarCreated];
  if (!_findBarGlassView) {
    return;
  }
  NSRect targetFrame = [self findBarFrameInOverlay];
  if (_findBarVisible && !_findBarGlassView.isHidden) {
    _findBarGlassView.frame = targetFrame;
    [_window makeFirstResponder:_findField];
    if (_findField.currentEditor) {
      [_findField.currentEditor selectAll:nil];
    }
    return;
  }

  _findBarVisible = YES;
  NSUInteger gen = ++_findBarAnimGen;
  (void)gen;
  _findBarGlassView.frame = targetFrame;
  _findBarGlassView.hidden = NO;
  [self applyGlassMaterialSettings];

  CIFilter* blur = [CIFilter filterWithName:@"CIGaussianBlur"];
  [blur setDefaults];
  blur.name = @"findBlur";
  [blur setValue:@(8.0) forKey:@"inputRadius"];
  _findBarGlassView.layer.filters = @[ blur ];
  _findBarGlassView.layer.opacity = 0.0f;

  NSRect startFrame = NSOffsetRect(targetFrame, 0.0, 8.0);
  _findBarGlassView.frame = startFrame;

  [CATransaction begin];
  [CATransaction setCompletionBlock:^{
    if (self->_findBarAnimGen == gen && self->_findBarVisible) {
      self->_findBarGlassView.layer.filters = nil;
    }
  }];
  [CATransaction setDisableActions:YES];
  _findBarGlassView.layer.opacity = 1.0f;
  [_findBarGlassView.layer setValue:@(0.0)
                         forKeyPath:@"filters.findBlur.inputRadius"];
  [CATransaction setDisableActions:NO];
  CAMediaTimingFunction* fn =
      [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
  CABasicAnimation* op = [CABasicAnimation animationWithKeyPath:@"opacity"];
  op.fromValue = @(0.0f);
  op.toValue = @(1.0f);
  op.duration = 0.16;
  op.timingFunction = fn;
  [_findBarGlassView.layer addAnimation:op forKey:@"findInOp"];
  CABasicAnimation* bl =
      [CABasicAnimation animationWithKeyPath:@"filters.findBlur.inputRadius"];
  bl.fromValue = @(8.0);
  bl.toValue = @(0.0);
  bl.duration = 0.16;
  bl.timingFunction = fn;
  [_findBarGlassView.layer addAnimation:bl forKey:@"findInBlur"];
  [CATransaction commit];

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.16;
    ctx.timingFunction = fn;
    _findBarGlassView.animator.frame = targetFrame;
  }
                      completionHandler:nil];

  [_window makeFirstResponder:_findField];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_findBarVisible && self->_findField.currentEditor) {
      [self->_findField.currentEditor selectAll:nil];
    }
  });
  NSString* existing = _findField.stringValue ?: @"";
  if (existing.length > 0 && _bridge) {
    _bridge->StartFindInPage(base::SysNSStringToUTF16(existing),
                             /*forward=*/true, /*find_match=*/true);
  }
}

- (void)dismissFindBarAnimated:(BOOL)animated
                clearSelection:(BOOL)clearSelection {
  if (_bridge) {
    _bridge->StopFindInPage(clearSelection ? true : false);
  }
  if (!_findBarVisible && (!_findBarGlassView || _findBarGlassView.isHidden)) {
    return;
  }
  _findBarVisible = NO;
  NSUInteger gen = ++_findBarAnimGen;
  if (_window.firstResponder == _findField ||
      (_findField.currentEditor &&
       _window.firstResponder == _findField.currentEditor)) {
    [_window makeFirstResponder:nil];
  }
  if (!animated || !_findBarGlassView) {
    _findBarGlassView.hidden = YES;
    _findBarGlassView.layer.filters = nil;
    return;
  }
  CIFilter* blur = [CIFilter filterWithName:@"CIGaussianBlur"];
  [blur setDefaults];
  blur.name = @"findBlur";
  [blur setValue:@(0.0) forKey:@"inputRadius"];
  _findBarGlassView.layer.filters = @[ blur ];

  NSRect endFrame = NSOffsetRect(_findBarGlassView.frame, 0.0, 6.0);
  CAMediaTimingFunction* fn =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _findBarGlassView.layer.opacity = 0.0f;
  [_findBarGlassView.layer setValue:@(6.0)
                         forKeyPath:@"filters.findBlur.inputRadius"];
  [CATransaction setDisableActions:NO];
  CABasicAnimation* op = [CABasicAnimation animationWithKeyPath:@"opacity"];
  op.fromValue = @(1.0f);
  op.toValue = @(0.0f);
  op.duration = 0.13;
  op.timingFunction = fn;
  [_findBarGlassView.layer addAnimation:op forKey:@"findOutOp"];
  CABasicAnimation* bl =
      [CABasicAnimation animationWithKeyPath:@"filters.findBlur.inputRadius"];
  bl.fromValue = @(0.0);
  bl.toValue = @(6.0);
  bl.duration = 0.13;
  bl.timingFunction = fn;
  [_findBarGlassView.layer addAnimation:bl forKey:@"findOutBlur"];
  [CATransaction commit];

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.13;
    ctx.timingFunction = fn;
    _findBarGlassView.animator.frame = endFrame;
  }
                      completionHandler:^{
                        if (self->_findBarAnimGen == gen &&
                            !self->_findBarVisible) {
                          self->_findBarGlassView.hidden = YES;
                          self->_findBarGlassView.layer.filters = nil;
                          self->_findBarGlassView.layer.opacity = 1.0f;
                        }
                      }];
}

- (void)findNext:(BOOL)forward {
  if (!_findBarVisible) {
    [self showFindBar];
  }
  NSString* q = _findField.stringValue ?: @"";
  if (q.length > 0 && _bridge) {
    _bridge->StartFindInPage(base::SysNSStringToUTF16(q),
                             forward ? true : false, /*find_match=*/true);
  }
}

- (void)updateFindBarActiveMatch:(int)active totalMatches:(int)total {
  if (!_findCountLabel) {
    return;
  }
  NSString* q = _findField.stringValue ?: @"";
  if (q.length == 0 || total < 0) {
    _findCountLabel.stringValue = @"";
    _findCountLabel.textColor = NSColor.secondaryLabelColor;
    return;
  }
  if (total == 0) {
    _findCountLabel.stringValue = @"0 of 0";
    _findCountLabel.textColor =
        [NSColor.systemRedColor colorWithAlphaComponent:0.88];
  } else {
    int shownActive = std::max(0, active);
    _findCountLabel.stringValue =
        [NSString stringWithFormat:@"%d of %d", shownActive, total];
    _findCountLabel.textColor = NSColor.secondaryLabelColor;
  }
}

- (void)controlTextDidChange:(NSNotification*)obj {
  if (obj.object == _findField && _findBarVisible) {
    NSString* q = _findField.stringValue ?: @"";
    if (_bridge) {
      _bridge->StartFindInPage(base::SysNSStringToUTF16(q), /*forward=*/true,
                               /*find_match=*/true);
    }
    return;
  }
  if (obj.object == _spotlightField && _spotlightActive) {
    NSString* currentText = _spotlightField.stringValue ?: @"";
    _spotlightUserTyped = currentText;
    _spotlightSelectedIndex = -1;
    [self layoutSpotlightInnerControls];
    if (_bridge) {
      _bridge->StartAutocomplete(base::SysNSStringToUTF16(currentText),
                                 /*allow_zero_suggest=*/true);
    }
    return;
  }
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
  if (obj.object == _spotlightField) {
    return;
  }
  if (obj.object == _expandedAddressField && _editingAddress) {
    if (CACurrentMediaTime() < _ignoreEndEditingUntil &&
        _window.isKeyWindow) {
      [_window makeFirstResponder:_expandedAddressField];
      return;
    }
    [self dismissExpandedAddressBarAnimated:YES];
    if (!_pinned && !_settingsPreviewForceOpen && _extensionPopupCount == 0 &&
        _sidebarVisible) {
      [self ensureHoverWatchTimerRunning];
    }
  }
}

- (BOOL)control:(NSControl*)control
               textView:(NSTextView*)textView
    doCommandBySelector:(SEL)commandSelector {
  if (control == _findField && _findBarVisible) {
    if (commandSelector == @selector(insertNewline:)) {
      BOOL shift =
          (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
      [self findNext:!shift];
      return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
      [self dismissFindBarAnimated:YES clearSelection:YES];
      return YES;
    }
    return NO;
  }
  if (control == _spotlightField && _spotlightActive) {
    if (commandSelector == @selector(moveDown:)) {
      if (_spotlightSuggestionItems.count > 0) {
        if (_spotlightSelectedIndex + 1 <
            static_cast<NSInteger>(_spotlightSuggestionItems.count)) {
          _spotlightSelectedIndex += 1;
        } else {
          _spotlightSelectedIndex = -1;
        }
        [self refreshSpotlightSelection];
        return YES;
      }
    }
    if (commandSelector == @selector(moveUp:)) {
      if (_spotlightSuggestionItems.count > 0) {
        if (_spotlightSelectedIndex >= 0) {
          _spotlightSelectedIndex -= 1;
        } else {
          _spotlightSelectedIndex =
              static_cast<NSInteger>(_spotlightSuggestionItems.count) - 1;
        }
        [self refreshSpotlightSelection];
        return YES;
      }
    }
    if (commandSelector == @selector(insertNewline:)) {
      if (_spotlightSelectedIndex >= 0 &&
          _spotlightSelectedIndex <
              static_cast<NSInteger>(_spotlightSuggestionItems.count)) {
        [self acceptSpotlightSuggestionAtIndex:_spotlightSelectedIndex];
        return YES;
      }
      LightSuggestionItem* inlineTop = _spotlightInlineTopItem;
      NSString* input = _spotlightField.stringValue ?: @"";
      if (_bridge) {
        _bridge->StopAutocomplete(/*clear_results=*/false);
      }
      [self dismissSpotlight];
      if (_bridge) {
        if (inlineTop) {
          _bridge->OpenSuggestionItem(inlineTop, /*new_tab=*/true);
        } else {
          NSString* trimmed = [input
              stringByTrimmingCharactersInSet:
                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
          if (trimmed.length > 0) {
            _bridge->NavigateToInput(base::SysNSStringToUTF16(trimmed),
                                     /*new_tab=*/true);
          } else {
            _bridge->CreateNewTab();
          }
        }
      }
      return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
      [self dismissSpotlight];
      return YES;
    }
    return NO;
  }
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
    // Only quit immediately on a deliberate second tap (after Q was released).
    // If the user is continuously holding Cmd+Q, let the smooth left-to-right
    // hold progress bar finish and trigger termination at 100%.
    if (_trafficLightsGroup.qWasReleasedSincePresent) {
      return YES;
    }
    return NO;
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
    _addressContainer.securityIconInteractive = NO;
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
    _addressContainer.securityIconInteractive = YES;
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
    _addressContainer.securityIconInteractive = YES;
  }
  [_window invalidateCursorRectsForView:_addressContainer];

  _expandedSecurityIconView.image = _securityIconView.image;
  if (!_editingAddress) {
    _addressField.stringValue = _displayAddressString ?: @"";
  }
}

- (NSSize)ghostSizeForPinned:(BOOL)asPinned {
  CGFloat w = _scrollView ? _scrollView.bounds.size.width : [self currentSidebarWidth];
  if (asPinned) {
    constexpr CGFloat kPadX = 6.0;
    constexpr CGFloat kGap = 6.0;
    const CGFloat kTileH = [self pinnedTileHeightForWidth:w];
    // Keep pinned drag ghost compact at 1/3 width during hover; on drop into a
    // wider 1/2 or 1/1 slot, animateLandingToOverlayRect smoothly expands it.
    constexpr NSUInteger totalInRow = 3;
    CGFloat contentW = std::max<CGFloat>(40.0, w - kPadX * 2.0);
    CGFloat gaps = (totalInRow - 1) * kGap;
    CGFloat tileW = std::max<CGFloat>(40.0, (contentW - gaps) / totalInRow);
    return NSMakeSize(tileW, kTileH);
  }
  return NSMakeSize(std::max<CGFloat>(100.0, w - 12.0), kTabRowHeight);
}

- (int)modelIndexForVisualSlot:(int)slot pinned:(BOOL)targetPinned {
  if (!_bridge || !_bridge->browser()) {
    return slot;
  }
  TabStripModel* model = _bridge->browser()->GetTabStripModel();
  if (!model) {
    return slot;
  }
  if (targetPinned) {
    int otherPinned = 0;
    for (LightPinnedTileView* tile in _pinnedTileViews) {
      if (tile != _dragSourceView) {
        otherPinned++;
      }
    }
    return std::clamp(slot, 0, otherPinned);
  }
  // Unpinned visual slot -> count non-dragged unpinned tabs preceding `slot`.
  int nonDraggedPinned = 0;
  for (LightPinnedTileView* tile in _pinnedTileViews) {
    if (tile != _dragSourceView) {
      nonDraggedPinned++;
    }
  }
  int tabsBefore = 0;
  int entryIdx = 0;
  for (id entry in _layoutEntries) {
    if (entry == _dragSourceView) {
      continue;
    }
    if (entryIdx >= slot) {
      break;
    }
    if ([entry isKindOfClass:[LightTabRowView class]]) {
      tabsBefore += 1;
    } else if ([entry isKindOfClass:[NSDictionary class]]) {
      NSArray<LightTabRowView*>* rows = entry[@"rows"];
      for (LightTabRowView* r in rows) {
        if (r != _dragSourceView) {
          tabsBefore += 1;
        }
      }
    }
    entryIdx += 1;
  }
  return nonDraggedPinned + tabsBefore;
}

- (void)beginTabDragFromIndex:(int)tabIndex
                         view:(NSView*)sourceView
                       pinned:(BOOL)fromPinned
                  screenPoint:(NSPoint)scrPt {
  if (!_window || !_overlayView || !sourceView || !_bridge) {
    return;
  }
  [_urlBarHoverTrail cancelAllAnimated:NO];
  [_tabHoverTrail cancelAllAnimated:NO];
  [_pinnedHoverTrail cancelAllAnimated:NO];
  _draggedTabIndex = tabIndex;
  _draggedFromPinned = fromPinned;
  _dragSourceView = sourceView;
  _dragDropTargetPinned = fromPinned;
  _dragDropTargetIndex = tabIndex;

  // Determine initial visual slot index in its starting zone.
  _dragDropTargetSlot = 0;
  if (fromPinned) {
    for (NSUInteger i = 0; i < _pinnedTileViews.count; ++i) {
      if (_pinnedTileViews[i] == sourceView) {
        _dragDropTargetSlot = static_cast<int>(i);
        break;
      }
    }
  } else {
    int slot = 0;
    for (id entry in _layoutEntries) {
      if (entry == sourceView) {
        _dragDropTargetSlot = slot;
        break;
      }
      slot++;
    }
  }
  _dragOriginSlot = _dragDropTargetSlot;

  // Extract live title, URL, favicon, selection & container info for the
  // morphing ghost view.
  NSString* title = @"Tab";
  NSString* urlSpec = nil;
  NSImage* favicon = nil;
  NSColor* containerColor = nil;
  BOOL isSelected = NO;
  BOOL isEphemeral = NO;
  BrowserWindowInterface* browser = _bridge->browser();
  BrowserView* browserView = _bridge->browser_view();
  TabStripModel* model = browser ? browser->GetTabStripModel() : nullptr;
  if (model && model->ContainsIndex(tabIndex)) {
    isSelected = (model->active_index() == tabIndex);
    if (tabs::TabInterface* tab = model->GetTabAtIndex(tabIndex)) {
      tabs::TabData data = tabs::TabData::FromTabInterface(tab);
      title = base::SysUTF16ToNSString(data.title);
      urlSpec = base::SysUTF8ToNSString(data.visible_url.spec());
      if ((data.visible_url.SchemeIs("chrome") ||
           data.visible_url.SchemeIs("light")) &&
          data.visible_url.GetHost() == "extensions") {
        favicon = SymbolImage(@"puzzlepiece.extension", 13.5, NSFontWeightMedium);
        [favicon setTemplate:YES];
      } else if (data.should_display_favicon && !data.favicon.IsEmpty() &&
                 browserView && browserView->GetColorProvider() &&
                 !IsNewTabOrBlankURL(data.visible_url)) {
        gfx::ImageSkia skia =
            data.favicon.Rasterize(browserView->GetColorProvider());
        if (!skia.isNull()) {
          favicon = gfx::NSImageFromImageSkia(skia);
        }
      }
    }
    if (content::WebContents* wc = model->GetWebContentsAt(tabIndex)) {
      std::string cid = LightGetTabContainerIdForWebContents(wc);
      if (auto container = LightFindTabContainer(cid)) {
        containerColor = SidebarColorFromHex(container->color_hex);
        isEphemeral =
            (container->clear_behavior ==
                 LightContainerClearBehavior::kOnBrowserQuit ||
             container->clear_behavior ==
                 LightContainerClearBehavior::kOnAllTabsClosed);
      }
    }
  }

  NSPoint winPt = [_window convertPointFromScreen:scrPt];
  NSPoint overlayPt = [_overlayView convertPoint:winPt fromView:nil];
  NSRect srcInOverlay =
      [_overlayView convertRect:sourceView.bounds fromView:sourceView];
  _dragGrabOffset = NSMakePoint(overlayPt.x - NSMidX(srcInOverlay),
                                overlayPt.y - NSMidY(srcInOverlay));

  [_dragGhostView removeFromSuperview];
  _dragGhostView = [[LightDragGhostView alloc] initWithCardRect:srcInOverlay
                                                          title:title
                                                        urlSpec:urlSpec
                                                        favicon:favicon
                                                 containerColor:containerColor
                                                       selected:isSelected
                                             ephemeralContainer:isEphemeral
                                                       asPinned:fromPinned];
  [_overlayView addSubview:_dragGhostView positioned:NSWindowAbove relativeTo:nil];

  // Hide the original view completely — the user has physically picked it up!
  sourceView.alphaValue = 0.0;
  [self layoutTabRowsAnimated:NO];
}

- (void)updateTabDragAtScreenPoint:(NSPoint)scrPt {
  if (_draggedTabIndex < 0 || !_window || !_overlayView || !_tabsDocumentView) {
    return;
  }
  NSPoint winPt = [_window convertPointFromScreen:scrPt];
  NSPoint overlayPt = [_overlayView convertPoint:winPt fromView:nil];
  NSPoint ghostCenter = NSMakePoint(overlayPt.x - _dragGrabOffset.x,
                                    overlayPt.y - _dragGrabOffset.y);
  if (_dragGhostView) {
    [_dragGhostView moveCenterToOverlayPoint:ghostCenter];
  }

  NSPoint docPt = [_tabsDocumentView convertPoint:winPt fromView:nil];
  CGFloat w = _scrollView ? _scrollView.bounds.size.width : [self currentSidebarWidth];
  constexpr CGFloat kPadX = 6.0;
  constexpr CGFloat kGap = 6.0;
  const CGFloat kTileH = [self pinnedTileHeightForWidth:w];
  constexpr int kMaxPerRow = 3;

  int otherPinnedCount = 0;
  for (LightPinnedTileView* tile in _pinnedTileViews) {
    if (tile != _dragSourceView) {
      otherPinnedCount++;
    }
  }
  // Compute deterministic pinned-zone height from the grid containing the
  // preview slot (if already in pinned zone) or existing pinned tiles.
  int pinnedCountIfInZone = otherPinnedCount + 1;
  int rowsIfInZone = (pinnedCountIfInZone + kMaxPerRow - 1) / kMaxPerRow;
  CGFloat pinnedHeightIfInZone = 4.0 + rowsIfInZone * (kTileH + kGap) + 4.0;
  CGFloat pinnedThresholdY =
      (otherPinnedCount > 0 || _dragDropTargetPinned)
          ? pinnedHeightIfInZone
          : 30.0;  // Dragging near top of sidebar pins even when 0 pins exist!

  constexpr CGFloat kHorizontalSlop = 28.0;
  const BOOL inSidebarX =
      (docPt.x >= -kHorizontalSlop && docPt.x <= w + kHorizontalSlop);

  BOOL targetPinned = _draggedFromPinned;
  int targetSlot = _dragOriginSlot;

  if (inSidebarX) {
    targetPinned = (docPt.y <= pinnedThresholdY);
    if (targetPinned) {
      // Deterministic cell math in the 3-column pinned grid — zero oscillation!
      CGFloat contentW = std::max<CGFloat>(1.0, w - kPadX * 2.0);
      int row = std::max(
          0, static_cast<int>(std::floor((docPt.y - 4.0) / (kTileH + kGap))));
      row = std::min(row, std::max(0, rowsIfInZone - 1));
      int rowStart = row * kMaxPerRow;
      int itemsInRow = std::min(kMaxPerRow, pinnedCountIfInZone - rowStart);
      CGFloat colFraction =
          std::clamp<CGFloat>((docPt.x - kPadX) / contentW, 0.0, 0.999);
      int col = std::min(itemsInRow - 1,
                         static_cast<int>(std::floor(colFraction * itemsInRow)));
      targetSlot = std::clamp(rowStart + col, 0, otherPinnedCount);
    } else {
      // Deterministic slot math in unpinned list from un-gapped entry heights!
      int otherPinnedRows =
          otherPinnedCount > 0
              ? ((otherPinnedCount + kMaxPerRow - 1) / kMaxPerRow)
              : 0;
      CGFloat baseY = otherPinnedRows > 0
                          ? (4.0 + otherPinnedRows * (kTileH + kGap) + 4.0)
                          : 4.0;
      int slot = 0;
      for (id entry in _layoutEntries) {
        if (entry == _dragSourceView) {
          continue;
        }
        CGFloat entryH = kTabRowHeight + kTabRowSpacing;
        if ([entry isKindOfClass:[NSDictionary class]]) {
          NSDictionary* dict = (NSDictionary*)entry;
          BOOL collapsed = [dict[@"collapsed"] boolValue];
          if (collapsed) {
            entryH = 38.0;
          } else {
            NSArray<LightTabRowView*>* rows = dict[@"rows"];
            int cnt = 0;
            for (LightTabRowView* r in rows) {
              if (r != _dragSourceView) {
                cnt++;
              }
            }
            entryH = 36.0 + cnt * (kTabRowHeight + kTabRowSpacing) + 7.0;
          }
        }
        if (docPt.y < baseY + entryH * 0.5) {
          break;
        }
        baseY += entryH;
        slot++;
      }
      targetSlot = slot;
    }
  }

  BOOL changed = (targetPinned != _dragDropTargetPinned) ||
                 (targetSlot != _dragDropTargetSlot);
  if (changed) {
    BOOL pinnedChanged = (targetPinned != _dragDropTargetPinned);
    _dragDropTargetPinned = targetPinned;
    _dragDropTargetSlot = targetSlot;
    _dragDropTargetIndex =
        [self modelIndexForVisualSlot:targetSlot pinned:targetPinned];

    if (pinnedChanged && _dragGhostView) {
      // Smoothly center grab offset when morphing between wide row & compact tile.
      _dragGrabOffset = NSZeroPoint;
      NSSize newSize = [self ghostSizeForPinned:targetPinned];
      [_dragGhostView setMorphedAsPinned:targetPinned
                              targetSize:newSize
                            anchorCenter:overlayPt
                                animated:YES];
    }
    // Subtle macOS trackpad alignment haptic tick on slot / zone change!
    [[NSHapticFeedbackManager defaultPerformer]
        performFeedbackPattern:NSHapticFeedbackPatternAlignment
               performanceTime:NSHapticFeedbackPerformanceTimeNow];
    // Physically slide all other pinned tiles & unpinned tabs out of the way!
    [self layoutTabRowsAnimated:YES];
  }
}

- (void)endTabDragAtScreenPoint:(NSPoint)scrPt {
  if (_draggedTabIndex < 0) {
    return;
  }
  [self updateTabDragAtScreenPoint:scrPt];
  int fromIdx = _draggedTabIndex;
  BOOL targetPinned = _dragDropTargetPinned;
  int targetIdx = _dragDropTargetIndex;

  LightDragGhostView* ghost = _dragGhostView;
  NSView* srcView = _dragSourceView;
  NSRect landingInOverlay = NSZeroRect;
  if (!NSIsEmptyRect(_dragPreviewSlotFrameInDoc) && _tabsDocumentView && _overlayView) {
    landingInOverlay =
        [_overlayView convertRect:_dragPreviewSlotFrameInDoc fromView:_tabsDocumentView];
  }

  _draggedTabIndex = -1;
  _dragSourceView = nil;
  _dragGhostView = nil;

  uintptr_t droppedWC = 0;
  BOOL droppedWasSelected = NO;
  if (targetPinned && _bridge) {
    BrowserWindowInterface* browser = _bridge->browser();
    TabStripModel* model = browser ? browser->GetTabStripModel() : nullptr;
    if (model && model->ContainsIndex(fromIdx)) {
      droppedWC = reinterpret_cast<uintptr_t>(model->GetWebContentsAt(fromIdx));
      droppedWasSelected = (model->active_index() == fromIdx);
    }
  }

  auto finishCommit = ^{
    [ghost removeFromSuperview];
    srcView.alphaValue = 1.0;
    if (targetPinned && droppedWC != 0) {
      self->_recentlyDroppedPinnedWC = droppedWC;
      self->_recentlyDroppedPinnedWasSelected = droppedWasSelected;
    }
    if (self->_bridge) {
      self->_bridge->DropTabAt(fromIdx, targetPinned ? true : false, targetIdx);
    }
  };

  if (ghost && !NSIsEmptyRect(landingInOverlay)) {
    const BOOL widthExpanding =
        std::abs(landingInOverlay.size.width - ghost.targetCardSize.width) > 8.0;
    const NSTimeInterval landDuration = widthExpanding ? 0.20 : 0.16;
    [ghost animateLandingToOverlayRect:landingInOverlay
                              duration:landDuration
                            completion:finishCommit];
  } else {
    finishCommit();
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

  int selectedCount = 0;
  for (int i = 0; i < count; ++i) {
    if (model->IsTabSelected(i)) {
      selectedCount++;
    }
  }
  const BOOL hasMultiSelect = selectedCount > 1;

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

  const NSUInteger prevPinnedCount = _pinnedTileViews.count;
  const NSUInteger prevUnpinnedCount = _tabRowViews.count;
  if (_draggedTabIndex >= 0 &&
      (prevPinnedCount != pinnedIndices.size() ||
       prevUnpinnedCount != unpinnedIndices.size())) {
    _draggedTabIndex = -1;
    _dragSourceView.alphaValue = 1.0;
    _dragSourceView = nil;
    [_dragGhostView removeFromSuperview];
    _dragGhostView = nil;
  }
  if (prevPinnedCount != pinnedIndices.size() ||
      prevUnpinnedCount != unpinnedIndices.size()) {
    [_tabHoverTrail cancelAllAnimated:NO];
    [_pinnedHoverTrail cancelAllAnimated:NO];
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
    tile.onSelect = ^(int idx, NSEventModifierFlags mods) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (!s || !s->_bridge) {
        return;
      }
      BOOL shift = (mods & NSEventModifierFlagShift) != 0;
      BOOL cmd = (mods & NSEventModifierFlagCommand) != 0;
      s->_bridge->SelectTabAt(idx, shift, cmd);
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
    tile.onDragStart = ^(int idx, NSView* v, NSPoint scrPt) {
      [weakSelf beginTabDragFromIndex:idx view:v pinned:YES screenPoint:scrPt];
    };
    tile.onDragAtScreenPoint = ^(int idx, NSPoint scrPt) {
      (void)idx;
      [weakSelf updateTabDragAtScreenPoint:scrPt];
    };
    tile.onDragEnd = ^(int idx, NSPoint scrPt) {
      (void)idx;
      [weakSelf endTabDragAtScreenPoint:scrPt];
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
    row.onSelect = ^(int idx, NSEventModifierFlags mods) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        BOOL shift = (mods & NSEventModifierFlagShift) != 0;
        BOOL cmd = (mods & NSEventModifierFlagCommand) != 0;
        s->_bridge->SelectTabAt(idx, shift, cmd);
      }
    };
    row.onClose = ^(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      if (s && s->_bridge) {
        s->_bridge->CloseTabAt(idx);
      }
    };
    row.onDragStart = ^(int idx, NSView* v, NSPoint scrPt) {
      [weakSelf beginTabDragFromIndex:idx view:v pinned:NO screenPoint:scrPt];
    };
    row.onDragAtScreenPoint = ^(int idx, NSPoint scrPt) {
      (void)idx;
      [weakSelf updateTabDragAtScreenPoint:scrPt];
    };
    row.onDragEnd = ^(int idx, NSPoint scrPt) {
      (void)idx;
      [weakSelf endTabDragAtScreenPoint:scrPt];
    };
    row.menuProvider = ^NSMenu*(int idx) {
      __strong __typeof(weakSelf) s = weakSelf;
      return s ? [s buildTabContextMenuForIndex:idx] : nil;
    };
    [_tabsDocumentView addSubview:row];
    [_tabRowViews addObject:row];
  }

  auto extractFavicon = [&](const tabs::TabData& data) -> NSImage* {
    if ((data.visible_url.SchemeIs("chrome") ||
         data.visible_url.SchemeIs("light")) &&
        data.visible_url.GetHost() == "extensions") {
      NSImage* extSym =
          SymbolImage(@"puzzlepiece.extension", 13.5, NSFontWeightMedium);
      [extSym setTemplate:YES];
      return extSym;
    }
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

    NSColor* pinContainerCol = nil;
    BOOL pinEphemeral = NO;
    if (wc) {
      std::string cid = LightGetTabContainerIdForWebContents(wc);
      if (auto container = LightFindTabContainer(cid)) {
        pinContainerCol = SidebarColorFromHex(container->color_hex);
        pinEphemeral =
            (container->clear_behavior ==
                 LightContainerClearBehavior::kOnBrowserQuit ||
             container->clear_behavior ==
                 LightContainerClearBehavior::kOnAllTabsClosed);
      }
    }

    LightPinnedTileView* tile = _pinnedTileViews[p];
    tile.tabIndex = i;
    BOOL isUnloaded = wc && wc->WasDiscarded();
    [tile configureWithTitle:title
                     urlSpec:urlSpec
                     favicon:extractFavicon(data)
                   isLoading:isLoading
                    unloaded:isUnloaded
                    selected:(i == activeIndex)
               multiSelected:(hasMultiSelect && model->IsTabSelected(i))
                     audible:audible
                       muted:muted
              containerColor:pinContainerCol
          ephemeralContainer:pinEphemeral];
    if (wc && reinterpret_cast<uintptr_t>(wc) == _recentlyDroppedPinnedWC) {
      // Resting backing already cross-faded in during the landing animation.
      _recentlyDroppedPinnedWC = 0;
      _recentlyDroppedPinnedWasSelected = NO;
    }
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

    NSString* containerSym = nil;
    NSColor* containerCol = nil;
    if (content::WebContents* wc = model->GetWebContentsAt(i)) {
      std::string cid = LightGetTabContainerIdForWebContents(wc);
      if (auto container = LightFindTabContainer(cid)) {
        containerSym = base::SysUTF8ToNSString(container->symbol);
        containerCol = SidebarColorFromHex(container->color_hex);
      }
    }

    LightTabRowView* row = _tabRowViews[u];
    row.tabIndex = i;
    [row configureWithTitle:title
                    favicon:extractFavicon(data)
                  isLoading:isLoading
                   selected:(i == activeIndex)
              multiSelected:(hasMultiSelect && model->IsTabSelected(i))
                     pinned:NO
            containerSymbol:containerSym
             containerColor:containerCol];
  }

  // Group unpinned rows into contiguous Tab Group blocks and standalone rows.
  [_layoutEntries removeAllObjects];
  NSUInteger groupBlockCursor = 0;
  LightTabGroupBlockView* blockToFocusRename = nil;

  size_t u = 0;
  while (u < unpinnedIndices.size()) {
    int idx = unpinnedIndices[u];
    std::optional<tab_groups::TabGroupId> gid = model->GetTabGroupForTab(idx);
    if (!gid.has_value() || !model->group_model() ||
        !model->group_model()->ContainsTabGroup(*gid)) {
      [_layoutEntries addObject:_tabRowViews[u]];
      ++u;
      continue;
    }

    // Gather contiguous tabs belonging to `*gid`.
    NSMutableArray<LightTabRowView*>* groupRows = [NSMutableArray array];
    NSImage* firstFavicon = nil;
    NSString* fallbackLabel = @"Untitled";
    while (u < unpinnedIndices.size() &&
           model->GetTabGroupForTab(unpinnedIndices[u]) == gid) {
      int memberIdx = unpinnedIndices[u];
      if (!firstFavicon) {
        if (tabs::TabInterface* t = model->GetTabAtIndex(memberIdx)) {
          tabs::TabData td = tabs::TabData::FromTabInterface(t);
          firstFavicon = extractFavicon(td);
          if (td.title.size() > 0 && [fallbackLabel isEqualToString:@"Untitled"]) {
            fallbackLabel = base::SysUTF16ToNSString(td.title);
          }
        }
      }
      [groupRows addObject:_tabRowViews[u]];
      ++u;
    }

    while (_groupBlockViews.count <= groupBlockCursor) {
      LightTabGroupBlockView* block =
          [[LightTabGroupBlockView alloc] initWithFrame:NSZeroRect];
      block.onToggleCollapse = ^(NSString* tok) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->ToggleCollapseGroupToken(tok);
        }
      };
      block.onCommitRename = ^(NSString* tok, NSString* newTitle) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s) {
          s->_renamingGroupToken = @"";
          if (s->_bridge) {
            s->_bridge->RenameGroupToken(tok, newTitle);
          }
          [s reloadTabsAndNavigation];
        }
      };
      block.onCancelRename = ^(NSString* tok) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s) {
          s->_renamingGroupToken = @"";
          [s reloadTabsAndNavigation];
        }
      };
      block.onNewTabInGroup = ^(NSString* tok) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->CreateNewTabInGroupToken(tok);
        }
      };
      block.onCloseGroup = ^(NSString* tok) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s->_bridge) {
          s->_bridge->CloseGroupToken(tok);
        }
      };
      block.menuProvider = ^NSMenu*(NSString* tok) {
        __strong __typeof(weakSelf) s = weakSelf;
        return s ? [s buildGroupContextMenuForToken:tok] : nil;
      };
      // Insert behind tab rows so group card paints behind member rows!
      [_tabsDocumentView addSubview:block
                         positioned:NSWindowBelow
                         relativeTo:nil];
      [_groupBlockViews addObject:block];
    }

    LightTabGroupBlockView* block = _groupBlockViews[groupBlockCursor++];
    TabGroup* tg = model->group_model()->GetTabGroup(*gid);
    const auto* vd = tg ? tg->visual_data() : nullptr;
    NSString* token = base::SysUTF8ToNSString(gid->ToString());
    NSString* gTitle =
        vd ? base::SysUTF16ToNSString(vd->title()) : @"";
    tab_groups::TabGroupColorId gColor =
        vd ? vd->color() : tab_groups::TabGroupColorId::kGrey;
    BOOL gCollapsed = vd ? (vd->is_collapsed() ? YES : NO) : NO;
    BOOL isRenaming =
        (_renamingGroupToken.length > 0 &&
         [_renamingGroupToken isEqualToString:token]);

    [block configureWithToken:token
                        title:gTitle
                fallbackLabel:fallbackLabel
                      colorId:gColor
                    collapsed:gCollapsed
              firstTabFavicon:firstFavicon
                     renaming:isRenaming];
    if (isRenaming) {
      blockToFocusRename = block;
    }

    [_layoutEntries addObject:@{
      @"block" : block,
      @"rows" : groupRows,
      @"collapsed" : @(gCollapsed),
    }];
  }

  while (_groupBlockViews.count > groupBlockCursor) {
    LightTabGroupBlockView* extra = _groupBlockViews.lastObject;
    [extra removeFromSuperview];
    [_groupBlockViews removeLastObject];
  }

  // Ensure every live tab view is visible and sweep any orphaned tab subviews.
  for (LightPinnedTileView* tile in _pinnedTileViews) {
    if (tile != _dragSourceView) {
      tile.alphaValue = 1.0;
    }
  }
  for (LightTabRowView* row in _tabRowViews) {
    if (row != _dragSourceView) {
      row.alphaValue = 1.0;
    }
  }
  for (NSView* sub in [_tabsDocumentView.subviews copy]) {
    if (([sub isKindOfClass:[LightTabRowView class]] &&
         ![_tabRowViews containsObject:(LightTabRowView*)sub]) ||
        ([sub isKindOfClass:[LightPinnedTileView class]] &&
         ![_pinnedTileViews containsObject:(LightPinnedTileView*)sub]) ||
        ([sub isKindOfClass:[LightTabGroupBlockView class]] &&
         ![_groupBlockViews containsObject:(LightTabGroupBlockView*)sub])) {
      [sub removeFromSuperview];
    }
  }

  [self layoutTabRows];

  if (blockToFocusRename) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [blockToFocusRename focusInlineRenameEditor];
    });
  }
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

@interface LightExtensionsMenuBridge : NSObject
+ (void)populateExtensionsMenu:(NSMenu*)menu;
@end

@implementation LightExtensionsMenuBridge

+ (void)populateExtensionsMenu:(NSMenu*)menu {
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
    if (target) {
      [target populateExtensionsMenu:menu];
    }
  }
}

@end

@interface LightSidebarExtensionPopupBridge : NSObject
+ (NSValue*)beginExtensionPopupForWindow:(NSWindow*)window;
+ (void)endExtensionPopupForWindow:(NSWindow*)window;
@end

@implementation LightSidebarExtensionPopupBridge

+ (LightGlassSidebarObjCController*)controllerForWindow:(NSWindow*)window
    API_AVAILABLE(macos(26.0)) {
  NSWindow* targetWin = window ?: (NSApp.keyWindow ?: NSApp.mainWindow);
  LightGlassSidebarObjCController* fallback = nil;
  for (id obj in ActiveSidebarControllers()) {
    LightGlassSidebarObjCController* ctrl =
        (LightGlassSidebarObjCController*)obj;
    if (ctrl.targetWindow == targetWin) {
      return ctrl;
    }
    if (!fallback && ctrl.targetWindow.isVisible) {
      fallback = ctrl;
    }
  }
  return fallback;
}

+ (NSValue*)beginExtensionPopupForWindow:(NSWindow*)window {
  if (@available(macOS 26.0, *)) {
    LightGlassSidebarObjCController* ctrl = [self controllerForWindow:window];
    if (ctrl) {
      return [NSValue valueWithRect:[ctrl beginExtensionPopup]];
    }
  }
  return [NSValue valueWithRect:NSZeroRect];
}

+ (void)endExtensionPopupForWindow:(NSWindow*)window {
  if (@available(macOS 26.0, *)) {
    LightGlassSidebarObjCController* ctrl = [self controllerForWindow:window];
    if (ctrl) {
      [ctrl endExtensionPopup];
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
gfx::Insets LightGlassSidebarBridge::GetContentFrameInsetsForBrowserView(
    const BrowserView* browser_view) {
  auto it = ActiveSidebarBridges().find(browser_view);
  if (it == ActiveSidebarBridges().end() || !it->second) {
    return gfx::Insets();
  }
  return it->second->GetContentFrameInsets();
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

gfx::Rect LightBeginSidebarExtensionPopup(gfx::NativeWindow browser_window) {
  NSWindow* nsWin = browser_window.GetNativeNSWindow();
  NSValue* val =
      [LightSidebarExtensionPopupBridge beginExtensionPopupForWindow:nsWin];
  NSRect cocoaRect = val ? val.rectValue : NSZeroRect;
  if (NSIsEmptyRect(cocoaRect)) {
    return gfx::Rect();
  }
  // Anchor immediately to the right of the sidebar.
  NSRect anchorRect = NSMakeRect(NSMaxX(cocoaRect) + 8.0, cocoaRect.origin.y,
                                 1.0, std::max<CGFloat>(1.0, cocoaRect.size.height));
  return gfx::ScreenRectFromNSRect(anchorRect);
}

void LightEndSidebarExtensionPopup(gfx::NativeWindow browser_window) {
  NSWindow* nsWin = browser_window.GetNativeNSWindow();
  [LightSidebarExtensionPopupBridge endExtensionPopupForWindow:nsWin];
}
