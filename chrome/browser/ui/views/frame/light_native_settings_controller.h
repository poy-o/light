// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_NATIVE_SETTINGS_CONTROLLER_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_NATIVE_SETTINGS_CONTROLLER_H_

#include <string>

class BrowserWindowInterface;
class Profile;

// Opens or focuses the unified native macOS System Settings-style window for
// both Chromium preferences and Custom (Light) UI settings.
class LightNativeSettingsController {
 public:
  static void ShowForBrowser(BrowserWindowInterface* browser);
  static void ShowForBrowserToCategory(BrowserWindowInterface* browser,
                                       const std::string& category_title);
  static void ShowForProfile(Profile* profile);
};

#endif  // CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_NATIVE_SETTINGS_CONTROLLER_H_
