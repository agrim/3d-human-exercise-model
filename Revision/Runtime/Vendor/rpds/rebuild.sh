#!/bin/bash
# Run on macOS with Xcode, rustup, and Python.xcframework from bootstrap.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cache="$here/../../.cache"
source="$cache/rpds_py-0.30.0"
url=https://files.pythonhosted.org/packages/20/af/3f2f423103f1113b36230496629986e0ef7e199d2aa8392452b484b38ced/rpds_py-0.30.0.tar.gz
curl --fail --location --silent --show-error "$url" -o "$cache/rpds.tar.gz"
echo "dd8ff7cf90014af0c0f787eea34794ebf6415242ee1d6fa91eaba725cc441e84  $cache/rpds.tar.gz" | shasum -a 256 -c -
tar -xzf "$cache/rpds.tar.gz" -C "$cache"
targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
rustup target add "${targets[@]}"
export PYO3_CONFIG_FILE="$here/pyo3.conf"
for target in "${targets[@]}"; do
  slice=ios-arm64_x86_64-simulator
  if [[ $target == aarch64-apple-ios ]]; then slice=ios-arm64; fi
  export RUSTFLAGS="--remap-path-prefix=$source=rpds --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=cargo -C link-arg=-F$cache/Python.xcframework/$slice -C link-arg=-framework -C link-arg=Python"
  cargo build --locked --release --manifest-path "$source/Cargo.toml" --target "$target"
  lib="$cache/$target.rpds"
  cp "$source/target/$target/release/librpds.dylib" "$lib"
  install_name_tool -id '@rpath/rpds.rpds.framework/rpds.rpds' "$lib"
  strip -x "$lib"
  gzip -nc "$lib" > "$here/$target.gz"
done
