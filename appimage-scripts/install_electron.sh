#!/usr/bin/env bash

set -e

mkdir -p "${APP_DIR}/electron"

mkdir -p "${APP_DIR}/electron_temp"

npm install electron --prefix "${APP_DIR}/electron"

# ls "${APP_DIR}/electron_temp/node_modules/electron/dist"
# cp -Lr "${APP_DIR}/electron_temp/node_modules/" "${APP_DIR}/electron"

cat << 'EOF' > "${APP_DIR}/bin/electron"
#!/usr/bin/env bash

ELECTRON_DIR=${HERE:-..}/electron/node_modules/electron/dist

export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"

"${ELECTRON_DIR}"/electron --no-sandbox "$@"
EOF

chmod +x "${APP_DIR}/bin/electron"
