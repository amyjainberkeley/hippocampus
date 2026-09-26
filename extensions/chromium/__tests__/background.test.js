import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

let messageListener;
const postMessage = vi.fn();
const sendNativeMessage = vi.fn();
const disconnectListeners = [];

globalThis.chrome = {
  runtime: {
    sendNativeMessage,
    connectNative: vi.fn(() => ({
      onDisconnect: { addListener: (listener) => disconnectListeners.push(listener) },
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
    for (const disconnect of disconnectListeners.splice(0)) disconnect();
    postMessage.mockClear();
    sendNativeMessage.mockReset();
    globalThis.chrome.runtime.connectNative.mockClear();
  });

  it("authorizes without sending page content to the native boundary", () => {
    sendNativeMessage.mockImplementation((_name, message, callback) => {
      expect(message).toEqual({
        type: "capture_authorization",
        incognito: false,
      });
      callback({ status: "authorized" });
    });
    const sendResponse = vi.fn();

    const keepsChannelOpen = messageListener(
      { type: "capture_authorization" },
      sender({ incognito: false }),
      sendResponse,
    );

    expect(keepsChannelOpen).toBe(true);
    expect(sendResponse).toHaveBeenCalledWith({ authorized: true });
  });

  it("rejects authorization before native messaging for unknown privacy state", () => {
    const sendResponse = vi.fn();

    messageListener(
      { type: "capture_authorization" },
      sender({}),
      sendResponse,
    );

    expect(sendNativeMessage).not.toHaveBeenCalled();
    expect(sendResponse).toHaveBeenCalledWith({ authorized: false });
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

  it("connects a fresh native host after the prior host disconnects", () => {
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});
    expect(globalThis.chrome.runtime.connectNative).toHaveBeenCalledOnce();
    expect(disconnectListeners).toHaveLength(1);

    disconnectListeners[0]();
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});

    expect(globalThis.chrome.runtime.connectNative).toHaveBeenCalledTimes(2);
    expect(postMessage).toHaveBeenCalledTimes(2);
  });

  it("does not let an old disconnect clear the replacement host", () => {
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});
    const oldDisconnect = disconnectListeners[0];
    oldDisconnect();
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});

    oldDisconnect();
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});

    expect(globalThis.chrome.runtime.connectNative).toHaveBeenCalledTimes(2);
    expect(postMessage).toHaveBeenCalledTimes(3);
  });

  it("retries after native host connection construction throws", () => {
    globalThis.chrome.runtime.connectNative.mockImplementationOnce(() => {
      throw new Error("native host unavailable");
    });

    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});
    messageListener(pageContentMessage(), sender({ incognito: false }), () => {});

    expect(globalThis.chrome.runtime.connectNative).toHaveBeenCalledTimes(2);
    expect(postMessage).toHaveBeenCalledOnce();
  });

  it("declares the extension unavailable in incognito windows", () => {
    const manifestPath = fileURLToPath(new URL("../manifest.json", import.meta.url));
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

    expect(manifest.incognito).toBe("not_allowed");
  });
});
