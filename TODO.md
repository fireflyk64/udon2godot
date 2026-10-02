# udon2godot TODO

Status legend: [x] done and verified, [~] implemented but needs more coverage, [ ] open.

## UI leftovers, round 2 (2026-10-02) — current work

Asked for: every leftover of the section below, the animation curves and the ScrollRect's
inertia first. Each item gets a case in `tests/unity_ui` (or the unit tests) before the code.

- [x] Animation clips on UI (fixture canvas "AnimatedUi": a panel whose Animator has one state
      per clip, sampled by hand in `test/ui_anim_test.gd`, 47 checks)
      - [x] rotation, scale and position curves of a RectTransform (`m_EulerCurves`,
            `m_RotationCurves`, `m_ScaleCurves`, `m_PositionCurves`: they carry no class id and
            become 3D tracks, which a Control cannot take): the tracks are pointed at the
            `UnidotRect` helper, now a Node3D whose transform (in Godot's convention, as the
            tracks hold it) is handed to `RT.set_local_position / rotation / scale`. A plain
            Transform holder between rects moves what it holds the same way.
      - [x] curves of UI components: Graphic colour (`m_Color`, `m_fontColor`), `m_Enabled`,
            Image fill amount, text font size, CanvasGroup alpha / interactable / blocks
            raycasts, Slider value, Toggle `m_IsOn`, Selectable `m_Interactable`: value tracks
            on a second helper (`runtime/ui_anim.gd`, "UnidotUi") whose setters are those a
            script uses (`ui_graphic`, `ui_text`, `ui_canvas_group`, `ui_selectable`)
      - [x] sprite curves (`m_PPtrCurves` on `m_Sprite`): a discrete value track; the keys keep
            the references until the clip is fitted to an Animator (clips are imported in the
            same stage as textures, whose sprites do not exist yet)
      - [x] `m_IsActive` of an object below an Animator (what a script sees as activeSelf): the
            track stays on `visible`; a plugin hook (`handle_animated_active`) lets the Udon
            plugin put the node in the group `udon_animated_active`, and the run time makes
            of each change what `SetActive` does (OnEnable / OnDisable, no more Update).
            Udon fixture: `Blinker/Lamp`, 5 checks (116 headless / 152 with a display).
- [x] ScrollRect: inertia (`decelerationRate`), the elastic spring, `Scrollbar.numberOfSteps`.
      `runtime/scroll_rect.gd` is ScrollRect.LateUpdate now: `move` (the velocity decays by
      decelerationRate ^ time and carries the content; content outside the view springs back
      by Mathf.SmoothDamp over `elasticity`, three times slower while the wheel scrolls;
      clamped content is put back), `drag_to` (OnDrag with RubberDelta), the wheel may
      overshoot an elastic rect, a drag leaves its velocity, a press stops it, the handle
      shrinks while the content is over-stretched. A Scrollbar with steps is a Range with
      that step; a ScrollRect linked to it puts its content on the step (what Unity's
      onValueChanged round trip does). The first frame still finds the content at rest.
      Scripts: `velocity`, `StopMovement`, `inertia`, `decelerationRate`, `elasticity`,
      `Scrollbar.numberOfSteps` / `direction` (were stubs). Unit tests 378 → 408 (numbers
      from Unity's formulas), fixture cases `Stepped` and `BarStepped` (918 nodes), coverage
      `TWidgets` 63 checks (1087 in all).
- [x] Selectable: tints fade over `fadeDuration`; sprite swap; animation transition (triggers).
      Fixture canvas "Transitions", driven by the pointer in `test/ui_anim_test.gd` (68 checks);
      unit tests 408 → 434.
      - [x] `ui_graphic.cross_fade` is Graphic.CrossFadeColor / CrossFadeAlpha (a Tween kept in
            the graphic's metadata; from the colour of the moment, RGB and alpha apart). The
            Selectable's helper fades the tint when its state changes; a Selectable that
            appears (OnEnable) and the importer's static pass set it at once. Scripts'
            `CrossFadeColor` / `CrossFadeAlpha` use the same function.
      - [x] the Toggle's check mark fades in 0.1 s (`toggleTransition` Fade, now imported)
      - [x] sprite swap: `m_SpriteState` → `sprites` of the selectable metadata, drawn as the
            Image's override sprite (`ui_graphic.set_override_sprite`; `Image.sprite` stays).
            Scripts: `overrideSprite`, `spriteState`, `toggleTransition` (were stubs).
      - [x] animation transition: `m_AnimationTriggers` → `triggers`; a state change resets the
            five triggers and sets the state's on the object's AnimationTree. Trigger
            parameters are now used up: the controller's root lists them (`unidot_triggers`)
            and `runtime/anim_tree.gd` resets the ones named by the transition a state
            machine has just taken (before, a trigger stayed set for ever). A clicked button
            stays Selected, as in Unity.
- [x] Text: a font asset's material (outline, underlay), fallback fonts, Page and Linked
      overflow, sprite tags. Fixture canvas "TextStyles" (font assets with materials, a
      material preset, a sprite asset, TextMeshPro's settings asset); the reference reads the
      same files on its own (`TextStyles` in `tools/unity_ui_reference.py`) and compares the
      outline, the shadow, the fallbacks and the inline sprites of every TextMeshPro text;
      unit tests 434 → 471.
      - [x] outline and underlay: the distance field shader's numbers are fractions of the
            atlas's gradient scale; the importer turns them into lengths per font size
            (`outline: {ratio, color}`, `underlay: {x, y, dilate, color}` of the text
            settings) from the font asset's own material (an object of the asset's file) or
            the text's material preset (`handle_asset_resource` hook → `unidot_tmp_material`),
            and `ui_text.gd` draws them as the label's outline and shadow in whole units
            (thinner than a unit but visible: one unit). vrcbce's menus use both.
      - [x] fallback fonts: the asset's `m_FallbackFontAssetTable` and the fallbacks of the
            project's "TMP Settings" asset become `Font.fallbacks` (on a scene-local
            variation: the asset's font is a file of its own), for the stand-in family too
      - [x] Page overflow: `page_range` finds the lines of the page in the laid out text and
            the drawing child shows them as a text of their own; `pageToDisplay` for scripts
      - [x] Linked overflow: the text shows its whole lines and gives the linked text its
            string and `first` (TextMeshPro's firstVisibleCharacter, also imported and
            scriptable), from which that one goes on
      - [x] sprite tags (`<sprite=1>`, `index=`, `name=""`, with an asset name): a sprite
            asset becomes a Resource (`unidot_tmp_sprites`); the text's asset, or the default
            one of "TMP Settings", is drawn as `[img]` regions of the sheet, scaled with the
            font size as TextMeshPro scales them; a sprite counts as one character
      - [x] scripts: `outlineWidth`, `outlineColor`, `pageToDisplay`, `firstVisibleCharacter`
            (were stubs); coverage `TWidgets` 74 checks (1098 in all)
      Not done: the vertical place of a sprite in its line (Godot centres an inline picture,
      TextMeshPro puts it on the baseline by its bearing), the softness of an underlay, the
      face dilate and the inner half of an outline (Godot outlines outside the glyph only).
- [ ] Rects: negative sizes; an InputField lower than a line; 3D components and plain
      Transforms without UI below a control; a plain Transform whose only UI is a nested
      prefab instance
- [ ] The pointer falls through a canvas that has nothing under it
- [ ] Sprites packed tightly or rotated in an atlas
- [ ] The pixel check: translucent graphics, text
- [ ] vrcbce: `Silent/Filamented` and the fur shaders; the cue through the desktop player; the
      sample scene with all tables
- [ ] VRChat's own constraint components authored in a scene

## RectTransform and canvas positioning (pool table UI)

The pool table's canvases showed positioning errors. What was found (2026-09-30):

* The table's UI is not flat. `intl.menu` is a 0 x 0 canvas at scale 0.005 whose children are
  tilted 45 degrees about x (`MenuAnchor`, `StartMenu`) or pushed along z (`OtherMenu` 7 cm,
  the scorecard texts 77 cm); the importer drew all of it in the one plane of the canvas.
* `BilliardsModule.SetTableTransforms` and `MenuManager` put seven UI elements on 3D spots of
  the table model at run time (`setTransform`: world position and rotation of `.NAME_0`,
  `.NAME_1`, `.SCORE_0`, `.SCORE_1`, `.SNOOKER_INSTRUCTIONS`, `.MENU`, `.JOINMENU`); the runtime
  projected those onto the canvas plane.
* A root canvas was placed from `m_LocalPosition`, whose x / y Unity leaves at 0 for a
  RectTransform (the scorecard canvas sat 0.86 m too low); the position is the anchored position.
* Script properties went through catalog mappings that disagreed with the importer
  (`anchoredPosition => $0.position`, `sizeDelta => $0.size`, `anchorMin` with y unflipped,
  `rect => get_rect()`, `localRotation` of a Control always identity, `transform.parent`
  returning the canvas's viewport), and `pivot_offset` was computed from the size delta, which is
  wrong for stretched rects.
* RectTransform overrides on prefab instances were dropped ("Unable to convert Transform
  properties"), and Godot resets the anchors of an instanced Control root on load
  (`layout_mode = 0` is stored for a Control saved outside the tree).
* The table uses no layout groups (59 Images, 52 TextMeshPro, 23 Buttons, 3 Toggles, 2 Sliders,
  11 Canvases of which 8 nested).

- [x] Survey and reference rectangles: `tools/unity_ui_reference.py <assets> <scene> --survey`
      reads the Unity files alone (its own YAML reader, nested prefab instances with
      modifications and stripped objects), lays the UI out with Unity's rules (anchors, pivots,
      rotation / scale in 3D, CanvasScaler, layout groups, fitters) and prints every node's world
      corners and the case counts; `--compare dump.json` holds an imported scene against it.
      The Godot side is `refs/unidot_importer/test/ui_dump.gd` (`scenarios/canvas_dump.gd` in a
      world; `world_runner.gd --static` runs the scene without its scripts): each corner is
      followed through what is rendered (control -> viewport pixel -> quad or inline view).
- [x] One implementation for import and run time: `refs/unidot_importer/runtime/
      rect_transform.gd`. Unity values live in the Control itself (anchors, offsets,
      `pivot_offset_ratio`, rotation, scale), what a Control cannot hold in `unidot_rect`
      metadata; every setter Unity scripts use (`anchoredPosition`, `sizeDelta`, `anchorMin/Max`,
      `offsetMin/Max`, `pivot`, `SetSizeWithCurrentAnchors`, `SetInsetAndSizeFromParentEdge`,
      `localPosition / Rotation / Scale`, world position and rotation, `GetLocal/WorldCorners`,
      `SetParent`) goes through it, from the importer and from `U.rect_*` / `U.set_position`.
      Unit tests `test/rect_transform_test.gd` (153 checks, in and outside the tree); coverage
      fixture `TRect.cs` sets every property from a converted script (50 checks + 7 engine-side).
- [x] UI nodes in 3D: a canvas is an "island" (Node3D holder + SubViewport + plane). A control
      whose transform leaves the plane of its canvas (tilt about x / y over 0.5 degrees, more
      than 1 mm along z; `unidot/ui/flatten_depth`) gets a canvas of its own in the same place of
      the tree: at start for imported values, at the end of the frame for values a script set
      (so `SetParent(true)` followed by `localPosition = 0` does not build one). Scripts keep
      addressing the control; `transform.parent`, `GetChild`, `Find`, `childCount`,
      `GetSiblingIndex` see through the holder and viewport nodes. A nested canvas is drawn
      inside the canvas around it while coplanar and on its own quad otherwise; planes follow
      their rect, content and world scale every frame (`runtime/canvas_plane.gd`).
- [x] Separation: Unity UI import is `refs/unidot_importer/ui_integration.gd`, a built-in plugin
      with no reference to Udon (commit "Unity UI import as a built-in plugin"), with its runtime
      scripts in unidot's `runtime/` (canvas_plane, canvas_scaler, layout_group, scroll_rect,
      dropdown). `udon_integration.gd` (1948 -> 1270 lines) keeps scripts, fields, SDK components
      and receives UnityEvent calls through the `ui_unity_event` hook. `udon_runtime` loads
      `addons/unidot_importer/runtime/` (`install_runtime` in `scripts/_godot_env.sh`).
- [x] Unit tests without scripting: `scripts/test_ui.sh` (in `ci.sh`) imports `tests/unity_ui`
      (written by `tools/gen_ui_fixture.py`) with unidot alone - no sandbox, no udon_runtime, no
      udon plugin - and compares the running scene with the reference: 18 canvases, 378 of 378
      nodes within 2 mm + 1 %. Canvases: Rects (anchors, pivots, offsets, scale, z rotation,
      mirrored, zero-size parents, hidden), Spatial (tilted, turned, flipped, z offsets, nested),
      Metres (scale-1 canvas with scaled panels and widgets), Layouts, Nested (in place, prefab
      instances, coplanar and tilted), Cards (prefab instances with RectTransform overrides, in
      a layout group), Placed (pivot, rotated and scaled parents, empty root, hidden canvas),
      seven screen canvases (every CanvasScaler mode).
- [x] Layout groups: `runtime/layout_group.gd` is Unity's rebuild (LayoutRebuilder order,
      HorizontalOrVerticalLayoutGroup, GridLayoutGroup, ContentSizeFitter, AspectRatioFitter,
      LayoutUtility priorities) and places children by writing their anchors, anchored position
      and size delta. 43 fixture panels: horizontal (6 alignments, reverse, control / expand
      width and both, flexible, squeezed below preferred and below minimum, child scale, pivots,
      inactive and ignored children), vertical (alignments, control width / height, reverse,
      expand without control, layout priority), grid (flexible, 4 start corners, vertical start
      axis, fixed rows / columns, alignment, one child, empty, inactive / ignored), fitters
      (vertical list, horizontal min, both with a corner pivot, grid rows, nested groups, fitter
      on a child), aspect ratio (4 modes, stretched width), inactive group. Scripts reach the
      same data: `GetComponent<VerticalLayoutGroup>()`, `spacing`, `padding` (RectOffset),
      `childAlignment`, `childControl*`, `LayoutElement.*`, `ContentSizeFitter.*Fit`,
      `LayoutUtility.Get*`, `LayoutRebuilder.ForceRebuildLayoutImmediate` (TRect).
- [x] Pool table verification (2026-09-30, `scripts/test_world_billiards.sh`):
      * as imported (`--static`): 3 root canvases, 147 of 147 UI nodes within 2 mm + 1 % of the
        Unity reference, active flags included (before: the scorecard texts 0.86 m off, the
        lobby menu flat instead of tilted, `OtherMenu` 7 cm and `StartMenu` 16 cm off their depth);
      * with the scripts running (`scenarios/billiards.gd`, 40 checks): `player0-name`,
        `player1-name`, `player0-score`, `player1-score`, `SnookerInstructions`, `MenuAnchor` and,
        once the game is live, `JoinMenu` are on their spots of the table model - world
        position within 2 mm, rotation within 0.5 degrees, and drawn there - and every UI control
        of the world is drawn within 3 mm of where its transform says;
      * `scenarios/billiards_play.gd` (17 checks) still plays through the pointer: START, the
        lobby buttons on the tilted menu, cue pickup, aim, shoot;
      * `scenarios/billiards_ui.gd` (18 checks) photographs each element from its readable side
        in the idle, lobby and game states (`shots/ui_*.png`): the lobby menu stands tilted at
        the head of the table with the join menu beside it, the names and scores sit on the
        table's scorecard, the practice menu is its own panel beside the table.
      Seen in the screenshots and not a matter of position (see the items below): text set by a
      script shows TextMeshPro tags literally (`<size=13>LocalPlayer`), the game mode buttons
      are white squares, slider handles do not follow the value.
- [x] What the pool table's UI draws (after positioning). The screenshots of `billiards_ui.gd`
      showed the menus in place but not looking like Unity. One implementation again: the importer
      writes metadata, a run-time module of unidot renders it, and a script's setter goes through
      the same module.
      - [x] Text (`runtime/ui_text.gd`, metadata `unidot_text`): Unity rich text → BBCode by a tag
            tokenizer (TextMeshPro's and uGUI's tag sets; anything else in angle brackets stays
            text: `<<`, `<winner>`), font styles (the table uses bold + italic + small caps on 16
            texts), auto-sizing (7 texts; a helper child refits when the rect changes), a
            SystemFont family with Liberation Sans metrics (TMP's default font; the theme's Open
            Sans is 21 % taller). uGUI Text is a RichTextLabel too. `text` / `fontSize` /
            `fontStyle` / `richText` / `enableAutoSizing` ... of a script go through `U.ui_text_*`.
      - [x] Graphics (`runtime/ui_graphic.gd`, metadata `unidot_graphic`): colour × CanvasRenderer
            colour × enabled. A disabled Image draws nothing while its object and children stay
            (the six `<<` / `>>` buttons were white boxes); `Graphic.enabled`, `color`,
            `CrossFadeAlpha`, `canvasRenderer.SetAlpha` of a script use it (`enabled` used to
            hide the whole object).
      - [x] Selectables (`runtime/selectable.gd`, metadata `unidot_selectable`): colour tint of
            the target graphic by selection state (the game mode buttons have a normal colour of
            alpha 0), Toggle check mark follows `isOn`, Slider fill and handle follow the value
            (Slider.UpdateVisuals); `colors`, `interactable`, `isOn`, `value`,
            `SetValueWithoutNotify`, `direction`, `fillRect` ... of a script.
      - [x] InputField: the LineEdit draws text and placeholder with the fonts and colours of
            Unity's two child objects, which are not drawn a second time.
      - [x] Tests without scripting: the "Widgets" canvas of `tests/unity_ui` (9 sliders, toggles,
            9 buttons, disabled graphics, masks, canvas groups, rich text, an input field); the
            reference computes the colour each graphic is drawn with and the characters each
            text shows, the dump reads both from what the controls draw.
      - [x] Scripts: `tests/coverage/TWidgets.cs` (36 checks) and the engine-side checks of
            what is drawn after the script ran.
- [x] Found on the way:
      * Rendering is not where the transforms are. Godot rounds the origin of every Control to
        a whole unit of its parent's space when drawing ("snap controls to pixels"); on a canvas
        in metres (the table's `intl.menu`) that is up to half a metre: the START and PLAY
        buttons were drawn half outside their viewport (and looked occluded). Off on every
        canvas viewport. No check of transforms could see it, so `test/ui_shots.gd --check`
        renders each canvas and compares the pixel at the centre of every solid graphic with
        renders each canvas and compares pixels with the transforms: five points of every
        solid graphic and nine of every sprite (where its texture is opaque and even), through
        text drawn over them (2211 points on 449 of 497 graphics in `tests/unity_ui`, 329 on
        41 of 48 in the pool table with every menu shown; with the snapping left on it reports
        the START and PLAY buttons and the fixture's menu items). `scripts/test_ui.sh` and
        `scripts/test_world_billiards.sh` run it when a display is there.
      * unidot's YAML reader kept the closing quote of single-quoted scalars and dropped doubled
        quotes (`'>>'` → `>>'`).
- [x] Text higher than its rect (TextMeshPro's overflow mode, all 53 texts of the table; uGUI's
      vertical overflow): Unity draws every line around the alignment point, a RichTextLabel
      draws from the top and drops the lines that start below its rect. Such a text is drawn by
      a child label as high as the content, placed by the vertical alignment
      (`UnidotTextOverflow`, made and removed by `ui_text.gd` as text and rect change; the node
      keeps the Unity rect and the string). Fixture: TmpOverTop / Middle / Bottom, UguiOver.
- [x] A branch off upstream unidot with only the UI work, for upstreaming:
      `tools/unidot_ui_branch.py` builds `ui-canvas` in the fork (upstream main + 3 commits: the
      YAML fix; scene nodes may be any Node, with the plugin hooks for GameObject nodes and
      component overrides; the UI plugin with its run-time modules and tests: 34 files). The UI
      files are copied; of `object_adapter.gd` (49 hunks against upstream), `convert_scene.gd`
      and `scene_node_state.gd` only the hunks the UI needs are applied (no Udon, shader or
      particle code). `UNIDOT=<worktree> scripts/test_ui.sh` passes on it alone: 312 unit checks,
      761 of 761 nodes, 2218 pixel points. Local, not pushed.
- [x] ScrollRect as Unity's own scroller. It was a Godot ScrollContainer: the scrolled object and
      Unity's Scrollbar children were not where Unity puts them, and scripts that read or set
      `content.anchoredPosition` saw nothing. Now the objects stay what they are
      (`runtime/scroll_rect.gd`, helper child `UnidotScroll`, metadata `unidot_scroll`): the
      content moves inside the viewport object by its anchored position (ScrollRect.UpdateBounds
      / CalculateOffset / SetNormalizedPosition ported: content smaller than the view is padded
      by its pivot, content outside is brought back unless the movement is unrestricted), the
      viewport makes room for scrollbars that hide themselves (visibility 2,
      SetLayoutHorizontal / UpdateScrollbarLayout), the Scrollbars get size, value and
      visibility and their handles follow (Scrollbar.UpdateVisuals in `selectable.gd`, which
      also takes the pointer on a Scrollbar as Unity does), the wheel and dragging scroll,
      `onValueChanged` is the helper's `scrolled` signal. The reference tool models the same
      (independently, from the Unity files); `tests/unity_ui` has a "Scroll" canvas with 13
      scroll views and 5 scrollbars (174 nodes). `scripts/test_unity_fixture.sh` compares the
      fixture world's UI with the reference too (40 of 40 nodes; it had two ScrollRect
      mismatches, and the comparison of what is drawn found an Image on a Slider's own object
      that was not drawn and a reference that did not know Dropdown.RefreshShownValue).
      Left: inertia and the elastic spring (the content snaps back), `Scrollbar.numberOfSteps`.
- [x] Text that is cut at its rect (uGUI's vertical Truncate, TextMeshPro's Truncate / Ellipsis /
      Masking): a truncated text shows the lines that fit entirely, placed by the vertical
      alignment (it was clipped from the top, a line that fits only partly drawn partly); a
      masked one is drawn whole and clipped at the rect. Same drawing child as the overflow.
- [x] TextMeshPro's Ellipsis mode (99 texts in the cloned repositories: Udonity 57, the model
      loader 29, SaccFlight 13; none on the pool table) and lines that are not wrapped. A cut
      text showed the lines that fit and no ellipsis, and a line wider than its rect that is
      not wrapped (a player name in a column) was not cut at all. The longest beginning of the
      text that fits the rect is found by laying it out (`to_bbcode` with a character limit
      and a tail), with the ellipsis after it in Ellipsis mode, in the text's styles; the node
      keeps the whole text. 14 unit checks, canvas "Cut" in `tests/unity_ui`.
- [x] CanvasGroup (`runtime/canvas_group.gd`): a group that is not interactable or does not block
      raycasts takes no pointer input, nor does anything below it (`mouse_behavior_recursive`;
      the group's Control used to swallow clicks or let them through to its children), the
      Selectables below a non-interactable group are in their disabled state
      (Selectable.IsInteractable), `ignoreParentGroups` starts over; overrides on prefab
      instances; `alpha` / `interactable` / `blocksRaycasts` of a script.
- [x] UI component overrides on prefab instances: text, font size / style, colour (by member:
      `m_Color.r`), `m_Enabled` (it used to hide the object), sprite, Selectable colours /
      interactable, `m_IsOn`, Slider value / range / direction, layout group / element / fitter
      settings. The override changes the same metadata and is rendered by the same modules; the
      component is found by its file id (`unidot_ui` metadata of the Control), or by its fields
      inside nested instances. `tests/unity_ui`: `Panel.prefab` with three instances on the
      "Overrides" canvas (26 expectations that failed before).
      Layout components keep their settings when disabled (`enabled: false` in the metadata), so
      `layoutGroup.enabled` of a script works and no longer hides the object.
- [x] Dropdown lists (20 templates in the cloned repositories: Udonity 15, UdonUtils 3, the
      model loader 2). A click opened Godot's popup window, which is not Unity's objects (no
      template look, and on a world canvas it opened as a window of the screen).
      `runtime/dropdown.gd` is now a helper child (`UnidotDropdown`, metadata `unidot_dropdown`
      with the caption / template / item references) and ports Dropdown.Show: a copy of the
      Template ("Dropdown List"), one copy of its item per option (text, image, Toggle on for
      the value), the content sized to the items, the list shortened to its content, flipped
      when it leaves the canvas (FlipLayoutOnAxis), a blocker over the canvas that closes it.
      The OptionButton stays as the holder of options and value; its own popup opens only
      without a template. `tests/unity_ui` has three dropdowns (3 options, 10 options that
      scroll, one at the lower edge that flips); `test/ui_dropdown_test.gd` (run by
      `scripts/test_ui.sh`) clicks through the viewport and checks Unity's numbers: 37 checks.
      Scripts: `Show` / `Hide` / `IsExpanded`, `captionText` / `captionImage` / `template` /
      `itemText` / `itemImage`, and option changes (`ClearOptions`, `AddOptions`, `options`)
      refresh the caption (coverage TWidgets: 16 checks).
      Differences left: the list is the last child of the canvas root (Unity leaves it under
      the Dropdown and draws it on top with a sorting canvas; Godot picks by tree order), an
      item is named `Item 1_ B` (a node name cannot hold Unity's colon), no fade in / out.
- [ ] Left over, not positioning of the pool table:
      * TextMeshPro's Page and Linked overflow modes truncate.
      * Sprite tags of TextMeshPro; a font asset's material (outline, underlay) and its
        fallback fonts; a font asset whose font file is not in the project gets a stand-in;
        sprites packed tightly or rotated in an atlas.
      * Selectable transitions other than colour tint (sprite swap, animation; none of the cloned
        repositories uses them); tints are applied at once (no fade).
      * A rect with a negative size (stretched with insets larger than the parent): a Control
        cannot be negative; children anchored to it are off (flagged, not compared).
      * An InputField smaller than one line of its font keeps Godot's minimum height.
      * 3D components (AudioSource, colliders, meshes) and plain Transforms without UI below
        them under a UI control have no 3D frame unless the control is a canvas. (A plain
        Transform that holds UI is a Control: see the vrcbce item.) A plain Transform whose
        only UI is a nested prefab instance is not recognized as holding UI.
      * The pointer takes the nearest canvas shape; it does not fall through to a canvas behind
        when the nearest one has no control under the pointer.
      * The pixel check does not compare text glyphs, translucent graphics or widgets drawn by
        Godot (LineEdit, OptionButton).
- [x] TextMeshPro (3D) outside a canvas (the table's "winner" text) → Label3D (font size in
      tenths of a unit, the object's RectTransform as text box); a RectTransform outside every
      canvas is an ordinary Node3D placed by its anchored position.
- [x] Sprites of UI Images. The importer loaded the whole texture of a sprite and stretched it
      over the rect. The pool table: 58 of 65 Images are of type Sliced, two sprites have borders
      (`snookerbutton.psd` 68 px, 12 uses: every button shape; `SelectionOutline.png` 196 px, 4
      uses), 20 Images use Unity's built-in sprites (UISprite 13, Background 4, Knob 2,
      InputFieldBackground 1), which no package ships: white squares.
      - [x] Sprite information from the texture's import settings (`spriteBorder`,
            `spritePixelsToUnits`, the rect and border of a sprite in a sheet: an AtlasTexture).
      - [x] Image type Sliced: nine patches drawn by a helper child (`runtime/ui_sprite.gd`,
            behind the control), border size as Unity (sprite pixels × canvas reference pixels
            per unit / sprite pixels per unit / multiplier), borders shrink on an axis where the
            rect is smaller than both (Image.GetAdjustedBorders), fill centre.
      - [x] Tiled (Image.GenerateTiledSprite: the borders stay, the centre and the edges repeat
            from the bottom-left, the last tiles cut) and Filled, horizontal and vertical
            with origin; `fillAmount` / `fillMethod` / `fillOrigin` / `type` / `SetNativeSize`
            of a script. Radial fills are drawn whole.
      - [x] Built-in sprites: stand-ins with Unity's sizes (200 pixels per unit) and 10 pixel
            borders in `runtime/sprites` (ImageTextures saved as text: no import step), written
            by `make_sprites.gd`.
      - [x] An Image's preferred size in a layout is its sprite's size in canvas units, or the
            sum of its borders when sliced or tiled (`preferred` of the graphic metadata;
            the reference reads PNG / PSD headers and the .meta).
      - [x] Tests: slice, tile and fill geometry by hand-computed Unity numbers;
            `Frame.png`, `Bar.png`, `Sheet.png` written by the fixture generator and a "Sprites"
            canvas (27 Images); the pixel check maps 25 points of every such Image through the
            slices and checks that holes show what is behind; `TWidgets` drives a filled Image.
- [x] Pool table shader ports. 12 custom shaders were approximated with StandardMaterial3D: the
      cloth had no tint / detail / rim lights, the scorecard lamps did not follow the score, the
      shot timer did not run, the guide line was not cut at the table's edge, and the desktop
      key hint (`metaphira/GameUI`, a screen overlay) hung in the world as a quad.
      - [x] Script-set properties reach a port's uniforms: `SetFloat("_Floor")` was sent as
            `Floor`, which no port has (the ball shadows lay on the floor under the table);
            `U.mat_set` uses the Unity name when the shader has that uniform, and packs colour
            and number arrays.
      - [x] `metaphira/TableSurface` (tint map, cloth detail, Oklab hue shift, timer rim lights).
      - [x] `metaphira/Scorecard`, `metaphira/Timer`.
      - [x] `harry_t/cliptable` (guide line; the table's matrix is in Unity space, the port
            mirrors Godot's world x), `harry_t/text_alpha`, `harry_t/twoframe`.
      - [x] `metaphira/GameUI` (screen overlay), `metaphira/CueCenter` (the scene's reflections
            stand in for the shader's own cubemap).
      - [x] Checks in `scenarios/billiards.gd` (55 checks): the ports are in use, GraphicsManager's
            scorecard has the 15 lamp colours and the game mode, the shadows the table height,
            the guide line its half extents and matrix, the cloth its textures and keyword.
      Left without a port: `metaphira/Physics` / `PhysicsDummy` (materials nothing uses),
      `Custom/StandardScrollingEmissive` (another table model), `metaphira/ScreenOverlay`
      (camera override module). No Unity pictures to compare with: the ports follow the
      shader sources line by line.
- [ ] vrcbce (VRCBilliards Community Edition, `refs/vrcbce`): a second pool table, so far only
      converted and compile-checked, never imported. An independent check of the canvas work:
      three menu styles (M.O.O.N 140 rects, esnya 126, akalink 191; 10 canvases each, read by
      the reference tool without changes), 20 plain Transform children under rects, 12 rects
      under plain Transforms, 15 rects rotated about x / y, TextMeshPro font assets whose source
      fonts are in the package (Calistoga 87 texts, TT Norms 8), one radial fill.
      - [x] Import the package through the world pipeline (`scripts/import_world.sh
            refs/vrcbce/Packages/com.vrcbilliards.vrcbce`): 21 classes convert with 0 warnings,
            18 table prefabs and the sample scene import; 280 scripts attached, 325 UI nodes,
            36 events wired. Found: see the next items.
      - [x] UI reference comparison of the three table prefabs (static): M.O.O.N 117 of 117
            nodes, esnya 103 of 103, akalink 166 of 166, 0 problems. The canvases needed no
            importer change; the comparison did: names that end in a blank (`Zoom: `) or hold
            the path separator (`github.com/VRCBilliards/vrcbce`), and z on overlay canvases
            (it places nothing on the screen).
      - [x] Pixel check of the canvases on a display: 0 misdrawn (28 / 121 / 637 points; most
            graphics of the M.O.O.N menu are translucent or textured).
      - [x] A partial class is known by the file named after it. `PoolStateManager` has eight
            parts; the manifest carried the GUID of `PoolStateManager.Base.cs`, the components
            carry that of `PoolStateManager.cs`: 19 table behaviours had no script and 73
            references to them were unresolved. `ClassInfo::script_file` (test in
            `tests/convert.rs`).
      - [x] The sandbox allows 256 properties per program; `PoolStateManager` has 245 fields
            plus its base class ("Maximum number of properties reached", later fields had no
            property). `MAX_PROPERTIES` is 1024 in the patched godot-sandbox (`refs/godot-sandbox`,
            one more local commit); the Linux library is rebuilt
            (`godot_project/addons/godot_sandbox/bin`, `tools/sandbox_build`). The libraries of
            the other platforms are the upstream release and keep the limit of 256.
      - [x] Unity's constraint components (PositionConstraint ...: 16 per table, the ball
            shadows) were dropped at import ("Failed to instantiate object of type
            PositionConstraint", 301 lines). unidot has adapter classes for the six Animations
            constraints now and hands them to plugins (`handle_constraint`); the Udon plugin
            writes the settings to the node's `udon_constraint` metadata under the names of
            the script API (sources as NodePaths, resolved when the scene is complete), and the
            run time adopts them into the store `U.solve_constraints` solves: the first of an
            object as the constraint a script's `GetComponent` finds, further ones (position
            and rotation on one object) beside it. `tests/unity_fixture`: Ball / Shadow / Twin /
            Idle / Mid (4 script checks, 6 scenario checks: one source with an offset, two
            constraints on one object, an inactive one, two weighted sources on two axes, the
            followers track a source that moves).
      - [x] The order of a scene's roots. The fixture's new root objects changed which "Canvas"
            `GameObject.Find` returned and which prefab instance came first: the importer
            sorted the roots by `m_RootOrder`, which Unity 2022.2 and later no longer write
            (the pool table scene has none), with a sort that is not stable. `convert_scene.gd`
            reads the `SceneRoots` object (Transform or PrefabInstance file ids), falls back to
            `m_RootOrder` (also of prefab instances) and breaks ties by file id. The fixture
            has a SceneRoots list and a check of the imported order.
      - [x] `GameObject.Find` looked at every Godot node: the root control of each canvas is
            named "Canvas", component nodes have names too, inactive objects were found. It
            walks GameObjects only now (the logical tree `transform.Find` uses), in hierarchy
            order, active objects only, with Unity's path forms (coverage TTransform).
      - [x] TextMeshPro font assets: the source font file of the asset (`m_SourceFontFileGUID`)
            instead of the stand-in family. `ui_integration.handle_scripted_object` turns the
            font asset into a FontVariation of its font file (bold and italic synthesized as
            TextMeshPro does, slant from `italicStyle`); without the file a system font of the
            asset's family, then the stand-in. `tests/unity_ui`: canvas "Fonts" with
            `Fonts/Calistoga.ttf` (OFL, licence next to it), an asset made from it and one
            whose font file is gone; the reference reads the family from the asset, the dump
            from the font in use (4 expectations that failed before).
      - [x] Radial fills of an Image (Radial 90 / 180 / 360; they were drawn whole).
            `ui_sprite.gd` ports Image.GenerateFilledSprite / RadialCut; `radial_covers` is the
            meaning of the fill (a swept angle in the rect's proportions, written without the
            quads): the unit test holds one against the other at 61,839 points over every
            method, origin and direction (26,517 differ when the direction is flipped), the
            pixel check uses it (and leaves out three pixels around the edge). `tests/unity_ui`:
            16 radial Images on the "Sprites" canvas. A filled sprite with no fill amount draws
            nothing (the reference and the dump report it); `fillCenter` of a script is the
            sprite's setting now.
      - [x] A plain Transform inside a canvas with RectTransforms below it (vrcbce's in-game
            UI: timer circle, timer text, winner text below `LookAtHead`, which a script turns
            to the player). The importer made the Transform a Node3D and its RectTransforms
            "outside every canvas": nothing of them was drawn, and the Image / text components
            had no node, so script fields that refer to them (through the stripped components
            of the nested prefab instance) stayed null (`timerCountdown.fillAmount` on null
            every frame). Such a Transform is a Control now: no size, at its local position
            from the parent's pivot, with its rotation and scale; what is below it is laid out
            against no parent rect, as Unity does. The reference tool models the same.
            `tests/unity_ui`: canvas "Plain" (16 nodes: offset, turned and scaled, tilted in
            3D, nested twice, inactive, and a Transform without UI that stays an object in
            space).
      - [x] A Button whose onClick calls `UdonBehaviour.Interact` (how vrcbce unlocks its
            table: a button → `ActivaterUdonEvent.Interact` → `SendCustomEvent`) was reported
            as an unsupported persistent call. It is wired to the behaviour's `Interact` now
            (fixture: the BL button, 1 check).
      - [x] One table runs (`scenarios/vrcbce.gd`, 22 checks): the table is unlocked by using
            its "Enable Table" object, player 1 signs up and the game starts through the
            menu's buttons, the intro animation ends, the break is played, the balls collide
            and come to rest, the turn passes; the ball shadows are under the balls throughout.
            What it took, each with a test of its own:
            * `x |= f()` and `x &= f()` (and `|` / `&`) on bools evaluate both sides in C#; the
              converter wrote `x = x or f()`, which stops calling `f` once `x` is true: after
              the first moving ball no other ball was stepped (no friction, no collisions among
              them, the turn never ended). The side that may do something goes first now, or
              both become arguments of `U.b_or` / `U.b_and` (tests/convert.rs, coverage
              TSystem). 48 lines change in the cloned repositories (the glb loader writes
              `&` / `|` throughout).
            * a delayed event counted the delta of the frame it was scheduled in and ran before
              that frame's `Update`: vrcbce's intro animation (an `Update` countdown that
              switches the shadow constraints off) and the event of the same length that
              switches them on again ended in the wrong order. The delay runs from the
              scheduling frame's time, and a frame's delayed events come after its `Update`
              (coverage TVRC).
            * references stored by the importer are NodePaths of the saved scene; a control
              that gets a canvas of its own at start (it is not in the plane of its canvas)
              takes what is below it along. `U.resolve_ref` looks through such canvases.
            * the offset of a PositionConstraint is in the space of the constrained object's
              parent (the shadows are 0.2 below the balls under a parent scaled 0.15); the
              solver added it in world space (fixture: Scaled / Under).
            * an inactive GameObject was only hidden when it was UI: `m_IsActive` was applied
              to prefab-instance overrides alone (the table's guideline stood on the table; 35
              inactive objects of the MS-VRCSA table were saved visible and hidden only by
              their scripts). Hidden at import now (fixture: Sleeper).
      - [x] In `scripts/test_world_community.sh` (and so in CI): the scenario on the M.O.O.N
            table, headless and on the display, and the UI reference comparison and pixel check
            of the three menu styles.
      - [x] vrcbce's desktop UI (a screen-space canvas, 10 nodes per menu style) was off: its
            plain Transforms are turned out of the canvas plane (`Shot Angle`: -90 degrees about
            x, scale 75; `desktop_hitpower`) and their RectTransform children are turned back
            (and scaled 0.02), so the result is in the plane again. A Control shows the planar
            projection of its own rotation and scale, the holder's projection had no height,
            and nothing below it could undo that. A plain Transform holder never turns or
            scales as a Control now: it hands its rotation, scale and distance from the plane
            down (`unidot_carry`), each RectTransform below shows the projection of the composed
            transform and keeps its own Unity values, and what is still out of the plane after
            composing gets a canvas of its own (the holder does not: on a world canvas a turned
            holder used to become a canvas with further canvases inside it). `tests/unity_ui`:
            the pattern on the "Plain" world canvas and on a screen canvas ("ScreenHolders"),
            a holder in front of the canvas; 25 unit checks. vrcbce: 135 / 121 / 184 nodes, 0
            problems.
      - [x] Ports of five of vrcbce's shaders (`shader_ports/`): `VRCBCE/Ghost Balls`
            (marker, cue grip and hit indicators), `VRCBCE/Surface Color Mask` (the ball atlas
            with team colours), `VRCBCE/TableSurface`, `VRCBCE/Unlit Color+Texture`,
            `Custom/StandardScrollingEmissive`. They follow the shader sources; there are no
            Unity pictures to compare with.
      - [x] Animator clips that animate RectTransforms. vrcbce's two slide toggles are moved
            by clips (`Left` / `Right`: `m_AnchoredPosition.x` and `m_LocalPosition` of the
            RectTransform "Selector", class id 224) that `UIAnimationManager` switches with
            `Animator.SetBool("Toggle")`. unidot converted the curves as if the target were a
            Node3D: three float tracks on `Selector:position`, the anchored position dropped
            ("Unknown property"). Only vrcbce has such clips among the cloned repositories (2 of
            356 clips); it is also the first imported AnimatorController a script drives.
            RectTransform curves are tracks on a helper child of the Control now
            (`runtime/rect_anim.gd`, "UnidotRect": anchored position, size delta, anchors,
            pivot, local position, scale, Euler angles), whose setters go through
            `rect_transform.gd` like every other way a rect changes; the helper is added to the
            controls a clip animates when the clip is adapted to its Animator. Where a clip
            records the local position beside the anchored position, x and y are taken once.
            `tests/unity_ui`: canvas "Animated" (two objects with the same controller, three
            clips), `test/ui_anim_test.gd` in `scripts/test_ui.sh` (17 checks: poses, the
            transition, keys over time, size and scale, the other object is not moved). vrcbce
            scenario: switching the guideline slides the knob to the other pose (the clips' -39 and 36) and
            switches the guideline (4 checks).
            Left: rotation curves of a RectTransform (`m_EulerCurves` have no class id and
            become 3D rotation tracks), curves of UI components (colours, `m_Enabled`).
      - [ ] Not done for vrcbce: `Silent/Filamented` (a Standard replacement, 17 materials)
            and the two fur shaders are approximated; the guideline's shader is not in the
            package; the cue is not played through the desktop player as on the MS-VRCSA
            table; the sample scene with all 18 tables is imported but not run.
- [ ] Then continue with the open items below (Animator; VRChat constraint components; ...).

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
      connect to `SendCustomEvent` (26 wired in the billiards table). Layout groups, sprites
      (9-slice), ScrollRect, text, Dropdown lists and TextMeshPro font assets (their source
      fonts) are done (see the first section).
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
      (`metadata/<param>`), triggers map to `parameters/<name>/request` or conditions. Exercised by an
      imported controller since 2026-10-01: vrcbce's slide toggles (two states switched by a bool that
      `UIAnimationManager` sets; the clips animate a RectTransform, see the first section). Not yet
      exercised: triggers, blend trees, layers, clips on 3D objects in an imported world
      (SaccFlightAndVehicles has 337 clips and is not imported as a world).
- [~] Official pool table (MS-VRCSA-Billiards): converts (30 classes, 0 errors), imports, runs; the
      scenario plays a break and screenshots render the table with its skybox, ball shadows (ported
      shader), cast shadows (`world_runner --shadows`) and UI boards. The cue is played through the
      desktop player (`billiards_play.gd`), the table's shaders are ported (see the first section).
      Open: the 12 scripts the package does not ship (reported by the doctor).
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
      verification. Unity's constraint *components* authored in a scene are imported (see the
      vrcbce item in the first section); VRChat's own constraint components (VRCPositionConstraint
      ...) authored in a scene are not yet.
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
- [x] UdonUtils `RuntimeTestingExample.unity` (2026-09-17): the whole `Runtime` folder imports
      (148 classes, 1234 scripts attached over its scenes) and the package's own two
      `TestController`s run their 17 test cases inside the world; `scenarios/udonutils_tests.gd`
      holds each verdict against what one player can expect: the 7 single-player cases pass
      (sanity, game time vs delta time, PlayerData round trips up to 100 kB, persistence across
      visits on the second controller), the 10 that say "requires 2 players" fail with exactly
      that message; a revisit (`--player-data <file>`, kept between runs) also passes the first
      persistence case (8). Headless only: 148 sandboxes plus the GL driver do not fit the 8 GB
      address-space cap of `scripts/godot.sh`, and the caps stay where the user set them.
      What the run exposed and fixed at the source (coverage checks in `TNulls.cs` / `TVRC.cs`):
      `OnPlayerRestored` was never raised by the default provider, `OnPlayerDataUpdated` was not
      raised for local writes (now once per frame with `PlayerData.Info` states Added / Changed /
      Removed); `PlayerData.Info`, `PlayerData.State` and other nested C# type names had no
      catalog alias; `GetComponent<T>()` / `typeof(T)` / `x is T` inside a generic method used
      the literal "T" (type arguments now travel in hidden leading `_T_<name>: String`
      parameters, inferred from `out` / `ref` arguments too, `GetUdonTypeName<T>()` is the
      generic form); `base.OnPlayerRestored(p)` with no converted base defining it became
      `super.OnPlayerRestored(p)`, which the sandbox dispatches back to the override until the
      VM depth limit (such calls into UdonSharpBehaviour are empty, `base.SendCustomEvent`
      goes to the catalog); and a SafeGDScript compiler bug: `var n: Node3D = null` followed by
      `n = items[0]` left the register typed NIL, so `n == self` folded to false at compile time
      (godot-sandbox fork 4d58be8, regression test). PlayerData can now be kept between sessions
      (`UdonWorldProvider.player_data_file`, typed variant storage; the network provider's server
      store used JSON, which turned Vector3 into text and ints into floats).
- [x] `scripts/test_world_community.sh` runs them (skips what is not cloned, re-imports when the
      importer or the converter's manifest changed); part of `ci.sh`.
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

## Every converted script compiles in the sandbox

`udon2godot --check` only says the converter had no errors. `scripts/compile_check_refs.sh` converts
every repository under `refs/` and loads each script in the sandbox: on 2026-09-17, 165 of the 362
scripts of the pool table and the community prefabs did not compile (verify.sh only checked vrcbce
and SaccFlight, 108 scripts that all compile). Now 362 of 362 compile; `tests/coverage/TNulls.cs`
runs every case below in the sandbox (26 checks; coverage 954 / 0).

- [x] `scripts/compile_check_refs.sh` (prints the compiler's message per failed script); part of
      `scripts/ci.sh`, and `scripts/verify.sh` now fails when its own compile check does (the
      result was only printed).
- [x] 123 x "Constant 'X' is already declared in <base script>": C# `public new const int
      ExecutionOrder` hides the base constant (UdonUtils does it in every class); a GDScript class
      cannot redeclare a base member. A field, constant or auto-property that hides a base member
      is emitted as `<name>_<Class>`; the class and its subclasses resolve to it, base code keeps
      the base member.
- [x] 45 x "Cannot assign null to global 'X' of type String": `string s = null`, `return null`
      from a string method, null for `System.Type` / `VRCUrl` (Strings on the Godot side) and
      string auto-properties. `""` stands for a null string everywhere (assignments, returns,
      arguments, defaults), and `x == null` on those types also tests `""`.
- [x] Arrays, `DataList` and `DataDictionary` that C# sets to null, compares with null or returns
      as null are declared with SafeGDScript's nullable types (`Array?`, `Dictionary?`): fields
      (a non-serialized one starts null, so `if (cache == null) cache = new T[n];` works; it never
      ran before), locals, parameters (also `out` / `ref` and `= null` defaults) and return types
      (by method name, so overrides keep one signature). `src/nullflow.rs` finds them by name;
      everything else keeps the plain type the sandbox compiles to typed instructions.
- [x] A bare `default` takes the type it is assigned to (`bounds = default;` was `null`).
- [x] 34 x "Enum 'X' is already declared in <base script>": a derived script inherits the enum
      blocks of its base scripts and no longer repeats them.
- [x] `abstract` / `virtual` / `override` properties always go through `get_X()` / `set_X()`: an
      abstract `{ get; }` was a plain variable, so base-class code read the variable while the
      subclass defined a getter nobody called (Udonity's `InspectedType`). A virtual
      auto-property keeps one `_prop_X` variable in the first class that declares it.
- [x] Overloads along a class chain: a base with `Foo()` and `Foo(int)` names them `Foo` and
      `Foo_2`; an `override Foo(int)` in a subclass was named `Foo` again and replaced the wrong
      base method (Udonity's `OnContextDropdownActionInvoked`, the model loader's `Clear` /
      `Display`). Overrides take the name of the base method with the same parameter types, new
      overloads avoid names the bases use, and `base.Foo(n)` calls the matching overload.
- [x] `Next() ?? fallback` evaluated `Next()` up to three times; the left side runs once.
- [x] A call no overload here can take, in a class whose base is not among the sources (Udonity's
      `Log(string)` from the VUdon logger package): called by name with a warning instead of a
      call the compiler rejects for its argument count.

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
    server-side validation, ENet vs WebRTC (PlayerData persists per player on the server since
    2026-09-17, in the same typed file format as single-player `--player-data`).
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
