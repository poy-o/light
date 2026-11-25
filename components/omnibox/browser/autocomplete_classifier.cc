// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/omnibox/browser/autocomplete_classifier.h"

#include <utility>

#include "base/auto_reset.h"
#include "base/feature_list.h"
#include "base/strings/utf_string_conversions.h"
#include "base/trace_event/trace_event.h"
#include "build/android_buildflags.h"
#include "build/build_config.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_provider.h"
#include "components/omnibox/browser/omnibox_field_trial.h"
#include "components/omnibox/common/omnibox_feature_configs.h"
#include "components/omnibox/common/omnibox_features.h"
#include "extensions/buildflags/buildflags.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_ANDROID)
#include "base/android/device_info.h"
#endif

#if !BUILDFLAG(IS_IOS)
#include "components/history_clusters/core/config.h"  // nogncheck
#endif

#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
#include "extensions/common/extension_features.h"  // nogncheck
#endif

AutocompleteClassifier::AutocompleteClassifier(
    std::unique_ptr<AutocompleteController> controller,
    std::unique_ptr<AutocompleteSchemeClassifier> scheme_classifier)
    : controller_(std::move(controller)),
      scheme_classifier_(std::move(scheme_classifier)),
      inside_classify_(false) {}

AutocompleteClassifier::~AutocompleteClassifier() {
  // We should only reach here after Shutdown() has been called.
  DCHECK(!controller_);
}

void AutocompleteClassifier::Shutdown() {
  controller_.reset();
}

// static
int AutocompleteClassifier::DefaultOmniboxProviders(bool is_low_memory_device) {
  // Light: strictly local, non-AI providers only (no zero-suggest network
  // calls, no AI Mode / contextual / featured / on-device / remote telemetry).
  return static_cast<int>(
      AutocompleteProvider::Type::kKeyword |
      AutocompleteProvider::Type::kOpenTab |
      AutocompleteProvider::Type::kZeroSuggestLocalHistory |
      AutocompleteProvider::Type::kBookmark |
      AutocompleteProvider::Type::kBuiltin |
      AutocompleteProvider::Type::kHistoryQuick |
      AutocompleteProvider::Type::kHistoryUrl |
      AutocompleteProvider::Type::kShortcuts |
      AutocompleteProvider::Type::kHistoryFuzzy |
      AutocompleteProvider::Type::kCalculator |
      AutocompleteProvider::Type::kVerbatimMatch);
}

void AutocompleteClassifier::Classify(
    const std::u16string& text,
    bool in_keyword_mode,
    bool allow_exact_keyword_match,
    metrics::OmniboxEventProto::PageClassification page_classification,
    AutocompleteMatch* match,
    GURL* alternate_nav_url) {
  TRACE_EVENT1("omnibox", "AutocompleteClassifier::Classify", "text",
               base::UTF16ToUTF8(text));
  DCHECK(!inside_classify_);
  base::AutoReset<bool> reset(&inside_classify_, true);
  AutocompleteInput input(text, page_classification, *scheme_classifier_);
  input.set_prevent_inline_autocomplete(true);
  input.set_in_keyword_mode(in_keyword_mode);
  input.set_allow_exact_keyword_match(allow_exact_keyword_match);
  input.set_omit_asynchronous_matches(true);
  controller_->Start(input);
  DCHECK(controller_->done());

  auto* default_match = controller_->result().default_match();
  if (!default_match) {
    if (alternate_nav_url)
      *alternate_nav_url = GURL();
    return;
  }

  *match = *default_match;
  if (alternate_nav_url) {
    *alternate_nav_url = AutocompleteResult::ComputeAlternateNavUrl(
        input, *match, controller_->autocomplete_provider_client());
  }
}
