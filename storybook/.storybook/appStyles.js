const APP_INDEX_URL = "/codetracer-app-index.html";

function appHref(href) {
  const url = new URL(href, window.location.origin + "/");
  return url.pathname + url.search + url.hash;
}

export async function loadCodeTracerAppStyles() {
  if (document.head.querySelector("meta[data-codetracer-app-styles]")) return;

  const response = await fetch(APP_INDEX_URL);
  if (!response.ok) {
    throw new Error(`Failed to load CodeTracer app index from ${APP_INDEX_URL}`);
  }

  const html = await response.text();
  const appDocument = new DOMParser().parseFromString(html, "text/html");
  const links = [...appDocument.querySelectorAll('link[rel~="stylesheet"][href]')];

  for (const source of links) {
    const href = appHref(source.getAttribute("href"));
    if (document.head.querySelector(`link[rel="stylesheet"][href="${href}"]`)) continue;

    const link = document.createElement("link");
    link.rel = "stylesheet";
    if (source.id) link.id = source.id;
    if (source.type) link.type = source.type;
    link.href = href;
    document.head.appendChild(link);
  }

  const marker = document.createElement("meta");
  marker.dataset.codetracerAppStyles = "true";
  document.head.appendChild(marker);
}

// The colour themes a story can be shown in, mapped to the theme name
// CodeTracer's `loadTheme` (src/frontend/renderer.nim) resolves to
// `frontend/styles/{name}_theme_electron.css`. Storybook's `theme` global
// (the toolbar, or `&globals=theme:light` in a story URL) picks one.
export const CODETRACER_THEMES = {
  dark: "default_dark",
  light: "default_white",
};

/**
 * Point the app's `#theme` stylesheet at `themeKey`'s build, the way
 * `loadTheme` does in the app, and resolve once it has loaded. The href is
 * derived from the one the app index declares, so no stylesheet path is
 * written down here.
 */
export function setCodeTracerTheme(themeKey) {
  const name = CODETRACER_THEMES[themeKey] ?? CODETRACER_THEMES.dark;
  const link = document.getElementById("theme");
  if (!link) return Promise.resolve();
  const href = link.getAttribute("href").replace(/[^/]*_theme_electron\.css$/, `${name}_theme_electron.css`);
  document.documentElement.dataset.codetracerTheme = themeKey in CODETRACER_THEMES ? themeKey : "dark";
  if (link.getAttribute("href") === href) return Promise.resolve();
  return new Promise((resolve) => {
    link.addEventListener("load", () => resolve(), { once: true });
    link.addEventListener("error", () => resolve(), { once: true });
    link.setAttribute("href", href);
  });
}
