-- CommonsLang_Rust.CargoLock -- author time: turn a Cargo.lock into a dk bundle of
-- the workspace's crates.io crates, for CommonsLang_Rust.Cargo.F_StaticLib.
--
--   ./dk0 --trust-local-caps write dialog CommonsLang_Rust.CargoLock.Bundle@1.0.0
--     lock=PATH/Cargo.lock out=etc/dk/v/<Lib>.Crates.Bundle.values.jsonc
--     id=<Lib>.Crates.Bundle@<version>
--
-- Cargo.lock records each crate's sha256 but not its size, and a dk bundle needs
-- both. Filling in the sizes waits on a dk0 feature: an autofix of a values file
-- from Lua that fixes every asset of a bundle in one call and keeps the file's
-- comments (requested from the build session, MAC-77). Until then the dialog stops
-- with an error after it parses the lock. It never runs curl or a child dk0.
--
-- Each asset is static.crates.io/crates/<name>/<name>-<version>.crate with the
-- sha256 Cargo.lock records. The build checks it twice: dk checks the bundle's
-- sha256 when it fetches, and cargo checks Cargo.lock's checksum against the
-- vendored crate. A Cargo.lock entry from a git repository, another registry or a
-- path outside the workspace has no checksum, so the dialog refuses it.
--
-- lua-ml has no local functions, no booleans and no string.gsub; a global table
-- holds the helpers.

CommonsLang_Rust_CargoLock = {
  id_module = "CommonsLang_Rust.CargoLock",
  id_version = "1.0.0",
  crates_io = "registry+https://github.com/rust-lang/crates.io-index",
  crates_io_sparse = "sparse+https://index.crates.io/",
  mirror = "https://static.crates.io/crates"
}

local M = { id = CommonsLang_Rust_CargoLock.id_module .. "@" .. CommonsLang_Rust_CargoLock.id_version }
rules, uirules = build.newrules(M)

-- Export marker: running any rule of a scriptmodule brings the whole module
-- (including uirules.Bundle) into a distribution. dist/<ABI>.u runs this.
function rules.Export(command, request)
  local slots = {
    "Release.Darwin_arm64", "Release.Darwin_x86_64", "Release.Linux_x86_64", "Release.Linux_x86",
    "Release.Windows_x86_64", "Release.Windows_x86"
  }
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = string.format("%s.Export@%s", CommonsLang_Rust_CargoLock.id_module, CommonsLang_Rust_CargoLock.id_version),
      slots = slots, execution_slot = "Release.execution_abi" } } }
  elseif command == "submit" then
    return { submit = { values = { schema_version = { major = 1, minor = 0 }, forms = { {
      id = request.submit.outputid,
      function_ = { commands = {
        "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')",
        "touch",
        "${SLOT.request}/cargolock-scriptmodule"
      } },
      outputs = { assets = { { slots = slots, paths = { "cargolock-scriptmodule" } } } } } } } } }
  end
end

-- The value of a `key = "value"` line, or nil.
function CommonsLang_Rust_CargoLock.value_of(line, key)
  local prefix = key .. " = \""
  if string.sub(line, 1, string.len(prefix)) ~= prefix then return nil end
  if string.sub(line, -1) ~= "\"" then return nil end
  return string.sub(line, string.len(prefix) + 1, -2)
end

-- Parses Cargo.lock (TOML, version 3 or 4) into a list of
-- { name, version, source, checksum } tables, one per [[package]].
function CommonsLang_Rust_CargoLock.parse(text)
  local H = CommonsLang_Rust_CargoLock
  local pkgs = {}
  local cur = nil
  local pos = 1
  local len = string.len(text)
  while pos <= len do
    local nl = string.find(text, "\n", pos)
    local stop = len
    if nl then stop = nl - 1 end
    local line = string.sub(text, pos, stop)
    if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
    if line == "[[package]]" then
      cur = {}
      table.insert(pkgs, cur)
    elseif string.sub(line, 1, 1) == "[" then
      cur = nil
    elseif cur then
      local v = H.value_of(line, "name")
      if v then cur.name = v end
      v = H.value_of(line, "version")
      if v then cur.version = v end
      v = H.value_of(line, "source")
      if v then cur.source = v end
      v = H.value_of(line, "checksum")
      if v then cur.checksum = v end
    end
    pos = stop + 2
  end
  return pkgs
end

-- The crates.io crates of a parsed Cargo.lock, as { path, checksum } tables. A
-- package with no source is a workspace member and needs no crate.
function CommonsLang_Rust_CargoLock.crates(pkgs, lockpath)
  local H = CommonsLang_Rust_CargoLock
  local out = {}
  local i = 1
  while pkgs[i] do
    local p = pkgs[i]
    if p.source then
      local ok = 0
      if p.source == H.crates_io then ok = 1 end
      if p.source == H.crates_io_sparse then ok = 1 end
      assert(ok == 1, string.format(
        "%s %s comes from %s; only crates.io crates can be vendored (they carry a checksum)",
        tostring(p.name), tostring(p.version), p.source))
      assert(p.checksum, string.format("%s %s has no checksum in %s", p.name, p.version, lockpath))
      table.insert(out, { path = string.format("%s/%s-%s.crate", p.name, p.name, p.version), checksum = p.checksum })
    end
    i = i + 1
  end
  return out
end

-- The bundle as JSON text, one asset per crates.io crate.
function CommonsLang_Rust_CargoLock.bundle_json(id, crates, sizes, lockpath)
  local H = CommonsLang_Rust_CargoLock
  local assets = {}
  local i = 1
  while crates[i] do
    local c = crates[i]
    local size = assert(sizes[c.path], "no size for " .. c.path)
    table.insert(assets, string.format(
      "        {\n          \"path\": \"%s\",\n          \"origin\": \"crates-io\",\n          \"size\": %s,\n          \"checksum\": { \"sha256\": \"%s\" }\n        }",
      c.path, size, c.checksum))
    i = i + 1
  end
  local body = ""
  local j = 1
  while assets[j] do
    if j > 1 then body = body .. ",\n" end
    body = body .. assets[j]
    j = j + 1
  end
  return "// The crates.io crates of " .. lockpath .. ", for CommonsLang_Rust.Cargo.F_StaticLib.\n" ..
    "// Written by CommonsLang_Rust.CargoLock.Bundle@" .. H.id_version .. ". Regenerate it whenever\n" ..
    "// Cargo.lock changes.\n" ..
    "{\n" ..
    "  \"$schema\": \"https://diskuv.com/dk/schema/dk-value-1.0.json\",\n" ..
    "  \"schema_version\": { \"major\": 1, \"minor\": 0 },\n" ..
    "  \"bundles\": [\n" ..
    "    {\n" ..
    "      \"id\": \"" .. id .. "\",\n" ..
    "      \"listing\": { \"origins\": [ { \"name\": \"crates-io\", \"mirrors\": [ \"" .. H.mirror .. "\" ] } ] },\n" ..
    "      \"assets\": [\n" .. body .. "\n      ]\n" ..
    "    }\n" ..
    "  ]\n" ..
    "}\n"
end

function uirules.Bundle(command, request)
  local H = CommonsLang_Rust_CargoLock
  if command ~= "submit" then return end
  local lockpath = request.user.lock or "Cargo.lock"
  local out = assert(request.user.out, "please provide out=PATH (for example etc/dk/v/MyLib.Crates.Bundle.values.jsonc)")
  local id = assert(request.user.id, "please provide id=<Lib>.Crates.Bundle@<version>")
  local text = assert(request.ui.readfile { path = lockpath })
  local crates = H.crates(H.parse(text), lockpath)
  local count = 0
  while crates[count + 1] do count = count + 1 end
  error(string.format(
    "%s has %d crates.io crates, but writing their bundle needs each crate's size, and this dk0 cannot fill sizes from a dialog yet (the Lua autofix requested in MAC-77)",
    lockpath, count))
  local json = H.bundle_json(id, crates, {}, lockpath)
  local meta = request.ui.checksum { path = out }
  local expected = "false"
  if meta and meta.sha256 then expected = meta.sha256 end
  local ok, written = request.ui.writefile { path = out, content = json, expected_sha256 = expected }
  assert(ok, "could not write `" .. out .. "`: " .. tostring(written))
  print("wrote " .. tostring(written))
  return { submit = {} }
end

return M
