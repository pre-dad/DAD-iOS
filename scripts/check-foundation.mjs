import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const SOURCE_REPOSITORY = "pre-dad/DAD-Main";
const hash = (contents) => createHash("sha256").update(contents).digest("hex");
const files = ["DADNullValue.swift", "DADTokens.kt", "DADTokens.swift", "links.json", "mobile.openapi.json", "openapi.json", "swift.openapi.json", "tokens.json", "tokens.ts", "ui-catalog-vectors.json", "ui-catalog.json"];

export async function verifyFoundation(root) {
  const lock = JSON.parse(await readFile(resolve(root, "foundation.lock.json"), "utf8"));
  if (!/^\d+\.\d+\.\d+$/.test(lock.version) || lock.release_tag !== `mobile-foundation-v${lock.version}` ||
      lock.source_repository !== SOURCE_REPOSITORY || !/^[a-f0-9]{40}$/.test(lock.source_revision)) throw new Error("Invalid foundation lock");
  const directory = resolve(root, "contracts/foundation");
  const raw = await readFile(resolve(directory, "manifest.json"));
  if (hash(raw) !== lock.manifest_sha256) throw new Error("Foundation manifest differs from the pinned release");
  const manifest = JSON.parse(raw);
  for (const key of ["version", "source_repository", "source_revision"]) {
    if (manifest[key] !== lock[key]) throw new Error(`Foundation ${key} differs from lock`);
  }
  if (JSON.stringify(Object.keys(manifest.files).sort()) !== JSON.stringify(files)) throw new Error("Unexpected foundation file set");
  for (const file of files) {
    const expected = manifest.files[file];
    if (!/^[a-f0-9]{64}$/.test(expected) || hash(await readFile(resolve(directory, file))) !== expected) throw new Error(`Foundation drift: ${file}`);
  }
  return lock;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    const lock = await verifyFoundation(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
    console.log(`DAD mobile foundation ${lock.version} verified at ${lock.source_revision}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
