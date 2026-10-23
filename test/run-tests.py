"""Fixture tests with Lua 5.1 (Lupa), Expat and Jive's pure LuaSocket URL code.

Install lupa, then: python test/run-tests.py [--socket-url path/to/socket/url.lua]
No device, network, API account or native audio decoder is required.
"""
import argparse
import os
from pathlib import Path
import xml.parsers.expat

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


def runtime(socket_url):
    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)

    def lom(data):
        stack, result = [], None
        parser = xml.parsers.expat.ParserCreate()

        def start(name, attrs):
            nonlocal result
            node = lua.table()
            node[b"tag"] = name.encode()
            node[b"attr"] = lua.table_from({k.encode(): v.encode() for k, v in attrs.items()})
            if stack:
                stack[-1][len(stack[-1]) + 1] = node
            else:
                result = node
            stack.append(node)

        def text(value):
            if stack and value:
                stack[-1][len(stack[-1]) + 1] = value.encode()

        parser.StartElementHandler = start
        parser.EndElementHandler = lambda _: stack.pop()
        parser.CharacterDataHandler = text
        try:
            parser.Parse(data, True)
            return result
        except xml.parsers.expat.ExpatError as error:
            return None, str(error).encode()

    lua.globals()[b"python_lom"] = lom
    lua.globals()[b"socket_url_path"] = str(socket_url).replace("\\", "/").encode()
    lua.execute(b"""
        os.setlocale('C')
        package.preload['lxp.lom']=function() return {parse=function(xml) return python_lom(xml) end} end
        package.preload['socket.url']=function() return dofile(socket_url_path) end
    """)
    for path in (ROOT / "applet/StandaloneRadio").glob("*.lua"):
        name = b"applets.StandaloneRadio." + path.stem.encode()
        lua.globals()[b"opml_test_module_name"] = name
        lua.globals()[b"opml_test_module_file"] = str(path).replace("\\", "/").encode()
        lua.execute(b"""
            local name,file=opml_test_module_name,opml_test_module_file
            package.preload[name]=function()
                local value=assert(loadfile(file))(name)
                return value or package.loaded[name]
            end
        """)
    return lua


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket-url", type=Path, default=ROOT.parent / "Squeezify/upstream/squeezeplay/src/luasocket-2.0.2/src/url.lua")
    args = parser.parse_args()
    if not args.socket_url.is_file():
        parser.error("Provide the LuaSocket 2.x pure Lua URL module with --socket-url")
    os.chdir(ROOT)
    tests = sorted((ROOT / "test").glob("*test.lua"))
    for test in tests:
        lua = runtime(args.socket_url)
        lua.execute(test.read_bytes())
        print("PASS", test.name, flush=True)
    print(f"{len(tests)} Lua suites passed")


if __name__ == "__main__":
    main()
