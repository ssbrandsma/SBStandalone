"""Fixture tests with Lua 5.1 (Lupa), Expat and Jive's pure LuaSocket URL code.

Install lupa, then: python test/run-tests.py [--socket-url path/to/socket/url.lua]
No device, network, API account or native audio decoder is required.
"""
import argparse
import os
from pathlib import Path
import xml.parsers.expat

from lupa.lua51 import LuaRuntime
from lupa.lua54 import LuaRuntime as ModernLuaRuntime

ROOT = Path(__file__).resolve().parents[1]


def runtime(socket_url, modern=False):
    lua = (ModernLuaRuntime if modern else LuaRuntime)(encoding=None, unpack_returned_tuples=True)

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

    def sax(callbacks, separator):
        parser = xml.parsers.expat.ParserCreate(namespace_separator=separator.decode())
        handle = lua.table()
        def emit(key, *args):
            fn = callbacks[key]
            if fn is not None:
                return fn(handle, *args)
        parser.StartElementHandler = lambda tag, attrs: emit(b"StartElement", tag.encode(), lua.table_from({k.encode(): v.encode() for k, v in attrs.items()}))
        parser.EndElementHandler = lambda tag: emit(b"EndElement", tag.encode())
        parser.CharacterDataHandler = lambda value: emit(b"CharacterData", value.encode())
        parser.StartDoctypeDeclHandler = lambda *args: emit(b"StartDoctypeDecl")
        parser.ExternalEntityRefHandler = lambda *args: emit(b"ExternalEntityRef") or 0
        def parse(_, chunk=None):
            try:
                parser.Parse(chunk if chunk is not None else b"", chunk is None)
                return True
            except xml.parsers.expat.ExpatError as error:
                return None, str(error).encode()
        handle[b"parse"] = parse
        handle[b"close"] = lambda _: True
        return handle

    lua.globals()[b"python_sax"] = sax
    lua.globals()[b"python_lom"] = lom
    lua.globals()[b"socket_url_path"] = str(socket_url).replace("\\", "/").encode()
    lua.execute(b"""
        os.setlocale('C')
        package.preload['lxp']=function() return {new=function(callbacks,sep) return python_sax(callbacks,sep) end} end
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
        lua = runtime(args.socket_url, modern=test.name=="podcast-playback-test.lua")
        lua.execute(test.read_bytes())
        print("PASS", test.name, flush=True)
    print(f"{len(tests)} Lua suites passed")


if __name__ == "__main__":
    main()
