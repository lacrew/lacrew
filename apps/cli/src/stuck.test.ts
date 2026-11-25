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

test("redacts RPC URLs down to scheme and host", () => {
  assert.equal(
    redact("URL: https://eth-sepolia.g.alchemy.com/v2/abc123SECRET"),
    "URL: https://eth-sepolia.g.alchemy.com",
  );
  assert.equal(redact("https://sepolia.infura.io/v3/deadbeef"), "https://sepolia.infura.io");
  assert.equal(redact("https://rpc.example:8545/x?apikey=SECRET&a=1"), "https://rpc.example");
  assert.equal(redact("wss://u:p@node.example/ws/KEY123"), "wss://node.example");
  assert.equal(redact("(http://127.0.0.1:8545/)"), "(http://127.0.0.1:8545)");
  assert.equal(redact("http://localhost:8545/?k=v"), "http://localhost:8545");
});

test("redacts bearer-like tokens", () => {
  const t = "abcdefghijklmnop1234567890";
  assert.ok(!redact(`Authorization: Bearer ${t}`).includes(t));
  assert.ok(!redact(`Authorization: ${t}`).includes(t));
  assert.ok(!redact(`sent Bearer ${t} ok`).includes(t));
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
