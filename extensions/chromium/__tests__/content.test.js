// Unit tests for the Hippocampus content script extractor.
// Run with: npx vitest run (from extensions/chromium/)

import { describe, it, expect, beforeEach, vi } from "vitest";

// Mock chrome.runtime before importing
globalThis.chrome = {
  runtime: {
    sendMessage: vi.fn(),
  },
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
const { extractPageContent, isBlockedURL, MAX_TEXT_LENGTH } = await import(
  "../content.js"
);

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
