// Copyright 2024 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {html} from '//resources/lit/v3_0/lit.rollup.js';

import type {ChromeUrlsAppElement} from './app.js';

export function getHtml(this: ChromeUrlsAppElement) {
  return html`
<h2>Light About — Internal URLs</h2>
<ul>
  ${this.webuiUrlInfos_.map(item => html`
    ${this.isChromeUrlsUrl_(item) ? html`
      <li>
        <a href="#">light://about</a>
      </li>
    ` : html`
      ${item.enabled ? html`
        <li>
          <a href="${item.url}">${this.toLightUrl_(item.url)}</a>
        </li>
      ` : html`
        <li>${this.toLightUrl_(item.url)}</li>
      `}
    `}
  `)}
</ul>
${this.internalUrlInfos_.length ? html`
  <h2 id="internal-debugging-pages">Internal Debugging Page URLs</h2>
  <p id="debug-pages-description">
    <span>Internal debugging pages are currently </span>
    <span class="bold">${this.getDebugPagesEnabledText_()}</span><span>.</span>
  </p>
  <cr-button @click="${this.onToggleDebugPagesClick_}"
      ?disabled="${this.debugPagesButtonDisabled_}">
    ${this.getDebugPagesToggleButtonLabel_()}
  </cr-button>
  <ul>
    ${this.internalUrlInfos_.map(item => html`
      ${this.isInternalUiEnabled_(item) ? html`
        <li>
          <a href="${item.url}">${this.toLightUrl_(item.url)}</a>
        </li>
      ` : html`
        <li>${this.toLightUrl_(item.url)}</li>
      `}
    `)}
  </ul>
` : ''}
${this.commandUrls_.length ? html`
  <h2>Command URLs for Debug</h2>
  <p>
    The following URLs are for debugging purposes only. Because they crash or
    hang the renderer, they're not linked directly; you can type them into the
    address bar if you need them.
  </p>
  <ul>
    ${this.commandUrls_.map(item => html`
      <li>${this.toLightUrl_(item)}</li>
    `)}
  </ul>
` : ''}`;
}
