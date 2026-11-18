import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.GITLEAKS_BINARY ? resolve(process.env.GITLEAKS_BINARY) : "gitleaks";

test("secret exceptions allow only the reviewed values in their original files", async () => {
  const root = await mkdtemp(join(tmpdir(), "dad-secret-config-"));
  const report = join(root, "report.json");
  const paths = ["contracts/foundation/manifest.json", "Tests/DADFoundationTests/ApplicationSubmitTests.swift",
    "UITests/CredentialAuthFlowTests.swift"];
  const fixtures = await Promise.all(paths.map(async path => [path, await readFile(join(repo, path), "utf8")]));
  const scan = () => {
    const result = spawnSync(binary, ["dir", ".", "--config", join(repo, ".gitleaks.toml"),
      "--redact", "--no-banner", "--report-format", "json", "--report-path", report], { cwd: root, encoding: "utf8" });
    assert.ifError(result.error);
    assert.ok(result.status === 0 || result.status === 1, result.stderr);
    return result.status;
  };
  try {
    for (const [path, text] of fixtures) {
      await mkdir(dirname(join(root, path)), { recursive: true });
      await writeFile(join(root, path), text + "\n");
    }
    assert.equal(scan(), 0, "reviewed hashes and fixtures must not be flagged");

    // A synthetic high-entropy marker exercises the generic key rule without using a credential.
    const marker = 'api_key = "' + ["7fQ2nZ8xL5", "vM9pW3kC6jH4sB0dY"].join("") + '"\n';
    for (const [path, text] of fixtures) await writeFile(join(root, path), text + "\n" + marker);
    assert.equal(scan(), 1, "an unrelated key in an excepted file must fail");
    const findings = JSON.parse(await readFile(report, "utf8"));
    assert.equal(findings.length, 3);
    assert.ok(findings.every(finding => finding.RuleID === "generic-api-key"));

    for (const [path] of fixtures) await rm(join(root, path));
    await writeFile(join(root, "unrelated.swift"), fixtures[1][1] + "\n");
    assert.equal(scan(), 1, "the same value in an unrelated file is not excepted");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
