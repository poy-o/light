// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_SIDEBAR_CONTROLLER_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_SIDEBAR_CONTROLLER_H_

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/native_ui_types.h"

class BrowserView;

#ifdef __OBJC__
@class NSWindow;
#else
class NSWindow;
#endif

// Bridges Chromium's BrowserView / TabStripModel / WebContents state to a
// native AppKit macOS 26+ Liquid Glass (NSGlassEffectView) floating sidebar.
class LightGlassSidebarBridge {
 public:
  static std::unique_ptr<LightGlassSidebarBridge> Create(
      BrowserView* browser_view,
      NSWindow* window);
  static int GetPinnedSidebarWidthForBrowserView(
      const BrowserView* browser_view);
  static gfx::Insets GetContentFrameInsetsForBrowserView(
      const BrowserView* browser_view);

  virtual ~LightGlassSidebarBridge() = default;

  virtual void FocusAddressBar(bool select_all) = 0;
  virtual void ShowSpotlightCommandBar() = 0;
  virtual void ShowFindBar() = 0;
  virtual void FindNext(bool forward) = 0;
  virtual void ToggleCollapsed() = 0;
  virtual bool IsCollapsed() const = 0;
};

// Locks the sidebar open & fills the Extensions icon while an extension popup
// (e.g. ExtensionPopup) is open, returning the screen-coordinate anchor rect
// immediately to the right of the sidebar in Cocoa coordinates (or empty rect).
gfx::Rect LightBeginSidebarExtensionPopup(gfx::NativeWindow browser_window);
void LightEndSidebarExtensionPopup(gfx::NativeWindow browser_window);

#endif  // CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_SIDEBAR_CONTROLLER_H_
