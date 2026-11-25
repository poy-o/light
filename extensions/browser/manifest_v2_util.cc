// Copyright 2024 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "extensions/browser/manifest_v2_util.h"

#include "extensions/buildflags/buildflags.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"

static_assert(BUILDFLAG(ENABLE_EXTENSIONS_CORE));

namespace extensions::manifest_v2_util {

bool IsExtensionAffected(const Extension& extension) {
  return IsExtensionAffected(extension.manifest_version(), extension.GetType(),
                             extension.location());
}

bool IsExtensionAffected(int manifest_version,
                         Manifest::Type manifest_type,
                         mojom::ManifestLocation manifest_location) {
  // Light: Manifest V2 extensions are fully supported and unaffected.
  return false;
}

}  // namespace extensions::manifest_v2_util
