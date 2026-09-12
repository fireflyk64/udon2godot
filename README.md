# udon2godot

A compiler, written in Rust, that converts **UdonSharp** scripts (VRChat's Udon C#) into
**SafeGDScript** (`.sgd`) for the [Godot Sandbox](https://github.com/libriscv/godot-sandbox),
plus a Godot runtime addon that gives the converted scripts a VRChat-shaped world API which any
Godot game can implement — including a ready-made ENet multiplayer implementation.

```
UdonSharp .cs  ──udon2godot──▶  .sgd  ──godot-sandbox──▶  RISC-V guest running in Godot
                                  │
                                  └── extends addons/udon_runtime/udon_behaviour.gd
                                      calls Udon.*  (world provider: players, ownership, network, input)
                                      calls U.*     (Unity engine shims: math, transforms, physics, audio, …)
```

## Status

| Corpus | Classes | Lines of C# | Converter errors | Compiles in sandbox | Runs |
|---|---|---|---|---|---|
| [MS-VRCSA-Billiards](https://github.com/Sacchan-VRC/MS-VRCSA-Billiards) (official pool table, scene + prefabs) | 30 | 16.9k | 0 | 30/30 | imported world: lobby → 8-ball → break, 9/9 scenario checks |
| [vrcbce](https://github.com/VRCBilliards/vrcbce) (pool table) | 21 | 7.1k | 0 | 21/21 | — |
| [SaccFlightAndVehicles](https://github.com/Sacchan-VRC/SaccFlightAndVehicles) | 87 | 36.6k | 0 | 87/87 | — |
| `tests/coverage/*.cs` API coverage fixtures (16 classes) | 16 | 3.1k | 0 | 16/16 | 846/846 checks |
| `tests/unity_fixture` Unity scene through unidot + udon_integration | 1 | — | 0 | 1/1 | 40 script + 16 scenario checks |
| `tests/fixtures/Counter.cs` end-to-end lifecycle | 1 | — | 0 | 1/1 | 23/23 checks |
| `tests/fixtures/Counter.cs` over ENet, host + client processes | 1 | — | 0 | 1/1 | 28/28 checks |

`SaccAirVehicle` (2,657 lines in one class) needed the upstream godot-sandbox fix for the RISC-V
direct-jump range ("J-type jump out of reach" beyond 1 MB of code); `refs/godot-sandbox` carries
that fix plus a `MAX_LEVEL = 16` patch, and the prebuilt library is in `tools/sandbox_build/`.

Across the three corpora the converter maps 20,445 Unity/VRChat API uses with 21 warnings (plain
C# helper classes emitted as Node scripts, dynamic access on unknown types, two cross-class static
calls that `--class-name` turns into direct calls).

Catalog coverage of the 21,941 Udon externs that apply to scripts: **98.8 %** mapped
(83.2 % by hand-written mappings, the rest by generated stubs, see below); the remaining 260
are `Random` (mapped as `UnityEngine.Random` through `U.random_*`) and operator/boilerplate
entries.

## Building and using

```sh
cargo build --release
./target/release/udon2godot -o my_project/converted --res-prefix res://converted  path/to/UdonScripts/
./target/release/udon2godot --report path/to/UdonScripts/        # per-class API usage report
./target/release/udon2godot --check  path/to/UdonScripts/        # analyze only
./target/release/udon2godot --catalog-coverage                    # Udon externs not yet mapped
```

Options: `-o/--out DIR`, `--res-prefix res://path/` (used for `extends` between converted
scripts), `--base-script PATH`, `--class-name` (emit `class_name`; not allowed in a restricted
sandbox), `--report`, `--report-json FILE`, `--externs FILE` (custom KnownExterns list),
`--coverage-missing FILE` (machine-readable list of unmapped externs), `-q`. Setting
`UDON2GODOT_NO_GENERATED=1` disables the generated stub catalog (used by the stub generator).

Then in the Godot project:

1. Install the Godot Sandbox addon (`addons/godot_sandbox`). A source build with a higher
   `MAX_LEVEL` is recommended, see *Design notes*.
2. Copy `runtime/addons/udon_runtime` into `addons/` and register two autoloads:
   `Udon = res://addons/udon_runtime/udon.gd` and `U = res://addons/udon_runtime/u.gd`.
3. Attach a converted `.sgd` to a `Node3D` (the node plays the role of the Unity GameObject).
   Public fields are `@export`ed, so references between behaviours are wired in the inspector
   exactly as in Unity.
4. Mark nodes that carry VRChat components: `Udon.pickup(node)`, `Udon.station(node)`,
   `Udon.object_sync(node)`, `Udon.object_pool(node)`, `Udon.video(node)`, or put the node in
   the group `udon_pickup` / `udon_station` / … `GetComponent<VRC_Pickup>()` and friends find
   them that way.
5. Optionally implement `UdonWorldProvider` (see below) and call `Udon.set_provider(p)`, or
   use the bundled `UdonNetworkProvider` for multiplayer.

`godot_project/` is a ready-made test project (Godot 4.6.3):

```sh
GODOT=tools/Godot_v4.6.3-stable_linux.x86_64
$GODOT --headless --path godot_project -s e2e_counter.gd          # lifecycle of one converted script
$GODOT --headless --path godot_project -s coverage_runner.gd      # the API coverage fixtures
$GODOT --headless --path godot_project -s compile_check.gd [-- res://dir ...]
scripts/verify.sh        # cargo tests, corpus conversion, e2e, compile check
scripts/coverage_test.sh # converts tests/coverage and runs coverage_runner.gd
scripts/net_test.sh      # host + client Godot processes over ENet (godot_project/net_test.gd)
```

## Importing whole worlds

Scripts are half of a VRChat world; the other half is scene data. `scripts/import_world.sh` turns
a Unity asset folder (or a full project's `Assets`) into a runnable Godot project:

```sh
scripts/import_world.sh refs/MS-VRCSA-Billiards /tmp/worlds/billiards
scripts/world_doctor.py /tmp/worlds/billiards                       # what converted, what did not, why
tools/Godot_v4.6.3-stable_linux.x86_64 --headless --path /tmp/worlds/billiards -s world_runner.gd \
    -- --scene res://MS-VRCSA-Billiards/DefaultScene/MS-VRCSA_Scene.tscn --frames 120 --debug-scripts --dump-refs
scripts/test_world_billiards.sh /tmp/worlds/billiards               # lobby → join → 8-ball → break, with screenshots
scripts/test_unity_fixture.sh /tmp/worlds/fixture                   # hand-written Unity scene: transforms, refs, raycasts, onClick
scripts/ci.sh                                                       # all suites, one Godot at a time
```

The pipeline:

1. `udon2godot --manifest` converts every UdonSharp class and writes `converted/udon_manifest.json`
   (script GUID → `.sgd`, field types, sync modes).
2. The project is assembled from `godot_world_template/` (autoloads, sandbox, udon_runtime,
   `udon/coord_mode = unidot`, `udon/manifest`) plus the `udon-integration` branch of
   [unidot_importer](https://github.com/V-Sekai/unidot_importer) in `refs/unidot_importer`.
3. unidot runs headless in the Godot editor (`addons/unidot_importer/headless/`:
   `godot --headless --editor -- --unidot-import <dir> --unidot-text-scenes ...`). Its
   `udon_integration.gd` plugin attaches the converted scripts to the nodes unidot creates, converts
   every serialized field (references resolve once the scene exists and are stored as NodePaths in
   `metadata/udon_refs`, bound by the runtime at `_ready`), applies prefab-instance overrides, marks
   VRChat SDK components (`udon_pickup`, `udon_station`, ... groups + settings metadata read by the
   adapters), turns Unity UI into Controls (world-space canvases become a SubViewport on a quad,
   nested canvases are containers) and wires `Button.onClick`/`Toggle`/`Slider`/`InputField`
   persistent calls to `SendCustomEvent`. Prefab assets referenced by scripts become inactive template
   nodes under `UdonPrefabs`; RenderTexture assets become `UdonRenderTexture` resources backed by
   viewports on demand.
4. Materials: Godot cannot run Unity shaders, so unidot's material conversion now reads the
   ShaderLab source of custom shaders (`shaderlab.gd`) and applies its render state to the
   StandardMaterial3D it builds (blend mode, ZWrite, Cull, ZTest, render queue, unlit); skybox
   materials become real sky materials (Skybox/Procedural → ProceduralSkyMaterial, panoramic,
   6-sided and lat-long cubemaps → PanoramaSkyMaterial); and a hand-written Godot shader in
   `runtime/addons/udon_runtime/shader_ports/<Unity shader name>.gdshader` replaces the
   approximation entirely (project setting `unidot/shader_ports`), receiving the material's
   properties as uniforms. The pool table ships two ports (its ball-shadow projector and the
   additive "Transparent Orb"); `world_doctor.py` lists every custom shader that was approximated
   and the port file name that would fix it.
5. `udon_import_report.json`, `unidot_import.log` and `udon2godot_report.txt` feed
   `scripts/world_doctor.py`: unknown MonoBehaviour scripts (with their field lists), missing proxies,
   unresolved references, missing resources, stubbed API members, custom shaders without ports,
   asset import failures, and the scenes with their converted behaviours.

`world_runner.gd` (copied into the project) runs a scene headless or on screen: `--dump-refs` lists
every converted behaviour and its unbound references, `--debug-scripts` rebuilds the sandbox scripts
with debug information so guest backtraces name their functions, `--scenario res://scenarios/x.gd`
drives the world (`godot_world_template/scenarios/billiards.gd` uses `U.ui_press`, the behaviours'
public events and `Udon.simulate_*` input), `--frame <node> --view "x,y,z" --dist 1.2 --fov 55 --shot out.png` frames a node and
renders screenshots (`--display-driver x11 --rendering-method gl_compatibility` on a headless box);
`--shadows` turns on real-time shadows for every light, the stand-in for the lightmaps Unity
baked (lightmap data cannot be imported).

Unity project settings (layer names, gravity, fixed timestep, layer collision matrix, input axes)
are converted by `scripts/unity_project_settings.py` when a `ProjectSettings` folder exists; asset
packages without one use VRChat's fixed layer table.

## What the compiler does

* **Frontend** (`src/lexer.rs`, `src/parser.rs`): hand-written lexer and recursive-descent parser
  for the UdonSharp subset of C# (attributes, partial classes, properties, enums, `foreach`,
  `switch`, `out`/`ref`, `params`, interpolated strings, preprocessor conditionals, …).
* **Program model** (`src/program.rs`): partial classes are merged; fields, properties and
  method signatures are resolved against user classes, user enums and the API catalog.
* **API catalog** (`src/api.rs`, `data/api/*.udon`): a declarative mapping of the Unity /
  VRChat / .NET surface to Godot expressions — about 15,000 hand-written member mappings plus
  `generated.udon` with `!stub` entries for the remaining externs (72 today, down from 8,444;
  see *Stub generator* and the backlog in `TODO.md`).
  Each member carries a GDScript template (`$0` target, `$1..` arguments, `$v` assigned value,
  `$params` trailing params array, `$tmp` fresh temp, `A ;; B` pre-statements,
  `!unsupported msg`, `!stub tmpl`). Arguments a template uses more than once are hoisted
  into temps so side effects run once. The catalog is the *abstraction surface*: everything
  VRChat-specific is a call into the `Udon` autoload or an adapter it returns.
* **Extern table** (`src/externs.rs`, `data/known_externs.txt`): the 32,400 Udon extern
  signatures from `VRC.Udon.Wrapper.dll` (from udonweft's `lean/Udon/KnownExterns`). Used to
  tell "not mapped yet" from "not an Udon extern at all" in reports and for coverage audits.
* **Lowering** (`src/lower/`): typed lowering with C# semantics preserved where GDScript
  differs — `%` on floats → `fmod`, string concatenation with C# formatting (`True`, shortest
  round-trip floats), Unity-object null checks → `is_instance_valid`, value-type null
  comparisons folded, `for` → `range()` when safe, `do/while`, `switch` → `match` (with
  `break`-exit rewriting), `??`, `?.`, `x++` inside expressions, `out`/`ref` parameters (user
  methods return `[ret, refs…]`), casts with C# truncation/wrapping, `char` arithmetic on code
  points, `Enum.HasFlag`, implicit `bool` conversions (`RaycastHit2D`), enum declarations
  re-emitted per script, name mangling against GDScript keywords and Node members.
* **Emitter** (`src/gd.rs`): precedence-aware GDScript printer.

Each generated script `extends "res://addons/udon_runtime/udon_behaviour.gd"` and keeps the
C# method names (`Start`, `Update`, `Interact`, `OnPlayerJoined`, …); the base class dispatches
Godot callbacks to them and implements `SendCustomEvent*`, network events, delayed events and
variable synchronization. Metadata functions (`udon_synced_vars()`, `udon_sync_var_modes()`,
`udon_sync_mode()`, `udon_field_callbacks()`, `udon_network_callable()`, `udon_class()`,
`udon_class_chain()`) let a world provider implement replication without parsing the script.

### Stub generator

`tools/gen_catalog.py` runs the converter with `--coverage-missing`, demangles every extern the
hand-written catalog does not cover, and writes `data/api/generated.udon`: one `!stub` entry per
member (`pass` for calls, a typed default for values). Stubbed members convert and run instead
of failing, and `--report` lists them under *stubbed* so a world author knows exactly which
calls are no-ops. Re-run it after editing the hand-written catalog; hand-written entries always
win over stubs.

## The abstraction surface

`runtime/addons/udon_runtime/udon_world_provider.gd` is the interface a Godot game implements.
Every method has a working single-user default, so converted scripts run offline unchanged.

| Area | Provider methods | Consumed by |
|---|---|---|
| Players | `local_player()`, `master()`, `get_player_by_id()`, `get_players()`, `add_player()`, `remove_player()`, `players_in_range()` | `Networking.LocalPlayer`, `VRCPlayerApi.*`, `OnPlayerJoined/Left` |
| Player object (`udon_player.gd`) | `get_position()`, `get_tracking_data()`, `get_bone_position()`, `teleport_to()`, `set_velocity()`, `play_haptic_event_in_hand()`, tags, voice, locomotion, … | `VRCPlayerApi` members |
| Ownership | `owner_of()`, `set_owner_of()`, `is_owner()`, `OnOwnershipRequest` | `Networking.IsOwner/GetOwner/SetOwner`, `OnOwnershipTransferred` |
| Networking | `send_network_event()`, `serialize()`, `Udon.receive_network_event()`, `Udon.receive_serialization()`, `server_time_ms()`, `is_clogged()`, `network_stat()` | `SendCustomNetworkEvent`, `RequestSerialization`, `OnDeserialization`, `Networking.*` |
| Components | `pickup()`, `station()`, `object_sync()`, `object_pool()`, `video()`, `has_adapter()` (adapters in `udon_pickup.gd` etc.) | `VRC_Pickup`, `VRCStation`, `VRCObjectSync`, `VRCObjectPool`, video players, `GetComponent<VRC_*>` |
| Objects | `instantiate()`, `destroy()`, `get_player_objects()`, `player_object_init()` | `Instantiate`, `Destroy`, `VRCInstantiate`, `VRCPlayerObject` |
| Input | `get_key()`, `get_axis()`, `get_button()`, `get_mouse_button()`, `keycode_to_key()`, `is_using_hand_controller()` | `Input.*`, `KeyCode`, `InputManager` |
| Persistence | `player_data_set/get/has/remove()`, `player_data_all()` | `PlayerData.*` |
| Misc | `load_url_string()`, `new_image_downloader()`, `screen_camera()`, `avatar_pedestal_*()`, `open_menu()`, `economy()`, `midi_command()` | `VRCStringDownloader`, `VRCImageDownloader`, `VRCCameraSettings`, pedestals, economy, MIDI |

Behaviours that enter the tree after the world started receive `OnPlayerJoined` for every
player already present (`replay_joins`), the way VRChat raises it for everyone in the instance
when the local player joins.

### Multiplayer transport

`udon_network_provider.gd` (`UdonNetworkProvider extends UdonWorldProvider`) is a complete
implementation over Godot's high-level multiplayer with `ENetMultiplayerPeer`:

* `host(port)` / `join(address, port)` / `leave()`; the server peer is master and instance
  owner; players are announced with their display names, `OnPlayerJoined/Left` on every peer.
* Ownership is authoritative on the server and replicated; `OnOwnershipRequest` is honoured.
* `RequestSerialization` sends the `[UdonSynced]` snapshot (`udon_serialize()`) to all peers
  through the server; receivers run `udon_deserialize()`, which applies `[FieldChangeCallback]`
  setters and raises `OnDeserialization`. Continuous sync mode is rate-limited.
* `SendCustomNetworkEvent` with `All`/`Others`/`Owner`/`Self` targets, arguments,
  `[NetworkCallable]` filtering and `NetworkCalling.CallingPlayer` context.
* Pickup/station state, `VRCObjectSync` transforms (with `FlagDiscontinuity`), player
  positions/tracking, `PlayerData` (persisted per player on the server) and server time.
* Register the local player's body with `register_player_node(node)`; player positions,
  velocities and tracking data come from it.

`scripts/net_test.sh` starts a host and a client Godot process and checks all of the above end
to end (28 checks).

### Unity engine shims

Unity engine behaviour that does not depend on the world lives in `u.gd` (`U` autoload):
math (`Mathf`, vectors, `Quaternion.Euler/LookRotation`, `SmoothDamp`, Perlin noise,
`Matrix4x4`, `Bounds/Rect/Plane/Ray`), transforms (`forward/right/up`, `Rotate`, `LookAt`,
`TransformDirection`, `SetParent`), GameObject/Component (`SetActive`, `GetComponent<T>` over
nodes and `udon_class()`, `GameObject.Find`, tags, layers), 3D and 2D physics
(`Rigidbody`→`RigidBody3D`, `Physics.Raycast/SphereCast/Overlap*`, colliders, joints,
`Physics2D`), audio, Animator parameters and states, particles, renderers and materials
(`SetColor`, property blocks), lights and cameras, line renderers, UI (`Text`, `TMP`, sliders,
toggles, dropdowns, `RectTransform`), `string.Format`/`ToString("F2")` with .NET rounding,
`StringBuilder`, arrays, `DataList`/`DataDictionary`/`VRCJson`, `DateTime`, curves,
constraints, navigation and character controllers.

Physics callbacks are dispatched by the runtime: `OnTriggerEnter/Exit/Stay`,
`OnCollisionEnter/Exit/Stay` (with contact points), their 2D variants, `OnPlayerTrigger*` /
`OnPlayerCollision*` for the player body and `OnControllerColliderHit` from
`CharacterController.Move`. Areas are hooked as they enter the tree and rigid bodies once a
behaviour defines a collision handler; both sides of an event are served, so scripts on static
geometry hear about bodies landing on them. Unity and VRChat constraints (position, rotation,
scale, parent, aim, look-at) are solved every frame after `Update` from the sources a script
configures. Shape casts refine Godot's `cast_motion` (which resolves to about 1/256 of the
sweep) so long sweeps report exact distances and thin obstacles are not skipped.

Component lookups take the Godot class name or the converted class's `udon_class()`; Unity
types without a single Godot class (`Collider`, `Animator`, `UdonSharpBehaviour`, …) use an
alias table. `GetComponent<T>()` looks at the node and at its helper children (shapes, meshes,
audio players, lights, …) but not at children that are objects in their own right (bodies,
plain spatials, scripted behaviours).

**Coordinate conventions.** Scripts always compute in Unity numbers (left-handed, +Z forward);
`U.coord_mode` says how the Godot scene was derived and converts every value that crosses between
a script and a node: `UNIDOT` (default for imported worlds, project setting `udon/coord_mode`) —
unidot_importer mirrors X, so positions map x → -x and rotations (x,y,z,w) → (x,-y,-z,w); `UNITY` —
the scene keeps Unity axes verbatim (test scenes built by hand), identity; `GODOT` — the scene was
rotated a half-turn about Y so Unity's +Z forward is Godot's -Z. Cameras and lights look down −Z in
Godot either way, so `camera.transform.forward` is their viewing direction. The `TCoord` fixture
checks the UNIDOT mapping against Unity's numbers. 2D uses Unity's Y-up in scripts and flips to Godot's Y-down at the boundary;
2D scripts work in metres, so set the 2D gravity to `9.8` (the coverage runner shows how).

## Coverage fixtures

`tests/coverage/` holds sixteen UdonSharp classes written to exercise the API surface at runtime:
`TMath`/`TMathB` (integer and float semantics, `Mathf`, vectors, quaternions, colours,
matrices, random, bounds), `TStrings` (formatting, interpolation, `StringBuilder`, chars),
`TArrays` (arrays, params/ref/out, `DataList`, `DataDictionary`, JSON, enums), `TTransform`
(transforms, hierarchy, GameObject, components, instantiate/destroy), `TPhysics` (rigidbodies,
raycasts, triggers, collisions, joints), `TMedia` (audio, animator, particles, materials,
lights, camera, line renderer, curves), `TUI` (Unity UI and TextMeshPro over Godot controls),
`TVRC` (players, ownership, events, sync, pickups, stations, object sync/pool, player data,
input), `T2D` (2D physics), `TParticles` (particle modules), `TSystem` (.NET extras), `TNav`
(navigation meshes, links and agents) and `TAnim` (constraints, curves, humanoid tables).
`godot_project/coverage_runner.gd` builds the scene each fixture expects, runs it, verifies the
engine-side state the script cannot see, and reports every failed check; all 846 checks pass.

### Debug switches

Environment variables the runtime honours when a world misbehaves: `UDON_PHYS_DEBUG=1` prints
every physics hook, collision dispatch and `CharacterController.Move` (delta, velocity, slide
count); `UDON_NAV_DEBUG=1` prints the navigation map state (active, iteration, region count) at
the first query of each frame.

## Design notes and limitations

* **One sandbox per script; nested VM entries.** In godot-sandbox all instances of one `.sgd`
  share a machine, and `MAX_LEVEL` bounds nested guest entries (4 in the stock build = 3
  nested calls). Guest → base-class GDScript method → guest costs a level, and GDScript
  property accessors cost a host round-trip. The compiler therefore routes `SendCustomEvent`,
  `RequestSerialization` etc. through `U.*` host helpers and emits C# properties as
  `get_X()` / `set_X()` methods. `tools/sandbox_build/` holds a source build of godot-sandbox
  with `MAX_LEVEL = 16` (call chains nine levels deep verified); `godot_project` uses it.
* **Code size.** One SafeGDScript function body must stay within the RISC-V direct-jump range
  (1 MB of generated code). Very large classes (`SaccAirVehicle`) fail to compile; split them.
* Strings default to `""` rather than `null` (typed `String` slots cannot hold null) while
  string array elements are null; `s == null`, `??` and `string.IsNullOrEmpty` treat both as
  null.
* Integer arithmetic is 64-bit; wrapping is emulated only at explicit casts (`(int)`, `(byte)`…).
* `Rigidbody`, `Collider`, `Renderer` and friends map to the *node* the GameObject became.
  `MaterialPropertyBlock` values are applied to the renderer's instanced material.
* The sandbox cannot read computed properties of built-in values (`Color.h`, `Rect2.end`);
  the catalog avoids them (`U.color_hsv`, `position + size`).
* Not supported by Udon and therefore not converted: lambdas/delegates, generic collections,
  `try`/`catch` (the try block is kept), `goto`, constructors.
* Udon *graph* programs: decompile them to C# first with
  [udon_flat](https://github.com/V-Sekai-fire/udon_flat), then convert.
* Reports flag members that are not Udon externs at all (they would not compile in VRChat
  either) separately from members the catalog does not map yet and from stubs; add mappings in
  `data/api/`.

## Layout

```
src/            compiler (lexer, parser, ast, program, api catalog, template, lower/, gd emitter, main)
data/api/       API catalog: system*, unity_math, unity_core, unity_physics, unity_misc, unity_2d,
                unity_extra, vrc, vrc_extra (hand-written) and generated.udon (stubs)
data/known_externs.txt  Udon extern signatures (from udonweft)
tools/gen_catalog.py    stub generator; tools/sandbox_build/ source-built godot-sandbox (MAX_LEVEL 16)
runtime/addons/udon_runtime/   Godot addon: udon_behaviour.gd, udon.gd, u.gd, udon_world_provider.gd,
                udon_network_provider.gd, udon_player.gd, adapters (pickup, station, object sync/pool, video)
tests/          Rust integration tests, C# fixtures and tests/coverage/ API fixtures
godot_project/  Godot 4.6 test project: e2e_counter.gd, coverage_runner.gd, net_test.gd, compile_check.gd
scripts/        verify.sh, coverage_test.sh, net_test.sh
```
