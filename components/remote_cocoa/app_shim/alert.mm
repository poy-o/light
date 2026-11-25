// Copyright 2019 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/remote_cocoa/app_shim/alert.h"

#import "base/apple/foundation_util.h"
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>
#include "base/functional/bind.h"
#include "base/i18n/rtl.h"
#include "base/memory/raw_ptr_exclusion.h"
#include "base/strings/sys_string_conversions.h"
#include "ui/accelerated_widget_mac/window_resize_helper_mac.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/gfx/text_elider.h"

using remote_cocoa::mojom::AlertBridgeInitParams;
using remote_cocoa::mojom::AlertDisposition;

namespace {

const int kSlotsPerLine = 50;
const int kMessageTextMaxSlots = 2000;

void ApplyAdaptiveLightGlass(NSView* view) {
  if (@available(macOS 26.0, *)) {
    if (![view isKindOfClass:[NSGlassEffectView class]]) {
      return;
    }
    NSGlassEffectView* glass = (NSGlassEffectView*)view;
    NSUserDefaults* ud = NSUserDefaults.standardUserDefaults;
    NSInteger styleIdx =
        [ud objectForKey:@"LightSidebarGlassStyle"]
            ? std::clamp<NSInteger>([ud integerForKey:@"LightSidebarGlassStyle"],
                                    0, 1)
            : 0;
    glass.style = (styleIdx == 1) ? NSGlassEffectViewStyleClear
                                  : NSGlassEffectViewStyleRegular;
    NSInteger adaptiveVal =
        [ud objectForKey:@"LightSidebarGlassAdaptive"]
            ? std::clamp<NSInteger>(
                  [ud integerForKey:@"LightSidebarGlassAdaptive"], 0, 2)
            : 2;
    SEL adaptiveSel = NSSelectorFromString(@"set_adaptiveAppearance:");
    if ([glass respondsToSelector:adaptiveSel]) {
      [glass setValue:@(adaptiveVal) forKey:@"_adaptiveAppearance"];
    }
    if (@available(macOS 27.0, *)) {
      BOOL interactive =
          [ud objectForKey:@"LightSidebarGlassInteractive"]
              ? [ud boolForKey:@"LightSidebarGlassInteractive"]
              : YES;
      glass.effectIsInteractive = interactive;
    }
    CGFloat tintPct =
        [ud objectForKey:@"LightSidebarTintAlpha"]
            ? std::clamp<CGFloat>([ud doubleForKey:@"LightSidebarTintAlpha"],
                                  0.0, 100.0)
            : 4.0;
    CGFloat tr = [ud objectForKey:@"LightSidebarTintR"]
                     ? std::clamp<CGFloat>([ud doubleForKey:@"LightSidebarTintR"],
                                           0.0, 1.0)
                     : 1.0;
    CGFloat tg = [ud objectForKey:@"LightSidebarTintG"]
                     ? std::clamp<CGFloat>([ud doubleForKey:@"LightSidebarTintG"],
                                           0.0, 1.0)
                     : 1.0;
    CGFloat tb = [ud objectForKey:@"LightSidebarTintB"]
                     ? std::clamp<CGFloat>([ud doubleForKey:@"LightSidebarTintB"],
                                           0.0, 1.0)
                     : 1.0;
    CGFloat alpha = std::clamp<CGFloat>((tintPct / 100.0) + 0.03, 0.0, 0.90);
    glass.tintColor =
        [NSColor colorWithSRGBRed:tr green:tg blue:tb alpha:alpha];
  }
}

}  // namespace

@interface LightAlertGlassPanel : NSPanel
@property(nonatomic, copy) void (^onEscape)(void);
@property(nonatomic, copy) void (^onReturn)(void);
@end

@implementation LightAlertGlassPanel
@synthesize onEscape = _onEscape;
@synthesize onReturn = _onReturn;

- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
- (void)cancelOperation:(id)sender {
  if (_onEscape) {
    _onEscape();
  }
}
- (void)keyDown:(NSEvent*)event {
  if (event.keyCode == 53 && _onEscape) {  // Escape
    _onEscape();
    return;
  }
  if ((event.keyCode == 36 || event.keyCode == 76) && _onReturn) {  // Return
    _onReturn();
    return;
  }
  [super keyDown:event];
}
@end

@interface LightAlertPillButton : NSView
@property(nonatomic, copy) NSString* title;
@property(nonatomic, assign) BOOL primary;
@property(nonatomic, copy) void (^actionBlock)(void);
@end

@implementation LightAlertPillButton {
  NSTextField* __strong _label;
  NSTrackingArea* __strong _tracking;
  BOOL _hovered;
  BOOL _pressed;
}
@synthesize title = _title;
@synthesize primary = _primary;
@synthesize actionBlock = _actionBlock;

- (instancetype)initWithTitle:(NSString*)title primary:(BOOL)primary {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _title = [title copy];
    _primary = primary;
    self.wantsLayer = YES;
    _label = [NSTextField labelWithString:title ?: @""];
    _label.alignment = NSTextAlignmentCenter;
    _label.font = [NSFont systemFontOfSize:13.0
                                    weight:primary ? NSFontWeightSemibold
                                                   : NSFontWeightMedium];
    _label.textColor = primary ? NSColor.blackColor : NSColor.labelColor;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_label];
  }
  return self;
}
- (void)layout {
  [super layout];
  NSSize fit = [_label sizeThatFits:self.bounds.size];
  CGFloat h = std::ceil(fit.height);
  _label.frame = NSMakeRect(10.0, std::floor((self.bounds.size.height - h) * 0.5),
                            std::max<CGFloat>(0.0, self.bounds.size.width - 20.0),
                            h);
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) {
    [self removeTrackingArea:_tracking];
  }
  _tracking = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
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
  BOOL inside = NSPointInRect([self convertPoint:event.locationInWindow
                                        fromView:nil],
                              self.bounds);
  _pressed = NO;
  [self setNeedsDisplay:YES];
  if (inside && _actionBlock) {
    _actionBlock();
  }
}
- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:9.0
                                                       yRadius:9.0];
  if (_primary) {
    CGFloat a = _pressed ? 0.80 : (_hovered ? 0.92 : 0.98);
    [[NSColor colorWithWhite:1.0 alpha:a] setFill];
  } else {
    CGFloat a = _pressed ? 0.22 : (_hovered ? 0.16 : 0.11);
    [[NSColor.labelColor colorWithAlphaComponent:a] setFill];
  }
  [path fill];
}
@end

////////////////////////////////////////////////////////////////////////////////
// AlertBridgeHelper:

// Helper object that receives the notification that the dialog/sheet is
// going away. Is responsible for cleaning itself up.
@interface AlertBridgeHelper : NSObject <NSAlertDelegate> {
 @private
  NSAlert* __strong _alert;
  LightAlertGlassPanel* __strong _glassPanel;
  NSButton* __strong _glassSuppressionButton;
  BOOL _resolved;
  // This field is not a raw_ptr<> because it requires @property rewrite.
  RAW_PTR_EXCLUSION remote_cocoa::AlertBridge* _alertBridge;  // Weak.
  NSTextField* __strong _textField;
}
@property(assign, nonatomic) remote_cocoa::AlertBridge* alertBridge;

// Returns the underlying alert.
- (NSAlert*)alert;

// Add a text field to the alert.
- (void)addTextFieldWithPrompt:(NSString*)prompt;

// Presents an AppKit blocking dialog.
- (void)showAlert;
@end

@implementation AlertBridgeHelper
@synthesize alertBridge = _alertBridge;

- (void)initAlert:(AlertBridgeInitParams*)params {
  NSString* informative_text = base::SysUTF16ToNSString(params->message_text);

  // Truncate long JS alerts - crbug.com/331219
  NSCharacterSet* newline_char_set = [NSCharacterSet newlineCharacterSet];
  for (size_t index = 0, slots_count = 0; index < informative_text.length;
       ++index) {
    unichar current_char = [informative_text characterAtIndex:index];
    if ([newline_char_set characterIsMember:current_char])
      slots_count += kSlotsPerLine;
    else
      slots_count++;
    if (slots_count > kMessageTextMaxSlots) {
      std::u16string info_text = base::SysNSStringToUTF16(informative_text);
      informative_text = base::SysUTF16ToNSString(
          gfx::TruncateString(info_text, index, gfx::WORD_BREAK));
      break;
    }
  }

  NSString* message_text = l10n_util::FixUpWindowsStyleLabel(params->title);
  NSString* primary_title =
      l10n_util::FixUpWindowsStyleLabel(params->primary_button_text);
  NSString* secondary_title =
      params->secondary_button_text
          ? l10n_util::FixUpWindowsStyleLabel(*params->secondary_button_text)
          : nil;
  NSString* checkbox_title =
      params->check_box_text
          ? l10n_util::FixUpWindowsStyleLabel(*params->check_box_text)
          : nil;
  NSString* prompt_text =
      params->text_field_text
          ? base::SysUTF16ToNSString(*params->text_field_text)
          : nil;

  if (@available(macOS 26.0, *)) {
    constexpr CGFloat kW = 360.0;
    constexpr CGFloat kPad = 20.0;
    constexpr CGFloat kInnerW = kW - kPad * 2.0;

    NSTextField* titleLbl = [NSTextField wrappingLabelWithString:message_text ?: @""];
    titleLbl.font = [NSFont systemFontOfSize:14.5 weight:NSFontWeightSemibold];
    titleLbl.textColor = NSColor.labelColor;
    CGFloat titleH =
        message_text.length > 0
            ? std::ceil([titleLbl sizeThatFits:NSMakeSize(kInnerW, 200.0)].height)
            : 0.0;

    NSTextField* bodyLbl = nil;
    CGFloat bodyH = 0.0;
    if (informative_text.length > 0) {
      bodyLbl = [NSTextField wrappingLabelWithString:informative_text];
      bodyLbl.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
      bodyLbl.textColor = NSColor.secondaryLabelColor;
      bodyH = std::min<CGFloat>(
          220.0,
          std::ceil([bodyLbl sizeThatFits:NSMakeSize(kInnerW, 300.0)].height));
    }

    CGFloat promptH = prompt_text ? 28.0 : 0.0;
    CGFloat checkH = checkbox_title ? 22.0 : 0.0;
    constexpr CGFloat kBtnH = 32.0;

    CGFloat totalH = kPad;
    if (titleH > 0) totalH += titleH + 8.0;
    if (bodyH > 0) totalH += bodyH + 14.0;
    if (promptH > 0) totalH += promptH + 12.0;
    if (checkH > 0) totalH += checkH + 12.0;
    totalH += kBtnH + kPad;

    _glassPanel = [[LightAlertGlassPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, kW, totalH)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _glassPanel.opaque = NO;
    _glassPanel.backgroundColor = [NSColor clearColor];
    _glassPanel.hasShadow = YES;
    _glassPanel.level = NSModalPanelWindowLevel;
    _glassPanel.releasedWhenClosed = NO;

    NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, totalH)];
    root.wantsLayer = YES;
    root.layer.cornerRadius = 15.0;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.masksToBounds = YES;
    _glassPanel.contentView = root;

    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:root.bounds];
    glass.wantsLayer = YES;
    glass.cornerRadius = 15.0;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    ApplyAdaptiveLightGlass(glass);
    [root addSubview:glass];

    NSView* content = [[NSView alloc] initWithFrame:root.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.contentView = content;

    CGFloat y = totalH - kPad;
    if (titleH > 0) {
      y -= titleH;
      titleLbl.frame = NSMakeRect(kPad, y, kInnerW, titleH);
      [content addSubview:titleLbl];
      y -= 8.0;
    }
    if (bodyLbl && bodyH > 0) {
      y -= bodyH;
      bodyLbl.frame = NSMakeRect(kPad, y, kInnerW, bodyH);
      [content addSubview:bodyLbl];
      y -= 14.0;
    }
    if (prompt_text) {
      y -= promptH;
      _textField = [[NSTextField alloc] initWithFrame:NSMakeRect(kPad, y, kInnerW, promptH)];
      _textField.stringValue = prompt_text;
      _textField.font = [NSFont systemFontOfSize:13.0];
      _textField.bezeled = NO;
      _textField.bordered = NO;
      _textField.drawsBackground = YES;
      _textField.backgroundColor =
          [NSColor.labelColor colorWithAlphaComponent:0.08];
      _textField.focusRingType = NSFocusRingTypeNone;
      _textField.wantsLayer = YES;
      _textField.layer.cornerRadius = 7.0;
      _textField.cell.lineBreakMode = NSLineBreakByTruncatingTail;
      [content addSubview:_textField];
      _glassPanel.initialFirstResponder = _textField;
      y -= 12.0;
    }
    if (checkbox_title) {
      y -= checkH;
      _glassSuppressionButton =
          [NSButton checkboxWithTitle:checkbox_title target:nil action:nil];
      _glassSuppressionButton.font = [NSFont systemFontOfSize:12.0];
      _glassSuppressionButton.frame = NSMakeRect(kPad, y, kInnerW, checkH);
      [content addSubview:_glassSuppressionButton];
      y -= 12.0;
    }

    __weak __typeof(self) weakSelf = self;
    CGFloat btnY = kPad;
    if (secondary_title) {
      CGFloat btnW = std::floor((kInnerW - 10.0) * 0.5);
      LightAlertPillButton* secBtn =
          [[LightAlertPillButton alloc] initWithTitle:secondary_title primary:NO];
      secBtn.frame = NSMakeRect(kPad, btnY, btnW, kBtnH);
      secBtn.actionBlock = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::SECONDARY_BUTTON];
      };
      [content addSubview:secBtn];

      LightAlertPillButton* priBtn =
          [[LightAlertPillButton alloc] initWithTitle:primary_title primary:YES];
      priBtn.frame = NSMakeRect(kPad + btnW + 10.0, btnY, btnW, kBtnH);
      priBtn.actionBlock = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::PRIMARY_BUTTON];
      };
      [content addSubview:priBtn];

      _glassPanel.onEscape = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::SECONDARY_BUTTON];
      };
      _glassPanel.onReturn = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::PRIMARY_BUTTON];
      };
    } else {
      LightAlertPillButton* priBtn =
          [[LightAlertPillButton alloc] initWithTitle:primary_title primary:YES];
      priBtn.frame = NSMakeRect(kPad, btnY, kInnerW, kBtnH);
      priBtn.actionBlock = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::PRIMARY_BUTTON];
      };
      [content addSubview:priBtn];

      _glassPanel.onEscape = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::PRIMARY_BUTTON];
      };
      _glassPanel.onReturn = ^{
        [weakSelf finishGlassAlertWithDisposition:AlertDisposition::PRIMARY_BUTTON];
      };
    }
    return;
  }

  _alert = [[NSAlert alloc] init];
  _alert.delegate = self;

  if (prompt_text) {
    [self addTextFieldWithPrompt:prompt_text];
  }
  _alert.informativeText = informative_text;
  _alert.messageText = message_text;
  [_alert addButtonWithTitle:primary_title];

  if (secondary_title) {
    NSButton* other = [_alert addButtonWithTitle:secondary_title];
    other.keyEquivalent = @"\e";
  }
  if (checkbox_title) {
    _alert.showsSuppressionButton = YES;
    [_alert.suppressionButton setTitle:checkbox_title];
  }

  // Fix RTL dialogs.
  //
  // macOS will always display NSAlert strings as LTR. A workaround is to
  // manually set the text as attributed strings in the implementing
  // NSTextFields. This is a basic correctness issue.
  //
  // In addition, for readability, the overall alignment is set based on the
  // directionality of the first strongly-directional character.
  //
  // If the dialog fields are selectable then they will scramble when clicked.
  // Therefore, selectability is disabled.
  //
  // See http://crbug.com/70806 for more details.

  bool message_has_rtl =
      base::i18n::StringContainsStrongRTLChars(params->title);
  bool informative_has_rtl =
      base::i18n::StringContainsStrongRTLChars(params->message_text);

  NSTextField* message_text_field = nil;
  NSTextField* informative_text_field = nil;
  if (message_has_rtl || informative_has_rtl) {
    // Force layout of the dialog. NSAlert leaves its dialog alone once laid
    // out; if this is not done then all the modifications that are to come will
    // be un-done when the dialog is finally displayed.
    [_alert layout];

    // Locate the NSTextFields that implement the text display. These are
    // actually available as the ivars |_messageField| and |_informationField|
    // of the NSAlert, but it is safer (and more forward-compatible) to search
    // for them in the subviews.
    for (NSView* view in _alert.window.contentView.subviews) {
      NSTextField* text_field = base::apple::ObjCCast<NSTextField>(view);
      if ([text_field.stringValue isEqualTo:message_text]) {
        message_text_field = text_field;
      } else if ([text_field.stringValue isEqualTo:informative_text]) {
        informative_text_field = text_field;
      }
    }

    // This may fail in future OS releases, but it will still work for shipped
    // versions of Chromium.
    DCHECK(message_text_field);
    DCHECK(informative_text_field);
  }

  if (message_has_rtl && message_text_field) {
    NSMutableParagraphStyle* alignment =
        [NSParagraphStyle.defaultParagraphStyle mutableCopy];
    alignment.alignment = NSTextAlignmentRight;

    NSDictionary* alignment_attributes =
        @{NSParagraphStyleAttributeName : alignment};
    NSAttributedString* attr_string =
        [[NSAttributedString alloc] initWithString:message_text
                                        attributes:alignment_attributes];

    message_text_field.attributedStringValue = attr_string;
    message_text_field.selectable = NO;
  }

  if (informative_has_rtl && informative_text_field) {
    base::i18n::TextDirection direction =
        base::i18n::GetFirstStrongCharacterDirection(params->message_text);
    NSMutableParagraphStyle* alignment =
        [NSParagraphStyle.defaultParagraphStyle mutableCopy];
    alignment.alignment = direction == base::i18n::RIGHT_TO_LEFT
                              ? NSTextAlignmentRight
                              : NSTextAlignmentLeft;

    NSDictionary* alignment_attributes =
        @{NSParagraphStyleAttributeName : alignment};
    NSAttributedString* attr_string =
        [[NSAttributedString alloc] initWithString:informative_text
                                        attributes:alignment_attributes];

    informative_text_field.attributedStringValue = attr_string;
    informative_text_field.selectable = NO;
  }
}

- (NSAlert*)alert {
  return _alert;
}

- (void)addTextFieldWithPrompt:(NSString*)prompt {
  DCHECK(!_textField);
  _textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
  _textField.cell.lineBreakMode = NSLineBreakByTruncatingTail;
  self.alert.accessoryView = _textField;
  _alert.window.initialFirstResponder = _textField;

  [_textField setStringValue:prompt];
}

// |contextInfo| is the JavaScriptAppModalDialogCocoa that owns us.
- (void)alertDidEnd:(NSAlert*)alert
         returnCode:(int)returnCode
        contextInfo:(void*)contextInfo {
  switch (returnCode) {
    case NSAlertFirstButtonReturn:  // OK
      _alertBridge->SendResultAndDestroy(AlertDisposition::PRIMARY_BUTTON);
      break;
    case NSAlertSecondButtonReturn:  // Cancel
      _alertBridge->SendResultAndDestroy(AlertDisposition::SECONDARY_BUTTON);
      break;
    case NSModalResponseStop:  // Window was closed underneath us
      _alertBridge->SendResultAndDestroy(AlertDisposition::CLOSE);
      break;
    default:
      NOTREACHED();
  }
}

- (void)finishGlassAlertWithDisposition:(AlertDisposition)disposition {
  if (_resolved) {
    return;
  }
  _resolved = YES;
  if (_glassPanel) {
    NSWindow* parent = _glassPanel.parentWindow;
    if (parent) {
      [parent removeChildWindow:_glassPanel];
    }
    [_glassPanel orderOut:nil];
  }
  if (_alertBridge) {
    _alertBridge->SendResultAndDestroy(disposition);
  }
}

- (void)showAlert {
  DCHECK(_alertBridge);
  _alertBridge->SetAlertHasShown();
  if (_glassPanel) {
    NSWindow* parent = NSApp.keyWindow ?: NSApp.mainWindow;
    NSRect ref = parent ? parent.frame : NSScreen.mainScreen.visibleFrame;
    NSSize sz = _glassPanel.frame.size;
    NSPoint origin = NSMakePoint(
        std::floor(NSMidX(ref) - sz.width * 0.5),
        std::floor(NSMidY(ref) - sz.height * 0.5 + 24.0));
    [_glassPanel setFrameOrigin:origin];
    if (parent && parent != _glassPanel) {
      [parent addChildWindow:_glassPanel ordered:NSWindowAbove];
    }
    [_glassPanel makeKeyAndOrderFront:nil];
    if (_textField) {
      [_glassPanel makeFirstResponder:_textField];
    }
    return;
  }
  NSAlert* alert = [self alert];
  [alert layout];
  [alert.window recalculateKeyViewLoop];
  // TODO(crbug.com/40575730): Migrate to `[NSWindow
  // beginSheetModalForWindow:completionHandler:]` instead.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [alert beginSheetModalForWindow:nil  // nil here makes it app-modal
                    modalDelegate:self
                   didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                      contextInfo:nullptr];
#pragma clang diagnostic pop
}

- (void)closeWindow {
  DCHECK(_alertBridge);
  if (_glassPanel) {
    [self finishGlassAlertWithDisposition:AlertDisposition::CLOSE];
    return;
  }
  [NSApp endSheet:self.alert.window];
}

- (std::u16string)input {
  if (_textField)
    return base::SysNSStringToUTF16(_textField.stringValue);
  return std::u16string();
}

- (bool)shouldSuppress {
  if (_glassSuppressionButton) {
    return _glassSuppressionButton.state == NSControlStateValueOn;
  }
  if ([[self alert] showsSuppressionButton])
    return [[[self alert] suppressionButton] state] == NSControlStateValueOn;
  return false;
}

@end

namespace remote_cocoa {

////////////////////////////////////////////////////////////////////////////////
// AlertBridge:

AlertBridge::AlertBridge(
    mojo::PendingReceiver<mojom::AlertBridge> bridge_receiver)
    : weak_factory_(this) {
  if (bridge_receiver.is_valid()) {
    mojo_receiver_.Bind(std::move(bridge_receiver),
                        ui::WindowResizeHelperMac::Get()->task_runner());
    mojo_receiver_.set_disconnect_handler(base::BindOnce(
        &AlertBridge::OnMojoDisconnect, weak_factory_.GetWeakPtr()));
  }
}

AlertBridge::~AlertBridge() {
  helper_.alertBridge = nil;
  [NSObject cancelPreviousPerformRequestsWithTarget:helper_];
}

void AlertBridge::OnMojoDisconnect() {
  // If the alert has been shown, then close the window, and |this| will delete
  // itself after the window is closed. Otherwise, just delete |this|
  // immediately.
  if (alert_shown_)
    [helper_ closeWindow];
  else
    delete this;
}

void AlertBridge::SendResultAndDestroy(AlertDisposition disposition) {
  if (!alert_dismissed_) {
    DCHECK(callback_);
    std::move(callback_).Run(disposition, [helper_ input],
                             [helper_ shouldSuppress]);
  }
  delete this;
}

void AlertBridge::SetAlertHasShown() {
  DCHECK(!alert_shown_);
  alert_shown_ = true;
}

////////////////////////////////////////////////////////////////////////////////
// AlertBridge, mojo::AlertBridge:

void AlertBridge::Show(mojom::AlertBridgeInitParamsPtr params,
                       ShowCallback callback) {
  callback_ = std::move(callback);

  // Create a helper which will receive the sheet ended selector.
  helper_ = [[AlertBridgeHelper alloc] init];
  helper_.alertBridge = this;
  [helper_ initAlert:params.get()];

  // Dispatch the method to show the alert back to the top of the CFRunLoop.
  // This fixes an interaction bug with NSSavePanel. http://crbug.com/375785
  // When this object is destroyed, outstanding performSelector: requests
  // should be cancelled.
  [helper_ performSelector:@selector(showAlert) withObject:nil afterDelay:0];
}

void AlertBridge::Dismiss() {
  alert_dismissed_ = true;
  OnMojoDisconnect();
}

}  // namespace remote_cocoa
