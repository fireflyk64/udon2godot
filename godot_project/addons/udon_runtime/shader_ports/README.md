# Shader ports

unidot_importer cannot translate Unity shaders. A material whose shader has a file here named
`<Unity shader name>.gdshader` with `/` → `__` and spaces → `_` (e.g. `metaphira/Ball Shadow` →
`metaphira__Ball_Shadow.gdshader`) becomes a ShaderMaterial using it; uniforms named like the
Unity properties (`_MainTex`, `_Color`, `_Scale`, `_MainTex_ST`, ...) receive the material's values.
Materials without a port are approximated with a StandardMaterial3D plus the render state parsed
from the ShaderLab source (blend, ZWrite, Cull, ZTest, queue, lit/unlit); `world_doctor.py` lists
the shaders that were approximated and the file name a port would need.

A Unity shader with several passes: `<name>.pass1.gdshader`, `<name>.pass2.gdshader` ... beside
the port are drawn after it (the material's `next_pass` chain) with the same uniforms. A pass
whose source has a line `// unidot_repeat: <uniform> = v1, v2, ...` is drawn once per value
with that uniform set to it (the shells of a fur shader: `CF_Pool__Fur.pass1.gdshader`).

The directories searched are the project setting `unidot/shader_ports`.
