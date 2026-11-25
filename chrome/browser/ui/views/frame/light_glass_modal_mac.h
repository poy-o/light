// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_MODAL_MAC_H_
#define CHROME_BROWSER_UI_VIEWS_FRAME_LIGHT_GLASS_MODAL_MAC_H_

#include <memory>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "components/permissions/permission_prompt.h"
#include "extensions/browser/install_prompt_data.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/native_ui_types.h"

namespace content {
class WebContents;
}

namespace views {
class Widget;
}

struct AuthenticatorRequestDialogModel;

// Applies native macOS Liquid Glass (NSGlassEffectView on macOS 26+,
// NSVisualEffectView fallback) as the backdrop of a Chromium Views modal
// Widget, making its window and BubbleFrameView transparent so the glass
// shows through.
void LightApplyLiquidGlassToWidget(views::Widget* widget,
                                   float corner_radius = 15.0f);

// Presents a native macOS Liquid Glass "Add extension?" dialog for standard
// extension install prompts. Returns true if the native dialog was shown and
// took ownership of |done_callback|; returns false to fall back to Views.
bool LightShowGlassExtensionInstallDialog(
    std::unique_ptr<ExtensionInstallPromptShowParams>& show_params,
    ExtensionInstallPrompt::DoneCallback& done_callback,
    std::unique_ptr<extensions::InstallPromptData>& prompt);

// Shows a sidebar-bound Liquid Glass popup ("<Extension> has been added to
// Light") immediately to the right of the sidebar, opening the sidebar if
// auto-hidden and filling the sidebar extensions icon while shown.
bool LightShowGlassExtensionPostInstallPopup(
    gfx::NativeWindow parent_window,
    const std::u16string& title,
    const std::vector<std::u16string>& paragraphs,
    const gfx::ImageSkia& icon,
    base::OnceClosure on_manage_shortcuts,
    base::OnceClosure on_closed);

// Shows a sidebar-bound Liquid Glass popup ("Remove <Extension>?") immediately
// to the right of the sidebar, opening the sidebar if auto-hidden and filling
// the sidebar extensions icon while shown. Returns an opaque handle for
// programmatic closure via LightCloseGlassExtensionUninstallPopup.
void* LightShowGlassExtensionUninstallPopup(
    gfx::NativeWindow parent_window,
    const std::u16string& title,
    const std::u16string& subtitle,
    const std::u16string& checkbox_label,
    const gfx::ImageSkia& icon,
    base::OnceCallback<void(bool accepted, bool checkbox_checked)> on_result);

void LightCloseGlassExtensionUninstallPopup(void* handle);

// Creates a native macOS Liquid Glass PermissionPrompt for site permissions
// (camera, microphone, location, notifications, clipboard, etc.).
std::unique_ptr<permissions::PermissionPrompt> LightCreateGlassPermissionPrompt(
    content::WebContents* web_contents,
    permissions::PermissionPrompt::Delegate* delegate);

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
