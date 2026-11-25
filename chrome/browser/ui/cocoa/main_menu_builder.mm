// Copyright 2018 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/cocoa/main_menu_builder.h"

#include <AvailabilityVersions.h>

#include "base/feature_list.h"
#include "base/i18n/rtl.h"
#include "base/mac/mac_util.h"
#include "build/branding_buildflags.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_features.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/feedback/report_unsafe_site_dialog.h"
#include "chrome/browser/ui/cocoa/accelerators_cocoa.h"
#include "chrome/browser/ui/cocoa/history_menu_bridge.h"
#include "chrome/browser/ui/toolbar/app_menu_model.h"
#include "chrome/browser/ui/ui_features.h"
#include "chrome/common/chrome_features.h"
#include "chrome/grit/branded_strings.h"
#include "chrome/grit/generated_resources.h"
#include "components/strings/grit/components_strings.h"
#include "components/web_distiller/core/web_distiller_features.h"
#include "ui/base/accelerators/platform_accelerator_cocoa.h"
#import "ui/base/cocoa/macos27_sdk.h"
#include "ui/base/l10n/l10n_util.h"
#import "ui/base/l10n/l10n_util_mac.h"
#include "ui/strings/grit/ui_strings.h"

@interface LightExtensionsMenuDelegate : NSObject <NSMenuDelegate>
@end

@implementation LightExtensionsMenuDelegate
- (void)menuNeedsUpdate:(NSMenu*)menu {
  Class bridgeCls = NSClassFromString(@"LightExtensionsMenuBridge");
  SEL sel = NSSelectorFromString(@"populateExtensionsMenu:");
  if (bridgeCls && [bridgeCls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [bridgeCls performSelector:sel withObject:menu];
#pragma clang diagnostic pop
  }
}
@end

namespace chrome {
namespace {

LightExtensionsMenuDelegate* GetExtensionsMenuDelegate() {
  static LightExtensionsMenuDelegate* __strong delegate =
      [[LightExtensionsMenuDelegate alloc] init];
  return delegate;
}

using Item = internal::MenuItemBuilder;

// Capitalization Policy (go/chrome-capitalization):
// Native macOS system menu bar items follow Apple Human Interface
// Guidelines (HIG) and must use Title Case (via `_MAC` string variants or
// `use_titlecase`).
NSMenuItem* BuildAppMenu(NSApplication* nsapp,
                         id app_delegate,
                         const std::u16string& product_name,
                         bool is_pwa,
                         bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      // NB: The IDS_APP_MENU_PRODUCT_NAME string is not actually used to
      // determine what is displayed in bold in the menu bar as the app menu
      // title. The Info.plist's CFBundleName value is what is actually used.
      Item(IDS_APP_MENU_PRODUCT_NAME)
          .tag(IDC_CHROME_MENU)
          .submenu({
              Item(IDS_ABOUT_MAC)
                  .string_format_1(product_name)
                  .tag(IDC_ABOUT)
                  .target(app_delegate)
                  .action(@selector(orderFrontStandardAboutPanel:))
                  .sf_symbol(@"info.circle"),
              Item().is_separator(),
              Item(IDS_PREFERENCES)
                  .tag(IDC_OPTIONS)
                  .target(app_delegate)
                  .action(@selector(showPreferences:))
                  .sf_symbol(@"gearshape")
                  .remove_if(is_pwa),
              Item(IDS_PREFERENCES)
                  .command_id(IDC_WEB_APP_SETTINGS)
                  .sf_symbol(@"gearshape")
                  .remove_if(!is_pwa),
              Item().is_separator(),
              Item(IDS_CLEAR_BROWSING_DATA_MAC)
                  .command_id(IDC_CLEAR_BROWSING_DATA)
                  .sf_symbol(@"trash")
                  .remove_if(is_pwa),
              Item(IDS_IMPORT_SETTINGS_MENU_MAC)
                  .command_id(IDC_IMPORT_SETTINGS)
                  .sf_symbol(@"square.and.arrow.down")
                  .remove_if(is_pwa),
              Item().is_separator(),
              Item(IDS_SERVICES_MAC)
                  .tag(-1)
                  .submenu({}),
              Item().is_separator(),
              Item(IDS_HIDE_APP_MAC)
                  .string_format_1(product_name)
                  .tag(IDC_HIDE_APP)
                  .action(@selector(hide:))
                  .sf_symbol(@"eye.slash"),
              Item(IDS_HIDE_OTHERS_MAC)
                  .action(@selector(hideOtherApplications:))
                  .key_equivalent(@"h", NSEventModifierFlagCommand |
                                            NSEventModifierFlagOption)
                  .sf_symbol(@"eye.slash.circle"),
              Item(IDS_SHOW_ALL_MAC)
                  .action(@selector(unhideAllApplications:))
                  .sf_symbol(@"eye"),
              Item().is_separator(),
              Item(IDS_CONFIRM_TO_QUIT_OPTION)
                  .target(app_delegate)
                  .action(@selector(toggleConfirmToQuit:))
                  .sf_symbol(@"exclamationmark.triangle")
                  .remove_if(is_pwa),
              Item().is_separator(),
              Item(IDS_EXIT_MAC)
                  .string_format_1(product_name)
                  .tag(IDC_EXIT)
                  .target(nsapp)
                  .action(@selector(terminate:))
                  .sf_symbol(@"power"),
          })
          .Build();
  // clang-format on

  NSMenuItem* services_item = [item.submenu itemWithTag:-1];
  services_item.tag = 0;

  nsapp.servicesMenu = services_item.submenu;

  return item;
}

NSMenuItem* BuildFileMenu(NSApplication* nsapp,
                          id app_delegate,
                          const std::u16string& product_name,
                          bool is_pwa,
                          bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      Item(IDS_FILE_MENU_MAC)
          .tag(IDC_FILE_MENU)
          .submenu({
              Item(IDS_NEW_TAB_MAC)
                  .command_id(IDC_NEW_TAB)
                  .sf_symbol(@"plus.square")
                  .remove_if(is_pwa),
              Item(IDS_NEW_WINDOW_MAC)
                  .command_id(IDC_NEW_WINDOW)
                  .sf_symbol(@"macwindow.badge.plus"),
              Item(IDS_NEW_INCOGNITO_WINDOW_MAC)
                  .command_id(IDC_NEW_INCOGNITO_WINDOW)
                  .sf_symbol(@"eyeglasses")
                  .remove_if(is_pwa),
              Item(IDS_NEW_ISOLATED_WINDOW_MAC)
                  .command_id(IDC_NEW_ISOLATED_WINDOW)
                  .sf_symbol(@"lock.shield")
                  .remove_if(is_pwa),
              Item(IDS_REOPEN_CLOSED_TABS_MAC)
                  .command_id(IDC_RESTORE_TAB)
                  .sf_symbol(@"arrow.uturn.backward")
                  .remove_if(is_pwa),
              Item(IDS_OPEN_FILE_MAC)
                  .command_id(IDC_OPEN_FILE)
                  .sf_symbol(@"doc")
                  .remove_if(is_pwa),
              Item(IDS_OPEN_LOCATION_MAC)
                  .command_id(IDC_FOCUS_LOCATION)
                  .sf_symbol(@"magnifyingglass")
                  .remove_if(is_pwa),
              Item().is_separator(),
              Item(IDS_CLOSE_WINDOW_MAC)
                  .tag(IDC_CLOSE_WINDOW)
                  .action(@selector(performClose:))
                  .sf_symbol(@"xmark.rectangle"),
              Item(IDS_CLOSE_ALL_WINDOWS_MAC)
                  .action(@selector(closeAll:))
                  .is_alternate()
                  .key_equivalent(@"W", NSEventModifierFlagCommand |
                                            NSEventModifierFlagOption)
                  .sf_symbol(@"xmark.rectangle.portrait"),
              Item(IDS_CLOSE_TAB_MAC)
                  .command_id(IDC_CLOSE_TAB)
                  .sf_symbol(@"xmark")
                  .remove_if(is_pwa),
              Item(IDS_SAVE_PAGE_MAC)
                  .command_id(IDC_SAVE_PAGE)
                  .sf_symbol(@"square.and.arrow.down"),
              Item().is_separator()
                  .remove_if(is_pwa),
              Item(IDS_SHARE_MAC)
                  .sf_symbol(@"square.and.arrow.up")
                  .remove_if(is_pwa),
              Item().is_separator(),
              Item(IDS_PRINT)
                  .command_id(IDC_PRINT)
                  .sf_symbol(@"printer"),
              Item(IDS_PRINT_USING_SYSTEM_DIALOG_MAC)
                  .command_id(IDC_BASIC_PRINT)
                  .is_alternate()
                  .sf_symbol(@"printer")
                  .remove_if(is_pwa),
          })
          .Build();
  // clang-format on

  return item;
}

NSMenuItem* BuildEditMenu(NSApplication* nsapp,
                          id app_delegate,
                          const std::u16string& product_name,
                          bool is_pwa,
                          bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      Item(IDS_EDIT_MENU_MAC)
          .tag(IDC_EDIT_MENU)
          .submenu({
              Item(IDS_EDIT_UNDO_MAC)
                  .tag(IDC_CONTENT_CONTEXT_UNDO)
                  .action(@selector(undo:))
                  .sf_symbol(@"arrow.uturn.backward"),
              Item(IDS_EDIT_REDO_MAC)
                  .tag(IDC_CONTENT_CONTEXT_REDO)
                  .action(@selector(redo:))
                  .sf_symbol(@"arrow.uturn.forward"),
              Item().is_separator(),
              Item(IDS_CUT_MAC)
                  .tag(IDC_CONTENT_CONTEXT_CUT)
                  .action(@selector(cut:))
                  .sf_symbol(@"scissors"),
              Item(IDS_COPY_MAC)
                  .tag(IDC_CONTENT_CONTEXT_COPY)
                  .action(@selector(copy:))
                  .sf_symbol(@"doc.on.doc"),
              Item(IDS_PASTE_MAC)
                  .tag(IDC_CONTENT_CONTEXT_PASTE)
                  .action(@selector(paste:))
                  .sf_symbol(@"doc.on.clipboard"),
              Item(IDS_PASTE_MATCH_STYLE_MAC)
                  .tag(IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE)
                  .action(@selector(pasteAndMatchStyle:))
                  .sf_symbol(@"doc.on.clipboard"),
              Item(IDS_PASTE_MATCH_STYLE_MAC)
                  .action(@selector(pasteAndMatchStyle:))
                  .is_alternate()
                  .key_equivalent(@"V", NSEventModifierFlagCommand |
                                            NSEventModifierFlagOption)
                  .sf_symbol(@"doc.on.clipboard"),
              Item(IDS_EDIT_DELETE_MAC)
                  .tag(IDC_CONTENT_CONTEXT_DELETE)
                  .action(@selector(delete:))
                  .sf_symbol(@"delete.left"),
              Item(IDS_EDIT_SELECT_ALL_MAC)
                  .tag(IDC_CONTENT_CONTEXT_SELECTALL)
                  .action(@selector(selectAll:))
                  .sf_symbol(@"selection.pin.in.out"),
              Item().is_separator(),
              Item(IDS_EDIT_FIND_SUBMENU_MAC)
                  .tag(IDC_FIND_MENU)
                  .sf_symbol(@"magnifyingglass")
                  .submenu({
                      Item(IDS_EDIT_SEARCH_WEB_MAC)
                          .command_id(IDC_FOCUS_SEARCH)
                          .sf_symbol(@"globe"),
                      Item().is_separator(),
                      Item(IDS_EDIT_FIND_MAC)
                          .command_id(IDC_FIND)
                          .sf_symbol(@"magnifyingglass"),
                      Item(IDS_EDIT_FIND_NEXT_MAC)
                          .command_id(IDC_FIND_NEXT)
                          .sf_symbol(@"chevron.down"),
                      Item(IDS_EDIT_FIND_PREVIOUS_MAC)
                          .command_id(IDC_FIND_PREVIOUS)
                          .sf_symbol(@"chevron.up"),
                      Item(IDS_EDIT_USE_SELECTION_MAC)
                          .action(@selector(copyToFindPboard:))
                          .key_equivalent(@"e", NSEventModifierFlagCommand)
                          .sf_symbol(@"text.magnifyingglass"),
                      Item(IDS_EDIT_JUMP_TO_SELECTION_MAC)
                          .action(@selector(centerSelectionInVisibleArea:))
                          .key_equivalent(@"j", NSEventModifierFlagCommand)
                          .sf_symbol(@"arrow.down.to.line"),
              }),
              Item(IDS_EDIT_SPELLING_GRAMMAR_MAC)
                  .tag(IDC_SPELLCHECK_MENU)
                  .sf_symbol(@"textformat.abc.dottedunderline")
                  .submenu({
                      Item(IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC)
                          .action(@selector(showGuessPanel:))
                          .key_equivalent(@":", NSEventModifierFlagCommand),
                      Item(IDS_EDIT_CHECK_DOCUMENT_MAC)
                          .action(@selector(checkSpelling:))
                          .key_equivalent(@";", NSEventModifierFlagCommand),
                      Item(IDS_EDIT_CHECK_SPELLING_TYPING_MAC)
                          .action(@selector
                                  (toggleContinuousSpellChecking:)),
                      Item(IDS_EDIT_CHECK_GRAMMAR_MAC)
                          .action(@selector(toggleGrammarChecking:)),
                  }),
              Item(IDS_EDIT_SUBSTITUTIONS_MAC)
                  .sf_symbol(@"text.quote")
                  .submenu({
                      Item(IDS_EDIT_SHOW_SUBSTITUTIONS_MAC)
                          .action(@selector(orderFrontSubstitutionsPanel:)),
                      Item().is_separator(),
                      Item(IDS_EDIT_SMART_QUOTES_MAC)
                          .action(@selector(toggleAutomaticQuoteSubstitution:)),
                      Item(IDS_EDIT_SMART_DASHES_MAC)
                          .action(@selector(toggleAutomaticDashSubstitution:)),
                      Item(IDS_EDIT_TEXT_REPLACEMENT_MAC)
                          .action(@selector(toggleAutomaticTextReplacement:)),
              }),
              Item(IDS_EDIT_TRANSFORMATIONS_MAC)
                  .sf_symbol(@"textformat")
                  .submenu({
                      Item(IDS_EDIT_MAKE_UPPERCASE_MAC)
                          .action(@selector(uppercaseWord:)),
                      Item(IDS_EDIT_MAKE_LOWERCASE_MAC)
                          .action(@selector(lowercaseWord:)),
                      Item(IDS_EDIT_CAPITALIZE_MAC)
                          .action(@selector(capitalizeWord:)),
              }),
              Item(IDS_SPEECH_MAC)
                  .sf_symbol(@"waveform")
                  .submenu({
                      Item(IDS_SPEECH_START_SPEAKING_MAC)
                          .action(@selector(startSpeaking:)),
                      Item(IDS_SPEECH_STOP_SPEAKING_MAC)
                          .action(@selector(stopSpeaking:)),
              }),
            // The "Start Dictation..." and "Emoji & Symbols" items are
            // inserted by AppKit.
          })
          .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildViewMenu(NSApplication* nsapp,
                          id app_delegate,
                          const std::u16string& product_name,
                          bool is_pwa,
                          bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      Item(IDS_VIEW_MENU_MAC)
          .tag(IDC_VIEW_MENU)
          .submenu({
              Item(IDS_BOOKMARK_BAR_ALWAYS_SHOW_MAC)
                  .command_id(IDC_SHOW_BOOKMARK_BAR)
                  .sf_symbol(@"book")
                  .remove_if(is_pwa),
              Item(IDS_TOGGLE_FULLSCREEN_TOOLBAR_MAC)
                  .command_id(IDC_TOGGLE_FULLSCREEN_TOOLBAR)
                  .sf_symbol(@"menubar.rectangle"),
              Item(IDS_CONTEXT_MENU_SHOW_FULL_URLS)
                  .command_id(IDC_SHOW_FULL_URLS)
                  .sf_symbol(@"link"),
              Item(IDS_CONTEXT_MENU_SHOW_SEARCH_TOOLS)
                  .command_id(IDC_SHOW_SEARCH_TOOLS)
                  .sf_symbol(@"magnifyingglass"),
              Item(IDS_SWITCH_TO_VERTICAL_TAB_MAC)
                  .command_id(IDC_TOGGLE_VERTICAL_TABS)
                  .sf_symbol(@"sidebar.left"),
              Item(IDS_VERTICAL_TABS_VIEW_MENU_TOGGLE_COLLAPSE)
                  .command_id(IDC_TOGGLE_VERTICAL_TABS_COLLAPSE)
                  .key_equivalent(@"L", NSEventModifierFlagCommand)
                  .sf_symbol(@"sidebar.leading"),
              Item(IDS_CUSTOMIZE_TOUCH_BAR)
                  .tag(IDC_CUSTOMIZE_TOUCH_BAR)
                  .action(@selector(toggleTouchBarCustomizationPalette:))
                  .sf_symbol(@"slider.horizontal.3")
                  .remove_if(is_pwa),
              Item().is_separator(),
              Item(IDS_STOP_MENU_MAC)
                  .command_id(IDC_STOP)
                  .sf_symbol(@"xmark"),
              Item(IDS_RELOAD_MENU_MAC)
                  .command_id(IDC_RELOAD)
                  .sf_symbol(@"arrow.clockwise"),
              Item(IDS_RELOAD_BYPASSING_CACHE_MENU_MAC)
                  .command_id(IDC_RELOAD_BYPASSING_CACHE)
                  .is_alternate()
                  .sf_symbol(@"arrow.clockwise"),
              Item().is_separator(),
              Item(IDS_ENTER_FULLSCREEN_MAC)
                  .tag(IDC_FULLSCREEN)
                  .action(@selector(toggleFullScreen:))
                  .sf_symbol(@"arrow.up.left.and.arrow.down.right"),
              Item(IDS_ENTER_FULLSCREEN_MAC)
                  .action(@selector(toggleFullScreen:))
                  .is_alternate()
                  .key_equivalent(@"f", NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl)
                  .sf_symbol(@"arrow.up.left.and.arrow.down.right"),
              Item(IDS_TEXT_DEFAULT_MAC)
                  .command_id(IDC_ZOOM_NORMAL)
                  .sf_symbol(@"1.magnifyingglass"),
              Item(IDS_TEXT_BIGGER_MAC)
                  .command_id(IDC_ZOOM_PLUS)
                  .sf_symbol(@"plus.magnifyingglass"),
              Item(IDS_TEXT_SMALLER_MAC)
                  .command_id(IDC_ZOOM_MINUS)
                  .sf_symbol(@"minus.magnifyingglass"),
              Item().is_separator(),
              Item(IDS_MEDIA_ROUTER_MENU_ITEM_TITLE)
                  .command_id(IDC_ROUTE_MEDIA)
                  .sf_symbol(@"airplayvideo"),
              Item().is_separator(),
              Item(IDS_DEVELOPER_MENU_MAC)
                  .tag(IDC_DEVELOPER_MENU)
                  .sf_symbol(@"chevron.left.forwardslash.chevron.right")
                  .submenu({
                      Item(IDS_VIEW_SOURCE_MAC)
                          .command_id(IDC_VIEW_SOURCE)
                          .sf_symbol(@"doc.text.magnifyingglass"),
                      Item(IDS_DEV_TOOLS_MAC)
                          .command_id(IDC_DEV_TOOLS)
                          .sf_symbol(@"wrench.and.screwdriver"),
                      Item(IDS_DEV_TOOLS_ELEMENTS_MAC)
                          .command_id(IDC_DEV_TOOLS_INSPECT)
                          .sf_symbol(@"cursorarrow.click.2"),
                      Item(IDS_DEV_TOOLS_CONSOLE_MAC)
                          .command_id(IDC_DEV_TOOLS_CONSOLE)
                          .sf_symbol(@"terminal"),
                      Item(IDS_ALLOW_JAVASCRIPT_APPLE_EVENTS_MAC)
                          .command_id(IDC_TOGGLE_JAVASCRIPT_APPLE_EVENTS)
                          .sf_symbol(@"applescript"),
                  }),
        })
        .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildHistoryMenu(NSApplication* nsapp,
                             id app_delegate,
                             const std::u16string& product_name,
                             bool is_pwa,
                             bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      Item(IDS_HISTORY_MENU_MAC)
          .tag(IDC_HISTORY_MENU)
          .submenu({
              Item(IDS_HISTORY_HOME_MAC)
                  .command_id(IDC_HOME)
                  .sf_symbol(@"house")
                  .remove_if(is_pwa),
              Item(IDS_HISTORY_BACK_MAC)
                  .command_id(IDC_BACK)
                  .sf_symbol(@"chevron.left"),
              Item(IDS_HISTORY_FORWARD_MAC)
                  .command_id(IDC_FORWARD)
                  .sf_symbol(@"chevron.right"),
              Item().is_separator()
                  .tag(HistoryMenuBridge::kRecentlyClosedSeparator)
                  .remove_if(is_pwa),
              Item(IDS_HISTORY_CLOSED_MAC)
                  .tag(HistoryMenuBridge::kRecentlyClosedTitle)
                  .is_section_header()
                  .remove_if(is_pwa),
              Item().is_separator()
                  .tag(HistoryMenuBridge::kVisitedSeparator)
                  .remove_if(is_pwa),
              Item(IDS_HISTORY_VISITED_MAC)
                  .tag(HistoryMenuBridge::kVisitedTitle)
                  .is_section_header()
                  .remove_if(is_pwa),
              Item().is_separator()
                  .tag(HistoryMenuBridge::kShowFullSeparator)
                  .remove_if(is_pwa),
              Item(IDS_HISTORY_SHOWFULLHISTORY_MAC)
                  .command_id(IDC_SHOW_HISTORY)
                  .sf_symbol(
                      @"clock.arrow.trianglehead.counterclockwise.rotate.90")
                  .remove_if(is_pwa),
          })
          .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildBookmarksMenu(NSApplication* nsapp,
                               id app_delegate,
                               const std::u16string& product_name,
                               bool is_pwa,
                               bool is_rtl) {
  if (is_pwa) {
    return nil;
  }

  const int bookmarks_manager_string_id =
      features::IsMenuSimplificationEnabled() ? IDS_BOOKMARK_MANAGER_V2_MAC
                                              : IDS_BOOKMARK_MANAGER_MAC;
  // clang-format off
  NSMenuItem* item =
      Item(IDS_BOOKMARKS_MENU)
          .tag(AppMenuModel::kBookmarksMenuPlaceholder)
          .submenu({
              Item(bookmarks_manager_string_id)
                  .command_id(IDC_SHOW_BOOKMARK_MANAGER)
                  .sf_symbol(@"book"),
              Item().is_separator()
                  .tag(IDC_BOOKMARK_THIS_TAB),
              Item(IDS_BOOKMARK_THIS_TAB_MAC)
                  .command_id(IDC_BOOKMARK_THIS_TAB)
                  .sf_symbol(@"star"),
              Item(IDS_BOOKMARK_ALL_TABS_MAC)
                  .command_id(IDC_BOOKMARK_ALL_TABS)
                  .sf_symbol(@"star.fill"),
              Item().is_separator()
                  .tag(IDC_BOOKMARK_THIS_TAB),
          })
          .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildProfilesMenu(NSApplication* nsapp,
                              id app_delegate,
                              const std::u16string& product_name,
                              bool is_pwa,
                              bool is_rtl) {
  // clang-format off
  NSMenuItem* item =
      Item(IDS_PROFILES_MENU_NAME)
          .tag(IDC_PROFILE_MAIN_MENU)
          .submenu({})
          .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildExtensionsMenu(NSApplication* nsapp,
                                id app_delegate,
                                const std::u16string& product_name,
                                bool is_pwa,
                                bool is_rtl) {
  if (is_pwa) {
    return nil;
  }

  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Extensions"
                                                action:nil
                                         keyEquivalent:@""];
  NSMenu* submenu = [[NSMenu alloc] initWithTitle:@"Extensions"];
  submenu.delegate = GetExtensionsMenuDelegate();
  NSMenuItem* manageItem = Item(IDS_SHOW_EXTENSIONS_MAC)
                               .command_id(IDC_MANAGE_EXTENSIONS)
                               .sf_symbol(@"slider.horizontal.3")
                               .Build();
  if (manageItem) {
    [submenu addItem:manageItem];
  }
  item.submenu = submenu;
  return item;
}

NSMenuItem* BuildTabMenu(NSApplication* nsapp,
                         id app_delegate,
                         const std::u16string& product_name,
                         bool is_pwa,
                         bool is_rtl) {
  if (is_pwa) {
    return nil;
  }

  // clang-format off
  NSMenuItem* item =
      Item(IDS_TAB_MENU_MAC)
          .tag(IDC_TAB_MENU)
          .submenu({
              Item(is_rtl ? IDS_TAB_CXMENU_NEWTABTOLEFT
                          : IDS_TAB_CXMENU_NEWTABTORIGHT)
                  .command_id(IDC_NEW_TAB_TO_RIGHT)
                  .sf_symbol(@"plus.square"),
              Item(IDS_TAB_CXMENU_NEWTABBELOW)
                  .command_id(IDC_NEW_TAB_TO_RIGHT)
                  .sf_symbol(@"plus.square")
                  .set_hidden(true),
              Item(IDS_NEXT_TAB_MAC)
                  .command_id(IDC_CYCLE_TO_NEXT_TAB)
                  .sf_symbol(@"chevron.right.square"),
              Item(IDS_PREV_TAB_MAC)
                  .command_id(IDC_CYCLE_TO_PREV_TAB)
                  .sf_symbol(@"chevron.left.square"),
              Item(IDS_DUPLICATE_TAB_MAC)
                  .command_id(IDC_DUPLICATE_TAB)
                  .sf_symbol(@"plus.square.on.square"),
              Item(IDS_DUPLICATE_TARGET_TAB_MAC)
                  .command_id(IDC_DUPLICATE_TARGET_TAB)
                  .is_alternate()
                  .key_equivalent(@"", NSEventModifierFlagOption)
                  .sf_symbol(@"plus.square.on.square"),
              Item(IDS_MUTE_SITE_MAC)
                  .command_id(IDC_WINDOW_MUTE_SITE)
                  .sf_symbol(@"speaker.slash"),
              Item(IDS_MUTE_TARGET_SITE_MAC)
                  .command_id(IDC_MUTE_TARGET_SITE)
                  .is_alternate()
                  .key_equivalent(@"", NSEventModifierFlagOption)
                  .sf_symbol(@"speaker.slash"),
              Item(IDS_PIN_TAB_MAC)
                  .command_id(IDC_WINDOW_PIN_TAB)
                  .sf_symbol(@"pin"),
              Item(IDS_PIN_TARGET_TAB_MAC)
                  .command_id(IDC_PIN_TARGET_TAB)
                  .is_alternate()
                  .key_equivalent(@"", NSEventModifierFlagOption)
                  .sf_symbol(@"pin"),
              Item(IDS_GROUP_TAB_MAC)
                  .command_id(IDC_WINDOW_GROUP_TAB)
                  .sf_symbol(@"rectangle.stack"),
              Item(IDS_GROUP_TARGET_TAB_MAC)
                  .command_id(IDC_GROUP_TARGET_TAB)
                  .is_alternate()
                  .key_equivalent(@"", NSEventModifierFlagOption)
                  .sf_symbol(@"rectangle.stack"),
              Item(IDS_TAB_CXMENU_CLOSEOTHERTABS)
                  .command_id(IDC_WINDOW_CLOSE_OTHER_TABS)
                  .sf_symbol(@"xmark.circle"),
              Item(is_rtl ? IDS_TAB_CXMENU_CLOSETABSTOLEFT
                          : IDS_TAB_CXMENU_CLOSETABSTORIGHT)
                  .command_id(IDC_WINDOW_CLOSE_TABS_TO_RIGHT)
                  .sf_symbol(@"arrow.right.to.line"),
              Item(IDS_TAB_CXMENU_CLOSETABSBELOW)
                  .command_id(IDC_WINDOW_CLOSE_TABS_TO_RIGHT)
                  .sf_symbol(@"arrow.down.to.line")
                  .set_hidden(true),
              Item(IDS_MOVE_TAB_TO_NEW_WINDOW)
                  .command_id(IDC_MOVE_TAB_TO_NEW_WINDOW)
                  .sf_symbol(@"macwindow.on.rectangle"),
              Item(IDS_TAB_CXMENU_ADD_TAB_TO_NEW_SPLIT)
                  .command_id(IDC_NEW_SPLIT_TAB)
                  .sf_symbol(@"rectangle.split.2x1"),
              Item(IDS_SEARCH_TABS)
                  .command_id(IDC_TAB_SEARCH)
                  .sf_symbol(@"magnifyingglass"),
              Item().is_separator(),
          })
          .Build();
  // clang-format on
  return item;
}

NSMenuItem* BuildHelpMenu(NSApplication* nsapp,
                          id app_delegate,
                          const std::u16string& product_name,
                          bool is_pwa,
                          bool is_rtl) {
  if (is_pwa) {
    return nil;
  }

  // clang-format off
  std::vector<Item> items = {};
#if BUILDFLAG(GOOGLE_CHROME_BRANDING)
  items.push_back(Item(IDS_FEEDBACK_MAC).command_id(IDC_FEEDBACK));
  bool is_profile_loaded =
      g_browser_process && g_browser_process->profile_manager() &&
      g_browser_process->profile_manager()->GetLastUsedProfileIfLoaded();
  if (is_profile_loaded && feedback::ReportUnsafeSiteDialog::IsEnabled(
                               *(g_browser_process->profile_manager()
                                     ->GetLastUsedProfileIfLoaded()))) {
    items.push_back(Item(IDS_REPORT_UNSAFE_SITE)
                        .command_id(IDC_REPORT_UNSAFE_SITE));
  }
#endif
  items.push_back(Item(IDS_HELP_MAC)
                      .string_format_1(product_name)
                      .command_id(IDC_HELP_PAGE_VIA_MENU)
                      .sf_symbol(@"questionmark.circle"));
  NSMenuItem* item =
      Item(IDS_HELP_MENU_MAC)
          .submenu(items)
          .Build();
  // clang-format on

  nsapp.helpMenu = item.submenu;
  return item;
}

}  // namespace

NSMenu* BuildMainMenu(NSApplication* nsapp,
                      id<NSApplicationDelegate> app_delegate,
                      const std::u16string& product_name,
                      bool is_pwa,
                      bool is_rtl) {
  AcceleratorsCocoa::CreateForPWA(is_pwa);

  NSMenu* main_menu = [[NSMenu alloc] initWithTitle:@""];
  for (auto* builder : {
           &BuildAppMenu,
           &BuildFileMenu,
           &BuildEditMenu,
           &BuildViewMenu,
           &BuildProfilesMenu,
           &BuildTabMenu,
           &BuildBookmarksMenu,
           &BuildExtensionsMenu,
           &BuildHistoryMenu,
           &BuildHelpMenu,
       }) {
    auto item = builder(nsapp, app_delegate, product_name, is_pwa, is_rtl);
    if (item) {
      [main_menu addItem:item];
    }
  }

  nsapp.mainMenu = main_menu;

  return main_menu;
}

NSMenuItem* BuildFileMenuForTesting(bool is_pwa) {
  NSMenu* mainMenu = BuildMainMenu(nil, nil, u"", is_pwa, /*is_rtl=*/false);

  // First is the App menu, then the File menu.
  const int kFileMenuItemIndex = 1;

  return [mainMenu itemArray][kFileMenuItemIndex];
}

namespace internal {

MenuItemBuilder::MenuItemBuilder(int string_id) : string_id_(string_id) {}

MenuItemBuilder::MenuItemBuilder(const MenuItemBuilder&) = default;

MenuItemBuilder& MenuItemBuilder::operator=(const MenuItemBuilder&) = default;

MenuItemBuilder::~MenuItemBuilder() = default;

NSMenuItem* MenuItemBuilder::Build() const {
  if (is_removed_) {
    return nil;
  }

  if (is_separator_) {
    NSMenuItem* item = [NSMenuItem separatorItem];
    if (tag_) {
      item.tag = tag_;
    }
    item.hidden = is_hidden_;
    return item;
  }

  NSString* title;
  if (!string_arg1_.empty()) {
    title = l10n_util::GetNSStringFWithFixup(string_id_, string_arg1_);
  } else {
    title = l10n_util::GetNSStringWithFixup(string_id_);
  }

  if (is_section_header_) {
    NSMenuItem* item;
    if (@available(macOS 14, *)) {
      item = [NSMenuItem sectionHeaderWithTitle:title];
    } else {
      item = [[NSMenuItem alloc] initWithTitle:title
                                        action:nil
                                 keyEquivalent:@""];
      item.enabled = NO;
    }
    if (tag_) {
      item.tag = tag_;
    }
    item.hidden = is_hidden_;
    return item;
  }

  // If the item is command-dispatched, look up the relevant key equivalent
  // from the accelerator table. Otherwise, use the builder-specified key
  // equivalent.
  NSString* key_equivalent = key_equivalent_;
  NSEventModifierFlags key_equivalent_flags = key_equivalent_flags_;
  if (tag_ != 0) {
    if (const ui::Accelerator* accelerator =
            AcceleratorsCocoa::GetInstance()->GetAcceleratorForCommand(tag_)) {
      KeyEquivalentAndModifierMask* equivalent =
          GetKeyEquivalentAndModifierMaskFromAccelerator(*accelerator);
      key_equivalent = equivalent.keyEquivalent;
      key_equivalent_flags = equivalent.modifierMask;
    }
  }

  SEL action = !submenu_.has_value() ? action_ : nil;

  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:key_equivalent];
  item.target = target_;
  item.tag = tag_;
  item.keyEquivalentModifierMask = key_equivalent_flags;
  item.alternate = is_alternate_;
  item.hidden = is_hidden_;
  if (sf_symbol_name_) {
    item.image = [NSImage imageWithSystemSymbolName:sf_symbol_name_
                           accessibilityDescription:nil];
    if (@available(macOS 27, *)) {
      item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
    }
  }

  if (submenu_.has_value()) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:title];
    for (const auto& subitem : submenu_.value()) {
      NSMenuItem* ns_subitem = subitem.Build();
      if (ns_subitem) {
        [menu addItem:ns_subitem];
      }
    }
    item.submenu = menu;
  }

  return item;
}

}  // namespace internal
}  // namespace chrome
