// Copyright 2016 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/metrics/enabled_state_provider.h"

#include "base/base_switches.h"
#include "base/command_line.h"

namespace metrics {

namespace {
// Some browser_tests enable metrics reporting independent of the presence of
// kForceFieldTrials:
// - MetricsServiceBrowserFilesTest.FilesRemain
// - MetricsInternalsUIBrowserTestWithLog.All
bool g_ignore_force_field_trials_for_testing = false;
}  // namespace

bool EnabledStateProvider::IsReportingEnabled() const {
  return false;
}

void EnabledStateProvider::SetIgnoreForceFieldTrialsForTesting(
    bool ignore_trials) {
  g_ignore_force_field_trials_for_testing = ignore_trials;
}

}  // namespace metrics
