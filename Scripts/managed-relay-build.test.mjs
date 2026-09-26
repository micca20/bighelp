import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
function run(...args) {
  const result = spawnSync(process.execPath, args, { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}
test("notification derivative preserves exact recovered baseline and parses inserted dollar expressions", async () => {
  run("services/relay/scripts/assemble.mjs", "build");
  const baseline = await readFile(root + "/services/relay/dist/worker.js");
  assert.equal(baseline.length, 775005);
  assert.equal(createHash("sha256").update(baseline).digest("hex"), "3f07a9f97e5948feec13b683735cec1f997cb0f265eceefab9e52247012befa2");
  run("services/relay/scripts/assemble-notifications.mjs");
  run("--check", "services/relay/dist/worker-notifications.js");
  const derivative = await readFile(root + "/services/relay/dist/worker-notifications.js", "utf8");
  const feature = await readFile(root + "/services/relay/src/managed-notifications.js", "utf8");
  assert.ok(derivative.includes(feature), "Authored feature bytes must survive literal insertion unchanged");
  assert.equal(derivative.split("var __defProp = Object.defineProperty;").length,
    baseline.toString("utf8").split("var __defProp = Object.defineProperty;").length,
    "Replacement metacharacters must not insert the prefix of the baseline");
});
