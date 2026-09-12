using UdonSharp;
using UnityEngine;
using UnityEngine.AI;
using Unity.AI.Navigation;

namespace Coverage
{
    /// Navigation over Godot's NavigationServer3D. The runner provides a NavigationRegion3D "Region"
    /// (flat 20x20 mesh at y=0), a NavigationLink3D "Link" and a NavigationAgent3D "Agent".
    public class TNav : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public NavMeshLink link;
        public NavMeshAgent agent;
        public GameObject region;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(link != null && agent != null && region != null, "nav nodes wired");

            // NavMesh queries
            NavMeshHit hit;
            Check(NavMesh.SamplePosition(new Vector3(1, 0.5f, 1), out hit, 2f, NavMesh.AllAreas) && Near(hit.position.y, 0f) && hit.hit, "SamplePosition snaps to the mesh: " + hit.position);
            Check(!NavMesh.SamplePosition(new Vector3(50, 0, 50), out hit, 1f, NavMesh.AllAreas), "SamplePosition misses far away");
            NavMeshPath path = new NavMeshPath();
            Check(NavMesh.CalculatePath(new Vector3(-5, 0, -5), new Vector3(5, 0, 5), NavMesh.AllAreas, path) && path.corners.Length >= 2, "CalculatePath corners: " + path.corners.Length);
            NavMeshHit ray;
            Check(NavMesh.Raycast(new Vector3(0, 0, 0), new Vector3(0, 0, 40), out ray, NavMesh.AllAreas) && ray.hit && ray.position.z < 11f && ray.position.z > 8f, "NavMesh.Raycast leaves the mesh at the edge: " + ray.position);
            Check(!NavMesh.Raycast(new Vector3(-3, 0, 0), new Vector3(3, 0, 0), out ray, NavMesh.AllAreas), "NavMesh.Raycast inside stays clear");
            NavMeshTriangulation tri = NavMesh.CalculateTriangulation();
            Check(tri.vertices.Length == 4 && tri.indices.Length == 6 && tri.areas.Length == 2, "CalculateTriangulation: " + tri.vertices.Length + "/" + tri.indices.Length);
            NavMeshQueryFilter filter = new NavMeshQueryFilter();
            filter.areaMask = NavMesh.AllAreas;
            filter.SetAreaCost(3, 2.5f);
            Check(Near(filter.GetAreaCost(3), 2.5f) && Near(filter.GetAreaCost(0), 1f), "NavMeshQueryFilter area costs");
            Check(NavMesh.SamplePosition(new Vector3(2, 1, 2), out hit, 3f, filter) && hit.hit, "SamplePosition with filter");
            NavMeshBuildSettings settings = NavMesh.CreateSettings();
            settings.agentRadius = 0.35f;
            Check(Near(settings.agentRadius, 0.35f) && Near(settings.agentHeight, 2f) && NavMesh.GetSettingsCount() == 1, "NavMeshBuildSettings");

            // links
            link.startPoint = new Vector3(0, 0, 0);
            link.endPoint = new Vector3(4, 0, 4);
            Check(Near(link.endPoint.x, 4f) && Near(link.startPoint.x, 0f), "NavMeshLink points");
            link.bidirectional = false;
            Check(!link.bidirectional, "NavMeshLink.bidirectional");
            link.bidirectional = true;
            link.costModifier = 3;
            Check(link.costModifier == 3, "NavMeshLink.costModifier");
            link.area = 2;
            Check(link.area == 2, "NavMeshLink.area");
            link.width = 1.5f;
            Check(Near(link.width, 1.5f), "NavMeshLink.width stored");
            OffMeshLink off = link.GetComponent<OffMeshLink>();
            Check(off != null && off.biDirectional && Near(off.costOverride, 3f), "OffMeshLink view of the same link");
            off.startTransform = region.transform;
            Check(off.startTransform == region.transform, "OffMeshLink.startTransform");
            off.activated = false;
            Check(!off.activated, "OffMeshLink.activated");
            NavMeshLinkData data = new NavMeshLinkData();
            data.startPosition = new Vector3(-2, 0, -2);
            data.endPosition = new Vector3(2, 0, 2);
            data.costModifier = 2f;
            NavMeshLinkInstance inst = NavMesh.AddLink(data);
            Check(inst.valid, "NavMesh.AddLink instance valid");
            NavMesh.RemoveLink(inst);
            Check(!inst.valid, "NavMesh.RemoveLink invalidates");
            NavMeshData nmd = new NavMeshData();
            NavMeshDataInstance di = NavMesh.AddNavMeshData(nmd);
            Check(!di.valid, "AddNavMeshData without a mesh is not valid");

            // modifiers are bake-time settings: they round-trip
            NavMeshModifier mod = region.GetComponent<NavMeshModifier>();
            mod.area = 4;
            mod.ignoreFromBuild = true;
            Check(mod.area == 4 && mod.ignoreFromBuild && mod.applyToChildren, "NavMeshModifier stored");
            NavMeshModifierVolume vol = region.GetComponent<NavMeshModifierVolume>();
            vol.size = new Vector3(2, 2, 2);
            Check(Near(vol.size.x, 2f), "NavMeshModifierVolume stored");

            // agent
            Check(agent.navMeshOwner != null, "NavMeshAgent.navMeshOwner");
            NavMeshPath ap = new NavMeshPath();
            Check(agent.CalculatePath(new Vector3(5, 0, 5), ap) && ap.corners.Length >= 2, "NavMeshAgent.CalculatePath");
            NavMeshHit ah;
            Check(agent.Raycast(new Vector3(0, 0, 40), out ah) && ah.hit, "NavMeshAgent.Raycast");
            done = true;
        }
    }
}
