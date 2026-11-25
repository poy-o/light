// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <memory>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/ui/extensions/extension_dialog_utils.h"
#include "chrome/grit/generated_resources.h"
#include "extensions/browser/ui_util.h"
#include "extensions/buildflags/buildflags.h"
#include "extensions/common/constants.h"
#include "ui/base/interaction/element_identifier.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/models/dialog_model.h"
#include "ui/gfx/image/image_skia_operations.h"

#if BUILDFLAG(IS_MAC)
#include "chrome/browser/ui/views/frame/light_glass_modal_mac.h"
#endif

static_assert(BUILDFLAG(ENABLE_EXTENSIONS_CORE));

namespace {

DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kCheckboxId);

// The implementation of the uninstall dialog.
class ExtensionUninstallDialogImpl
    : public extensions::ExtensionUninstallDialog {
 public:
  ExtensionUninstallDialogImpl(
      Profile* profile,
      gfx::NativeWindow parent,
      extensions::ExtensionUninstallDialog::Delegate* delegate);
  ExtensionUninstallDialogImpl(const ExtensionUninstallDialogImpl&) = delete;
  ExtensionUninstallDialogImpl& operator=(const ExtensionUninstallDialogImpl&) =
      delete;
  ~ExtensionUninstallDialogImpl() override;

  // Forwards that the dialog has been accepted to the delegate.
  void DialogAccepted();
  // Reports a canceled dialog to the delegate (unless accepted).
  void DialogClosing();

 private:
  void Show() override;
  void Close() override;

  // Pointer to the DialogModel for the dialog. This is cleared when the dialog
  // is being closed and OnDialogClosed is reported. As such it prevents access
  // to the dialog after it's been closed, as well as preventing multiple
  // reports of OnDialogClosed.
  raw_ptr<ui::DialogModel> dialog_model_ = nullptr;
#if BUILDFLAG(IS_MAC)
  void* light_glass_handle_ = nullptr;
#endif

  // WeakPtrs because the associated dialog may outlive |this|, which is owned
  // by the caller of extensions::ExtensionsUninstallDialog::Create().
  base::WeakPtrFactory<ExtensionUninstallDialogImpl> weak_ptr_factory_{this};
};

ExtensionUninstallDialogImpl::ExtensionUninstallDialogImpl(
    Profile* profile,
    gfx::NativeWindow parent,
    extensions::ExtensionUninstallDialog::Delegate* delegate)
    : extensions::ExtensionUninstallDialog(profile, parent, delegate) {}

ExtensionUninstallDialogImpl::~ExtensionUninstallDialogImpl() {
#if BUILDFLAG(IS_MAC)
  if (light_glass_handle_) {
    void* handle = light_glass_handle_;
    light_glass_handle_ = nullptr;
    LightCloseGlassExtensionUninstallPopup(handle);
  }
#endif
  if (dialog_model_) {
    dialog_model_->host()->Close();
  }
  CHECK(!dialog_model_, base::NotFatalUntil::M162);
}

void ExtensionUninstallDialogImpl::Show() {
#if BUILDFLAG(IS_MAC)
  {
    std::u16string title = l10n_util::GetStringFUTF16(
        IDS_EXTENSION_PROMPT_UNINSTALL_TITLE,
        extensions::ui_util::GetFixupExtensionNameForUIDisplay(
            extension()->name()));
    std::u16string subtitle;
    if (triggering_extension()) {
      subtitle = l10n_util::GetStringFUTF16(
          IDS_EXTENSION_PROMPT_UNINSTALL_TRIGGERED_BY_EXTENSION,
          extensions::ui_util::GetFixupExtensionNameForUIDisplay(
              triggering_extension()->name()));
    }
    std::u16string checkbox_label;
    if (ShouldShowCheckbox()) {
      checkbox_label =
          triggering_extension()
              ? l10n_util::GetStringFUTF16(
                    IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE_FROM_EXTENSION,
                    extensions::ui_util::GetFixupExtensionNameForUIDisplay(
                        extension()->name()))
              : l10n_util::GetStringUTF16(
                    IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE);
    }
    gfx::ImageSkia resized = gfx::ImageSkiaOperations::CreateResizedImage(
        icon(), skia::ImageOperations::ResizeMethod::RESIZE_GOOD,
        gfx::Size(extension_misc::EXTENSION_ICON_SMALL,
                  extension_misc::EXTENSION_ICON_SMALL));
    light_glass_handle_ = LightShowGlassExtensionUninstallPopup(
        parent(), title, subtitle, checkbox_label, resized,
        base::BindOnce(
            [](base::WeakPtr<ExtensionUninstallDialogImpl> self, bool accepted,
               bool checkbox_checked) {
              if (!self) {
                return;
              }
              self->light_glass_handle_ = nullptr;
              if (accepted) {
                self->OnDialogClosed(
                    checkbox_checked
                        ? CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED
                        : CLOSE_ACTION_UNINSTALL);
              } else {
                self->OnDialogClosed(CLOSE_ACTION_CANCELED);
              }
            },
            weak_ptr_factory_.GetWeakPtr()));
    if (light_glass_handle_) {
      return;
    }
  }
#endif
  ui::DialogModel::Builder dialog_builder;
  dialog_builder.SetInternalName("ExtensionUninstallDialog")
      .SetTitle(l10n_util::GetStringFUTF16(
          IDS_EXTENSION_PROMPT_UNINSTALL_TITLE,
          extensions::ui_util::GetFixupExtensionNameForUIDisplay(
              extension()->name())))
      .OverrideShowCloseButton(false)
      .SetDialogDestroyingCallback(
          base::BindOnce(&ExtensionUninstallDialogImpl::DialogClosing,
                         weak_ptr_factory_.GetWeakPtr()))
      .SetIcon(ui::ImageModel::FromImageSkia(
          gfx::ImageSkiaOperations::CreateResizedImage(
              icon(), skia::ImageOperations::ResizeMethod::RESIZE_GOOD,
              gfx::Size(extension_misc::EXTENSION_ICON_SMALL,
                        extension_misc::EXTENSION_ICON_SMALL))))
      .AddOkButton(base::BindOnce(&ExtensionUninstallDialogImpl::DialogAccepted,
                                  weak_ptr_factory_.GetWeakPtr()),
                   ui::DialogModel::Button::Params()
                       .SetLabel(l10n_util::GetStringUTF16(
                           IDS_EXTENSION_PROMPT_UNINSTALL_BUTTON))
                       .SetId(kOkButtonElementId))
      .AddCancelButton(
          base::DoNothing() /* Cancel is covered by WindowClosingCallback */,
          ui::DialogModel::Button::Params().SetId(kCancelButtonElementId));

  if (triggering_extension()) {
    dialog_builder.AddParagraph(
        ui::DialogModelLabel(
            l10n_util::GetStringFUTF16(
                IDS_EXTENSION_PROMPT_UNINSTALL_TRIGGERED_BY_EXTENSION,
                extensions::ui_util::GetFixupExtensionNameForUIDisplay(
                    triggering_extension()->name())))
            .set_is_secondary()
            .set_allow_character_break());
  }

  if (ShouldShowCheckbox()) {
    std::u16string checkbox_label =
        triggering_extension()
            ? l10n_util::GetStringFUTF16(
                  IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE_FROM_EXTENSION,
                  extensions::ui_util::GetFixupExtensionNameForUIDisplay(
                      extension()->name()))
            : l10n_util::GetStringUTF16(
                  IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE);

    dialog_builder.AddCheckbox(kCheckboxId,
                               ui::DialogModelLabel(checkbox_label));
  }

  std::unique_ptr<ui::DialogModel> dialog_model = dialog_builder.Build();
  dialog_model_ = dialog_model.get();

  ShowDialog(parent(), extension()->id(), std::move(dialog_model));
}

void ExtensionUninstallDialogImpl::Close() {
#if BUILDFLAG(IS_MAC)
  if (light_glass_handle_) {
    void* handle = light_glass_handle_;
    light_glass_handle_ = nullptr;
    LightCloseGlassExtensionUninstallPopup(handle);
    return;
  }
#endif
  CHECK(dialog_model_, base::NotFatalUntil::M162);
  dialog_model_->host()->Close();
}

void ExtensionUninstallDialogImpl::DialogAccepted() {
  CHECK(dialog_model_, base::NotFatalUntil::M162);
  const bool checkbox_is_checked =
      ShouldShowCheckbox() &&
      dialog_model_->GetCheckboxByUniqueId(kCheckboxId)->is_checked();
  dialog_model_ = nullptr;
  OnDialogClosed(checkbox_is_checked
                     ? CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED
                     : CLOSE_ACTION_UNINSTALL);
}

void ExtensionUninstallDialogImpl::DialogClosing() {
  if (!dialog_model_) {
    return;
  }
  dialog_model_ = nullptr;
  OnDialogClosed(CLOSE_ACTION_CANCELED);
}

}  // namespace

DEFINE_CLASS_ELEMENT_IDENTIFIER_VALUE(extensions::ExtensionUninstallDialog,
                                      kCancelButtonElementId);
DEFINE_CLASS_ELEMENT_IDENTIFIER_VALUE(extensions::ExtensionUninstallDialog,
                                      kOkButtonElementId);

// static
std::unique_ptr<extensions::ExtensionUninstallDialog>
extensions::ExtensionUninstallDialog::Create(Profile* profile,
                                             gfx::NativeWindow parent,
                                             Delegate* delegate) {
  return std::make_unique<ExtensionUninstallDialogImpl>(profile, parent,
                                                        delegate);
}
