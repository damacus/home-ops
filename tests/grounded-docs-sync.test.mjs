import assert from "node:assert/strict";
import { test } from "node:test";
import { syncCatalog } from "../kubernetes/apps/dev/grounded-docs/app/sync.mjs";

const source = {
  library: "rails-guides", version: "8.1.4",
  url: "https://guides.rubyonrails.org/v8.1.4/", maxPages: 500, maxDepth: 4,
};

function backend(versions = []) {
  const calls = [];
  return {
    calls,
    run(args) {
      calls.push(args);
      if (args[0] === "list") {
        return JSON.stringify({ libraries: [{ name: source.library, versions }] });
      }
      return "done";
    },
  };
}

test("first sync indexes the approved version without replacing existing data", () => {
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
  for (const response of ["not json", "{}", '{"libraries":null}']) {
    let calls = 0;
    assert.throws(() => syncCatalog([source], () => { calls += 1; return response; }));
    assert.equal(calls, 1);
  }
});
