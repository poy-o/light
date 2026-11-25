// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/views/frame/light_tab_containers_mac.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <memory>
#include <utility>

#include "base/functional/callback_helpers.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/security_principal.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "ui/base/page_transition_types.h"

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

namespace {

NSString* const kContainersDefaultsKey = @"LightTabContainers";
NSString* const kContainersChangedNotification =
    @"LightTabContainersDidChangeNotification";
constexpr char kLightContainerPartitionDomain[] = "light_container";
const void* const kLightTabContainerUserDataKey =
    &kLightTabContainerUserDataKey;

class LightTabContainerUserData : public base::SupportsUserData::Data {
 public:
  explicit LightTabContainerUserData(std::string container_id)
      : container_id_(std::move(container_id)) {}
  const std::string& container_id() const { return container_id_; }

 private:
  std::string container_id_;
};

std::vector<LightTabContainer> DefaultContainers() {
  return {
      {"private", "Private", "eye.slash", "#AF52DE", true},
      {"personal", "Personal", "person", "#0A84FF", false},
      {"work", "Work", "briefcase", "#FF9F0A", false},
      {"shopping", "Shopping", "bag", "#30D158", false},
  };
}

void PostContainersChanged() {
  [NSNotificationCenter.defaultCenter
      postNotificationName:kContainersChangedNotification
                    object:nil];
}

}  // namespace

std::vector<LightTabContainer> LightGetTabContainers() {
  NSObject* raw =
      [NSUserDefaults.standardUserDefaults objectForKey:kContainersDefaultsKey];
  if (![raw isKindOfClass:[NSArray class]]) {
    auto defaults = DefaultContainers();
    LightSaveTabContainers(defaults);
    return defaults;
  }

  NSArray* arr = (NSArray*)raw;
  std::vector<LightTabContainer> result;
  result.reserve(arr.count);
  for (id entry in arr) {
    if (![entry isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSDictionary* dict = (NSDictionary*)entry;
    NSString* cid = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    NSString* name =
        [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : @"";
    NSString* symbol =
        [dict[@"symbol"] isKindOfClass:[NSString class]] ? dict[@"symbol"] : @"globe";
    NSString* colorHex =
        [dict[@"color"] isKindOfClass:[NSString class]] ? dict[@"color"] : @"#0A84FF";
    BOOL inMemory =
        [dict[@"inMemory"] isKindOfClass:[NSNumber class]]
            ? [(NSNumber*)dict[@"inMemory"] boolValue]
            : NO;
    if (cid.length == 0 || name.length == 0) {
      continue;
    }
    result.push_back({base::SysNSStringToUTF8(cid),
                      base::SysNSStringToUTF8(name),
                      base::SysNSStringToUTF8(symbol),
                      base::SysNSStringToUTF8(colorHex), inMemory != NO});
  }
  return result;
}

std::optional<LightTabContainer> LightFindTabContainer(const std::string& id) {
  if (id.empty()) {
    return std::nullopt;
  }
  for (const auto& c : LightGetTabContainers()) {
    if (c.id == id) {
      return c;
    }
  }
  return std::nullopt;
}

void LightSaveTabContainers(const std::vector<LightTabContainer>& containers) {
  NSMutableArray<NSDictionary*>* arr =
      [NSMutableArray arrayWithCapacity:containers.size()];
  for (const auto& c : containers) {
    if (c.id.empty() || c.name.empty()) {
      continue;
    }
    [arr addObject:@{
      @"id" : base::SysUTF8ToNSString(c.id),
      @"name" : base::SysUTF8ToNSString(c.name),
      @"symbol" : base::SysUTF8ToNSString(c.symbol.empty() ? "globe" : c.symbol),
      @"color" : base::SysUTF8ToNSString(c.color_hex.empty() ? "#0A84FF" : c.color_hex),
      @"inMemory" : @(c.in_memory),
    }];
  }
  [NSUserDefaults.standardUserDefaults setObject:arr
                                          forKey:kContainersDefaultsKey];
  PostContainersChanged();
}

void LightAddTabContainer(const LightTabContainer& container) {
  auto list = LightGetTabContainers();
  bool updated = false;
  for (auto& existing : list) {
    if (existing.id == container.id) {
      existing = container;
      updated = true;
      break;
    }
  }
  if (!updated) {
    list.push_back(container);
  }
  LightSaveTabContainers(list);
}

void LightDeleteTabContainer(const std::string& id) {
  auto list = LightGetTabContainers();
  std::erase_if(list, [&](const LightTabContainer& c) { return c.id == id; });
  LightSaveTabContainers(list);
}

void LightResetDefaultTabContainers() {
  LightSaveTabContainers(DefaultContainers());
}

void LightClearTabContainerData(Profile* profile,
                                const std::string& container_id) {
  if (!profile || container_id.empty()) {
    return;
  }
  auto container = LightFindTabContainer(container_id);
  const bool in_memory = container ? container->in_memory : false;
  content::StoragePartitionConfig config =
      content::StoragePartitionConfig::Create(
          profile, kLightContainerPartitionDomain, container_id, in_memory);
  if (content::StoragePartition* partition =
          profile->GetStoragePartition(config, /*can_create=*/false)) {
    partition->ClearData(content::StoragePartition::REMOVE_DATA_MASK_ALL,
                         blink::StorageKey(), base::Time(), base::Time::Max(),
                         base::DoNothing());
  }
}

content::WebContents* LightOpenNewTabInContainer(
    BrowserWindowInterface* browser,
    const std::string& container_id,
    const GURL& initial_url) {
  if (!browser) {
    return nullptr;
  }
  Profile* profile = browser->GetProfile();
  TabStripModel* model = browser->GetTabStripModel();
  if (!profile || !model) {
    return nullptr;
  }
  auto container = LightFindTabContainer(container_id);
  if (!container) {
    return nullptr;
  }

  const GURL target_url =
      initial_url.is_valid() ? initial_url : GURL("about:blank");
  content::StoragePartitionConfig config =
      content::StoragePartitionConfig::Create(
          profile, kLightContainerPartitionDomain, container->id,
          container->in_memory);
  scoped_refptr<content::SiteInstance> site_instance =
      content::SiteInstance::CreateForFixedStoragePartition(
          profile, target_url, config);

  content::WebContents::CreateParams create_params(profile,
                                                   std::move(site_instance));
  std::unique_ptr<content::WebContents> wc =
      content::WebContents::Create(create_params);
  if (!wc) {
    return nullptr;
  }

  wc->SetUserData(kLightTabContainerUserDataKey,
                  std::make_unique<LightTabContainerUserData>(container->id));
  content::WebContents* raw_wc = wc.get();

  model->AppendWebContents(std::move(wc), /*foreground=*/true);

  content::NavigationController::LoadURLParams load_params(target_url);
  load_params.transition_type = ui::PAGE_TRANSITION_TYPED;
  raw_wc->GetController().LoadURLWithParams(load_params);
  return raw_wc;
}

std::string LightGetTabContainerIdForWebContents(
    content::WebContents* web_contents) {
  if (!web_contents) {
    return std::string();
  }
  if (auto* data = static_cast<LightTabContainerUserData*>(
          web_contents->GetUserData(kLightTabContainerUserDataKey))) {
    return data->container_id();
  }
  if (content::RenderFrameHost* rfh = web_contents->GetPrimaryMainFrame()) {
    if (content::SiteInstance* si = rfh->GetSiteInstance()) {
      const auto& config = si->GetSecurityPrincipal().GetStoragePartitionConfig();
      if (!config.is_default() &&
          config.partition_domain() == kLightContainerPartitionDomain) {
        return config.partition_name();
      }
    }
  }
  return std::string();
}
