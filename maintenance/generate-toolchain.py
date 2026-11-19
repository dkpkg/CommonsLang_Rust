#!/usr/bin/env python3
"""Regenerate the CommonsLang_Rust toolchain values for one Rust release.

Usage (from the repository root):

    python3 -I maintenance/generate-toolchain.py 1.99.1 DOWNLOAD_DIR

It reads the release's channel manifest from static.rust-lang.org, downloads any
missing rustc, cargo and rust-std tarballs into DOWNLOAD_DIR, checks each against
the manifest's sha256, and writes:

    etc/dk/v/CommonsLang_Rust/Toolchain.Bundle.values.jsonc
    etc/dk/v/CommonsLang_Rust/Host.values.lua
    etc/dk/v/CommonsLang_Rust/Std.values.lua

The file lists inside the .lua files are the tarball members that the Host and Std
objects keep. Run it again whenever the pinned Rust version moves; then bump every
module version that names the old one (Cargo.values.lua, dist/*.u, dk.u).
"""
import hashlib
import json
import os
import sys
import tarfile
import tomllib
import urllib.request

# The slots CommonsLang_Rust supports. A host slot runs rustc and cargo; a target
# slot only needs the standard library for its triple.
HOSTS = {
    "Release.Darwin_arm64": "aarch64-apple-darwin",
    "Release.Darwin_x86_64": "x86_64-apple-darwin",
    "Release.Linux_x86_64": "x86_64-unknown-linux-gnu",
    "Release.Windows_x86_64": "x86_64-pc-windows-msvc",
}
TARGETS = dict(HOSTS)
TARGETS.update({
    "Release.Linux_x86": "i686-unknown-linux-gnu",
    "Release.Windows_x86": "i686-pc-windows-msvc",
})
LICENSES = ("COPYRIGHT", "LICENSE-APACHE", "LICENSE-MIT", "LICENSE-THIRD-PARTY")


def keep(component, top, rel):
    """True when the member `rel` (relative to the tarball's top directory) is kept."""
    if rel in LICENSES:
        return True
    if rel.endswith(".pdb"):
        return False
    if component == "rustc":
        if rel in ("rustc/bin/rustc", "rustc/bin/rustc.exe"):
            return True
        if rel.startswith("rustc/bin/") and rel.endswith(".dll"):
            return True  # rustc_driver-*.dll and LLVM on Windows
        # rustc/lib holds librustc_driver and LLVM, and rustc/lib/rustlib/<host>/bin
        # holds rust-objcopy (rustc strips with it on macOS) and rust-lld (the
        # default linker of x86_64-unknown-linux-gnu). Only the debugger scripts in
        # rustc/lib/rustlib/etc are left out.
        return rel.startswith("rustc/lib/") and not rel.startswith("rustc/lib/rustlib/etc/")
    if component == "cargo":
        return rel in ("cargo/bin/cargo", "cargo/bin/cargo.exe")
    if component == "rust-std":
        return "/lib/rustlib/" in rel
    raise ValueError(component)


def members(path, component):
    top = os.path.basename(path)[: -len(".tar.gz")]
    out = []
    with tarfile.open(path, "r:gz") as t:
        for m in t.getmembers():
            if not (m.isfile() or m.issym()):
                continue
            name = m.name[2:] if m.name.startswith("./") else m.name
            if not name.startswith(top + "/"):
                raise SystemExit(f"{path}: member outside {top}/: {name}")
            rel = name[len(top) + 1:]
            if keep(component, top, rel):
                out.append(name)
    return sorted(out)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def lua_list(names, indent):
    pad = " " * indent
    return "{\n" + ",\n".join(pad + json.dumps(n) for n in names) + "\n" + " " * (indent - 2) + "}"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    version, dl = sys.argv[1], sys.argv[2]
    os.makedirs(dl, exist_ok=True)
    with urllib.request.urlopen(f"https://static.rust-lang.org/dist/channel-rust-{version}.toml") as r:
        manifest = tomllib.loads(r.read().decode())
    date = manifest["date"]
    rustc_ver = manifest["pkg"]["rustc"]["version"].split(" ")[0]
    if rustc_ver != version:
        raise SystemExit(f"manifest is for rustc {rustc_ver}, not {version}")
    mirror = f"https://static.rust-lang.org/dist/{date}"

    wanted = [("rustc", t) for t in HOSTS.values()] + [("cargo", t) for t in HOSTS.values()] + \
             [("rust-std", t) for t in TARGETS.values()]
    assets, lists = [], {}
    for comp, triple in wanted:
        entry = manifest["pkg"][comp]["target"][triple]
        name = f"{comp}-{version}-{triple}.tar.gz"
        if entry["url"] != f"{mirror}/{name}":
            raise SystemExit(f"unexpected url {entry['url']}")
        path = os.path.join(dl, name)
        if not os.path.exists(path):
            print(f"downloading {name}", file=sys.stderr)
            urllib.request.urlretrieve(entry["url"], path)
        if sha256(path) != entry["hash"]:
            raise SystemExit(f"{name}: sha256 does not match the channel manifest")
        assets.append({"path": name, "checksum": {"sha256": entry["hash"]},
                       "size": os.path.getsize(path), "origin": "static-rust-lang-org"})
        lists[(comp, triple)] = members(path, comp)

    vdir = os.path.join("etc", "dk", "v", "CommonsLang_Rust")
    os.makedirs(vdir, exist_ok=True)
    bundle = {
        "$schema": "https://diskuv.com/dk/schema/dk-value-1.0.json",
        "schema_version": {"major": 1, "minor": 0},
        "bundles": [{
            "id": f"CommonsLang_Rust.Toolchain.Bundle@{version}",
            "listing": {"origins": [{"name": "static-rust-lang-org", "mirrors": [mirror]}]},
            "assets": assets,
        }],
    }
    with open(os.path.join(vdir, "Toolchain.Bundle.values.jsonc"), "w", newline="\n") as f:
        f.write(f"// The Rust {version} components that CommonsLang_Rust redistributes, from the\n"
                f"// official channel manifest {mirror}/../channel-rust-{version}.toml.\n"
                "// Generated by maintenance/generate-toolchain.py; do not edit by hand.\n")
        json.dump(bundle, f, indent=2)
        f.write("\n")

    write_lua(os.path.join(vdir, "Host.values.lua"), version, "Host", HOSTS, lists,
              [("rustc", "rustc"), ("cargo", "cargo"), ("rust-std", "std")])
    write_lua(os.path.join(vdir, "Std.values.lua"), version, "Std", TARGETS, lists,
              [("rust-std", None)])


HEADER = {
    "Host": """-- CommonsLang_Rust.Host -- rustc, cargo and the host's standard library for one
-- execution host, as a dk object with the slots of the four host ABIs.
--
--   run-function CommonsLang_Rust.Host.Files@{v} -d OUT slot=Release.Darwin_arm64
--
-- A cross leg builds the toolchain of its host with executionslot=Release.execution_abi as well,
-- so the slot comes from the execution ABI and the leg does not publish a second value of it.
--
-- The object has three directories, one per upstream tarball, each keeping the
-- tarball's own top directory:
--   rustc/rustc-{v}-<triple>/rustc/{{bin,lib}}
--   cargo/cargo-{v}-<triple>/cargo/bin/cargo
--   std/rust-std-{v}-<triple>/rust-std-<triple>/lib/rustlib/<triple>
-- assets/cargo/build-staticlib.* merge them into one toolchain tree at build time.
""",
    "Std": """-- CommonsLang_Rust.Std -- the Rust standard library for one target, as a dk object
-- with the slots of the six target ABIs.
--
--   run-function CommonsLang_Rust.Std.Files@{v} -d OUT slot=Release.Linux_x86
--
-- The object keeps the tarball's top directory:
--   rust-std-{v}-<triple>/rust-std-<triple>/lib/rustlib/<triple>
""",
}


def write_lua(path, version, unit, slots, lists, parts):
    g = f"CommonsLang_Rust_{unit}"
    lines = [HEADER[unit].format(v=version),
             "-- Generated by maintenance/generate-toolchain.py; do not edit by hand.",
             "-- lua-ml has no local functions, so a global table holds the helpers.",
             "",
             f"{g} = {{",
             f'  id_module = "CommonsLang_Rust.{unit}",',
             f'  id_version = "{version}",',
             f'  bundle = "CommonsLang_Rust.Toolchain.Bundle@{version}"',
             "}",
             "",
             f'local M = {{ id = {g}.id_module .. "@" .. {g}.id_version }}',
             "rules, uirules = build.newrules(M)",
             "",
             f"{g}.TRIPLES = {{}}"]
    for s, t in slots.items():
        lines.append(f'{g}.TRIPLES["{s}"] = "{t}"')
    lines += ["", f"{g}.SLOTS = {lua_list(list(slots), 2)}", "", f"{g}.PATHS = {{}}"]
    for s, t in slots.items():
        for comp, sub in parts:
            key = f"{s}|{comp}"
            lines.append(f'{g}.PATHS["{key}"] = {lua_list(lists[(comp, t)], 4)}')
    subs = ", ".join("{ " + json.dumps(c) + ", " + (json.dumps(d) if d else '""') + " }" for c, d in parts)
    lines += ["",
              f"-- Each part: the tarball component and the object subdirectory it goes in.",
              f"{g}.PARTS = {{ {subs} }}",
              "",
              f"function {g}.form_output_id()",
              f'  return string.format("%s.Form@%s", {g}.id_module, {g}.id_version)',
              "end",
              "",
              f"-- One CommonsBase_Std.Extract.F_Untar per part. Each untar is its own object",
              f"-- (Release.Agnostic), so its module id names the part and the slot.",
              f"function {g}.form_values(slot)",
              f'  local triple = assert({g}.TRIPLES[slot], "unsupported slot: " .. slot)',
              "  local private = {}",
              "  local outpaths = {}",
              "  local i = 1",
              f"  local part = {g}.PARTS[1]",
              "  while part do",
              "    local comp = part[1]",
              "    local sub = part[2]",
              f'    local paths = {g}.PATHS[slot .. "|" .. comp]',
              '    local dir = "${SLOT." .. slot .. "}"',
              '    local prefix = ""',
              '    if sub ~= "" then',
              '      dir = dir .. "/" .. sub',
              '      prefix = sub .. "/"',
              "    end",
              '    local modname = comp',
              '    if comp == "rust-std" then modname = "Std" end',
              '    if comp == "rustc" then modname = "Rustc" end',
              '    if comp == "cargo" then modname = "Cargo" end',
              "    local cmd = string.format(",
              '      "run-function CommonsBase_Std.Extract.F_Untar@0.3.0 -d %s modver=CommonsLang_Rust.%s.Untar.%s.%s@%s tarmodver=%s tarassetpath=%s-%s-%s.tar.gz",',
              f'      dir, "{unit}", modname, string.sub(slot, 9), {g}.id_version,',
              f"      {g}.bundle, comp, {g}.id_version, triple)",
              "    local j = 1",
              "    local p = paths[1]",
              "    while p do",
              '      cmd = cmd .. " paths[]=" .. p',
              "      table.insert(outpaths, prefix .. p)",
              "      j = j + 1",
              "      p = paths[j]",
              "    end",
              "    table.insert(private, cmd)",
              "    i = i + 1",
              f"    part = {g}.PARTS[i]",
              "  end",
              "  return { private = private }, { assets = { { slots = { slot }, paths = outpaths } } }",
              "end",
              "",
              "function rules.Files(command, request)",
              '  if command == "declareoutput" then',
              '    local slot = assert(request.user.slot, "please provide `slot=SLOT`")',
              "    -- executionslot=Release.execution_abi asks the engine to resolve the slot from the host, so a",
              "    -- cross leg that builds its own toolchain withholds it from its release: the native leg of the",
              "    -- host publishes it, under the one value id that a native build gives it.",
              "    return { declareoutput = { return_objects = {",
              f"      id = {g}.form_output_id(),",
              f"      slots = {g}.SLOTS,",
              "      execution_slot = request.user.executionslot or slot } } }",
              '  elseif command == "submit" then',
              '    local slot = assert(request.user.slot, "please provide `slot=SLOT`")',
              f"    local precommands, outputs = {g}.form_values(slot)",
              "    return { submit = { values = { schema_version = { major = 1, minor = 0 },",
              "      forms = { { id = request.submit.outputid, precommands = precommands, outputs = outputs } } } } }",
              "  end",
              "end",
              "",
              "return M",
              ""]
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
