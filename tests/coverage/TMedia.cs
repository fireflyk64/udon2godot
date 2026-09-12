using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Audio, animation, particles, renderers, materials, lights, camera, line renderer, curves.
    public class TMedia : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public AudioSource audio;          // AudioStreamPlayer3D "Audio" with a generated stream
        public AudioClip clip;
        public Animator animator;          // AnimationPlayer "Anim" with animation "spin"
        public ParticleSystem particles;   // GPUParticles3D "Particles"
        public MeshRenderer meshRenderer;  // MeshInstance3D "Mesh" with a StandardMaterial3D
        public Light light;                // OmniLight3D "Light"
        public Camera cam;                 // Camera3D "Cam"
        public LineRenderer line;          // Node3D "Line"
        public AnimationCurve curve;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            // Audio
            Check(audio != null, "audio wired");
            audio.volume = 0.5f;
            Check(Near(audio.volume, 0.5f), "volume linear round trip: " + audio.volume);
            audio.pitch = 1.5f;
            Check(Near(audio.pitch, 1.5f), "pitch");
            audio.loop = true;
            Check(audio.loop, "loop on");
            audio.loop = false;
            audio.clip = clip;
            Check(audio.clip == clip, "clip assignment");
            Check(clip != null && clip.length > 0f, "AudioClip.length: " + (clip != null ? clip.length : -1f));
            audio.Play();
            Check(audio.isPlaying, "isPlaying after Play");
            audio.Pause();
            audio.UnPause();
            audio.Stop();
            Check(!audio.isPlaying, "isPlaying false after Stop");
            audio.PlayOneShot(clip, 0.8f);
            audio.PlayDelayed(0.1f);
            audio.mute = true;
            Check(audio.mute, "mute");
            audio.mute = false;
            audio.maxDistance = 25f;
            Check(Near(audio.maxDistance, 25f), "maxDistance");
            audio.time = 0f;
            Check(audio.time >= 0f, "time");
            audio.enabled = false;
            Check(!audio.enabled, "audio enabled false");
            audio.enabled = true;

            // Animator over an AnimationPlayer
            Check(animator != null, "animator wired");
            animator.SetFloat("Speed", 0.75f);
            animator.SetBool("Open", true);
            animator.SetInteger("Count", 3);
            Check(Near(animator.GetFloat("Speed"), 0.75f) && animator.GetBool("Open") && animator.GetInteger("Count") == 3, "animator parameters");
            animator.SetTrigger("Fire");
            animator.ResetTrigger("Fire");
            animator.Play("spin");
            AnimatorStateInfo info = animator.GetCurrentAnimatorStateInfo(0);
            Check(info.IsName("spin"), "GetCurrentAnimatorStateInfo.IsName");
            Check(info.length > 0f, "state length: " + info.length);
            animator.speed = 2f;
            Check(Near(animator.speed, 2f), "animator.speed");
            animator.speed = 1f;
            Check(Animator.StringToHash("spin") == Animator.StringToHash("spin"), "StringToHash stable");
            animator.enabled = true;
            Check(animator.enabled, "animator enabled");

            // Particles
            Check(particles != null, "particles wired");
            particles.Play();
            Check(particles.isPlaying && particles.isEmitting, "particles playing");
            particles.Stop();
            Check(!particles.isPlaying, "particles stopped");
            ParticleSystem.EmissionModule em = particles.emission;
            em.enabled = true;
            Check(em.enabled, "emission module enabled");
            em.rateOverTime = new ParticleSystem.MinMaxCurve(20f);
            Check(Near(em.rateOverTime.constant, 20f), "rateOverTime MinMaxCurve");
            ParticleSystem.MainModule main = particles.main;
            main.startLifetime = 2f;
            main.loop = false;
            Check(Near(main.startLifetime.constant, 2f) && !main.loop, "main module");
            main.startColor = Color.red;
            Check(Near(main.startColor.color.r, 1f), "startColor MinMaxGradient");
            particles.Emit(5);
            particles.Clear();

            // Renderer / Material
            Check(meshRenderer != null && meshRenderer.enabled, "renderer wired");
            meshRenderer.enabled = false;
            Check(!meshRenderer.enabled, "renderer disabled");
            meshRenderer.enabled = true;
            Material mat = meshRenderer.material;
            Check(mat != null, "renderer.material");
            mat.color = Color.green;
            Check(Near(mat.color.g, 1f) && Near(mat.color.r, 0f), "material.color");
            mat.SetColor("_Color", Color.blue);
            Check(Near(mat.GetColor("_Color").b, 1f), "SetColor/GetColor _Color");
            mat.SetFloat("_Glossiness", 0.25f);
            Check(Near(mat.GetFloat("_Glossiness"), 0.25f), "SetFloat/GetFloat mapped property");
            mat.SetFloat("_Custom", 3f);
            Check(Near(mat.GetFloat("_Custom"), 3f) && mat.HasProperty("_Custom"), "custom float property stored");
            mat.SetVector("_Vec", new Vector4(1, 2, 3, 4));
            Check(Near(mat.GetVector("_Vec").z, 3f), "SetVector/GetVector");
            Check(meshRenderer.sharedMaterial != null, "sharedMaterial");
            Check(meshRenderer.bounds.size.x > 0f, "renderer.bounds");
            MaterialPropertyBlock block = new MaterialPropertyBlock();
            block.SetColor("_Color", Color.yellow);
            block.SetFloat("_Alpha", 0.5f);
            meshRenderer.SetPropertyBlock(block);
            Check(Near(block.GetFloat("_Alpha"), 0.5f), "MaterialPropertyBlock get");
            mat.SetColor("_Color", Color.blue); // the property block above overrode the renderer's colour
            Material copy = new Material(mat);
            copy.color = Color.white;
            Check(Near(mat.color.b, 1f) && Near(copy.color.r, 1f), "new Material(Material) copies");

            // Light
            light.intensity = 2f;
            light.color = Color.cyan;
            light.range = 12f;
            Check(Near(light.intensity, 2f) && Near(light.color.g, 1f) && Near(light.range, 12f), "light props");
            light.enabled = false;
            Check(!light.enabled, "light disabled");
            light.enabled = true;

            // Camera
            Check(cam != null && Camera.main != null, "camera wired / Camera.main");
            cam.fieldOfView = 70f;
            Check(Near(cam.fieldOfView, 70f), "fieldOfView");
            cam.nearClipPlane = 0.1f;
            cam.farClipPlane = 500f;
            Check(Near(cam.nearClipPlane, 0.1f) && Near(cam.farClipPlane, 500f), "clip planes");
            Vector3 sp = cam.WorldToScreenPoint(cam.transform.position + cam.transform.forward * 10f);
            Check(sp.z > 9f && sp.z < 11f, "WorldToScreenPoint depth: " + sp.z);
            Ray r = cam.ScreenPointToRay(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
            Check(Vector3.Dot(r.direction, cam.transform.forward) > 0.9f, "ScreenPointToRay center points forward");
            Check(Screen.width > 0 && Screen.height > 0, "Screen size");

            // LineRenderer
            line.positionCount = 3;
            line.SetPosition(0, Vector3.zero);
            line.SetPosition(1, Vector3.up);
            line.SetPosition(2, Vector3.right);
            Check(line.positionCount == 3 && line.GetPosition(1) == Vector3.up, "LineRenderer positions");
            line.startWidth = 0.2f;
            line.startColor = Color.red;
            Check(Near(line.startWidth, 0.2f) && Near(line.startColor.r, 1f), "LineRenderer props");
            line.enabled = false;
            line.enabled = true;

            // AnimationCurve
            curve = AnimationCurve.Linear(0f, 0f, 1f, 10f);
            Check(Near(curve.Evaluate(0.5f), 5f), "AnimationCurve.Linear.Evaluate: " + curve.Evaluate(0.5f));
            AnimationCurve c2 = new AnimationCurve(new Keyframe(0, 1), new Keyframe(2, 3));
            Check(Near(c2.Evaluate(1f), 2f) && c2.length == 2, "AnimationCurve keys");

            // Rendering extras: property ids, sampler state, cubemaps, 3D textures
            int colorId = Shader.PropertyToID("_Color");
            MaterialPropertyBlock idBlock = new MaterialPropertyBlock();
            idBlock.SetColor(colorId, Color.red);
            Check(idBlock.HasProperty(colorId) && idBlock.HasColor(colorId) && !idBlock.HasFloat("_Nope"), "MaterialPropertyBlock.Has* by id");
            meshRenderer.SetPropertyBlock(idBlock);
            Check(Near(meshRenderer.material.GetColor("_Color").r, 1f) && Near(meshRenderer.material.GetColor("_Color").g, 0f), "PropertyToID resolves to the material colour");
            mat.SetFloat(Shader.PropertyToID("_Metallic"), 0.75f);
            Check(Near(mat.GetFloat("_Metallic"), 0.75f), "Material.SetFloat by id");
            idBlock.SetMatrix("_M", Matrix4x4.identity);
            Check(idBlock.HasMatrix("_M") && idBlock.GetMatrix("_M").isIdentity, "MaterialPropertyBlock matrix");
            Texture2D tex = new Texture2D(8, 4);
            Check(Near(tex.texelSize.x, 0.125f) && Near(tex.texelSize.y, 0.25f) && tex.dimension == TextureDimension.Tex2D, "Texture.texelSize / dimension");
            tex.wrapMode = TextureWrapMode.Clamp;
            tex.filterMode = FilterMode.Point;
            tex.anisoLevel = 4;
            Check(tex.wrapMode == TextureWrapMode.Clamp && tex.wrapModeU == TextureWrapMode.Clamp && tex.filterMode == FilterMode.Point && tex.anisoLevel == 4, "texture sampler state stored");
            tex.IncrementUpdateCount();
            Check(tex.updateCount == 1, "updateCount");
            tex.width = 16;
            Check(tex.width == 16 && tex.height == 4, "Texture2D.width setter resizes");
            Cubemap cube = new Cubemap(4, TextureFormat.RGBA32, false);
            cube.SetPixel(CubemapFace.PositiveX, 1, 2, Color.red);
            Check(cube.width == 4 && Near(cube.GetPixel(CubemapFace.PositiveX, 1, 2).r, 1f) && cube.dimension == TextureDimension.Cube, "Cubemap pixels");
            Color[] face = cube.GetPixels(CubemapFace.NegativeY);
            Check(face.Length == 16, "Cubemap.GetPixels face size");
            Texture3D t3 = new Texture3D(2, 2, 2, TextureFormat.RGBA32, false);
            t3.SetPixel(1, 1, 1, Color.green);
            Check(t3.depth == 2 && Near(t3.GetPixel(1, 1, 1).g, 1f) && Near(t3.GetPixel(0, 0, 0).g, 0f), "Texture3D pixels");
            Color[] vox = t3.GetPixels();
            Check(vox.Length == 8 && Near(vox[7].g, 1f), "Texture3D.GetPixels layout");

            // meshes: attributes, extra uv sets, bounds, combining
            Mesh quad = new Mesh();
            quad.vertices = new Vector3[] { new Vector3(0, 0, 0), new Vector3(1, 0, 0), new Vector3(1, 1, 0), new Vector3(0, 1, 0) };
            quad.triangles = new int[] { 0, 1, 2, 0, 2, 3 };
            Check(quad.vertexCount == 4 && quad.HasVertexAttribute(VertexAttribute.Position) && !quad.HasVertexAttribute(VertexAttribute.TexCoord0), "Mesh vertex attributes");
            Check(quad.GetVertexAttributeDimension(VertexAttribute.Position) == 3, "attribute dimension");
            quad.uv3 = new Vector2[] { Vector2.zero, Vector2.one, Vector2.up, Vector2.right };
            Check(quad.uv3.Length == 4, "uv3 stored");
            quad.bounds = new Bounds(Vector3.zero, new Vector3(4, 4, 4));
            Check(Near(quad.bounds.size.x, 4f), "Mesh.bounds setter");
            CombineInstance ci0 = new CombineInstance();
            ci0.mesh = quad;
            ci0.transform = Matrix4x4.identity;
            CombineInstance ci1 = new CombineInstance();
            ci1.mesh = quad;
            ci1.transform = Matrix4x4.identity;
            Mesh combined = new Mesh();
            combined.CombineMeshes(new CombineInstance[] { ci0, ci1 }, true, true);
            Check(combined.vertexCount == 8 && combined.triangles.Length == 12 && combined.subMeshCount == 1, "CombineMeshes merged: " + combined.vertexCount);
            Mesh combined2 = new Mesh();
            combined2.CombineMeshes(new CombineInstance[] { ci0, ci1 }, false, true);
            Check(combined2.subMeshCount == 2, "CombineMeshes separate sub meshes");
            meshRenderer.forceRenderingOff = true;
            Check(meshRenderer.forceRenderingOff, "forceRenderingOff");
            meshRenderer.forceRenderingOff = false;
            meshRenderer.localBounds = new Bounds(Vector3.zero, new Vector3(3, 3, 3));
            Check(Near(meshRenderer.localBounds.size.x, 3f), "Renderer.localBounds setter");

            // physical camera, frustum utilities
            cam.aperture = 5.6f;
            cam.iso = 400;
            cam.focusDistance = 3f;
            Check(Near(cam.aperture, 5.6f) && cam.iso == 400 && Near(cam.focusDistance, 3f), "physical camera props");
            cam.gateFit = Camera.GateFitMode.Vertical;
            Check(cam.gateFit == Camera.GateFitMode.Vertical, "gateFit stored");
            Plane[] planes = GeometryUtility.CalculateFrustumPlanes(cam);
            Check(planes.Length == 6, "CalculateFrustumPlanes count");
            Bounds inFront = new Bounds(cam.transform.position + cam.transform.forward * 5f, Vector3.one);
            Bounds behind = new Bounds(cam.transform.position - cam.transform.forward * 5f, Vector3.one);
            Check(GeometryUtility.TestPlanesAABB(planes, inFront) && !GeometryUtility.TestPlanesAABB(planes, behind), "TestPlanesAABB in front / behind");
            Bounds cb = GeometryUtility.CalculateBounds(new Vector3[] { new Vector3(-1, 0, 0), new Vector3(1, 2, 0) }, Matrix4x4.identity);
            Check(Near(cb.size.x, 2f) && Near(cb.size.y, 2f), "CalculateBounds");
            Plane poly;
            Check(GeometryUtility.TryCreatePlaneFromPolygon(new Vector3[] { Vector3.zero, Vector3.right, Vector3.up }, out poly) && Mathf.Abs(poly.normal.z) > 0.99f, "TryCreatePlaneFromPolygon");
            FrustumPlanes fp = new FrustumPlanes();
            fp.zNear = 0.5f;
            Check(Near(fp.zNear, 0.5f) && Near(fp.zFar, 1000f), "FrustumPlanes struct");

            // spherical harmonics
            SphericalHarmonicsL2 sh = new SphericalHarmonicsL2();
            sh.AddAmbientLight(new Color(0.5f, 0.25f, 0f));
            Vector3[] dirs = new Vector3[] { Vector3.up, Vector3.forward };
            Color[] cols = new Color[2];
            sh.Evaluate(dirs, cols);
            Check(Near(cols[0].r, 0.5f) && Near(cols[1].g, 0.25f), "SphericalHarmonicsL2 ambient evaluate: " + cols[0]);
            Check(sh[0, 0] > 0f, "SH coefficient indexer");
            sh.AddDirectionalLight(Vector3.up, Color.white, 1f);
            Color[] cols2 = new Color[2];
            sh.Evaluate(dirs, cols2);
            Check(cols2[0].r > cols[0].r, "directional light brightens its direction");

            // VRC rendering: shadows over the scene's DirectionalLight3D, camera settings, texture info
            VRCQualitySettings.SetShadowDistance(60f);
            Check(Near(VRCQualitySettings.ShadowDistance, 60f), "VRCQualitySettings.ShadowDistance");
            VRCQualitySettings.ShadowCascades = 2;
            Check(VRCQualitySettings.ShadowCascades == 2, "ShadowCascades");
            VRCQualitySettings.SetShadowDistance(80f, 0.1f, 0.3f, 0.6f);
            Check(Near(VRCQualitySettings.ShadowCascade4Split.y, 0.3f), "ShadowCascade4Split");
            TextureInfo ti = new TextureInfo();
            ti.AnisoLevel = 8;
            ti.WrapModeU = TextureWrapMode.Mirror;
            Check(ti.AnisoLevel == 8 && ti.WrapModeU == TextureWrapMode.Mirror, "TextureInfo");
            VRCCameraSettings vcs = VRCCameraSettings.ScreenCamera;
            Check(vcs != null && vcs.Forward.magnitude > 0.99f && vcs.GetEyePosition(Camera.StereoscopicEye.Left) == vcs.Position, "VRCCameraSettings eye/forward");

            // Time
            Check(Time.time >= 0f && Time.deltaTime >= 0f && Time.fixedDeltaTime > 0f, "Time statics");
            Check(Time.frameCount >= 0 && Time.realtimeSinceStartup > 0f, "frameCount/realtime");
            Check(Time.timeScale == 1f, "timeScale default");
            done = true;
        }

        /// The sandbox caps scoped variants per call: the gradient checks run in a second call.
        public void AfterFrames()
        {
            // Gradient keys
            Gradient grad = new Gradient();
            GradientColorKey[] ck = new GradientColorKey[] { new GradientColorKey(Color.red, 0f), new GradientColorKey(Color.blue, 1f) };
            GradientAlphaKey[] ak = new GradientAlphaKey[] { new GradientAlphaKey(1f, 0f), new GradientAlphaKey(0f, 1f) };
            grad.SetKeys(ck, ak);
            Color mid = grad.Evaluate(0.5f);
            Check(Near(mid.r, 0.5f) && Near(mid.b, 0.5f) && Near(mid.a, 0.5f), "Gradient.SetKeys / Evaluate: " + mid);
            Check(grad.colorKeys.Length == 2 && Near(grad.colorKeys[1].time, 1f) && Near(grad.alphaKeys[1].alpha, 0f), "Gradient key round trip");
            grad.mode = GradientMode.Fixed;
            Check(grad.mode == GradientMode.Fixed, "Gradient.mode stored");

        }
    }
}
