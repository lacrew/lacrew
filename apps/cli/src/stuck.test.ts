import { strict as assert } from "node:assert";
import { test } from "node:test";
import { redact, stuckHint, stuckUrl } from "./stuck.js";

const KEY = "0x" + "ab".repeat(32);

test("redact strips private keys, secret-named values, bearer tokens and home paths", () => {
  const out = redact(
    `PRIVATE_KEY=${KEY} failed; key ${KEY}; Authorization: Bearer abcdef1234567890 ` +
      `at /Users/jane/work/lacrew/x.ts; OPENROUTER_API_KEY: sk-abcdefghijklmnopqrstu`,
  );
  assert.ok(!out.includes(KEY));
  assert.ok(!out.includes("abcdef1234567890"));
  assert.ok(!out.includes("jane"));
  assert.ok(!out.includes("sk-abcdefghijklmnopqrstu"));
});

test("redact strips RPC provider keys and url credentials", () => {
  const out = redact(
    "https://eth-sepolia.g.alchemy.com/v2/AbCdEfGhIjKlMnOpQrStUv and https://user:pw@host/x?apikey=zzz",
  );
  assert.ok(!out.includes("AbCdEfGhIjKlMnOpQrStUv"));
  assert.ok(!out.includes("user:pw"));
  assert.ok(!out.includes("zzz"));
});

test("stuckUrl targets the quickstart template and carries step, error and versions", () => {
  const url = new URL(
    stuckUrl({
      command: "deploy",
      error: new Error(`boom ${KEY}`),
      cliVersion: "0.1.0",
      nodeVersion: "v22.1.0",
      platform: "darwin-arm64",
    }),
  );
  assert.equal(url.origin + url.pathname, "https://github.com/lacrew/lacrew/issues/new");
  assert.equal(url.searchParams.get("template"), "quickstart-stuck.yml");
  assert.equal(url.searchParams.get("step"), "CLI: lacrew deploy");
  assert.ok(url.searchParams.get("error")!.startsWith("Error: boom"));
  assert.ok(!url.search.includes(KEY.slice(2, 20)));
  assert.match(url.searchParams.get("versions")!, /lacrew-cli 0\.1\.0\nnode v22\.1\.0\ndarwin-arm64/);
});

test("a huge error stays within the URL budget", () => {
  const url = stuckUrl({ error: "x".repeat(50_000), cliVersion: "0.1.0" });
  assert.ok(url.length < 4000);
});

test("stuckHint names the link", () => {
  assert.match(stuckHint({ error: "e", cliVersion: "0.1.0" }), /Stuck\? Tell us[\s\S]*https:\/\/github\.com/);
});
