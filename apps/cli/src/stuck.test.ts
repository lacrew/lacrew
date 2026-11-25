import assert from "node:assert/strict";
import { test } from "node:test";
import { buildStuckUrl, redact, stepReached } from "./stuck.js";

test("step names the command but never flags or their values", () => {
  assert.equal(stepReached(["deploy", "--rpc", "http://user:pw@host"]), "lacrew deploy");
  assert.equal(stepReached(["flows", "save", "f.json"]), "lacrew flows save");
  assert.equal(stepReached([]), "lacrew");
});

test("redacts keys, secret env assignments and URL credentials", () => {
  const key = "0x" + "ab".repeat(32);
  const out = redact(`bad ${key} PRIVATE_KEY=abc https://u:p@rpc.example`);
  assert.ok(!out.includes(key));
  assert.ok(!out.includes("=abc"));
  assert.ok(!out.includes("u:p"));
});

test("builds a prefilled quickstart issue link", () => {
  const url = new URL(
    buildStuckUrl({ argv: ["deploy", "--anvil"], errorLines: ["boom"], cliVersion: "0.1.0" }),
  );
  assert.equal(
    url.origin + url.pathname,
    "https://github.com/marc-aurele-besner/lacrew/issues/new",
  );
  assert.equal(url.searchParams.get("template"), "quickstart.yml");
  assert.equal(url.searchParams.get("step"), "lacrew deploy");
  assert.equal(url.searchParams.get("error"), "boom");
  assert.equal(url.searchParams.get("cli_version"), "0.1.0");
});
