using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// ParticleSystem: modules (engine-mapped and stored), MinMaxCurve/MinMaxGradient, playback
    /// state, Emit/EmitParams, ParticleSystemRenderer. coverage_runner.gd verifies the GPUParticles3D
    /// side (amount, lifetime, scale, colour, shape, ramps, noise, trails, sheet animation, collision).
    public class TParticles : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;
        public ParticleSystem ps;   // GPUParticles3D "Emitter"
        public float playTime;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            Check(ps != null, "particle system wired");
            Check(GetComponentInChildren<ParticleSystem>() == ps, "GetComponentInChildren<ParticleSystem>");

            ParticleSystem.MainModule main = ps.main;
            main.startLifetime = 2.5f;
            Check(Near(main.startLifetime.constant, 2.5f), "startLifetime round trip " + main.startLifetime.constant);
            main.startSize = new ParticleSystem.MinMaxCurve(0.5f, 1.5f);
            Check(Near(main.startSize.constantMin, 0.5f) && Near(main.startSize.constantMax, 1.5f) && main.startSize.mode == ParticleSystemCurveMode.TwoConstants, "startSize two constants");
            main.startSpeed = 3f;
            main.startColor = Color.red;
            Check(main.startColor.color == Color.red, "startColor");
            main.maxParticles = 50;
            Check(main.maxParticles == 50, "maxParticles");
            main.loop = false;
            Check(!main.loop, "loop");
            main.simulationSpace = ParticleSystemSimulationSpace.World;
            Check(main.simulationSpace == ParticleSystemSimulationSpace.World, "simulationSpace");
            main.gravityModifier = 0.5f;
            Check(Near(main.gravityModifier.constant, 0.5f), "gravityModifier");
            main.stopAction = ParticleSystemStopAction.Disable;
            Check(main.stopAction == ParticleSystemStopAction.Disable, "stored property round trip (stopAction)");
            Check(Near(main.duration, 5f), "duration default " + main.duration);

            ParticleSystem.EmissionModule em = ps.emission;
            em.rateOverTime = 20f;
            Check(Near(em.rateOverTime.constant, 20f), "rateOverTime");
            ParticleSystem.Burst[] bursts = new ParticleSystem.Burst[1];
            bursts[0] = new ParticleSystem.Burst(0f, 8);
            em.SetBursts(bursts);
            Check(em.burstCount == 1 && em.GetBurst(0).minCount == 8, "bursts " + em.burstCount);

            ParticleSystem.ShapeModule shape = ps.shape;
            shape.shapeType = ParticleSystemShapeType.Sphere;
            shape.radius = 0.5f;
            Check(shape.shapeType == ParticleSystemShapeType.Sphere && Near(shape.radius, 0.5f), "shape");
            Check((int)ParticleSystemShapeType.Box == 5 && (int)ParticleSystemShapeType.Cone == 4, "shape enum values");

            ParticleSystem.ColorOverLifetimeModule col = ps.colorOverLifetime;
            Gradient g = new Gradient();
            col.color = new ParticleSystem.MinMaxGradient(g);
            col.enabled = true;
            Check(col.color.mode == ParticleSystemGradientMode.Gradient && col.color.gradient != null, "colorOverLifetime gradient");

            ParticleSystem.SizeOverLifetimeModule sol = ps.sizeOverLifetime;
            AnimationCurve curve = AnimationCurve.Linear(0f, 1f, 1f, 0f);
            sol.size = new ParticleSystem.MinMaxCurve(2f, curve);
            sol.enabled = true;
            Check(sol.size.mode == ParticleSystemCurveMode.Curve && Near(sol.size.curveMultiplier, 2f), "sizeOverLifetime curve");
            Check(Near(sol.size.Evaluate(0f), 2f) && Near(sol.size.Evaluate(1f), 0f), "MinMaxCurve.Evaluate on a curve " + sol.size.Evaluate(0f) + " " + sol.size.Evaluate(1f));

            ParticleSystem.NoiseModule noise = ps.noise;
            noise.enabled = true;
            noise.strength = 0.3f;
            Check(noise.enabled && Near(noise.strength.constant, 0.3f), "noise");

            ParticleSystem.TrailModule trails = ps.trails;
            trails.enabled = true;
            trails.lifetime = 0.4f;
            Check(trails.enabled && Near(trails.lifetime.constant, 0.4f), "trails");

            ParticleSystem.TextureSheetAnimationModule tsa = ps.textureSheetAnimation;
            tsa.enabled = true;
            tsa.numTilesX = 4;
            tsa.numTilesY = 2;
            Check(tsa.numTilesX == 4 && tsa.numTilesY == 2, "texture sheet tiles");

            ParticleSystem.RotationOverLifetimeModule rol = ps.rotationOverLifetime;
            rol.enabled = true;
            rol.z = Mathf.PI;
            Check(Near(rol.z.constant, Mathf.PI), "rotationOverLifetime");

            ParticleSystem.CollisionModule coll = ps.collision;
            coll.enabled = true;
            coll.bounce = 0.7f;
            Check(coll.enabled && Near(coll.bounce.constant, 0.7f), "collision");

            ParticleSystem.MinMaxCurve two = new ParticleSystem.MinMaxCurve(1f, 3f);
            Check(Near(two.Evaluate(0f, 0f), 1f) && Near(two.Evaluate(0f, 1f), 3f) && Near(two.Evaluate(0f, 0.5f), 2f), "MinMaxCurve.Evaluate two constants");
            ParticleSystem.MinMaxGradient twoc = new ParticleSystem.MinMaxGradient(Color.black, Color.white);
            Check(twoc.mode == ParticleSystemGradientMode.TwoColors && twoc.colorMax == Color.white, "MinMaxGradient two colors");
            ParticleSystem.MinMaxCurve implicitCurve = 4f;
            float back = implicitCurve.constant;
            Check(Near(back, 4f), "implicit float to MinMaxCurve");

            ps.Play();
            Check(ps.isPlaying && ps.isEmitting && !ps.isStopped, "Play: isPlaying");
            Check(ps.particleCount > 0, "particleCount while playing");
            ps.Pause();
            Check(ps.isPaused, "Pause: isPaused");
            ps.Play();
            ps.Stop();
            Check(!ps.isPlaying && ps.isStopped, "Stop");
            ps.Emit(5);
            ParticleSystem.EmitParams ep = new ParticleSystem.EmitParams();
            ep.position = new Vector3(1, 2, 3);
            ep.startColor = Color.green;
            ep.startSize = 0.25f;
            Check(ep.position == new Vector3(1, 2, 3) && ep.startColor == Color.green && Near(ep.startSize, 0.25f), "EmitParams fields");
            ps.Emit(ep, 2);
            ep.ResetStartColor();
            Check(ep.startColor == Color.white, "EmitParams.ResetStartColor");
            ps.Simulate(1f, true, true);
            ps.Play();
            playTime = ps.time;

            ParticleSystemRenderer r = ps.GetComponent<ParticleSystemRenderer>();
            Check(r != null, "ParticleSystemRenderer via GetComponent");
            if (r != null)
            {
                r.renderMode = ParticleSystemRenderMode.Mesh;
                Check(r.renderMode == ParticleSystemRenderMode.Mesh, "renderMode round trip");
                r.maxParticleSize = 2f;
                Check(Near(r.maxParticleSize, 2f), "renderer stored property");
                Check(r.material != null, "renderer material");
            }
            done = true;
        }

        public void AfterFrames()
        {
            Check(ps.time >= playTime, "time keeps counting while playing: " + ps.time);
        }
    }
}
