import "../styles/index.css"
import Willamette from "willamette"

// Willamette's modal assumes a domain-root site. Use its search keyboard/link
// actions with our project-subpath-aware Pagefind page instead.
Willamette.openSearch = () => window.location.assign(document.querySelector("a[slot=search]").href)
Willamette.init()
