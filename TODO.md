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
- [x] Parser confidence without a rewrite: `tools/parser_diff.py` is a differential test against
      tree-sitter-c-sharp. `udon2godot --ast-summary` exports what the hand-written parser produced
      (types, members, parameter counts, per-member counts of statement and expression kinds) and
      the same summary is computed from tree-sitter's tree after applying the lexer's `#if`
      evaluation to the text. 164 files (tests + the three corpora) are structurally identical. It
      found one real bug: `#define` inside an inactive `#if` branch took effect (`#if UNITY_ANDROID`
      + `#define HT_QUEST` dropped the desktop-only guideline code of the pool table). Where the
      two disagreed otherwise, the hand-written parser follows the C# spec and tree-sitter does not
      (`f(a * b)` read as a pointer declaration, `(name) & x` read as a cast). `scripts/ci.sh` runs
      it when the Python packages are installed. The rewrite to a parser-generator idiom stays
      deferred: there is no known parse gap left to justify it.
- [~] VRC SDK component nodes: components referenced through the SDK DLL are identified by the
      DLL's class fileID (the DLL GUID alone used to mean VRC_Pickup: 51 of the pool table's 89
      "pickups" were spatial audio sources, object syncs and UI shapes; now 38 / 34 / 9), new kind
      VRCSpatialAudioSource; otherwise by field signature: VRCStation, VRCObjectSync,
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
- [x] `generated.udon` is empty and `--catalog-coverage` reports 21,941 / 21,941 (2026-09-16):
      StringBuilder's `Chars` externs are its indexer (`[IndexerName]`; `set this[int]` is a new
      catalog form, lowered for `sb[i] = c`), Mesh.GetBindposes/GetBoneWeights(List) clear the list
      like the array properties, VRCCameraDollyPathPoint (a dictionary here) answers the Component
      surface from the dictionary. The 56 primitive externs the generator skipped are mapped for
      real: decimal arithmetic, rounding modes, GetBits and constructors, char surrogates and
      UnicodeCategory, string ctors / IndexOfAny / LastIndexOfAny / CompareOrdinal / CopyTo /
      Intern / Normalize, Parse/TryParse of sbyte/ushort/ulong with NumberStyles, double
      infinities, `new object()`; TStrings covers them (868 coverage checks). Still marked `!stub`
      by hand: 87 entries in unity_ui / unity_particles / unity_extra (factory helpers, particle
      module internals).

## Interactive play: pointer, player, test apparatus

Playing an imported world with mouse and keyboard, not only through scenarios. Status of the
MS-VRCSA-Billiards import on 2026-09-15 (`scenarios/canvas_dump.gd` on the imported world, and
`--shot` from a wide view): the table, balls and physics are right; the world canvases are wrong.

- [x] Canvas planes are far too big, with the content displaced and stretched. Measured: the
      scorecard canvas (Unity rect 1.4 × 0.2 units at scale 1 → 1.4 m × 0.2 m) gets a 274 m × 55 m
      plane; the practice menu (`intl.menu`, Unity rect 0 × 0 at scale 0.005 whose children are
      300 × 100 px menus) gets a 100 m × 100 m plane with the viewport clamped at 8192 px, so the
      texture is stretched about 10× and every point on it maps to the wrong control. Causes, all in
      the fit-to-content step (`_finalize_world_canvas` in `udon_integration.gd` at import, `_fit` in
      `udon_canvas_plane.gd` at runtime): the union is taken over nested canvases and scaled Controls
      whose rects are in pixels while `Control.scale` (0.005) only scales their drawing, and at runtime
      `get_global_rect()` ignores `scale` altogether; when the viewport hits the 8192 px clamp the
      quad keeps the unclamped size instead of lowering the pixel density. Fix: compute child bounds in
      canvas units from the stored `udon_rect` data (anchors, offsets, pivot, scale applied around the
      pivot) recursively, skip inactive nodes, let nested canvases contribute only their scaled rect,
      and when the viewport would exceed the clamp, reduce `k` (pixels per unit) so quad, viewport and
      root scale stay consistent. Acceptance: every world canvas's plane equals the Unity rect × scale
      (within one child overflow that is really there), the plane centre stays where the Unity canvas
      is, and a point on the plane maps back to the control under it. Done: both fits take the union
      of drawing controls through `Control.get_transform()` (import: anchors/offsets, runtime: the
      laid-out tree); the second cause was `U.set_position` on Controls writing world metres into
      viewport pixels when scripts move menus onto table anchor spots (`setTransform(.MENU,
      MenuAnchor)`), now converted through the canvas node (`transform.position/localPosition/
      rotation/lossyScale` on RectTransforms). Verified by `tests/unity_fixture` UiCanvas (63 checks
      on the display: positions, viewport mapping, rendered colours at projected pivots, window
      clicks) and the billiards canvases (2.8 × 1.6 m menu, 1.4 × 0.95 m scoreboard).
- [x] Pointer → canvas input by raycast + `SubViewport.push_input` (mouse now, VR ray later). One
      `UdonPointer` node (runtime): each frame take the ray (camera through the mouse position, or a
      controller's -Z), `intersect_ray` against the `udon_ui_shape` areas (collide with areas, hit from
      the readable side only), convert the hit point to the plane's local XY, then to viewport pixels
      with the canvas config (`k`, `offset`, `pivot`, `plane_center`; X is mirrored because the quad
      faces -Z), and push `InputEventMouseMotion` / `InputEventMouseButton` (button mask, double click,
      hover enter/exit when the canvas under the pointer changes) into that canvas's viewport, the way
      `udon_canvas_plane.gd` already forwards input into nested canvases. Same pointer drives
      `Interact` on behaviours (proximity, `DisableInteractive`) and pickups (see below). Design after
      V-Sekai/interaction_system + canvas_plane (`interaction_system` branch): their
      `function_pointer_receiver` signals (`pointer_pressed/moved/release` with world points) are the
      seam; the raycast pointer emits the same signals so the Lasso-based manager (Voronoi snapping,
      good for VR, needs the engine module) can replace the picking step later, both stay possible.
      Keep `U.ui_click_world(canvas, point)` as the scripted path and make it share the math.
      Done for the mouse: `udon_pointer.gd` (`Udon.pointer()`), hover enter/exit, Interact and
      pickups on solid hits, `set_ray`/`press`/`release` for other sources. Open: a VR/controller
      source, Lasso snapping as an alternative picker, hover prompt in a HUD.
- [x] Desktop player controller (replaces the static `--spawn` body): `desktop_player.gd` in the
      runtime, spawned by `world_runner.gd --play` (and usable from any game). CharacterBody3D +
      capsule at the scene descriptor spawn, WASD / arrows, Shift run, Space jump, mouse look with the
      mouse captured, Esc/Tab frees the mouse for canvases. Provides VRCPlayerApi data: position,
      rotation, velocity, grounded, tracking data (Head = camera, hands = camera offsets), eye height.
      Input plumbing in `udon_world_provider.gd`: `Horizontal`/`Vertical` from WASD actions
      (registered with `InputMap.add_action` at startup when the project has none), `Mouse X`/`Mouse Y`
      from the relative mouse motion of the frame, `Jump`/`Fire1` buttons, `Udon.input_event`
      (InputJump/InputUse/InputGrab/InputDrop/InputMove*/InputLook*) fired from the same actions.
- [x] Pickups and Interact from the pointer: hover shows `InteractionText`, left click / E on a
      behaviour with `Interact` calls it (within `proximity`); on a `udon_pickup` node the click picks
      it up (`OnPickup`, held at a hand offset in front of the camera, `exact_gun`/`exact_grip`
      orientation), left mouse while held = `OnPickupUseDown/Up`, drop with G / right click (`OnDrop`).
- [x] Test apparatus for interaction: (1) a test scene in `tests/unity_fixture` with a world canvas
      (buttons, toggle, slider at known Unity coordinates, one nested canvas, one scaled one) and a
      screen-space canvas; (2) scenario API in `world_runner.gd` that drives real input through the
      window: `r.mouse_move(px)`, `r.click(px)` (`Input.parse_input_event`), `r.key(KEY_E)`,
      `r.look_at_node(n)`, `r.click_node(n)` (project the control's world centre through the camera to
      window pixels, then click there); (3) checks: the pixel the pointer computes for a control equals
      the control's own rect (math roundtrip both ways), the button's `pressed` fires, the slider
      value changes, nested and scaled canvases respond; (4) screenshots after each step with the hit
      point drawn, kept in `out/` for eyeballing; (5) the fixture run is part of `scripts/ci.sh` under
      the X display like the billiards shots. Done: UiCanvas in the fixture (corner/centre buttons,
      2× container, nested canvas), `world_runner.gd` scenario API (`project`, `pixel`, `capture`,
      `mouse_move`, `click`, `key`, `camera`, `--face` for canvases), `scripts/test_unity_fixture.sh`
      runs the display pass when DISPLAY is set. Also covered (74 checks on the display): a Slider
      dragged through the pointer (HSlider, onValueChanged), a Toggle, an InputField typed into
      through the window (the pointer forwards keys to the last clicked canvas) and submitted with
      Enter (onEndEdit), and a screen-space canvas button (Godot's own GUI; its full-window root
      must ignore the mouse or it swallows every click meant for the world). Clicks driven by a
      scenario draw a red ring on the HUD for two seconds so screenshots show where they landed.
      Dropdown and ScrollRect are covered too (83 display checks): the Dropdown (OptionButton) opens
      its popup inside the canvas viewport and the third option is picked through the pointer
      (onValueChanged, `dropdown.value`); the ScrollRect becomes a ScrollContainer with
      `udon_scroll_rect.gd` (Unity's stretched Viewport child expands and takes the content's size
      as its minimum, `scrolled` = ScrollRect.onValueChanged with the normalized position), the
      pointer forwards the mouse wheel, a hidden item is scrolled into view and clicked, and masks
      and scroll rects clip what they hold when the canvas plane is fitted. Unity's own Scrollbar
      objects are real scroll bars now (VScrollBar / HScrollBar by direction, value 0..1,
      `GetComponent<Scrollbar>` finds them) and a ScrollRect's `m_VerticalScrollbar` /
      `m_HorizontalScrollbar` are linked both ways (`scrollbar.value = 0` scrolls a console to
      the bottom); a Dropdown's caption is Unity's own Text child, kept up to date by
      `udon_dropdown.gd` (the OptionButton's own text and arrow are invisible), and
      `dropdown.value = i` raises onValueChanged (fixture 84 / 117).
- [x] Desktop player controller: done as `udon_desktop_player.gd` (`world_runner.gd --play`,
      `scripts/play_world.sh`), `scenarios/player.gd` on the fixture (walk, strafe, jump, tracking
      data, Esc frees the mouse, clicks through the player camera). Stations: the pointer offers
      "Sit" on a `VRCStation` collider, a click seats the player (use_station, OnStationEntered),
      the body follows the enter location and ignores locomotion, Space leaves through the exit
      location (OnStationExited); `Chair.cs` + the Chair box in the fixture, 21 checks. Fixed on the
      way in the importer: forward references inside component settings (a station's exit location,
      a pickup's ExactGrip) were misfiled into `udon_refs` instead of the component config, and
      references to children not built yet were dropped. `VRCPlayerApi.UseAttachedStation()`
      seats the player in the station of the calling behaviour (`Udon.use_attached_station(player,
      self)`: its node, else the nearest station below or above it). The fixture has a
      VRC_SceneDescriptor whose spawn is a child object (array references to nodes built later
      resolve through the pending list): the player spawns there and respawns below
      `RespawnHeightY` with OnPlayerRespawn.
- [~] VR input: `udon_vr_player.gd` (`world_runner.gd --vr`) is an XROrigin3D with the headset camera
      and two XRController3D nodes on the aim pose; each hand owns a pointer (`Udon.pointer("left" /
      "right")`, fed by `set_ray`) so the trigger presses world canvases, calls Interact and seats
      the player in stations, the grip grabs and carries pickups (trigger = use while held), the
      left stick walks along the head's yaw, the right stick snap-turns, A/X leaves a station.
      `IsUserInVR()` is true, tracking data comes from the headset and controllers, and InputUse /
      InputGrab / InputDrop / InputJump / InputMove* carry the hand (`UdonInputEventArgs.handType`;
      InputUse now fires on every use press, as in VRChat). `--vr-sim` runs the same player with
      plain nodes as controllers: `scenarios/vr.gd` (16 checks, part of the fixture test) aims each
      hand at a canvas button and pulls the trigger, checks the hand type the script receives,
      tracking data, stick locomotion, snap turn, and sitting and leaving a station. Not done: a run
      on real OpenXR hardware, Lasso snapping as an alternative picker, hand-held UI laser visuals
      beyond a thin ray.
- [x] Godot 4.7.2 and the latest unidot_importer (2026-09-15): `origin/main` (the 4.7 parse fixes and
      the ImageMagick check) merged into the fork branch `udon-integration` without conflicts;
      `scripts/*.sh`, `scripts/setup_deps.sh`, the project features and the README moved to 4.7.2.
      verify, coverage, the fixture (headless, display, player) and the billiards import + scenario
      all pass on 4.7.2. 4.7 defaults to Jolt Physics: the desktop player first fell through the
      fixture's floor there and worlds were pinned to Godot Physics for a day. The cause was not the
      scaled collider (a unit BoxShape3D under a (10, 1, 10) node works in Jolt) but the spawn snap:
      Jolt registers a new body at once, so the downward ray hit the player's own capsule. The spawn
      is now computed before the body is added, jumps are buffered for 0.15 s and the floor snaps
      (Jolt reports floor contact a step later); the pin is gone and the fixture (50 / 74 / 25
      checks) and billiards (9 + 17) pass on Jolt as well as on Godot Physics.
- [x] Billiards played interactively: `scenarios/billiards_play.gd` (16 checks) drives the game only
      through window input: the START canvas button through the pointer, Mode8Ball and Play (the
      opener is seated automatically, JoinOrange stays hidden), the orange cue grip picked up through
      the pointer (VRC_Pickup → OnPickup → DesktopManager.holdingCue), E enters the desktop aiming
      view, mouse deltas put the cursor on the apex ball, Mouse0 held + pull back builds power,
      release fires the shot and the balls move. Found on the way: `Input.GetKey(KeyCode.Mouse0)`
      never read the real mouse (the provider rejected mouse keycodes before its mouse branch).
      `scripts/test_world_billiards.sh` runs it headless (PLAY_SHOTS=1 on the display with
      screenshots); `scripts/play_world.sh <world>` launches it for a person.

## Overload-level extern coverage

Catalog coverage (100 %) is counted per member *name*. UdonEssentials' player list showed the hole:
`byte.Parse(hex, NumberStyles.HexNumber)` fell back to the one-argument `byte.Parse` and parsed
hex as decimal. `udon2godot --coverage-overloads` lists every extern whose name is mapped while no
mapping accepts those arguments (count and catalog types; unknown types match anything, numeric
types match each other, a base type accepts a derived one, an int parameter accepts an enum):
1344 on 2026-09-16 (675 by argument count alone), 0 on 2026-09-17.

- [x] Audit tool: `--coverage-overloads`, comparing argument types, with the extern signature split
      fixed for `VRC_Pickup` / `TMP_Dropdown` style names (`VRCSDKBaseVRC_PickupPickupHand` is one
      argument).
- [x] System types: integer and float `Parse` / `TryParse` with `NumberStyles` / `IFormatProvider`,
      `ToString(format, provider)`, `string` ranges and `StringComparison` forms (the two older
      `IndexOf` / `StartsWith` mappings ignored the comparison), `string.Format(provider, ...)`,
      `char.IsX(string, int)`, `Convert.ToX(object|string, provider)` and `(string, base)`, `Array`
      ranges (`BinarySearch` now returns the complement for a missing value), `StringBuilder`,
      `DateTime`, `Encoding`, `Regex`.
- [x] Unity 3D types: every `Physics` cast / check overload that takes a `Ray` or omits trailing
      arguments, `Rigidbody.AddRelativeForce(x, y, z)` family, `Transform.TransformVector(x, y, z)`,
      `GetComponentInParent(Type, bool)`, `Vector2.SmoothDamp`, `Vector3.OrthoNormalize` (3 refs),
      `Mathf.SmoothDampAngle` (5 args), `Rect` (inverse rects), `Bounds.Expand(Vector3)`,
      `ToString(format)` of colours / quaternions / bounds / rays, `Debug.Log*Format(context, ...)`,
      `Material` / `MaterialPropertyBlock` by property id, `Mesh` ranges and update flags,
      `Texture2D` mip arguments.
- [x] `List<T>`-taking overloads (975): skipped by the audit, U# cannot create a `List<T>`.
- [x] 2D physics: depth-range variants map like the sibling without them (Godot 2D has no depth),
      `ContactFilter2D` variants apply the filter's layer mask.
- [x] Overload resolution uses catalog relations: a derived argument fits its base closely
      (`CultureInfo` is an `IFormatProvider`), an enum never stands in for a class or another enum.
      Found by the new fixture: `int.Parse("42", CultureInfo.InvariantCulture)` picked the
      `NumberStyles` overload.
- [x] Fixture `TOverloads.cs` (28 checks) + 7 ray / check overloads in `TPhysics.cs`; coverage is
      920 checks. `scripts/ci.sh` fails when either audit reports a gap (0 / 0 now).
- [x] `scripts/diff_converter_output.sh`: converts every reference repo with the last committed
      converter and with the working tree and prints the generated lines that differ. It caught
      what no suite did: a bare `type ParticleSystem` block in a file that loads before the
      declaration turned typed fields into Variant (a declaration now overrides an earlier bare
      block; unit test). For this batch the diff is 6 lines, all intended.

## Community prefab worlds: import and run

The eight community repositories convert (see "Long term"); none has been imported as a scene and
run yet. The ones that ship an example scene go through `scripts/import_world.sh` and get a
scenario, like the pool table.

- [x] `scripts/setup_deps.sh --community` clones the eight repositories at pinned commits (they
      are not needed for the core suites).
- [x] EmyChess `ExampleScene.unity`: imports (24 scripts attached, 74 UI nodes, 13 wired events, 17
      pickups, 0 unresolved references; the one unknown script is the SDK's pipeline manager) and
      `scenarios/emychess.gd` passes 20 checks: both sides register, the imported Start button
      starts the game, 32 pieces, 1. e4, an illegal pawn jump is rejected, 1... e5, 2. Nf3,
      2... d5 3. exd5 captures (31 pieces, white scores), a blocked bishop move is rejected, end.
- [x] UdonEssentials `UdonEssentials_ExampleScene.unity` (an UdonSharp 0.x package, see the next
      section): `scenarios/udon_essentials.gd` passes 16 checks: the player list adds an entry
      with the local player's name (instantiated from the UI prefab nested in the list), online
      count, instance master, clocks tick; SimplePlayerSettings applies walk / run / jump on join;
      Groups answers; the EventDispatcher prefab dispatches Update / LateUpdate / FixedUpdate to
      a registered receiver and stops after removal. 84 fields on 5 proxy-less behaviours, 2
      variable-table overrides of the scene.
- [ ] UdonUtils `RuntimeTestingExample.unity`: the package's own `TestController` runs its test
      cases in the imported world; the scenario reports its pass / fail counts.
- [~] `scripts/test_world_community.sh` runs them (skips what is not cloned, re-imports when the
      importer changed); EmyChess so far. Not part of `ci.sh` yet.
- [~] Whatever the imports expose in the converter, importer or runtime is fixed at the source and
      covered by a fixture check (not patched in the scenario). So far: EmyChess lost its menus
      (3 UI nodes, 27 unresolved references): a Canvas parented to a node of a model / prefab
      instance is a RectTransform child of a *stripped* Transform, and unidot only collected
      Transform children there (fork 3de6a94: 74 UI nodes, 13 events, 0 unresolved). The Unity
      fixture now has a prefab (`Holder.prefab`), an instance of it and a canvas under the
      instance's child (4 checks; fixture 54 / 87 / 25 / 16). The fixture scene and `Chair.cs`
      shared a GUID; the scene has its own now. EmyChess' `Board` and `DefaultRules` did not
      load: "Undefined label: for_end_N" from the sandbox's SafeGDScript compiler. Its generic
      `for x in <iterable>` path pushed a loop context and a scope, then returned into the batched
      array / string walk without popping them, so a `break` after a nested loop targeted the
      inner loop's never-emitted end label (still so in upstream main). Fixed in the fork
      (godot-sandbox e649bf2, compiler regression test), library rebuilt and tracked, coverage
      check in `TExt.cs` (921 checks); world test scripts refresh the library of a reused world.
      `[HideInInspector] public` fields are serialized by Unity, the converter emitted them as
      plain `var` and their saved values were lost (each chess piece's `type`, `board`, `pool`;
      also the pool table's hidden cloth colours): they are `@export_storage` now. Overrides of
      scripted components inside nested prefab instances arrive in unidot as a virtual object
      without `m_Script` and were ignored; reference overrides were additionally queued against
      an owner that never matched and written into a shared dictionary, so nothing was saved
      (fork 66854ef + next). Fixture: `Holder.prefab` with a scripted child, `Outer.prefab` nesting
      it, value and reference overrides from the scene and from the outer prefab, hidden fields
      (62 / 95 / 25 / 16 checks). `a && f(out x)` / `a || f(out x)`: the statements the right
      operand needs used to run unconditionally (a warning said so), which breaks the usual
      `x != null && x.TryGet(out y)` guard; they are now inside `if _t:` / `if not _t:` with the
      declared locals kept outside (TExt checks the side effects; the pool table's desktop
      button raycast is guarded by its state again). Attribute / editor / exception classes are
      skipped instead of lowered (UdonUtils: 67 warnings and 2 errors -> 4 warnings).

## Unity UI layout groups

UdonEssentials' player list adds its entries under a `VerticalLayoutGroup` + `ContentSizeFitter`;
the importer ignored layout components, so an instantiated entry had zero width (its anchors
stretch over a parent that Unity sizes through the layout) and the list showed nothing.

- [x] `udon_layout_group.gd` (runtime, on a helper child so the Control keeps its script slot):
      Horizontal / Vertical layout (padding, spacing, child alignment, childControlWidth/Height,
      childForceExpandWidth/Height, reverse arrangement; minimum -> preferred -> flexible
      distribution as in Unity), Grid layout (cell size, spacing, start corner / axis, constraint),
      `ContentSizeFitter` (grows away from the pivot), `LayoutElement` (min / preferred / flexible,
      ignoreLayout); re-layout when children are added, removed, shown, hidden or resized.
- [x] Importer: layout components become `udon_layout` / `udon_fitter` / `udon_layout_element`
      metadata and the helper is added.
- [x] Fixture: a vertical list with a fitter that receives instantiated entries (and loses a hidden
      one), a horizontal row with a preferred and two flexible elements (1 : 2), a two-column grid;
      positions and sizes checked (fixture 95 / 130). Found on the way: `transform.childCount` /
      `GetChild` did not count UI children (every Control was taken for a component of its
      parent), so `content.childCount` was 0 and `row.GetChild(4)` null.
- [x] UdonEssentials scenario checks the entry's rectangle (17 checks); the screenshot shows the
      list with "1 / 1", the master's name and the local player's row.
- [x] `DateTime.ToString` / `TimeSpan.ToString` custom formats: a tokenizer for `yyyy yy MMMM MMM
      MM M dddd ddd dd d HH H hh h mm m ss s f.. tt t`, quoted and escaped literals, the standard
      one-letter formats, day of week; `hh\:mm\:ss` for time spans (coverage 928).

## UdonSharp 0.x scenes (no C# proxy components)

UdonEssentials (2021) is an UdonSharp 0.x package: its prefabs carry only `UdonBehaviour`
components. Field values are not YAML keys of a proxy MonoBehaviour but live in
`serializedPublicVariablesBytesString` (base64 of Odin Serializer's binary format holding a
`UdonVariableTable`), object references are indices into `publicVariablesUnityEngineObjects`.
The importer attached the scripts ("missing proxies: 5") and every field kept its default.

- [x] Decoder for the Odin binary entry stream in the unidot plugin (`udon_odin.gd`): named /
      unnamed nodes, arrays, primitive arrays, primitives, strings, type names and ids, internal
      and external references; `UdonVariableTable` -> `{symbol: {type, value}}`. Structs come as
      positional floats, primitive arrays as one packed block (checked against UdonEssentials).
- [x] Behaviours without a proxy get their exported fields from the decoded table through the same
      conversion as proxy fields (values, structs, arrays, references): UdonEssentials 72 fields
      on 4 behaviours.
- [x] Prefab-instance overrides of `serializedPublicVariablesBytesString` and of
      `publicVariablesUnityEngineObjects.Array.data[i]` (the node keeps which object index each
      reference field uses). An override that re-points a field at another object *of the source
      prefab* is reported as unsupported.
- [x] Fixture: proxy-less `Legacy` behaviour in the scene and `LegacyBox.prefab` with instance
      overrides; tables written by `tools/odin_encode.py` (float, int, bool, string, Vector3,
      Color, reference, reference array, float and string arrays, null). Also `Item.prefab`, a UI
      prefab with a RectTransform root used as an instantiation template (unidot typed prefab
      roots as Node3D and dropped such prefabs). Fixture 74 / 107 / 25 / 16.
- [x] UdonEssentials scenario: player list entry, player settings, groups, event dispatcher (16
      checks, see "Community prefab worlds").

## Next

- VR on real OpenXR hardware (the player and per-hand pointers exist and pass with simulated
  controllers), Lasso snapping as an alternative picker.
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

  - Let's keep trying some more Udon prefabs. There are hundreds out there. Converter-level status
    (2026-09-16, `udon2godot --check --report refs/<repo>`, clones are not part of setup_deps.sh):
    UdonEssentials 6 classes, EmyChess 13, UdonCombatSystem 32, UdonZip 2,
    vrchat-3d-model-loader-tablet 29, vrchat-glb-loader 16, VUdon-Udonity 94, UdonUtils 150: all
    convert with 0 errors except two lambdas in UdonUtils' reflection helper (not Udon). Fixed on
    the way: a stack overflow on chained `new const` values across classes (constants are now
    inlined in the declaring class's context with a re-entry guard), `using A = B;` inside a
    namespace, index initializers, and object / collection initializers (they were dropped). All
    324 files match tree-sitter structurally. Second pass (same day): user extension methods
    (`this T x` parameters, resolved after the catalog), statics of classes with no live instance
    (`Udon.call_static` / `static_get` create a holder node lazily), qualified base names
    (`Varneon.VUdon.Editors.Foo` -> `Foo`), user types that shadow a catalog type fall back to the
    catalog member, nine more Unity enums, `Type.Equals`, VUdon-style array extensions, and arrays
    that are initialised with or compared against null stay untyped in SafeGDScript. Coverage fixture
    `TExt.cs` (878 checks in total). Third pass: `out` / `ref` arguments (and `out var x`
    declarations) of cross-class static and extension calls were dropped, they now use the same
    `[ret, out...]` path as same-class calls; generic method parameters are bound from the type
    arguments or inferred from the arguments, so `out var x` of a `T` parameter gets a real type;
    `out string x` locals start as "" instead of a typed null. The "routed through
    Udon.call_static" warning is gone (that path is supported at runtime). Warnings now:
    UdonEssentials 4, EmyChess 1, UdonCombatSystem 3, UdonZip 0, model-loader-tablet 15,
    glb-loader 25, Udonity 72 (was 548), UdonUtils 120 (was 390). Fourth pass: enum values print
    as their member name (`ToString()`, interpolation, concatenation; a generated
    `_enum_name_<Enum>` helper per script, the e2e expectation `phase=0` was wrong and is now
    `phase=Idle`), a user enum wins over a same-named nested catalog enum (`Mode` vs
    `Navigation.Mode`), a base class from a package outside the sources makes the class a
    behaviour (`ConsoleWindow : UdonLogger`) instead of a plain Node, C#'s "Color Color" rule
    (`TestController TestController;` + `TestController.ExecutionOrder`), namespace-relative type
    paths (`Runtime.Pool.Pool`), BCL aliases (`Single.Parse`, `Int32.MaxValue`), `GetType()` /
    `ToString()` of System.Object on any type and on `this`, inherited setters without `this.`
    (`name = ...`), setters on a field whose type is shadowed by a user class
    (`toggle.interactable`), `dict[computed key] = v` was dropped when the key came from a
    template, locals shared between `switch` sections are declared before the `match`, static
    helper classes no longer warn. Warnings now: UdonEssentials 3, EmyChess 0, UdonCombatSystem 0,
    UdonZip 0, model-loader-tablet 11, glb-loader 23, Udonity 42, UdonUtils 67 (coverage 885
    checks). What is left is mostly packages that are not in the clones (UdonLogger,
    EnumResolver, UdonAssetDatabase), editor-only code and see "Overload-level extern coverage".
    Not done yet for these: scene import and runtime scenarios, the remaining
    unmapped members and "unknown type" warnings. Examples:
    1. https://github.com/Varneon/UdonEssentials (Console, Event Dispatcher, Player list)
    2. https://github.com/emymin/EmyChess
    3. https://github.com/Toly65/UdonCombatSystem (might be hard to test without VR, but it does support some desktop features)
    4. https://github.com/Foorack/UdonZip
    5. https://github.com/vr-voyage/vrchat-3d-model-loader-tablet and https://github.com/vr-voyage/vrchat-glb-loader - Test case for web download. There are some model files local here which can be converted to .glb and served over http://localhost if needed. Either way, you will need to download the examples and convert them using the tools provided in vrchat-glb-loader to use a compatible texture format, though Godot also supports Basis Universal.
    6. https://github.com/Varneon/VUdon-Udonity inspector (will be emulated in Godot). might be a good stress test of GameObject/Component <-> Node mappings
    7. https://github.com/Guribo/UdonUtils/tree/master/Packages/tlp.udonutils/Runtime/Scenes/Examples
