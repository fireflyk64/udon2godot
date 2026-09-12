using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Rigidbody, raycasts, overlaps, colliders. The runner provides a RigidBody3D "Body"
    /// (box 1x1x1 at y=5), a StaticBody3D "Floor" (100x1x100 at y=-0.5) and an Area3D "Trigger".
    public class TPhysics : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Rigidbody body;
        public Collider floorCol;
        public Collider trigger;
        public CharacterController controller;
        public int triggerEnters;
        public int collisionEnters;
        public int controllerHits;
        private float startY;
        private Vector3 lastHitNormal;
        private GameObject lastHitObject;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(body != null && floorCol != null, "nodes wired");
            body.mass = 2f;
            Check(Near(body.mass, 2f), "mass");
            body.drag = 0.5f;
            body.angularDrag = 0.1f;
            Check(Near(body.drag, 0.5f) && Near(body.angularDrag, 0.1f), "drag/angularDrag");
            body.useGravity = false;
            Check(!body.useGravity, "useGravity off");
            body.useGravity = true;
            Check(body.useGravity, "useGravity on");
            body.isKinematic = true;
            Check(body.isKinematic, "isKinematic");
            body.isKinematic = false;
            body.velocity = new Vector3(1, 0, 0);
            Check(Near(body.velocity.x, 1f), "velocity set/get");
            body.velocity = Vector3.zero;
            body.angularVelocity = new Vector3(0, 2, 0);
            Check(Near(body.angularVelocity.y, 2f), "angularVelocity");
            body.angularVelocity = Vector3.zero;
            body.constraints = RigidbodyConstraints.FreezeRotation;
            Check(body.freezeRotation && (body.constraints & RigidbodyConstraints.FreezeRotationX) != 0, "constraints/freezeRotation");
            body.constraints = RigidbodyConstraints.None;
            Check(!body.freezeRotation, "constraints cleared");
            body.position = new Vector3(0, 5, 0);
            Check(Near(body.position.y, 5f) && Near(body.transform.position.y, 5f), "rigidbody.position");
            body.rotation = Quaternion.Euler(0, 90, 0);
            Check(Near(Quaternion.Angle(body.rotation, Quaternion.Euler(0, 90, 0)), 0f), "rigidbody.rotation");
            body.rotation = Quaternion.identity;
            body.centerOfMass = new Vector3(0, -0.2f, 0);
            Check(Near(body.centerOfMass.y, -0.2f), "centerOfMass");
            Check(Near(body.worldCenterOfMass.y, 4.8f), "worldCenterOfMass");
            body.ResetCenterOfMass();
            Check(!body.IsSleeping() || true, "IsSleeping callable");
            body.WakeUp();
            Vector3 pv = body.GetPointVelocity(body.position + Vector3.right);
            Check(pv.magnitude < 0.01f, "GetPointVelocity at rest");
            body.AddForce(new Vector3(0, 10, 0));
            body.AddForce(Vector3.right * 3f, ForceMode.Impulse);
            body.AddTorque(Vector3.up, ForceMode.Impulse);
            body.AddForceAtPosition(Vector3.forward, body.position + Vector3.right, ForceMode.Force);
            startY = body.position.y;

            // raycast down onto the floor from above
            RaycastHit hit;
            bool hitSomething = Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, out hit, 100f);
            Check(hitSomething, "Physics.Raycast hits the floor");
            if (hitSomething)
            {
                Check(Near(hit.point.y, 0f), "hit.point on floor top: " + hit.point.y);
                Check(Near(hit.distance, 5f), "hit.distance: " + hit.distance);
                Check(hit.normal.y > 0.99f, "hit.normal up");
                Check(hit.collider == floorCol && hit.transform == floorCol.transform, "hit.collider is floor");
                Check(hit.rigidbody == null, "hit.rigidbody null for static floor");
            }
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.up, 100f), "Raycast up hits nothing");
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, 2f), "Raycast too short misses");
            Check(Physics.Raycast(new Ray(new Vector3(10, 5, 10), Vector3.down), out hit) && Near(hit.distance, 5f), "Raycast(Ray, out hit)");
            int mask = 1 << 3;
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, out hit, 100f, mask), "Raycast with non-matching layer mask misses");
            RaycastHit[] hits = Physics.RaycastAll(new Vector3(10, 5, 10), Vector3.down, 100f);
            Check(hits.Length >= 1, "RaycastAll");
            Check(Physics.Linecast(new Vector3(10, 5, 10), new Vector3(10, -5, 10)), "Linecast through floor");
            RaycastHit sh;
            Check(Physics.SphereCast(new Vector3(10, 5, 10), 0.5f, Vector3.down, out sh, 100f) && sh.distance > 4f && sh.distance < 5.1f, "SphereCast: " + sh.distance);
            RaycastHit bh;
            Check(Physics.BoxCast(new Vector3(10, 5, 10), new Vector3(0.5f, 0.5f, 0.5f), Vector3.down, out bh, Quaternion.identity, 100f) && bh.distance > 4f && bh.distance < 5.1f, "BoxCast: " + bh.distance);
            Check(Physics.BoxCast(new Vector3(10, 5, 10), new Vector3(0.5f, 0.5f, 0.5f), Vector3.down), "BoxCast(bool)");
            Check(Physics.BoxCastAll(new Vector3(10, 5, 10), new Vector3(0.5f, 0.5f, 0.5f), Vector3.down).Length == 1, "BoxCastAll");
            Check(!Physics.BoxCast(new Vector3(10, 5, 10), new Vector3(0.5f, 0.5f, 0.5f), Vector3.up, Quaternion.identity, 100f), "BoxCast up misses");
            RaycastHit ch;
            Check(Physics.CapsuleCast(new Vector3(10, 5, 10), new Vector3(10, 6, 10), 0.25f, Vector3.down, out ch, 100f) && ch.distance > 4f && ch.distance < 5.1f, "CapsuleCast: " + ch.distance);
            RaycastHit[] cbuf = new RaycastHit[2];
            Check(Physics.CapsuleCastNonAlloc(new Vector3(10, 5, 10), new Vector3(10, 6, 10), 0.25f, Vector3.down, cbuf, 100f) == 1 && cbuf[0].distance > 4f, "CapsuleCastNonAlloc");
            Collider[] cap = new Collider[4];
            Check(Physics.OverlapCapsuleNonAlloc(new Vector3(0, 0, 0), new Vector3(0, 2, 0), 1f, cap) >= 1, "OverlapCapsuleNonAlloc");
            Collider[] around = Physics.OverlapSphere(new Vector3(0, 0, 0), 3f);
            Check(around.Length >= 1, "OverlapSphere finds floor");
            Collider[] buf = new Collider[4];
            int n = Physics.OverlapSphereNonAlloc(new Vector3(0, 0, 0), 3f, buf);
            Check(n >= 1 && buf[0] != null, "OverlapSphereNonAlloc");
            Check(Physics.CheckSphere(new Vector3(0, 0, 0), 1f), "CheckSphere");
            Check(Physics.gravity.y < 0f, "Physics.gravity");

            // colliders
            Bounds fb = floorCol.bounds;
            Check(fb.size.x > 50f && Near(fb.max.y, 0f), "floor bounds: " + fb.size + " max " + fb.max);
            Check(floorCol.enabled, "collider enabled");
            Check(!floorCol.isTrigger && trigger.isTrigger, "isTrigger");
            Check(floorCol.attachedRigidbody == null && body.GetComponent<Collider>().attachedRigidbody == body, "attachedRigidbody");
            Vector3 cp = floorCol.ClosestPoint(new Vector3(3, 10, 3));
            Check(Near(cp.y, 0f) && Near(cp.x, 3f), "ClosestPoint");
            Physics.IgnoreCollision(body.GetComponent<Collider>(), floorCol, false);

            // Unity 2022 layer overrides fold into the Godot collision mask (engine check: 1 | 1<<5)
            Collider bodyCol = body.GetComponent<Collider>();
            bodyCol.excludeLayers = 1 << 3;
            Check(bodyCol.excludeLayers == (1 << 3) && bodyCol.includeLayers == 0, "Collider.excludeLayers round trip");
            bodyCol.excludeLayers = 0;
            body.includeLayers = 1 << 5;
            Check(body.includeLayers == (1 << 5) && bodyCol.includeLayers == (1 << 5), "Rigidbody.includeLayers shared with its collider");
            Check(!bodyCol.providesContacts || true, "providesContacts readable");
            bodyCol.providesContacts = true;
            Check(bodyCol.providesContacts, "providesContacts set");
            bodyCol.contactOffset = 0.02f;
            Check(Near(bodyCol.contactOffset, 0.02f), "contactOffset stored");
            Check(bodyCol.attachedArticulationBody == null, "attachedArticulationBody null");
            body.centerOfMass = new Vector3(0, -0.2f, 0);
            Check(!body.automaticCenterOfMass, "automaticCenterOfMass off after explicit centre");
            body.automaticCenterOfMass = true;
            Check(body.automaticCenterOfMass, "automaticCenterOfMass on");
            Check(body.automaticInertiaTensor, "automaticInertiaTensor default");
            Vector3 before = body.GetAccumulatedForce();
            body.AddForce(new Vector3(0, 10, 0));
            Vector3 acc = body.GetAccumulatedForce();
            Check(Near(acc.y - before.y, 10f), "GetAccumulatedForce this step: " + acc);
            Vector3 beforeT = body.GetAccumulatedTorque();
            body.AddTorque(new Vector3(0, 0, 4f));
            Check(Near(body.GetAccumulatedTorque().z - beforeT.z, 4f), "GetAccumulatedTorque this step");
            body.isKinematic = true;
            body.Move(new Vector3(0, 6, 0), Quaternion.Euler(0, 45, 0));
            Check(Near(body.position.y, 6f) && Near(Quaternion.Angle(body.rotation, Quaternion.Euler(0, 45, 0)), 0f), "Rigidbody.Move (kinematic)");
            body.rotation = Quaternion.identity;
            body.position = new Vector3(0, 5, 0);
            body.isKinematic = false;
            // the kinematic round trip zeroes velocity (Godot and Unity alike): re-apply the sideways impulse
            body.AddForce(Vector3.right * 3f, ForceMode.Impulse);
            body.maxLinearVelocity = 50f;
            Check(Near(body.maxLinearVelocity, 50f), "maxLinearVelocity stored");

            // PhysicsScene delegates to the world queries
            PhysicsScene scene = Physics.defaultPhysicsScene;
            Check(scene.IsValid() && !scene.IsEmpty() && scene == Physics.defaultPhysicsScene, "PhysicsScene valid");
            RaycastHit sceneHit;
            Check(scene.Raycast(new Vector3(10, 5, 10), Vector3.down, out sceneHit, 100f, -1, QueryTriggerInteraction.UseGlobal) && Near(sceneHit.distance, 5f), "PhysicsScene.Raycast(out hit)");
            Check(scene.Raycast(new Vector3(10, 5, 10), Vector3.down, 100f, -1, QueryTriggerInteraction.UseGlobal), "PhysicsScene.Raycast(bool)");
            RaycastHit[] sceneBuf = new RaycastHit[2];
            Check(scene.Raycast(new Vector3(10, 5, 10), Vector3.down, sceneBuf, 100f, -1, QueryTriggerInteraction.UseGlobal) == 1 && sceneBuf[0].collider == floorCol, "PhysicsScene.Raycast(results)");
            Check(scene.SphereCast(new Vector3(10, 5, 10), 0.5f, Vector3.down, out sceneHit, 100f, -1, QueryTriggerInteraction.UseGlobal) && sceneHit.distance > 4f, "PhysicsScene.SphereCast");
            Collider[] sceneCols = new Collider[4];
            Check(scene.OverlapSphere(new Vector3(0, 0, 0), 3f, sceneCols, -1, QueryTriggerInteraction.UseGlobal) >= 1, "PhysicsScene.OverlapSphere");
            Check(sceneHit.colliderInstanceID != 0, "RaycastHit.colliderInstanceID");
            Physics.bounceThreshold = 3f;
            Check(Near(Physics.bounceThreshold, 3f), "Physics.bounceThreshold stored");

            // PhysicMaterial combine modes map to Godot rough/absorbent and round-trip
            PhysicMaterial pm = new PhysicMaterial();
            pm.frictionCombine = PhysicMaterialCombine.Maximum;
            pm.bounceCombine = PhysicMaterialCombine.Minimum;
            pm.name = "Ice";
            Check(pm.frictionCombine == PhysicMaterialCombine.Maximum && pm.bounceCombine == PhysicMaterialCombine.Minimum, "PhysicMaterial combine modes");
            pm.frictionCombine = PhysicMaterialCombine.Multiply;
            Check(pm.frictionCombine == PhysicMaterialCombine.Multiply && pm.name == "Ice", "PhysicMaterial Multiply + name");
            floorCol.material = pm;
            Check(floorCol.material == pm, "collider material assigned");

            // structs
            WheelHit wh = new WheelHit();
            wh.force = 5f;
            wh.forwardDir = Vector3.forward;
            Check(Near(wh.force, 5f) && wh.forwardDir.z > 0.9f, "WheelHit setters");
            JointMotor jm = new JointMotor();
            jm.freeSpin = true;
            jm.targetVelocity = 3f;
            Check(jm.freeSpin && Near(jm.targetVelocity, 3f), "JointMotor.freeSpin");

            // CharacterController: capsule shape, move into the floor and get OnControllerColliderHit
            Check(controller != null, "controller wired");
            controller.height = 2f;
            controller.radius = 0.4f;
            Check(Near(controller.height, 2f) && Near(controller.radius, 0.4f), "CharacterController capsule size");
            CapsuleCollider capsule = controller.GetComponent<CapsuleCollider>();
            Check(capsule != null && capsule.direction == 1, "CapsuleCollider direction default Y");
            capsule.direction = 0;
            Check(capsule.direction == 0, "CapsuleCollider direction X");
            capsule.direction = 1;
            CollisionFlags flags = controller.Move(new Vector3(0, -1f, 0));
            Check((flags & CollisionFlags.Below) != 0 && controller.isGrounded, "CharacterController.Move lands on the floor: " + (int)flags);
            Check(controllerHits >= 1 && lastHitNormal.y > 0.9f && lastHitObject == floorCol.gameObject, "OnControllerColliderHit dispatched: " + controllerHits);
            done = true;
        }

        public override void OnControllerColliderHit(ControllerColliderHit hit)
        {
            controllerHits++;
            lastHitNormal = hit.normal;
            lastHitObject = hit.gameObject;
            Check(hit.controller == controller && hit.moveDirection.y < 0f && hit.moveLength > 0.5f, "ControllerColliderHit fields");
        }

        public override void OnTriggerEnter(Collider other) { triggerEnters++; }
        public override void OnCollisionEnter(Collision collision)
        {
            collisionEnters++;
            Check(collision.collider != null && collision.contacts.Length >= 0, "OnCollisionEnter has collider");
            ContactPoint[] cps = new ContactPoint[4];
            int k = collision.GetContacts(cps);
            Check(k == Mathf.Min(collision.contactCount, 4), "Collision.GetContacts count");
            if (collisionEnters == 1)
                Check(collision.gameObject == floorCol.gameObject && collision.rigidbody == null, "first collision is with the floor");
        }

        /// Called by the runner after ~60 physics frames.
        public void AfterFrames()
        {
            Check(body.position.y < startY, "gravity pulled the body down: " + body.position.y + " < " + startY);
            Check(body.velocity.x > 0.5f || body.position.x > 0.05f, "impulse moved body along +X");
            Check(body.position.y > 0.4f, "body rests on floor (not falling through): " + body.position.y);
            Check(collisionEnters >= 1, "OnCollisionEnter fired when the body landed: " + collisionEnters);
            Check(triggerEnters >= 1, "OnTriggerEnter fired when the body reached the trigger: " + triggerEnters);
        }
    }
}
