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

#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/webauthn/authenticator_request_dialog_model.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia_util_mac.h"
#include "ui/views/bubble/bubble_frame_view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/non_client_view.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

NSView* MakeLiquidGlassBackdrop(NSRect bounds, CGFloat cornerRadius) {
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:bounds];
    glass.wantsLayer = YES;
    glass.style = NSGlassEffectViewStyleRegular;
    glass.cornerRadius = cornerRadius;
    glass.tintColor = [NSColor colorWithWhite:1.0 alpha:0.06];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
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
  vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return vfx;
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
    self.layer.cornerRadius = 15.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;

    _label = [NSTextField labelWithString:title];
    _label.font = [NSFont systemFontOfSize:13.0
                                    weight:(primary ? NSFontWeightSemibold
                                                    : NSFontWeightMedium)];
    _label.alignment = NSTextAlignmentCenter;
    _label.textColor = primary ? NSColor.whiteColor : NSColor.labelColor;
    _label.focusRingType = NSFocusRingTypeNone;
    [self addSubview:_label];
    [self updateAppearance];
  }
  return self;
}

- (void)updateAppearance {
  if (_primary) {
    NSColor* accent = NSColor.controlAccentColor;
    CGFloat alpha = _pressed ? 0.80 : (_hovered ? 0.92 : 1.0);
    self.layer.backgroundColor = [accent colorWithAlphaComponent:alpha].CGColor;
    self.layer.borderWidth = 0.0;
  } else {
    CGFloat alpha = _pressed ? 0.22 : (_hovered ? 0.16 : 0.10);
    self.layer.backgroundColor =
        [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
    self.layer.borderColor =
        [NSColor.labelColor colorWithAlphaComponent:0.14].CGColor;
    self.layer.borderWidth = 0.5;
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
- (void)installKeyMonitor;
- (void)removeKeyMonitor;
@end

@implementation LightGlassExtensionInstallPanel {
  id __strong _keyMonitor;
}
@synthesize onCancel = _onCancel;
@synthesize onAccept = _onAccept;

- (BOOL)canBecomeKeyWindow {
  return NO;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

- (void)installKeyMonitor {
  if (_keyMonitor) {
    return;
  }
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

- (void)removeKeyMonitor {
  if (_keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
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
  root.layer.cornerRadius = 20.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  panel.contentView = root;

  NSView* glass = MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH), 20.0);
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
  root.layer.cornerRadius = 20.0;
  root.layer.cornerCurve = kCACornerCurveContinuous;
  root.layer.masksToBounds = YES;
  panel.contentView = root;

  NSView* glass = MakeLiquidGlassBackdrop(NSMakeRect(0, 0, kWidth, totalH), 20.0);
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
