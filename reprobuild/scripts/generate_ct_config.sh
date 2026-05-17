set -eu

out=build/generated/ct_config.h
mkdir -p "$(dirname "$out")" build/c
cat > "$out" <<'EOF'
#ifndef REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_GENERATED 1
#endif
EOF
