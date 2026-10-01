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
    /// `check`), `slider` (0..1 at 0.5, left to right, `fill` and `handle`) and `text3d`, a
    /// TextMeshPro outside the canvas.
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

            // graphics: enabled is not the object's activity
            Check(Near(image.color.g, 0.5f), "image colour as imported: " + image.color);
            image.color = new Color(0.5f, 1f, 1f, 1f);
            Check(Near(image.color.r, 0.5f) && Near(image.color.g, 1f), "image colour setter: " + image.color);
            image.enabled = false;
            Check(!image.enabled && image.gameObject.activeSelf && kid.gameObject.activeInHierarchy, "a disabled Image leaves its object and children active");
            image.canvasRenderer.SetAlpha(0.25f);
            Check(Near(image.canvasRenderer.GetAlpha(), 0.25f) && Near(image.color.a, 1f), "CanvasRenderer alpha is apart from the colour");

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
            button.colors = block;
            Check(Near(buttonImage.canvasRenderer.GetColor().r, 1f) && Near(buttonImage.canvasRenderer.GetColor().g, 0f), "a new ColorBlock tints the target: " + buttonImage.canvasRenderer.GetColor());
            button.interactable = false;
            Check(!button.interactable && Near(buttonImage.canvasRenderer.GetColor().b, 1f) && Near(buttonImage.canvasRenderer.GetAlpha(), 0.5f), "not interactable: the disabled colour: " + buttonImage.canvasRenderer.GetColor());

            Check(!toggle.isOn && toggle.graphic == check, "toggle as imported");
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

            // 3D text
            Check(text3d.text == "ready", "3D text as imported: " + text3d.text);
            text3d.text = "<b>Winner</b>";
            Check(text3d.text == "<b>Winner</b>", "3D text reads back as set");
            text3d.color = new Color(0f, 1f, 0f, 1f);
            Check(Near(text3d.color.g, 1f) && Near(text3d.color.r, 0f), "3D text colour");
            done = true;
        }
    }
}
