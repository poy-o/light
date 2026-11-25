// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/views/frame/light_glass_modal_mac.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <utility>
#include <variant>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/webauthn/authenticator_request_dialog_model.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_util.h"
#include "components/permissions/request_type.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia_util_mac.h"
#include "ui/views/bubble/bubble_frame_view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/non_client_view.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

@protocol LightModalCIFilterPrivate <NSObject>
+ (id)filterWithName:(NSString*)name;
- (void)setDefaults;
- (void)setValue:(id)value forKey:(NSString*)key;
@end

namespace {

constexpr CGFloat kModalCornerRadius = 15.0;

id MakeModalGaussianBlurFilter(CGFloat radius) {
  Class ciFilterClass = NSClassFromString(@"CIFilter");
  if (!ciFilterClass) {
    return nil;
  }
  id filter = [(id<LightModalCIFilterPrivate>)ciFilterClass
      filterWithName:@"CIGaussianBlur"];
  if (!filter) {
    return nil;
  }
  [filter setDefaults];
  [filter setValue:@(radius) forKey:@"inputRadius"];
  [filter setValue:@"permBlur" forKey:@"name"];
  return filter;
}

bool ModalUDBool(NSString* key, bool fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj boolValue];
  }
  return fallback;
}

double ModalUDDouble(NSString* key, double fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj doubleValue];
  }
  return fallback;
}

NSInteger ModalUDInt(NSString* key, NSInteger fallback) {
  NSObject* obj = [NSUserDefaults.standardUserDefaults objectForKey:key];
  if ([obj isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)obj integerValue];
  }
  return fallback;
}

void ApplyAdaptiveGlassSettingsToView(NSView* view, CGFloat extraTintAlpha) {
  if (@available(macOS 26.0, *)) {
    if (![view isKindOfClass:[NSGlassEffectView class]]) {
      return;
    }
    NSGlassEffectView* glass = (NSGlassEffectView*)view;
    NSInteger styleIdx =
        std::clamp<NSInteger>(ModalUDInt(@"LightSidebarGlassStyle", 0), 0, 1);
    glass.style = (styleIdx == 1) ? NSGlassEffectViewStyleClear
                                  : NSGlassEffectViewStyleRegular;

    NSInteger adaptiveVal = std::clamp<NSInteger>(
        ModalUDInt(@"LightSidebarGlassAdaptive", 2), 0, 2);
    SEL adaptiveSel = NSSelectorFromString(@"set_adaptiveAppearance:");
    if ([glass respondsToSelector:adaptiveSel]) {
      [glass setValue:@(adaptiveVal) forKey:@"_adaptiveAppearance"];
    }

    if (@available(macOS 27.0, *)) {
      BOOL interactive = ModalUDBool(@"LightSidebarGlassInteractive", true);
      glass.effectIsInteractive = interactive;
    }

    CGFloat tintAlphaPct = std::clamp<CGFloat>(
        ModalUDDouble(@"LightSidebarTintAlpha", 4.0), 0.0, 100.0);
    CGFloat tr =
        std::clamp<CGFloat>(ModalUDDouble(@"LightSidebarTintR", 1.0), 0.0, 1.0);
    CGFloat tg =
        std::clamp<CGFloat>(ModalUDDouble(@"LightSidebarTintG", 1.0), 0.0, 1.0);
    CGFloat tb =
        std::clamp<CGFloat>(ModalUDDouble(@"LightSidebarTintB", 1.0), 0.0, 1.0);
    CGFloat alpha =
        std::clamp<CGFloat>((tintAlphaPct / 100.0) + extraTintAlpha, 0.0, 0.90);
    if (alpha <= 0.005) {
      glass.tintColor = nil;
    } else {
      glass.tintColor =
          [NSColor colorWithSRGBRed:tr green:tg blue:tb alpha:alpha];
    }
  }
}

NSView* MakeLiquidGlassBackdrop(NSRect bounds,
                                CGFloat cornerRadius,
                                CGFloat extraTintAlpha = 0.03) {
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:bounds];
    glass.wantsLayer = YES;
    glass.cornerRadius = cornerRadius;
    glass.layer.borderWidth = 0.0;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    ApplyAdaptiveGlassSettingsToView(glass, extraTintAlpha);
    return glass;
  }
  NSVisualEffectView* vfx = [[NSVisualEffectView alloc] initWithFrame:bounds];
  vfx.wantsLayer = YES;
  vfx.material = NSVisualEffectMaterialHUDWindow;
  vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  vfx.state = NSVisualEffectStateActive;
  vfx.layer.cornerRadius = cornerRadius;
  vfx.layer.cornerCurve = kCACornerCurveContinuous;
  vfx.layer.masksToBounds = YES;
  vfx.layer.borderWidth = 0.0;
  vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return vfx;
}

NSRect BeginSidebarExtensionPopup(NSWindow* parentWindow) {
  Class bridgeCls = NSClassFromString(@"LightSidebarExtensionPopupBridge");
  SEL sel = NSSelectorFromString(@"beginExtensionPopupForWindow:");
  if (bridgeCls && [bridgeCls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id val = [bridgeCls performSelector:sel withObject:parentWindow];
#pragma clang diagnostic pop
    if ([val isKindOfClass:[NSValue class]]) {
      return [(NSValue*)val rectValue];
    }
  }
  return NSZeroRect;
}

void EndSidebarExtensionPopup(NSWindow* parentWindow) {
  Class bridgeCls = NSClassFromString(@"LightSidebarExtensionPopupBridge");
  SEL sel = NSSelectorFromString(@"endExtensionPopupForWindow:");
  if (bridgeCls && [bridgeCls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [bridgeCls performSelector:sel withObject:parentWindow];
#pragma clang diagnostic pop
  }
}

NSRect FrameAnchoredToSidebarRight(NSWindow* parentWindow,
                                   NSRect sidebarAnchorRect,
                                   CGFloat width,
                                   CGFloat height) {
  NSRect frame = NSMakeRect(0, 0, width, height);
  if (!NSIsEmptyRect(sidebarAnchorRect)) {
    frame.origin.x = std::floor(NSMaxX(sidebarAnchorRect) + 10.0);
    frame.origin.y = std::floor(NSMaxY(sidebarAnchorRect) - height + 4.0);
  } else if (parentWindow) {
    NSRect pf = parentWindow.frame;
    frame.origin.x = std::floor(NSMinX(pf) + 270.0);
    frame.origin.y = std::floor(NSMaxY(pf) - height - 48.0);
  }
  NSScreen* scr =
      (parentWindow && parentWindow.screen) ? parentWindow.screen : NSScreen.mainScreen;
  if (scr) {
    NSRect vf = scr.visibleFrame;
    if (NSMaxX(frame) > NSMaxX(vf) - 12.0) {
      frame.origin.x = std::floor(NSMaxX(vf) - width - 12.0);
    }
    if (NSMinX(frame) < NSMinX(vf) + 12.0) {
      frame.origin.x = std::floor(NSMinX(vf) + 12.0);
    }
    if (NSMinY(frame) < NSMinY(vf) + 12.0) {
      frame.origin.y = std::floor(NSMinY(vf) + 12.0);
    }
    if (NSMaxY(frame) > NSMaxY(vf) - 12.0) {
      frame.origin.y = std::floor(NSMaxY(vf) - height - 12.0);
    }
  }
  return frame;
}

void ClearViewsBackgroundsRecursively(views::View* view) {
  if (!view) {
    return;
  }
  view->SetBackground(nullptr);
  for (views::View* child : view->children()) {
    ClearViewsBackgroundsRecursively(child);
  }
}

}  // namespace

void LightApplyLiquidGlassToWidget(views::Widget* widget, float corner_radius) {
  if (!widget) {
    return;
  }
  NSWindow* win = widget->GetNativeWindow().GetNativeNSWindow();
  if (!win || !win.contentView) {
    return;
  }

  win.opaque = NO;
  win.backgroundColor = [NSColor clearColor];
  win.hasShadow = YES;

  NSView* contentView = win.contentView;
  contentView.wantsLayer = YES;
  contentView.layer.backgroundColor = [NSColor clearColor].CGColor;
  contentView.layer.cornerRadius = corner_radius;
  contentView.layer.cornerCurve = kCACornerCurveContinuous;
  contentView.layer.masksToBounds = YES;

  // Avoid adding duplicate glass backdrops across step transitions.
  static char kGlassBackdropKey;
  if (!objc_getAssociatedObject(contentView, &kGlassBackdropKey)) {
    NSView* glass =
        MakeLiquidGlassBackdrop(contentView.bounds, corner_radius);
    objc_setAssociatedObject(contentView, &kGlassBackdropKey, glass,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [contentView addSubview:glass positioned:NSWindowBelow relativeTo:nil];
  }

  if (views::NonClientView* ncv = widget->non_client_view()) {
    if (views::BubbleFrameView* bfv =
            static_cast<views::BubbleFrameView*>(ncv->frame_view())) {
      bfv->SetBackgroundColor(SK_ColorTRANSPARENT);
      bfv->SchedulePaint();
    }
  }
  ClearViewsBackgroundsRecursively(widget->GetContentsView());
}

@interface LightGlassPillButton : NSView
@property(nonatomic, copy) void (^onClick)(void);
- (instancetype)initWithTitle:(NSString*)title primary:(BOOL)primary;
@end

@implementation LightGlassPillButton {
  NSTextField* __strong _label;
  NSTrackingArea* __strong _trackingArea;
  BOOL _primary;
  BOOL _hovered;
  BOOL _pressed;
}

@synthesize onClick = _onClick;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithTitle:(NSString*)title primary:(BOOL)primary {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _primary = primary;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.0;

    _label = [NSTextField labelWithString:title];
    _label.font = [NSFont systemFontOfSize:13.0
                                    weight:(primary ? NSFontWeightSemibold
                                                    : NSFontWeightMedium)];
    _label.alignment = NSTextAlignmentCenter;
    _label.textColor =
        primary ? [NSColor colorWithWhite:0.08 alpha:1.0] : NSColor.labelColor;
    _label.focusRingType = NSFocusRingTypeNone;
    [self addSubview:_label];
    [self updateAppearance];
  }
  return self;
}

- (void)updateAppearance {
  if (_primary) {
    CGFloat alpha = _pressed ? 0.80 : (_hovered ? 1.0 : 0.93);
    self.layer.backgroundColor =
        [NSColor.whiteColor colorWithAlphaComponent:alpha].CGColor;
    self.layer.borderWidth = 0.0;
    self.layer.borderColor = nil;
  } else {
    CGFloat alpha = _pressed ? 0.22 : (_hovered ? 0.16 : 0.10);
    self.layer.backgroundColor =
        [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
    self.layer.borderWidth = 0.0;
    self.layer.borderColor = nil;
  }
}

- (void)layout {
  [super layout];
  NSSize fit = [_label sizeThatFits:NSMakeSize(300.0, 30.0)];
  _label.frame = NSMakeRect(
      0.0, std::floor((self.bounds.size.height - fit.height) * 0.5),
      self.bounds.size.width, std::ceil(fit.height));
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
  [self updateAppearance];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _pressed = NO;
  [self updateAppearance];
}

- (void)mouseDown:(NSEvent*)event {
  _pressed = YES;
  [self updateAppearance];
}

- (void)mouseUp:(NSEvent*)event {
  BOOL inside = NSPointInRect(
      [self convertPoint:event.locationInWindow fromView:nil], self.bounds);
  _pressed = NO;
  [self updateAppearance];
  if (inside && _onClick) {
    _onClick();
  }
}

@end

@interface LightGlassExtensionInstallPanel : NSPanel
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, copy) void (^onAccept)(void);
@property(nonatomic, assign) BOOL dismissOnOutsideClick;
@property(nonatomic, weak) NSView* adaptiveGlassView;
@property(nonatomic, assign) CGFloat extraGlassTint;
- (void)installKeyMonitor;
- (void)removeKeyMonitor;
@end

@implementation LightGlassExtensionInstallPanel {
  id __strong _keyMonitor;
  id __strong _clickMonitor;
  id __strong _settingsObserver;
}
@synthesize onCancel = _onCancel;
@synthesize onAccept = _onAccept;
@synthesize dismissOnOutsideClick = _dismissOnOutsideClick;
@synthesize adaptiveGlassView = _adaptiveGlassView;
@synthesize extraGlassTint = _extraGlassTint;

- (BOOL)canBecomeKeyWindow {
  return NO;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

- (void)installKeyMonitor {
  if (!_settingsObserver) {
    __weak __typeof(self) weakSelf = self;
    _settingsObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"LightSettingsDidChangeNotification"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                  __strong __typeof(weakSelf) s = weakSelf;
                  if (s && s.adaptiveGlassView) {
                    ApplyAdaptiveGlassSettingsToView(s.adaptiveGlassView,
                                                     s.extraGlassTint);
                  }
                }];
  }
  if (!_keyMonitor) {
    __weak __typeof(self) weakSelf = self;
    _keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
                                       __strong __typeof(weakSelf) s = weakSelf;
                                       if (!s || !s.isVisible) {
                                         return event;
                                       }
                                       if (event.keyCode == 53) {  // Escape
                                         if (s.onCancel) {
                                           s.onCancel();
                                         }
                                         return nil;
                                       }
                                       if (event.keyCode == 36 ||
                                           event.keyCode == 76) {  // Return
                                         if (s.onAccept) {
                                           s.onAccept();
                                           return nil;
                                         }
                                       }
                                       return event;
                                     }];
  }
  if (_dismissOnOutsideClick && !_clickMonitor) {
    __weak __typeof(self) weakSelf = self;
    _clickMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                              NSEventMaskRightMouseDown)
                                     handler:^NSEvent*(NSEvent* event) {
                                       __strong __typeof(weakSelf) s = weakSelf;
                                       if (!s || !s.isVisible) {
                                         return event;
                                       }
                                       if (event.window != s) {
                                         if (s.onCancel) {
                                           s.onCancel();
                                         }
                                       }
                                       return event;
                                     }];
  }
}

- (void)removeKeyMonitor {
  if (_keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
  }
  if (_clickMonitor) {
    [NSEvent removeMonitor:_clickMonitor];
    _clickMonitor = nil;
  }
  if (_settingsObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_settingsObserver];
    _settingsObserver = nil;
  }
}

- (void)orderOut:(id)sender {
  [self removeKeyMonitor];
  [super orderOut:sender];
}

- (void)dealloc {
  [self removeKeyMonitor];
}
@end

namespace {

void StripFocusRingsRecursively(NSView* view) {
  view.focusRingType = NSFocusRingTypeNone;
  for (NSView* sub in view.subviews) {
    StripFocusRingsRecursively(sub);
  }
}

}  // namespace

bool LightShowGlassExtensionInstallDialog(
    std::unique_ptr<ExtensionInstallPromptShowParams>& show_params,
    ExtensionInstallPrompt::DoneCallback& done_callback,
    std::unique_ptr<extensions::InstallPromptData>& prompt) {
  if (!prompt || !prompt->extension()) {
    return false;
  }
  using PromptType = extensions::InstallPromptData::PromptType;
  if (prompt->type() != PromptType::INSTALL_PROMPT &&
      prompt->type() != PromptType::REMOTE_INSTALL_PROMPT) {
    return false;
  }

  NSWindow* parentWindow =
      show_params && show_params->GetParentWindow()
          ? show_params->GetParentWindow().GetNativeNSWindow()
          : (NSApp.keyWindow ?: NSApp.mainWindow);

  NSString* titleText = base::SysUTF16ToNSString(prompt->GetDialogTitle());
  NSImage* iconImage = nil;
  if (!prompt->icon().IsEmpty()) {
    iconImage = gfx::NSImageFromImageSkia(*prompt->icon().ToImageSkia());
  }

  NSMutableArray<NSString*>* permissions = [NSMutableArray array];
  for (size_t i = 0; i < prompt->GetPermissionCount(); ++i) {
    NSString* perm = base::SysUTF16ToNSString(prompt->GetPermission(i));
    if (perm.length > 0) {
      [permissions addObject:perm];
    }
  }

  const CGFloat kWidth = 380.0;
  const CGFloat kPad = 20.0;
  CGFloat y = kPad;

  // Header height (icon + title).
  y += 44.0 + 14.0;

  // Permissions section.
  NSMutableArray<NSTextField*>* permLabels = [NSMutableArray array];
  NSTextField* permHeader = nil;
  if (permissions.count > 0) {
    permHeader = [NSTextField labelWithString:@"It can:"];
    permHeader.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    permHeader.textColor = NSColor.secondaryLabelColor;
    y += 20.0;

    for (NSString* perm in permissions) {
      NSTextField* lbl =
          [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"•  %@", perm]];
      lbl.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
      lbl.textColor = NSColor.labelColor;
      NSSize fit = [lbl sizeThatFits:NSMakeSize(kWidth - kPad * 2.0, 200.0)];
      lbl.frame = NSMakeRect(kPad, y, kWidth - kPad * 2.0, std::ceil(fit.height));
      y += std::ceil(fit.height) + 6.0;
      [permLabels addObject:lbl];
    }
    y += 10.0;
  } else {
    permHeader = [NSTextField
        wrappingLabelWithString:@"This extension requires no special permissions."];
    permHeader.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
    permHeader.textColor = NSColor.secondaryLabelColor;
    y += 22.0;
  }

  const CGFloat kBtnH = 30.0;
  const CGFloat totalH = y + kBtnH + kPad;

  NSRect frame = NSMakeRect(0, 0, kWidth, totalH);
  if (parentWindow) {
    NSRect pf = parentWindow.frame;
    frame.origin.x = std::floor(NSMidX(pf) - kWidth * 0.5);
    frame.origin.y = std::floor(NSMidY(pf) - totalH * 0.5 + 30.0);
  }

  LightGlassExtensionInstallPanel* panel =
      [[LightGlassExtensionInstallPanel alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskBorderless |
                               NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.hasShadow = YES;
  panel.level = NSModalPanelWindowLevel;
  panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  panel.releasedWhenClosed = NO;
  panel.autorecalculatesKeyViewLoop = NO;

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = kModalCornerRadius;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.layer.borderWidth = 0.0;
  panel.contentView = root;

  NSView* glass =
      MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH),
                              kModalCornerRadius, /*extraTintAlpha=*/0.035);
  panel.adaptiveGlassView = glass;
  panel.extraGlassTint = 0.035;
  [root addSubview:glass];

  // Flipped container inside glass for top-down layout.
  NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [glass addSubview:content];

  // AppKit default NSView is bottom-up, so compute from top (totalH).
  CGFloat topY = totalH - kPad;

  NSImageView* iconView =
      [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, topY - 44.0, 44.0, 44.0)];
  iconView.wantsLayer = YES;
  iconView.layer.cornerRadius = 10.0;
  iconView.layer.cornerCurve = kCACornerCurveContinuous;
  iconView.layer.masksToBounds = YES;
  iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  iconView.image =
      iconImage ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension"
                             accessibilityDescription:nil];
  [content addSubview:iconView];

  NSTextField* titleField = [NSTextField wrappingLabelWithString:titleText ?: @"Add extension?"];
  titleField.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightSemibold];
  titleField.textColor = NSColor.labelColor;
  NSSize titleFit =
      [titleField sizeThatFits:NSMakeSize(kWidth - kPad * 2.0 - 56.0, 60.0)];
  titleField.frame = NSMakeRect(
      kPad + 56.0, topY - 22.0 - std::ceil(titleFit.height) * 0.5,
      kWidth - kPad * 2.0 - 56.0, std::ceil(titleFit.height));
  [content addSubview:titleField];

  CGFloat curY = topY - 44.0 - 14.0;
  if (permHeader) {
    NSSize hFit = [permHeader sizeThatFits:NSMakeSize(kWidth - kPad * 2.0, 40.0)];
    permHeader.frame = NSMakeRect(kPad, curY - std::ceil(hFit.height),
                                  kWidth - kPad * 2.0, std::ceil(hFit.height));
    [content addSubview:permHeader];
    curY -= std::ceil(hFit.height) + 8.0;
  }

  for (NSTextField* lbl in permLabels) {
    CGFloat lh = lbl.frame.size.height;
    lbl.frame = NSMakeRect(kPad, curY - lh, kWidth - kPad * 2.0, lh);
    [content addSubview:lbl];
    curY -= lh + 6.0;
  }

  __block ExtensionInstallPrompt::DoneCallback callback = std::move(done_callback);
  __block std::unique_ptr<extensions::InstallPromptData> ownedPrompt =
      std::move(prompt);
  __block std::unique_ptr<ExtensionInstallPromptShowParams> ownedParams =
      std::move(show_params);
  __block BOOL finished = NO;

  auto finish = ^(ExtensionInstallPrompt::Result result) {
    if (finished) {
      return;
    }
    finished = YES;
    if (ownedPrompt) {
      if (result == ExtensionInstallPrompt::Result::ACCEPTED) {
        ownedPrompt->OnDialogAccepted();
      } else {
        ownedPrompt->OnDialogCanceled();
      }
    }
    [panel orderOut:nil];
    if (callback) {
      std::move(callback).Run(
          ExtensionInstallPrompt::DoneCallbackPayload(result));
    }
    ownedPrompt.reset();
    ownedParams.reset();
  };

  panel.onCancel = ^{
    finish(ExtensionInstallPrompt::Result::USER_CANCELED);
  };
  panel.onAccept = ^{
    finish(ExtensionInstallPrompt::Result::ACCEPTED);
  };

  CGFloat btnW = (kWidth - kPad * 2.0 - 10.0) * 0.5;
  LightGlassPillButton* cancelBtn =
      [[LightGlassPillButton alloc] initWithTitle:@"Cancel" primary:NO];
  cancelBtn.frame = NSMakeRect(kPad, kPad, btnW, kBtnH);
  cancelBtn.onClick = ^{
    finish(ExtensionInstallPrompt::Result::USER_CANCELED);
  };
  [content addSubview:cancelBtn];

  LightGlassPillButton* addBtn =
      [[LightGlassPillButton alloc] initWithTitle:@"Add Extension" primary:YES];
  addBtn.frame = NSMakeRect(kPad + btnW + 10.0, kPad, btnW, kBtnH);
  addBtn.onClick = ^{
    finish(ExtensionInstallPrompt::Result::ACCEPTED);
  };
  [content addSubview:addBtn];

  if (parentWindow) {
    [parentWindow addChildWindow:panel ordered:NSWindowAbove];
  }
  StripFocusRingsRecursively(panel.contentView);
  [panel installKeyMonitor];
  [panel orderFront:nil];
  return true;
}

// -----------------------------------------------------------------------------
// Native macOS Liquid Glass WebAuthn / Passkey Sheet
// -----------------------------------------------------------------------------
@interface LightGlassOptionRowView : NSView
@property(nonatomic, copy) void (^onClick)(void);
- (instancetype)initWithTitle:(NSString*)title
                     subtitle:(NSString*)subtitle
                       symbol:(NSString*)symbol;
@end

@implementation LightGlassOptionRowView {
  NSView* __strong _badgeBg;
  NSImageView* __strong _iconView;
  NSTextField* __strong _titleField;
  NSTextField* __strong _subtitleField;
  NSImageView* __strong _chevronView;
  NSTrackingArea* __strong _trackingArea;
  BOOL _hovered;
  BOOL _pressed;
}

@synthesize onClick = _onClick;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithTitle:(NSString*)title
                     subtitle:(NSString*)subtitle
                       symbol:(NSString*)symbol {
  if ((self = [super initWithFrame:NSZeroRect])) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 12.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.focusRingType = NSFocusRingTypeNone;

    _badgeBg = [[NSView alloc] initWithFrame:NSZeroRect];
    _badgeBg.wantsLayer = YES;
    _badgeBg.layer.cornerRadius = 8.0;
    _badgeBg.layer.cornerCurve = kCACornerCurveContinuous;
    _badgeBg.layer.backgroundColor =
        [NSColor.labelColor colorWithAlphaComponent:0.08].CGColor;
    [self addSubview:_badgeBg];

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage* img = [NSImage imageWithSystemSymbolName:symbol
                             accessibilityDescription:nil];
    if (img) {
      NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration
          configurationWithPointSize:14.0
                              weight:NSFontWeightMedium];
      _iconView.image = [img imageWithSymbolConfiguration:cfg];
    }
    _iconView.contentTintColor = NSColor.labelColor;
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    [_badgeBg addSubview:_iconView];

    _titleField = [NSTextField labelWithString:title ?: @""];
    _titleField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    _titleField.textColor = NSColor.labelColor;
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleField.focusRingType = NSFocusRingTypeNone;
    [self addSubview:_titleField];

    if (subtitle.length > 0) {
      _subtitleField = [NSTextField labelWithString:subtitle];
      _subtitleField.font =
          [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
      _subtitleField.textColor = NSColor.secondaryLabelColor;
      _subtitleField.lineBreakMode = NSLineBreakByTruncatingTail;
      _subtitleField.focusRingType = NSFocusRingTypeNone;
      [self addSubview:_subtitleField];
    }

    _chevronView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage* chev = [NSImage imageWithSystemSymbolName:@"chevron.right"
                              accessibilityDescription:nil];
    if (chev) {
      NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration
          configurationWithPointSize:11.0
                              weight:NSFontWeightSemibold];
      _chevronView.image = [chev imageWithSymbolConfiguration:cfg];
    }
    _chevronView.contentTintColor = NSColor.tertiaryLabelColor;
    _chevronView.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_chevronView];

    [self updateAppearance];
  }
  return self;
}

- (void)updateAppearance {
  CGFloat alpha = _pressed ? 0.18 : (_hovered ? 0.12 : 0.06);
  self.layer.backgroundColor =
      [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
  self.layer.borderColor =
      [NSColor.labelColor colorWithAlphaComponent:(_hovered ? 0.14 : 0.08)]
          .CGColor;
  self.layer.borderWidth = 0.5;
}

- (void)layout {
  [super layout];
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  _badgeBg.frame = NSMakeRect(10.0, std::floor((h - 30.0) * 0.5), 30.0, 30.0);
  _iconView.frame = NSMakeRect(0.0, 0.0, 30.0, 30.0);
  _chevronView.frame =
      NSMakeRect(w - 22.0, std::floor((h - 14.0) * 0.5), 12.0, 14.0);

  CGFloat textX = 50.0;
  CGFloat textW = std::max<CGFloat>(0.0, w - textX - 28.0);
  if (_subtitleField) {
    _titleField.frame = NSMakeRect(textX, 7.0, textW, 17.0);
    _subtitleField.frame = NSMakeRect(textX, 24.0, textW, 15.0);
  } else {
    _titleField.frame =
        NSMakeRect(textX, std::floor((h - 17.0) * 0.5), textW, 17.0);
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
  [self updateAppearance];
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  _pressed = NO;
  [self updateAppearance];
}

- (void)mouseDown:(NSEvent*)event {
  _pressed = YES;
  [self updateAppearance];
}

- (void)mouseUp:(NSEvent*)event {
  BOOL inside = NSPointInRect(
      [self convertPoint:event.locationInWindow fromView:nil], self.bounds);
  _pressed = NO;
  [self updateAppearance];
  if (inside && _onClick) {
    _onClick();
  }
}
@end

namespace {

std::unordered_map<AuthenticatorRequestDialogModel*,
                   LightGlassExtensionInstallPanel* __strong>&
WebAuthnPanels() {
  static auto* map =
      new std::unordered_map<AuthenticatorRequestDialogModel*,
                             LightGlassExtensionInstallPanel* __strong>();
  return *map;
}

NSString* SymbolForMechanism(
    const AuthenticatorRequestDialogModel::Mechanism& mech) {
  using M = AuthenticatorRequestDialogModel::Mechanism;
  if (std::holds_alternative<M::ICloudKeychain>(mech.type)) {
    return @"icloud.fill";
  }
  if (std::holds_alternative<M::Credential>(mech.type)) {
    return @"person.badge.key.fill";
  }
  if (std::holds_alternative<M::Hybrid>(mech.type)) {
    return @"iphone";
  }
  if (std::holds_alternative<M::Password>(mech.type)) {
    return @"lock.fill";
  }
  if (std::holds_alternative<M::Transport>(mech.type)) {
    return @"key.fill";
  }
  return @"key.fill";
}

}  // namespace

bool LightUpdateGlassWebAuthnDialog(AuthenticatorRequestDialogModel* model,
                                    views::Widget* parent_widget) {
  if (!model) {
    return false;
  }
  using Step = AuthenticatorRequestDialogModel::Step;
  const Step step = model->step();
  if (step != Step::kMechanismSelection && step != Step::kSelectAccount) {
    LightDismissGlassWebAuthnDialog(model);
    return false;
  }

  LightDismissGlassWebAuthnDialog(model);

  NSWindow* parentWindow =
      parent_widget && parent_widget->parent()
          ? parent_widget->parent()->GetNativeWindow().GetNativeNSWindow()
          : (NSApp.keyWindow ?: NSApp.mainWindow);

  struct RowSpec {
    NSString* title;
    NSString* subtitle;
    NSString* symbol;
    base::RepeatingClosure callback;
  };
  std::vector<RowSpec> rows;

  if (step == Step::kMechanismSelection) {
    for (const auto& mech : model->mechanisms) {
      NSString* title = base::SysUTF16ToNSString(mech.name);
      NSString* subtitle = base::SysUTF16ToNSString(mech.description);
      rows.push_back(
          {title, subtitle, SymbolForMechanism(mech), mech.callback});
    }
  } else {
    for (size_t i = 0; i < model->creds.size(); ++i) {
      const auto& cred = model->creds[i];
      NSString* title = base::SysUTF8ToNSString(
          cred.user.name.value_or(cred.user.display_name.value_or("Passkey")));
      NSString* subtitle = base::SysUTF16ToNSString(
          AuthenticatorRequestDialogModel::GetMechanismDescription(cred));
      rows.push_back(
          {title, subtitle, @"person.badge.key.fill",
           base::BindRepeating(&AuthenticatorRequestDialogModel::OnAccountSelected,
                               base::Unretained(model), i)});
    }
  }

  if (rows.empty()) {
    return false;
  }

  const CGFloat kWidth = 360.0;
  const CGFloat kPad = 18.0;
  const CGFloat kRowH = 46.0;
  const CGFloat kRowGap = 8.0;
  const CGFloat kHeaderH = 44.0;
  const CGFloat kBtnH = 30.0;

  CGFloat rowsH =
      rows.size() * kRowH + (rows.size() > 1 ? (rows.size() - 1) * kRowGap : 0);
  CGFloat totalH = kPad + kHeaderH + 14.0 + rowsH + 16.0 + kBtnH + kPad;

  NSRect frame = NSMakeRect(0, 0, kWidth, totalH);
  if (parentWindow) {
    NSRect pf = parentWindow.frame;
    frame.origin.x = std::floor(NSMidX(pf) - kWidth * 0.5);
    frame.origin.y = std::floor(NSMidY(pf) - totalH * 0.5 + 30.0);
  }

  LightGlassExtensionInstallPanel* panel =
      [[LightGlassExtensionInstallPanel alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskBorderless |
                               NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.hasShadow = YES;
  panel.level = NSModalPanelWindowLevel;
  panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  panel.releasedWhenClosed = NO;
  panel.autorecalculatesKeyViewLoop = NO;

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = kModalCornerRadius;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.layer.borderWidth = 0.0;
  panel.contentView = root;

  NSView* glass =
      MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH),
                              kModalCornerRadius, /*extraTintAlpha=*/0.035);
  panel.adaptiveGlassView = glass;
  panel.extraGlassTint = 0.035;
  [root addSubview:glass];

  NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [glass addSubview:content];

  CGFloat topY = totalH - kPad;

  // Compact SF Symbol badge (no Chromium SVG artwork).
  NSView* headerBadge =
      [[NSView alloc] initWithFrame:NSMakeRect(kPad, topY - 36.0, 36.0, 36.0)];
  headerBadge.wantsLayer = YES;
  headerBadge.layer.cornerRadius = 10.0;
  headerBadge.layer.cornerCurve = kCACornerCurveContinuous;
  headerBadge.layer.backgroundColor =
      [NSColor.controlAccentColor colorWithAlphaComponent:0.16].CGColor;
  [content addSubview:headerBadge];

  NSImageView* headerIcon =
      [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 36.0, 36.0)];
  NSImage* keyImg = [NSImage imageWithSystemSymbolName:@"person.badge.key.fill"
                              accessibilityDescription:nil];
  if (keyImg) {
    NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration
        configurationWithPointSize:17.0
                            weight:NSFontWeightMedium];
    headerIcon.image = [keyImg imageWithSymbolConfiguration:cfg];
  }
  headerIcon.contentTintColor = NSColor.controlAccentColor;
  headerIcon.imageScaling = NSImageScaleProportionallyDown;
  [headerBadge addSubview:headerIcon];

  NSString* rpHost = base::SysUTF8ToNSString(model->relying_party_id);
  NSTextField* titleField =
      [NSTextField labelWithString:@"Use a saved passkey"];
  titleField.font = [NSFont systemFontOfSize:14.5 weight:NSFontWeightSemibold];
  titleField.textColor = NSColor.labelColor;
  titleField.frame = NSMakeRect(kPad + 46.0, topY - 19.0, kWidth - kPad * 2.0 - 46.0, 19.0);
  [content addSubview:titleField];

  NSTextField* subField =
      [NSTextField labelWithString:(rpHost.length > 0 ? rpHost : @"Sign in")];
  subField.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
  subField.textColor = NSColor.secondaryLabelColor;
  subField.frame = NSMakeRect(kPad + 46.0, topY - 36.0, kWidth - kPad * 2.0 - 46.0, 16.0);
  [content addSubview:subField];

  CGFloat curY = topY - kHeaderH - 14.0;
  for (const auto& r : rows) {
    LightGlassOptionRowView* rowView =
        [[LightGlassOptionRowView alloc] initWithTitle:r.title
                                              subtitle:r.subtitle
                                                symbol:r.symbol];
    rowView.frame = NSMakeRect(kPad, curY - kRowH, kWidth - kPad * 2.0, kRowH);
    base::RepeatingClosure cb = r.callback;
    rowView.onClick = ^{
      if (cb) {
        cb.Run();
      }
    };
    [content addSubview:rowView];
    curY -= kRowH + kRowGap;
  }

  LightGlassPillButton* cancelBtn =
      [[LightGlassPillButton alloc] initWithTitle:@"Cancel" primary:NO];
  cancelBtn.frame = NSMakeRect(kPad, kPad, kWidth - kPad * 2.0, kBtnH);
  cancelBtn.onClick = ^{
    model->CancelAuthenticatorRequest();
  };
  [content addSubview:cancelBtn];

  panel.onCancel = ^{
    model->CancelAuthenticatorRequest();
  };

  WebAuthnPanels()[model] = panel;
  if (parentWindow) {
    [parentWindow addChildWindow:panel ordered:NSWindowAbove];
  }
  StripFocusRingsRecursively(panel.contentView);
  [panel installKeyMonitor];
  [panel orderFront:nil];
  return true;
}

void LightDismissGlassWebAuthnDialog(AuthenticatorRequestDialogModel* model) {
  if (!model) {
    return;
  }
  auto& map = WebAuthnPanels();
  auto it = map.find(model);
  if (it != map.end()) {
    LightGlassExtensionInstallPanel* panel = it->second;
    map.erase(it);
    if (panel) {
      if (panel.parentWindow) {
        [panel.parentWindow removeChildWindow:panel];
      }
      [panel orderOut:nil];
    }
  }
}

// -----------------------------------------------------------------------------
// Sidebar-Bound Extension Added ("<ext> has been added to Light") Popup
// -----------------------------------------------------------------------------
bool LightShowGlassExtensionPostInstallPopup(
    gfx::NativeWindow parent_window,
    const std::u16string& title,
    const std::vector<std::u16string>& paragraphs,
    const gfx::ImageSkia& icon,
    base::OnceClosure on_manage_shortcuts,
    base::OnceClosure on_closed) {
  NSWindow* parentWindow =
      parent_window ? parent_window.GetNativeNSWindow()
                    : (NSApp.keyWindow ?: NSApp.mainWindow);
  if (!parentWindow) {
    return false;
  }

  NSRect anchorRect = BeginSidebarExtensionPopup(parentWindow);

  NSString* titleText = base::SysUTF16ToNSString(title);
  NSImage* iconImage = !icon.isNull() ? gfx::NSImageFromImageSkia(icon) : nil;

  const CGFloat kWidth = 340.0;
  const CGFloat kPad = 16.0;
  CGFloat contentH = 40.0;  // header

  NSMutableArray<NSTextField*>* paraLabels = [NSMutableArray array];
  for (const auto& p : paragraphs) {
    if (p.empty()) {
      continue;
    }
    NSTextField* lbl =
        [NSTextField wrappingLabelWithString:base::SysUTF16ToNSString(p)];
    lbl.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
    lbl.textColor = NSColor.secondaryLabelColor;
    NSSize fit = [lbl sizeThatFits:NSMakeSize(kWidth - kPad * 2.0, 200.0)];
    lbl.frame = NSMakeRect(kPad, 0, kWidth - kPad * 2.0, std::ceil(fit.height));
    contentH += 10.0 + std::ceil(fit.height);
    [paraLabels addObject:lbl];
  }

  const CGFloat kBtnH = 30.0;
  const CGFloat totalH = kPad + contentH + 14.0 + kBtnH + kPad;
  NSRect frame = FrameAnchoredToSidebarRight(parentWindow, anchorRect, kWidth, totalH);

  LightGlassExtensionInstallPanel* panel =
      [[LightGlassExtensionInstallPanel alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskBorderless |
                               NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.hasShadow = YES;
  panel.level = NSFloatingWindowLevel;
  panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  panel.releasedWhenClosed = NO;
  panel.autorecalculatesKeyViewLoop = NO;
  panel.dismissOnOutsideClick = YES;

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = kModalCornerRadius;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.layer.borderWidth = 0.0;
  panel.contentView = root;

  NSView* glass = MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH),
                                          kModalCornerRadius, 0.035);
  panel.adaptiveGlassView = glass;
  panel.extraGlassTint = 0.035;
  [root addSubview:glass];

  NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [glass addSubview:content];

  CGFloat topY = totalH - kPad;

  NSImageView* iconView =
      [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, topY - 36.0, 36.0, 36.0)];
  iconView.wantsLayer = YES;
  iconView.layer.cornerRadius = 8.0;
  iconView.layer.cornerCurve = kCACornerCurveContinuous;
  iconView.layer.masksToBounds = YES;
  iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  iconView.image =
      iconImage ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension.fill"
                             accessibilityDescription:nil];
  [content addSubview:iconView];

  NSTextField* titleField =
      [NSTextField wrappingLabelWithString:(titleText.length > 0
                                                ? titleText
                                                : @"Extension added to Light")];
  titleField.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];
  titleField.textColor = NSColor.labelColor;
  NSSize titleFit =
      [titleField sizeThatFits:NSMakeSize(kWidth - kPad * 2.0 - 46.0, 60.0)];
  titleField.frame =
      NSMakeRect(kPad + 46.0, topY - 18.0 - std::ceil(titleFit.height) * 0.5,
                 kWidth - kPad * 2.0 - 46.0, std::ceil(titleFit.height));
  [content addSubview:titleField];

  CGFloat curY = topY - 40.0;
  for (NSTextField* lbl in paraLabels) {
    curY -= 10.0 + lbl.frame.size.height;
    lbl.frame = NSMakeRect(kPad, curY, kWidth - kPad * 2.0, lbl.frame.size.height);
    [content addSubview:lbl];
  }

  __block base::OnceClosure closedCb = std::move(on_closed);
  __block base::OnceClosure shortcutsCb = std::move(on_manage_shortcuts);
  __block BOOL finished = NO;
  __weak NSWindow* weakParent = parentWindow;

  auto dismiss = ^{
    if (finished) {
      return;
    }
    finished = YES;
    NSWindow* p = weakParent;
    if (p && panel.parentWindow == p) {
      [p removeChildWindow:panel];
    }
    [panel orderOut:nil];
    EndSidebarExtensionPopup(p);
    if (closedCb) {
      std::move(closedCb).Run();
    }
  };

  panel.onCancel = dismiss;
  panel.onAccept = dismiss;

  BOOL hasShortcuts = !shortcutsCb.is_null();
  if (hasShortcuts) {
    CGFloat btnW = (kWidth - kPad * 2.0 - 8.0) * 0.5;
    LightGlassPillButton* shortcutsBtn =
        [[LightGlassPillButton alloc] initWithTitle:@"Shortcuts" primary:NO];
    shortcutsBtn.frame = NSMakeRect(kPad, kPad, btnW, kBtnH);
    shortcutsBtn.onClick = ^{
      auto cb = std::move(shortcutsCb);
      dismiss();
      if (cb) {
        std::move(cb).Run();
      }
    };
    [content addSubview:shortcutsBtn];

    LightGlassPillButton* doneBtn =
        [[LightGlassPillButton alloc] initWithTitle:@"Done" primary:YES];
    doneBtn.frame = NSMakeRect(kPad + btnW + 8.0, kPad, btnW, kBtnH);
    doneBtn.onClick = dismiss;
    [content addSubview:doneBtn];
  } else {
    LightGlassPillButton* doneBtn =
        [[LightGlassPillButton alloc] initWithTitle:@"Done" primary:YES];
    doneBtn.frame = NSMakeRect(kPad, kPad, kWidth - kPad * 2.0, kBtnH);
    doneBtn.onClick = dismiss;
    [content addSubview:doneBtn];
  }

  [parentWindow addChildWindow:panel ordered:NSWindowAbove];
  StripFocusRingsRecursively(panel.contentView);
  [panel installKeyMonitor];
  [panel orderFront:nil];
  return true;
}

// -----------------------------------------------------------------------------
// Sidebar-Bound Remove Extension Popup
// -----------------------------------------------------------------------------
namespace {
struct UninstallPopupState {
  LightGlassExtensionInstallPanel* __strong panel = nil;
  NSWindow* __weak parentWindow = nil;
  base::OnceCallback<void(bool, bool)> on_result;
  BOOL finished = NO;
};

std::unordered_map<void*, std::unique_ptr<UninstallPopupState>>&
ActiveUninstallPopups() {
  static auto* map =
      new std::unordered_map<void*, std::unique_ptr<UninstallPopupState>>();
  return *map;
}

void FinishUninstallPopup(void* handle, bool accepted, bool checked) {
  auto& map = ActiveUninstallPopups();
  auto it = map.find(handle);
  if (it == map.end()) {
    return;
  }
  auto state = std::move(it->second);
  map.erase(it);
  if (!state || state->finished) {
    return;
  }
  state->finished = YES;
  NSWindow* p = state->parentWindow;
  if (p && state->panel && state->panel.parentWindow == p) {
    [p removeChildWindow:state->panel];
  }
  [state->panel orderOut:nil];
  EndSidebarExtensionPopup(p);
  if (state->on_result) {
    std::move(state->on_result).Run(accepted, checked);
  }
}
}  // namespace

void* LightShowGlassExtensionUninstallPopup(
    gfx::NativeWindow parent_window,
    const std::u16string& title,
    const std::u16string& subtitle,
    const std::u16string& checkbox_label,
    const gfx::ImageSkia& icon,
    base::OnceCallback<void(bool accepted, bool checkbox_checked)> on_result) {
  NSWindow* parentWindow =
      parent_window ? parent_window.GetNativeNSWindow()
                    : (NSApp.keyWindow ?: NSApp.mainWindow);
  if (!parentWindow) {
    return nullptr;
  }

  NSRect anchorRect = BeginSidebarExtensionPopup(parentWindow);

  const CGFloat kWidth = 340.0;
  const CGFloat kPad = 16.0;
  CGFloat bodyH = 40.0;

  NSTextField* subField = nil;
  if (!subtitle.empty()) {
    subField =
        [NSTextField wrappingLabelWithString:base::SysUTF16ToNSString(subtitle)];
    subField.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
    subField.textColor = NSColor.secondaryLabelColor;
    NSSize fit = [subField sizeThatFits:NSMakeSize(kWidth - kPad * 2.0, 120.0)];
    subField.frame =
        NSMakeRect(kPad, 0, kWidth - kPad * 2.0, std::ceil(fit.height));
    bodyH += 10.0 + std::ceil(fit.height);
  }

  NSButton* reportCheckbox = nil;
  if (!checkbox_label.empty()) {
    reportCheckbox = [NSButton
        checkboxWithTitle:base::SysUTF16ToNSString(checkbox_label)
                   target:nil
                   action:nil];
    reportCheckbox.font = [NSFont systemFontOfSize:12.5];
    reportCheckbox.state = NSControlStateValueOff;
    bodyH += 10.0 + 22.0;
  }

  const CGFloat kBtnH = 30.0;
  const CGFloat totalH = kPad + bodyH + 14.0 + kBtnH + kPad;
  NSRect frame =
      FrameAnchoredToSidebarRight(parentWindow, anchorRect, kWidth, totalH);

  LightGlassExtensionInstallPanel* panel =
      [[LightGlassExtensionInstallPanel alloc]
          initWithContentRect:frame
                    styleMask:(NSWindowStyleMaskBorderless |
                               NSWindowStyleMaskNonactivatingPanel)
                      backing:NSBackingStoreBuffered
                        defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.hasShadow = YES;
  panel.level = NSFloatingWindowLevel;
  panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  panel.releasedWhenClosed = NO;
  panel.autorecalculatesKeyViewLoop = NO;
  panel.dismissOnOutsideClick = YES;

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  root.wantsLayer = YES;
  root.layer.cornerRadius = kModalCornerRadius;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  root.layer.borderWidth = 0.0;
  panel.contentView = root;

  NSView* glass = MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH),
                                          kModalCornerRadius, 0.035);
  panel.adaptiveGlassView = glass;
  panel.extraGlassTint = 0.035;
  [root addSubview:glass];

  NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [glass addSubview:content];

  CGFloat topY = totalH - kPad;

  NSImage* iconImage = !icon.isNull() ? gfx::NSImageFromImageSkia(icon) : nil;
  NSImageView* iconView =
      [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, topY - 36.0, 36.0, 36.0)];
  iconView.wantsLayer = YES;
  iconView.layer.cornerRadius = 8.0;
  iconView.layer.cornerCurve = kCACornerCurveContinuous;
  iconView.layer.masksToBounds = YES;
  iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  iconView.image =
      iconImage ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension.fill"
                             accessibilityDescription:nil];
  [content addSubview:iconView];

  NSTextField* titleField =
      [NSTextField wrappingLabelWithString:base::SysUTF16ToNSString(title)];
  titleField.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];
  titleField.textColor = NSColor.labelColor;
  NSSize titleFit =
      [titleField sizeThatFits:NSMakeSize(kWidth - kPad * 2.0 - 46.0, 60.0)];
  titleField.frame =
      NSMakeRect(kPad + 46.0, topY - 18.0 - std::ceil(titleFit.height) * 0.5,
                 kWidth - kPad * 2.0 - 46.0, std::ceil(titleFit.height));
  [content addSubview:titleField];

  CGFloat curY = topY - 40.0;
  if (subField) {
    curY -= 10.0 + subField.frame.size.height;
    subField.frame =
        NSMakeRect(kPad, curY, kWidth - kPad * 2.0, subField.frame.size.height);
    [content addSubview:subField];
  }
  if (reportCheckbox) {
    curY -= 10.0 + 22.0;
    reportCheckbox.frame = NSMakeRect(kPad, curY, kWidth - kPad * 2.0, 22.0);
    [content addSubview:reportCheckbox];
  }

  auto state = std::make_unique<UninstallPopupState>();
  state->panel = panel;
  state->parentWindow = parentWindow;
  state->on_result = std::move(on_result);
  void* handle = state.get();
  ActiveUninstallPopups()[handle] = std::move(state);

  panel.onCancel = ^{
    FinishUninstallPopup(handle, /*accepted=*/false, /*checked=*/false);
  };
  panel.onAccept = ^{
    bool checked = reportCheckbox && reportCheckbox.state == NSControlStateValueOn;
    FinishUninstallPopup(handle, /*accepted=*/true, checked);
  };

  CGFloat btnW = (kWidth - kPad * 2.0 - 8.0) * 0.5;
  LightGlassPillButton* cancelBtn =
      [[LightGlassPillButton alloc] initWithTitle:@"Cancel" primary:NO];
  cancelBtn.frame = NSMakeRect(kPad, kPad, btnW, kBtnH);
  cancelBtn.onClick = ^{
    FinishUninstallPopup(handle, /*accepted=*/false, /*checked=*/false);
  };
  [content addSubview:cancelBtn];

  LightGlassPillButton* removeBtn =
      [[LightGlassPillButton alloc] initWithTitle:@"Remove" primary:YES];
  removeBtn.frame = NSMakeRect(kPad + btnW + 8.0, kPad, btnW, kBtnH);
  removeBtn.onClick = ^{
    bool checked = reportCheckbox && reportCheckbox.state == NSControlStateValueOn;
    FinishUninstallPopup(handle, /*accepted=*/true, checked);
  };
  [content addSubview:removeBtn];

  [parentWindow addChildWindow:panel ordered:NSWindowAbove];
  StripFocusRingsRecursively(panel.contentView);
  [panel installKeyMonitor];
  [panel orderFront:nil];
  return handle;
}

void LightCloseGlassExtensionUninstallPopup(void* handle) {
  if (!handle) {
    return;
  }
  FinishUninstallPopup(handle, /*accepted=*/false, /*checked=*/false);
}

// -----------------------------------------------------------------------------
// Native macOS Liquid Glass Site Permission Prompt
// -----------------------------------------------------------------------------
namespace {

NSString* SymbolForPermissionRequest(permissions::RequestType type) {
  switch (type) {
    case permissions::RequestType::kCameraStream:
    case permissions::RequestType::kCameraPanTiltZoom:
      return @"camera.fill";
    case permissions::RequestType::kMicStream:
      return @"mic.fill";
    case permissions::RequestType::kGeolocation:
      return @"location.fill";
    case permissions::RequestType::kNotifications:
      return @"bell.fill";
    case permissions::RequestType::kClipboard:
      return @"doc.on.clipboard.fill";
    default:
      return @"hand.raised.fill";
  }
}

class LightGlassPermissionPrompt : public permissions::PermissionPrompt {
 public:
  LightGlassPermissionPrompt(content::WebContents* web_contents,
                             Delegate* delegate)
      : web_contents_(web_contents), delegate_(delegate->GetWeakPtr()) {
    delegate->SetPromptShown();
    ShowPanel();
  }

  ~LightGlassPermissionPrompt() override { ClosePanel(); }

  bool UpdateAnchor() override {
    RepositionPanel();
    return true;
  }

  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return TabSwitchingBehavior::kDestroyPromptButKeepRequestPending;
  }

  permissions::PermissionPromptDisposition GetPromptDisposition()
      const override {
    return permissions::PermissionPromptDisposition::ANCHORED_BUBBLE;
  }

  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    return std::nullopt;
  }

  bool IsAskPrompt() const override { return true; }

  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants()
      const override {
    return {};
  }

  std::optional<permissions::feature_params::PermissionElementPromptPosition>
  GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  void RepositionPanel() {
    if (!panel_ || !parent_window_) {
      return;
    }
    NSRect pf = parent_window_.frame;
    NSSize sz = panel_.frame.size;
    CGFloat x = std::floor(NSMidX(pf) - sz.width * 0.5);
    CGFloat y = std::floor(NSMaxY(pf) - sz.height - 64.0);
    [panel_ setFrameOrigin:NSMakePoint(x, y)];
  }

  void ClosePanel() {
    if (!panel_) {
      return;
    }
    LightGlassExtensionInstallPanel* p = panel_;
    NSView* content = content_view_;
    NSWindow* parentWin = parent_window_;
    panel_ = nil;
    content_view_ = nil;
    parent_window_ = nil;
    p.onCancel = nil;
    p.onAccept = nil;
    [p removeKeyMonitor];

    // Animate out smoothly: 100% opacity & 0 blur -> faded & blurred (12pt).
    constexpr CGFloat kExitBlur = 12.0;
    constexpr CFTimeInterval kExitDur = 0.18;
    if (content && content.layer) {
      content.layerUsesCoreImageFilters = YES;
      if (id blur = MakeModalGaussianBlurFilter(0.0)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        content.layer.filters = @[ blur ];
        [CATransaction commit];
      }
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [content.layer setValue:@(kExitBlur)
                   forKeyPath:@"filters.permBlur.inputRadius"];
      CABasicAnimation* blurAnim = [CABasicAnimation
          animationWithKeyPath:@"filters.permBlur.inputRadius"];
      blurAnim.fromValue = @(0.0);
      blurAnim.toValue = @(kExitBlur);
      blurAnim.duration = kExitDur;
      blurAnim.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [content.layer addAnimation:blurAnim forKey:@"permExitBlur"];
      [CATransaction commit];
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = kExitDur;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      p.animator.alphaValue = 0.0;
    }
        completionHandler:^{
          if (parentWin && p.parentWindow == parentWin) {
            [parentWin removeChildWindow:p];
          }
          [p orderOut:nil];
        }];
  }

  void ShowPanel() {
    if (!web_contents_ || !delegate_ || delegate_->Requests().empty()) {
      return;
    }
    gfx::NativeWindow native_win = web_contents_->GetTopLevelNativeWindow();
    parent_window_ = native_win ? native_win.GetNativeNSWindow()
                                : (NSApp.keyWindow ?: NSApp.mainWindow);
    if (!parent_window_) {
      return;
    }

    const auto& requests = delegate_->Requests();
    NSString* symbolName =
        SymbolForPermissionRequest(requests.front()->request_type());

    std::u16string origin_text = url_formatter::FormatUrlForSecurityDisplay(
        delegate_->GetRequestingOrigin(),
        url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC);
    NSString* originStr = base::SysUTF16ToNSString(origin_text);
    NSString* heading =
        originStr.length > 0
            ? [NSString stringWithFormat:@"%@ wants to", originStr]
            : @"This site wants to";

    bool supports_one_time = true;
    NSMutableArray<NSString*>* items = [NSMutableArray array];
    NSString* requestingOriginSpec =
        base::SysUTF8ToNSString(delegate_->GetRequestingOrigin().spec());
    for (const auto& req : requests) {
      if (requestingOriginSpec.length > 0) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"LightPermissionAskedNotification"
                          object:nil
                        userInfo:@{
                          @"origin" : requestingOriginSpec,
                          @"type" : @(static_cast<int>(
                              req->GetContentSettingsType())),
                        }];
      }
      if (!permissions::PermissionUtil::DoesSupportTemporaryGrants(
              req->GetContentSettingsType())) {
        supports_one_time = false;
      }
      NSString* frag = base::SysUTF16ToNSString(req->GetMessageTextFragment());
      if (frag.length > 0) {
        [items addObject:frag];
      }
    }

    const CGFloat kWidth = 340.0;
    const CGFloat kPad = 18.0;
    CGFloat bodyH = 38.0;

    NSMutableArray<NSTextField*>* itemLabels = [NSMutableArray array];
    for (NSString* text in items) {
      NSString* line = items.count > 1
                           ? [NSString stringWithFormat:@"•  %@", text]
                           : text;
      NSTextField* lbl = [NSTextField wrappingLabelWithString:line];
      lbl.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
      lbl.textColor = NSColor.labelColor;
      NSSize fit = [lbl sizeThatFits:NSMakeSize(kWidth - kPad * 2.0, 120.0)];
      lbl.frame =
          NSMakeRect(kPad, 0, kWidth - kPad * 2.0, std::ceil(fit.height));
      bodyH += 8.0 + std::ceil(fit.height);
      [itemLabels addObject:lbl];
    }

    const CGFloat kBtnH = 30.0;
    const CGFloat kBtnGap = 8.0;
    const CGFloat buttonsH =
        supports_one_time ? (kBtnH * 2.0 + kBtnGap) : kBtnH;
    const CGFloat totalH = kPad + bodyH + 14.0 + buttonsH + kPad;

    NSRect pf = parent_window_.frame;
    NSRect frame = NSMakeRect(std::floor(NSMidX(pf) - kWidth * 0.5),
                              std::floor(NSMaxY(pf) - totalH - 64.0), kWidth,
                              totalH);

    LightGlassExtensionInstallPanel* panel =
        [[LightGlassExtensionInstallPanel alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskBorderless |
                                 NSWindowStyleMaskNonactivatingPanel)
                        backing:NSBackingStoreBuffered
                          defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    panel.releasedWhenClosed = NO;
    panel.autorecalculatesKeyViewLoop = NO;
    panel_ = panel;

    NSView* root =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
    root.wantsLayer = YES;
    root.layerUsesCoreImageFilters = YES;
    root.layer.cornerRadius = kModalCornerRadius;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.masksToBounds = YES;
    root.layer.borderWidth = 0.0;
    panel.contentView = root;

    NSView* glass = MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH),
                                            kModalCornerRadius, 0.035);
    panel.adaptiveGlassView = glass;
    panel.extraGlassTint = 0.035;
    [root addSubview:glass];

    NSView* content =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, totalH)];
    content.wantsLayer = YES;
    content.layerUsesCoreImageFilters = YES;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    content_view_ = content;
    [glass addSubview:content];

    CGFloat topY = totalH - kPad;

    NSView* iconBadge = [[NSView alloc]
        initWithFrame:NSMakeRect(kPad, topY - 32.0, 32.0, 32.0)];
    iconBadge.wantsLayer = YES;
    iconBadge.layer.cornerRadius = 9.0;
    iconBadge.layer.cornerCurve = kCACornerCurveContinuous;
    iconBadge.layer.backgroundColor =
        [NSColor.labelColor colorWithAlphaComponent:0.10].CGColor;
    [content addSubview:iconBadge];

    NSImageView* iconView =
        [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 32.0, 32.0)];
    NSImage* img = [NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:nil];
    if (img) {
      NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration
          configurationWithPointSize:14.5
                              weight:NSFontWeightMedium];
      iconView.image = [img imageWithSymbolConfiguration:cfg];
    }
    iconView.contentTintColor = NSColor.labelColor;
    iconView.imageScaling = NSImageScaleNone;
    iconView.imageAlignment = NSImageAlignCenter;
    [iconBadge addSubview:iconView];

    NSTextField* titleField = [NSTextField wrappingLabelWithString:heading];
    titleField.font =
        [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];
    titleField.textColor = NSColor.labelColor;
    NSSize titleFit =
        [titleField sizeThatFits:NSMakeSize(kWidth - kPad * 2.0 - 42.0, 44.0)];
    titleField.frame =
        NSMakeRect(kPad + 42.0, topY - 16.0 - std::ceil(titleFit.height) * 0.5,
                   kWidth - kPad * 2.0 - 42.0, std::ceil(titleFit.height));
    [content addSubview:titleField];

    CGFloat curY = topY - 38.0;
    for (NSTextField* lbl in itemLabels) {
      curY -= 8.0 + lbl.frame.size.height;
      lbl.frame =
          NSMakeRect(kPad, curY, kWidth - kPad * 2.0, lbl.frame.size.height);
      [content addSubview:lbl];
    }

    base::WeakPtr<Delegate> weak_delegate = delegate_;
    auto invokeAction = ^(int action) {
      if (!weak_delegate) {
        return;
      }
      PromptOptions opts = std::monostate();
      if (action == 1) {
        weak_delegate->Accept(opts);
      } else if (action == 2) {
        weak_delegate->AcceptThisTime(opts);
      } else if (action == 3) {
        weak_delegate->Deny(opts);
      } else {
        weak_delegate->Dismiss(opts);
      }
    };

    panel.onCancel = ^{
      invokeAction(0);
    };
    panel.onAccept = ^{
      invokeAction(1);
    };

    if (supports_one_time) {
      CGFloat halfW = (kWidth - kPad * 2.0 - kBtnGap) * 0.5;
      LightGlassPillButton* denyBtn =
          [[LightGlassPillButton alloc] initWithTitle:@"Don't allow" primary:NO];
      denyBtn.frame = NSMakeRect(kPad, kPad, halfW, kBtnH);
      denyBtn.onClick = ^{
        invokeAction(3);
      };
      [content addSubview:denyBtn];

      LightGlassPillButton* onceBtn =
          [[LightGlassPillButton alloc] initWithTitle:@"Allow this time"
                                              primary:NO];
      onceBtn.frame = NSMakeRect(kPad + halfW + kBtnGap, kPad, halfW, kBtnH);
      onceBtn.onClick = ^{
        invokeAction(2);
      };
      [content addSubview:onceBtn];

      LightGlassPillButton* allowBtn =
          [[LightGlassPillButton alloc] initWithTitle:@"Allow while visiting"
                                              primary:YES];
      allowBtn.frame =
          NSMakeRect(kPad, kPad + kBtnH + kBtnGap, kWidth - kPad * 2.0, kBtnH);
      allowBtn.onClick = ^{
        invokeAction(1);
      };
      [content addSubview:allowBtn];
    } else {
      CGFloat halfW = (kWidth - kPad * 2.0 - kBtnGap) * 0.5;
      LightGlassPillButton* denyBtn =
          [[LightGlassPillButton alloc] initWithTitle:@"Don't allow" primary:NO];
      denyBtn.frame = NSMakeRect(kPad, kPad, halfW, kBtnH);
      denyBtn.onClick = ^{
        invokeAction(3);
      };
      [content addSubview:denyBtn];

      LightGlassPillButton* allowBtn =
          [[LightGlassPillButton alloc] initWithTitle:@"Allow" primary:YES];
      allowBtn.frame = NSMakeRect(kPad + halfW + kBtnGap, kPad, halfW, kBtnH);
      allowBtn.onClick = ^{
        invokeAction(1);
      };
      [content addSubview:allowBtn];
    }

    [parent_window_ addChildWindow:panel ordered:NSWindowAbove];
    StripFocusRingsRecursively(panel.contentView);
    [panel installKeyMonitor];

    // Animate in smoothly: start blurred (12pt) at 75% opacity -> crisp 100%.
    constexpr CGFloat kEnterBlur = 12.0;
    constexpr CFTimeInterval kEnterDur = 0.22;
    panel.alphaValue = 0.75;
    if (content.layer) {
      if (id blur = MakeModalGaussianBlurFilter(kEnterBlur)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        content.layer.filters = @[ blur ];
        [CATransaction commit];
      }
    }
    [panel orderFront:nil];

    if (content.layer) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [CATransaction setCompletionBlock:^{
        // Detach CoreImage filter at rest so text remains razor sharp.
        content.layer.filters = nil;
      }];
      [content.layer setValue:@(0.0)
                   forKeyPath:@"filters.permBlur.inputRadius"];
      CABasicAnimation* blurAnim = [CABasicAnimation
          animationWithKeyPath:@"filters.permBlur.inputRadius"];
      blurAnim.fromValue = @(kEnterBlur);
      blurAnim.toValue = @(0.0);
      blurAnim.duration = kEnterDur;
      blurAnim.timingFunction = [CAMediaTimingFunction
          functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      [content.layer addAnimation:blurAnim forKey:@"permEnterBlur"];
      [CATransaction commit];
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = kEnterDur;
      ctx.timingFunction =
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
      panel.animator.alphaValue = 1.0;
    }
                        completionHandler:nil];
  }

  raw_ptr<content::WebContents> web_contents_;
  base::WeakPtr<Delegate> delegate_;
  NSWindow* __weak parent_window_ = nil;
  NSView* __strong content_view_ = nil;
  LightGlassExtensionInstallPanel* __strong panel_ = nil;
};

}  // namespace

std::unique_ptr<permissions::PermissionPrompt> LightCreateGlassPermissionPrompt(
    content::WebContents* web_contents,
    permissions::PermissionPrompt::Delegate* delegate) {
  if (!web_contents || !delegate || delegate->Requests().empty()) {
    return nullptr;
  }
  return std::make_unique<LightGlassPermissionPrompt>(web_contents, delegate);
}
