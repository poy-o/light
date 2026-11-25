// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/tabs/pinned_tab_codec.h"

#include <stddef.h>

#include <utility>

#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/pref_names.h"
#include "components/pref_registry/pref_registry_syncable.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/security_principal.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"

using content::NavigationEntry;

namespace {

// Key used in dictionaries for the url.
const char kURL[] = "url";
const char kLightContainerId[] = "light_container_id";

// Returns a base::DictValue representing the supplied StartupTab.
base::DictValue EncodeTab(const GURL& url,
                          const std::string& light_container_id = "") {
  base::DictValue dict;
  dict.Set(kURL, url.spec());
  if (!light_container_id.empty()) {
    dict.Set(kLightContainerId, light_container_id);
  }
  return dict;
}

// Encodes all the pinned tabs from `browser` into `serialized_tabs`.
void EncodePinnedTabs(BrowserWindowInterface* browser,
                      base::ListValue& serialized_tabs) {
  const TabStripModel* const tab_model = browser->GetTabStripModel();
  for (const tabs::TabInterface* tab : *tab_model) {
    if (!tab->IsPinned()) {
      break;
    }

    content::WebContents* web_contents = tab->GetContents();
    std::string container_id;
    if (content::RenderFrameHost* rfh = web_contents->GetPrimaryMainFrame()) {
      if (content::SiteInstance* si = rfh->GetSiteInstance()) {
        const auto& cfg =
            si->GetSecurityPrincipal().GetStoragePartitionConfig();
        if (!cfg.is_default() &&
            cfg.partition_domain() == "light_container") {
          // Never persist ephemeral/wipe-on-close container tabs even if pinned.
          if (cfg.in_memory()) {
            continue;
          }
          container_id = cfg.partition_name();
          const size_t pos = container_id.find("#g");
          if (pos != std::string::npos) {
            container_id.erase(pos);
          }
        }
      }
    }
    NavigationEntry* entry =
        web_contents->GetController().GetLastCommittedEntry();
    if (entry) {
      serialized_tabs.Append(EncodeTab(entry->GetURL(), container_id));
    }
  }
}

// Decodes the previously written values in `value` to `tab`, returning true
// on success.
std::optional<StartupTab> DecodeTab(const base::DictValue& value) {
  const std::string* const url_string = value.FindString(kURL);
  if (!url_string) {
    return std::nullopt;
  }
  StartupTab tab(GURL(*url_string), StartupTab::Type::kPinned);
  if (const std::string* cid = value.FindString(kLightContainerId)) {
    tab.light_container_id = *cid;
  }
  return tab;
}

}  // namespace

// static
void PinnedTabCodec::RegisterProfilePrefs(
    user_prefs::PrefRegistrySyncable* registry) {
  registry->RegisterListPref(prefs::kPinnedTabs);
}

// static
void PinnedTabCodec::WritePinnedTabs(Profile* profile) {
  PrefService* prefs = profile->GetPrefs();
  if (!prefs) {
    return;
  }

  base::ListValue values;
  ForEachCurrentBrowserWindowInterfaceOrderedByActivation(
      [profile, &values](BrowserWindowInterface* browser) {
        if (browser->GetType() == BrowserWindowInterface::TYPE_NORMAL &&
            browser->GetProfile() == profile) {
          EncodePinnedTabs(browser, values);
        }
        return true;
      });
  prefs->SetList(prefs::kPinnedTabs, std::move(values));
}

// static
void PinnedTabCodec::WritePinnedTabs(Profile* profile,
                                     const StartupTabs& tabs) {
  PrefService* prefs = profile->GetPrefs();
  if (!prefs) {
    return;
  }

  ScopedListPrefUpdate update(prefs, prefs::kPinnedTabs);
  base::ListValue& values = update.Get();
  values.clear();
  for (const auto& tab : tabs) {
    values.Append(EncodeTab(tab.url, tab.light_container_id));
  }
}

// static
StartupTabs PinnedTabCodec::ReadPinnedTabs(Profile* profile) {
  PrefService* prefs = profile->GetPrefs();
  if (!prefs) {
    return {};
  }

  StartupTabs results;

  for (const auto& serialized_tab : prefs->GetList(prefs::kPinnedTabs)) {
    if (!serialized_tab.is_dict()) {
      continue;
    }
    std::optional<StartupTab> tab = DecodeTab(serialized_tab.GetDict());
    if (tab.has_value()) {
      results.push_back(tab.value());
    }
  }

  return results;
}
