import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { verifyFoundation } from "./check-foundation.mjs";

const source = new URL("../", import.meta.url);
test("pinned contract verifies offline and tampering with either payload or manifest fails", async () => {
  const root = await mkdtemp(resolve(tmpdir(), "dad-foundation-test-"));
  try {
    await cp(new URL("contracts", source), resolve(root, "contracts"), { recursive: true });
    await cp(new URL("foundation.lock.json", source), resolve(root, "foundation.lock.json"));
    assert.equal((await verifyFoundation(root)).version, "2.12.0");
    const path = resolve(root, "contracts/foundation/tokens.json");
    const original = await readFile(path);
    await writeFile(path, '{}\n');
    await assert.rejects(verifyFoundation(root), /Foundation drift: tokens.json/);
    await writeFile(path, original);
    await writeFile(resolve(root, "contracts/foundation/manifest.json"), '{}\n');
    await assert.rejects(verifyFoundation(root), /manifest differs/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
