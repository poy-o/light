// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/views/frame/light_native_settings_controller.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/themes/theme_service_factory.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/views/frame/light_tab_containers_mac.h"
#include "chrome/common/pref_names.h"
#include "components/omnibox/browser/omnibox_prefs.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_service.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

constexpr CGFloat kSettingsSidebarWidth = 232.0;
constexpr CGFloat kContentMaxWidth = 560.0;

NSImage* SettingsSymbol(NSString* name, CGFloat size, NSFontWeight weight) {
  NSImage* img = [NSImage imageWithSystemSymbolName:name
                           accessibilityDescription:nil];
  if (!img) {
    return nil;
  }
  NSImageSymbolConfiguration* cfg =
      [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
  return [img imageWithSymbolConfiguration:cfg];
}

void PostLightSettingsChanged() {
  [NSNotificationCenter.defaultCenter
      postNotificationName:@"LightSettingsDidChangeNotification"
                    object:nil];
}

bool UDGetBool(NSString* key, bool fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj boolValue];
  }
  return fallback;
}

void UDSetBool(NSString* key, bool val) {
  [NSUserDefaults.standardUserDefaults setBool:val forKey:key];
  PostLightSettingsChanged();
}

double UDGetDouble(NSString* key, double fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj doubleValue];
  }
  return fallback;
}

void UDSetDouble(NSString* key, double val) {
  [NSUserDefaults.standardUserDefaults setDouble:val forKey:key];
  PostLightSettingsChanged();
}

NSInteger UDGetInt(NSString* key, NSInteger fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj integerValue];
  }
  return fallback;
}

void UDSetInt(NSString* key, NSInteger val) {
  [NSUserDefaults.standardUserDefaults setInteger:val forKey:key];
  PostLightSettingsChanged();
}

bool PrefGetBool(PrefService* prefs, const char* key, bool fallback) {
  if (!prefs || !prefs->FindPreference(key)) {
    return fallback;
  }
  return prefs->GetBoolean(key);
}

void PrefSetBool(PrefService* prefs, const char* key, bool val) {
  if (prefs && prefs->FindPreference(key)) {
    prefs->SetBoolean(key, val);
  }
}

int PrefGetInt(PrefService* prefs, const char* key, int fallback) {
  if (!prefs || !prefs->FindPreference(key)) {
    return fallback;
  }
  return prefs->GetInteger(key);
}

void PrefSetInt(PrefService* prefs, const char* key, int val) {
  if (prefs && prefs->FindPreference(key)) {
    prefs->SetInteger(key, val);
  }
}

std::string PrefGetString(PrefService* prefs,
                          const char* key,
                          const std::string& fallback) {
  if (!prefs || !prefs->FindPreference(key)) {
    return fallback;
  }
  return prefs->GetString(key);
}

void PrefSetString(PrefService* prefs,
                   const char* key,
                   const std::string& val) {
  if (prefs && prefs->FindPreference(key)) {
    prefs->SetString(key, val);
  }
}

}  // namespace

// -----------------------------------------------------------------------------
// Flipped NSView helper for top-down System Settings scroll layout.
// -----------------------------------------------------------------------------
@interface LightSettingsFlippedView : NSView
@end

@implementation LightSettingsFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

// -----------------------------------------------------------------------------
// Action wrapper so standard AppKit controls (NSSwitch, NSPopUpButton, etc.)
// can invoke Objective-C blocks cleanly.
// -----------------------------------------------------------------------------
@interface LightControlBlockTarget : NSObject
@property(nonatomic, copy) void (^handler)(id sender);
+ (instancetype)targetWithBlock:(void (^)(id sender))block;
- (void)invoke:(id)sender;
@end

@implementation LightControlBlockTarget
@synthesize handler = _handler;

+ (instancetype)targetWithBlock:(void (^)(id sender))block {
  LightControlBlockTarget* t = [[LightControlBlockTarget alloc] init];
  t.handler = block;
  return t;
}

- (void)invoke:(id)sender {
  if (_handler) {
    _handler(sender);
  }
}
@end

// -----------------------------------------------------------------------------
// Rounded squircle colored icon badge (exactly like macOS System Settings).
// -----------------------------------------------------------------------------
@interface LightSettingsIconBadgeView : NSView
- (instancetype)initWithSymbol:(NSString*)symbol color:(NSColor*)color;
@end

@implementation LightSettingsIconBadgeView {
  NSColor* __strong _color;
  NSImageView* __strong _iconView;
}

- (instancetype)initWithSymbol:(NSString*)symbol color:(NSColor*)color {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 24, 24)])) {
    _color = color;
    self.wantsLayer = YES;
    _iconView = [[NSImageView alloc] initWithFrame:self.bounds];
    _iconView.image = SettingsSymbol(symbol, 12.5, NSFontWeightSemibold);
    _iconView.contentTintColor = NSColor.whiteColor;
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    _iconView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_iconView];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:6.0
                                                       yRadius:6.0];
  [_color setFill];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Sidebar category row in the left System Settings navigation list.
// -----------------------------------------------------------------------------
@interface LightSettingsSidebarRowView : NSView
@property(nonatomic, assign) NSInteger categoryIndex;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, copy) void (^onSelect)(NSInteger index);
- (instancetype)initWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                        color:(NSColor*)color
                        index:(NSInteger)index;
@end

@implementation LightSettingsSidebarRowView {
  LightSettingsIconBadgeView* __strong _badge;
  NSTextField* __strong _label;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
}

@synthesize categoryIndex = _categoryIndex;
@synthesize selected = _selected;
@synthesize onSelect = _onSelect;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                        color:(NSColor*)color
                        index:(NSInteger)index {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _categoryIndex = index;
    self.wantsLayer = YES;
    _badge = [[LightSettingsIconBadgeView alloc] initWithSymbol:symbol
                                                          color:color];
    [self addSubview:_badge];

    _label = [NSTextField labelWithString:title];
    _label.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_label];
  }
  return self;
}

- (void)setSelected:(BOOL)selected {
  _selected = selected;
  _label.font = [NSFont
      systemFontOfSize:13.0
                weight:selected ? NSFontWeightMedium : NSFontWeightRegular];
  _label.textColor = selected ? NSColor.whiteColor : NSColor.labelColor;
  [self setNeedsDisplay:YES];
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  CGFloat w = self.bounds.size.width;
  _badge.frame = NSMakeRect(8.0, std::floor((h - 22.0) * 0.5), 22.0, 22.0);
  NSSize fit = [_label sizeThatFits:NSMakeSize(300.0, h)];
  _label.frame =
      NSMakeRect(38.0, std::floor((h - fit.height) * 0.5),
                 std::max<CGFloat>(0.0, w - 46.0), std::ceil(fit.height));
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
  if (_onSelect) {
    _onSelect(_categoryIndex);
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  if (!_selected && !_hovered) {
    return;
  }
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:7.0
                                                       yRadius:7.0];
  if (_selected) {
    [[NSColor controlAccentColor] setFill];
  } else {
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
  }
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Grouped inset rounded card (macOS System Settings Form group).
// -----------------------------------------------------------------------------
@interface LightSettingsCardView : NSView
@property(nonatomic, copy) void (^onHoverChanged)(BOOL hovered);
@end

@implementation LightSettingsCardView {
  NSTrackingArea* __strong _hoverTrackingArea;
}

@synthesize onHoverChanged = _onHoverChanged;

- (BOOL)isFlipped {
  return YES;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverTrackingArea) {
    [self removeTrackingArea:_hoverTrackingArea];
    _hoverTrackingArea = nil;
  }
  if (_onHoverChanged) {
    _hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                      NSTrackingActiveAlways | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
  }
}

- (void)mouseEntered:(NSEvent*)event {
  if (_onHoverChanged) {
    _onHoverChanged(YES);
  }
}

- (void)mouseMoved:(NSEvent*)event {
  if (_onHoverChanged) {
    _onHoverChanged(YES);
  }
}

- (void)mouseExited:(NSEvent*)event {
  if (_onHoverChanged) {
    _onHoverChanged(NO);
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:10.0
                                                       yRadius:10.0];
  [[NSColor.labelColor colorWithAlphaComponent:0.045] setFill];
  [path fill];
}

@end

// -----------------------------------------------------------------------------
// Main Native System Settings Window Controller
// -----------------------------------------------------------------------------
@interface LightNativeSettingsWindowController
    : NSObject <NSWindowDelegate, NSSearchFieldDelegate>

@property(nonatomic, readonly) NSWindow* window;

- (instancetype)initWithProfile:(Profile*)profile
                        browser:(BrowserWindowInterface*)browser;
- (void)updateContextWithProfile:(Profile*)profile
                         browser:(BrowserWindowInterface*)browser;
- (void)selectCategoryByTitle:(NSString*)title;
- (void)showWindow;

@end

@implementation LightNativeSettingsWindowController {
  NSWindow* __strong _window;
  raw_ptr<Profile> _profile;
  raw_ptr<BrowserWindowInterface> _browser;

  NSView* __strong _sidebarHost;
  NSSearchField* __strong _searchField;
  NSScrollView* __strong _sidebarScroll;
  LightSettingsFlippedView* __strong _sidebarDoc;
  NSMutableArray<NSDictionary*>* __strong _categories;
  NSMutableArray<LightSettingsSidebarRowView*>* __strong _sidebarRows;
  NSInteger _selectedCategory;

  NSView* __strong _detailPane;
  NSTextField* __strong _pageTitleLabel;
  NSScrollView* __strong _detailScroll;
  LightSettingsFlippedView* __strong _detailDoc;
  LightSettingsCardView* __weak _sidebarPreviewCard;
  NSTimer* __strong _sidebarPreviewWatchTimer;
  BOOL _sidebarPreviewHovering;
  NSMutableArray<LightControlBlockTarget*>* __strong _retainedTargets;
}

@synthesize window = _window;

- (instancetype)initWithProfile:(Profile*)profile
                        browser:(BrowserWindowInterface*)browser {
  if ((self = [super init])) {
    _profile = profile;
    _browser = browser;
    _retainedTargets = [NSMutableArray array];
    _sidebarRows = [NSMutableArray array];
    _selectedCategory = 0;

    _categories = [@[
      @{
        @"title" : @"Custom",
        @"symbol" : @"sparkles",
        @"color" : NSColor.systemIndigoColor,
        @"keywords" : @"corner radius sidebar blur spring animation log light"
      },
      @{
        @"title" : @"Containers",
        @"symbol" : @"square.stack.3d.up.fill",
        @"color" : NSColor.systemPurpleColor,
        @"keywords" : @"container private isolated tab profile cookies storage"
      },
      @{
        @"title" : @"General",
        @"symbol" : @"gear",
        @"color" : NSColor.systemGrayColor,
        @"keywords" : @"startup restore home page hardware acceleration"
      },
      @{
        @"title" : @"Appearance",
        @"symbol" : @"paintbrush.fill",
        @"color" : NSColor.systemCyanColor,
        @"keywords" : @"theme dark light mode font size url"
      },
      @{
        @"title" : @"Search Engine",
        @"symbol" : @"magnifyingglass",
        @"color" : NSColor.systemBlueColor,
        @"keywords" : @"google duckduckgo bing search omnibox"
      },
      @{
        @"title" : @"Privacy & Security",
        @"symbol" : @"hand.raised.fill",
        @"color" : NSColor.systemBlueColor,
        @"keywords" : @"https safe browsing cookies do not track clear data"
      },
      @{
        @"title" : @"Autofill & Passwords",
        @"symbol" : @"key.fill",
        @"color" : NSColor.systemOrangeColor,
        @"keywords" : @"passwords sign in addresses payment credit cards"
      },
      @{
        @"title" : @"Downloads",
        @"symbol" : @"arrow.down.circle.fill",
        @"color" : NSColor.systemBlueColor,
        @"keywords" : @"download folder directory ask where save"
      },
      @{
        @"title" : @"Performance",
        @"symbol" : @"gauge.with.dots.needle.67percent",
        @"color" : NSColor.systemGreenColor,
        @"keywords" : @"memory saver battery energy efficiency"
      },
      @{
        @"title" : @"Languages",
        @"symbol" : @"globe",
        @"color" : NSColor.systemTealColor,
        @"keywords" : @"spellcheck spelling translate languages"
      },
    ] mutableCopy];

    [self buildWindow];
    [self selectCategory:0];
  }
  return self;
}

- (void)updateContextWithProfile:(Profile*)profile
                         browser:(BrowserWindowInterface*)browser {
  if (profile) {
    _profile = profile;
  }
  if (browser) {
    _browser = browser;
  }
  [self rebuildDetailPage];
}

- (void)showWindow {
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildWindow {
  NSRect initialRect = NSMakeRect(0, 0, 780, 580);
  NSWindowStyleMask style =
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
      NSWindowStyleMaskFullSizeContentView;
  _window = [[NSWindow alloc] initWithContentRect:initialRect
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"Settings";
  _window.titleVisibility = NSWindowTitleHidden;
  _window.titlebarAppearsTransparent = YES;
  _window.releasedWhenClosed = NO;
  _window.minSize = NSMakeSize(660, 440);
  _window.delegate = self;
  [_window center];

  NSView* root = _window.contentView;
  root.wantsLayer = YES;

  // Left sidebar with macOS 26 Liquid Glass / VisualEffect material.
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc]
        initWithFrame:NSMakeRect(0, 0, kSettingsSidebarWidth, 580)];
    glass.style = NSGlassEffectViewStyleRegular;
    glass.cornerRadius = 0.0;
    glass.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    NSView* inner = [[NSView alloc] initWithFrame:glass.bounds];
    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.contentView = inner;
    [root addSubview:glass];
    _sidebarHost = inner;
  } else {
    NSVisualEffectView* vfx = [[NSVisualEffectView alloc]
        initWithFrame:NSMakeRect(0, 0, kSettingsSidebarWidth, 580)];
    vfx.material = NSVisualEffectMaterialSidebar;
    vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    vfx.state = NSVisualEffectStateFollowsWindowActiveState;
    vfx.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [root addSubview:vfx];
    _sidebarHost = vfx;
  }

  // Vertical hairline divider between sidebar and detail pane.
  NSBox* divider = [[NSBox alloc]
      initWithFrame:NSMakeRect(kSettingsSidebarWidth, 0, 1.0, 580)];
  divider.boxType = NSBoxCustom;
  divider.borderWidth = 0.0;
  divider.fillColor = [NSColor.separatorColor colorWithAlphaComponent:0.45];
  divider.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
  [root addSubview:divider];

  // Search field at top of sidebar (below traffic lights).
  _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  _searchField.placeholderString = @"Search";
  _searchField.font = [NSFont systemFontOfSize:12.5];
  _searchField.delegate = self;
  [_sidebarHost addSubview:_searchField];

  _sidebarScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _sidebarScroll.drawsBackground = NO;
  _sidebarScroll.hasVerticalScroller = YES;
  _sidebarScroll.autohidesScrollers = YES;
  _sidebarScroll.borderType = NSNoBorder;
  _sidebarDoc = [[LightSettingsFlippedView alloc] initWithFrame:NSZeroRect];
  _sidebarScroll.documentView = _sidebarDoc;
  [_sidebarHost addSubview:_sidebarScroll];

  __weak __typeof(self) weakSelf = self;
  for (NSUInteger i = 0; i < _categories.count; ++i) {
    NSDictionary* cat = _categories[i];
    LightSettingsSidebarRowView* row = [[LightSettingsSidebarRowView alloc]
        initWithTitle:cat[@"title"]
               symbol:cat[@"symbol"]
                color:cat[@"color"]
                index:static_cast<NSInteger>(i)];
    row.onSelect = ^(NSInteger idx) {
      [weakSelf selectCategory:idx];
    };
    [_sidebarDoc addSubview:row];
    [_sidebarRows addObject:row];
  }

  // Right detail pane.
  _detailPane = [[NSView alloc]
      initWithFrame:NSMakeRect(kSettingsSidebarWidth + 1.0, 0,
                               780 - kSettingsSidebarWidth - 1.0, 580)];
  _detailPane.wantsLayer = YES;
  _detailPane.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
  _detailPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_detailPane];

  _pageTitleLabel = [NSTextField labelWithString:@"Custom"];
  _pageTitleLabel.font = [NSFont systemFontOfSize:20.0 weight:NSFontWeightBold];
  _pageTitleLabel.textColor = NSColor.labelColor;
  [_detailPane addSubview:_pageTitleLabel];

  _detailScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _detailScroll.drawsBackground = NO;
  _detailScroll.hasVerticalScroller = YES;
  _detailScroll.autohidesScrollers = YES;
  _detailScroll.borderType = NSNoBorder;
  _detailDoc = [[LightSettingsFlippedView alloc] initWithFrame:NSZeroRect];
  _detailScroll.documentView = _detailDoc;
  [_detailPane addSubview:_detailScroll];

  [self layoutWindowSubviews];
}

- (void)windowWillClose:(NSNotification*)notification {
  [self setSidebarPreviewHovering:NO];
}

- (void)setSidebarPreviewHovering:(BOOL)hovering {
  if (_sidebarPreviewHovering == hovering) {
    return;
  }
  _sidebarPreviewHovering = hovering;
  [NSNotificationCenter.defaultCenter
      postNotificationName:@"LightSettingsSidebarPreviewHoverNotification"
                    object:nil
                  userInfo:@{@"hovering" : @(hovering)}];
  if (hovering) {
    if (!_sidebarPreviewWatchTimer) {
      __weak __typeof(self) weakSelf = self;
      _sidebarPreviewWatchTimer = [NSTimer
          scheduledTimerWithTimeInterval:0.05
                                 repeats:YES
                                   block:^(NSTimer* t) {
                                     [weakSelf checkSidebarPreviewHoverState];
                                   }];
    }
  } else {
    [_sidebarPreviewWatchTimer invalidate];
    _sidebarPreviewWatchTimer = nil;
  }
}

- (void)checkSidebarPreviewHoverState {
  if (!_window.isVisible || _selectedCategory != 0 || !_sidebarPreviewCard ||
      !_sidebarPreviewCard.window) {
    [self setSidebarPreviewHovering:NO];
    return;
  }
  // Keep preview open while actively dragging a slider inside the card or
  // picking a tint color in NSColorPanel.
  if ([NSEvent pressedMouseButtons] != 0) {
    return;
  }
  NSPoint scrPt = [NSEvent mouseLocation];
  if (NSColorPanel.sharedColorPanelExists &&
      NSColorPanel.sharedColorPanel.isVisible &&
      NSPointInRect(scrPt,
                    NSInsetRect(NSColorPanel.sharedColorPanel.frame, -12, -12))) {
    return;
  }
  NSPoint winPt = [_window convertPointFromScreen:scrPt];
  NSPoint scrollPt = [_detailScroll convertPoint:winPt fromView:nil];
  if (!NSPointInRect(scrollPt, _detailScroll.bounds)) {
    [self setSidebarPreviewHovering:NO];
    return;
  }
  NSPoint cardPt = [_sidebarPreviewCard convertPoint:winPt fromView:nil];
  NSRect expandedBounds = NSInsetRect(_sidebarPreviewCard.bounds, -6.0, -26.0);
  if (!NSPointInRect(cardPt, expandedBounds)) {
    [self setSidebarPreviewHovering:NO];
  }
}

- (void)windowDidResize:(NSNotification*)notification {
  [self layoutWindowSubviews];
  [self rebuildDetailPage];
}

- (void)layoutWindowSubviews {
  NSRect sh = _sidebarHost.bounds;
  _searchField.frame =
      NSMakeRect(12.0, sh.size.height - 76.0, sh.size.width - 24.0, 28.0);
  _sidebarScroll.frame =
      NSMakeRect(0.0, 0.0, sh.size.width, std::max<CGFloat>(0.0, sh.size.height - 86.0));
  [self layoutSidebarRows];

  NSRect dp = _detailPane.bounds;
  _pageTitleLabel.frame =
      NSMakeRect(28.0, dp.size.height - 46.0, dp.size.width - 56.0, 28.0);
  _detailScroll.frame =
      NSMakeRect(0.0, 0.0, dp.size.width, std::max<CGFloat>(0.0, dp.size.height - 58.0));
}

- (void)layoutSidebarRows {
  NSString* query =
      [_searchField.stringValue stringByTrimmingCharactersInSet:
                                    NSCharacterSet.whitespaceCharacterSet]
          .lowercaseString;
  CGFloat w = _sidebarScroll.bounds.size.width;
  CGFloat y = 4.0;
  for (NSUInteger i = 0; i < _sidebarRows.count; ++i) {
    LightSettingsSidebarRowView* row = _sidebarRows[i];
    NSDictionary* cat = _categories[i];
    BOOL match = query.length == 0 ||
                 [[cat[@"title"] lowercaseString] containsString:query] ||
                 [[cat[@"keywords"] lowercaseString] containsString:query];
    row.hidden = !match;
    if (match) {
      row.frame = NSMakeRect(10.0, y, std::max<CGFloat>(0.0, w - 20.0), 32.0);
      y += 34.0;
    }
  }
  _sidebarDoc.frame =
      NSMakeRect(0.0, 0.0, w, std::max<CGFloat>(_sidebarScroll.bounds.size.height, y + 8.0));
}

- (void)controlTextDidChange:(NSNotification*)obj {
  if (obj.object == _searchField) {
    [self layoutSidebarRows];
  }
}

- (void)selectCategoryByTitle:(NSString*)title {
  for (NSUInteger i = 0; i < _categories.count; ++i) {
    if ([_categories[i][@"title"] isEqualToString:title]) {
      [self selectCategory:static_cast<NSInteger>(i)];
      return;
    }
  }
}

- (void)selectCategory:(NSInteger)index {
  if (index < 0 || index >= static_cast<NSInteger>(_categories.count)) {
    return;
  }
  if (index != 0) {
    [self setSidebarPreviewHovering:NO];
  }
  _selectedCategory = index;
  for (NSUInteger i = 0; i < _sidebarRows.count; ++i) {
    _sidebarRows[i].selected = (static_cast<NSInteger>(i) == index);
  }
  _pageTitleLabel.stringValue = _categories[index][@"title"];
  [self rebuildDetailPage];
}

// -----------------------------------------------------------------------------
// Card & Row Builders (System Settings Form Style)
// -----------------------------------------------------------------------------
- (NSView*)makeRowWithTitle:(NSString*)title
                   subtitle:(NSString*)subtitle
                    control:(NSView*)control
                      width:(CGFloat)width {
  CGFloat rowH = subtitle.length > 0 ? 54.0 : 40.0;
  LightSettingsFlippedView* row = [[LightSettingsFlippedView alloc]
      initWithFrame:NSMakeRect(0, 0, width, rowH)];

  CGFloat controlW = control ? control.frame.size.width : 0.0;
  CGFloat controlH = control ? control.frame.size.height : 0.0;
  CGFloat textMaxW = std::max<CGFloat>(120.0, width - controlW - 44.0);

  NSTextField* titleLbl = [NSTextField labelWithString:title];
  titleLbl.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
  titleLbl.textColor = NSColor.labelColor;
  titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
  NSSize tFit = [titleLbl sizeThatFits:NSMakeSize(textMaxW, 24.0)];

  if (subtitle.length > 0) {
    titleLbl.frame = NSMakeRect(14.0, 9.0, textMaxW, std::ceil(tFit.height));
    NSTextField* subLbl = [NSTextField labelWithString:subtitle];
    subLbl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    subLbl.textColor = NSColor.secondaryLabelColor;
    subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    NSSize sFit = [subLbl sizeThatFits:NSMakeSize(textMaxW, 20.0)];
    subLbl.frame = NSMakeRect(14.0, 28.0, textMaxW, std::ceil(sFit.height));
    [row addSubview:subLbl];
  } else {
    titleLbl.frame =
        NSMakeRect(14.0, std::floor((rowH - tFit.height) * 0.5), textMaxW,
                   std::ceil(tFit.height));
  }
  [row addSubview:titleLbl];

  if (control) {
    control.frame = NSMakeRect(width - controlW - 14.0,
                               std::floor((rowH - controlH) * 0.5), controlW,
                               controlH);
    [row addSubview:control];
  }
  return row;
}

- (NSView*)makeSwitchRow:(NSString*)title
                subtitle:(NSString*)subtitle
                   value:(BOOL)value
                   width:(CGFloat)width
                onChange:(void (^)(BOOL newValue))onChange {
  NSSwitch* sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
  sw.state = value ? NSControlStateValueOn : NSControlStateValueOff;
  LightControlBlockTarget* tgt =
      [LightControlBlockTarget targetWithBlock:^(id sender) {
        NSSwitch* s = (NSSwitch*)sender;
        if (onChange) {
          onChange(s.state == NSControlStateValueOn);
        }
      }];
  [_retainedTargets addObject:tgt];
  sw.target = tgt;
  sw.action = @selector(invoke:);
  [sw sizeToFit];
  return [self makeRowWithTitle:title
                       subtitle:subtitle
                        control:sw
                          width:width];
}

- (NSView*)makePopupRow:(NSString*)title
               subtitle:(NSString*)subtitle
                  items:(NSArray<NSString*>*)items
          selectedIndex:(NSInteger)selectedIndex
                  width:(CGFloat)width
               onChange:(void (^)(NSInteger idx))onChange {
  NSPopUpButton* pop =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 190, 26)
                                 pullsDown:NO];
  pop.font = [NSFont systemFontOfSize:12.5];
  [pop addItemsWithTitles:items];
  if (selectedIndex >= 0 &&
      selectedIndex < static_cast<NSInteger>(items.count)) {
    [pop selectItemAtIndex:selectedIndex];
  }
  LightControlBlockTarget* tgt =
      [LightControlBlockTarget targetWithBlock:^(id sender) {
        NSPopUpButton* p = (NSPopUpButton*)sender;
        if (onChange) {
          onChange(p.indexOfSelectedItem);
        }
      }];
  [_retainedTargets addObject:tgt];
  pop.target = tgt;
  pop.action = @selector(invoke:);
  return [self makeRowWithTitle:title
                       subtitle:subtitle
                        control:pop
                          width:width];
}

- (NSView*)makeSliderRow:(NSString*)title
                subtitle:(NSString*)subtitle
                   value:(double)value
                     min:(double)minVal
                     max:(double)maxVal
                  suffix:(NSString*)suffix
              isFloating:(BOOL)isFloating
                   width:(CGFloat)width
                onChange:(void (^)(double val))onChange {
  NSView* wrap = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 196, 24)];
  NSTextField* valLbl = [NSTextField
      labelWithString:(isFloating
                           ? [NSString stringWithFormat:@"%.1f%@", value, suffix]
                           : [NSString stringWithFormat:@"%.0f%@", value, suffix])];
  valLbl.font = [NSFont monospacedDigitSystemFontOfSize:12.0
                                                 weight:NSFontWeightRegular];
  valLbl.textColor = NSColor.secondaryLabelColor;
  valLbl.alignment = NSTextAlignmentRight;
  valLbl.frame = NSMakeRect(142, 4, 54, 16);
  [wrap addSubview:valLbl];

  NSSlider* slider = [NSSlider sliderWithValue:value
                                      minValue:minVal
                                      maxValue:maxVal
                                        target:nil
                                        action:nil];
  slider.continuous = YES;
  slider.frame = NSMakeRect(0, 2, 138, 20);
  LightControlBlockTarget* tgt =
      [LightControlBlockTarget targetWithBlock:^(id sender) {
        NSSlider* s = (NSSlider*)sender;
        double v = isFloating ? (std::round(s.doubleValue * 10.0) / 10.0)
                              : std::round(s.doubleValue);
        valLbl.stringValue =
            isFloating ? [NSString stringWithFormat:@"%.1f%@", v, suffix]
                       : [NSString stringWithFormat:@"%.0f%@", v, suffix];
        if (onChange) {
          onChange(v);
        }
      }];
  [_retainedTargets addObject:tgt];
  slider.target = tgt;
  slider.action = @selector(invoke:);
  [wrap addSubview:slider];

  return [self makeRowWithTitle:title
                       subtitle:subtitle
                        control:wrap
                          width:width];
}

- (NSView*)makeButtonRow:(NSString*)title
                subtitle:(NSString*)subtitle
             buttonTitle:(NSString*)buttonTitle
                   width:(CGFloat)width
                onAction:(void (^)(void))onAction {
  NSButton* btn = [NSButton buttonWithTitle:buttonTitle
                                     target:nil
                                     action:nil];
  btn.bezelStyle = NSBezelStylePush;
  btn.font = [NSFont systemFontOfSize:12.5];
  LightControlBlockTarget* tgt =
      [LightControlBlockTarget targetWithBlock:^(id sender) {
        if (onAction) {
          onAction();
        }
      }];
  [_retainedTargets addObject:tgt];
  btn.target = tgt;
  btn.action = @selector(invoke:);
  [btn sizeToFit];
  NSRect bf = btn.frame;
  btn.frame = NSMakeRect(0, 0, std::max<CGFloat>(90.0, bf.size.width + 12.0),
                         bf.size.height);
  return [self makeRowWithTitle:title
                       subtitle:subtitle
                        control:btn
                          width:width];
}

- (NSView*)makeGlassTintColorRow:(CGFloat)width {
  NSView* wrap = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 214, 26)];

  NSColorWell* well = [[NSColorWell alloc] initWithFrame:NSMakeRect(172, 1, 42, 24)];
  if (@available(macOS 13.0, *)) {
    well.colorWellStyle = NSColorWellStyleMinimal;
  }
  double r = UDGetDouble(@"LightSidebarTintR", 1.0);
  double g = UDGetDouble(@"LightSidebarTintG", 1.0);
  double b = UDGetDouble(@"LightSidebarTintB", 1.0);
  well.color = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];

  LightControlBlockTarget* wellTgt =
      [LightControlBlockTarget targetWithBlock:^(id sender) {
        NSColorWell* w = (NSColorWell*)sender;
        NSColor* c = [w.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (c) {
          [NSUserDefaults.standardUserDefaults setDouble:c.redComponent
                                                  forKey:@"LightSidebarTintR"];
          [NSUserDefaults.standardUserDefaults setDouble:c.greenComponent
                                                  forKey:@"LightSidebarTintG"];
          [NSUserDefaults.standardUserDefaults setDouble:c.blueComponent
                                                  forKey:@"LightSidebarTintB"];
          if (UDGetDouble(@"LightSidebarTintAlpha", 4.0) < 1.0) {
            [NSUserDefaults.standardUserDefaults setDouble:16.0
                                                    forKey:@"LightSidebarTintAlpha"];
          }
          PostLightSettingsChanged();
        }
      }];
  [_retainedTargets addObject:wellTgt];
  well.target = wellTgt;
  well.action = @selector(invoke:);
  [wrap addSubview:well];

  struct SwatchSpec {
    CGFloat r, g, b;
    NSString* tip;
  };
  const SwatchSpec kSwatches[] = {
      {1.00, 1.00, 1.00, @"Ice White"},
      {0.07, 0.08, 0.10, @"Obsidian"},
      {0.75, 0.48, 0.60, @"Plum"},
      {0.30, 0.55, 0.96, @"Ocean Blue"},
      {0.61, 0.42, 0.94, @"Violet"},
      {0.25, 0.69, 0.42, @"Emerald"},
      {0.93, 0.52, 0.20, @"Amber"},
  };
  __weak __typeof(self) weakSelf = self;
  for (size_t i = 0; i < std::size(kSwatches); ++i) {
    CGFloat sx = static_cast<CGFloat>(i) * 23.0;
    NSButton* swBtn = [[NSButton alloc] initWithFrame:NSMakeRect(sx, 4, 18, 18)];
    swBtn.bordered = NO;
    swBtn.title = @"";
    swBtn.toolTip = kSwatches[i].tip;
    swBtn.wantsLayer = YES;
    swBtn.layer.cornerRadius = 9.0;
    swBtn.layer.backgroundColor =
        [NSColor colorWithSRGBRed:kSwatches[i].r
                            green:kSwatches[i].g
                             blue:kSwatches[i].b
                            alpha:1.0]
            .CGColor;
    swBtn.layer.borderWidth = 1.0;
    swBtn.layer.borderColor =
        [NSColor.labelColor colorWithAlphaComponent:0.25].CGColor;
    const CGFloat sr = kSwatches[i].r;
    const CGFloat sg = kSwatches[i].g;
    const CGFloat sb = kSwatches[i].b;
    LightControlBlockTarget* swTgt =
        [LightControlBlockTarget targetWithBlock:^(id sender) {
          [NSUserDefaults.standardUserDefaults setDouble:sr
                                                  forKey:@"LightSidebarTintR"];
          [NSUserDefaults.standardUserDefaults setDouble:sg
                                                  forKey:@"LightSidebarTintG"];
          [NSUserDefaults.standardUserDefaults setDouble:sb
                                                  forKey:@"LightSidebarTintB"];
          if (UDGetDouble(@"LightSidebarTintAlpha", 4.0) < 4.0 &&
              !(sr > 0.99 && sg > 0.99 && sb > 0.99)) {
            [NSUserDefaults.standardUserDefaults setDouble:18.0
                                                    forKey:@"LightSidebarTintAlpha"];
          }
          well.color = [NSColor colorWithSRGBRed:sr green:sg blue:sb alpha:1.0];
          PostLightSettingsChanged();
          [weakSelf rebuildDetailPage];
        }];
    [_retainedTargets addObject:swTgt];
    swBtn.target = swTgt;
    swBtn.action = @selector(invoke:);
    [wrap addSubview:swBtn];
  }

  return [self makeRowWithTitle:@"Glass Tint Color"
                       subtitle:@"Pick a preset swatch or custom color well"
                        control:wrap
                          width:width];
}

- (CGFloat)appendSectionHeader:(NSString*)header
                          rows:(NSArray<NSView*>*)rows
                        atYPos:(CGFloat)y
                         width:(CGFloat)cardWidth
                         leftX:(CGFloat)leftX {
  if (header.length > 0) {
    NSTextField* hdr = [NSTextField labelWithString:header];
    hdr.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    hdr.textColor = NSColor.secondaryLabelColor;
    hdr.frame = NSMakeRect(leftX + 4.0, y, cardWidth, 16.0);
    [_detailDoc addSubview:hdr];
    y += 22.0;
  }

  LightSettingsCardView* card =
      [[LightSettingsCardView alloc] initWithFrame:NSZeroRect];
  if ([header isEqualToString:@"Liquid Glass Sidebar"]) {
    _sidebarPreviewCard = card;
    __weak __typeof(self) weakSelf = self;
    card.onHoverChanged = ^(BOOL hovered) {
      if (hovered) {
        [weakSelf setSidebarPreviewHovering:YES];
      } else {
        [weakSelf checkSidebarPreviewHoverState];
      }
    };
  }
  CGFloat cy = 0.0;
  for (NSUInteger i = 0; i < rows.count; ++i) {
    NSView* r = rows[i];
    NSRect rf = r.frame;
    r.frame = NSMakeRect(0.0, cy, cardWidth, rf.size.height);
    [card addSubview:r];
    cy += rf.size.height;
    if (i + 1 < rows.count) {
      NSBox* sep = [[NSBox alloc]
          initWithFrame:NSMakeRect(14.0, cy, cardWidth - 28.0, 0.5)];
      sep.boxType = NSBoxCustom;
      sep.borderWidth = 0.0;
      sep.fillColor = [NSColor.separatorColor colorWithAlphaComponent:0.38];
      [card addSubview:sep];
      cy += 1.0;
    }
  }
  card.frame = NSMakeRect(leftX, y, cardWidth, cy);
  [_detailDoc addSubview:card];
  return y + cy + 20.0;
}

// -----------------------------------------------------------------------------
// Page Rebuilder
// -----------------------------------------------------------------------------
- (void)rebuildDetailPage {
  [_retainedTargets removeAllObjects];
  for (NSView* sub in [_detailDoc.subviews copy]) {
    [sub removeFromSuperview];
  }

  CGFloat availW = _detailScroll.bounds.size.width;
  CGFloat cardW = std::min<CGFloat>(kContentMaxWidth,
                                    std::max<CGFloat>(340.0, availW - 56.0));
  CGFloat leftX = 28.0;
  CGFloat y = 8.0;

  PrefService* prefs = _profile ? _profile->GetPrefs() : nullptr;
  PrefService* localState =
      g_browser_process ? g_browser_process->local_state() : nullptr;
  __weak __typeof(self) weakSelf = self;

  switch (_selectedCategory) {
    case 0: {  // Custom
      NSArray* cornerRows = @[
        [self makeSwitchRow:@"Dynamic Per-Corner Square on Screen Edges"
                   subtitle:@"Set individual corners (TL, TR, BL, BR) to 0 when touching screen edges"
                      value:UDGetBool(@"LightAutoCornerRadiusEnabled", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightAutoCornerRadiusEnabled", v);
                   }],
        [self makeSliderRow:@"Base Window Corner Radius"
                   subtitle:@"Corner radius used when not touching screen edges"
                      value:UDGetDouble(@"LightBaseWindowCornerRadius", 20.0)
                        min:0.0
                        max:32.0
                     suffix:@" pt"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightBaseWindowCornerRadius", v);
                   }],
        [self makeSwitchRow:@"Auto-Square Top-Left Corner"
                   subtitle:nil
                      value:UDGetBool(@"LightAutoCornerTopLeft", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightAutoCornerTopLeft", v);
                   }],
        [self makeSwitchRow:@"Auto-Square Top-Right Corner"
                   subtitle:nil
                      value:UDGetBool(@"LightAutoCornerTopRight", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightAutoCornerTopRight", v);
                   }],
        [self makeSwitchRow:@"Auto-Square Bottom-Left Corner"
                   subtitle:nil
                      value:UDGetBool(@"LightAutoCornerBottomLeft", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightAutoCornerBottomLeft", v);
                   }],
        [self makeSwitchRow:@"Auto-Square Bottom-Right Corner"
                   subtitle:nil
                      value:UDGetBool(@"LightAutoCornerBottomRight", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightAutoCornerBottomRight", v);
                   }],
      ];
      y = [self appendSectionHeader:@"Window Corners"
                               rows:cornerRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];

      // Map Adaptive Scrim: 2 = Adaptive (Default), 0 = Automatic, 1 = Off (Pure Raw Glass)
      NSInteger adaptiveRaw = UDGetInt(@"LightSidebarGlassAdaptive", 2);
      NSInteger adaptiveMenuIdx =
          (adaptiveRaw == 1) ? 2 : ((adaptiveRaw == 0) ? 1 : 0);

      NSArray* sidebarRows = @[
        [self makePopupRow:@"Glass Material Style"
                  subtitle:@"Switch between frosted Regular glass and crystal Clear glass"
                     items:@[ @"Regular (Frosted)", @"Clear (Crystal)" ]
             selectedIndex:UDGetInt(@"LightSidebarGlassStyle", 0)
                     width:cardW
                  onChange:^(NSInteger idx) {
                    UDSetInt(@"LightSidebarGlassStyle", idx);
                  }],
        [self makePopupRow:@"Adaptive Readability Scrim"
                  subtitle:@"Turn Off for raw un-dimmed refractive glass over bright/dark pages"
                     items:@[
                       @"Adaptive (Default)", @"Automatic",
                       @"Off (Pure Raw Glass)"
                     ]
             selectedIndex:adaptiveMenuIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    NSInteger mapped = (idx == 2) ? 1 : ((idx == 1) ? 0 : 2);
                    UDSetInt(@"LightSidebarGlassAdaptive", mapped);
                  }],
        [self makeSwitchRow:@"Interactive Glass Specular Lensing"
                   subtitle:@"Dynamic macOS Liquid Glass lensing response on interaction"
                      value:UDGetBool(@"LightSidebarGlassInteractive", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightSidebarGlassInteractive", v);
                   }],
        [self makeGlassTintColorRow:cardW],
        [self makeSliderRow:@"Glass Tint Strength"
                   subtitle:@"0% is completely untinted glass; higher values deepen color tint"
                      value:UDGetDouble(@"LightSidebarTintAlpha", 4.0)
                        min:0.0
                        max:85.0
                     suffix:@"%"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarTintAlpha", v);
                   }],
        [self makeSliderRow:@"Sidebar Drop Shadow"
                   subtitle:@"Ambient shadow intensity behind the floating glass panel"
                      value:UDGetDouble(@"LightSidebarShadowAlpha", 28.0)
                        min:0.0
                        max:60.0
                     suffix:@"%"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarShadowAlpha", v);
                   }],
        [self makeSwitchRow:@"Auto-Hide Sidebar When Not Hovering Left"
                   subtitle:@"Automatically spring-hide sidebar when cursor leaves the left side"
                      value:UDGetBool(@"LightSidebarAutoHide", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightSidebarAutoHide", v);
                   }],
        [self makeSliderRow:@"Sidebar Width"
                   subtitle:nil
                      value:UDGetDouble(@"LightSidebarWidth", 228.0)
                        min:190.0
                        max:300.0
                     suffix:@" pt"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarWidth", v);
                   }],
        [self makeSliderRow:@"Sidebar Corner Radius"
                   subtitle:nil
                      value:UDGetDouble(@"LightSidebarCornerRadius", 20.0)
                        min:8.0
                        max:30.0
                     suffix:@" pt"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarCornerRadius", v);
                   }],
        [self makeSliderRow:@"Opening Spring Speed"
                   subtitle:@"Multiplier on CASpringAnimation speed when revealing"
                      value:UDGetDouble(@"LightSidebarOpenSpeed", 4.0)
                        min:1.0
                        max:8.0
                     suffix:@"×"
                 isFloating:YES
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarOpenSpeed", v);
                   }],
        [self makeSliderRow:@"Closing Spring Speed"
                   subtitle:@"Multiplier on CASpringAnimation speed when hiding"
                      value:UDGetDouble(@"LightSidebarCloseSpeed", 2.0)
                        min:1.0
                        max:8.0
                     suffix:@"×"
                 isFloating:YES
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarCloseSpeed", v);
                   }],
        [self makeSliderRow:@"Motion Blur Radius"
                   subtitle:@"Gaussian blur applied to sidebar contents while springing"
                      value:UDGetDouble(@"LightSidebarBlurRadius", 14.0)
                        min:0.0
                        max:28.0
                     suffix:@" pt"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarBlurRadius", v);
                   }],
        [self makeSliderRow:@"Left-Edge Hover Trigger Width"
                   subtitle:@"Active left-edge width that triggers sidebar reveal"
                      value:UDGetDouble(@"LightSidebarTriggerWidth", 14.0)
                        min:4.0
                        max:32.0
                     suffix:@" pt"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     UDSetDouble(@"LightSidebarTriggerWidth", v);
                   }],
      ];
      y = [self appendSectionHeader:@"Liquid Glass Sidebar"
                               rows:sidebarRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];

      NSArray* diagRows = @[
        [self makeSwitchRow:@"Verbose Window & Mouse Logging"
                   subtitle:@"Logs resize, corner state, and cursor geometry to /tmp/light_ui_debug.log"
                      value:UDGetBool(@"LightVerboseDiagLogging", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     UDSetBool(@"LightVerboseDiagLogging", v);
                   }],
        [self makeButtonRow:@"Diagnostic Log File"
                   subtitle:@"/tmp/light_ui_debug.log"
                buttonTitle:@"Open Log…"
                      width:cardW
                   onAction:^{
                     [NSWorkspace.sharedWorkspace
                         openURL:[NSURL fileURLWithPath:@"/tmp/light_ui_debug.log"]];
                   }],
        [self makeButtonRow:@"Reset Custom Preferences"
                   subtitle:@"Restore all Custom corner & sidebar settings to defaults"
                buttonTitle:@"Reset Defaults"
                      width:cardW
                   onAction:^{
                     NSArray<NSString*>* keys = @[
                       @"LightAutoCornerRadiusEnabled",
                       @"LightBaseWindowCornerRadius",
                       @"LightAutoCornerTopLeft",
                       @"LightAutoCornerTopRight",
                       @"LightAutoCornerBottomLeft",
                       @"LightAutoCornerBottomRight",
                       @"LightSidebarGlassStyle",
                       @"LightSidebarGlassAdaptive",
                       @"LightSidebarGlassInteractive",
                       @"LightSidebarTintR",
                       @"LightSidebarTintG",
                       @"LightSidebarTintB",
                       @"LightSidebarTintAlpha",
                       @"LightSidebarShadowAlpha",
                       @"LightSidebarAutoHide",
                       @"LightSidebarWidth",
                       @"LightSidebarCornerRadius",
                       @"LightSidebarOpenSpeed",
                       @"LightSidebarCloseSpeed",
                       @"LightSidebarBlurRadius",
                       @"LightSidebarTriggerWidth",
                     ];
                     for (NSString* k in keys) {
                       [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
                     }
                     PostLightSettingsChanged();
                     [weakSelf rebuildDetailPage];
                   }],
      ];
      y = [self appendSectionHeader:@"Diagnostics"
                               rows:diagRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 1: {  // Containers
      auto parseHex = [](const std::string& hex) -> NSColor* {
        unsigned int rgb = 0x0A84FF;
        if (!hex.empty() && hex[0] == '#' && hex.size() == 7) {
          std::sscanf(hex.c_str() + 1, "%x", &rgb);
        }
        return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                                   green:((rgb >> 8) & 0xFF) / 255.0
                                    blue:(rgb & 0xFF) / 255.0
                                   alpha:1.0];
      };

      std::vector<LightTabContainer> containers = LightGetTabContainers();
      NSMutableArray* existingRows = [NSMutableArray array];
      for (const auto& c : containers) {
        std::string cid = c.id;
        NSView* row = [[LightSettingsFlippedView alloc]
            initWithFrame:NSMakeRect(0, 0, cardW, 52.0)];

        LightSettingsIconBadgeView* badge = [[LightSettingsIconBadgeView alloc]
            initWithSymbol:base::SysUTF8ToNSString(c.symbol)
                     color:parseHex(c.color_hex)];
        badge.frame = NSMakeRect(14.0, 14.0, 24.0, 24.0);
        [row addSubview:badge];

        NSTextField* titleLbl =
            [NSTextField labelWithString:base::SysUTF8ToNSString(c.name)];
        titleLbl.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
        titleLbl.textColor = NSColor.labelColor;
        titleLbl.frame = NSMakeRect(48.0, 9.0, std::max<CGFloat>(100.0, cardW - 210.0), 17.0);
        [row addSubview:titleLbl];

        NSString* subText =
            c.in_memory ? @"Private (in-memory, clears on close)"
                        : @"Isolated persistent cookies & site data";
        NSTextField* subLbl = [NSTextField labelWithString:subText];
        subLbl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
        subLbl.textColor = NSColor.secondaryLabelColor;
        subLbl.frame = NSMakeRect(48.0, 28.0, std::max<CGFloat>(100.0, cardW - 210.0), 15.0);
        [row addSubview:subLbl];

        NSButton* clearBtn = [NSButton buttonWithTitle:@"Clear Data"
                                                target:nil
                                                action:nil];
        clearBtn.bezelStyle = NSBezelStylePush;
        clearBtn.font = [NSFont systemFontOfSize:12.0];
        clearBtn.frame = NSMakeRect(cardW - 156.0, 12.0, 82.0, 26.0);
        LightControlBlockTarget* clearTgt =
            [LightControlBlockTarget targetWithBlock:^(id sender) {
              __strong __typeof(weakSelf) s = weakSelf;
              if (s && s->_profile) {
                LightClearTabContainerData(s->_profile, cid);
              }
            }];
        [_retainedTargets addObject:clearTgt];
        clearBtn.target = clearTgt;
        clearBtn.action = @selector(invoke:);
        [row addSubview:clearBtn];

        NSButton* delBtn = [NSButton buttonWithTitle:@"Delete"
                                              target:nil
                                              action:nil];
        delBtn.bezelStyle = NSBezelStylePush;
        delBtn.font = [NSFont systemFontOfSize:12.0];
        delBtn.frame = NSMakeRect(cardW - 68.0, 12.0, 56.0, 26.0);
        LightControlBlockTarget* delTgt =
            [LightControlBlockTarget targetWithBlock:^(id sender) {
              LightDeleteTabContainer(cid);
              [weakSelf rebuildDetailPage];
            }];
        [_retainedTargets addObject:delTgt];
        delBtn.target = delTgt;
        delBtn.action = @selector(invoke:);
        [row addSubview:delBtn];

        [existingRows addObject:row];
      }
      if (existingRows.count == 0) {
        [existingRows
            addObject:[self makeRowWithTitle:@"No Tab Containers"
                                    subtitle:@"Create a container below or reset defaults."
                                     control:nil
                                       width:cardW]];
      }
      y = [self appendSectionHeader:@"Tab Containers"
                               rows:existingRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];

      // Create New Container card.
      NSTextField* nameField =
          [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 190, 24)];
      nameField.placeholderString = @"e.g. Banking, Social, Work";
      nameField.font = [NSFont systemFontOfSize:12.5];

      NSArray<NSString*>* symbolNames = @[
        @"eye.slash", @"person", @"briefcase", @"bag", @"shield", @"star",
        @"flame", @"globe", @"lock", @"heart"
      ];
      NSArray<NSString*>* symbolLabels = @[
        @"Private (Eye Slash)", @"Person", @"Briefcase", @"Shopping Bag",
        @"Shield", @"Star", @"Flame", @"Globe", @"Lock", @"Heart"
      ];
      NSPopUpButton* symbolPop =
          [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 190, 26)
                                     pullsDown:NO];
      symbolPop.font = [NSFont systemFontOfSize:12.5];
      [symbolPop addItemsWithTitles:symbolLabels];

      NSArray<NSString*>* colorLabels = @[
        @"Purple", @"Blue", @"Orange", @"Green", @"Red", @"Cyan", @"Pink",
        @"Gray"
      ];
      NSArray<NSString*>* colorHexes = @[
        @"#AF52DE", @"#0A84FF", @"#FF9F0A", @"#30D158", @"#FF453A", @"#64D2FF",
        @"#FF375F", @"#8E8E93"
      ];
      NSPopUpButton* colorPop =
          [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 190, 26)
                                     pullsDown:NO];
      colorPop.font = [NSFont systemFontOfSize:12.5];
      [colorPop addItemsWithTitles:colorLabels];
      [colorPop selectItemAtIndex:1];

      NSSwitch* privateSwitch =
          [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
      privateSwitch.state = NSControlStateValueOff;
      [privateSwitch sizeToFit];

      NSArray* createRows = @[
        [self makeRowWithTitle:@"Container Name"
                      subtitle:@"Shown when right-clicking the + button in the sidebar"
                       control:nameField
                         width:cardW],
        [self makeRowWithTitle:@"Icon"
                      subtitle:nil
                       control:symbolPop
                         width:cardW],
        [self makeRowWithTitle:@"Accent Color"
                      subtitle:nil
                       control:colorPop
                         width:cardW],
        [self makeRowWithTitle:@"Private (In-Memory)"
                      subtitle:@"Discard cookies, logins, and storage when Light quits"
                       control:privateSwitch
                         width:cardW],
        [self makeButtonRow:@"Add Container"
                   subtitle:@"Right-click the + button under your tabs to open a tab in any container"
                buttonTitle:@"Add Container"
                      width:cardW
                   onAction:^{
                     NSString* rawName =
                         [nameField.stringValue
                             stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
                     if (rawName.length == 0) {
                       return;
                     }
                     NSString* slug =
                         [[rawName lowercaseString]
                             stringByReplacingOccurrencesOfString:@" "
                                                       withString:@"_"];
                     NSString* uniqueId = [NSString
                         stringWithFormat:@"%@_%ld", slug,
                                          (long)[NSDate.date timeIntervalSince1970]];
                     NSInteger symIdx = std::clamp<NSInteger>(
                         symbolPop.indexOfSelectedItem, 0,
                         static_cast<NSInteger>(symbolNames.count) - 1);
                     NSInteger colIdx = std::clamp<NSInteger>(
                         colorPop.indexOfSelectedItem, 0,
                         static_cast<NSInteger>(colorHexes.count) - 1);
                     LightTabContainer c;
                     c.id = base::SysNSStringToUTF8(uniqueId);
                     c.name = base::SysNSStringToUTF8(rawName);
                     c.symbol = base::SysNSStringToUTF8(symbolNames[symIdx]);
                     c.color_hex = base::SysNSStringToUTF8(colorHexes[colIdx]);
                     c.in_memory =
                         (privateSwitch.state == NSControlStateValueOn);
                     LightAddTabContainer(c);
                     [weakSelf rebuildDetailPage];
                   }],
        [self makeButtonRow:@"Reset Defaults"
                   subtitle:@"Restore Private, Personal, Work, and Shopping containers"
                buttonTitle:@"Reset Defaults"
                      width:cardW
                   onAction:^{
                     LightResetDefaultTabContainers();
                     [weakSelf rebuildDetailPage];
                   }],
      ];
      y = [self appendSectionHeader:@"New Container"
                               rows:createRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 2: {  // General
      int restoreVal = PrefGetInt(prefs, prefs::kRestoreOnStartup, 5);
      NSInteger startupIdx = (restoreVal == 1) ? 1 : 0;
      NSArray* startupRows = @[
        [self makePopupRow:@"On Startup"
                  subtitle:@"Choose what opens when you launch the browser"
                     items:@[
                       @"Open the New Tab Page",
                       @"Continue Where You Left Off"
                     ]
             selectedIndex:startupIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    PrefSetInt(prefs, prefs::kRestoreOnStartup,
                               idx == 1 ? 1 : 5);
                  }],
        [self makeSwitchRow:@"Use Hardware Acceleration"
                   subtitle:@"Use GPU compositing and video decoding when available (restart required)"
                      value:PrefGetBool(localState,
                                        prefs::kHardwareAccelerationModeEnabled,
                                        true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(localState,
                                 prefs::kHardwareAccelerationModeEnabled, v);
                   }],
      ];
      y = [self appendSectionHeader:@"Startup & System"
                               rows:startupRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 3: {  // Appearance
      ThemeService* themeService =
          _profile ? ThemeServiceFactory::GetForProfile(_profile) : nullptr;
      NSInteger schemeIdx = 0;
      if (themeService) {
        auto s = themeService->GetBrowserColorScheme();
        if (s == ThemeService::BrowserColorScheme::kLight) {
          schemeIdx = 1;
        } else if (s == ThemeService::BrowserColorScheme::kDark) {
          schemeIdx = 2;
        }
      }
      NSArray* appRows = @[
        [self makePopupRow:@"Color Scheme"
                  subtitle:@"Choose Light, Dark, or match macOS appearance"
                     items:@[ @"System", @"Light", @"Dark" ]
             selectedIndex:schemeIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    if (!themeService) {
                      return;
                    }
                    auto mode = ThemeService::BrowserColorScheme::kSystem;
                    if (idx == 1) {
                      mode = ThemeService::BrowserColorScheme::kLight;
                    } else if (idx == 2) {
                      mode = ThemeService::BrowserColorScheme::kDark;
                    }
                    themeService->SetBrowserColorScheme(mode);
                  }],
        [self makeSliderRow:@"Default Font Size"
                   subtitle:@"Standard web content font size"
                      value:PrefGetInt(prefs, prefs::kWebKitDefaultFontSize, 16)
                        min:10.0
                        max:24.0
                     suffix:@" px"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     PrefSetInt(prefs, prefs::kWebKitDefaultFontSize,
                                static_cast<int>(v));
                   }],
        [self makeSliderRow:@"Minimum Font Size"
                   subtitle:@"Smallest allowed font size on web pages"
                      value:PrefGetInt(prefs, prefs::kWebKitMinimumFontSize, 0)
                        min:0.0
                        max:18.0
                     suffix:@" px"
                 isFloating:NO
                      width:cardW
                   onChange:^(double v) {
                     PrefSetInt(prefs, prefs::kWebKitMinimumFontSize,
                                static_cast<int>(v));
                   }],
        [self makeSwitchRow:@"Always Show Full URLs"
                   subtitle:@"Include https:// and trivial subdomains in address displays"
                      value:PrefGetBool(prefs,
                                        omnibox::kPreventUrlElisionsInOmnibox,
                                        false)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, omnibox::kPreventUrlElisionsInOmnibox,
                                 v);
                   }],
      ];
      y = [self appendSectionHeader:@"Theme & Typography"
                               rows:appRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 4: {  // Search Engine
      NSMutableArray<NSString*>* titles = [NSMutableArray array];
      auto providers = std::make_shared<std::vector<raw_ptr<TemplateURL>>>();
      NSInteger activeIdx = 0;
      TemplateURLService* turlService =
          _profile ? TemplateURLServiceFactory::GetForProfile(_profile)
                   : nullptr;
      if (turlService) {
        const TemplateURL* defaultProvider =
            turlService->GetDefaultSearchProvider();
        for (TemplateURL* turl : turlService->GetTemplateURLs()) {
          if (!turl || !turlService->ShowInDefaultList(turl)) {
            continue;
          }
          if (turl == defaultProvider) {
            activeIdx = static_cast<NSInteger>(providers->size());
          }
          providers->push_back(turl);
          [titles addObject:base::SysUTF16ToNSString(turl->short_name())];
        }
      }
      if (titles.count == 0) {
        [titles addObject:@"Google"];
      }
      NSArray* seRows = @[
        [self makePopupRow:@"Default Search Engine"
                  subtitle:@"Used when searching from the Liquid Glass address bar"
                     items:titles
             selectedIndex:activeIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    if (turlService && idx >= 0 &&
                        idx < static_cast<NSInteger>(providers->size())) {
                      turlService->SetUserSelectedDefaultSearchProvider(
                          (*providers)[idx]);
                    }
                  }],
      ];
      y = [self appendSectionHeader:@"Address Bar Search"
                               rows:seRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 5: {  // Privacy & Security
      bool sbEnabled = PrefGetBool(prefs, "safebrowsing.enabled", true);
      bool sbEnhanced = PrefGetBool(prefs, "safebrowsing.enhanced", false);
      NSInteger sbIdx = !sbEnabled ? 2 : (sbEnhanced ? 0 : 1);

      int cookieMode = PrefGetInt(prefs, "profile.cookie_controls_mode", 1);
      NSInteger cookieIdx =
          (cookieMode == 0) ? 0 : ((cookieMode == 1) ? 2 : 1);

      NSArray* privRows = @[
        [self makePopupRow:@"Safe Browsing"
                  subtitle:@"Protection against dangerous sites and downloads"
                     items:@[
                       @"Enhanced Protection",
                       @"Standard Protection",
                       @"No Protection"
                     ]
             selectedIndex:sbIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    if (idx == 0) {
                      PrefSetBool(prefs, "safebrowsing.enabled", true);
                      PrefSetBool(prefs, "safebrowsing.enhanced", true);
                    } else if (idx == 1) {
                      PrefSetBool(prefs, "safebrowsing.enabled", true);
                      PrefSetBool(prefs, "safebrowsing.enhanced", false);
                    } else {
                      PrefSetBool(prefs, "safebrowsing.enabled", false);
                      PrefSetBool(prefs, "safebrowsing.enhanced", false);
                    }
                  }],
        [self makeSwitchRow:@"Always Use Secure Connections"
                   subtitle:@"Upgrade navigations to HTTPS and warn before loading HTTP sites"
                      value:PrefGetBool(prefs, prefs::kHttpsOnlyModeEnabled,
                                        false)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, prefs::kHttpsOnlyModeEnabled, v);
                   }],
        [self makePopupRow:@"Third-Party Cookies"
                  subtitle:@"Control cross-site cookie tracking"
                     items:@[
                       @"Allow Third-Party Cookies",
                       @"Block in Incognito",
                       @"Block All Third-Party Cookies"
                     ]
             selectedIndex:cookieIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    int mode = (idx == 0) ? 0 : ((idx == 2) ? 1 : 2);
                    PrefSetInt(prefs, "profile.cookie_controls_mode", mode);
                  }],
        [self makeSwitchRow:@"Send a \"Do Not Track\" Request"
                   subtitle:@"Include the DNT header with browsing traffic"
                      value:PrefGetBool(prefs, prefs::kEnableDoNotTrack, false)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, prefs::kEnableDoNotTrack, v);
                   }],
        [self makeButtonRow:@"Clear Browsing Data"
                   subtitle:@"Delete history, cookies, cache, and site data"
                buttonTitle:@"Clear Data…"
                      width:cardW
                   onAction:^{
                     __strong __typeof(weakSelf) s = weakSelf;
                     if (s && s->_browser) {
                       chrome::ExecuteCommand(s->_browser,
                                              IDC_CLEAR_BROWSING_DATA);
                     }
                   }],
      ];
      y = [self appendSectionHeader:@"Security & Tracking"
                               rows:privRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 6: {  // Autofill & Passwords
      NSArray* afRows = @[
        [self makeSwitchRow:@"Offer to Save Passwords"
                   subtitle:@"Save login credentials in Password Manager"
                      value:PrefGetBool(prefs, "credentials_enable_service",
                                        true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "credentials_enable_service", v);
                   }],
        [self makeSwitchRow:@"Sign In Automatically"
                   subtitle:@"Automatically sign in to websites using stored credentials"
                      value:PrefGetBool(prefs, "credentials_enable_autosignin",
                                        true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "credentials_enable_autosignin", v);
                   }],
        [self makeSwitchRow:@"Save and Fill Addresses"
                   subtitle:@"Includes names, phone numbers, email addresses, and shipping addresses"
                      value:PrefGetBool(prefs, "autofill.profile_enabled", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "autofill.profile_enabled", v);
                   }],
        [self makeSwitchRow:@"Save and Fill Payment Methods"
                   subtitle:@"Fills in payment forms with your saved cards"
                      value:PrefGetBool(prefs, "autofill.credit_card_enabled",
                                        true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "autofill.credit_card_enabled", v);
                   }],
      ];
      y = [self appendSectionHeader:@"Credentials & Autofill"
                               rows:afRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 7: {  // Downloads
      std::string dlPath =
          PrefGetString(prefs, prefs::kDownloadDefaultDirectory, "");
      NSString* dlDisplay =
          dlPath.empty() ? @"~/Downloads" : base::SysUTF8ToNSString(dlPath);
      NSArray* dlRows = @[
        [self makeButtonRow:@"Download Location"
                   subtitle:dlDisplay
                buttonTitle:@"Change…"
                      width:cardW
                   onAction:^{
                     NSOpenPanel* panel = [NSOpenPanel openPanel];
                     panel.canChooseDirectories = YES;
                     panel.canChooseFiles = NO;
                     panel.canCreateDirectories = YES;
                     panel.prompt = @"Select";
                     [panel beginSheetModalForWindow:weakSelf.window
                                   completionHandler:^(NSModalResponse resp) {
                                     if (resp == NSModalResponseOK &&
                                         panel.URL.path) {
                                       PrefSetString(
                                           prefs,
                                           prefs::kDownloadDefaultDirectory,
                                           base::SysNSStringToUTF8(
                                               panel.URL.path));
                                       [weakSelf rebuildDetailPage];
                                     }
                                   }];
                   }],
        [self makeSwitchRow:@"Ask Where to Save Each File Before Downloading"
                   subtitle:nil
                      value:PrefGetBool(prefs, prefs::kPromptForDownload, false)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, prefs::kPromptForDownload, v);
                   }],
      ];
      y = [self appendSectionHeader:@"Files"
                               rows:dlRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 8: {  // Performance
      int memState =
          PrefGetInt(localState, "performance_tuning.high_efficiency_mode.state",
                     2);
      NSInteger memIdx = (memState == 0) ? 0 : ((memState == 3) ? 2 : 1);

      int batState =
          PrefGetInt(localState, "performance_tuning.battery_saver_mode.state",
                     1);
      NSInteger batIdx = (batState == 0) ? 0 : ((batState == 2) ? 2 : 1);

      NSArray* perfRows = @[
        [self makePopupRow:@"Memory Saver"
                  subtitle:@"Frees up memory from inactive tabs"
                     items:@[ @"Off", @"Balanced", @"Maximum" ]
             selectedIndex:memIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    int val = (idx == 0) ? 0 : ((idx == 2) ? 3 : 2);
                    PrefSetInt(localState,
                               "performance_tuning.high_efficiency_mode.state",
                               val);
                  }],
        [self makePopupRow:@"Energy Saver"
                  subtitle:@"Conserves battery power by limiting background activity and visual effects"
                     items:@[ @"Off", @"When Unplugged", @"Always On" ]
             selectedIndex:batIdx
                     width:cardW
                  onChange:^(NSInteger idx) {
                    int val = (idx == 0) ? 0 : ((idx == 2) ? 2 : 1);
                    PrefSetInt(localState,
                               "performance_tuning.battery_saver_mode.state",
                               val);
                  }],
      ];
      y = [self appendSectionHeader:@"Memory & Power"
                               rows:perfRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }

    case 9: {  // Languages
      NSArray* langRows = @[
        [self makeSwitchRow:@"Check Spelling While Typing"
                   subtitle:@"Highlight misspelled words in text fields"
                      value:PrefGetBool(prefs, "browser.enable_spellchecking",
                                        true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "browser.enable_spellchecking", v);
                   }],
        [self makeSwitchRow:@"Offer to Translate Pages"
                   subtitle:@"Prompt to translate pages in languages you don't read"
                      value:PrefGetBool(prefs, "translate.enabled", true)
                      width:cardW
                   onChange:^(BOOL v) {
                     PrefSetBool(prefs, "translate.enabled", v);
                   }],
      ];
      y = [self appendSectionHeader:@"Spelling & Translation"
                               rows:langRows
                             atYPos:y
                              width:cardW
                              leftX:leftX];
      break;
    }
  }

  _detailDoc.frame = NSMakeRect(
      0.0, 0.0, availW, std::max<CGFloat>(_detailScroll.bounds.size.height, y + 16.0));
}

@end

// -----------------------------------------------------------------------------
// Objective-C entry point so app_controller_mac.mm can invoke without GN cycles
// -----------------------------------------------------------------------------
@interface LightNativeSettingsMenuBridge : NSObject
+ (void)openForProfilePtr:(NSValue*)profileValue;
@end

namespace {
LightNativeSettingsWindowController* __strong g_settings_controller = nil;

void ShowSettingsWindowImpl(Profile* profile, BrowserWindowInterface* browser) {
  if (!profile && browser) {
    profile = browser->GetProfile();
  }
  if (!g_settings_controller) {
    g_settings_controller = [[LightNativeSettingsWindowController alloc]
        initWithProfile:profile
                browser:browser];
  } else {
    [g_settings_controller updateContextWithProfile:profile browser:browser];
  }
  [g_settings_controller showWindow];
}
}  // namespace

@implementation LightNativeSettingsMenuBridge
+ (void)openForProfilePtr:(NSValue*)profileValue {
  Profile* profile = static_cast<Profile*>(profileValue.pointerValue);
  ShowSettingsWindowImpl(profile, nullptr);
}
@end

// static
void LightNativeSettingsController::ShowForBrowser(
    BrowserWindowInterface* browser) {
  ShowSettingsWindowImpl(browser ? browser->GetProfile() : nullptr, browser);
}

// static
void LightNativeSettingsController::ShowForBrowserToCategory(
    BrowserWindowInterface* browser,
    const std::string& category_title) {
  ShowSettingsWindowImpl(browser ? browser->GetProfile() : nullptr, browser);
  if (g_settings_controller && !category_title.empty()) {
    [g_settings_controller
        selectCategoryByTitle:base::SysUTF8ToNSString(category_title)];
  }
}

// static
void LightNativeSettingsController::ShowForProfile(Profile* profile) {
  ShowSettingsWindowImpl(profile, nullptr);
}
