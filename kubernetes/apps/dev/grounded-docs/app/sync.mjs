import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/** Sync only reviewed sources, through the worker; never open its SQLite file. */
export function syncCatalog(sources, run) {
  const libraries = JSON.parse(run(["list", "--output", "json"]));
  if (!Array.isArray(libraries)) throw new Error("Invalid library catalogue response");
  for (const source of sources) {
    const library = libraries.find((item) => item.name === source.library);
    const existing = library?.versions.find((item) => item.version === source.version);
    if (existing) {
      if (existing.sourceUrl !== source.url) {
        throw new Error(`${source.library}: source URL differs; review before replacing data`);
      }
      if (["running", "queued", "updating"].includes(existing.status)) {
        throw new Error(`${source.library}: indexing already active; retry after it completes`);
      }
      run(["refresh", source.library, "--version", source.version]);
    } else {
      run([
        "scrape", source.library, source.url, "--version", source.version,
        "--max-pages", String(source.maxPages), "--max-depth", String(source.maxDepth),
        "--max-concurrency", "2", "--scope", "subpages", "--ignore-errors=false",
      ]);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const sources = JSON.parse(readFileSync(new URL("sources.json", import.meta.url), "utf8"));
    const server = process.env.GROUNDED_DOCS_SERVER_URL;
    if (!server) throw new Error("GROUNDED_DOCS_SERVER_URL is required");
    syncCatalog(sources, (args) => {
      console.error(`Grounded Docs: ${args[0]} ${args[1] ?? ""}`);
      return execFileSync(process.execPath, [
        "/app/dist/index.js", ...args, "--server-url", server,
        "--config", "/etc/grounded-docs/config.yaml",
      ], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], timeout: 3_600_000 });
    });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
