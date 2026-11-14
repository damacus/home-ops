import "../styles/index.css"
import Willamette from "willamette"

// Willamette's modal assumes a domain-root site. Use its search keyboard/link
// actions with our project-subpath-aware Pagefind page instead.
Willamette.openSearch = () => window.location.assign(document.querySelector("a[slot=search]").href)
Willamette.init()

// Keep the full navigation available without pushing a phone's article off screen.
const navigation = document.querySelector('aside[slot="sidebar-start"] > details')
const smallScreen = window.matchMedia("(max-width: 767px)")
if (navigation) {
  navigation.open = !smallScreen.matches
  smallScreen.addEventListener("change", ({ matches }) => { navigation.open = !matches })
}
