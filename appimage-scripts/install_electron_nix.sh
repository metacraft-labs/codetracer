#!/usr/bin/env bash
# ROOT_PATH
# APPDIR

# export ROOT_PATH=$(git rev-parse --show-toplevel)
# APPDIR="${ROOT_PATH}/AppDir"

# mkdir -p ${APP_DIR}/electron
#
# ls ${ROOT_PATH}/node_modules/electron/dist
cp -Lr "${ROOT_PATH}"/node_modules/electron/dist "${APP_DIR}"/electron

set -e

cat << 'EOF' > "${APP_DIR}/bin/electron"
#!/usr/bin/env bash
$HERE/node_modules/node_modules/electron/dist/electron --no-sandbox "$@"
EOF

chmod +x "${APP_DIR}/bin/electron"
