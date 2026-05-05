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
