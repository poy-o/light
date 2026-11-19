// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_MODAL_MAC_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_MODAL_MAC_H_

#include <memory>

#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "extensions/browser/install_prompt_data.h"

namespace views {
class Widget;
}

struct AuthenticatorRequestDialogModel;

// Applies native macOS Liquid Glass (NSGlassEffectView on macOS 26+,
// NSVisualEffectView fallback) as the backdrop of a Chromium Views modal
// Widget, making its window and BubbleFrameView transparent so the glass
// shows through.
void LightApplyLiquidGlassToWidget(views::Widget* widget,
                                   float corner_radius = 18.0f);

// Presents a native macOS Liquid Glass "Add extension?" dialog for standard
// extension install prompts. Returns true if the native dialog was shown and
// took ownership of |done_callback|; returns false to fall back to Views.
bool LightShowGlassExtensionInstallDialog(
    std::unique_ptr<ExtensionInstallPromptShowParams>& show_params,
    ExtensionInstallPrompt::DoneCallback& done_callback,
    std::unique_ptr<extensions::InstallPromptData>& prompt);

// Shows or updates a native macOS Liquid Glass panel for WebAuthn passkey /
// mechanism selection steps (replacing the Views dialog and artwork). Returns
// true if the native panel handled the current step (caller should keep
// |widget| hidden); returns false to fall back to the Views dialog.
bool LightUpdateGlassWebAuthnDialog(AuthenticatorRequestDialogModel* model,
                                    views::Widget* parent_widget);

// Dismisses any active native Liquid Glass WebAuthn panel associated with
// |model|.
void LightDismissGlassWebAuthnDialog(AuthenticatorRequestDialogModel* model);

#endif  // CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_MODAL_MAC_H_
