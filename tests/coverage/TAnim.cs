using System;
using UdonSharp;
using UnityEngine;
using UnityEngine.Animations;
using VRC.SDK3.Dynamics.Constraint.Components;
using VRC.Dynamics;

namespace Coverage
{
    /// Constraints solved by the runtime, animation curves, humanoid tables, reflection defaults.
    /// The runner provides a Node3D "Target" at (4, 1, 0) on the host and "Follower", "Aimer",
    /// "Scaled" and "ParentFollower" Node3Ds under the fixture.
    public class TAnim : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Transform target;
        public GameObject follower;
        public GameObject aimer;
        public GameObject scaled;
        public GameObject parentFollower;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(target != null && follower != null && aimer != null && scaled != null && parentFollower != null, "anim nodes wired");

            // Unity constraints
            ConstraintSource src = new ConstraintSource();
            src.sourceTransform = target;
            src.weight = 1f;
            PositionConstraint pc = follower.GetComponent<PositionConstraint>();
            Check(pc != null, "PositionConstraint component");
            pc.AddSource(src);
            pc.translationOffset = new Vector3(0, 1, 0);
            pc.translationAxis = Axis.X | Axis.Y | Axis.Z;
            pc.weight = 1f;
            pc.constraintActive = true;
            Check(pc.sourceCount == 1 && pc.constraintActive && Near(pc.GetSource(0).weight, 1f), "PositionConstraint configured");
            ConstraintSource[] srcs = new ConstraintSource[1];
            pc.GetSources(srcs);
            Check(srcs[0].sourceTransform == target, "GetSources");
            AimConstraint ac = aimer.GetComponent<AimConstraint>();
            ac.AddSource(src);
            ac.aimVector = Vector3.forward;
            ac.upVector = Vector3.up;
            ac.worldUpType = AimConstraintWorldUpType.SceneUp;
            ac.constraintActive = true;
            Check(ac.worldUpType == AimConstraintWorldUpType.SceneUp && ac.aimVector == Vector3.forward, "AimConstraint configured");
            ScaleConstraint sc = scaled.GetComponent<ScaleConstraint>();
            sc.AddSource(src);
            sc.scaleOffset = new Vector3(2, 2, 2);
            sc.constraintActive = true;
            Check(sc.sourceCount == 1 && Near(sc.scaleOffset.x, 2f), "ScaleConstraint configured");

            // VRC constraints share the store
            VRCParentConstraint vp = parentFollower.GetComponent<VRCParentConstraint>();
            VRCConstraintSource vs = new VRCConstraintSource(target, 1f, new Vector3(0, 0, 2), Vector3.zero);
            vp.Sources.Add(vs);
            vp.GlobalWeight = 1f;
            vp.ActivateConstraint();
            Check(vp.IsActive && vp.Sources.Count == 1 && Near(vp.Sources[0].Weight, 1f), "VRCParentConstraint configured");
            vp.ApplyConfigurationChanges();

            // AnimationCurve extras
            AnimationCurve curve = AnimationCurve.Linear(0f, 0f, 1f, 10f);
            Keyframe k1 = curve[1];
            Check(Near(k1.value, 10f) && Near(k1.time, 1f), "AnimationCurve indexer");
            AnimationCurve c2 = new AnimationCurve();
            c2.CopyFrom(curve);
            Check(c2.length == 2 && Near(c2.Evaluate(0.5f), 5f), "AnimationCurve.CopyFrom");
            c2.ClearKeys();
            Check(c2.length == 0, "ClearKeys");
            curve.postWrapMode = WrapMode.Loop;
            Check(curve.postWrapMode == WrapMode.Loop, "postWrapMode stored");
            Keyframe[] keys = new Keyframe[] { new Keyframe(0, 2), new Keyframe(1, 4) };
            c2.keys = keys;
            Check(c2.length == 2 && Near(c2.Evaluate(1f), 4f), "keys setter");

            // humanoid tables
            Check(HumanTrait.BoneCount == 55 && HumanTrait.BoneName[10] == "Head" && HumanTrait.MuscleCount == 95, "HumanTrait tables");
            Check(HumanTrait.RequiredBone(0) && !HumanTrait.RequiredBone(21) && HumanTrait.GetParentBone((int)HumanBodyBones.Head) == (int)HumanBodyBones.Neck, "HumanTrait bones");
            HumanDescription hd = new HumanDescription();
            hd.armStretch = 0.1f;
            Check(Near(hd.armStretch, 0.1f) && Near(hd.upperArmTwist, 0.5f), "HumanDescription");
            AvatarMask mask = new AvatarMask();
            mask.AddTransformPath(target, false);
            Check(mask.transformCount == 1 && mask.GetTransformActive(0), "AvatarMask paths");
            mask.SetHumanoidBodyPartActive(AvatarMaskBodyPart.Head, false);
            Check(!mask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.Head) && mask.GetHumanoidBodyPartActive(AvatarMaskBodyPart.Body), "AvatarMask body parts");
            SkeletonBone sb = new SkeletonBone();
            sb.position = Vector3.one;
            Check(Near(sb.scale.x, 1f) && Near(sb.position.x, 1f), "SkeletonBone");

            // reflection defaults
            Type t = typeof(Vector3);
            Check(t.IsPublic && !t.IsGenericType && t.GetArrayRank() == 1 && !t.HasElementType, "Type reflection defaults");
            AnimatorOverrideController aoc = new AnimatorOverrideController();
            Check(aoc.overridesCount == 0 && aoc.runtimeAnimatorController == null, "AnimatorOverrideController");
            done = true;
        }

        /// The solver runs at the end of each frame: after a few frames the nodes follow the target.
        public void AfterFrames()
        {
            Check(Near(follower.transform.position.x, 4f) && Near(follower.transform.position.y, 2f), "PositionConstraint solved: " + follower.transform.position);
            Vector3 toTarget = (target.position - aimer.transform.position).normalized;
            Check(Vector3.Dot(aimer.transform.forward, toTarget) > 0.99f, "AimConstraint solved: " + aimer.transform.forward);
            Check(Near(scaled.transform.localScale.x, 2f) && Near(scaled.transform.localScale.z, 2f), "ScaleConstraint solved: " + scaled.transform.localScale);
            Check(Near(parentFollower.transform.position.x, 4f) && Near(parentFollower.transform.position.z, 2f), "VRCParentConstraint solved with offset: " + parentFollower.transform.position);
        }
    }
}
