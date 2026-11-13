import build from "./config/esbuild.defaults.js"

build({
  publicPath: "/home-ops/_bridgetown/static",
  bridgetownConfig: { source: "site_docs", destination: "output" },
  globOptions: { excludeFilter: /\\.(dsd|lit)\\.css$/ }
})
