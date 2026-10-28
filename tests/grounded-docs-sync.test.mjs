import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { syncCatalog } from "../kubernetes/apps/dev/grounded-docs/app/sync.mjs";

const source = {
  library: "rails-guides", version: "8.1.4",
  url: "https://guides.rubyonrails.org/v8.1.4/", maxPages: 500, maxDepth: 4,
};

test("a ConfigMap-style symlink executes the entry point", () => {
  const dir = mkdtempSync(join(tmpdir(), "grounded-docs-test-"));
  try {
    const link = join(dir, "sync.mjs");
    symlinkSync(fileURLToPath(new URL("../kubernetes/apps/dev/grounded-docs/app/sync.mjs", import.meta.url)), link);
    const result = spawnSync(process.execPath, [link], {
      encoding: "utf8", env: { ...process.env, GROUNDED_DOCS_SERVER_URL: "" },
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /GROUNDED_DOCS_SERVER_URL is required/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

function backend(versions = []) {
  const calls = [];
  return {
    calls,
    run(args) {
      calls.push(args);
      if (args[0] === "list") {
        return JSON.stringify(versions.length ? [{ name: source.library, versions }] : []);
      }
      return "done";
    },
  };
}

test("an empty CLI catalogue indexes the approved version without replacing existing data", () => {
  const server = backend();
  syncCatalog([source], server.run);
  assert.deepEqual(server.calls[1], [
    "scrape", source.library, source.url, "--version", "8.1.4",
    "--max-pages", "500", "--max-depth", "4", "--max-concurrency", "2",
    "--scope", "subpages", "--ignore-errors=false",
  ]);
  assert.ok(server.calls.every((args) => !args.includes("--replace")));
});

test("a repeat sync refreshes only the exact approved version", () => {
  const server = backend([
    { version: "8.0.0", sourceUrl: "https://guides.rubyonrails.org/v8.0.0/" },
    { version: "8.1.4", sourceUrl: source.url, status: "completed" },
  ]);
  syncCatalog([source], server.run);
  assert.deepEqual(server.calls[1], ["refresh", source.library, "--version", "8.1.4"]);
});

test("a changed source URL fails before mutating an indexed version", () => {
  const server = backend([{ version: "8.1.4", sourceUrl: "https://guides.rubyonrails.org/" }]);
  assert.throws(() => syncCatalog([source], server.run), /source URL/);
  assert.equal(server.calls.length, 1);
});

test("an active indexing job is left alone", () => {
  for (const status of ["running", "queued", "updating"]) {
    const server = backend([{ version: "8.1.4", sourceUrl: source.url, status }]);
    assert.throws(() => syncCatalog([source], server.run), /already active/);
    assert.equal(server.calls.length, 1);
  }
});

test("a failed refresh stops before starting another source", () => {
  const server = backend([{ version: "8.1.4", sourceUrl: source.url, status: "completed" }]);
  const run = (args) => {
    if (args[0] === "refresh") throw new Error("upstream failed");
    return server.run(args);
  };
  assert.throws(() => syncCatalog([source, { ...source, library: "other" }], run), /upstream failed/);
  assert.equal(server.calls.length, 1);
});

test("an unavailable or malformed catalogue response never starts a scrape", () => {
  for (const response of ["not json", "null", "{}", '{"libraries":[]}', '{"libraries":null}']) {
    let calls = 0;
    assert.throws(() => syncCatalog([source], () => { calls += 1; return response; }));
    assert.equal(calls, 1);
  }
});
