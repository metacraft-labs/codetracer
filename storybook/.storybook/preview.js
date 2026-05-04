const cssHrefs = [
  "/frontend/styles/default_dark_theme_electron.css",
  "/frontend/styles/loader.css",
  "/public/third_party/font-awesome.min.css",
  "/public/third_party/vex.css",
  "/public/third_party/vex-theme-os.css",
  "/public/third_party/golden-layout/dist/css/goldenlayout-base.css",
  "/public/third_party/golden-layout/dist/css/themes/goldenlayout-light-theme.css",
  "/public/third_party/jstree_default.css",
  "/public/third_party/bootstrap-4.3.1-dist/css/bootstrap.css",
  "/public/third_party/bootstrap-4.3.1-dist/css/bootstrap-grid.css",
  "/public/third_party/nouislider.css",
  "/public/third_party/@exuanbo/file-icons-js/dist/css/file-icons.css",
  "/public/third_party/devicon-base.css",
];

for (const href of cssHrefs) {
  if (!document.head.querySelector(`link[href="${href}"]`)) {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    document.head.appendChild(link);
  }
}

const preview = {
  parameters: {
    layout: "fullscreen",
  },
};

export default preview;
