# udon2godot TODO

Status legend: [x] done and verified, [~] implemented but needs more coverage, [ ] open.

- [x] Upstream fixed the 1MB direct-jump limit. Update the upstream godot-sandbox tooling to get the fixes.
      `refs/godot-sandbox` is at upstream main + the `MAX_LEVEL = 16` patch; the rebuilt library is in
      `tools/sandbox_build/` and `godot_project/addons/godot_sandbox/bin/`. All 108 corpus scripts compile
      (SaccAirVehicle included); the math coverage fixture was split anyway (TMath/TMathB).
- [x] Unicode identifiers crash the converter. The lexer slices on char boundaries now and non-ASCII
      identifiers are transliterated (`φ` → `phi`, `Δθ` → `Deltatheta`, other chars → `_uXXXX`).
- [x] Full scene and prefab converter through unidot_importer. `scripts/import_world.sh <unity assets> <out>`
      converts the scripts, assembles a Godot project from `godot_world_template/`, and runs unidot headless
      (fork branch `udon-integration` in `refs/unidot_importer`: `headless/` command-line driver,
      `udon_integration.gd` importer plugin, plugin hooks in `object_adapter.gd`). Diagnostics:
      `scripts/world_doctor.py <out>`, `<out>/udon_import_report.json`, `<out>/unidot_import.log`.
- [x] Coordinate convention agreed with unidot. `U.coord_mode = UNIDOT` (default for imported worlds via
      `udon/coord_mode`): scripts compute in Unity numbers, every value crossing to a node is mirrored
      (positions x → -x, rotations (x,-y,-z,w)); cameras/lights carry their half-turn. Fixture `TCoord`
      builds the scene the way unidot does and checks forward/Euler/LookRotation/raycasts/velocities
      (34 checks); `tests/unity_fixture` is a hand-written Unity scene (transforms, references, arrays,
      colliders, a wired Button) imported through the real pipeline and checked by its converted script
      (`scripts/test_unity_fixture.sh`, 24 + 8 checks).
- [x] CI: `scripts/ci.sh` runs verify, coverage, net, the Unity fixture and the billiards import +
      scenario sequentially (one Godot at a time).
- [~] Canvas scene conversion and UnityEvent wiring. RectTransform GameObjects become Controls
      (Button/Toggle/Slider/LineEdit/OptionButton/Label/RichTextLabel/TextureRect), world-space canvases
      become SubViewport + quad (sized to the union of their content, nested canvases are containers),
      overlay canvases a CanvasLayer; `Button.onClick`/`Toggle`/`Slider`/`InputField` persistent calls
      connect to `SendCustomEvent` (26 wired in the billiards table). Open: TMP fonts/sprites/9-slice
      fidelity, layout groups, Dropdown item templates, ScrollRect contents.
- [x] Test hooks: `U.ui_press(node, value)`, `U.ui_click_world(canvas, point)`, `Udon.simulate_key/axis/
      button/mouse_*`, `Udon.input_event("InputJump", ...)`; `world_runner.gd --scenario` drives a world
      (`godot_world_template/scenarios/billiards.gd` opens the lobby, joins, starts 8-ball and plays a
      break: `scripts/test_world_billiards.sh`, SCENARIO PASSED).
- [x] UdonBehaviour serialized properties and references: exported values are converted by type
      (manifest from `udon2godot --manifest`), references resolve after the scene exists and are stored
      as NodePaths in `metadata/udon_refs`, bound by `udon_behaviour.gd` at `_ready`; prefab-instance
      overrides (`field.Array.data[i]`) are applied; `UdonBehaviour` component settings (interact text,
      proximity, sync method, enabled) land in `metadata/udon_behaviour`.
- [x] GetComponent/Transform.Find follow unidot conventions: component helper children (MeshRenderer,
      colliders as StaticBody3D/Area3D named after the collider, AudioSource, Camera ...), child
      GameObjects skipped by GetChild/childCount, Unity names sanitised the way Godot does
      (`intl.table` → `intl_table`), canvas children found through the viewport.
- [x] Prefab-typed fields: prefab assets referenced by scripts become inactive template nodes under
      `UdonPrefabs` (sandbox exports are Node-typed); `Udon.instantiate` duplicates them and also accepts
      PackedScene.
- [~] Animator: `Animator.Set*/Get*` write unidot's `runtime/anim_tree.gd` metadata parameters
      (`metadata/<param>`), triggers map to `parameters/<name>/request` or conditions. Not yet exercised by
      an imported controller.
- [~] Official pool table (MS-VRCSA-Billiards): converts (30 classes, 0 errors), imports, runs; the
      scenario plays a break and screenshots render the table with its skybox, ball shadows (ported
      shader), cast shadows (`world_runner --shadows`) and UI boards. Open: cue/desktop interaction
      through a player controller, the 12 scripts the package does not ship (reported by the doctor),
      ports for the remaining 12 custom shaders (table cloth detail, scorecard, timer, guideline).
- [x] Custom shaders: unidot's material conversion reads ShaderLab render state (blend, ZWrite, Cull,
      ZTest, queue, unlit), converts skybox shaders to sky materials, and uses hand-written Godot ports
      from `unidot/shader_ports` (`runtime/addons/udon_runtime/shader_ports/`, named after the Unity
      shader) when present; the doctor lists shaders that were approximated. Cubemap skyboxes from
      cross/strip layouts are not stitched yet (only lat-long sources).
- [~] Unimplemented behaviours: audited the 8,444 generated `!stub` entries. None is used by the three
      corpora (their 15k API uses all hit hand-written mappings), so the audit ranked stubs by type:
      half are static duplicates, the rest are ParticleSystem modules (~1,000), Physics2D, UI internals
      (Selectable navigation/OnPointer*, layout), TMP layout properties, texture streaming, camera
      physical parameters, NavMesh, VRCPhysBone curves. Filled the plausible gaps in engine types:
      Physics.BoxCast/CapsuleCast/*All/*NonAlloc with real shape sweeps, OverlapCapsuleNonAlloc,
      GetIgnoreCollision, Rigidbody.SweepTestAll, Matrix4x4 elements/indexers, Vector3/Quaternion
      indexers (coverage 575 checks). Remaining stubs are per-feature work (particles, 2D physics,
      TMP layout); the 260 unmapped externs are UnityEngine.Random (mapped as `U.random_*`) and operators.
- [x] RenderTexture: `UdonRenderTexture` resources (from `.renderTexture` assets or `new RenderTexture`)
      get a SubViewport on first use (`U.rt_viewport`); `Camera.targetTexture` renders through a proxy
      camera inside it; materials receive the viewport texture.
- [ ] Switch from the hand coded parser to a more standard Rust idiom. Deferred: the hand-written parser
      handles all corpora with zero errors; a differential test against tree-sitter-c-sharp would be the
      cheaper way to find parse gaps.
- [~] VRC SDK component nodes: VRC_Pickup (by GUID) and, by field signature, VRCStation, VRCObjectSync,
      VRCObjectPool, VRC_MirrorReflection, VRC_SceneDescriptor, VRC_AvatarPedestal, VRC_PortalMarker,
      video players are marked with `udon_<kind>` groups + metadata read by the adapters; more GUIDs can
      be added through `udon/component_guids`. Only VRC_Pickup is exercised by the billiards table.
- [~] Project settings conversion: `scripts/unity_project_settings.py <ProjectSettings> <out>` writes
      layer names, gravity, fixed timestep, tags, the layer collision matrix (`udon/collision_matrix`,
      applied to imported bodies) and InputMap actions; `import_world.sh` runs it when a ProjectSettings
      folder sits next to the assets. VRChat's fixed layer table is the runtime default.
- [ ] Udon graph programs: udon_flat is a Unity editor tool (C#) and cannot run here; supporting graph
      assets needs a uasm → C# (or → SafeGDScript) decompiler in this repo.

## Stub backlog

`data/api/generated.udon` started with 8,444 `!stub` entries (4,250 distinct instance members in 318
types; the rest are static twins) and holds 72 after the items marked done. Each item below names the types, the count of instance stubs and how they
get implemented: *engine* = mapped to real Godot behaviour, *stored* = value round-trips through
`U.prop_get/prop_set` (metadata) but has no engine effect, *no-op* = intentionally inert (editor-time,
reflection, platform). Re-run `tools/gen_catalog.py` after each item so the generated file shrinks.

- [x] Enums stubbed with value 0 (22 types, ~170 members): TextAlignmentOptions, Horizontal/Vertical
      AlignmentOptions, TextOverflowModes, RegexOptions, CubemapFace, HandType, UdonInputEventType,
      VRCInputMethod, VRCImageDownloadState/Error, VideoError, DataError, TokenType, JsonExportType,
      MirrorClearFlags, CollectObjects, NavMeshCollectGeometry, SpritePackingMode/Rotation,
      TextRenderFlags, VertexSortingOrder → real values; generator learns that `enum` lines are mappings.
- [x] `!stored` catalog marker + `U.prop_get/prop_set` (node metadata / struct dictionaries) so
      approximated properties round-trip; the report and doctor list them apart from no-ops.
- [x] Particles (≈790): ParticleSystem 37, ParticleSystemRenderer 61, ShapeModule 78, MainModule 60,
      NoiseModule 54, CollisionModule 50, TrailModule 42, TextureSheetAnimation 37, LimitVelocity 32,
      VelocityOverLifetime 30, Lights 24, SizeBySpeed 22, Trigger 20, ExternalForces 18, RotationBySpeed 18,
      ForceOverLifetime 16, RotationOverLifetime 16, SubEmitters 15, SizeOverLifetime 14, CustomData 10,
      InheritVelocity 8, ColorBySpeed 6, Emission 2, Burst 2, MinMaxCurve 7, MinMaxGradient 7, EmitParams 27,
      Particle 24. Done: `tools/gen_particles.py` → `data/api/unity_particles.udon` (every module member;
      engine-mapped main/emission/shape/velocity/limit/force/colour/size/rotation/noise/collision/
      sheet/trails/renderer, the rest `!stored`), MinMaxCurve/MinMaxGradient as float/Color-or-
      Dictionary structs with curves and gradients, playback state (time, paused, one-shot), bursts,
      EmitParams/Particle dictionaries; unidot fork converts ParticleSystem + ParticleSystemRenderer to
      GPUParticles3D (commit "ParticleSystem → GPUParticles3D conversion"); coverage TParticles (37
      checks incl. engine-side verification) and the Unity fixture's imported emitter (11 + 5 checks).
- [x] UI (≈1,100): `tools/gen_ui.py` → `data/api/unity_ui.udon` (Selectable state/navigation/ColorBlock/
      SpriteState, Graphic canvas/depth/raycast/native size, TMP alignment/overflow/wrapping/alpha/RTL/
      max lines, Mask/RectMask2D clipping, Outline/Shadow theme overrides, AspectRatioFitter,
      LayoutElement/LayoutUtility sizes and flexible flags, Dropdown option data, ToggleGroup, Sprite
      rect/pivot/ppu/Create, Canvas pixelRect/root/scale, UI enums, UnityEvent signals; Unity layout/
      event-system internals are plain no-ops, the rest `!stored`). The converter passes Unity names for
      Control-based components and the runtime resolves them (`_TYPE_ALIASES`, "@clip"/"@meta:" rules).
      Importer: Outline/Shadow, Mask, LayoutElement, AspectRatioFitter, CanvasGroup (fork commit "UI: …").
      Coverage TUI 60 checks with engine-side verification; Unity fixture 40 + 16 checks.
- [x] System (≈330): TimeSpan parsing/arithmetic, DateTime/DateTimeOffset/TimeZoneInfo, CultureInfo and
      format providers as dictionaries, Convert/BitConverter widths, Guid (canonical strings, byte
      layout), Encoding, Regex collections, StringBuilder indexer, `System.Random` as an extern alias of
      the Unity mapping, Vector2Int/Vector3Int/Vector4/Vector2/Vector3/Quaternion/Mathf/Color/Color32
      extras, Rect/Plane/Bounds/Matrix4x4 setters (`data/api/system_extra.udon`, `unity_math.udon`;
      coverage TSystem 37 checks).
- [x] Physics 3D (≈200): collider/rigidbody includeLayers/excludeLayers folded into the Godot
      collision mask, GetAccumulatedForce/Torque (forces tracked per physics step), Rigidbody.Move,
      automatic centre of mass / inertia, CapsuleCollider.direction (shape orientation), providesContacts
      (contact monitor), PhysicMaterial combine modes (rough/absorbent), PhysicsScene as the one world
      (every query overload), ControllerColliderHit(+Player) dispatched from CharacterController.Move,
      WheelHit/JointMotor/Collision extras; the rest `!stored`. Runtime: **OnTriggerEnter/Exit/Stay,
      OnCollisionEnter/Exit/Stay, the 2D and OnPlayer* variants are now dispatched** (udon.gd physics
      hub: areas hooked as they enter the tree, rigid bodies once a behaviour defines a collision
      handler, both sides of an event served); shape casts refine `cast_motion`'s 1/256 resolution and
      bound long sweeps with a ray; static catalog properties accept assignment (`Physics.gravity = …`
      used to be dropped). Coverage TPhysics 86 checks with engine-side verification.
- [x] Physics 2D (≈230): CapsuleDirection2D capsules, GetRayIntersection (3D ray against the z=0
      plane), Linecast/OverlapArea/OverlapCapsule NonAlloc, ContactFilter2D as a real dictionary filter
      (layer mask honoured by the filter overloads, depth/normal-angle tests), PhysicsScene2D (all
      overloads), ConstantForce2D as a component over RigidBody2D constant force/torque, SliderJoint2D
      limits ↔ groove length, JointSuspension2D/JointTranslationLimits2D, Collider2D.GetShapes,
      Physics2D sleep thresholds / time to sleep / solver iterations as live space parameters (the rest
      `!stored`). Coverage T2D 65 checks with engine-side verification.
- [x] Rendering and assets (≈500): Shader.PropertyToID ids resolve back to property names for
      materials, blocks and globals; texture sampler state (wrap/filter/aniso/bias) round-trips on
      the resource, texelSize/dimension/mipmapCount/updateCount are real; Cubemap and Texture3D are
      real Godot textures with pixel access (images kept on the resource: layered textures cannot be
      read back headlessly); Mesh vertex-attribute queries, custom bounds, CombineMeshes (merged or
      per-instance surfaces), extra UV sets stored; Renderer forceRenderingOff/bounds/localBounds
      (custom_aabb, particles visibility_aabb); physical camera → CameraAttributesPhysical
      (aperture, shutter, ISO, focus); GeometryUtility frustum planes / TestPlanesAABB /
      CalculateBounds / plane from polygon; SphericalHarmonicsL2 with real SH evaluation;
      VRCQualitySettings shadow distance / cascades / splits over the DirectionalLight3D;
      OcclusionPortal over OccluderInstance3D; Gizmos, editor-only camera bits and post-process
      volumes inert or stored. Coverage TMedia 88 checks with engine-side verification.
- [x] Navigation (≈270): NavMeshLink and OffMeshLink over NavigationLink3D (points, direction,
      area ↔ navigation layer bit, cost modifier ↔ travel_cost, activated ↔ enabled, transforms the
      link follows), NavMesh.AddLink/RemoveLink and AddNavMeshData as live NavigationLink3D /
      NavigationRegion3D nodes with instance handles, NavMesh.Raycast (walks the segment on the map),
      CalculateTriangulation from the scene's navigation meshes, query filters with area costs,
      build settings as Unity-default dictionaries, NavMeshModifier/Volume stored (bake-time).
      Coverage TNav 26 checks with engine-side verification.
- [x] Animation, constraints, humanoid, cameras (≈280): Unity Animations constraints and VRChat
      constraints are **solved by the runtime** (`U.solve_constraints`, deferred after every Update:
      position / rotation / scale / parent / aim / look-at with weights, axis masks, offsets, world-up
      modes, per-source parent offsets; every setting round-trips through the constraint store),
      AnimationCurve indexer / keys setter / CopyFrom / ClearKeys / wrap modes, Motion and clip
      statistics, AnimatorOverrideController as a clip map, humanoid tables (HumanTrait bone names,
      parents, required bones; HumanDescription / HumanLimit / SkeletonBone / AvatarMask
      dictionaries), Cinemachine damping maths and attachments, VRC camera dolly settings stored,
      System.Type reflection answers for plain classes. Coverage TAnim 26 checks with engine-side
      verification. Not done: the unidot fork does not convert Unity/VRC constraint *components*
      yet (scripts that configure constraints work; authored ones are dropped at import).
- [x] VRC SDK and last leftovers (≈300): PhysBone curves/limits/grab state stored, contact
      receivers/senders with distance-based CalculateProximity, per-object NetworkStats through the
      provider (`network_stat_for`), PlayerData typed TryGet* / GetKeys / IsType, MIDI data blocks
      with timing maths, Store/menu calls routed to the provider, drone and image-download
      leftovers, Gradient colour/alpha keys as real Godot gradients, TextAsset, HumanPose(+Handler),
      small structs and UnityEvent constructors; `destroyCancellationToken` on every component.
      Coverage: TVRC 73, TMedia 91, TSystem 39 checks.
- [ ] What is left in `generated.udon` (72 entries, 36 instance members): VRCCameraDollyPathPoint's
      Component boilerplate (it is a dictionary here), StringBuilder `Chars` indexer externs, two
      `List<T>`-taking Mesh methods (generics are not Udon), static-only twins.

## Next

- Reference player controller (desktop + VR input events, pickups, stations, interact proximity).
- Realistic rendering: lightmaps cannot be imported; `--shadows` substitutes real-time shadows. Ambient
  occlusion / GI fallback needs the Forward+ renderer (not available on the headless box).

## Long term

  - Physics fidelity: physics materials and combine modes, Rigidbody.interpolation, continuous collision
    detection, Jolt vs Godot Physics.
  - Video and network backends: video adapters are placeholders; VRCStringDownloader/VRCImageDownloader
    need real HTTP with allow-lists.
  - Networking beyond the two-process test: late joiners, 3+ peers, packet loss, dedicated server mode,
    server-side validation, persistent PlayerData storage, ENet vs WebRTC.
  - Sandbox policy: restricted mode profile with `U.*`/`Udon.*` as the security boundary.
  - Exception policy: Udon halts a behaviour after an exception; the sandbox aborts the call and
    continues.
  - Performance: per-frame host round-trip cost for Update-heavy scripts, binary translation settings.
  - Editor import plugin wrapping the headless pipeline.
