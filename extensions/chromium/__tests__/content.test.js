// Unit tests for the Hippocampus content script extractor.
// Run with: npx vitest run (from extensions/chromium/)

import { describe, it, expect, beforeEach, vi } from "vitest";

// Mock chrome.runtime + chrome.extension before importing.
// `inIncognitoContext` defaults to false here; individual tests flip it.
globalThis.chrome = {
  runtime: {
    sendMessage: vi.fn(),
  },
  extension: {
    inIncognitoContext: false,
  },
};

// Module-eval-time globals: content.js touches `window.location.href`,
// `document`, and `history` at top level. Stand up minimal stubs here
// so the `await import` below doesn't throw; tests override these in
// `setupDOM()`.
globalThis.window = {
  location: { href: "https://example.com/page" },
  addEventListener: () => {},
};
globalThis.document = {
  title: "",
  body: { innerText: "" },
  visibilityState: "visible",
  addEventListener: () => {},
  querySelector: () => null,
};
globalThis.history = {
  pushState: () => {},
  replaceState: () => {},
};

// Mock DOM globals
function setupDOM(opts = {}) {
  const {
    href = "https://example.com/page",
    bodyText = "Hello world",
    title = "Example Page",
    metaDesc = null,
    ogTitle = null,
  } = opts;

  Object.defineProperty(globalThis, "window", {
    value: {
      location: { href },
      addEventListener: vi.fn(),
    },
    writable: true,
    configurable: true,
  });

  Object.defineProperty(globalThis, "document", {
    value: {
      title,
      body: { innerText: bodyText },
      visibilityState: "visible",
      addEventListener: vi.fn(),
      querySelector: (sel) => {
        if (sel === 'meta[name="description"]' && metaDesc) {
          return { content: metaDesc };
        }
        if (sel === 'meta[property="og:title"]' && ogTitle) {
          return { content: ogTitle };
        }
        return null;
      },
    },
    writable: true,
    configurable: true,
  });

  globalThis.history = {
    pushState: vi.fn(),
    replaceState: vi.fn(),
  };
}

// Re-import the module functions for testing
const {
  extractPageContent,
  isBlockedURL,
  isIncognitoContext,
  isTopFrame,
  MAX_TEXT_LENGTH,
} = await import("../content.js");

describe("isBlockedURL", () => {
  it("blocks data: URLs", () => {
    expect(isBlockedURL("data:text/html,<h1>test</h1>")).toBe(true);
  });

  it("blocks chrome: URLs", () => {
    expect(isBlockedURL("chrome://settings")).toBe(true);
  });

  it("blocks chrome-extension: URLs", () => {
    expect(isBlockedURL("chrome-extension://abc/popup.html")).toBe(true);
  });

  it("blocks about: URLs", () => {
    expect(isBlockedURL("about:blank")).toBe(true);
  });

  it("blocks file: URLs", () => {
    expect(isBlockedURL("file:///home/user/doc.html")).toBe(true);
  });

  it("blocks null/empty", () => {
    expect(isBlockedURL(null)).toBe(true);
    expect(isBlockedURL("")).toBe(true);
  });

  it("allows http/https", () => {
    expect(isBlockedURL("https://example.com")).toBe(false);
    expect(isBlockedURL("http://localhost:3000")).toBe(false);
  });
});

describe("extractPageContent", () => {
  beforeEach(() => {
    setupDOM();
  });

  it("extracts basic page content", () => {
    const result = extractPageContent();
    expect(result).not.toBeNull();
    expect(result.url).toBe("https://example.com/page");
    expect(result.title).toBe("Example Page");
    expect(result.text).toBe("Hello world");
    expect(result.ts_us).toBeGreaterThan(0);
  });

  it("extracts meta description", () => {
    setupDOM({ metaDesc: "A description" });
    const result = extractPageContent();
    expect(result.meta_description).toBe("A description");
  });

  it("extracts og:title", () => {
    setupDOM({ ogTitle: "OG Title" });
    const result = extractPageContent();
    expect(result.og_title).toBe("OG Title");
  });

  it("returns null for blocked URLs", () => {
    setupDOM({ href: "chrome://settings" });
    const result = extractPageContent();
    expect(result).toBeNull();
  });

  it("truncates text at 200K chars", () => {
    const longText = "a".repeat(MAX_TEXT_LENGTH + 1000);
    setupDOM({ bodyText: longText });
    const result = extractPageContent();
    expect(result.text.length).toBe(MAX_TEXT_LENGTH);
  });

  it("NEVER reads form input values", () => {
    // The content script reads document.body.innerText, which does NOT
    // include input.value or textarea.value — those are form state, not
    // rendered text. This test documents the invariant.
    setupDOM({ bodyText: "visible text only" });
    const result = extractPageContent();
    expect(result.text).toBe("visible text only");
    // No access to any .value property
  });
});

describe("MAX_TEXT_LENGTH", () => {
  it("is 200000", () => {
    expect(MAX_TEXT_LENGTH).toBe(200000);
  });
});

describe("isTopFrame (SH Fork E1 — all_frames:true)", () => {
  // The content script runs once per frame with `all_frames: true`.
  // `window === window.top` discriminates the top-level frame from any
  // sub-frame. Tests stub `window.top` directly (sync iframes can't be
  // set up under happy-dom in vitest without spawning a real iframe).

  beforeEach(() => {
    setupDOM();
  });

  it("returns true when window === window.top (top frame)", () => {
    // setupDOM() created globalThis.window without a `.top` field —
    // assign it to itself to mimic Chromium's top-frame invariant
    // (window.top points to the same Window object).
    globalThis.window.top = globalThis.window;
    expect(isTopFrame()).toBe(true);
  });

  it("returns false when window !== window.top (sub-frame)", () => {
    // Mimic a sub-frame: window.top is a DIFFERENT object (the parent
    // tab's top-level Window). The strict-equality check fails →
    // isTopFrame returns false → background.js treats this as a
    // sub-frame and the native host applies the iframe title prefix.
    globalThis.window.top = { id: "different-window-object" };
    expect(isTopFrame()).toBe(false);
  });

  it("fails closed (returns false) if window.top access throws", () => {
    // Older Chromium builds raise SecurityError on cross-origin
    // window.top property access. The content script must treat that
    // as a sub-frame (fail-closed) so no iframe content escapes the
    // attribution prefix.
    Object.defineProperty(globalThis.window, "top", {
      get() {
        throw new Error("SecurityError: cross-origin access");
      },
      configurable: true,
    });
    expect(isTopFrame()).toBe(false);
  });
});

describe("extractPageContent — per-frame attribution (SH Fork E1)", () => {
  beforeEach(() => {
    setupDOM();
  });

  it("payload carries is_top_frame:true for the top frame", () => {
    globalThis.window.top = globalThis.window;
    const result = extractPageContent();
    expect(result.is_top_frame).toBe(true);
  });

  it("payload carries is_top_frame:false for a sub-frame", () => {
    globalThis.window.top = { id: "parent-window" };
    const result = extractPageContent();
    expect(result.is_top_frame).toBe(false);
  });

  it("sub-frame extracts its own DOM (cross-origin iframe parity)", () => {
    // Mimic a sub-frame whose URL + title + body are all different
    // from the parent. SH Fork E1's whole point is to get this content
    // — without all_frames:true, the iframe's `document.body.innerText`
    // never reaches the brain.
    setupDOM({
      href: "https://js.stripe.com/v3/elements-inner-payment.html",
      bodyText: "Card number: ****  $42.00 USD",
      title: "Stripe Elements — Payment",
    });
    globalThis.window.top = { id: "parent-window" };
    const result = extractPageContent();
    expect(result).not.toBeNull();
    expect(result.is_top_frame).toBe(false);
    expect(result.url).toBe(
      "https://js.stripe.com/v3/elements-inner-payment.html",
    );
    expect(result.title).toBe("Stripe Elements — Payment");
    expect(result.text).toBe("Card number: ****  $42.00 USD");
  });

  it("sub-frame in incognito still returns null (CSO defense-in-depth)", () => {
    // The CSO invariant is FOUR layers — the iframe should bail at
    // layer 2 (`inIncognitoContext`) regardless of frame depth.
    globalThis.chrome.extension.inIncognitoContext = true;
    globalThis.window.top = { id: "parent-window" };
    const result = extractPageContent();
    expect(result).toBeNull();
    // Reset for sibling tests.
    globalThis.chrome.extension.inIncognitoContext = false;
  });

  it("sub-frame on a blocked protocol still returns null", () => {
    // The BLOCKED_PROTOCOLS check runs per-frame. A `data:` iframe
    // self-terminates and never sendMessage()s, so no event escapes
    // the content-script boundary.
    setupDOM({ href: "data:text/html,<h1>hi</h1>" });
    globalThis.window.top = { id: "parent-window" };
    const result = extractPageContent();
    expect(result).toBeNull();
  });
});

describe("incognito exclusion (CSO invariant)", () => {
  beforeEach(() => {
    setupDOM();
    // Reset to non-incognito between tests so failures are obvious.
    globalThis.chrome.extension.inIncognitoContext = false;
  });

  it("isIncognitoContext returns false in normal context", () => {
    expect(isIncognitoContext()).toBe(false);
  });

  it("isIncognitoContext returns true when the chrome flag is set", () => {
    globalThis.chrome.extension.inIncognitoContext = true;
    expect(isIncognitoContext()).toBe(true);
  });

  it("extractPageContent returns null in an incognito context", () => {
    globalThis.chrome.extension.inIncognitoContext = true;
    const result = extractPageContent();
    expect(result).toBeNull();
  });

  it("extractPageContent works again once the flag clears", () => {
    globalThis.chrome.extension.inIncognitoContext = true;
    expect(extractPageContent()).toBeNull();
    globalThis.chrome.extension.inIncognitoContext = false;
    expect(extractPageContent()).not.toBeNull();
  });
});
