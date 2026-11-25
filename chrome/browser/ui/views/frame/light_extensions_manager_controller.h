// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_EXTENSIONS_MANAGER_CONTROLLER_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_EXTENSIONS_MANAGER_CONTROLLER_H_

class BrowserWindowInterface;
class Profile;

// Native macOS System Settings-style Liquid Glass popup window for managing
// installed extensions (Enable/Disable, Options, Remove, Load Unpacked,
// Install .crx, Developer Mode).
class LightExtensionsManagerController {
 public:
  static void ShowForBrowser(BrowserWindowInterface* browser);
  static void ShowForProfile(Profile* profile);
};

#endif  // CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_EXTENSIONS_MANAGER_CONTROLLER_H_
