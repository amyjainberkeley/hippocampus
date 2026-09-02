const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const safariRoot = path.resolve(__dirname, "..");

function installGlobals() {
  global.browser = {
    extension: { inIncognitoContext: false },
    runtime: {
      sendMessage() {},
      sendNativeMessage() { return Promise.resolve(); },
      onMessage: { addListener() {} },
    },
  };
  global.chrome = undefined;
  global.window = {
    location: { href: "https://example.com/private-plan" },
    addEventListener() {},
  };
  global.window.top = global.window;
  global.document = {
    title: "Private plan",
    body: { innerText: "must never be extracted" },
    visibilityState: "visible",
    addEventListener() {},
    querySelector() { return null; },
  };
  global.history = {
    pushState() {},
    replaceState() {},
  };
  global.setTimeout = () => 1;
  global.clearTimeout = () => {};
}

installGlobals();
const content = require(path.join(safariRoot, "content.js"));
const background = require(path.join(safariRoot, "background.js"));

test("Safari rejects private context before extracting page text", () => {
  browser.extension.inIncognitoContext = true;
  assert.equal(content.isPrivateContext(), true);
  assert.equal(content.extractPageContent(), null);
});

test("Safari manifest forbids private-window execution", () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(safariRoot, "manifest.json"), "utf8"),
  );
  assert.equal(manifest.incognito, "not_allowed");
});

test("Safari background only accepts an explicitly non-private tab", () => {
  assert.equal(background.isPersistableTab({ incognito: false }), true);
  assert.equal(background.isPersistableTab({ incognito: true }), false);
  assert.equal(background.isPersistableTab({}), false);
  assert.equal(background.isPersistableTab(null), false);
});
