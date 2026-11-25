// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/views/frame/light_extensions_manager_controller.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/extension_icon_image.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_constants.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/manifest_handlers/manifest_url_handlers.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "extensions/common/permissions/permission_message.h"
#include "extensions/common/permissions/permissions_data.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

bool IsExtDarkAppearance(NSView* view) {
  NSAppearance* app = view ? view.effectiveAppearance : NSApp.effectiveAppearance;
  NSAppearanceName best = [app bestMatchFromAppearancesWithNames:@[
    NSAppearanceNameDarkAqua, NSAppearanceNameAqua
  ]];
  return [best isEqualToString:NSAppearanceNameDarkAqua];
}

NSImage* ExtSymbol(NSString* name, CGFloat size, NSFontWeight weight) {
  NSImage* img = [NSImage imageWithSystemSymbolName:name
                           accessibilityDescription:nil];
  if (!img) {
    return nil;
  }
  NSImageSymbolConfiguration* cfg =
      [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
  return [img imageWithSymbolConfiguration:cfg];
}

bool IsExternallyInstalledExtension(const extensions::Extension* ext) {
  if (!ext) {
    return false;
  }
  return !extensions::ManifestURL::UpdatesFromGallery(ext) ||
         extensions::Manifest::IsUnpackedLocation(ext->location()) ||
         extensions::Manifest::IsExternalLocation(ext->location());
}

NSImage* LoadExtensionIconSyncFromDisk(const extensions::Extension* ext) {
  if (!ext) {
    return nil;
  }
  auto tryRelativePath = [&](const base::FilePath& rel) -> NSImage* {
    if (rel.empty()) {
      return nil;
    }
    base::FilePath full = ext->path().Append(rel);
    NSString* nsPath = base::SysUTF8ToNSString(full.AsUTF8Unsafe());
    if (nsPath.length == 0) {
      return nil;
    }
    NSImage* img = [[NSImage alloc] initWithContentsOfFile:nsPath];
    return (img && img.isValid && img.size.width > 0) ? img : nil;
  };

  extensions::ExtensionResource res = extensions::IconsInfo::GetIconResource(
      ext, extension_misc::EXTENSION_ICON_LARGE,
      ExtensionIconSet::Match::kBigger);
  if (res.empty()) {
    res = extensions::IconsInfo::GetIconResource(
        ext, extension_misc::EXTENSION_ICON_MEDIUM,
        ExtensionIconSet::Match::kSmaller);
  }
  if (!res.empty()) {
    if (NSImage* img = tryRelativePath(res.relative_path())) {
      return img;
    }
  }

  if (const extensions::Manifest* manifest = ext->manifest()) {
    static constexpr const char* kActionKeys[] = {"action", "browser_action",
                                                  "page_action"};
    for (const char* key : kActionKeys) {
      const base::DictValue* dict = manifest->FindDictPath(key);
      if (!dict) {
        continue;
      }
      if (const std::string* s = dict->FindString("default_icon")) {
        if (NSImage* img = tryRelativePath(base::FilePath::FromUTF8Unsafe(*s))) {
          return img;
        }
      } else if (const base::DictValue* iconDict =
                     dict->FindDict("default_icon")) {
        std::string bestPath;
        int bestSize = -1;
        for (const auto [szKey, val] : *iconDict) {
          if (val.is_string()) {
            int sz = std::atoi(szKey.c_str());
            if (sz > bestSize) {
              bestSize = sz;
              bestPath = val.GetString();
            }
          }
        }
        if (!bestPath.empty()) {
          if (NSImage* img =
                  tryRelativePath(base::FilePath::FromUTF8Unsafe(bestPath))) {
            return img;
          }
        }
      }
    }
  }
  return nil;
}

class LightExtIconEntry : public extensions::IconImage::Observer {
 public:
  LightExtIconEntry(Profile* profile,
                    const extensions::Extension* ext,
                    NSImageView* targetView)
      : target_view_(targetView) {
    if (!profile || !ext) {
      return;
    }
    const ExtensionIconSet& icons = extensions::IconsInfo::GetIcons(ext);
    if (icons.empty()) {
      return;
    }
    icon_image_ = std::make_unique<extensions::IconImage>(
        profile, ext, icons, extension_misc::EXTENSION_ICON_LARGE,
        gfx::ImageSkia(), this);
    icon_image_->image_skia().EnsureRepsForSupportedScales();
    ApplyImageIfReady();
  }

  ~LightExtIconEntry() override { icon_image_.reset(); }

  void OnExtensionIconImageChanged(extensions::IconImage* image) override {
    ApplyImageIfReady();
  }

 private:
  void ApplyImageIfReady() {
    if (!icon_image_ || !target_view_) {
      return;
    }
    gfx::ImageSkia skia = icon_image_->image_skia();
    if (skia.isNull()) {
      return;
    }
    if (NSImage* img = gfx::NSImageFromImageSkia(skia)) {
      if (img.size.width > 0 && img.size.height > 0) {
        target_view_.image = img;
        target_view_.contentTintColor = nil;
      }
    }
  }

  NSImageView* __weak target_view_;
  std::unique_ptr<extensions::IconImage> icon_image_;
};

}  // namespace

@interface LightExtFlippedView : NSView
@property(nonatomic, copy) void (^onLayout)(void);
@end

@implementation LightExtFlippedView
@synthesize onLayout = _onLayout;
- (BOOL)isFlipped {
  return YES;
}
- (void)layout {
  [super layout];
  if (_onLayout) {
    _onLayout();
  }
}
@end

@interface LightExtBlockTarget : NSObject
@property(nonatomic, copy) void (^block)(id sender);
+ (instancetype)targetWithBlock:(void (^)(id sender))block;
- (void)invoke:(id)sender;
@end

@implementation LightExtBlockTarget
@synthesize block = _block;
+ (instancetype)targetWithBlock:(void (^)(id sender))block {
  LightExtBlockTarget* t = [[LightExtBlockTarget alloc] init];
  t.block = block;
  return t;
}
- (void)invoke:(id)sender {
  if (_block) {
    _block(sender);
  }
}
@end

// -----------------------------------------------------------------------------
// Hover Drift + Brighter Hover Outline GPU trail controller (0ms ON / 70ms
// linear fade-out + 18pt/48-step pointer sweep interpolation + 3pt arming slop).
// -----------------------------------------------------------------------------
@interface LightExtHoverTrailCanvas : NSView
@end

@implementation LightExtHoverTrailCanvas
- (BOOL)isFlipped {
  return YES;
}
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
@end

@interface LightExtHoverTrailController : NSObject
@property(nonatomic, assign) CGFloat cornerRadius;
@property(nonatomic, assign) CGFloat fillAlpha;
@property(nonatomic, assign) CGFloat borderWidth;
@property(nonatomic, assign) CGFloat borderAlphaDark;
@property(nonatomic, assign) CGFloat borderAlphaLight;
@property(nonatomic, assign) BOOL placeAboveSubviews;
@property(nonatomic, copy) NSArray<NSView*>* (^rowsProvider)(void);
@property(nonatomic, copy) BOOL (^isRowExcluded)(NSView* row);
- (instancetype)initWithScrollView:(NSScrollView*)scrollView
                      documentView:(NSView*)documentView;
- (instancetype)initWithContainerView:(NSView*)containerView;
- (void)syncCanvasBounds;
- (void)handleMouseMovedInWindow:(NSPoint)winPt;
- (void)cancelAllAnimated:(BOOL)animated;
- (void)teardown;
@end

@implementation LightExtHoverTrailController {
  NSScrollView* __weak _scrollView;
  NSView* __weak _documentView;
  LightExtHoverTrailCanvas* __strong _canvas;
  NSMapTable<NSView*, CALayer*>* __strong _activePills;
  NSView* __weak _hoveredRow;
  BOOL _hasLastPointer;
  NSPoint _lastDocPoint;
  BOOL _armed;
  BOOL _hasArmOrigin;
  NSPoint _armOrigin;
}

@synthesize cornerRadius = _cornerRadius;
@synthesize fillAlpha = _fillAlpha;
@synthesize borderWidth = _borderWidth;
@synthesize borderAlphaDark = _borderAlphaDark;
@synthesize borderAlphaLight = _borderAlphaLight;
@synthesize placeAboveSubviews = _placeAboveSubviews;
@synthesize rowsProvider = _rowsProvider;
@synthesize isRowExcluded = _isRowExcluded;

- (instancetype)initWithScrollView:(NSScrollView*)scrollView
                      documentView:(NSView*)documentView {
  if ((self = [super init])) {
    _scrollView = scrollView;
    _documentView = documentView;
    _cornerRadius = 12.0;
    _fillAlpha = 0.055;
    _borderWidth = 1.25;
    _borderAlphaDark = 0.36;
    _borderAlphaLight = 0.24;
    _placeAboveSubviews = YES;
    _activePills = [NSMapTable weakToStrongObjectsMapTable];

    _canvas =
        [[LightExtHoverTrailCanvas alloc] initWithFrame:documentView.bounds];
    _canvas.wantsLayer = YES;
    _canvas.layer.masksToBounds = NO;
    _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [documentView addSubview:_canvas positioned:NSWindowAbove relativeTo:nil];

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
    _cornerRadius = 9.5;
    _fillAlpha = 0.07;
    _borderWidth = 1.1;
    _borderAlphaDark = 0.30;
    _borderAlphaLight = 0.20;
    _placeAboveSubviews = YES;
    _activePills = [NSMapTable weakToStrongObjectsMapTable];

    _canvas =
        [[LightExtHoverTrailCanvas alloc] initWithFrame:containerView.bounds];
    _canvas.wantsLayer = YES;
    _canvas.layer.masksToBounds = NO;
    _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [containerView addSubview:_canvas positioned:NSWindowAbove relativeTo:nil];
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
  if (_placeAboveSubviews) {
    if (doc.subviews.lastObject != _canvas) {
      [_canvas removeFromSuperview];
      [doc addSubview:_canvas positioned:NSWindowAbove relativeTo:nil];
    }
  } else {
    if (doc.subviews.firstObject != _canvas) {
      [_canvas removeFromSuperview];
      [doc addSubview:_canvas positioned:NSWindowBelow relativeTo:nil];
    }
  }
}

- (CALayer*)ensureActivePillForRow:(NSView*)row {
  if (!row || !_canvas.layer) {
    return nil;
  }
  const bool dark = IsExtDarkAppearance(_documentView);
  CALayer* pill = [_activePills objectForKey:row];
  if (!pill) {
    pill = [CALayer layer];
    pill.cornerCurve = kCACornerCurveContinuous;
    [_canvas.layer addSublayer:pill];
    [_activePills setObject:pill forKey:row];
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [pill removeAnimationForKey:@"extHoverTrailFade"];
  pill.frame = row.frame;
  pill.cornerRadius = _cornerRadius;
  pill.backgroundColor =
      (dark ? [NSColor colorWithWhite:1.0 alpha:_fillAlpha]
            : [NSColor colorWithWhite:0.0 alpha:_fillAlpha * 0.75])
          .CGColor;
  pill.borderWidth = _borderWidth;
  pill.borderColor =
      (dark ? [NSColor colorWithWhite:1.0 alpha:_borderAlphaDark]
            : [NSColor colorWithWhite:0.0 alpha:_borderAlphaLight])
          .CGColor;
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
  [pill removeAnimationForKey:@"extHoverTrailFade"];

  __weak __typeof(self) weakSelf = self;
  __weak NSView* weakRow = row;
  [CATransaction begin];
  [CATransaction setCompletionBlock:^{
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    if (pill.opacity <= 0.001f && ![pill animationForKey:@"extHoverTrailFade"]) {
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
  fade.duration = 0.070;
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  fade.removedOnCompletion = YES;
  [pill addAnimation:fade forKey:@"extHoverTrailFade"];
  [CATransaction commit];
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
    if (_isRowExcluded && _isRowExcluded(row)) {
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
  if (!doc || !doc.window || doc.isHidden) {
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
    NSPoint localPt = [doc convertPoint:winPt fromView:nil];
    if (!NSPointInRect(localPt, doc.bounds)) {
      if (_hoveredRow || _hasLastPointer) {
        [self cancelAllAnimated:YES];
      }
      return;
    }
  }
  NSPoint docPt = [doc convertPoint:winPt fromView:nil];

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
    int steps = (dist <= 18.0)
                    ? 1
                    : std::min<int>(48, static_cast<int>(std::ceil(dist / 18.0)));
    NSView* lastSeen = nil;
    for (int i = 1; i <= steps; ++i) {
      CGFloat t = static_cast<CGFloat>(i) / static_cast<CGFloat>(steps);
      NSPoint sample =
          NSMakePoint(_lastDocPoint.x + dx * t, _lastDocPoint.y + dy * t);
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

  for (NSView* v in visited) {
    if (v != finalTarget) {
      [self ensureActivePillForRow:v];
      [self startFadeOutForRow:v];
    }
  }
  if (prevHovered && prevHovered != finalTarget) {
    [self startFadeOutForRow:prevHovered];
  }
  if (finalTarget) {
    [self ensureActivePillForRow:finalTarget];
  }
  _hoveredRow = finalTarget;
}

@end

// -----------------------------------------------------------------------------
// Custom sleek glass-pill search bar with generous internal padding.
// -----------------------------------------------------------------------------
@interface LightExtSearchBarView : NSView <NSTextFieldDelegate>
@property(nonatomic, readonly) NSTextField* textField;
@property(nonatomic, copy) void (^onQueryChanged)(NSString* query);
- (NSString*)queryString;
@end

@implementation LightExtSearchBarView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _textField;
  NSButton* __strong _clearBtn;
  BOOL _focused;
}

@synthesize textField = _textField;
@synthesize onQueryChanged = _onQueryChanged;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 11.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.image = ExtSymbol(@"magnifyingglass", 13.0, NSFontWeightMedium);
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_iconView];

    _textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _textField.bordered = NO;
    _textField.bezeled = NO;
    _textField.drawsBackground = NO;
    _textField.focusRingType = NSFocusRingTypeNone;
    _textField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    _textField.textColor = NSColor.labelColor;
    _textField.placeholderString = @"Search extensions…";
    _textField.usesSingleLineMode = YES;
    _textField.cell.scrollable = YES;
    _textField.cell.wraps = NO;
    _textField.delegate = self;
    [self addSubview:_textField];

    _clearBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
    _clearBtn.bordered = NO;
    _clearBtn.image = ExtSymbol(@"xmark.circle.fill", 13.0, NSFontWeightMedium);
    _clearBtn.contentTintColor = NSColor.tertiaryLabelColor;
    _clearBtn.target = self;
    _clearBtn.action = @selector(handleClear:);
    _clearBtn.hidden = YES;
    [self addSubview:_clearBtn];

    [self updateAppearanceAnimated:NO];
  }
  return self;
}

- (NSString*)queryString {
  return _textField.stringValue ?: @"";
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateAppearanceAnimated:NO];
}

- (void)updateAppearanceAnimated:(BOOL)animated {
  const bool dark = IsExtDarkAppearance(self);
  CGColorRef bg =
      (dark ? [NSColor colorWithWhite:1.0 alpha:(_focused ? 0.11 : 0.075)]
            : [NSColor colorWithWhite:0.0 alpha:(_focused ? 0.07 : 0.045)])
          .CGColor;
  CGColorRef bd =
      (_focused
           ? [NSColor.controlAccentColor colorWithAlphaComponent:0.55].CGColor
           : (dark ? [NSColor colorWithWhite:1.0 alpha:0.13]
                   : [NSColor colorWithWhite:0.0 alpha:0.11])
                 .CGColor);
  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:0.16];
    [CATransaction
        setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  }
  self.layer.backgroundColor = bg;
  self.layer.borderColor = bd;
  self.layer.borderWidth = _focused ? 1.25 : 0.75;
  [CATransaction commit];
}

- (void)layout {
  [super layout];
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  _iconView.frame = NSMakeRect(13.0, std::floor((h - 15.0) * 0.5), 15.0, 15.0);
  _clearBtn.frame =
      NSMakeRect(std::max<CGFloat>(0.0, w - 30.0), std::floor((h - 20.0) * 0.5),
                 20.0, 20.0);
  CGFloat rightPad = _clearBtn.isHidden ? 14.0 : 34.0;
  NSSize fit = [_textField sizeThatFits:NSMakeSize(1000.0, h)];
  CGFloat th = std::min<CGFloat>(h - 6.0, std::ceil(fit.height));
  _textField.frame =
      NSMakeRect(36.0, std::floor((h - th) * 0.5),
                 std::max<CGFloat>(40.0, w - 36.0 - rightPad), th);
}

- (void)mouseDown:(NSEvent*)event {
  [self.window makeFirstResponder:_textField];
}

- (void)handleClear:(id)sender {
  _textField.stringValue = @"";
  _clearBtn.hidden = YES;
  [self setNeedsLayout:YES];
  if (_onQueryChanged) {
    _onQueryChanged(@"");
  }
}

- (void)controlTextDidBeginEditing:(NSNotification*)note {
  _focused = YES;
  [self updateAppearanceAnimated:YES];
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
  _focused = NO;
  [self updateAppearanceAnimated:YES];
}

- (void)controlTextDidChange:(NSNotification*)note {
  NSString* q = _textField.stringValue ?: @"";
  _clearBtn.hidden = (q.length == 0);
  [self setNeedsLayout:YES];
  if (_onQueryChanged) {
    _onQueryChanged(q);
  }
}

@end

// -----------------------------------------------------------------------------
// Sleek filter chip with animated click/unclick transitions & press physics.
// Hover glow + bright outline is driven by LightExtHoverTrailController.
// -----------------------------------------------------------------------------
@interface LightExtFilterChipView : NSView
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, copy) void (^onClick)(void);
- (instancetype)initWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                  accentColor:(NSColor*)accentColor;
- (void)setSelected:(BOOL)selected animated:(BOOL)animated;
- (void)setCount:(NSInteger)count;
- (CGFloat)idealWidth;
@end

@implementation LightExtFilterChipView {
  NSImageView* __strong _iconView;
  NSTextField* __strong _label;
  NSTextField* __strong _countLabel;
  NSColor* __strong _accentColor;
  NSString* __strong _baseTitle;
  BOOL _pressed;
}

@synthesize selected = _selected;
@synthesize onClick = _onClick;

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                  accentColor:(NSColor*)accentColor {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _baseTitle = [title copy];
    _accentColor = accentColor;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 9.5;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.image = ExtSymbol(symbol, 11.0, NSFontWeightMedium);
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    [self addSubview:_iconView];

    _label = [NSTextField labelWithString:_baseTitle];
    _label.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    _label.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_label];

    _countLabel = [NSTextField labelWithString:@"0"];
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0
                                                        weight:NSFontWeightMedium];
    _countLabel.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_countLabel];

    [self updateAppearanceAnimated:NO];
  }
  return self;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateAppearanceAnimated:NO];
}

- (void)setCount:(NSInteger)count {
  _countLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)count];
  [self setNeedsLayout:YES];
}

- (CGFloat)idealWidth {
  NSSize fitL = [_label sizeThatFits:NSMakeSize(160.0, 28.0)];
  NSSize fitC = [_countLabel sizeThatFits:NSMakeSize(60.0, 28.0)];
  return 11.0 + 13.0 + 6.0 + std::ceil(fitL.width) + 7.0 +
         std::ceil(fitC.width) + 12.0;
}

- (void)setSelected:(BOOL)selected {
  [self setSelected:selected animated:NO];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
  if (_selected == selected && animated) {
    return;
  }
  _selected = selected;
  [self updateAppearanceAnimated:animated];
  if (animated && self.layer) {
    // Subtle springy click/unclick ease pop around center.
    CALayer* l = self.layer;
    NSRect b = self.bounds;
    l.anchorPoint = CGPointMake(0.5, 0.5);
    l.position = CGPointMake(NSMidX(self.frame), NSMidY(self.frame));
    (void)b;
    CABasicAnimation* pop =
        [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pop.fromValue = @(selected ? 0.94 : 1.02);
    pop.toValue = @(1.0);
    pop.duration = 0.20;
    pop.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
    pop.removedOnCompletion = YES;
    [l addAnimation:pop forKey:@"chipSelectPop"];
  }
}

- (void)updateAppearanceAnimated:(BOOL)animated {
  const bool dark = IsExtDarkAppearance(self);
  NSColor* accent = _accentColor ?: NSColor.controlAccentColor;

  CGColorRef bg = nil;
  CGColorRef bd = nil;
  CGFloat bw = 0.75;
  if (_selected) {
    bg = [accent colorWithAlphaComponent:(dark ? 0.22 : 0.14)].CGColor;
    bd = [accent colorWithAlphaComponent:(dark ? 0.58 : 0.45)].CGColor;
    bw = 1.0;
    _label.textColor = dark ? NSColor.whiteColor : accent;
    _iconView.contentTintColor = accent;
    _countLabel.textColor =
        [(dark ? NSColor.whiteColor : accent) colorWithAlphaComponent:0.75];
  } else {
    bg = (dark ? [NSColor colorWithWhite:1.0 alpha:0.055]
               : [NSColor colorWithWhite:0.0 alpha:0.04])
             .CGColor;
    bd = (dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
               : [NSColor colorWithWhite:0.0 alpha:0.09])
             .CGColor;
    bw = 0.75;
    _label.textColor = [NSColor.labelColor colorWithAlphaComponent:0.86];
    _iconView.contentTintColor = NSColor.secondaryLabelColor;
    _countLabel.textColor = NSColor.tertiaryLabelColor;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:!animated];
  if (animated) {
    [CATransaction setAnimationDuration:0.18];
    [CATransaction
        setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  }
  self.layer.backgroundColor = bg;
  self.layer.borderColor = bd;
  self.layer.borderWidth = bw;
  [CATransaction commit];
}

- (void)layout {
  [super layout];
  CGFloat h = self.bounds.size.height;
  _iconView.frame = NSMakeRect(11.0, std::floor((h - 13.0) * 0.5), 13.0, 13.0);
  NSSize fitL = [_label sizeThatFits:NSMakeSize(160.0, h)];
  CGFloat lw = std::ceil(fitL.width);
  CGFloat lh = std::ceil(fitL.height);
  _label.frame = NSMakeRect(30.0, std::floor((h - lh) * 0.5), lw + 1.0, lh);

  NSSize fitC = [_countLabel sizeThatFits:NSMakeSize(60.0, h)];
  CGFloat cw = std::ceil(fitC.width);
  CGFloat ch = std::ceil(fitC.height);
  _countLabel.frame =
      NSMakeRect(30.0 + lw + 7.0, std::floor((h - ch) * 0.5) + 0.5, cw + 1.0, ch);
}

- (void)animatePressScale:(CGFloat)scale {
  if (!self.layer) {
    return;
  }
  self.layer.anchorPoint = CGPointMake(0.5, 0.5);
  self.layer.position = CGPointMake(NSMidX(self.frame), NSMidY(self.frame));
  [CATransaction begin];
  [CATransaction setAnimationDuration:0.10];
  [CATransaction
      setAnimationTimingFunction:
          [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0]];
  self.layer.transform = CATransform3DMakeScale(scale, scale, 1.0);
  [CATransaction commit];
}

- (void)mouseDown:(NSEvent*)event {
  _pressed = YES;
  [self animatePressScale:0.94];
}

- (void)mouseUp:(NSEvent*)event {
  if (!_pressed) {
    return;
  }
  _pressed = NO;
  [self animatePressScale:1.0];
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(pt, self.bounds) && _onClick) {
    _onClick();
  }
}

@end

// -----------------------------------------------------------------------------
// Clickable extension card (inline controls swallow their own clicks; clicking
// anywhere else on the card opens the full Extension Inspector view).
// -----------------------------------------------------------------------------
@interface LightExtCardView : LightExtFlippedView
@property(nonatomic, assign) BOOL enabledExtension;
@property(nonatomic, copy) void (^onOpenDetail)(void);
@end

@implementation LightExtCardView

@synthesize enabledExtension = _enabledExtension;
@synthesize onOpenDetail = _onOpenDetail;

- (void)updateCardBacking {
  const bool dark = IsExtDarkAppearance(self);
  if (_enabledExtension) {
    self.layer.backgroundColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.06]
              : [NSColor colorWithWhite:0.0 alpha:0.04])
            .CGColor;
    self.layer.borderColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.09]
              : [NSColor colorWithWhite:0.0 alpha:0.07])
            .CGColor;
  } else {
    // Slightly dimmed backing for disabled extensions — still clearly readable.
    self.layer.backgroundColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.028]
              : [NSColor colorWithWhite:0.0 alpha:0.022])
            .CGColor;
    self.layer.borderColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.055]
              : [NSColor colorWithWhite:0.0 alpha:0.045])
            .CGColor;
  }
  self.layer.borderWidth = 0.75;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updateCardBacking];
}

- (void)mouseUp:(NSEvent*)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  if (!NSPointInRect(pt, self.bounds)) {
    return;
  }
  // Ignore clicks inside interactive controls (buttons/switches).
  for (NSView* sub in self.subviews) {
    if ([sub isKindOfClass:[NSControl class]] &&
        ![sub isKindOfClass:[NSTextField class]] &&
        NSPointInRect(pt, sub.frame)) {
      return;
    }
  }
  if (_onOpenDetail) {
    _onOpenDetail();
  }
}

@end

@class LightExtensionsManagerWindowController;

namespace {
class LightExtRegistryBridge : public extensions::ExtensionRegistryObserver {
 public:
  LightExtRegistryBridge(Profile* profile,
                         LightExtensionsManagerWindowController* owner)
      : owner_(owner) {
    if (profile) {
      if (auto* reg = extensions::ExtensionRegistry::Get(profile)) {
        obs_.Observe(reg);
      }
    }
  }
  void OnExtensionLoaded(content::BrowserContext*,
                         const extensions::Extension*) override;
  void OnExtensionUnloaded(content::BrowserContext*,
                           const extensions::Extension*,
                           extensions::UnloadedExtensionReason) override;
  void OnExtensionInstalled(content::BrowserContext*,
                            const extensions::Extension*,
                            bool) override;
  void OnExtensionUninstalled(content::BrowserContext*,
                              const extensions::Extension*,
                              extensions::UninstallReason) override;

 private:
  __weak LightExtensionsManagerWindowController* owner_;
  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      obs_{this};
};
}  // namespace

@interface LightExtensionsManagerWindowController : NSObject <NSWindowDelegate>
@property(nonatomic, readonly) NSWindow* window;
- (instancetype)initWithProfile:(Profile*)profile
                        browser:(BrowserWindowInterface*)browser;
- (void)updateProfile:(Profile*)profile
              browser:(BrowserWindowInterface*)browser;
- (void)showWindow;
- (void)reloadExtensionsList;
@end

namespace {
void LightExtRegistryBridge::OnExtensionLoaded(content::BrowserContext*,
                                               const extensions::Extension*) {
  [owner_ reloadExtensionsList];
}
void LightExtRegistryBridge::OnExtensionUnloaded(
    content::BrowserContext*,
    const extensions::Extension*,
    extensions::UnloadedExtensionReason) {
  [owner_ reloadExtensionsList];
}
void LightExtRegistryBridge::OnExtensionInstalled(
    content::BrowserContext*,
    const extensions::Extension*,
    bool) {
  [owner_ reloadExtensionsList];
}
void LightExtRegistryBridge::OnExtensionUninstalled(
    content::BrowserContext*,
    const extensions::Extension*,
    extensions::UninstallReason) {
  [owner_ reloadExtensionsList];
}
}  // namespace

@implementation LightExtensionsManagerWindowController {
  NSWindow* __strong _window;
  raw_ptr<Profile> _profile;
  raw_ptr<BrowserWindowInterface> _browser;
  std::unique_ptr<LightExtRegistryBridge> _regObserver;
  std::vector<std::unique_ptr<LightExtIconEntry>> _iconEntries;
  std::vector<std::unique_ptr<LightExtIconEntry>> _detailIconEntries;

  LightExtFlippedView* __strong _rootView;
  LightExtFlippedView* __strong _listContainerView;
  NSTextField* __strong _titleLabel;
  NSButton* __strong _loadUnpackedBtn;
  NSButton* __strong _installCrxBtn;
  NSTextField* __strong _devModeLabel;
  NSSwitch* __strong _devModeSwitch;

  LightExtSearchBarView* __strong _searchBar;
  LightExtFlippedView* __strong _chipsBarView;
  NSMutableArray<LightExtFilterChipView*>* __strong _filterChips;
  NSInteger _selectedFilter;  // 0=All, 1=Enabled, 2=Disabled, 3=External
  NSString* __strong _searchQuery;

  NSScrollView* __strong _listScroll;
  LightExtFlippedView* __strong _listDoc;
  NSMutableArray<LightExtCardView*>* __strong _cardViews;
  NSMutableArray<LightExtBlockTarget*>* __strong _retainedTargets;

  LightExtHoverTrailController* __strong _cardsHoverTrail;
  LightExtHoverTrailController* __strong _chipsHoverTrail;
  id __strong _localEventMonitor;

  // Full detail inspector view (presented smoothly when clicking an extension).
  LightExtFlippedView* __strong _detailOverlayView;
  NSScrollView* __strong _detailScroll;
  LightExtFlippedView* __strong _detailDoc;
  NSMutableArray<LightExtBlockTarget*>* __strong _detailTargets;
  std::string _activeDetailExtId;
}

@synthesize window = _window;

- (instancetype)initWithProfile:(Profile*)profile
                        browser:(BrowserWindowInterface*)browser {
  if ((self = [super init])) {
    _profile = profile;
    _browser = browser;
    _retainedTargets = [NSMutableArray array];
    _detailTargets = [NSMutableArray array];
    _filterChips = [NSMutableArray array];
    _cardViews = [NSMutableArray array];
    _selectedFilter = 0;
    _searchQuery = @"";
    [self buildWindow];
    if (_profile) {
      _regObserver = std::make_unique<LightExtRegistryBridge>(_profile, self);
    }
    [self reloadExtensionsList];
  }
  return self;
}

- (void)dealloc {
  if (_localEventMonitor) {
    [NSEvent removeMonitor:_localEventMonitor];
    _localEventMonitor = nil;
  }
  [_cardsHoverTrail teardown];
  [_chipsHoverTrail teardown];
}

- (void)updateProfile:(Profile*)profile
              browser:(BrowserWindowInterface*)browser {
  if (profile && profile != _profile) {
    _profile = profile;
    _regObserver = std::make_unique<LightExtRegistryBridge>(_profile, self);
  }
  if (browser) {
    _browser = browser;
  }
  if (_profile && _profile->GetPrefs() && _devModeSwitch) {
    bool dev = _profile->GetPrefs()->GetBoolean(
        prefs::kExtensionsUIDeveloperMode);
    _devModeSwitch.state = dev ? NSControlStateValueOn : NSControlStateValueOff;
  }
  [self reloadExtensionsList];
}

- (void)showWindow {
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self reloadExtensionsList];
}

- (void)buildWindow {
  NSRect rect = NSMakeRect(0, 0, 760, 600);
  NSWindowStyleMask style =
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
      NSWindowStyleMaskFullSizeContentView;
  _window = [[NSWindow alloc] initWithContentRect:rect
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"Extensions";
  _window.titleVisibility = NSWindowTitleHidden;
  _window.titlebarAppearsTransparent = YES;
  _window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
  _window.minSize = NSMakeSize(600, 460);
  _window.releasedWhenClosed = NO;
  _window.acceptsMouseMovedEvents = YES;
  _window.delegate = self;
  [_window center];

  NSView* container = [[NSView alloc] initWithFrame:rect];
  container.wantsLayer = YES;
  _window.contentView = container;

  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:rect];
    glass.wantsLayer = YES;
    glass.style = NSGlassEffectViewStyleRegular;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:glass];

    _rootView = [[LightExtFlippedView alloc] initWithFrame:rect];
    _rootView.wantsLayer = YES;
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.contentView = _rootView;
  } else {
    NSVisualEffectView* vev = [[NSVisualEffectView alloc] initWithFrame:rect];
    vev.material = NSVisualEffectMaterialWindowBackground;
    vev.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    vev.state = NSVisualEffectStateFollowsWindowActiveState;
    vev.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:vev];

    _rootView = [[LightExtFlippedView alloc] initWithFrame:rect];
    _rootView.wantsLayer = YES;
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [vev addSubview:_rootView];
  }

  __weak __typeof(self) weakSelf = self;
  _rootView.onLayout = ^{
    [weakSelf layoutControls];
  };

  _listContainerView = [[LightExtFlippedView alloc] initWithFrame:rect];
  _listContainerView.wantsLayer = YES;
  _listContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [_rootView addSubview:_listContainerView];

  // Header row (no sidebar — clean full-width macOS list UI).
  _titleLabel = [NSTextField labelWithString:@"Extensions"];
  _titleLabel.font = [NSFont systemFontOfSize:21.0 weight:NSFontWeightBold];
  _titleLabel.textColor = NSColor.labelColor;
  [_listContainerView addSubview:_titleLabel];

  _loadUnpackedBtn = [NSButton buttonWithTitle:@"Load Unpacked…"
                                        target:self
                                        action:@selector(handleLoadUnpacked:)];
  _loadUnpackedBtn.bezelStyle = NSBezelStylePush;
  _loadUnpackedBtn.font =
      [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
  [_listContainerView addSubview:_loadUnpackedBtn];

  _installCrxBtn = [NSButton buttonWithTitle:@"Install .crx…"
                                      target:self
                                      action:@selector(handleInstallCrx:)];
  _installCrxBtn.bezelStyle = NSBezelStylePush;
  _installCrxBtn.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
  [_listContainerView addSubview:_installCrxBtn];

  _devModeLabel = [NSTextField labelWithString:@"Developer Mode"];
  _devModeLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
  _devModeLabel.textColor = NSColor.secondaryLabelColor;
  [_listContainerView addSubview:_devModeLabel];

  _devModeSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
  bool devMode = _profile && _profile->GetPrefs() &&
                 _profile->GetPrefs()->GetBoolean(prefs::kExtensionsUIDeveloperMode);
  _devModeSwitch.state = devMode ? NSControlStateValueOn : NSControlStateValueOff;
  _devModeSwitch.target = self;
  _devModeSwitch.action = @selector(handleDevModeToggle:);
  [_devModeSwitch sizeToFit];
  [_listContainerView addSubview:_devModeSwitch];

  // Sleek padded glass-pill search bar above filter chips.
  _searchBar = [[LightExtSearchBarView alloc] initWithFrame:NSZeroRect];
  _searchBar.onQueryChanged = ^(NSString* query) {
    __strong __typeof(weakSelf) s = weakSelf;
    if (!s) {
      return;
    }
    s->_searchQuery = query ?: @"";
    [s reloadExtensionsList];
  };
  [_listContainerView addSubview:_searchBar];

  // Filter chips row with Hover Drift + animated selection.
  _chipsBarView = [[LightExtFlippedView alloc] initWithFrame:NSZeroRect];
  _chipsBarView.wantsLayer = YES;
  [_listContainerView addSubview:_chipsBarView];

  NSArray<NSDictionary*>* chipDefs = @[
    @{@"title" : @"All", @"symbol" : @"puzzlepiece.extension",
      @"color" : NSColor.controlAccentColor},
    @{@"title" : @"Enabled", @"symbol" : @"checkmark.circle",
      @"color" : NSColor.systemGreenColor},
    @{@"title" : @"Disabled", @"symbol" : @"pause.circle",
      @"color" : NSColor.systemGrayColor},
    @{@"title" : @"External", @"symbol" : @"exclamationmark.triangle",
      @"color" : NSColor.systemOrangeColor},
  ];
  for (NSUInteger i = 0; i < chipDefs.count; ++i) {
    NSDictionary* d = chipDefs[i];
    LightExtFilterChipView* chip =
        [[LightExtFilterChipView alloc] initWithTitle:d[@"title"]
                                               symbol:d[@"symbol"]
                                          accentColor:d[@"color"]];
    [chip setSelected:(i == 0) animated:NO];
    NSInteger idx = static_cast<NSInteger>(i);
    chip.onClick = ^{
      [weakSelf selectFilter:idx];
    };
    [_chipsBarView addSubview:chip];
    [_filterChips addObject:chip];
  }

  _chipsHoverTrail =
      [[LightExtHoverTrailController alloc] initWithContainerView:_chipsBarView];
  _chipsHoverTrail.cornerRadius = 9.5;
  _chipsHoverTrail.fillAlpha = 0.06;
  _chipsHoverTrail.borderWidth = 1.15;
  _chipsHoverTrail.borderAlphaDark = 0.34;
  _chipsHoverTrail.borderAlphaLight = 0.24;
  _chipsHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_filterChips : @[];
  };
  _chipsHoverTrail.isRowExcluded = ^BOOL(NSView* row) {
    if ([row isKindOfClass:[LightExtFilterChipView class]]) {
      return ((LightExtFilterChipView*)row).selected;
    }
    return NO;
  };

  // Full-width scrollable extension list.
  _listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _listScroll.drawsBackground = NO;
  _listScroll.hasVerticalScroller = YES;
  _listScroll.autohidesScrollers = YES;
  _listScroll.scrollerStyle = NSScrollerStyleOverlay;
  _listScroll.borderType = NSNoBorder;
  _listDoc = [[LightExtFlippedView alloc] initWithFrame:NSZeroRect];
  _listDoc.wantsLayer = YES;
  _listScroll.documentView = _listDoc;
  [_listContainerView addSubview:_listScroll];

  _cardsHoverTrail = [[LightExtHoverTrailController alloc]
      initWithScrollView:_listScroll
            documentView:_listDoc];
  _cardsHoverTrail.cornerRadius = 12.0;
  _cardsHoverTrail.fillAlpha = 0.055;
  _cardsHoverTrail.borderWidth = 1.3;
  _cardsHoverTrail.borderAlphaDark = 0.38;
  _cardsHoverTrail.borderAlphaLight = 0.25;
  _cardsHoverTrail.rowsProvider = ^NSArray<NSView*>* {
    __strong __typeof(weakSelf) s = weakSelf;
    return s ? (NSArray<NSView*>*)s->_cardViews : @[];
  };
  _cardsHoverTrail.isRowExcluded = ^BOOL(NSView* row) { return NO; };

  // Detail inspector view (initially hidden, animates in when clicking a card).
  _detailOverlayView = [[LightExtFlippedView alloc] initWithFrame:rect];
  _detailOverlayView.wantsLayer = YES;
  _detailOverlayView.hidden = YES;
  _detailOverlayView.alphaValue = 0.0;
  _detailOverlayView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [_rootView addSubview:_detailOverlayView];

  _detailScroll = [[NSScrollView alloc] initWithFrame:rect];
  _detailScroll.drawsBackground = NO;
  _detailScroll.hasVerticalScroller = YES;
  _detailScroll.autohidesScrollers = YES;
  _detailScroll.scrollerStyle = NSScrollerStyleOverlay;
  _detailScroll.borderType = NSNoBorder;
  _detailScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _detailDoc = [[LightExtFlippedView alloc] initWithFrame:rect];
  _detailDoc.wantsLayer = YES;
  _detailScroll.documentView = _detailDoc;
  [_detailOverlayView addSubview:_detailScroll];

  // Local event monitor for Hover Drift tracking + Escape to close detail view.
  _localEventMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:
          (NSEventMaskMouseMoved | NSEventMaskScrollWheel |
           NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
           NSEventMaskKeyDown)
                                   handler:^NSEvent*(NSEvent* event) {
                                     __strong __typeof(weakSelf) s = weakSelf;
                                     if (!s || !s->_window ||
                                         !s->_window.isVisible) {
                                       return event;
                                     }
                                     if (event.type == NSEventTypeKeyDown &&
                                         event.window == s->_window &&
                                         event.keyCode == 53 &&
                                         !s->_activeDetailExtId.empty()) {
                                       [s closeExtensionDetailAnimated:YES];
                                       return nil;
                                     }
                                     if (event.type == NSEventTypeMouseMoved) {
                                       if (s->_activeDetailExtId.empty()) {
                                         NSPoint wp = [s->_window
                                             convertPointFromScreen:
                                                 NSEvent.mouseLocation];
                                         [s->_cardsHoverTrail
                                             handleMouseMovedInWindow:wp];
                                         [s->_chipsHoverTrail
                                             handleMouseMovedInWindow:wp];
                                       }
                                     } else if (event.window == s->_window) {
                                       [s->_cardsHoverTrail
                                           cancelAllAnimated:NO];
                                       [s->_chipsHoverTrail
                                           cancelAllAnimated:NO];
                                     }
                                     return event;
                                   }];

  [self layoutControls];
}

- (void)windowDidResignKey:(NSNotification*)note {
  [_cardsHoverTrail cancelAllAnimated:NO];
  [_chipsHoverTrail cancelAllAnimated:NO];
}

- (void)layoutControls {
  if (!_rootView) {
    return;
  }
  NSRect b = _rootView.bounds;
  CGFloat w = b.size.width;
  CGFloat h = b.size.height;
  _listContainerView.frame = b;
  _detailOverlayView.frame = b;
  _detailScroll.frame = b;

  constexpr CGFloat kPadX = 24.0;

  // Header row (sits cleanly beneath traffic lights).
  CGFloat headerY = 38.0;
  _titleLabel.frame = NSMakeRect(kPadX, headerY, 170.0, 28.0);

  CGFloat rightX = w - kPadX;
  CGFloat swW = _devModeSwitch.frame.size.width;
  CGFloat swH = _devModeSwitch.frame.size.height;
  rightX -= swW;
  _devModeSwitch.frame =
      NSMakeRect(rightX, headerY + std::floor((28.0 - swH) * 0.5), swW, swH);
  rightX -= 7.0;

  NSSize devFit = [_devModeLabel sizeThatFits:NSMakeSize(140.0, 20.0)];
  CGFloat devW = std::ceil(devFit.width);
  rightX -= devW;
  _devModeLabel.frame = NSMakeRect(rightX, headerY + 6.0, devW, 17.0);
  rightX -= 14.0;

  [_installCrxBtn sizeToFit];
  CGFloat crxW = std::ceil(_installCrxBtn.frame.size.width) + 6.0;
  rightX -= crxW;
  _installCrxBtn.frame = NSMakeRect(rightX, headerY + 2.0, crxW, 25.0);
  rightX -= 8.0;

  [_loadUnpackedBtn sizeToFit];
  CGFloat unpW = std::ceil(_loadUnpackedBtn.frame.size.width) + 6.0;
  rightX -= unpW;
  _loadUnpackedBtn.frame = NSMakeRect(rightX, headerY + 2.0, unpW, 25.0);

  // Full-width padded glass search bar.
  CGFloat searchY = headerY + 42.0;
  _searchBar.frame = NSMakeRect(kPadX, searchY,
                                std::max<CGFloat>(180.0, w - kPadX * 2.0), 38.0);

  // Filter chips row below search bar.
  CGFloat chipsY = searchY + 48.0;
  _chipsBarView.frame =
      NSMakeRect(kPadX, chipsY, std::max<CGFloat>(180.0, w - kPadX * 2.0), 32.0);
  CGFloat cx = 0.0;
  for (LightExtFilterChipView* chip in _filterChips) {
    CGFloat cw = [chip idealWidth];
    chip.frame = NSMakeRect(cx, 1.0, cw, 28.0);
    cx += cw + 8.0;
  }
  [_chipsHoverTrail syncCanvasBounds];

  // List scroll view below chips.
  CGFloat listY = chipsY + 42.0;
  _listScroll.frame =
      NSMakeRect(0.0, listY, w, std::max<CGFloat>(80.0, h - listY));

  if (!_activeDetailExtId.empty()) {
    [self rebuildDetailViewForExtensionId:_activeDetailExtId];
  }
}

- (void)windowDidResize:(NSNotification*)note {
  [self layoutControls];
  [self reloadExtensionsList];
}

- (void)selectFilter:(NSInteger)idx {
  if (_selectedFilter == idx) {
    return;
  }
  _selectedFilter = idx;
  [_chipsHoverTrail cancelAllAnimated:YES];
  for (NSUInteger i = 0; i < _filterChips.count; ++i) {
    [_filterChips[i] setSelected:(static_cast<NSInteger>(i) == idx)
                        animated:YES];
  }
  [self reloadExtensionsList];
}

- (void)handleDevModeToggle:(NSSwitch*)sender {
  if (_profile && _profile->GetPrefs()) {
    _profile->GetPrefs()->SetBoolean(
        prefs::kExtensionsUIDeveloperMode,
        sender.state == NSControlStateValueOn);
  }
}

- (void)handleLoadUnpacked:(id)sender {
  if (!_profile) {
    return;
  }
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = YES;
  panel.canChooseFiles = NO;
  panel.prompt = @"Load";
  panel.message =
      @"Select an unpacked extension folder containing manifest.json";
  Profile* profile = _profile;
  [panel beginSheetModalForWindow:_window
                completionHandler:^(NSModalResponse resp) {
                  if (resp == NSModalResponseOK && panel.URL.path) {
                    base::FilePath path(
                        base::SysNSStringToUTF8(panel.URL.path));
                    scoped_refptr<extensions::UnpackedInstaller> installer =
                        extensions::UnpackedInstaller::Create(profile);
                    installer->Load(path);
                  }
                }];
}

- (void)handleInstallCrx:(id)sender {
  if (!_profile) {
    return;
  }
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.prompt = @"Install";
  panel.message = @"Select a .crx extension package to install";
  Profile* profile = _profile;
  BrowserWindowInterface* browser = _browser;
  [panel beginSheetModalForWindow:_window
                completionHandler:^(NSModalResponse resp) {
                  if (resp == NSModalResponseOK && panel.URL.path) {
                    base::FilePath path(
                        base::SysNSStringToUTF8(panel.URL.path));
                    content::WebContents* wc =
                        (browser && browser->GetTabStripModel())
                            ? browser->GetTabStripModel()->GetActiveWebContents()
                            : nullptr;
                    std::unique_ptr<ExtensionInstallPrompt> prompt;
                    if (wc) {
                      prompt =
                          std::make_unique<ExtensionInstallPrompt>(wc, nullptr);
                    }
                    scoped_refptr<extensions::CrxInstaller> installer =
                        extensions::CrxInstaller::Create(profile,
                                                         std::move(prompt));
                    installer->set_off_store_install_allow_reason(
                        extensions::CrxInstaller::
                            OffStoreInstallAllowedFromSettingsPage);
                    installer->set_error_on_unsupported_requirements(true);
                    installer->InstallCrx(path);
                  }
                }];
}

- (void)openURLInBrowser:(const GURL&)url {
  if (!url.is_valid()) {
    return;
  }
  if (_browser) {
    NavigateParams params(_browser, url, ui::PAGE_TRANSITION_LINK);
    params.disposition = WindowOpenDisposition::kNewForegroundTab;
    Navigate(&params);
  } else {
    NSURL* nsUrl = [NSURL URLWithString:base::SysUTF8ToNSString(url.spec())];
    if (nsUrl) {
      [[NSWorkspace sharedWorkspace] openURL:nsUrl];
    }
  }
}

- (void)openExtensionDetailForId:(const std::string&)extId {
  _activeDetailExtId = extId;
  [_cardsHoverTrail cancelAllAnimated:NO];
  [_chipsHoverTrail cancelAllAnimated:NO];
  [self rebuildDetailViewForExtensionId:extId];

  _detailOverlayView.hidden = NO;
  _detailOverlayView.alphaValue = 0.0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.20;
    ctx.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
    _listContainerView.animator.alphaValue = 0.0;
    _detailOverlayView.animator.alphaValue = 1.0;
  }
                      completionHandler:^{
                        if (!self->_activeDetailExtId.empty()) {
                          self->_listContainerView.hidden = YES;
                        }
                      }];
}

- (void)closeExtensionDetailAnimated:(BOOL)animated {
  _activeDetailExtId.clear();
  _listContainerView.hidden = NO;
  if (!animated) {
    _detailOverlayView.hidden = YES;
    _detailOverlayView.alphaValue = 0.0;
    _listContainerView.alphaValue = 1.0;
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.18;
    ctx.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.30 :1.0];
    _detailOverlayView.animator.alphaValue = 0.0;
    _listContainerView.animator.alphaValue = 1.0;
  }
                      completionHandler:^{
                        if (self->_activeDetailExtId.empty()) {
                          self->_detailOverlayView.hidden = YES;
                        }
                      }];
}

- (void)rebuildDetailViewForExtensionId:(const std::string&)extId {
  if (!_detailDoc || !_profile) {
    return;
  }
  for (NSView* sub in [_detailDoc.subviews copy]) {
    [sub removeFromSuperview];
  }
  [_detailTargets removeAllObjects];
  _detailIconEntries.clear();

  auto* registry = extensions::ExtensionRegistry::Get(_profile);
  auto* registrar = extensions::ExtensionRegistrar::Get(_profile);
  if (!registry) {
    return;
  }
  const extensions::Extension* ext =
      registry->GetInstalledExtension(extId);
  if (!ext) {
    [self closeExtensionDetailAnimated:YES];
    return;
  }

  const bool isEnabled =
      registry->enabled_extensions().GetByID(extId) != nullptr;
  const bool isExternal = IsExternallyInstalledExtension(ext);
  const bool hasOptions = extensions::OptionsPageInfo::HasOptionsPage(ext);
  const GURL optionsUrl =
      hasOptions ? extensions::OptionsPageInfo::GetOptionsPage(ext) : GURL();
  const GURL homepageUrl = extensions::ManifestURL::GetHomepageURL(ext);
  const GURL detailsUrl = extensions::ManifestURL::GetDetailsURL(ext);
  const GURL webStoreUrl =
      detailsUrl.is_valid()
          ? detailsUrl
          : GURL("https://chromewebstore.google.com/detail/" + extId);
  const bool dark = IsExtDarkAppearance(_detailDoc);

  CGFloat availW = std::max<CGFloat>(480.0, _detailScroll.bounds.size.width);
  constexpr CGFloat kPadX = 28.0;
  CGFloat contentW = availW - kPadX * 2.0;
  CGFloat y = 38.0;

  __weak __typeof(self) weakSelf = self;

  // Back button row.
  NSButton* backBtn = [NSButton buttonWithTitle:@"  Extensions"
                                         target:nil
                                         action:nil];
  backBtn.bordered = NO;
  backBtn.image = ExtSymbol(@"chevron.left", 12.5, NSFontWeightSemibold);
  backBtn.imagePosition = NSImageLeft;
  backBtn.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
  backBtn.contentTintColor = NSColor.controlAccentColor;
  [backBtn sizeToFit];
  backBtn.frame =
      NSMakeRect(kPadX - 4.0, y, std::ceil(backBtn.frame.size.width) + 8.0, 24.0);
  LightExtBlockTarget* backTgt = [LightExtBlockTarget targetWithBlock:^(id) {
    [weakSelf closeExtensionDetailAnimated:YES];
  }];
  [_detailTargets addObject:backTgt];
  backBtn.target = backTgt;
  backBtn.action = @selector(invoke:);
  [_detailDoc addSubview:backBtn];
  y += 38.0;

  // Hero card: Full 64x64 icon + Name + Version + Status Switch + Source Badge.
  NSView* heroCard = [[LightExtFlippedView alloc]
      initWithFrame:NSMakeRect(kPadX, y, contentW, 102.0)];
  heroCard.wantsLayer = YES;
  heroCard.layer.cornerRadius = 14.0;
  heroCard.layer.cornerCurve = kCACornerCurveContinuous;
  heroCard.layer.backgroundColor =
      (dark ? [NSColor colorWithWhite:1.0 alpha:0.06]
            : [NSColor colorWithWhite:0.0 alpha:0.04])
          .CGColor;
  heroCard.layer.borderColor =
      (dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
            : [NSColor colorWithWhite:0.0 alpha:0.08])
          .CGColor;
  heroCard.layer.borderWidth = 0.75;
  [_detailDoc addSubview:heroCard];

  NSImageView* iconView =
      [[NSImageView alloc] initWithFrame:NSMakeRect(18, 19, 64, 64)];
  iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  if (NSImage* diskIcon = LoadExtensionIconSyncFromDisk(ext)) {
    iconView.image = diskIcon;
    iconView.contentTintColor = nil;
  } else {
    iconView.image =
        ExtSymbol(@"puzzlepiece.extension.fill", 36.0, NSFontWeightMedium);
    iconView.contentTintColor = NSColor.secondaryLabelColor;
    _detailIconEntries.push_back(
        std::make_unique<LightExtIconEntry>(_profile, ext, iconView));
  }
  [heroCard addSubview:iconView];

  NSTextField* nameLbl =
      [NSTextField labelWithString:base::SysUTF8ToNSString(ext->name())];
  nameLbl.font = [NSFont systemFontOfSize:18.0 weight:NSFontWeightBold];
  nameLbl.textColor = NSColor.labelColor;
  nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
  nameLbl.frame = NSMakeRect(96, 18, std::max<CGFloat>(160.0, contentW - 180.0), 24);
  [heroCard addSubview:nameLbl];

  NSString* metaStr = [NSString
      stringWithFormat:@"Version %@  •  Manifest V%d  •  %@",
                       base::SysUTF8ToNSString(ext->VersionString()),
                       ext->manifest_version(),
                       isEnabled ? @"Enabled" : @"Disabled"];
  NSTextField* metaLbl = [NSTextField labelWithString:metaStr];
  metaLbl.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
  metaLbl.textColor = NSColor.secondaryLabelColor;
  metaLbl.frame = NSMakeRect(96, 44, std::max<CGFloat>(160.0, contentW - 180.0), 17);
  [heroCard addSubview:metaLbl];

  // Source badge chip inside hero card.
  NSView* badge = [[LightExtFlippedView alloc]
      initWithFrame:NSMakeRect(96, 66, isExternal ? 136.0 : 128.0, 20.0)];
  badge.wantsLayer = YES;
  badge.layer.cornerRadius = 10.0;
  badge.layer.cornerCurve = kCACornerCurveContinuous;
  if (isExternal) {
    badge.layer.backgroundColor =
        [NSColor colorWithSRGBRed:1.0 green:0.54 blue:0.06 alpha:0.24].CGColor;
    badge.layer.borderColor =
        [NSColor colorWithSRGBRed:1.0 green:0.60 blue:0.12 alpha:0.85].CGColor;
  } else {
    badge.layer.backgroundColor =
        [NSColor.systemBlueColor colorWithAlphaComponent:0.18].CGColor;
    badge.layer.borderColor =
        [NSColor.systemBlueColor colorWithAlphaComponent:0.55].CGColor;
  }
  badge.layer.borderWidth = 0.85;
  NSImageView* bIcon =
      [[NSImageView alloc] initWithFrame:NSMakeRect(7, 4.5, 11, 11)];
  bIcon.image = ExtSymbol(
      isExternal ? @"exclamationmark.triangle.fill" : @"checkmark.seal.fill",
      9.5, NSFontWeightBold);
  bIcon.contentTintColor =
      isExternal ? [NSColor colorWithSRGBRed:1.0 green:0.62 blue:0.12 alpha:1.0]
                 : NSColor.systemBlueColor;
  [badge addSubview:bIcon];
  NSTextField* bLbl = [NSTextField
      labelWithString:(isExternal ? @"Externally Installed" : @"Chrome Web Store")];
  bLbl.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
  bLbl.textColor = bIcon.contentTintColor;
  bLbl.frame = NSMakeRect(21, 3, badge.frame.size.width - 25, 14);
  [badge addSubview:bLbl];
  [heroCard addSubview:badge];

  // Live Enable/Disable switch in hero card.
  NSSwitch* sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
  sw.state = isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  [sw sizeToFit];
  sw.frame = NSMakeRect(contentW - sw.frame.size.width - 18.0, 39.0,
                        sw.frame.size.width, sw.frame.size.height);
  std::string capturedId = extId;
  LightExtBlockTarget* swTgt =
      [LightExtBlockTarget targetWithBlock:^(NSSwitch* s) {
        if (!registrar) {
          return;
        }
        if (s.state == NSControlStateValueOn) {
          registrar->EnableExtension(capturedId);
        } else {
          registrar->DisableExtension(
              capturedId, {extensions::disable_reason::DISABLE_USER_ACTION});
        }
      }];
  [_detailTargets addObject:swTgt];
  sw.target = swTgt;
  sw.action = @selector(invoke:);
  [heroCard addSubview:sw];

  y += 116.0;

  // Action buttons bar: Open in Finder, Chrome Web Store, Homepage, Options,
  // Reload, Remove.
  CGFloat bx = kPadX;
  CGFloat by = y;
  auto addActionBtn = [&](NSString* title, NSString* symbol, BOOL destructive,
                          void (^handler)(void)) {
    NSButton* btn = [NSButton buttonWithTitle:title target:nil action:nil];
    btn.bezelStyle = NSBezelStylePush;
    btn.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    if (symbol.length > 0) {
      btn.image = ExtSymbol(symbol, 11.5, NSFontWeightMedium);
      btn.imagePosition = NSImageLeft;
    }
    if (destructive) {
      btn.contentTintColor = NSColor.systemRedColor;
    }
    [btn sizeToFit];
    CGFloat bw = std::ceil(btn.frame.size.width) + 10.0;
    if (bx + bw > kPadX + contentW && bx > kPadX) {
      bx = kPadX;
      by += 34.0;
    }
    btn.frame = NSMakeRect(bx, by, bw, 27.0);
    LightExtBlockTarget* tgt = [LightExtBlockTarget targetWithBlock:^(id) {
      if (handler) {
        handler();
      }
    }];
    [_detailTargets addObject:tgt];
    btn.target = tgt;
    btn.action = @selector(invoke:);
    [_detailDoc addSubview:btn];
    bx += bw + 8.0;
  };

  NSString* extPathStr = base::SysUTF8ToNSString(ext->path().AsUTF8Unsafe());
  addActionBtn(@"Open in Finder", @"folder", NO, ^{
    if (extPathStr.length > 0) {
      NSURL* fileUrl = [NSURL fileURLWithPath:extPathStr];
      if (fileUrl) {
        [[NSWorkspace sharedWorkspace]
            activateFileViewerSelectingURLs:@[ fileUrl ]];
      }
    }
  });
  addActionBtn(@"Open in Web Store", @"bag", NO, ^{
    [weakSelf openURLInBrowser:webStoreUrl];
  });
  if (homepageUrl.is_valid() && homepageUrl != webStoreUrl) {
    addActionBtn(@"Homepage", @"safari", NO, ^{
      [weakSelf openURLInBrowser:homepageUrl];
    });
  }
  if (hasOptions && optionsUrl.is_valid()) {
    addActionBtn(@"Options…", @"gearshape", NO, ^{
      [weakSelf openURLInBrowser:optionsUrl];
    });
  }
  addActionBtn(@"Reload", @"arrow.clockwise", NO, ^{
    if (registrar) {
      registrar->ReloadExtension(capturedId);
    }
  });
  addActionBtn(@"Remove", @"trash", YES, ^{
    if (registrar) {
      registrar->UninstallExtension(
          capturedId, extensions::UNINSTALL_REASON_USER_INITIATED, nullptr);
      [weakSelf closeExtensionDetailAnimated:YES];
    }
  });
  y = by + 42.0;

  // Helper for detail section cards.
  auto makeSectionCard = [&](NSString* heading, CGFloat innerH) -> NSView* {
    NSTextField* hLbl = [NSTextField labelWithString:heading];
    hLbl.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    hLbl.textColor = NSColor.secondaryLabelColor;
    hLbl.frame = NSMakeRect(kPadX + 4.0, y, contentW, 16.0);
    [_detailDoc addSubview:hLbl];
    y += 22.0;

    NSView* card = [[LightExtFlippedView alloc]
        initWithFrame:NSMakeRect(kPadX, y, contentW, innerH)];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.backgroundColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.05]
              : [NSColor colorWithWhite:0.0 alpha:0.035])
            .CGColor;
    card.layer.borderColor =
        (dark ? [NSColor colorWithWhite:1.0 alpha:0.08]
              : [NSColor colorWithWhite:0.0 alpha:0.065])
            .CGColor;
    card.layer.borderWidth = 0.75;
    [_detailDoc addSubview:card];
    y += innerH + 16.0;
    return card;
  };

  // Full Description section.
  const std::string* descPtr = ext->manifest()->FindStringPath(
      extensions::manifest_keys::kDescription);
  NSString* fullDesc =
      (descPtr && !descPtr->empty())
          ? base::SysUTF8ToNSString(*descPtr)
          : @"No description provided by this extension.";
  NSTextField* descField = [NSTextField wrappingLabelWithString:fullDesc];
  descField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
  descField.textColor = NSColor.labelColor;
  descField.selectable = YES;
  NSSize descFit =
      [descField sizeThatFits:NSMakeSize(contentW - 28.0, 2000.0)];
  CGFloat descH = std::max<CGFloat>(22.0, std::ceil(descFit.height) + 4.0);
  NSView* descCard = makeSectionCard(@"DESCRIPTION", descH + 24.0);
  descField.frame = NSMakeRect(14.0, 12.0, contentW - 28.0, descH);
  [descCard addSubview:descField];

  // Extension Details (ID + Copy button + Disk Path).
  NSView* infoCard = makeSectionCard(@"DETAILS", 78.0);
  NSTextField* idTitle = [NSTextField labelWithString:@"Extension ID"];
  idTitle.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
  idTitle.textColor = NSColor.secondaryLabelColor;
  idTitle.frame = NSMakeRect(14.0, 12.0, 96.0, 16.0);
  [infoCard addSubview:idTitle];

  NSString* extIdNS = base::SysUTF8ToNSString(extId);
  NSTextField* idVal = [NSTextField labelWithString:extIdNS];
  idVal.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
  idVal.textColor = NSColor.labelColor;
  idVal.selectable = YES;
  idVal.lineBreakMode = NSLineBreakByTruncatingMiddle;
  idVal.frame =
      NSMakeRect(114.0, 12.0, std::max<CGFloat>(120.0, contentW - 196.0), 16.0);
  [infoCard addSubview:idVal];

  NSButton* copyBtn = [NSButton buttonWithTitle:@"Copy" target:nil action:nil];
  copyBtn.bezelStyle = NSBezelStylePush;
  copyBtn.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  copyBtn.frame = NSMakeRect(contentW - 70.0, 8.0, 56.0, 23.0);
  LightExtBlockTarget* copyTgt =
      [LightExtBlockTarget targetWithBlock:^(NSButton* b) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:extIdNS
                                          forType:NSPasteboardTypeString];
        b.title = @"Copied";
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ b.title = @"Copy"; });
      }];
  [_detailTargets addObject:copyTgt];
  copyBtn.target = copyTgt;
  copyBtn.action = @selector(invoke:);
  [infoCard addSubview:copyBtn];

  NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(14.0, 39.0, contentW - 28.0, 0.5)];
  sep.boxType = NSBoxCustom;
  sep.borderWidth = 0.0;
  sep.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.08];
  [infoCard addSubview:sep];

  NSTextField* pathTitle = [NSTextField labelWithString:@"Location"];
  pathTitle.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
  pathTitle.textColor = NSColor.secondaryLabelColor;
  pathTitle.frame = NSMakeRect(14.0, 49.0, 96.0, 16.0);
  [infoCard addSubview:pathTitle];

  NSTextField* pathVal =
      [NSTextField labelWithString:(extPathStr.length > 0 ? extPathStr : @"—")];
  pathVal.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
  pathVal.textColor = NSColor.secondaryLabelColor;
  pathVal.selectable = YES;
  pathVal.lineBreakMode = NSLineBreakByTruncatingMiddle;
  pathVal.frame =
      NSMakeRect(114.0, 49.0, std::max<CGFloat>(120.0, contentW - 128.0), 16.0);
  [infoCard addSubview:pathVal];

  // Permissions section.
  NSMutableArray<NSString*>* permStrings = [NSMutableArray array];
  if (ext->permissions_data()) {
    extensions::PermissionMessages msgs =
        ext->permissions_data()->GetPermissionMessages();
    for (const auto& msg : msgs) {
      NSString* s = base::SysUTF16ToNSString(msg.message());
      if (s.length > 0) {
        [permStrings addObject:s];
      }
    }
  }
  if (permStrings.count == 0) {
    [permStrings addObject:@"No special permissions requested."];
  }
  NSMutableArray<NSTextField*>* permFields = [NSMutableArray array];
  CGFloat permTotalH = 12.0;
  for (NSString* ps in permStrings) {
    NSString* bullet = [NSString stringWithFormat:@"•  %@", ps];
    NSTextField* pf = [NSTextField wrappingLabelWithString:bullet];
    pf.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    pf.textColor = NSColor.labelColor;
    NSSize pfit = [pf sizeThatFits:NSMakeSize(contentW - 28.0, 400.0)];
    CGFloat ph = std::max<CGFloat>(18.0, std::ceil(pfit.height) + 2.0);
    pf.frame = NSMakeRect(14.0, permTotalH, contentW - 28.0, ph);
    [permFields addObject:pf];
    permTotalH += ph + 6.0;
  }
  permTotalH += 6.0;
  NSView* permCard = makeSectionCard(@"PERMISSIONS", permTotalH);
  for (NSTextField* pf in permFields) {
    [permCard addSubview:pf];
  }

  _detailDoc.frame = NSMakeRect(
      0, 0, availW,
      std::max<CGFloat>(_detailScroll.bounds.size.height, y + 24.0));
}

- (void)reloadExtensionsList {
  if (!_listDoc || !_profile) {
    return;
  }
  [_cardsHoverTrail cancelAllAnimated:NO];
  for (NSView* v in [_listDoc.subviews copy]) {
    if (![v isKindOfClass:[LightExtHoverTrailCanvas class]]) {
      [v removeFromSuperview];
    }
  }
  [_cardViews removeAllObjects];
  [_retainedTargets removeAllObjects];
  _iconEntries.clear();

  auto* registry = extensions::ExtensionRegistry::Get(_profile);
  auto* registrar = extensions::ExtensionRegistrar::Get(_profile);
  if (!registry) {
    return;
  }

  struct ExtRow {
    scoped_refptr<const extensions::Extension> ext;
    bool enabled;
    bool external;
  };
  std::vector<ExtRow> allRows;
  NSInteger enabledCount = 0;
  NSInteger disabledCount = 0;
  NSInteger externalCount = 0;

  auto collect = [&](const extensions::ExtensionSet& set, bool isEnabled) {
    for (const auto& ext : set) {
      if (!ext || extensions::Manifest::IsComponentLocation(ext->location())) {
        continue;
      }
      if (!ext->is_extension() && !ext->is_legacy_packaged_app()) {
        continue;
      }
      const bool isExt = IsExternallyInstalledExtension(ext.get());
      if (isEnabled) {
        enabledCount++;
      } else {
        disabledCount++;
      }
      if (isExt) {
        externalCount++;
      }
      allRows.push_back({ext, isEnabled, isExt});
    }
  };
  collect(registry->enabled_extensions(), true);
  collect(registry->disabled_extensions(), false);

  if (_filterChips.count >= 4) {
    [_filterChips[0] setCount:static_cast<NSInteger>(allRows.size())];
    [_filterChips[1] setCount:enabledCount];
    [_filterChips[2] setCount:disabledCount];
    [_filterChips[3] setCount:externalCount];
    [self layoutControls];
  }

  std::vector<ExtRow> filtered;
  for (const auto& r : allRows) {
    if (_selectedFilter == 1 && !r.enabled) {
      continue;
    }
    if (_selectedFilter == 2 && r.enabled) {
      continue;
    }
    if (_selectedFilter == 3 && !r.external) {
      continue;
    }
    if (_searchQuery.length > 0) {
      NSString* name = base::SysUTF8ToNSString(r.ext->name());
      const std::string* descPtr = r.ext->manifest()->FindStringPath(
          extensions::manifest_keys::kDescription);
      NSString* desc = descPtr ? base::SysUTF8ToNSString(*descPtr) : @"";
      if ([name rangeOfString:_searchQuery options:NSCaseInsensitiveSearch]
                  .location == NSNotFound &&
          [desc rangeOfString:_searchQuery options:NSCaseInsensitiveSearch]
                  .location == NSNotFound) {
        continue;
      }
    }
    filtered.push_back(r);
  }
  std::sort(filtered.begin(), filtered.end(),
            [](const ExtRow& a, const ExtRow& b) {
              return a.ext->name() < b.ext->name();
            });

  CGFloat availW = std::max<CGFloat>(420.0, _listScroll.bounds.size.width);
  constexpr CGFloat kLeftX = 24.0;
  CGFloat cardW = availW - kLeftX * 2.0;
  CGFloat y = 4.0;

  if (filtered.empty()) {
    NSTextField* empty = [NSTextField labelWithString:@"No extensions found."];
    empty.font = [NSFont systemFontOfSize:13.0];
    empty.textColor = NSColor.secondaryLabelColor;
    empty.frame = NSMakeRect(kLeftX, y + 14.0, cardW, 20.0);
    [_listDoc addSubview:empty];
    y += 52.0;
  }

  __weak __typeof(self) weakSelf = self;
  for (const auto& item : filtered) {
    const extensions::Extension* ext = item.ext.get();
    std::string extId = ext->id();
    const bool hasOptions = extensions::OptionsPageInfo::HasOptionsPage(ext);
    const GURL optionsUrl =
        hasOptions ? extensions::OptionsPageInfo::GetOptionsPage(ext) : GURL();

    constexpr CGFloat kCardH = 78.0;
    LightExtCardView* card = [[LightExtCardView alloc]
        initWithFrame:NSMakeRect(kLeftX, y, cardW, kCardH)];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.enabledExtension = item.enabled;
    [card updateCardBacking];
    card.onOpenDetail = ^{
      [weakSelf openExtensionDetailForId:extId];
    };
    [_listDoc addSubview:card];
    [_cardViews addObject:card];

    NSImageView* iconView =
        [[NSImageView alloc] initWithFrame:NSMakeRect(15, 21, 36, 36)];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    iconView.alphaValue = item.enabled ? 1.0 : 0.72;
    if (NSImage* diskIcon = LoadExtensionIconSyncFromDisk(ext)) {
      iconView.image = diskIcon;
      iconView.contentTintColor = nil;
    } else {
      iconView.image =
          ExtSymbol(@"puzzlepiece.extension.fill", 22.0, NSFontWeightMedium);
      iconView.contentTintColor = NSColor.secondaryLabelColor;
      _iconEntries.push_back(
          std::make_unique<LightExtIconEntry>(_profile, ext, iconView));
    }
    [card addSubview:iconView];

    // Right-side controls first so we know exact remaining width for text.
    CGFloat rightX = cardW - 14.0;
    NSSwitch* sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
    sw.state = item.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [sw sizeToFit];
    rightX -= sw.frame.size.width;
    sw.frame = NSMakeRect(rightX, std::floor((kCardH - sw.frame.size.height) * 0.5),
                          sw.frame.size.width, sw.frame.size.height);
    LightExtBlockTarget* swTgt =
        [LightExtBlockTarget targetWithBlock:^(NSSwitch* s) {
          if (!registrar) {
            return;
          }
          if (s.state == NSControlStateValueOn) {
            registrar->EnableExtension(extId);
          } else {
            registrar->DisableExtension(
                extId, {extensions::disable_reason::DISABLE_USER_ACTION});
          }
        }];
    [_retainedTargets addObject:swTgt];
    sw.target = swTgt;
    sw.action = @selector(invoke:);
    [card addSubview:sw];
    rightX -= 10.0;

    NSButton* removeBtn = [NSButton buttonWithTitle:@"Remove"
                                             target:nil
                                             action:nil];
    removeBtn.bezelStyle = NSBezelStylePush;
    removeBtn.font = [NSFont systemFontOfSize:11.5];
    rightX -= 66.0;
    removeBtn.frame = NSMakeRect(rightX, 26, 66, 26);
    LightExtBlockTarget* remTgt = [LightExtBlockTarget targetWithBlock:^(id) {
      if (registrar) {
        registrar->UninstallExtension(
            extId, extensions::UNINSTALL_REASON_USER_INITIATED, nullptr);
      }
    }];
    [_retainedTargets addObject:remTgt];
    removeBtn.target = remTgt;
    removeBtn.action = @selector(invoke:);
    [card addSubview:removeBtn];
    rightX -= 8.0;

    if (hasOptions && optionsUrl.is_valid()) {
      NSButton* optBtn = [NSButton buttonWithTitle:@"Options"
                                            target:nil
                                            action:nil];
      optBtn.bezelStyle = NSBezelStylePush;
      optBtn.font = [NSFont systemFontOfSize:11.5];
      rightX -= 66.0;
      optBtn.frame = NSMakeRect(rightX, 26, 66, 26);
      LightExtBlockTarget* optTgt = [LightExtBlockTarget targetWithBlock:^(id) {
        [weakSelf openURLInBrowser:optionsUrl];
      }];
      [_retainedTargets addObject:optTgt];
      optBtn.target = optTgt;
      optBtn.action = @selector(invoke:);
      [card addSubview:optBtn];
      rightX -= 8.0;
    }

    CGFloat textMaxW = std::max<CGFloat>(140.0, rightX - 64.0 - 8.0);

    // Clean extension name (no "(MV2)" / "(MV3)" appended!).
    NSString* extName = base::SysUTF8ToNSString(ext->name());
    NSTextField* nameLbl = [NSTextField labelWithString:extName];
    nameLbl.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    nameLbl.textColor =
        item.enabled
            ? NSColor.labelColor
            : ([NSColor.labelColor blendedColorWithFraction:0.35
                                                    ofColor:NSColor.systemGrayColor]
                   ?: [NSColor.labelColor colorWithAlphaComponent:0.68]);
    if (!item.enabled) {
      nameLbl.textColor = [nameLbl.textColor colorWithAlphaComponent:0.72];
    }
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;

    NSString* verStr =
        [NSString stringWithFormat:@"v%@",
                                   base::SysUTF8ToNSString(ext->VersionString())];
    NSTextField* verLbl = [NSTextField labelWithString:verStr];
    verLbl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    verLbl.textColor = NSColor.tertiaryLabelColor;
    NSSize verFit = [verLbl sizeThatFits:NSMakeSize(90.0, 16.0)];
    CGFloat verW = std::ceil(verFit.width) + 2.0;

    constexpr CGFloat kChipH = 19.0;
    constexpr CGFloat kChipW = 132.0;
    CGFloat reservedRight = verW + 8.0 + (item.external ? (kChipW + 8.0) : 0.0);
    CGFloat availNameW = std::max<CGFloat>(72.0, textMaxW - reservedRight);
    NSSize nameFit = [nameLbl sizeThatFits:NSMakeSize(availNameW, 18.0)];
    CGFloat nameW = std::min<CGFloat>(std::ceil(nameFit.width) + 2.0, availNameW);
    nameLbl.frame = NSMakeRect(64.0, 13.0, nameW, 18.0);
    [card addSubview:nameLbl];

    verLbl.frame = NSMakeRect(64.0 + nameW + 6.0, 15.0, verW, 15.0);
    [card addSubview:verLbl];

    if (item.external) {
      NSView* chip = [[LightExtFlippedView alloc]
          initWithFrame:NSMakeRect(64.0 + nameW + 6.0 + verW + 8.0, 13.0, kChipW,
                                   kChipH)];
      chip.wantsLayer = YES;
      chip.layer.cornerRadius = kChipH * 0.5;
      chip.layer.cornerCurve = kCACornerCurveContinuous;
      chip.layer.backgroundColor =
          [NSColor colorWithSRGBRed:1.0 green:0.54 blue:0.06 alpha:0.24].CGColor;
      chip.layer.borderColor =
          [NSColor colorWithSRGBRed:1.0 green:0.60 blue:0.12 alpha:0.85].CGColor;
      chip.layer.borderWidth = 0.85;

      NSImageView* warnIcon = [[NSImageView alloc]
          initWithFrame:NSMakeRect(7.0, 4.0, 11.0, 11.0)];
      warnIcon.image =
          ExtSymbol(@"exclamationmark.triangle.fill", 9.0, NSFontWeightBold);
      warnIcon.contentTintColor =
          [NSColor colorWithSRGBRed:1.0 green:0.62 blue:0.12 alpha:1.0];
      [chip addSubview:warnIcon];

      NSTextField* chipLbl = [NSTextField labelWithString:@"Externally Installed"];
      chipLbl.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
      chipLbl.textColor =
          [NSColor colorWithSRGBRed:1.0 green:0.62 blue:0.12 alpha:1.0];
      chipLbl.frame = NSMakeRect(20.0, 2.5, kChipW - 24.0, 14.0);
      [chip addSubview:chipLbl];
      [card addSubview:chip];
    }

    // Properly wrapped 2-line description, vertically balanced inside card.
    const std::string* descPtr = ext->manifest()->FindStringPath(
        extensions::manifest_keys::kDescription);
    NSString* descStr = descPtr ? base::SysUTF8ToNSString(*descPtr) : @"";
    if (descStr.length == 0) {
      descStr = base::SysUTF8ToNSString(extId);
    }
    NSTextField* descLbl = [NSTextField wrappingLabelWithString:descStr];
    descLbl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    descLbl.textColor =
        item.enabled
            ? NSColor.secondaryLabelColor
            : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.74];
    descLbl.usesSingleLineMode = NO;
    descLbl.cell.wraps = YES;
    descLbl.cell.scrollable = NO;
    descLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    descLbl.maximumNumberOfLines = 2;
    descLbl.preferredMaxLayoutWidth = textMaxW;
    NSSize dFit = [descLbl sizeThatFits:NSMakeSize(textMaxW, 32.0)];
    CGFloat dH = std::min<CGFloat>(30.0, std::max<CGFloat>(15.0, std::ceil(dFit.height)));
    // Center description cleanly in the lower band [34 .. 70].
    CGFloat descY = 34.0 + std::floor((34.0 - dH) * 0.5);
    descLbl.frame = NSMakeRect(64.0, descY, textMaxW, dH);
    [card addSubview:descLbl];

    y += kCardH + 10.0;
  }

  _listDoc.frame = NSMakeRect(
      0, 0, availW,
      std::max<CGFloat>(_listScroll.bounds.size.height, y + 18.0));
  [_cardsHoverTrail syncCanvasBounds];

  if (!_activeDetailExtId.empty()) {
    [self rebuildDetailViewForExtensionId:_activeDetailExtId];
  }
}

@end

@interface LightExtensionsManagerMenuBridge : NSObject
+ (void)openForBrowserPtr:(NSValue*)browserValue;
+ (void)openForProfilePtr:(NSValue*)profileValue;
@end

namespace {
LightExtensionsManagerWindowController* __strong g_ext_manager = nil;

void ShowExtManagerImpl(Profile* profile, BrowserWindowInterface* browser) {
  if (!profile && browser) {
    profile = browser->GetProfile();
  }
  if (!g_ext_manager) {
    g_ext_manager = [[LightExtensionsManagerWindowController alloc]
        initWithProfile:profile
                browser:browser];
  } else {
    [g_ext_manager updateProfile:profile browser:browser];
  }
  [g_ext_manager showWindow];
}
}  // namespace

@implementation LightExtensionsManagerMenuBridge
+ (void)openForBrowserPtr:(NSValue*)browserValue {
  BrowserWindowInterface* browser =
      static_cast<BrowserWindowInterface*>(browserValue.pointerValue);
  ShowExtManagerImpl(browser ? browser->GetProfile() : nullptr, browser);
}
+ (void)openForProfilePtr:(NSValue*)profileValue {
  Profile* profile = static_cast<Profile*>(profileValue.pointerValue);
  ShowExtManagerImpl(profile, nullptr);
}
@end

// static
void LightExtensionsManagerController::ShowForBrowser(
    BrowserWindowInterface* browser) {
  ShowExtManagerImpl(browser ? browser->GetProfile() : nullptr, browser);
}

// static
void LightExtensionsManagerController::ShowForProfile(Profile* profile) {
  ShowExtManagerImpl(profile, nullptr);
}
