// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_TAB_CONTAINERS_MAC_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_TAB_CONTAINERS_MAC_H_

#include <optional>
#include <string>
#include <vector>

#include "url/gurl.h"

class BrowserWindowInterface;
class Profile;

namespace content {
class WebContents;
}

struct LightTabContainer {
  std::string id;
  std::string name;
  std::string symbol;
  std::string color_hex;
  bool in_memory = false;
};

// Returns the configured list of Tab Containers (seeding built-in defaults
// including Private, Personal, Work, and Shopping on first run).
std::vector<LightTabContainer> LightGetTabContainers();

// Looks up a Tab Container by its stable identifier.
std::optional<LightTabContainer> LightFindTabContainer(const std::string& id);

// Persists the list of Tab Containers and broadcasts
// LightTabContainersDidChangeNotification.
void LightSaveTabContainers(const std::vector<LightTabContainer>& containers);

// Adds or updates a Tab Container.
void LightAddTabContainer(const LightTabContainer& container);

// Deletes a Tab Container by id.
void LightDeleteTabContainer(const std::string& id);

// Resets Tab Containers back to the built-in defaults.
void LightResetDefaultTabContainers();

// Clears all site data (cookies, storage, cache, service workers) stored in
// the isolated StoragePartition belonging to `container_id`.
void LightClearTabContainerData(Profile* profile,
                                const std::string& container_id);

// Opens a new tab in `browser` whose WebContents is permanently locked to the
// isolated StoragePartition for `container_id` (via
// SiteInstance::CreateForFixedStoragePartition).
content::WebContents* LightOpenNewTabInContainer(
    BrowserWindowInterface* browser,
    const std::string& container_id,
    const GURL& initial_url = GURL());

// Returns the container id for `web_contents`, or an empty string if the tab
// uses the default browser storage partition.
std::string LightGetTabContainerIdForWebContents(
    content::WebContents* web_contents);

#endif  // CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_TAB_CONTAINERS_MAC_H_
