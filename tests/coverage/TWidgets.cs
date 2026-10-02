using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using TMPro;

namespace Coverage
{
    /// What a script changes on texts, graphics and selectables is drawn by the code that draws
    /// the imported scene (unidot's ui_text.gd, ui_graphic.gd, selectable.gd). The runner builds
    /// a canvas the way the importer does: `label` (TextMeshProUGUI "<b>Start</b>", size 20),
    /// `fitted` (auto-sized between 8 and 60 in 200 x 30), `image` with a child `kid`, `bar` (a
    /// horizontally filled Image of 128 x 32), `button`
    /// (its own Image as target graphic, normal colour with alpha 0), `toggle` (off, check mark
    /// `check`), `slider` (0..1 at 0.5, left to right, `fill` and `handle`), `dropdown` (options
    /// A, B, C; caption `caption`; a template of 150 with one item of 20 in a content of 28) and
    /// `text3d`, a TextMeshPro outside the canvas.
    public class TWidgets : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public TextMeshProUGUI label;
        public TextMeshProUGUI fitted;
        public Image image;
        public RectTransform kid;
        public Button button;
        public Image buttonImage;
        public Toggle toggle;
        public Image check;
        public Slider slider;
        public RectTransform fill;
        public RectTransform handle;
        public TextMeshPro text3d;
        public Image bar;
        public Dropdown dropdown;
        public TMP_Dropdown tmpDropdown;   // the same object (for IsExpanded, which only TMP has)
        public Text caption;
        public Sprite spare;               // a sprite that nothing shows
        public ScrollRect scroll;          // 200 x 200, clamped, content 500 high, a vertical bar
        public RectTransform scrollContent;
        public Scrollbar scrollBar;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }
        private bool Near2(Vector2 a, float x, float y) { return Near(a.x, x) && Near(a.y, y); }

        public void RunTests()
        {
            // text: the string a script sets is the string it reads, whatever is drawn
            Check(label.text == "<b>Start</b>", "text as imported: " + label.text);
            label.text = "<size=13>LocalPlayer</size> <color=#FFD700>won";
            Check(label.text == "<size=13>LocalPlayer</size> <color=#FFD700>won", "text reads back as set: " + label.text);
            Check(Near(label.fontSize, 20f), "fontSize as imported: " + label.fontSize);
            label.fontSize = 24.5f;
            Check(Near(label.fontSize, 24.5f), "fontSize keeps its fraction: " + label.fontSize);
            Check(label.fontStyle == FontStyles.Normal, "fontStyle as imported");
            label.fontStyle = FontStyles.Bold | FontStyles.UpperCase;
            Check((label.fontStyle & FontStyles.UpperCase) != 0, "fontStyle setter");
            Check(label.richText && label.enableWordWrapping && !label.enableAutoSizing, "text settings as imported");
            label.color = new Color(1f, 0f, 0f, 1f);
            Check(Near(label.color.r, 1f) && Near(label.color.g, 0f), "text colour: " + label.color);
            label.alpha = 0.5f;
            Check(Near(label.color.a, 0.5f) && Near(label.alpha, 0.5f), "TMP alpha is the alpha of the colour: " + label.color);
            label.enabled = false;
            Check(!label.enabled && label.gameObject.activeSelf, "a disabled text leaves its object active");
            label.enabled = true;
            Check(label.enabled, "text enabled again");
            Check(fitted.enableAutoSizing && Near(fitted.fontSizeMin, 8f) && Near(fitted.fontSizeMax, 60f), "auto-size settings as imported");
            // the outline of the text's material, pages, the first visible character
            Check(Near(label.outlineWidth, 0f), "no outline as imported: " + label.outlineWidth);
            label.outlineWidth = 0.2f;
            label.outlineColor = new Color32(255, 0, 0, 255);
            Check(Near(label.outlineWidth, 0.2f) && label.outlineColor.r == 255 && label.outlineColor.g == 0, "outlineWidth / outlineColor read back: " + label.outlineWidth);
            label.outlineWidth = 0f;
            label.overflowMode = TextOverflowModes.Page;
            label.pageToDisplay = 2;
            Check(label.pageToDisplay == 2 && label.overflowMode == TextOverflowModes.Page, "pageToDisplay reads back");
            label.overflowMode = TextOverflowModes.Overflow;
            label.firstVisibleCharacter = 3;
            Check(label.firstVisibleCharacter == 3, "firstVisibleCharacter reads back");
            label.firstVisibleCharacter = 0;
            // margins and line spacing: where the text is laid out
            Check(label.margin == Vector4.zero && Near(label.lineSpacing, 0f), "no margins, no line spacing as imported: " + label.margin);
            label.margin = new Vector4(4f, 2f, 10f, 0f);
            label.lineSpacing = 12.5f;
            Check(Near(label.margin.x, 4f) && Near(label.margin.z, 10f) && Near(label.lineSpacing, 12.5f), "margin / lineSpacing read back: " + label.margin + " " + label.lineSpacing);
            label.margin = Vector4.zero;
            label.lineSpacing = 0f;
            label.maxVisibleCharacters = 3;
            label.maxVisibleLines = 1;
            Check(label.maxVisibleCharacters == 3 && label.maxVisibleLines == 1, "maxVisibleCharacters / maxVisibleLines read back: " + label.maxVisibleCharacters);
            label.maxVisibleCharacters = 99999;
            label.maxVisibleLines = 99999;
            Check(label.maxVisibleCharacters == 99999, "... and all of them again: " + label.maxVisibleCharacters);

            // graphics: enabled is not the object's activity
            Check(Near(image.color.g, 0.5f), "image colour as imported: " + image.color);
            image.color = new Color(0.5f, 1f, 1f, 1f);
            Check(Near(image.color.r, 0.5f) && Near(image.color.g, 1f), "image colour setter: " + image.color);
            image.enabled = false;
            Check(!image.enabled && image.gameObject.activeSelf && kid.gameObject.activeInHierarchy, "a disabled Image leaves its object and children active");
            image.canvasRenderer.SetAlpha(0.25f);
            Check(Near(image.canvasRenderer.GetAlpha(), 0.25f) && Near(image.color.a, 1f), "CanvasRenderer alpha is apart from the colour");
            image.CrossFadeAlpha(0.5f, 0f, true);
            Check(Near(image.canvasRenderer.GetAlpha(), 0.5f), "CrossFadeAlpha without a duration is a set: " + image.canvasRenderer.GetAlpha());
            image.CrossFadeColor(new Color(1f, 0f, 0f, 1f), 0f, true, false);
            Check(Near(image.canvasRenderer.GetColor().g, 0f) && Near(image.canvasRenderer.GetAlpha(), 0.5f), "CrossFadeColor without alpha leaves the alpha: " + image.canvasRenderer.GetColor());
            image.CrossFadeColor(Color.white, 0f, true, true);
            // an override sprite is drawn in place of the sprite, which stays what it is
            Sprite before = image.sprite;
            image.overrideSprite = spare;
            Check(image.overrideSprite == spare && image.sprite == before && before != spare, "overrideSprite is drawn, sprite stays");
            image.overrideSprite = null;
            Check(image.overrideSprite == image.sprite && image.sprite == before, "without an override: the sprite itself");
            image.sprite = spare;
            Check(image.sprite == spare && image.overrideSprite == spare, "sprite setter");
            image.sprite = before;

            // a filled Image (the runner made `bar` one, at 1): the amount is drawn, the rect stays
            Check(bar.type == Image.Type.Filled && Near(bar.fillAmount, 1f), "filled Image as imported: " + bar.fillAmount);
            bar.fillAmount = 0.25f;
            Check(Near(bar.fillAmount, 0.25f) && Near(bar.rectTransform.rect.width, 128f), "fillAmount changes what is drawn, not the rect: " + bar.rectTransform.rect.width);
            bar.fillOrigin = 1;
            Check(bar.fillOrigin == 1 && bar.fillMethod == Image.FillMethod.Horizontal, "fill origin and method");

            // selectables
            ColorBlock block = button.colors;
            Check(Near(block.normalColor.a, 0f) && Near(block.highlightedColor.a, 1f), "ColorBlock as imported: " + block.normalColor);
            Check(Near(buttonImage.canvasRenderer.GetAlpha(), 0f), "normal colour with alpha 0 hides the target graphic");
            Check(button.targetGraphic == buttonImage, "targetGraphic");
            block.normalColor = new Color(1f, 0f, 0f, 1f);
            block.disabledColor = new Color(0f, 0f, 1f, 0.5f);
            block.fadeDuration = 0f;   // (the tint fades over this time: none, to see it at once)
            button.colors = block;
            Check(Near(buttonImage.canvasRenderer.GetColor().r, 1f) && Near(buttonImage.canvasRenderer.GetColor().g, 0f), "a new ColorBlock tints the target: " + buttonImage.canvasRenderer.GetColor());
            button.interactable = false;
            Check(!button.interactable && Near(buttonImage.canvasRenderer.GetColor().b, 1f) && Near(buttonImage.canvasRenderer.GetAlpha(), 0.5f), "not interactable: the disabled colour: " + buttonImage.canvasRenderer.GetColor());

            Check(!toggle.isOn && toggle.graphic == check, "toggle as imported");
            toggle.toggleTransition = Toggle.ToggleTransition.None;
            Check(toggle.toggleTransition == Toggle.ToggleTransition.None, "toggleTransition reads back");
            SpriteState swap = button.spriteState;
            swap.pressedSprite = spare;
            button.spriteState = swap;
            Check(button.spriteState.pressedSprite == spare && button.spriteState.highlightedSprite == null, "spriteState reads back");
            Check(Near(check.canvasRenderer.GetAlpha(), 0f), "the check mark of a toggle that is off");
            toggle.isOn = true;
            Check(toggle.isOn && Near(check.canvasRenderer.GetAlpha(), 1f), "isOn shows the check mark");
            toggle.SetIsOnWithoutNotify(false);
            Check(!toggle.isOn && Near(check.canvasRenderer.GetAlpha(), 0f), "SetIsOnWithoutNotify hides it again");
            toggle.isOn = true;

            Check(slider.fillRect == fill && slider.handleRect == handle, "fillRect / handleRect");
            Check(Near2(fill.anchorMax, 0.5f, 1f) && Near2(handle.anchorMin, 0.5f, 0f), "slider visuals as imported: " + fill.anchorMax);
            slider.value = 0.25f;
            Check(Near2(fill.anchorMin, 0f, 0f) && Near2(fill.anchorMax, 0.25f, 1f), "the fill follows the value: " + fill.anchorMax);
            Check(Near2(handle.anchorMin, 0.25f, 0f) && Near2(handle.anchorMax, 0.25f, 1f), "the handle follows the value: " + handle.anchorMin);
            slider.SetValueWithoutNotify(0.75f);
            Check(Near2(fill.anchorMax, 0.75f, 1f), "SetValueWithoutNotify moves the fill too: " + fill.anchorMax);
            slider.minValue = -1f;
            Check(Near2(fill.anchorMax, 0.875f, 1f), "the range changes the normalized value: " + fill.anchorMax);
            slider.direction = Slider.Direction.RightToLeft;
            Check(Near2(fill.anchorMin, 0.125f, 0f) && Near2(fill.anchorMax, 1f, 1f), "right to left: " + fill.anchorMin);
            Check(Near2(handle.anchorMin, 0.125f, 0f), "right to left handle: " + handle.anchorMin);

            // Dropdown: Unity's caption and list objects
            Check(dropdown.captionText == caption && caption.text == "A", "the caption shows the value as imported: " + caption.text);
            dropdown.value = 2;
            Check(caption.text == "C", "value moves the caption: " + caption.text);
            Check(Near(caption.lineSpacing, 1f), "uGUI line spacing as imported: " + caption.lineSpacing);
            caption.lineSpacing = 1.5f;
            Check(Near(caption.lineSpacing, 1.5f), "... reads back: " + caption.lineSpacing);
            caption.lineSpacing = 1f;
            dropdown.SetValueWithoutNotify(1);
            Check(caption.text == "B", "SetValueWithoutNotify too: " + caption.text);
            RectTransform template = dropdown.template;
            Check(template != null && !template.gameObject.activeSelf && dropdown.itemText != null, "template / itemText");
            Check(!tmpDropdown.IsExpanded, "IsExpanded before Show");
            dropdown.Show();
            Check(tmpDropdown.IsExpanded, "Show opens the list");
            RectTransform shown = (RectTransform)dropdown.transform.parent.Find("Dropdown List");
            Check(shown != null && shown.gameObject.activeInHierarchy, "the list is a copy of the template, on top of the canvas");
            if (shown != null)
            {
                Check(Near(shown.rect.height, 68f) && Near(shown.rect.width, 120f), "the list is as high as its three items: " + shown.rect.size);
                Transform items = shown.Find("Content");
                Transform second = items.childCount == 4 ? items.GetChild(2) : null;   // (after the template's item)
                Check(second != null && second.GetComponent<Toggle>().isOn && !items.GetChild(1).GetComponent<Toggle>().isOn, "one item per option, the current one on");
                Check(second != null && Near(((RectTransform)second).anchoredPosition.y, 34f), "items from the top down");
                Check(!template.gameObject.activeSelf, "the template stays inactive");
            }
            dropdown.Hide();
            Check(!tmpDropdown.IsExpanded, "Hide closes it");
            dropdown.ClearOptions();
            Check(caption.text == "" && dropdown.options.Count == 0, "ClearOptions empties the caption: " + caption.text);
            dropdown.AddOptions(new string[] { "x", "y" });
            Check(caption.text == "x" && dropdown.value == 0, "AddOptions shows the first option: " + caption.text);
            dropdown.captionText = null;
            dropdown.value = 1;
            Check(caption.text == "x" && dropdown.captionText == null, "without captionText nothing follows the value");
            dropdown.captionText = caption;
            Check(caption.text == "y", "a new captionText shows the value: " + caption.text);

            // 3D text
            Check(text3d.text == "ready", "3D text as imported: " + text3d.text);
            text3d.text = "<b>Winner</b>";
            Check(text3d.text == "<b>Winner</b>", "3D text reads back as set");
            text3d.color = new Color(0f, 1f, 0f, 1f);
            Check(Near(text3d.color.g, 1f) && Near(text3d.color.r, 0f), "3D text colour");

            // ScrollRect: the settings of its movement, its velocity, a Scrollbar with steps
            Check(scroll.inertia && Near(scroll.decelerationRate, 0.135f) && Near(scroll.elasticity, 0.1f), "ScrollRect movement settings as imported");
            scroll.inertia = false;
            scroll.decelerationRate = 0.5f;
            scroll.elasticity = 0.2f;
            Check(!scroll.inertia && Near(scroll.decelerationRate, 0.5f) && Near(scroll.elasticity, 0.2f), "... and as set");
            scroll.inertia = true;
            scroll.velocity = new Vector2(0f, 120f);
            Check(Near(scroll.velocity.y, 120f), "velocity reads back: " + scroll.velocity);
            scroll.StopMovement();
            Check(Near(scroll.velocity.y, 0f), "StopMovement");
            scroll.verticalNormalizedPosition = 0.5f;
            Check(Near(scrollContent.anchoredPosition.y, 150f), "normalized 0.5: half of the 300 hidden: " + scrollContent.anchoredPosition);
            Check(scrollBar.direction == Scrollbar.Direction.BottomToTop && scrollBar.numberOfSteps == 0, "Scrollbar direction / steps as imported");
            scrollBar.numberOfSteps = 5;
            scrollBar.value = 0.3f;
            Check(scrollBar.numberOfSteps == 5 && Near(scrollBar.value, 0.25f), "a value between steps is the nearest step: " + scrollBar.value);
            Check(Near(scrollContent.anchoredPosition.y, 225f), "... and the content follows the bar: " + scrollContent.anchoredPosition);
            scrollBar.numberOfSteps = 0;
            done = true;
        }
    }
}
