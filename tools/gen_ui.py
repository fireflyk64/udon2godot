#!/usr/bin/env python3
"""Generate `data/api/unity_ui.udon`: Unity UI (uGUI + TextMeshPro) members that the hand-written
catalog does not cover, from the Udon extern list.

Types with a hand-written block get an extension block (bare `type X`) that only adds members not
already mapped somewhere in the type's base chain; new types get a full header. Members map to
engine behaviour through `U.ui_*` helpers where Godot has an equivalent, to `pass` for Unity
layout/event-system internals that have no meaning in Godot, and to `!stored U.prop_get/prop_set`
(round trip only) for the rest. Re-run `tools/gen_catalog.py` afterwards.
"""
import os, re, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_catalog as G

OUT = os.path.join(G.API, 'unity_ui.udon')

# name: (base, kind, gd, mangled extern)
TYPES = collections.OrderedDict([
    ('Graphic', ('Behaviour', 'component', 'Control', 'UnityEngineUIGraphic')),
    ('MaskableGraphic', ('Graphic', 'component', 'Control', 'UnityEngineUIMaskableGraphic')),
    ('Selectable', ('Behaviour', 'component', 'Control', 'UnityEngineUISelectable')),
    ('Button', ('Selectable', 'component', 'BaseButton', 'UnityEngineUIButton')),
    ('Toggle', ('Selectable', 'component', 'BaseButton', 'UnityEngineUIToggle')),
    ('Slider', ('Selectable', 'component', 'Range', 'UnityEngineUISlider')),
    ('Scrollbar', ('Selectable', 'component', 'ScrollBar', 'UnityEngineUIScrollbar')),
    ('Dropdown', ('Selectable', 'component', 'OptionButton', 'UnityEngineUIDropdown')),
    ('InputField', ('Selectable', 'component', 'LineEdit', 'UnityEngineUIInputField')),
    ('VRCUrlInputField', ('InputField', 'component', 'LineEdit', 'VRCSDK3ComponentsVRCUrlInputField')),
    ('TMP_InputField', ('Graphic', 'component', 'LineEdit', 'TMProTMP_InputField')),
    ('Image', ('MaskableGraphic', 'component', 'Control', 'UnityEngineUIImage')),
    ('RawImage', ('MaskableGraphic', 'component', 'TextureRect', 'UnityEngineUIRawImage')),
    ('Text', ('MaskableGraphic', 'component', 'Control', 'UnityEngineUIText')),
    ('Mask', ('Behaviour', 'component', 'Control', 'UnityEngineUIMask')),
    ('RectMask2D', ('Behaviour', 'component', 'Control', 'UnityEngineUIRectMask2D')),
    ('BaseMeshEffect', ('Behaviour', 'component', 'Control', 'UnityEngineUIBaseMeshEffect')),
    ('Shadow', ('BaseMeshEffect', 'component', 'Control', 'UnityEngineUIShadow')),
    ('Outline', ('Shadow', 'component', 'Control', 'UnityEngineUIOutline')),
    ('PositionAsUV1', ('BaseMeshEffect', 'component', 'Control', 'UnityEngineUIPositionAsUV1')),
    ('AspectRatioFitter', ('Behaviour', 'component', 'Control', 'UnityEngineUIAspectRatioFitter')),
    ('LayoutElement', ('Behaviour', 'component', 'Control', 'UnityEngineUILayoutElement')),
    ('LayoutGroup', ('Behaviour', 'component', 'Container', 'UnityEngineUILayoutGroup')),
    ('HorizontalOrVerticalLayoutGroup', ('LayoutGroup', 'component', 'BoxContainer', 'UnityEngineUIHorizontalOrVerticalLayoutGroup')),
    ('HorizontalLayoutGroup', ('HorizontalOrVerticalLayoutGroup', 'component', 'HBoxContainer', 'UnityEngineUIHorizontalLayoutGroup')),
    ('VerticalLayoutGroup', ('HorizontalOrVerticalLayoutGroup', 'component', 'VBoxContainer', 'UnityEngineUIVerticalLayoutGroup')),
    ('GridLayoutGroup', ('LayoutGroup', 'component', 'GridContainer', 'UnityEngineUIGridLayoutGroup')),
    ('ContentSizeFitter', ('Behaviour', 'component', 'Control', 'UnityEngineUIContentSizeFitter')),
    ('Canvas', ('Behaviour', 'component', 'CanvasLayer', 'UnityEngineCanvas')),
    ('CanvasScaler', ('Behaviour', 'component', 'CanvasLayer', 'UnityEngineUICanvasScaler')),
    ('CanvasGroup', ('Behaviour', 'component', 'Control', 'UnityEngineCanvasGroup')),
    ('GraphicRaycaster', ('Behaviour', 'component', 'Node', 'UnityEngineUIGraphicRaycaster')),
    ('ScrollRect', ('Behaviour', 'component', 'ScrollContainer', 'UnityEngineUIScrollRect')),
    ('TMP_Text', ('Graphic', 'component', 'Control', 'TMProTMP_Text')),
    ('TextMeshPro', ('TMP_Text', 'component', 'Node', 'TMProTextMeshPro')),
    ('TextMeshProUGUI', ('TMP_Text', 'component', 'Control', 'TMProTextMeshProUGUI')),
    ('TMP_Dropdown', ('Graphic', 'component', 'OptionButton', 'TMProTMP_Dropdown')),
    ('ToggleGroup', ('Behaviour', 'component', 'ButtonGroup', 'UnityEngineUIToggleGroup')),
    ('RectTransform', ('Transform', 'component', 'Control', 'UnityEngineRectTransform')),
    ('CanvasRenderer', ('Component', 'component', 'CanvasItem', 'UnityEngineCanvasRenderer')),
    ('Sprite', ('Object', 'class', 'Texture2D', 'UnityEngineSprite')),
    ('LayoutUtility', (None, 'static', None, 'UnityEngineUILayoutUtility')),
    ('LayoutRebuilder', (None, 'static', None, 'UnityEngineUILayoutRebuilder')),
    ('MaskUtilities', (None, 'static', None, 'UnityEngineUIMaskUtilities')),
    ('DefaultControls', (None, 'static', None, 'UnityEngineUIDefaultControls')),
    ('Clipping', (None, 'static', None, 'UnityEngineUIClipping')),
])

# dictionary-backed structs: name -> (mangled, ctor template or None, {field: default})
STRUCTS = collections.OrderedDict([
    ('ColorBlock', ('UnityEngineUIColorBlock', 'U.ui_default_colors()', {})),
    ('Navigation', ('UnityEngineUINavigation', '{"mode": 3, "selectOnUp": null, "selectOnDown": null, "selectOnLeft": null, "selectOnRight": null, "wrapAround": false}', {'mode': '3'})),
    ('AnimationTriggers', ('UnityEngineUIAnimationTriggers', '{"normalTrigger": "Normal", "highlightedTrigger": "Highlighted", "pressedTrigger": "Pressed", "selectedTrigger": "Selected", "disabledTrigger": "Disabled"}', {'normalTrigger': '"Normal"', 'highlightedTrigger': '"Highlighted"', 'pressedTrigger': '"Pressed"', 'selectedTrigger': '"Selected"', 'disabledTrigger': '"Disabled"'})),
    ('SpriteState', ('UnityEngineUISpriteState', '{}', {})),
    ('Dropdown.OptionData', ('UnityEngineUIDropdownOptionData', '{"text": "", "image": null}', {'text': '""'})),
    ('TMP_Dropdown.OptionData', ('TMProTMP_DropdownOptionData', '{"text": "", "image": null}', {'text': '""'})),
    ('Dropdown.OptionDataList', ('UnityEngineUIDropdownOptionDataList', '{"options": []}', {'options': '[]'})),
    ('TMP_TextInfo', ('TMProTMP_TextInfo', '{}', {})),
    ('TMP_MeshInfo', ('TMProTMP_MeshInfo', '{}', {})),
    ('TextGenerationSettings', ('UnityEngineTextGenerationSettings', '{}', {'fontSize': '14', 'lineSpacing': '1.0', 'scaleFactor': '1.0', 'richText': 'true', 'color': 'Color.WHITE'})),
    ('FontData', ('UnityEngineUIFontData', '{"fontSize": 14, "lineSpacing": 1.0, "richText": true}', {'fontSize': '14', 'lineSpacing': '1.0', 'richText': 'true'})),
    ('DefaultControlsResources', ('UnityEngineUIDefaultControlsResources', '{}', {})),
    ('VertexHelper', ('UnityEngineUIVertexHelper', '{"verts": 0, "indices": 0}', {})),
])

# signals: Invoke emits
EVENTS = {
    'ButtonButtonClickedEvent': 'UnityEngineUIButtonButtonClickedEvent', 'SliderSliderEvent': 'UnityEngineUISliderSliderEvent',
    'ToggleToggleEvent': 'UnityEngineUIToggleToggleEvent', 'ScrollRectScrollRectEvent': 'UnityEngineUIScrollRectScrollRectEvent',
    'ScrollbarScrollEvent': 'UnityEngineUIScrollbarScrollEvent', 'Dropdown.DropdownEvent': 'UnityEngineUIDropdownDropdownEvent',
}

# Unity-internal methods that mean nothing in Godot (layout is automatic, the event system is Godot's): plain no-ops
PASS = {'CalculateLayoutInputHorizontal', 'CalculateLayoutInputVertical', 'SetLayoutHorizontal', 'SetLayoutVertical', 'Rebuild', 'LayoutComplete',
        'GraphicUpdateComplete', 'SetLayoutDirty', 'SetMaterialDirty', 'SetRaycastDirty', 'SetVerticesDirty', 'SetAllDirty', 'OnCullingChanged',
        'RecalculateClipping', 'RecalculateMasking', 'Cull', 'SetClipRect', 'SetClipSoftness', 'ForceLabelUpdate', 'OnPointerDown', 'OnPointerUp',
        'OnPointerEnter', 'OnPointerExit', 'OnSelect', 'OnDeselect', 'OnMove', 'OnDrag', 'OnBeginDrag', 'OnEndDrag', 'OnInitializePotentialDrag',
        'OnUpdateSelected', 'OnScroll', 'ProcessEvent', 'ModifyMesh', 'DisableSpriteOptimizations', 'UpdateGeometry', 'UpdateMeshPadding',
        'ForceMeshUpdate', 'ComputeMarginSize', 'UpdateVertexData', 'UpdateFontAsset', 'ClearMesh', 'CrossFadeAlpha', 'CrossFadeColor',
        'RegisterDirtyLayoutCallback', 'UnregisterDirtyLayoutCallback', 'RegisterDirtyVerticesCallback', 'UnregisterDirtyVerticesCallback',
        'RegisterDirtyMaterialCallback', 'UnregisterDirtyMaterialCallback', 'ForceUpdateCanvases', 'Notify2DMaskStateChanged', 'NotifyStencilStateChanged',
        'MarkLayoutForRebuild', 'ForceRebuildLayoutImmediate', 'EnsureValidState', 'RegisterToggle', 'UnregisterToggle', 'NotifyToggleOn',
        'ForceUpdateRectTransforms', 'SetDirection', 'RecalculateClipping', 'ReleaseSelection', 'MoveToStartOfLine', 'MoveToEndOfLine',
        'MoveTextEnd', 'MoveTextStart', 'OnUpdateSelected', 'OnPointerClick', 'OnSubmit', 'AddClippable', 'RemoveClippable', 'PerformClipping',
        'UpdateClipSoftness', 'UpdateSprite', 'OnValidate', 'Update', 'LateUpdate', 'Awake', 'OnEnable', 'OnDisable', 'Start', 'OnDestroy',
        'SetVerticesDirty', 'SetTextCustom', 'UpdateSDFScale', 'CalculateLayoutInputVertical'}

# explicit member templates: (type, key) where key is 'prop', 'set prop', or 'Method/argcount'
SPEC = {
    ('Selectable', 'IsInteractable/0'): 'U.ui_get_interactable($0)',
    ('Selectable', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('Selectable', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('Selectable', 'FindSelectableOnUp/0'): 'U.ui_neighbor($0, "up")',
    ('Selectable', 'FindSelectableOnDown/0'): 'U.ui_neighbor($0, "down")',
    ('Selectable', 'FindSelectableOnLeft/0'): 'U.ui_neighbor($0, "left")',
    ('Selectable', 'FindSelectableOnRight/0'): 'U.ui_neighbor($0, "right")',
    ('Selectable', 'FindSelectable/1'): 'null',
    ('Selectable', 'OnPointerClick/1'): 'U.ui_press($0, null)',
    ('Selectable', 'OnSubmit/1'): 'U.ui_press($0, null)',
    ('Selectable', 'navigation'): 'U.ui_nav_get($0)',
    ('Selectable', 'set navigation'): 'U.ui_nav_set($0, $v)',
    ('Selectable', 'colors'): 'U.ui_colors_get($0)',
    ('Selectable', 'set colors'): 'U.ui_colors_set($0, $v)',
    ('Selectable', 'spriteState'): 'U.ui_sprite_state_get($0)',
    ('Selectable', 'set spriteState'): 'U.ui_sprite_state_set($0, $v)',
    ('Selectable', 'animator'): 'null',
    ('Selectable', 'set image'): 'pass',
    ('Selectable', 'set targetGraphic'): 'pass',
    ('Selectable', 'allSelectableCount'): 'U.find_objects_of_type("Selectable").size()',
    ('Selectable', 'allSelectablesArray'): 'U.find_objects_of_type("Selectable")',
    ('Selectable', 'AllSelectablesNoAlloc/1'): 'U.fill_array($1, U.find_objects_of_type("Selectable"))',
    ('Button', 'OnPointerClick/1'): 'U.ui_press($0, null)',
    ('Button', 'OnSubmit/1'): 'U.ui_press($0, null)',
    ('Toggle', 'OnPointerClick/1'): 'U.ui_press($0, null)',
    ('Toggle', 'OnSubmit/1'): 'U.ui_press($0, null)',
    ('Toggle', 'group'): 'U.toggle_get_group($0)',
    ('Toggle', 'set group'): 'U.toggle_set_group($0, $v)',
    ('Toggle', 'set graphic'): 'pass',
    ('Slider', 'fillRect'): 'null',
    ('Slider', 'handleRect'): 'null',
    ('Slider', 'set fillRect'): 'pass',
    ('Slider', 'set handleRect'): 'pass',
    ('Scrollbar', 'onValueChanged'): '$0.value_changed',
    ('Scrollbar', 'interactable'): '$0.editable',
    ('Scrollbar', 'set interactable'): '$0.editable = $v',
    ('Scrollbar', 'SetValueWithoutNotify/1'): '$0.set_value_no_signal($1)',
    ('Scrollbar', 'handleRect'): 'null',
    ('Scrollbar', 'set handleRect'): 'pass',
    ('Dropdown', 'options'): 'U.dd_options($0)',
    ('Dropdown', 'set options'): 'U.dd_set_options($0, $v)',
    ('Dropdown', 'AddOptions/1'): 'U.dd_add_options($0, $1)',
    ('Dropdown', 'onValueChanged'): '$0.item_selected',
    ('Dropdown', 'captionText'): '$0',
    ('Dropdown', 'set captionText'): 'pass',
    ('Dropdown', 'captionImage'): 'null',
    ('Dropdown', 'set captionImage'): 'pass',
    ('Dropdown', 'itemText'): 'null',
    ('Dropdown', 'set itemText'): 'pass',
    ('Dropdown', 'itemImage'): 'null',
    ('Dropdown', 'set itemImage'): 'pass',
    ('Dropdown', 'template'): 'null',
    ('Dropdown', 'set template'): 'pass',
    ('Dropdown', 'Show/0'): '$0.show_popup()',
    ('Dropdown', 'Hide/0'): '$0.get_popup().hide()',
    ('TMP_Dropdown', 'options'): 'U.dd_options($0)',
    ('TMP_Dropdown', 'set options'): 'U.dd_set_options($0, $v)',
    ('TMP_Dropdown', 'AddOptions/1'): 'U.dd_add_options($0, $1)',
    ('TMP_Dropdown', 'Show/0'): '$0.show_popup()',
    ('TMP_Dropdown', 'Hide/0'): '$0.get_popup().hide()',
    ('TMP_Dropdown', 'IsExpanded'): '$0.get_popup().visible',
    ('TMP_Dropdown', 'value'): '$0.selected',
    ('TMP_Dropdown', 'set value'): '$0.select($v)',
    ('TMP_Dropdown', 'onValueChanged'): '$0.item_selected',
    ('TMP_Dropdown', 'captionText'): '$0',
    ('TMP_Dropdown', 'set captionText'): 'pass',
    ('TMP_Dropdown', 'interactable'): 'not $0.disabled',
    ('TMP_Dropdown', 'set interactable'): '$0.disabled = not $v',
    ('TMP_Dropdown', 'SetValueWithoutNotify/1'): '$0.select($1)',
    ('TMP_Dropdown', 'ClearOptions/0'): '$0.clear()',
    ('TMP_Dropdown', 'RefreshShownValue/0'): 'pass',
    ('InputField', 'onEndEdit'): '$0.text_submitted',
    ('InputField', 'onSubmit'): '$0.text_submitted',
    ('InputField', 'onValueChanged'): '$0.text_changed',
    ('InputField', 'MoveTextEnd/1'): '$0.caret_column = $0.text.length()',
    ('InputField', 'MoveTextStart/1'): '$0.caret_column = 0',
    ('InputField', 'flexibleWidth'): 'U.ui_flexible_get($0, "x")',
    ('InputField', 'flexibleHeight'): 'U.ui_flexible_get($0, "y")',
    ('InputField', 'minWidth'): 'U.ui_min_size($0, "x")',
    ('InputField', 'minHeight'): 'U.ui_min_size($0, "y")',
    ('InputField', 'preferredWidth'): 'U.ui_preferred_size($0, "x")',
    ('InputField', 'preferredHeight'): 'U.ui_preferred_size($0, "y")',
    ('InputField', 'layoutPriority'): '1',
    ('TMP_InputField', 'isFocused'): '$0.has_focus()',
    ('TMP_InputField', 'readOnly'): 'not $0.editable',
    ('TMP_InputField', 'set readOnly'): '$0.editable = not $v',
    ('TMP_InputField', 'richText'): 'false',
    ('TMP_InputField', 'set richText'): 'pass',
    ('Graphic', 'canvas'): 'U.ui_canvas($0)',
    ('Graphic', 'depth'): 'U.ui_depth($0)',
    ('Graphic', 'materialForRendering'): '$0.material',
    ('Graphic', 'mainTexture'): 'U.ui_get_texture($0)',
    ('Graphic', 'GetPixelAdjustedRect/0'): 'U.ui_rect($0)',
    ('Graphic', 'PixelAdjustPoint/1'): '$1',
    ('Graphic', 'Raycast/2'): 'U.ui_raycast($0, $1)',
    ('Graphic', 'SetNativeSize/0'): 'U.ui_set_native_size($0)',
    ('Graphic', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('Graphic', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('Graphic', 'GetModifiedMaterial/1'): '$1',
    ('MaskableGraphic', 'maskable'): 'true',
    ('MaskableGraphic', 'set maskable'): 'pass',
    ('MaskableGraphic', 'isMaskingGraphic'): '$0.clip_contents',
    ('MaskableGraphic', 'set isMaskingGraphic'): '$0.clip_contents = $v',
    ('MaskableGraphic', 'GetModifiedMaterial/1'): '$1',
    ('Image', 'preferredWidth'): 'U.ui_texture_size($0, "x")',
    ('Image', 'preferredHeight'): 'U.ui_texture_size($0, "y")',
    ('Image', 'flexibleWidth'): '-1.0',
    ('Image', 'flexibleHeight'): '-1.0',
    ('Image', 'minWidth'): '0.0',
    ('Image', 'minHeight'): '0.0',
    ('Image', 'layoutPriority'): '0',
    ('Image', 'mainTexture'): 'U.ui_get_texture($0)',
    ('Image', 'hasBorder'): 'false',
    ('Image', 'pixelsPerUnit'): 'U.sprite_ppu(U.ui_get_texture($0))',
    ('Image', 'alphaHitTestMinimumThreshold'): '0.0',
    ('Image', 'set alphaHitTestMinimumThreshold'): 'pass',
    ('RawImage', 'mainTexture'): '$0.texture',
    ('Text', 'GetTextAnchorPivot/1'): 'U.text_anchor_pivot($1)',
    ('Text', 'preferredWidth'): 'U.ui_preferred_size($0, "x")',
    ('Text', 'preferredHeight'): 'U.ui_preferred_size($0, "y")',
    ('Text', 'flexibleWidth'): '-1.0',
    ('Text', 'flexibleHeight'): '-1.0',
    ('Text', 'minWidth'): '0.0',
    ('Text', 'minHeight'): '0.0',
    ('Text', 'layoutPriority'): '0',
    ('Text', 'mainTexture'): 'null',
    ('Text', 'font'): 'null',
    ('Text', 'set font'): 'pass',
    ('Text', 'fontData'): '{"fontSize": U.ui_get_font_size($0), "lineSpacing": 1.0, "richText": true}',
    ('Mask', 'enabled'): '$0.clip_contents',
    ('Mask', 'set enabled'): '$0.clip_contents = $v',
    ('Mask', 'MaskEnabled/0'): '$0.clip_contents',
    ('Mask', 'rectTransform'): '$0',
    ('Mask', 'graphic'): '$0',
    ('Mask', 'showMaskGraphic'): '$0.visible',
    ('Mask', 'set showMaskGraphic'): '$0.visible = $v',
    ('Mask', 'IsRaycastLocationValid/2'): 'U.ui_raycast($0, $1)',
    ('Mask', 'GetModifiedMaterial/1'): '$1',
    ('RectMask2D', 'enabled'): '$0.clip_contents',
    ('RectMask2D', 'set enabled'): '$0.clip_contents = $v',
    ('RectMask2D', 'rectTransform'): '$0',
    ('RectMask2D', 'canvasRect'): 'U.ui_rect($0)',
    ('RectMask2D', 'IsRaycastLocationValid/2'): 'U.ui_raycast($0, $1)',
    ('Shadow', 'effectColor'): 'U.ui_effect_get($0, "shadow", "effectColor", Color(0, 0, 0, 0.5))',
    ('Shadow', 'set effectColor'): 'U.ui_effect_set($0, "shadow", "effectColor", $v)',
    ('Shadow', 'effectDistance'): 'U.ui_effect_get($0, "shadow", "effectDistance", Vector2(1, -1))',
    ('Shadow', 'set effectDistance'): 'U.ui_effect_set($0, "shadow", "effectDistance", $v)',
    ('Shadow', 'useGraphicAlpha'): '!stored U.prop_get($0, "useGraphicAlpha", true)',
    ('Shadow', 'set useGraphicAlpha'): '!stored U.prop_set($0, "useGraphicAlpha", $v)',
    ('Shadow', 'enabled'): 'bool(U.ui_effect_get($0, "shadow", "enabled", true))',
    ('Shadow', 'set enabled'): 'U.ui_effect_set($0, "shadow", "enabled", $v)',
    ('Outline', 'effectColor'): 'U.ui_effect_get($0, "outline", "effectColor", Color(0, 0, 0, 0.5))',
    ('Outline', 'set effectColor'): 'U.ui_effect_set($0, "outline", "effectColor", $v)',
    ('Outline', 'effectDistance'): 'U.ui_effect_get($0, "outline", "effectDistance", Vector2(1, -1))',
    ('Outline', 'set effectDistance'): 'U.ui_effect_set($0, "outline", "effectDistance", $v)',
    ('Outline', 'enabled'): 'bool(U.ui_effect_get($0, "outline", "enabled", true))',
    ('Outline', 'set enabled'): 'U.ui_effect_set($0, "outline", "enabled", $v)',
    ('BaseMeshEffect', 'graphic'): '$0',
    ('AspectRatioFitter', 'aspectMode'): 'int(U.prop_get($0, "aspectMode", 0))',
    ('AspectRatioFitter', 'set aspectMode'): 'U.ui_aspect_set($0, "aspectMode", $v)',
    ('AspectRatioFitter', 'aspectRatio'): 'float(U.prop_get($0, "aspectRatio", 1.0))',
    ('AspectRatioFitter', 'set aspectRatio'): 'U.ui_aspect_set($0, "aspectRatio", $v)',
    ('AspectRatioFitter', 'IsComponentValidOnObject/0'): 'true',
    ('AspectRatioFitter', 'IsAspectModeValid/0'): 'true',
    ('LayoutElement', 'flexibleWidth'): 'U.ui_flexible_get($0, "x")',
    ('LayoutElement', 'set flexibleWidth'): 'U.ui_flexible_set($0, "x", $v)',
    ('LayoutElement', 'flexibleHeight'): 'U.ui_flexible_get($0, "y")',
    ('LayoutElement', 'set flexibleHeight'): 'U.ui_flexible_set($0, "y", $v)',
    ('LayoutElement', 'layoutPriority'): '!stored int(U.prop_get($0, "layoutPriority", 1))',
    ('LayoutElement', 'set layoutPriority'): '!stored U.prop_set($0, "layoutPriority", $v)',
    ('LayoutElement', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('LayoutElement', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('LayoutGroup', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('LayoutGroup', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('LayoutGroup', 'rectTransform'): '$0',
    ('HorizontalOrVerticalLayoutGroup', 'spacing'): 'float($0.get_theme_constant("separation"))',
    ('HorizontalOrVerticalLayoutGroup', 'set spacing'): '$0.add_theme_constant_override("separation", int($v))',
    ('HorizontalOrVerticalLayoutGroup', 'childForceExpandWidth'): '!stored bool(U.prop_get($0, "childForceExpandWidth", true))',
    ('HorizontalOrVerticalLayoutGroup', 'set childForceExpandWidth'): '!stored U.prop_set($0, "childForceExpandWidth", $v)',
    ('HorizontalOrVerticalLayoutGroup', 'childForceExpandHeight'): '!stored bool(U.prop_get($0, "childForceExpandHeight", true))',
    ('HorizontalOrVerticalLayoutGroup', 'set childForceExpandHeight'): '!stored U.prop_set($0, "childForceExpandHeight", $v)',
    ('GridLayoutGroup', 'flexibleWidth'): '0.0',
    ('GridLayoutGroup', 'flexibleHeight'): '0.0',
    ('GridLayoutGroup', 'layoutPriority'): '0',
    ('GridLayoutGroup', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('GridLayoutGroup', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('ContentSizeFitter', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('ContentSizeFitter', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('CanvasScaler', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('CanvasScaler', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('Canvas', 'pixelRect'): 'U.ui_canvas_get($0, "pixelRect", Rect2())',
    ('Canvas', 'renderingDisplaySize'): 'U.ui_canvas_get($0, "renderingDisplaySize", Vector2.ZERO)',
    ('Canvas', 'isRootCanvas'): 'U.ui_canvas_get($0, "isRootCanvas", true)',
    ('Canvas', 'rootCanvas'): 'U.ui_canvas_get($0, "rootCanvas", $0)',
    ('Canvas', 'referencePixelsPerUnit'): 'U.ui_canvas_get($0, "referencePixelsPerUnit", 100.0)',
    ('Canvas', 'set referencePixelsPerUnit'): 'U.ui_canvas_set($0, "referencePixelsPerUnit", $v)',
    ('Canvas', 'renderMode'): 'U.ui_canvas_get($0, "renderMode", 2)',
    ('Canvas', 'scaleFactor'): 'U.ui_canvas_get($0, "scaleFactor", 1.0)',
    ('Canvas', 'set scaleFactor'): 'U.ui_canvas_set($0, "scaleFactor", $v)',
    ('Canvas', 'renderOrder'): 'U.ui_depth($0)',
    ('Canvas', 'cachedSortingLayerValue'): '0',
    ('CanvasGroup', 'IsRaycastLocationValid/2'): 'U.ui_raycast($0, $1)',
    ('GraphicRaycaster', 'eventCamera'): 'null',
    ('GraphicRaycaster', 'Raycast/2'): 'pass',
    ('GraphicRaycaster', 'IsActive/0'): '$0.is_inside_tree()',
    ('GraphicRaycaster', 'rootRaycaster'): '$0',
    ('GraphicRaycaster', 'sortOrderPriority'): '0',
    ('GraphicRaycaster', 'renderOrderPriority'): '0',
    ('ScrollRect', 'set content'): 'pass',
    ('ScrollRect', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('ScrollRect', 'IsActive/0'): '$0.is_visible_in_tree()',
    ('ScrollRect', 'onValueChanged'): '$0.get_v_scroll_bar().value_changed',
    ('ScrollRect', 'horizontalScrollbar'): '$0.get_h_scroll_bar()',
    ('ScrollRect', 'set horizontalScrollbar'): 'pass',
    ('ScrollRect', 'verticalScrollbar'): '$0.get_v_scroll_bar()',
    ('ScrollRect', 'set verticalScrollbar'): 'pass',
    ('ScrollRect', 'viewport'): '$0',
    ('ScrollRect', 'set viewport'): 'pass',
    ('ScrollRect', 'normalizedPosition'): 'Vector2(U.scroll_get_h($0), U.scroll_get_v($0))',
    ('ScrollRect', 'set normalizedPosition'): 'U.scroll_set_h($0, $v.x) ;; U.scroll_set_v($0, $v.y)',
    ('ScrollRect', 'StopMovement/0'): 'pass',
    ('ScrollRect', 'Rebuild/1'): 'pass',
    ('ScrollRect', 'flexibleWidth'): '-1.0',
    ('ScrollRect', 'flexibleHeight'): '-1.0',
    ('ScrollRect', 'minWidth'): 'U.ui_min_size($0, "x")',
    ('ScrollRect', 'minHeight'): 'U.ui_min_size($0, "y")',
    ('ScrollRect', 'preferredWidth'): 'U.ui_preferred_size($0, "x")',
    ('ScrollRect', 'preferredHeight'): 'U.ui_preferred_size($0, "y")',
    ('ScrollRect', 'layoutPriority'): '-1',
    ('TMP_Text', 'alpha'): 'U.ui_alpha_get($0)',
    ('TMP_Text', 'set alpha'): 'U.ui_alpha_set($0, $v)',
    ('TMP_Text', 'horizontalAlignment'): 'U.ui_halign_get($0)',
    ('TMP_Text', 'set horizontalAlignment'): 'U.ui_halign_set($0, $v)',
    ('TMP_Text', 'verticalAlignment'): 'U.ui_valign_get($0)',
    ('TMP_Text', 'set verticalAlignment'): 'U.ui_valign_set($0, $v)',
    ('TMP_Text', 'alignment'): 'U.ui_alignment_get($0)',
    ('TMP_Text', 'set alignment'): 'U.ui_alignment_set($0, $v)',
    ('TMP_Text', 'overflowMode'): 'U.ui_overflow_get($0)',
    ('TMP_Text', 'set overflowMode'): 'U.ui_overflow_set($0, $v)',
    ('TMP_Text', 'maxVisibleLines'): 'U.ui_max_lines_get($0)',
    ('TMP_Text', 'set maxVisibleLines'): 'U.ui_max_lines_set($0, $v)',
    ('TMP_Text', 'isRightToLeftText'): 'U.ui_rtl_get($0)',
    ('TMP_Text', 'set isRightToLeftText'): 'U.ui_rtl_set($0, $v)',
    ('TMP_Text', 'enableWordWrapping'): 'U.ui_wrap_get($0)',
    ('TMP_Text', 'set enableWordWrapping'): 'U.ui_wrap_set($0, $v)',
    ('TMP_Text', 'lineSpacing'): 'U.ui_line_spacing_get($0)',
    ('TMP_Text', 'set lineSpacing'): 'U.ui_line_spacing_set($0, $v)',
    ('TMP_Text', 'fontMaterial'): '$0.material',
    ('TMP_Text', 'set fontMaterial'): '$0.material = $v',
    ('TMP_Text', 'fontSharedMaterial'): '$0.material',
    ('TMP_Text', 'set fontSharedMaterial'): '$0.material = $v',
    ('TMP_Text', 'textInfo'): 'U.ui_text_info($0)',
    ('TMP_Text', 'preferredWidth'): 'U.ui_preferred_size($0, "x")',
    ('TMP_Text', 'preferredHeight'): 'U.ui_preferred_size($0, "y")',
    ('TMP_Text', 'flexibleWidth'): '-1.0',
    ('TMP_Text', 'flexibleHeight'): '-1.0',
    ('TMP_Text', 'minWidth'): '0.0',
    ('TMP_Text', 'minHeight'): '0.0',
    ('TMP_Text', 'layoutPriority'): '0',
    ('TMP_Text', 'GetPreferredValues/0'): 'Vector2(U.ui_preferred_size($0, "x"), U.ui_preferred_size($0, "y"))',
    ('TMP_Text', 'GetPreferredValues/1'): 'Vector2(U.ui_preferred_size($0, "x"), U.ui_preferred_size($0, "y"))',
    ('TMP_Text', 'GetPreferredValues/2'): 'Vector2(U.ui_preferred_size($0, "x"), U.ui_preferred_size($0, "y"))',
    ('TMP_Text', 'GetPreferredValues/3'): 'Vector2(U.ui_preferred_size($0, "x"), U.ui_preferred_size($0, "y"))',
    ('TMP_Text', 'GetRenderedValues/0'): 'U.ui_rect($0).size',
    ('TMP_Text', 'GetRenderedValues/1'): 'U.ui_rect($0).size',
    ('TMP_Text', 'GetParsedText/0'): 'U.ui_get_text($0)',
    ('TMP_Text', 'GetTextInfo/1'): 'U.ui_text_info($0)',
    ('TMP_Text', 'SetText/1'): 'U.ui_set_text($0, str($1))',
    ('TMP_Text', 'SetText/2'): 'U.ui_set_text($0, str($1))',
    ('TMP_Text', 'SetText/3'): 'U.ui_set_text($0, str($1))',
    ('TMP_Text', 'SetText/4'): 'U.ui_set_text($0, str($1))',
    ('TMP_Text', 'firstVisibleCharacter'): '!stored int(U.prop_get($0, "firstVisibleCharacter", 0))',
    ('TMP_Text', 'set firstVisibleCharacter'): '!stored U.prop_set($0, "firstVisibleCharacter", $v)',
    ('TextMeshProUGUI', 'isMaskingGraphic'): '$0.clip_contents',
    ('TextMeshProUGUI', 'set isMaskingGraphic'): '$0.clip_contents = $v',
    ('TextMeshProUGUI', 'mainTexture'): 'null',
    ('TextMeshPro', 'mainTexture'): 'null',
    ('TextMeshPro', 'renderer'): '$0',
    ('TextMeshPro', 'isMaskingGraphic'): 'false',
    ('TextMeshPro', 'set isMaskingGraphic'): 'pass',
    ('ToggleGroup', 'ActiveToggles/0'): 'U.toggle_group_active($0)',
    ('ToggleGroup', 'AnyTogglesOn/0'): 'U.toggle_group_first($0) != null',
    ('ToggleGroup', 'GetFirstActiveToggle/0'): 'U.toggle_group_first($0)',
    ('ToggleGroup', 'SetAllTogglesOff/0'): 'U.toggle_group_clear($0)',
    ('ToggleGroup', 'SetAllTogglesOff/1'): 'U.toggle_group_clear($0)',
    ('ToggleGroup', 'IsActive/0'): 'true',
    ('ToggleGroup', 'IsDestroyed/0'): 'not is_instance_valid($0)',
    ('RectTransform', 'GetLocalCorners/1'): 'U.rect_local_corners($0, $1)',
    ('RectTransform', 'hierarchyCount'): '$0.get_child_count() + 1',
    ('RectTransform', 'set hierarchyCapacity'): 'pass',
    ('RectTransform', 'drivenByObject'): 'null',
    ('RectTransform', 'set anchoredPosition3D'): 'U.rect_set_anchored_position($0, Vector2($v.x, $v.y))',
    ('CanvasRenderer', 'GetMesh/0'): 'null',
    ('Sprite', 'rect'): 'U.sprite_rect($0)',
    ('Sprite', 'textureRect'): 'U.sprite_rect($0)',
    ('Sprite', 'textureRectOffset'): 'Vector2.ZERO',
    ('Sprite', 'pivot'): 'U.sprite_pivot($0)',
    ('Sprite', 'pixelsPerUnit'): 'U.sprite_ppu($0)',
    ('Sprite', 'bounds'): 'U.sprite_bounds($0)',
    ('Sprite', 'border'): 'Vector4.ZERO',
    ('Sprite', 'packed'): 'false',
    ('Sprite', 'packingMode'): '0',
    ('Sprite', 'packingRotation'): '0',
    ('Sprite', 'associatedAlphaSplitTexture'): 'null',
    ('Sprite', 'vertices'): '[]',
    ('Sprite', 'triangles'): '[]',
    ('Sprite', 'uv'): '[]',
    ('Sprite', 'GetPhysicsShapeCount/0'): '0',
    ('Sprite', 'GetPhysicsShapePointCount/1'): '0',
    ('Sprite', 'GetPhysicsShape/2'): '0',
    ('Sprite', 'GetSecondaryTextureCount/0'): '0',
    ('Sprite', 'GetSecondaryTextures/1'): '0',
    ('Sprite', 'OverrideGeometry/2'): 'pass',
    ('Sprite', 'OverridePhysicsShape/1'): 'pass',
    ('LayoutUtility', 'GetMinWidth/1'): 'U.ui_min_size($1, "x")',
    ('LayoutUtility', 'GetMinHeight/1'): 'U.ui_min_size($1, "y")',
    ('LayoutUtility', 'GetPreferredWidth/1'): 'U.ui_preferred_size($1, "x")',
    ('LayoutUtility', 'GetPreferredHeight/1'): 'U.ui_preferred_size($1, "y")',
    ('LayoutUtility', 'GetFlexibleWidth/1'): 'U.ui_flexible_get($1, "x")',
    ('LayoutUtility', 'GetFlexibleHeight/1'): 'U.ui_flexible_get($1, "y")',
    ('LayoutUtility', 'GetMinSize/2'): 'U.ui_min_size($1, "x" if $2 == 0 else "y")',
    ('LayoutUtility', 'GetPreferredSize/2'): 'U.ui_preferred_size($1, "x" if $2 == 0 else "y")',
    ('LayoutUtility', 'GetFlexibleSize/2'): 'U.ui_flexible_get($1, "x" if $2 == 0 else "y")',
    ('LayoutRebuilder', 'ForceRebuildLayoutImmediate/1'): 'pass',
    ('LayoutRebuilder', 'MarkLayoutForRebuild/1'): 'pass',
    ('LayoutRebuilder', 'transform'): 'null',
    ('LayoutRebuilder', 'IsDestroyed/0'): 'false',
    ('MaskUtilities', 'IsDescendantOrSelf/2'): '($1 == $2 or $1.is_ancestor_of($2))',
    ('MaskUtilities', 'FindRootSortOverrideCanvas/1'): 'U.ui_canvas($1)',
    ('MaskUtilities', 'GetStencilDepth/2'): '0',
    ('MaskUtilities', 'GetRectMaskForClippable/1'): 'null',
    ('MaskUtilities', 'GetRectMasksForClip/2'): 'pass',
    ('Clipping', 'FindCullAndClipWorldRect/2'): 'Rect2()',
}


def demangle(m, ext_map, all_types):
    return G.demangle_type(m, ext_map, all_types)


def handwritten():
    """type → (base, set of member keys) from every hand-written catalog file."""
    types = {}
    for f in sorted(os.listdir(G.API)):
        if not f.endswith('.udon') or f in ('generated.udon', 'unity_ui.udon'):
            continue
        cur = None
        for line in open(os.path.join(G.API, f)):
            if line.startswith('type '):
                parts = line.split()
                cur = parts[1]
                base = parts[3] if len(parts) > 3 and parts[2] == ':' else None
                entry = types.setdefault(cur, [None, set()])
                if base:
                    entry[0] = base
            elif line.startswith('alias '):
                continue
            elif cur and line.startswith('  '):
                head = line.strip().split('=>')[0].strip()
                if head.startswith('enum '):
                    types[cur][1].add(head.split()[1])
                    continue
                if head.startswith('static '):
                    head = head[7:]
                is_set = head.startswith('set ')
                if is_set:
                    head = head[4:]
                name = head.split('(')[0].split(':')[0].strip()
                if head.startswith('ctor'):
                    name = 'ctor'
                types[cur][1].add(('set ' if is_set else '') + name)
    return types


GENERATED = {}  # type → member keys emitted earlier in this run (base types come first in TYPES)


def chain_has(types, tname, key):
    seen = set()
    cur = tname
    while cur and cur not in seen:
        seen.add(cur)
        if cur in types and key in types[cur][1]:
            return True
        if cur in GENERATED and key in GENERATED[cur]:
            return True
        nxt = types[cur][0] if cur in types else None
        if nxt is None and cur in TYPES:
            nxt = TYPES[cur][0]
        cur = nxt
    return False


GENERIC = {'IsActive/0': '$0.is_visible_in_tree()', 'IsDestroyed/0': 'not is_instance_valid($0)'}

STATIC = {('Sprite', 'Create'), ('Text', 'GetTextAnchorPivot')}
SPEC.update({
    ('Sprite', 'Create/3'): 'U.sprite_create($1, $2, $3)',
    ('Sprite', 'Create/4'): 'U.sprite_create($1, $2, $3, $4)',
    ('Sprite', 'Create/5'): 'U.sprite_create($1, $2, $3, $4)',
    ('Sprite', 'Create/6'): 'U.sprite_create($1, $2, $3, $4)',
    ('Sprite', 'Create/7'): 'U.sprite_create($1, $2, $3, $4)',
    ('Sprite', 'Create/8'): 'U.sprite_create($1, $2, $3, $4)',
    ('Sprite', 'Create/9'): 'U.sprite_create($1, $2, $3, $4)',
})

# nested enums of the UI types (C# spells them Owner.Name)
ENUMS = collections.OrderedDict([
    ('Selectable.Transition', ('UnityEngineUISelectableTransition', ['None', 'ColorTint', 'SpriteSwap', 'Animation'])),
    ('Navigation.Mode', ('UnityEngineUINavigationMode', ['None', 'Horizontal', 'Vertical', 'Automatic', 'Explicit'])),
    ('Slider.Direction', ('UnityEngineUISliderDirection', ['LeftToRight', 'RightToLeft', 'BottomToTop', 'TopToBottom'])),
    ('Scrollbar.Direction', ('UnityEngineUIScrollbarDirection', ['LeftToRight', 'RightToLeft', 'BottomToTop', 'TopToBottom'])),
    ('Image.Type', ('UnityEngineUIImageType', ['Simple', 'Sliced', 'Tiled', 'Filled'])),
    ('Image.FillMethod', ('UnityEngineUIImageFillMethod', ['Horizontal', 'Vertical', 'Radial90', 'Radial180', 'Radial360'])),
    ('Toggle.ToggleTransition', ('UnityEngineUIToggleToggleTransition', ['None', 'Fade'])),
    ('CanvasScaler.ScaleMode', ('UnityEngineUICanvasScalerScaleMode', ['ConstantPixelSize', 'ScaleWithScreenSize', 'ConstantPhysicalSize'])),
    ('CanvasScaler.ScreenMatchMode', ('UnityEngineUICanvasScalerScreenMatchMode', ['MatchWidthOrHeight', 'Expand', 'Shrink'])),
    ('ContentSizeFitter.FitMode', ('UnityEngineUIContentSizeFitterFitMode', ['Unconstrained', 'MinSize', 'PreferredSize'])),
    ('AspectRatioFitter.AspectMode', ('UnityEngineUIAspectRatioFitterAspectMode', ['None', 'WidthControlsHeight', 'HeightControlsWidth', 'FitInParent', 'EnvelopeParent'])),
    ('GridLayoutGroup.Corner', ('UnityEngineUIGridLayoutGroupCorner', ['UpperLeft', 'UpperRight', 'LowerLeft', 'LowerRight'])),
    ('GridLayoutGroup.Axis', ('UnityEngineUIGridLayoutGroupAxis', ['Horizontal', 'Vertical'])),
    ('GridLayoutGroup.Constraint', ('UnityEngineUIGridLayoutGroupConstraint', ['Flexible', 'FixedColumnCount', 'FixedRowCount'])),
    ('InputField.ContentType', ('UnityEngineUIInputFieldContentType', ['Standard', 'Autocorrected', 'IntegerNumber', 'DecimalNumber', 'Alphanumeric', 'Name', 'EmailAddress', 'Password', 'Pin', 'Custom'])),
    ('InputField.InputType', ('UnityEngineUIInputFieldInputType', ['Standard', 'AutoCorrect', 'Password'])),
    ('InputField.LineType', ('UnityEngineUIInputFieldLineType', ['SingleLine', 'MultiLineSubmit', 'MultiLineNewline'])),
    ('InputField.CharacterValidation', ('UnityEngineUIInputFieldCharacterValidation', ['None', 'Integer', 'Decimal', 'Alphanumeric', 'Name', 'EmailAddress'])),
    ('TMP_InputField.ContentType', ('TMProTMP_InputFieldContentType', ['Standard', 'Autocorrected', 'IntegerNumber', 'DecimalNumber', 'Alphanumeric', 'Name', 'EmailAddress', 'Password', 'Pin', 'Custom'])),
    ('TMP_InputField.InputType', ('TMProTMP_InputFieldInputType', ['Standard', 'AutoCorrect', 'Password'])),
    ('TMP_InputField.LineType', ('TMProTMP_InputFieldLineType', ['SingleLine', 'MultiLineSubmit', 'MultiLineNewline'])),
    ('TMP_InputField.CharacterValidation', ('TMProTMP_InputFieldCharacterValidation', ['None', 'Digit', 'Integer', 'Decimal', 'Alphanumeric', 'Name', 'Regex', 'EmailAddress', 'CustomValidator'])),
    ('ScrollRect.MovementType', ('UnityEngineUIScrollRectMovementType', ['Unrestricted', 'Elastic', 'Clamped'])),
    ('ScrollRect.ScrollbarVisibility', ('UnityEngineUIScrollRectScrollbarVisibility', ['Permanent', 'AutoHide', 'AutoHideAndExpandViewport'])),
    ('RenderMode', ('UnityEngineRenderMode', ['ScreenSpaceOverlay', 'ScreenSpaceCamera', 'WorldSpace'])),
    ('TextAnchor', ('UnityEngineTextAnchor', ['UpperLeft', 'UpperCenter', 'UpperRight', 'MiddleLeft', 'MiddleCenter', 'MiddleRight', 'LowerLeft', 'LowerCenter', 'LowerRight'])),
    ('FontStyle', ('UnityEngineFontStyle', ['Normal', 'Bold', 'Italic', 'BoldAndItalic'])),
    ('HorizontalWrapMode', ('UnityEngineHorizontalWrapMode', ['Wrap', 'Overflow'])),
    ('VerticalWrapMode', ('UnityEngineVerticalWrapMode', ['Truncate', 'Overflow'])),
    ('CanvasUpdate', ('UnityEngineUICanvasUpdate', ['Prelayout', 'Layout', 'PostLayout', 'PreRender', 'LatePreRender', 'MaxUpdateValue'])),
    ('RectTransform.Edge', ('UnityEngineRectTransformEdge', ['Left', 'Right', 'Top', 'Bottom'])),
    ('RectTransform.Axis', ('UnityEngineRectTransformAxis', ['Horizontal', 'Vertical'])),
    ('AdditionalCanvasShaderChannels', ('UnityEngineAdditionalCanvasShaderChannels', ['None', 'TexCoord1', 'TexCoord2', 'TexCoord3', 'Normal', 'Tangent'])),
    ('FontStyles', ('TMProFontStyles', ['Normal', 'Bold', 'Italic', 'Underline', 'LowerCase', 'UpperCase', 'SmallCaps', 'Strikethrough', 'Superscript', 'Subscript', 'Highlight'])),
])
ENUM_VALUES = {'AdditionalCanvasShaderChannels': [0, 1, 2, 4, 8, 16], 'FontStyles': [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512]}


def default_for(ty):
    if ty in STRUCTS or ty in ('ColorBlock', 'Navigation', 'AnimationTriggers', 'SpriteState'):
        return '{}'
    if ty == 'SelectableTransition':
        return '1'
    d = dict(G.GD_DEFAULT)
    d.update({'Vector3': 'Vector3.ZERO', 'Vector2': 'Vector2.ZERO', 'Rect': 'Rect2()', 'Color': 'Color.WHITE'})
    if ty in d:
        return d[ty]
    if ty.endswith('[]'):
        return '[]'
    if ty in ('Selectable', 'Graphic', 'Image', 'Texture', 'Texture2D', 'Material', 'Sprite', 'RectTransform', 'Transform', 'Canvas', 'Camera', 'Font', 'Mesh', 'Animator', 'ScrollRect', 'Scrollbar', 'Toggle', 'ToggleGroup', 'Component', 'GameObject', 'Object', 'Text', 'TMP_Text', 'TMP_FontAsset', 'RectMask2D', 'Shader', 'Renderer', 'CanvasRenderer'):
        return 'null'
    if ty in ('int', 'float', 'bool', 'string'):
        return d[ty]
    return '0'  # enums and unknown value types


def main():
    by = G.load_externs()
    ext_map, names = G.catalog_extern_map()
    all_types = set(by.keys())
    d = lambda m: demangle(m, ext_map, all_types)
    hw = handwritten()
    out = ['# GENERATED by tools/gen_ui.py from data/known_externs.txt — edit the generator, not this file.',
           '# Unity UI (uGUI, TextMeshPro) members: engine-mapped through U.ui_* where Godot has the notion,',
           '# `pass` for Unity layout/event-system internals, `!stored` round trips for the rest.', '']
    n_engine = n_stored = n_pass = 0
    for tname, (base, kind, gd, mangled) in TYPES.items():
        members = by.get(mangled, [])
        if tname in hw:
            out.append(f'type {tname}')
        elif kind == 'static':
            out.append(f'type {tname} kind=static extern={mangled}')
        else:
            out.append(f'type {tname} : {base} kind={kind} gd={gd} extern={mangled}')
        seen = set()
        lines = []
        for rest in sorted(members):
            name, args, ret = G.parse_member(rest)
            if name in ('Equals', 'GetHashCode', 'GetType', 'ToString', 'Finalize', 'MemberwiseClone', 'GetInstanceID') or name.startswith('op_') or name == 'ctor':
                continue
            targs = [d(a) for a in args]
            tret = d(ret)
            if any('List' in a and a in ('object',) for a in targs):
                pass
            is_get = name.startswith('get_') and not args
            is_set = name.startswith('set_') and len(args) == 1
            if is_get or is_set:
                prop = name[4:]
                key = ('set ' if is_set else '') + prop
                if key in seen or ((tname, key) not in SPEC and chain_has(hw, tname, key)):
                    continue
                seen.add(key)
                GENERATED.setdefault(tname, set()).add(key)
                ty = targs[0] if is_set else tret
                spec = SPEC.get((tname, key))
                if spec is not None:
                    t = spec
                    if kind == 'static':
                        lines.append(f'  static {"set " if is_set else ""}{prop}: {ty} => {t}')
                    else:
                        lines.append(f'  {"set " if is_set else ""}{prop}: {ty} => {t}')
                    n_engine += 1
                    continue
                if is_set:
                    lines.append(f'  set {prop}: {ty} => !stored U.prop_set($0, "{prop}", $v)')
                else:
                    lines.append(f'  {prop}: {ty} => !stored U.prop_get($0, "{prop}", {default_for(ty)})')
                n_stored += 1
                continue
            key = f'{name}/{len(args)}'
            if key in seen or ((tname, key) not in SPEC and chain_has(hw, tname, name)):
                continue
            seen.add(key)
            GENERATED.setdefault(tname, set()).add(name)
            sig = f'{name}({", ".join(targs)}): {tret}'
            prefix = 'static ' if kind == 'static' or (tname, name) in STATIC else ''
            spec = SPEC.get((tname, key))
            if spec is None and kind == 'component':
                spec = GENERIC.get(key)
            if spec is not None:
                lines.append(f'  {prefix}{sig} => {spec}')
                n_engine += 1
            elif name in PASS:
                lines.append(f'  {prefix}{sig} => {"pass" if tret == "void" else default_for(tret)}')
                n_pass += 1
            elif tret == 'void':
                lines.append(f'  {prefix}{sig} => !stub pass')
            else:
                lines.append(f'  {prefix}{sig} => !stub {default_for(tret)}')
        out.extend(lines)
        out.append('')
    # dictionary structs
    for sname, (mangled, ctor, defaults) in STRUCTS.items():
        members = by.get(mangled, [])
        out.append(f'type {sname} kind=struct gd=Dictionary extern={mangled}')
        if ctor is not None:
            out.append(f'  ctor() => {ctor}')
        if sname.endswith('OptionData'):
            out.append('  ctor(string) => {"text": $1, "image": null}')
            out.append('  ctor(Sprite) => {"text": "", "image": $1}')
            out.append('  ctor(string, Sprite) => {"text": $1, "image": $2}')
        if sname == 'ColorBlock':
            out.append('  static defaultColorBlock: ColorBlock => U.ui_default_colors()')
        if sname == 'Navigation':
            out.append('  static defaultNavigation: Navigation => {"mode": 3, "selectOnUp": null, "selectOnDown": null, "selectOnLeft": null, "selectOnRight": null, "wrapAround": false}')
        if sname == 'FontData':
            out.append('  static defaultFontData: FontData => {"fontSize": 14, "lineSpacing": 1.0, "richText": true}')
        seen = set()
        for rest in sorted(members):
            name, args, ret = G.parse_member(rest)
            if name in ('Equals', 'GetHashCode', 'GetType', 'ToString') or name.startswith('op_') or name.startswith('ctor'):
                continue
            targs = [d(a) for a in args]
            tret = d(ret)
            if name.startswith('get_') and not args:
                prop = name[4:]
                if prop in ('defaultColorBlock', 'defaultNavigation', 'defaultFontData') or ('get', prop) in seen:
                    continue
                seen.add(('get', prop))
                out.append(f'  {prop}: {tret} => $0.get("{prop}", {defaults.get(prop, default_for(tret))})')
            elif name.startswith('set_') and len(args) == 1:
                prop = name[4:]
                if ('set', prop) in seen:
                    continue
                seen.add(('set', prop))
                out.append(f'  set {prop}: {targs[0]} => $0.{prop} = $v')
            else:
                key = (name, len(args))
                if key in seen:
                    continue
                seen.add(key)
                sig = f'{name}({", ".join(targs)}): {tret}'
                if name in ('Clear', 'ClearAllMeshInfo', 'ClearLineInfo', 'ClearMeshInfo', 'ClearUnusedVertices', 'ResetVertexLayout', 'ResizeMeshInfo', 'SortGeometry', 'SwapVertexData', 'Dispose', 'FillMesh'):
                    out.append(f'  {sig} => pass')
                elif tret == 'void':
                    out.append(f'  {sig} => !stub pass')
                else:
                    out.append(f'  {sig} => !stub {default_for(tret)}')
        out.append('')
    for ename, mangled in EVENTS.items():
        out.append(f'type {ename} kind=class gd=Signal extern={mangled}')
        out.append('  Invoke(): void => $0.emit()')
        arg = {'ButtonButtonClickedEvent': None, 'SliderSliderEvent': 'float', 'ToggleToggleEvent': 'bool', 'ScrollRectScrollRectEvent': 'Vector2', 'ScrollbarScrollEvent': 'float', 'Dropdown.DropdownEvent': 'int'}[ename]
        if arg:
            out.append(f'  Invoke({arg}): void => $0.emit($1)')
        out.append('  AddListener(object): void => !unsupported UnityEvent listeners need delegates')
        out.append('  RemoveListener(object): void => pass')
        out.append('  RemoveAllListeners(): void => pass')
        out.append('  GetPersistentEventCount(): int => $0.get_connections().size()')
        out.append('')
    for ename, (mangled, vals) in ENUMS.items():
        if ename in hw:
            continue
        out.append(f'type {ename} kind=enum extern={mangled}')
        values = ENUM_VALUES.get(ename, list(range(len(vals))))
        for v, i in zip(vals, values):
            out.append(f'  enum {v} = {i}')
        out.append('')
    open(OUT, 'w').write('\n'.join(out) + '\n')
    print(f'wrote {OUT}: {n_engine} explicit, {n_pass} no-op, {n_stored} stored')


if __name__ == '__main__':
    main()
