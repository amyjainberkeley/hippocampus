import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

let messageListener;
const postMessage = vi.fn();

globalThis.chrome = {
  runtime: {
    connectNative: vi.fn(() => ({
      onDisconnect: { addListener: vi.fn() },
      postMessage,
    })),
    onMessage: {
      addListener(listener) {
        messageListener = listener;
      },
    },
  },
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Chrome/140.0" },
  configurable: true,
});

const { isPersistableTab } = await import("../background.js");

function pageContentMessage() {
  return {
    type: "page_content",
    payload: {
      url: "https://example.com/project",
      title: "Project",
      text: "ordinary work",
      ts_us: 1,
      is_top_frame: true,
    },
  };
}

function sender(tab) {
  return {
    tab: { id: 7, url: "https://example.com/project", ...tab },
    frameId: 0,
    url: "https://example.com/project",
  };
}

describe("Chromium private-context relay", () => {
  beforeEach(() => {
    postMessage.mockClear();
    globalThis.chrome.runtime.connectNative.mockClear();
  });

  it("accepts only an explicitly non-incognito tab", () => {
    expect(isPersistableTab({ incognito: false })).toBe(true);
    expect(isPersistableTab({ incognito: true })).toBe(false);
    expect(isPersistableTab({})).toBe(false);
    expect(isPersistableTab(undefined)).toBe(false);
  });

  it("does not connect or relay when the browser omits classification", () => {
    messageListener(pageContentMessage(), sender({}), () => {});

    expect(globalThis.chrome.runtime.connectNative).not.toHaveBeenCalled();
    expect(postMessage).not.toHaveBeenCalled();
  });

  it("relays ordinary tabs with an explicit false classification", () => {
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});

    expect(postMessage).toHaveBeenCalledOnce();
    expect(postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ incognito: false, text: "ordinary work" }),
    );
  });

  it("declares the extension unavailable in incognito windows", () => {
    const manifestPath = fileURLToPath(new URL("../manifest.json", import.meta.url));
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

    expect(manifest.incognito).toBe("not_allowed");
  });
});
