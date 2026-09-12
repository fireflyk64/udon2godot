using UdonSharp;
using UnityEngine;
using UnityEngine.UI;
using TMPro;

namespace Coverage
{
    /// uGUI / TextMeshPro over Godot Controls: Label "Text", HSlider "Slider", CheckBox "Toggle",
    /// TextureRect "Image", LineEdit "Input", OptionButton "Dropdown", Control "Rect", Label3D "Label3D".
    public class TUI : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Text uiText;
        public TextMeshProUGUI tmpText;
        public Slider slider;
        public Toggle toggle;
        public Image image;
        public InputField input;
        public Dropdown dropdown;
        public RectTransform rect;
        public TextMeshPro label3d;
        public Button button;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            uiText.text = "hello";
            Check(uiText.text == "hello", "Text.text");
            uiText.color = Color.red;
            Check(Near(uiText.color.r, 1f) && Near(uiText.color.g, 0f), "Text.color");
            uiText.fontSize = 24;
            Check(uiText.fontSize == 24, "Text.fontSize");
            uiText.enabled = false;
            Check(!uiText.enabled, "Graphic.enabled");
            uiText.enabled = true;

            tmpText.text = "tmp";
            Check(tmpText.text == "tmp", "TMP text");
            tmpText.SetText("set {0}", 1.5f);
            Check(tmpText.text == "set 1.5", "TMP SetText format: " + tmpText.text);
            tmpText.fontSize = 18f;
            Check(Near(tmpText.fontSize, 18f), "TMP fontSize");
            tmpText.color = Color.blue;
            Check(Near(tmpText.color.b, 1f), "TMP color");
            Check(tmpText.textInfo.characterCount == 7, "TMP textInfo.characterCount: " + tmpText.textInfo.characterCount);

            label3d.text = "3d";
            Check(label3d.text == "3d", "TextMeshPro (3D) text");

            slider.minValue = 0f;
            slider.maxValue = 10f;
            slider.value = 2.5f;
            Check(Near(slider.value, 2.5f) && Near(slider.normalizedValue, 0.25f), "Slider value/normalized");
            slider.normalizedValue = 0.5f;
            Check(Near(slider.value, 5f), "Slider normalizedValue set");
            slider.SetValueWithoutNotify(7f);
            Check(Near(slider.value, 7f), "SetValueWithoutNotify");
            slider.wholeNumbers = true;
            Check(slider.wholeNumbers, "wholeNumbers");
            slider.wholeNumbers = false;
            slider.interactable = false;
            Check(!slider.interactable, "Slider.interactable");
            slider.interactable = true;

            toggle.isOn = true;
            Check(toggle.isOn, "Toggle.isOn");
            toggle.SetIsOnWithoutNotify(false);
            Check(!toggle.isOn, "Toggle.SetIsOnWithoutNotify");
            toggle.interactable = false;
            Check(!toggle.interactable, "Toggle.interactable");
            toggle.interactable = true;

            image.color = new Color(0, 1, 0, 0.5f);
            Check(Near(image.color.g, 1f) && Near(image.color.a, 0.5f), "Image.color");
            image.fillAmount = 0.3f;
            Check(Near(image.fillAmount, 0.3f), "Image.fillAmount");
            image.enabled = false;
            Check(!image.enabled, "Image.enabled");
            image.enabled = true;

            input.text = "typed";
            Check(input.text == "typed", "InputField.text");
            input.characterLimit = 3;
            Check(input.characterLimit == 3, "characterLimit");
            input.characterLimit = 0;
            input.interactable = false;
            Check(!input.interactable, "InputField.interactable");
            input.interactable = true;
            input.readOnly = true;
            Check(input.readOnly, "readOnly");
            input.readOnly = false;

            dropdown.ClearOptions();
            dropdown.AddOptions(new string[] { "a", "b", "c" });
            dropdown.value = 2;
            Check(dropdown.value == 2 && dropdown.options.Count == 3, "Dropdown options/value");
            dropdown.SetValueWithoutNotify(1);
            Check(dropdown.value == 1, "Dropdown.SetValueWithoutNotify");

            rect.anchoredPosition = new Vector2(10, 20);
            rect.sizeDelta = new Vector2(100, 50);
            Check(Near(rect.anchoredPosition.x, 10f) && Near(rect.sizeDelta.y, 50f), "RectTransform position/size");
            Check(Near(rect.rect.width, 100f), "RectTransform.rect");
            rect.localScale = new Vector3(2, 2, 1);
            Check(Near(rect.localScale.x, 2f), "RectTransform.localScale");

            button.interactable = false;
            Check(!button.interactable, "Button.interactable");
            button.interactable = true;
            Check(uiText.gameObject.activeSelf, "UI gameObject active");
            uiText.gameObject.SetActive(false);
            Check(!uiText.gameObject.activeSelf, "UI SetActive(false)");
            uiText.gameObject.SetActive(true);

            // Selectable state, navigation, colours
            Check(button.IsInteractable() && button.IsActive(), "Selectable.IsInteractable/IsActive");
            Navigation nav = button.navigation;
            nav.mode = Navigation.Mode.Explicit;
            nav.selectOnDown = slider;
            button.navigation = nav;
            Check(button.FindSelectableOnDown() == slider, "navigation.selectOnDown -> FindSelectableOnDown");
            Check(button.navigation.selectOnDown == slider && button.navigation.mode == Navigation.Mode.Explicit, "navigation round trip");
            ColorBlock cb = button.colors;
            cb.normalColor = Color.red;
            button.colors = cb;
            Check(button.colors.normalColor == Color.red && Near(button.colors.colorMultiplier, 1f), "ColorBlock round trip");
            Check(ColorBlock.defaultColorBlock.normalColor == Color.white, "ColorBlock.defaultColorBlock");
            button.transition = Selectable.Transition.SpriteSwap;
            Check(button.transition == Selectable.Transition.SpriteSwap, "stored transition");

            // Graphic / Image
            Check(image.canvas != null, "Graphic.canvas");
            Check(!image.Raycast(new Vector2(-100, -100), null), "Graphic.Raycast outside");
            image.SetNativeSize();
            Check(image.depth >= 0, "Graphic.depth");

            // TMP alignment / overflow / wrapping / alpha
            tmpText.alignment = TextAlignmentOptions.Center;
            Check(tmpText.alignment == TextAlignmentOptions.Center && tmpText.horizontalAlignment == HorizontalAlignmentOptions.Center && tmpText.verticalAlignment == VerticalAlignmentOptions.Middle, "TMP alignment " + (int)tmpText.alignment);
            tmpText.horizontalAlignment = HorizontalAlignmentOptions.Right;
            Check(tmpText.horizontalAlignment == HorizontalAlignmentOptions.Right, "TMP horizontalAlignment");
            tmpText.overflowMode = TextOverflowModes.Ellipsis;
            Check(tmpText.overflowMode == TextOverflowModes.Ellipsis, "TMP overflowMode");
            tmpText.maxVisibleLines = 2;
            Check(tmpText.maxVisibleLines == 2, "TMP maxVisibleLines");
            tmpText.enableWordWrapping = false;
            Check(!tmpText.enableWordWrapping, "TMP enableWordWrapping");
            tmpText.alpha = 0.5f;
            Check(Near(tmpText.alpha, 0.5f), "TMP alpha");
            tmpText.alpha = 1f;
            tmpText.isRightToLeftText = true;
            Check(tmpText.isRightToLeftText, "TMP RTL");
            tmpText.isRightToLeftText = false;
            tmpText.wordSpacing = 3f;
            Check(Near(tmpText.wordSpacing, 3f), "TMP stored wordSpacing");
            Check((int)TextAlignmentOptions.BottomRight == 1028 && (int)TextAnchor.LowerRight == 8, "UI enum values");

            // Outline effect on the text control
            Outline ol = tmpText.GetComponent<Outline>();
            Check(ol != null, "Outline component on the text Control");
            ol.effectColor = Color.blue;
            ol.effectDistance = new Vector2(2, -2);
            Check(ol.effectColor == Color.blue && Near(ol.effectDistance.x, 2f), "Outline effect round trip");

            // Mask / layout
            Mask mask = rect.GetComponent<Mask>();
            mask.enabled = true;
            Check(mask.enabled && mask.MaskEnabled(), "Mask.enabled clips");
            LayoutElement le = rect.GetComponent<LayoutElement>();
            le.flexibleWidth = 2f;
            Check(Near(le.flexibleWidth, 2f), "LayoutElement.flexibleWidth");
            le.preferredWidth = 120f;
            Check(Near(LayoutUtility.GetPreferredWidth(rect), 120f), "LayoutUtility.GetPreferredWidth");

            // option data, sprites, text anchors, canvas
            Dropdown.OptionData od = new Dropdown.OptionData("d");
            Check(od.text == "d" && od.image == null, "Dropdown.OptionData ctor");
            Texture2D tex = new Texture2D(4, 4);
            Sprite sp = Sprite.Create(tex, new Rect(0, 0, 2, 2), new Vector2(0.5f, 0.5f));
            Check(sp != null && Near(sp.rect.width, 2f) && Near(sp.pixelsPerUnit, 100f), "Sprite.Create rect/ppu");
            Vector2 pv = Text.GetTextAnchorPivot(TextAnchor.LowerRight);
            Check(Near(pv.x, 1f) && Near(pv.y, 0f), "Text.GetTextAnchorPivot");
            Canvas cv = uiText.canvas;
            Check(cv != null && cv.pixelRect.width > 0f && cv.isRootCanvas, "Canvas.pixelRect/isRootCanvas");
            done = true;
        }
    }
}
