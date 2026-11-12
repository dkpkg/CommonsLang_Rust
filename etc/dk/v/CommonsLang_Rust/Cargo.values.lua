-- CommonsLang_Rust.Cargo -- build a static library from a locked Cargo workspace,
-- offline, for one target slot.
--
--   run-function CommonsLang_Rust.Cargo.F_StaticLib@1.0.0 -d OUT
--     modver=MODULE@VERSION        the object to produce
--     srcasset=MODULE@VERSION      a workspace asset holding the Cargo workspace root
--     srcpath=PATH                 ...and its path, as in get-asset -p PATH
--   OR
--     src=MODULE@VERSION           an object holding the Cargo workspace
--     srcdir=PATH                  ...the workspace root inside it (default: its root)
--     srcslot=SLOT                 ...the object's slot (default Release.Agnostic)
--     crates=BUNDLE@VERSION        the .crate files of the workspace's Cargo.lock;
--                                  CommonsLang_Rust.CargoLock.Bundle writes it
--     package=NAME                 cargo -p NAME; the crate builds a staticlib
--     lib=NAME                     the library name (default: package, - as _)
--     features[]=NAME              optional cargo features
--     macosx=VERSION               MACOSX_DEPLOYMENT_TARGET (default 15.0, DkML's)
--
-- The object, at the target slot (Release.target_abi):
--   lib/lib<lib>.a (macOS, Linux) or lib/<lib>.lib (Windows)
--   lib/native-static-libs.txt    rustc --print native-static-libs
--   lib/link_flags.sexp           the same as -cclib flags for dune's (:include)
--   share/cargo-build.json        rustc version, triple, Cargo.lock sha256, the cargo
--                                 command, and the macOS deployment target or the
--                                 Windows C runtime (/MD)
--
-- The build itself is assets/cargo/build-staticlib.sh (macOS, Linux) and
-- build-staticlib.ps1 (Windows). cargo runs with --locked --offline against a
-- vendored directory source made from the crates bundle, so it never reaches an
-- index. The toolchain is CommonsLang_Rust.Host (the execution host) plus
-- CommonsLang_Rust.Std (the target).
--
-- lua-ml has no local functions, no booleans and no string.gsub; a global table
-- holds the helpers. Every values.lua ends with `return M`.

CommonsLang_Rust_Cargo = {
  id_module = "CommonsLang_Rust.Cargo",
  id_version = "1.0.0",
  rust = "1.99.1",
  macosx = "15.0",
  coreutils = "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')",
  powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  vswhere = "$(--path=absnative get-object CommonsBase_Build.VSWhere@3.1.7 -s Release.execution_abi -e bin/vswhere.exe -d :)${/}bin${/}vswhere.exe"
}

local M = { id = CommonsLang_Rust_Cargo.id_module .. "@" .. CommonsLang_Rust_Cargo.id_version }
rules, uirules = build.newrules(M)

-- The target slots, and which build script each one uses. Keep the slot to triple
-- table in the build scripts equal to Std.values.lua.
CommonsLang_Rust_Cargo.UNIX_SLOTS = {
  "Release.Darwin_arm64", "Release.Darwin_x86_64", "Release.Linux_x86_64", "Release.Linux_x86"
}
CommonsLang_Rust_Cargo.WINDOWS_SLOTS = { "Release.Windows_x86_64", "Release.Windows_x86" }
CommonsLang_Rust_Cargo.SLOTS = {
  "Release.Darwin_arm64", "Release.Darwin_x86_64", "Release.Linux_x86_64", "Release.Linux_x86",
  "Release.Windows_x86_64", "Release.Windows_x86"
}

-- "dk-iroh" -> "dk_iroh" (no string.gsub in lua-ml).
function CommonsLang_Rust_Cargo.underscored(s)
  local out = ""
  local i = 1
  while i <= string.len(s) do
    local c = string.sub(s, i, i)
    if c == "-" then c = "_" end
    out = out .. c
    i = i + 1
  end
  return out
end

function CommonsLang_Rust_Cargo.join(tbl, sep)
  local out = ""
  local i = 1
  while tbl[i] do
    if i > 1 then out = out .. sep end
    out = out .. tbl[i]
    i = i + 1
  end
  return out
end

-- The NAME=VALUE arguments both build scripts take.
function CommonsLang_Rust_Cargo.script_args(p, slot)
  return {
    "rustver=" .. CommonsLang_Rust_Cargo.rust,
    "hostslot=${SLOTNAME.Release.execution_abi}",
    "targetslot=" .. slot,
    "host=host",
    "std=std",
    "crates=crates",
    "src=" .. p.srcarg,
    "package=" .. p.package,
    "lib=" .. p.lib,
    "features=" .. p.features,
    "macosx=" .. p.macosx,
    "out=${SLOT." .. slot .. "}"
  }
end

-- One command per target slot. `env -u ${SLOT.<slot>}` makes dk0 drop every
-- command whose slot is not the one being built (the CommonsLang_Python UvBuild
-- trick), so only one runs.
function CommonsLang_Rust_Cargo.commands(p)
  local H = CommonsLang_Rust_Cargo
  local commands = {}
  local i = 1
  while H.UNIX_SLOTS[i] do
    local slot = H.UNIX_SLOTS[i]
    local c = { H.coreutils, "env", "-u", "${SLOT." .. slot .. "}", "--", "/bin/sh", "build-staticlib.sh" }
    local args = H.script_args(p, slot)
    local j = 1
    while args[j] do table.insert(c, args[j]); j = j + 1 end
    table.insert(commands, c)
    i = i + 1
  end
  i = 1
  while H.WINDOWS_SLOTS[i] do
    local slot = H.WINDOWS_SLOTS[i]
    local c = { H.coreutils, "env", "-u", "${SLOT." .. slot .. "}", "--", H.powershell,
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "build-staticlib.ps1" }
    local args = H.script_args(p, slot)
    local j = 1
    while args[j] do table.insert(c, args[j]); j = j + 1 end
    table.insert(c, "vswhere=" .. H.vswhere)
    table.insert(commands, c)
    i = i + 1
  end
  return commands
end

function rules.F_StaticLib(command, request)
  local H = CommonsLang_Rust_Cargo
  local modver = assert(request.user.modver, "please provide modver=MODULE@VERSION")
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = modver, slots = H.SLOTS, execution_slot = "Release.target_abi" } } }
  end
  if command ~= "submit" then return end

  local package = assert(request.user.package, "please provide package=NAME (cargo -p NAME)")
  local p = {
    package = package,
    lib = request.user.lib or H.underscored(package),
    features = H.join(request.user.features or {}, ","),
    macosx = request.user.macosx or H.macosx
  }

  local private = {
    "get-object CommonsLang_Rust.Host.Form@" .. H.rust .. " -s Release.execution_abi -d host",
    "get-object CommonsLang_Rust.Std.Form@" .. H.rust .. " -s Release.target_abi -d std",
    "get-asset CommonsLang_Rust.Apparatus.BuildStaticLibSh@1.0.0 -p assets/cargo/build-staticlib.sh -f build-staticlib.sh",
    "get-asset CommonsLang_Rust.Apparatus.BuildStaticLibPs1@1.0.0 -p assets/cargo/build-staticlib.ps1 -f build-staticlib.ps1"
  }
  if request.user.crates then
    table.insert(private, "get-bundle " .. request.user.crates .. " -d crates")
  end
  if request.user.srcasset then
    local srcpath = assert(request.user.srcpath, "please provide srcpath=PATH with srcasset=")
    table.insert(private, "get-asset " .. request.user.srcasset .. " -p " .. srcpath .. " -d src")
    p.srcarg = "src"
  else
    local src = assert(request.user.src, "please provide srcasset=MODULE@VERSION srcpath=PATH, or src=MODULE@VERSION")
    local srcslot = request.user.srcslot or "Release.Agnostic"
    table.insert(private, "get-object " .. src .. " -s " .. srcslot .. " -d src")
    p.srcarg = "src"
    if request.user.srcdir then p.srcarg = "src/" .. request.user.srcdir end
  end

  local unixpaths = {
    "lib/lib" .. p.lib .. ".a", "lib/native-static-libs.txt", "lib/link_flags.sexp", "share/cargo-build.json"
  }
  local winpaths = {
    "lib/" .. p.lib .. ".lib", "lib/native-static-libs.txt", "lib/link_flags.sexp", "share/cargo-build.json"
  }
  return { submit = { values = {
    schema_version = { major = 1, minor = 0 },
    forms = { {
      id = request.submit.outputid,
      precommands = { private = private },
      function_ = { commands = H.commands(p) },
      outputs = { assets = {
        { slots = H.UNIX_SLOTS, paths = unixpaths },
        { slots = H.WINDOWS_SLOTS, paths = winpaths }
      } }
    } }
  } } }
end

return M
