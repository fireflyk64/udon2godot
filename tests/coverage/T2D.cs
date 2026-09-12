using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// 2D physics over Godot 2D nodes: RigidBody2D "Body2D" (circle r=0.5 at y=5 Unity units),
    /// StaticBody2D "Floor2D" (200x1 box at y=-0.5). Unity 2D is Y-up; the runtime flips Y.
    public class T2D : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Rigidbody2D body;
        public Collider2D floorCol;
        public SliderJoint2D slider;
        public int collisionEnters2D;
        private float startY;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(body != null && floorCol != null, "2D nodes wired");
            body.mass = 3f;
            body.gravityScale = 1f;
            Check(Near(body.mass, 3f) && Near(body.gravityScale, 1f), "mass/gravityScale");
            body.position = new Vector2(0, 5);
            Check(Near(body.position.y, 5f), "position (Y-up) round trip: " + body.position);
            body.velocity = new Vector2(1, 2);
            Check(Near(body.velocity.x, 1f) && Near(body.velocity.y, 2f), "velocity round trip (Y flipped internally)");
            body.velocity = Vector2.zero;
            body.rotation = 45f;
            Check(Near(body.rotation, 45f), "rotation degrees round trip: " + body.rotation);
            body.rotation = 0f;
            body.angularVelocity = 90f;
            Check(Near(body.angularVelocity, 90f), "angularVelocity");
            body.angularVelocity = 0f;
            body.freezeRotation = true;
            Check(body.freezeRotation && (body.constraints & RigidbodyConstraints2D.FreezeRotation) != 0, "freezeRotation/constraints");
            body.freezeRotation = false;
            body.isKinematic = true;
            Check(body.isKinematic && body.bodyType == RigidbodyType2D.Kinematic, "isKinematic/bodyType");
            body.bodyType = RigidbodyType2D.Dynamic;
            Check(!body.isKinematic, "bodyType Dynamic");
            body.drag = 0.2f;
            body.angularDrag = 0.1f;
            Check(Near(body.drag, 0.2f) && Near(body.angularDrag, 0.1f), "2D drag");
            body.AddForce(new Vector2(0, 5));
            body.AddForce(new Vector2(3, 0), ForceMode2D.Impulse);
            body.AddTorque(1f);
            Vector2 wp = body.GetRelativePoint(new Vector2(1, 0));
            Check(Near(wp.x, 1f) && Near(wp.y, 5f), "GetRelativePoint: " + wp);
            startY = body.position.y;

            RaycastHit2D hit = Physics2D.Raycast(new Vector2(20, 5), Vector2.down);
            Check(hit, "Physics2D.Raycast hits floor (implicit bool)");
            Check(hit.collider == floorCol, "hit.collider is floor");
            Check(Near(hit.point.y, 0f) && Near(hit.distance, 5f), "hit point/distance: " + hit.point + " " + hit.distance);
            Check(hit.normal.y > 0.9f, "hit normal up (Unity Y-up)");
            RaycastHit2D miss = Physics2D.Raycast(new Vector2(20, 5), Vector2.up, 100f);
            Check(!miss && miss.collider == null, "Raycast up misses");
            RaycastHit2D[] all = Physics2D.RaycastAll(new Vector2(20, 5), Vector2.down, 100f);
            Check(all.Length >= 1, "RaycastAll");
            Collider2D[] found = Physics2D.OverlapCircleAll(new Vector2(20, 0), 2f);
            Check(found.Length >= 1, "OverlapCircleAll finds floor");
            Collider2D one = Physics2D.OverlapPoint(new Vector2(20, -0.5f));
            Check(one == floorCol, "OverlapPoint inside floor");
            Check(Physics2D.OverlapPoint(new Vector2(20, 50)) == null, "OverlapPoint empty");
            RaycastHit2D circle = Physics2D.CircleCast(new Vector2(20, 5), 0.5f, Vector2.down, 100f);
            Check(circle && circle.distance > 4f && circle.distance < 5.1f, "CircleCast: " + circle.distance);
            Check(Physics2D.gravity.y < 0f, "Physics2D.gravity points down (Unity axes)");
            Bounds fb = floorCol.bounds;
            Check(fb.size.x > 100f, "Collider2D.bounds: " + fb.size);
            Check(!floorCol.isTrigger && floorCol.enabled && floorCol.attachedRigidbody == null, "Collider2D props");
            Check(body.GetComponent<Collider2D>().attachedRigidbody == body, "attachedRigidbody 2D");
            Physics2D.IgnoreCollision(body.GetComponent<Collider2D>(), floorCol, false);

            // more Physics2D overloads
            RaycastHit2D[] rbuf = new RaycastHit2D[4];
            Check(Physics2D.LinecastNonAlloc(new Vector2(20, 5), new Vector2(20, -5), rbuf) >= 1 && rbuf[0].collider == floorCol, "LinecastNonAlloc");
            Collider2D[] cbuf = new Collider2D[4];
            Check(Physics2D.OverlapAreaNonAlloc(new Vector2(19, -1), new Vector2(21, 0), cbuf) >= 1 && cbuf[0] == floorCol, "OverlapAreaNonAlloc");
            RaycastHit2D[] caps = Physics2D.CapsuleCastAll(new Vector2(20, 5), new Vector2(0.5f, 1f), CapsuleDirection2D.Vertical, 0f, Vector2.down);
            Check(caps.Length >= 1 && caps[0].distance > 4.3f && caps[0].distance < 4.7f, "CapsuleCastAll vertical: " + (caps.Length > 0 ? caps[0].distance : -1f));
            RaycastHit2D hcap = Physics2D.CapsuleCast(new Vector2(20, 5), new Vector2(1f, 0.5f), CapsuleDirection2D.Horizontal, 0f, Vector2.down, 100f);
            Check(hcap && hcap.distance > 4.6f && hcap.distance < 4.9f, "CapsuleCast horizontal: " + hcap.distance);
            Check(Physics2D.CapsuleCastNonAlloc(new Vector2(20, 5), new Vector2(0.5f, 1f), CapsuleDirection2D.Vertical, 0f, Vector2.down, rbuf, 100f) == 1, "CapsuleCastNonAlloc");
            Check(Physics2D.OverlapCapsule(new Vector2(20, 0), new Vector2(1f, 2f), CapsuleDirection2D.Vertical, 0f) == floorCol, "OverlapCapsule");
            RaycastHit2D rayHit = Physics2D.GetRayIntersection(new Ray(new Vector3(20, -0.5f, -5), Vector3.forward));
            Check(rayHit && rayHit.collider == floorCol && Near(rayHit.distance, 5f), "GetRayIntersection through the plane: " + rayHit.distance);
            Check(!Physics2D.GetRayIntersection(new Ray(new Vector3(20, 50, -5), Vector3.forward), 100f), "GetRayIntersection misses");
            Check(Physics2D.GetRayIntersectionNonAlloc(new Ray(new Vector3(20, -0.5f, -5), Vector3.forward), rbuf) == 1, "GetRayIntersectionNonAlloc");

            // ContactFilter2D is a real filter now
            ContactFilter2D filter = new ContactFilter2D();
            filter.SetLayerMask(1 << 3);
            Check(filter.useLayerMask && filter.isFiltering, "ContactFilter2D.SetLayerMask");
            Check(Physics2D.Raycast(new Vector2(20, 5), Vector2.down, filter, rbuf) == 0, "filtered raycast misses on layer mask");
            filter.ClearLayerMask();
            Check(Physics2D.Raycast(new Vector2(20, 5), Vector2.down, filter, rbuf) >= 1, "unfiltered raycast hits");
            filter.SetDepth(-1f, 1f);
            Check(filter.useDepth && Near(filter.minDepth, -1f) && Near(filter.maxDepth, 1f), "SetDepth");
            filter.ClearDepth();
            Check(!filter.useDepth, "ClearDepth");
            filter.SetNormalAngle(45f, 135f);
            Check(filter.useNormalAngle && !filter.IsFilteringNormalAngle(90f) && filter.IsFilteringNormalAngle(0f), "SetNormalAngle / IsFilteringNormalAngle");
            filter.NoFilter();
            Check(!filter.isFiltering, "NoFilter");

            // PhysicsScene2D
            PhysicsScene2D scene = Physics2D.defaultPhysicsScene;
            Check(scene.IsValid() && scene == Physics2D.defaultPhysicsScene, "PhysicsScene2D valid");
            RaycastHit2D sh = scene.Raycast(new Vector2(20, 5), Vector2.down, 100f, -1);
            Check(sh && sh.collider == floorCol, "PhysicsScene2D.Raycast");
            Check(scene.OverlapCircle(new Vector2(20, 0), 2f, cbuf, -1) >= 1, "PhysicsScene2D.OverlapCircle(results)");
            Check(scene.OverlapPoint(new Vector2(20, -0.5f), -1) == floorCol, "PhysicsScene2D.OverlapPoint");
            Check(scene.BoxCast(new Vector2(20, 5), new Vector2(1, 1), 0f, Vector2.down, 100f, -1), "PhysicsScene2D.BoxCast");

            // ConstantForce2D drives the RigidBody2D constant force
            ConstantForce2D cf = body.GetComponent<ConstantForce2D>();
            Check(cf != null && cf.enabled, "ConstantForce2D component");
            cf.force = new Vector2(0, 3);
            cf.torque = 2f;
            Check(Near(cf.force.y, 3f) && Near(cf.torque, 2f) && Near(body.totalForce.y, 3f), "ConstantForce2D force/torque");
            cf.enabled = false;
            Check(!cf.enabled && Near(body.totalForce.y, 0f), "ConstantForce2D disabled parks the force");
            cf.enabled = true;
            Check(Near(cf.force.y, 3f), "ConstantForce2D re-enabled");
            cf.force = Vector2.zero;
            cf.torque = 0f;

            // scene settings with a live Godot equivalent
            Physics2D.linearSleepTolerance = 0.02f;
            Physics2D.timeToSleep = 0.7f;
            Physics2D.velocityIterations = 10;
            Check(Near(Physics2D.linearSleepTolerance, 0.02f) && Near(Physics2D.timeToSleep, 0.7f) && Physics2D.velocityIterations == 10, "Physics2D space parameters");
            Physics2D.angularSleepTolerance = 3f;
            Check(Near(Physics2D.angularSleepTolerance, 3f), "angularSleepTolerance degrees");
            Physics2D.baumgarteScale = 0.3f;
            Check(Near(Physics2D.baumgarteScale, 0.3f), "baumgarteScale stored");

            // joints, shapes, structs
            Check(slider != null, "slider wired");
            JointTranslationLimits2D lim = new JointTranslationLimits2D();
            lim.min = -1f;
            lim.max = 2f;
            slider.limits = lim;
            Check(Near(slider.limits.min, -1f) && Near(slider.limits.max, 2f), "SliderJoint2D.limits via groove length");
            Check(slider.limitState == JointLimitState2D.Inactive, "limitState");
            PhysicsShapeGroup2D group = new PhysicsShapeGroup2D();
            Check(floorCol.GetShapes(group) == 1 && group.shapeCount == 1, "Collider2D.GetShapes");
            Check(floorCol.errorState == ColliderErrorState2D.None, "errorState");
            ColliderDistance2D cd = body.Distance(floorCol);
            cd.distance = 1.5f;
            Check(Near(cd.distance, 1.5f) && cd.isValid, "ColliderDistance2D setter");
            JointSuspension2D sus = new JointSuspension2D();
            sus.frequency = 4f;
            Check(Near(sus.frequency, 4f) && Near(sus.angle, 90f), "JointSuspension2D");
            done = true;
        }

        public override void OnCollisionEnter2D(Collision2D collision)
        {
            collisionEnters2D++;
            if (collisionEnters2D == 1)
                Check(collision.collider == floorCol && collision.contactCount >= 0, "OnCollisionEnter2D with the floor");
        }

        public void AfterFrames()
        {
            Check(body.position.y < startY, "2D gravity moved the body down: " + body.position.y);
            Check(body.position.x > 0.05f, "2D impulse moved body along +X: " + body.position.x);
            Check(body.position.y > 0.2f, "2D body rests on floor: " + body.position.y);
            Check(collisionEnters2D >= 1, "OnCollisionEnter2D fired: " + collisionEnters2D);
        }
    }
}
