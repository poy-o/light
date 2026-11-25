// Copyright 2018 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

#include "base/compiler_specific.h"
#include "base/mac/mac_util.h"
#import "base/mac/scoped_sending_event.h"
#include "base/memory/raw_ptr.h"
#import "base/message_loop/message_pump_apple.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/current_thread.h"
#include "base/values.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_ui_bindings.h"
#include "chrome/browser/headless/headless_mode_util.h"
#import "components/remote_cocoa/app_shim/menu_controller_cocoa_delegate_impl.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/url_constants.h"
#include "third_party/blink/public/common/context_menu_data/edit_flags.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "ui/base/cocoa/menu_utils.h"
#include "ui/base/interaction/element_tracker_mac.h"
#include "ui/color/color_provider.h"
#import "ui/menus/cocoa/menu_controller.h"
#include "ui/views/controls/menu/menu_controller_cocoa_delegate_params.h"
#include "ui/views/interaction/element_tracker_views.h"
#include "ui/views/widget/widget.h"

namespace {

// Retrieves an NSMenuItem which has the specified command_id. This function
// traverses the given |model| in the depth-first order. When this function
// finds an item whose command_id is the same as the given |command_id|, it
// returns the NSMenuItem associated with the item. This function emulates
// views::MenuItemViews::GetMenuItemByID() for Mac.
NSMenuItem* GetMenuItemByID(ui::MenuModel* model,
                            NSMenu* menu,
                            int command_id) {
  for (size_t i = 0; i < model->GetItemCount(); ++i) {
    NSMenuItem* item = [menu itemAtIndex:i];
    if (model->GetCommandIdAt(i) == command_id) {
      return item;
    }

    ui::MenuModel* submenu = model->GetSubmenuModelAt(i);
    if (submenu && [item hasSubmenu]) {
      NSMenuItem* subitem =
          GetMenuItemByID(submenu, [item submenu], command_id);
      if (subitem) {
        return subitem;
      }
    }
  }
  return nil;
}

constexpr CGFloat kPinnedTileHeight = 30.0;
constexpr CGFloat kPinnedTileMinWidth = 34.0;
constexpr CGFloat kPinnedTileGap = 5.0;
constexpr CGFloat kPinnedTileRadius = 8.0;
constexpr CGFloat kPinnedIconBasePointSize = 13.5;
constexpr CGFloat kPinnedIconMinPointSize = 11.0;
constexpr CGFloat kPinnedPaddingX = 8.0;
constexpr CGFloat kPinnedPaddingY = 5.0;

NSString* SymbolForCommand(int command_id) {
  switch (command_id) {
    case IDC_BACK:
      return @"chevron.backward";
    case IDC_FORWARD:
      return @"chevron.forward";
    case IDC_RELOAD:
      return @"arrow.clockwise";
    case IDC_SAVE_PAGE:
      return @"square.and.arrow.down";
    case IDC_PRINT:
      return @"printer";
    case IDC_VIEW_SOURCE:
      return @"chevron.left.forwardslash.chevron.right";
    case IDC_CONTENT_CONTEXT_SEARCHWEBFOR:
    case IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB:
      return @"magnifyingglass";
    case IDC_CONTENT_CONTEXT_TRANSLATE:
    case IDC_CONTENT_CONTEXT_PARTIAL_TRANSLATE:
      return @"character.book.closed";
    case IDC_CONTENT_CONTEXT_INSPECTELEMENT:
    case IDC_CONTENT_CONTEXT_INSPECTELEMENT_WITH_DEVTOOLS:
      return @"ladybug";
    case IDC_CONTENT_CONTEXT_EXIT_FULLSCREEN:
      return @"arrow.down.right.and.arrow.up.left";
    case IDC_CONTENT_CONTEXT_OPENLINKNEWTAB:
    case IDC_CONTENT_CONTEXT_OPENLINK_ISOLATED:
    case IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB:
    case IDC_CONTENT_CONTEXT_OPENAVNEWTAB:
    case IDC_CONTENT_CONTEXT_OPEN_ORIGINAL_IMAGE_NEW_TAB:
      return @"arrow.up.forward.square";
    case IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW:
      return @"arrow.up.forward.app";
    case IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD:
      return @"eye.slash";
    case IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW:
      return @"rectangle.split.2x1";
    case IDC_CONTENT_CONTEXT_SAVELINKAS:
    case IDC_CONTENT_CONTEXT_SAVEIMAGEAS:
    case IDC_CONTENT_CONTEXT_SAVEAVAS:
    case IDC_CONTENT_CONTEXT_SAVEVIDEOFRAMEAS:
    case IDC_CONTENT_CONTEXT_SAVEPLUGINAS:
      return @"square.and.arrow.down";
    case IDC_CONTENT_CONTEXT_COPYLINKLOCATION:
    case IDC_CONTENT_CONTEXT_COPYIMAGELOCATION:
    case IDC_CONTENT_CONTEXT_COPYAVLOCATION:
      return @"link";
    case IDC_CONTENT_CONTEXT_COPYLINKTEXT:
    case IDC_CONTENT_CONTEXT_COPYLINKTOTEXT:
    case IDC_CONTENT_CONTEXT_COPYIMAGE:
    case IDC_CONTENT_CONTEXT_COPYVIDEOFRAME:
    case IDC_CONTENT_CONTEXT_COPY:
      return @"doc.on.doc";
    case IDC_CONTENT_CONTEXT_ADD_LINK_TO_READING_LIST:
      return @"eyeglasses";
    case IDC_CONTENT_CONTEXT_OPENLINKINPROFILE:
      return @"person.crop.circle";
    case IDC_CONTENT_CONTEXT_VIDEO_FRAME:
      return @"photo";
    case IDC_CONTENT_CONTEXT_LOAD_IMAGE:
      return @"arrow.clockwise";
    case IDC_CONTENT_CONTEXT_PICTUREINPICTURE:
      return @"pip";
    case IDC_CONTENT_CONTEXT_LOOP:
      return @"repeat";
    case IDC_CONTENT_CONTEXT_CONTROLS:
      return @"slider.horizontal.3";
    case IDC_CONTENT_CONTEXT_ROTATECW:
      return @"rotate.right";
    case IDC_CONTENT_CONTEXT_ROTATECCW:
      return @"rotate.left";
    case IDC_CONTENT_CONTEXT_UNDO:
      return @"arrow.uturn.backward";
    case IDC_CONTENT_CONTEXT_REDO:
      return @"arrow.uturn.forward";
    case IDC_CONTENT_CONTEXT_CUT:
      return @"scissors";
    case IDC_CONTENT_CONTEXT_PASTE:
      return @"doc.on.clipboard";
    case IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE:
      return @"text.badge.checkmark";
    case IDC_CONTENT_CONTEXT_DELETE:
      return @"trash";
    case IDC_CONTENT_CONTEXT_SELECTALL:
      return @"square.dashed";
    case IDC_CONTENT_CONTEXT_LOOK_UP:
      return @"character.book.closed";
    case IDC_CONTENT_CONTEXT_EMOJI:
      return @"face.smiling";
    case IDC_CONTENT_CONTEXT_DICTATION:
      return @"mic";
    case IDC_CONTENT_CONTEXT_SPELLING_TOGGLE:
      return @"text.badge.checkmark";
    case IDC_SPELLCHECK_ADD_TO_DICTIONARY:
      return @"text.badge.plus";
    case IDC_SPELLCHECK_REMOVE_FROM_DICTIONARY:
      return @"text.badge.minus";
    case IDC_CONTENT_CONTEXT_GENERATEPASSWORD:
    case IDC_CONTENT_CONTEXT_SHOWALLSAVEDPASSWORDS:
    case IDC_CONTENT_CONTEXT_USE_PASSKEY_FROM_ANOTHER_DEVICE:
      return @"key";
    case IDC_CONTENT_CONTEXT_RELOADFRAME:
      return @"arrow.clockwise";
    case IDC_CONTENT_CONTEXT_VIEWFRAMESOURCE:
      return @"chevron.left.forwardslash.chevron.right";
    default:
      return nil;
  }
}

std::vector<int> PinnedCommands(const content::ContextMenuParams& params) {
  if (params.media_type == blink::mojom::ContextMenuDataMediaType::kImage) {
    if (!params.link_url.is_empty()) {
      return {IDC_CONTENT_CONTEXT_OPENLINKNEWTAB, IDC_CONTENT_CONTEXT_COPYIMAGE,
              IDC_CONTENT_CONTEXT_COPYLINKLOCATION};
    }
    return {IDC_CONTENT_CONTEXT_COPYIMAGE, IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB,
            IDC_CONTENT_CONTEXT_SAVEIMAGEAS};
  }
  if (params.is_editable) {
    return {IDC_CONTENT_CONTEXT_COPY, IDC_CONTENT_CONTEXT_PASTE,
            IDC_CONTENT_CONTEXT_CUT};
  }
  if (!params.selection_text.empty()) {
    return {IDC_CONTENT_CONTEXT_COPY, IDC_CONTENT_CONTEXT_LOOK_UP};
  }
  return {IDC_BACK, IDC_FORWARD, IDC_RELOAD};
}

bool PinnedCommandEnabled(const RenderViewContextMenu& menu, int command_id) {
  const content::ContextMenuParams& params = menu.params();
  switch (command_id) {
    case IDC_CONTENT_CONTEXT_COPY:
      return (params.edit_flags & blink::ContextMenuDataEditFlags::kCanCopy) != 0;
    case IDC_CONTENT_CONTEXT_CUT:
      return (params.edit_flags & blink::ContextMenuDataEditFlags::kCanCut) != 0;
    case IDC_CONTENT_CONTEXT_PASTE:
      return (params.edit_flags & blink::ContextMenuDataEditFlags::kCanPaste) != 0;
    case IDC_CONTENT_CONTEXT_UNDO:
      return (params.edit_flags & blink::ContextMenuDataEditFlags::kCanUndo) != 0;
    case IDC_CONTENT_CONTEXT_LOOK_UP:
      return !params.selection_text.empty();
    default:
      return menu.IsCommandIdEnabled(command_id);
  }
}

NSString* SymbolForMenuItemTitle(NSString* title) {
  if (!title.length) {
    return nil;
  }
  NSString* lower = title.lowercaseString;
  if ([lower containsString:@"elements"]) {
    return @"chevron.left.forwardslash.chevron.right";
  }
  if ([lower containsString:@"console"]) {
    return @"terminal";
  }
  if ([lower containsString:@"network"] || [lower containsString:@"throttling"]) {
    return @"network";
  }
  if ([lower containsString:@"sources"]) {
    return @"doc.text";
  }
  if ([lower containsString:@"memory"]) {
    return @"memorychip";
  }
  if ([lower containsString:@"application"]) {
    return @"app.badge";
  }
  if ([lower containsString:@"lighthouse"]) {
    return @"gauge.with.needle";
  }
  if ([lower containsString:@"security"]) {
    return @"lock.shield";
  }
  if ([lower containsString:@"recorder"] || [lower containsString:@"record"]) {
    return @"record.circle";
  }
  if ([lower containsString:@"performance"]) {
    return @"speedometer";
  }
  if ([lower containsString:@"issues"]) {
    return @"exclamationmark.triangle";
  }
  if ([lower containsString:@"animations"]) {
    return @"sparkles";
  }
  if ([lower containsString:@"coverage"]) {
    return @"chart.bar";
  }
  if ([lower containsString:@"changes"]) {
    return @"arrow.left.arrow.right";
  }
  if ([lower containsString:@"css"] || [lower containsString:@"style"]) {
    return @"paintbrush";
  }
  if ([lower containsString:@"sensors"] || [lower containsString:@"location"]) {
    return @"location";
  }
  if ([lower containsString:@"layers"]) {
    return @"square.3.layers.3d";
  }
  if ([lower containsString:@"media"]) {
    return @"play.rectangle";
  }
  if ([lower containsString:@"protocol"]) {
    return @"antenna.radiowaves.left.and.right";
  }
  if ([lower containsString:@"developer"] || [lower containsString:@"resources"]) {
    return @"wrench.and.screwdriver";
  }
  if ([lower containsString:@"overrides"]) {
    return @"slider.horizontal.3";
  }
  if ([lower containsString:@"dock"] || [lower containsString:@"undock"]) {
    return @"rectangle.bottomthird.inset.filled";
  }
  if ([lower containsString:@"settings"] || [lower containsString:@"preferences"]) {
    return @"gearshape";
  }
  if ([lower containsString:@"shortcuts"]) {
    return @"keyboard";
  }
  if ([lower containsString:@"help"] || [lower containsString:@"documentation"]) {
    return @"questionmark.circle";
  }
  if ([lower containsString:@"more tools"]) {
    return @"ellipsis.circle";
  }
  if ([lower containsString:@"continue"] || [lower containsString:@"resume"]) {
    return @"play.fill";
  }
  if ([lower containsString:@"pause"]) {
    return @"pause.fill";
  }
  if ([lower containsString:@"step"]) {
    return @"arrow.turn.down.right";
  }
  if ([lower containsString:@"breakpoint"] || [lower containsString:@"logpoint"]) {
    return @"circle.inset.filled";
  }
  if ([lower containsString:@"duplicate"]) {
    return @"plus.square.on.square";
  }
  if ([lower containsString:@"format"] || [lower containsString:@"pretty"]) {
    return @"text.alignleft";
  }
  if ([lower containsString:@"wrap"]) {
    return @"arrow.uturn.left";
  }
  if ([lower containsString:@"preserve"] || [lower containsString:@"pin"]) {
    return @"pin";
  }
  if ([lower containsString:@"disable"] || [lower containsString:@"block"]) {
    return @"nosign";
  }
  if ([lower containsString:@"enable"]) {
    return @"checkmark.circle";
  }
  if ([lower containsString:@"device"] || [lower containsString:@"emulate"]) {
    return @"iphone";
  }
  if ([lower containsString:@"copy"]) {
    return @"doc.on.doc";
  }
  if ([lower containsString:@"cut"]) {
    return @"scissors";
  }
  if ([lower containsString:@"paste"]) {
    return @"doc.on.clipboard";
  }
  if ([lower containsString:@"delete"] || [lower containsString:@"remove"] ||
      [lower containsString:@"clear"]) {
    return @"trash";
  }
  if ([lower containsString:@"edit"] || [lower containsString:@"rename"]) {
    return @"pencil";
  }
  if ([lower containsString:@"add"] || [lower containsString:@"new"]) {
    return @"plus";
  }
  if ([lower containsString:@"inspect"] || [lower containsString:@"reveal"] ||
      [lower containsString:@"show"] || [lower containsString:@"rendering"] ||
      [lower containsString:@"evaluate"] || [lower containsString:@"watch"]) {
    return @"eye";
  }
  if ([lower containsString:@"hide"]) {
    return @"eye.slash";
  }
  if ([lower containsString:@"expand"]) {
    return @"chevron.down.square";
  }
  if ([lower containsString:@"collapse"]) {
    return @"chevron.up.square";
  }
  if ([lower containsString:@"focus"] || [lower containsString:@"scroll"] ||
      [lower containsString:@"highlight"]) {
    return @"scope";
  }
  if ([lower containsString:@"force"] || [lower containsString:@"break on"]) {
    return @"bolt";
  }
  if ([lower containsString:@"save"] || [lower containsString:@"export"] ||
      [lower containsString:@"download"]) {
    return @"square.and.arrow.down";
  }
  if ([lower containsString:@"filter"] || [lower containsString:@"search"] ||
      [lower containsString:@"find"]) {
    return @"magnifyingglass";
  }
  if ([lower containsString:@"reload"] || [lower containsString:@"refresh"]) {
    return @"arrow.clockwise";
  }
  if ([lower containsString:@"open"]) {
    return @"arrow.up.forward.square";
  }
  if ([lower containsString:@"capture"] || [lower containsString:@"screenshot"]) {
    return @"camera";
  }
  if ([lower containsString:@"store"]) {
    return @"tray.and.arrow.down";
  }
  return nil;
}

void ApplyIconsToMenu(ui::MenuModel* model, NSMenu* menu) {
  if (!model || !menu) {
    return;
  }
  const NSInteger menuCount = [menu numberOfItems];
  const size_t modelCount = model->GetItemCount();
  for (size_t i = 0; i < modelCount && static_cast<NSInteger>(i) < menuCount;
       ++i) {
    NSMenuItem* item = [menu itemAtIndex:static_cast<NSInteger>(i)];
    if (!item || item.isSeparatorItem) {
      continue;
    }
    if (!item.image) {
      NSString* sym = SymbolForCommand(model->GetCommandIdAt(i));
      if (!sym) {
        sym = SymbolForMenuItemTitle(item.title);
      }
      if (sym) {
        NSImage* img = [NSImage imageWithSystemSymbolName:sym
                                 accessibilityDescription:nil];
        if (img) {
          [img setTemplate:YES];
          item.image = img;
        }
      }
    }
    ui::MenuModel* submenu = model->GetSubmenuModelAt(i);
    if (submenu && [item hasSubmenu]) {
      ApplyIconsToMenu(submenu, [item submenu]);
    }
  }
}

void RemoveCommandsAndSqueezeSeparators(NSMenu* menu,
                                        ui::MenuModel* model,
                                        const std::vector<int>& commands) {
  if (!menu || !model) {
    return;
  }
  for (size_t i = model->GetItemCount(); i-- > 0;) {
    if (static_cast<NSInteger>(i) >= [menu numberOfItems]) {
      continue;
    }
    int cmd = model->GetCommandIdAt(i);
    if (std::find(commands.begin(), commands.end(), cmd) != commands.end()) {
      [menu removeItemAtIndex:static_cast<NSInteger>(i)];
    }
  }
  for (NSInteger i = [menu numberOfItems] - 1; i >= 0; --i) {
    NSInteger count = [menu numberOfItems];
    if (i < count && [menu itemAtIndex:i].isSeparatorItem &&
        (i == 0 || i + 1 == count || [menu itemAtIndex:i + 1].isSeparatorItem)) {
      [menu removeItemAtIndex:i];
    }
  }
}

}  // namespace

@interface LightCtxPinnedActionTarget : NSObject
- (void)lightNoop:(id)sender;
@end

@implementation LightCtxPinnedActionTarget
- (void)lightNoop:(id)sender {
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
  return YES;
}
@end

@interface LightCtxPinnedTileView : NSView
@property(nonatomic, copy) void (^onClick)(void);
@property(nonatomic, readonly, getter=isTileEnabled) BOOL tileEnabled;
- (instancetype)initWithSymbol:(NSString*)symbol enabled:(BOOL)enabled;
- (void)updateIconPointSize:(CGFloat)pointSize;
- (void)clearHover;
@end

@implementation LightCtxPinnedTileView {
  NSString* __strong _symbolName;
  CGFloat _currentPointSize;
  NSImageView* __strong _icon;
  NSTrackingArea* __strong _trackingArea;
  id __strong _mouseMonitor;
  id __strong _windowObserver;
  id __strong _menuObserver;
  BOOL _hovered;
}

@synthesize onClick = _onClick;
@synthesize tileEnabled = _tileEnabled;

- (instancetype)initWithSymbol:(NSString*)symbol enabled:(BOOL)enabled {
  self = [super
      initWithFrame:NSMakeRect(0, 0, kPinnedTileMinWidth, kPinnedTileHeight)];
  if (self) {
    _symbolName = [symbol copy];
    _currentPointSize = 0.0;
    _tileEnabled = enabled;
    self.wantsLayer = YES;
    self.layer.cornerRadius = kPinnedTileRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.backgroundColor =
        [NSColor.whiteColor colorWithAlphaComponent:0.12].CGColor;

    _icon = [[NSImageView alloc] initWithFrame:self.bounds];
    _icon.contentTintColor = NSColor.labelColor;
    _icon.imageScaling = NSImageScaleNone;
    _icon.imageAlignment = NSImageAlignCenter;
    _icon.alphaValue = enabled ? 1.0 : 0.4;
    _icon.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_icon];
    [self updateIconPointSize:kPinnedIconBasePointSize];

    __weak LightCtxPinnedTileView* weakSelf = self;
    _windowObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidResignKeyNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  [weakSelf clearHover];
                }];
    _menuObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSMenuDidEndTrackingNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  [weakSelf clearHover];
                }];
  }
  return self;
}

- (void)updateIconPointSize:(CGFloat)pointSize {
  if (std::abs(_currentPointSize - pointSize) < 0.25 || !_symbolName) {
    return;
  }
  _currentPointSize = pointSize;
  NSImage* image = [NSImage imageWithSystemSymbolName:_symbolName
                             accessibilityDescription:nil];
  NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration
      configurationWithPointSize:pointSize
                          weight:NSFontWeightMedium];
  image = [image imageWithSymbolConfiguration:config];
  [image setTemplate:YES];
  _icon.image = image;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:_windowObserver];
  [[NSNotificationCenter defaultCenter] removeObserver:_menuObserver];
  if (_mouseMonitor) {
    [NSEvent removeMonitor:_mouseMonitor];
  }
}

- (NSView*)hitTest:(NSPoint)point {
  return NSPointInRect([self convertPoint:point fromView:self.superview],
                       self.bounds)
             ? self
             : nil;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
    _trackingArea = nil;
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                   NSTrackingActiveAlways | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)setHovered:(BOOL)hovered {
  const BOOL next = hovered && self.tileEnabled;
  if (_hovered == next) {
    return;
  }
  _hovered = next;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.layer.backgroundColor =
      [NSColor.whiteColor colorWithAlphaComponent:(next ? 0.17 : 0.12)].CGColor;
  [CATransaction commit];
}

- (void)clearHover {
  [self setHovered:NO];
}

- (void)mouseEntered:(NSEvent*)event {
  [self setHovered:YES];
}

- (void)mouseExited:(NSEvent*)event {
  [self setHovered:NO];
}

- (void)mouseMoved:(NSEvent*)event {
  [self updateHoverForEvent:event];
}

- (void)updateHoverForEvent:(NSEvent*)event {
  if (!self.window || (event.window && event.window != self.window)) {
    [self setHovered:NO];
    return;
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  [self setHovered:NSPointInRect(point, self.bounds)];
}

- (void)installMouseMonitor {
  if (_mouseMonitor) {
    return;
  }
  const NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                           NSEventMaskRightMouseDragged;
  __weak LightCtxPinnedTileView* weakSelf = self;
  _mouseMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:mask
                                   handler:^NSEvent*(NSEvent* event) {
                                     [weakSelf updateHoverForEvent:event];
                                     return event;
                                   }];
}

- (void)removeMouseMonitor {
  if (_mouseMonitor) {
    [NSEvent removeMonitor:_mouseMonitor];
    _mouseMonitor = nil;
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [self installMouseMonitor];
  } else {
    [self removeMouseMonitor];
    [self clearHover];
  }
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
  [super viewWillMoveToWindow:newWindow];
  if (!newWindow) {
    [self removeMouseMonitor];
    [self clearHover];
  }
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (void)mouseDown:(NSEvent*)event {
  [self setHovered:NO];
}

- (void)mouseUp:(NSEvent*)event {
  if (self.tileEnabled && self.onClick) {
    self.onClick();
  }
}
@end

@interface LightCtxPinnedActionsView : NSView
- (instancetype)initWithTiles:(NSArray<LightCtxPinnedTileView*>*)tiles
                        width:(CGFloat)width;
@end

@implementation LightCtxPinnedActionsView {
  NSArray<LightCtxPinnedTileView*>* __strong _tiles;
}

- (instancetype)initWithTiles:(NSArray<LightCtxPinnedTileView*>*)tiles
                        width:(CGFloat)width {
  const NSUInteger count = tiles.count;
  const CGFloat gaps = count > 1 ? (count - 1) * kPinnedTileGap : 0;
  const CGFloat minWidth =
      count * kPinnedTileMinWidth + gaps + 2 * kPinnedPaddingX;
  const CGFloat height = kPinnedTileHeight + 2 * kPinnedPaddingY;
  self = [super initWithFrame:NSMakeRect(0, 0, MAX(width, minWidth), height)];
  if (self) {
    _tiles = [tiles copy];
    self.autoresizingMask = NSViewWidthSizable;
    for (LightCtxPinnedTileView* tile in _tiles) {
      [self addSubview:tile];
    }
    [self layoutTiles];
  }
  return self;
}

- (void)layoutTiles {
  const CGFloat width = NSWidth(self.bounds);
  const NSUInteger count = _tiles.count;
  if (count == 0) {
    return;
  }
  const CGFloat gaps = count > 1 ? (count - 1) * kPinnedTileGap : 0;
  // Shrink horizontal padding and icon size proportionally as menu width narrows.
  const CGFloat padX = std::clamp<CGFloat>(width * 0.04, 5.0, kPinnedPaddingX);
  const CGFloat content = width - 2 * padX;
  const CGFloat tileWidth = MAX((content - gaps) / count, kPinnedTileMinWidth);
  const CGFloat rowWidth = tileWidth * count + gaps;
  const CGFloat padRatio =
      std::clamp<CGFloat>((padX - 5.0) / (kPinnedPaddingX - 5.0), 0.0, 1.0);
  const CGFloat tileRatio =
      std::clamp<CGFloat>((tileWidth - kPinnedTileMinWidth) / 28.0, 0.0, 1.0);
  const CGFloat scale = std::min<CGFloat>(padRatio, tileRatio);
  const CGFloat iconSize =
      kPinnedIconMinPointSize +
      (kPinnedIconBasePointSize - kPinnedIconMinPointSize) * scale;
  CGFloat x = padX + floor((content - rowWidth) / 2);
  for (LightCtxPinnedTileView* tile in _tiles) {
    tile.frame = NSMakeRect(x, kPinnedPaddingY, tileWidth, kPinnedTileHeight);
    [tile updateIconPointSize:iconSize];
    x += tileWidth + kPinnedTileGap;
  }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTiles];
}
@end

// Obj-C bridge class that is the target of all items in the context menu.
// Relies on the tag being set to the command id.
RenderViewContextMenuMacCocoa::RenderViewContextMenuMacCocoa(
    content::RenderFrameHost& render_frame_host,
    const content::ContextMenuParams& params,
    bool is_paste_enabled,
    bool is_paste_and_match_style_enabled,
    NSView* parent_view)
    : RenderViewContextMenuMac(render_frame_host,
                               params,
                               is_paste_enabled,
                               is_paste_and_match_style_enabled),
      parent_view_(parent_view) {}

RenderViewContextMenuMacCocoa::~RenderViewContextMenuMacCocoa() {
  if (menu_controller_) {
    [menu_controller_ cancel];
  }
}

void RenderViewContextMenuMacCocoa::Show() {
  views::Widget* widget = views::Widget::GetTopLevelWidgetForNativeView(
      source_web_contents_->GetNativeView());

  if (!widget || headless::IsHeadlessMode()) {
    return;
  }

  menu_controller_delegate_ = [[MenuControllerCocoaDelegateImpl alloc]
      initWithParams:MenuControllerParamsForWidget(widget)];
  menu_controller_ =
      [[MenuControllerCocoa alloc] initWithModel:&menu_model_
                                   isContextMenu:YES
                                        delegate:menu_controller_delegate_];

  NSPoint position =
      NSMakePoint(params_.x, NSHeight(parent_view_.bounds) - params_.y);
  position = [parent_view_ convertPoint:position toView:nil];
  NSEvent* clickEvent = ui::EventForPositioningContextMenuRelativeToWindow(
      position, [parent_view_ window]);

  NSMenu* cocoaMenu = menu_controller_.menu;
  ApplyIconsToMenu(&menu_model_, cocoaMenu);

  NSMutableArray<LightCtxPinnedTileView*>* tiles = [NSMutableArray array];
  if (params_.page_url.SchemeIs(content::kChromeDevToolsScheme)) {
    struct DevToolsPanelTile {
      const char* panel_id;
      NSString* symbol;
    };
    const DevToolsPanelTile kDevToolsTiles[] = {
        {"elements", @"chevron.left.forwardslash.chevron.right"},
        {"console", @"terminal"},
        {"network", @"network"},
    };
    content::WebContents* wc = source_web_contents_;
    for (const auto& entry : kDevToolsTiles) {
      LightCtxPinnedTileView* tile =
          [[LightCtxPinnedTileView alloc] initWithSymbol:entry.symbol
                                                 enabled:YES];
      std::string panelId = entry.panel_id;
      tile.onClick = ^{
        [cocoaMenu cancelTracking];
        if (DevToolsUIBindings* bindings =
                wc ? DevToolsUIBindings::ForWebContents(wc) : nullptr) {
          bindings->CallClientMethod("DevToolsAPI", "showPanel",
                                     base::Value(panelId));
        }
      };
      [tiles addObject:tile];
    }
  } else {
    std::vector<int> pinned = PinnedCommands(params_);
    RemoveCommandsAndSqueezeSeparators(cocoaMenu, &menu_model_, pinned);

    for (int command : pinned) {
      NSString* symbol = SymbolForCommand(command);
      if (!symbol) {
        continue;
      }
      LightCtxPinnedTileView* tile = [[LightCtxPinnedTileView alloc]
          initWithSymbol:symbol
                 enabled:PinnedCommandEnabled(*this, command)];
      base::WeakPtr<RenderViewContextMenuMacCocoa> weak =
          weak_factory_.GetWeakPtr();
      tile.onClick = ^{
        [cocoaMenu cancelTracking];
        if (weak) {
          weak->ExecuteCommand(command, 0);
        }
      };
      [tiles addObject:tile];
    }
  }
  if (tiles.count > 0) {
    LightCtxPinnedActionsView* strip =
        [[LightCtxPinnedActionsView alloc] initWithTiles:tiles
                                                   width:[cocoaMenu size].width];
    NSMenuItem* stripItem = [[NSMenuItem alloc] initWithTitle:@""
                                                       action:nil
                                                keyEquivalent:@""];
    stripItem.view = strip;
    if (!pinned_target_) {
      pinned_target_ = [[LightCtxPinnedActionTarget alloc] init];
    }
    stripItem.target = pinned_target_;
    stripItem.action = @selector(lightNoop:);
    [cocoaMenu insertItem:stripItem atIndex:0];
    [cocoaMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
  }

  ui::ShowContextMenu(cocoaMenu, clickEvent, parent_view_,
                      /*allow_nested_tasks=*/true,
                      views::ElementTrackerViews::GetContextForWidget(widget));
}

void RenderViewContextMenuMacCocoa::CancelToolkitMenu() {
  [menu_controller_ cancel];
}

void RenderViewContextMenuMacCocoa::UpdateToolkitMenuItem(
    int command_id,
    bool enabled,
    bool hidden,
    const std::u16string& title) {
  NSMenuItem* item =
      GetMenuItemByID(&menu_model_, [menu_controller_ menu], command_id);
  if (!item) {
    return;
  }

  // Update the returned NSMenuItem directly so we can update it immediately.
  item.enabled = enabled;
  item.title = base::SysUTF16ToNSString(title);
  item.hidden = hidden;
}
