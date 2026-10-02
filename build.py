"""Wrap the plugin source in a .rbxmx and install it as a Studio local plugin.

    python build.py            build + install
    python build.py --build    build only (writes BetterImports.rbxmx here)

A local plugin is just a model file dropped in the Plugins folder. Studio picks
it up on the next restart, or immediately via Plugins > Manage Plugins.
"""
import os, sys, pathlib

HERE = pathlib.Path(__file__).parent
SRC = HERE / "src" / "BetterImports.server.lua"
OUT = HERE / "BetterImports.rbxmx"
PLUGINS = pathlib.Path(os.environ["LOCALAPPDATA"]) / "Roblox" / "Plugins"

source = SRC.read_text(encoding="utf-8")
if "]]>" in source:
    sys.exit("source contains ]]> which would break the CDATA block")

xml = f"""<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
\t<Item class="Script" referent="RBX0">
\t\t<Properties>
\t\t\t<bool name="Disabled">false</bool>
\t\t\t<string name="Name">BetterImports</string>
\t\t\t<token name="RunContext">0</token>
\t\t\t<ProtectedString name="Source"><![CDATA[{source}]]></ProtectedString>
\t\t</Properties>
\t</Item>
</roblox>
"""

OUT.write_bytes(xml.encode("utf-8"))
print(f"built  {OUT}  ({len(xml):,} bytes, {source.count(chr(10)) + 1} lines of Luau)")

if "--build" not in sys.argv:
    PLUGINS.mkdir(parents=True, exist_ok=True)
    dest = PLUGINS / "BetterImports.rbxmx"
    dest.write_bytes(xml.encode("utf-8"))
    print(f"installed  {dest}")
    print("Studio: restart, or Plugins > Manage Plugins, to load it.")
