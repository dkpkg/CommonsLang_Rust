#!/bin/sh
# CommonsLang_Rust: build one static library from a locked Cargo workspace, offline.
#
# Run by CommonsLang_Rust.Cargo.F_StaticLib on macOS and Linux. Every input is a
# directory that dk materialized; this script never touches the network.
#
# Usage: build-staticlib.sh NAME=VALUE...
#   rustver=1.99.1            the Rust version of the Host and Std objects
#   hostslot=Release.ABI      the slot of the execution host (the Host object)
#   targetslot=Release.ABI    the slot to build for (the Std object)
#   host=DIR                  the CommonsLang_Rust.Host object
#   std=DIR                   the CommonsLang_Rust.Std object for the target
#   crates=DIR                the .crate files of the workspace's Cargo.lock
#   src=DIR                   the workspace root (Cargo.toml and Cargo.lock)
#   package=NAME              the cargo -p name of the staticlib crate
#   lib=NAME                  the library name (lib<lib>.a)
#   features=A,B              optional cargo features, comma separated
#   macosx=15.0               MACOSX_DEPLOYMENT_TARGET on Darwin targets
#   out=DIR                   where lib/ and share/ are written
set -eu

rustver= hostslot= targetslot= host= std= crates= src= package= lib= features= macosx= out=
for arg in "$@"; do
  case "$arg" in
    rustver=*) rustver=${arg#*=} ;;
    hostslot=*) hostslot=${arg#*=} ;;
    targetslot=*) targetslot=${arg#*=} ;;
    host=*) host=${arg#*=} ;;
    std=*) std=${arg#*=} ;;
    crates=*) crates=${arg#*=} ;;
    src=*) src=${arg#*=} ;;
    package=*) package=${arg#*=} ;;
    lib=*) lib=${arg#*=} ;;
    features=*) features=${arg#*=} ;;
    macosx=*) macosx=${arg#*=} ;;
    out=*) out=${arg#*=} ;;
    *) echo "build-staticlib.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
for v in rustver hostslot targetslot host std crates src package lib out; do
  eval "val=\${$v}"
  if [ -z "$val" ]; then echo "build-staticlib.sh: missing $v=" >&2; exit 2; fi
done
# dk passes the inputs relative to the form's directory; the build changes directory.
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
host=$(abs "$host"); std=$(abs "$std"); crates=$(abs "$crates"); src=$(abs "$src"); out=$(abs "$out")
# A workspace with no crates.io dependencies has no crates bundle.
if [ ! -d "$crates" ]; then crates="$PWD/.no-crates"; mkdir -p "$crates"; fi

# The slot to Rust target triple table. Keep it equal to the one in Cargo.values.lua
# and build-staticlib.ps1.
triple_of() {
  case "$1" in
    Release.Darwin_arm64) echo aarch64-apple-darwin ;;
    Release.Darwin_x86_64) echo x86_64-apple-darwin ;;
    Release.Linux_x86_64) echo x86_64-unknown-linux-gnu ;;
    Release.Linux_x86) echo i686-unknown-linux-gnu ;;
    *) echo "build-staticlib.sh: no Rust target for slot $1 on this host" >&2; return 1 ;;
  esac
}
hosttriple=$(triple_of "$hostslot")
targettriple=$(triple_of "$targetslot")

work=$(mktemp -d "${TMPDIR:-/tmp}/dkrust.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1. One toolchain tree: rustc, then cargo, then the host and target standard libraries.
#    rustc finds its sysroot from its own path, so the libraries go under its lib/rustlib.
tc="$work/toolchain"
mkdir -p "$tc"
cp -R "$host/rustc/rustc-$rustver-$hosttriple/rustc/." "$tc/"
cp -R "$host/cargo/cargo-$rustver-$hosttriple/cargo/bin/." "$tc/bin/"
# The Host object leaves out rustc/lib/rustlib (debugger scripts, rust-lld), so make it.
mkdir -p "$tc/lib/rustlib"
cp -R "$host/std/rust-std-$rustver-$hosttriple/rust-std-$hosttriple/lib/rustlib/$hosttriple" "$tc/lib/rustlib/"
if [ "$targettriple" != "$hosttriple" ]; then
  cp -R "$std/rust-std-$rustver-$targettriple/rust-std-$targettriple/lib/rustlib/$targettriple" "$tc/lib/rustlib/"
fi
# dk objects do not keep the executable bit of nested files.
find "$tc/bin" -type f -exec chmod +x {} +
if [ -d "$tc/lib/rustlib/$hosttriple/bin" ]; then
  find "$tc/lib/rustlib/$hosttriple/bin" -type f -exec chmod +x {} +
fi

# 2. The vendored sources: each .crate is a gzipped tar with one top directory
#    <name>-<version>. Cargo reads a directory source when each crate has a
#    .cargo-checksum.json; "package" is the sha256 of the .crate, which cargo checks
#    against Cargo.lock.
vendor="$work/vendor"
mkdir -p "$vendor"
find "$crates" -type f -name '*.crate' > "$work/crates.txt"
while IFS= read -r c; do
  base=$(basename "$c" .crate)
  tar -xzf "$c" -C "$vendor"
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$c" | cut -d' ' -f1)
  else
    sum=$(shasum -a 256 "$c" | cut -d' ' -f1)
  fi
  printf '{"files":{},"package":"%s"}' "$sum" > "$vendor/$base/.cargo-checksum.json"
done < "$work/crates.txt"

# 3. A writable copy of the workspace, so cargo's target/ never lands in a dk object.
ws="$work/src"
mkdir -p "$ws"
cp -R "$src/." "$ws/"
chmod -R u+w "$ws"

export CARGO_HOME="$work/cargo-home"
mkdir -p "$CARGO_HOME"
cat > "$CARGO_HOME/config.toml" <<EOF
[source.crates-io]
replace-with = "dk-vendored"

[source.dk-vendored]
directory = "$vendor"

[net]
offline = true
EOF

# 4. The environment: only the toolchain and the system C compiler.
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER CARGO_BUILD_TARGET CARGO_TARGET_DIR
export PATH="$tc/bin:$PATH"
export RUSTC="$tc/bin/rustc"
export CARGO_TARGET_DIR="$work/target"
cflags=
case "$targetslot" in
  Release.Darwin_*)
    export MACOSX_DEPLOYMENT_TARGET="${macosx:-15.0}"
    cc=/usr/bin/clang
    ;;
  Release.Linux_x86)
    cc=gcc
    cflags=-m32
    # cargo's linker for the i686 target is cc; the -m32 multilib is the dk1 Linux_x86 leg's.
    export CARGO_TARGET_I686_UNKNOWN_LINUX_GNU_LINKER=gcc
    ;;
  Release.Linux_*)
    cc=gcc
    ;;
esac
# The cc crate (ring's C and assembly) reads CC_<triple> and CFLAGS_<triple>.
tu=$(echo "$targettriple" | tr '-' '_')
eval "export CC_$tu=\"$cc\""
if [ -n "$cflags" ]; then eval "export CFLAGS_$tu=\"$cflags\""; fi

featarg=
if [ -n "$features" ]; then featarg="--features=$features"; fi

# 5. Build. cargo rustc --crate-type staticlib builds only the static library, even
#    when the crate also lists cdylib. --print native-static-libs names the system
#    libraries a final link needs; rustc prints it as a note on stderr.
cmdline="cargo rustc --locked --offline --release --target $targettriple -p $package --crate-type staticlib${featarg:+ $featarg} -- --print native-static-libs"
log="$work/cargo.log"
cd "$ws"
# shellcheck disable=SC2086
if ! cargo rustc --locked --offline --release --target "$targettriple" -p "$package" \
    --crate-type staticlib $featarg -- --print native-static-libs > "$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi
cat "$log" >&2

native=$(sed -n 's/^note: native-static-libs: //p' "$log" | tail -n 1)

# 6. The output object.
mkdir -p "$out/lib" "$out/share"
cp "$CARGO_TARGET_DIR/$targettriple/release/lib$lib.a" "$out/lib/lib$lib.a"
printf '%s\n' "$native" > "$out/lib/native-static-libs.txt"

# link_flags.sexp: each library as -cclib -l<x>; each "-framework X" stays one ordered
# pair, passed as -cclib "-framework X".
{
  printf '('
  set -- $native
  first=1
  while [ $# -gt 0 ]; do
    if [ "$1" = "-framework" ] && [ $# -ge 2 ]; then
      w="-framework $2"; shift 2
    else
      w="$1"; shift
    fi
    if [ $first -eq 1 ]; then first=0; else printf ' '; fi
    printf -- '-cclib "%s"' "$w"
  done
  printf ')\n'
} > "$out/lib/link_flags.sexp"

rustcver=$("$RUSTC" --version)
lockhash=$( (sha256sum "$ws/Cargo.lock" 2>/dev/null || shasum -a 256 "$ws/Cargo.lock") | cut -d' ' -f1)
case "$targetslot" in
  Release.Darwin_*) platkey=macosx_deployment_target; platval="$MACOSX_DEPLOYMENT_TARGET" ;;
  *) platkey=glibc_floor; platval="the build host's glibc" ;;
esac
cat > "$out/share/cargo-build.json" <<EOF
{
  "rustc": "$rustcver",
  "slot": "$targetslot",
  "target": "$targettriple",
  "host": "$hosttriple",
  "package": "$package",
  "library": "lib/lib$lib.a",
  "cargo_lock_sha256": "$lockhash",
  "cargo_command": "$cmdline",
  "$platkey": "$platval"
}
EOF
echo "build-staticlib.sh: wrote $out/lib/lib$lib.a for $targettriple" >&2
