#!/usr/bin/env python3
"""Write an Udon variable table the way VRChat stores it in
`UdonBehaviour.serializedPublicVariablesBytesString` (Odin Serializer binary format, base64).

UdonSharp 0.x scenes have no C# proxy components: the serialized fields of a behaviour live in this
table and Unity object references are indices into `publicVariablesUnityEngineObjects`. The Unity
fixture uses this tool to build such a behaviour by hand; the reader is
refs/unidot_importer/udon_odin.gd.

    tools/odin_encode.py spec.json      # prints the base64 text

spec.json: [[name, csharp_type, value], ...] with value a number / bool / string / null,
{"ref": index}, a list for vectors and colours (type UnityEngine.Vector3 ...) and for arrays
(type ending in []; elements numbers, strings or {"ref": index}).
"""
import base64, json, struct, sys

ASM = {"System": "mscorlib", "UnityEngine.UI": "UnityEngine.UI", "UnityEngine": "UnityEngine.CoreModule", "VRC.SDKBase": "VRCSDKBase"}
LIST_T = "System.Collections.Generic.List`1[[VRC.Udon.Common.Interfaces.IUdonVariable, VRC.Udon.Common]], mscorlib"


def qualified(t):
    for prefix in sorted(ASM, key=len, reverse=True):
        if t.startswith(prefix + "."):
            return "%s, %s" % (t, ASM[prefix])
    return t


class Writer:
    def __init__(self):
        self.out = bytearray()
        self.types = {}
        self.next_ref = 0

    def string(self, s):
        self.out += b"\x01" + struct.pack("<i", len(s)) + s.encode("utf-16-le")

    def type(self, name):
        if name in self.types:                      # TypeID
            self.out += b"\x30" + struct.pack("<i", self.types[name])
        else:                                       # TypeName
            self.types[name] = len(self.types)
            self.out += b"\x2f" + struct.pack("<i", self.types[name])
            self.string(name)

    def tag(self, named, unnamed, name):
        if name is None:
            self.out.append(unnamed)
        else:
            self.out.append(named)
            self.string(name)

    def ref_node(self, name, type_name):
        self.tag(0x01, 0x02, name)
        self.type(type_name)
        self.out += struct.pack("<i", self.next_ref)
        self.next_ref += 1

    def struct_node(self, name, type_name):
        self.tag(0x03, 0x04, name)
        self.type(type_name)

    def end_node(self):
        self.out.append(0x05)

    def begin_array(self, n):
        self.out += b"\x06" + struct.pack("<q", n)

    def end_array(self):
        self.out.append(0x07)

    def value(self, name, ctype, v):
        if isinstance(v, dict) and "ref" in v:
            self.tag(0x0B, 0x0C, name); self.out += struct.pack("<i", v["ref"])
        elif v is None:
            self.tag(0x2D, 0x2E, name)
        elif ctype.endswith("[]"):
            et = ctype[:-2]
            self.ref_node(name, qualified(ctype))
            if et in ("System.Single", "System.Int32", "System.Boolean", "System.Byte", "System.Double", "System.Int64"):
                fmt, size = {"System.Single": ("<f", 4), "System.Int32": ("<i", 4), "System.Boolean": ("<?", 1), "System.Byte": ("<B", 1), "System.Double": ("<d", 8), "System.Int64": ("<q", 8)}[et]
                self.out += b"\x08" + struct.pack("<ii", len(v), size) + b"".join(struct.pack(fmt, x) for x in v)
            else:
                self.begin_array(len(v))
                for x in v:
                    self.value(None, et, x)
                self.end_array()
            self.end_node()
        elif ctype in ("UnityEngine.Vector2", "UnityEngine.Vector3", "UnityEngine.Vector4", "UnityEngine.Quaternion", "UnityEngine.Color"):
            self.struct_node(name, qualified(ctype))
            for x in v:
                self.out += b"\x20" + struct.pack("<f", x)
            self.end_node()
        elif ctype == "VRC.SDKBase.VRCUrl":
            self.ref_node(name, qualified(ctype))
            self.value("url", "System.String", v)
            self.end_node()
        elif ctype == "System.Boolean":
            self.tag(0x2B, 0x2C, name); self.out.append(1 if v else 0)
        elif ctype == "System.Single":
            self.tag(0x1F, 0x20, name); self.out += struct.pack("<f", v)
        elif ctype == "System.Double":
            self.tag(0x21, 0x22, name); self.out += struct.pack("<d", v)
        elif ctype == "System.Int32":
            self.tag(0x17, 0x18, name); self.out += struct.pack("<i", v)
        elif ctype == "System.String":
            self.tag(0x27, 0x28, name); self.string(v)
        else:
            raise SystemExit("unsupported type " + ctype)


def encode(variables):
    w = Writer()
    w.ref_node(None, "VRC.Udon.Common.UdonVariableTable, VRC.Udon.Common")
    w.begin_array(1)
    w.value("type", "System.String", LIST_T)
    w.ref_node("Variables", LIST_T)
    w.begin_array(len(variables))
    for name, ctype, v in variables:
        w.ref_node(None, "VRC.Udon.Common.UdonVariable`1[[%s]], VRC.Udon.Common" % qualified(ctype))
        w.begin_array(2)
        w.value("type", "System.String", "System.String, mscorlib")
        w.value("SymbolName", "System.String", name)
        w.value("type", "System.String", qualified(ctype))
        w.value("Value", ctype, v)
        w.end_array()
        w.end_node()
    w.end_array()
    w.end_node()
    w.end_array()
    w.end_node()
    return base64.b64encode(bytes(w.out)).decode()


if __name__ == "__main__":
    print(encode(json.load(open(sys.argv[1]))))
