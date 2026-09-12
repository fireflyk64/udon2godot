using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.SDK3.Components;
using VRC.SDK3.Persistence;
using VRC.SDK3.UdonNetworkCalling;
using VRC.Udon.Common.Interfaces;

namespace Coverage
{
    /// VRChat world API: players, ownership, events, sync, pickups, stations, object sync/pool,
    /// player data, input, time. The runner provides "Other" (a second TVRC), "Pickup", "Station",
    /// "Synced" and "Pool" (with two inactive children) Node3Ds.
    [UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
    public class TVRC : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public TVRC other;
        public GameObject pickupObj;
        public GameObject stationObj;
        public GameObject syncedObj;
        public GameObject poolObj;

        [UdonSynced] public int syncedInt;
        [UdonSynced(UdonSyncMode.Linear)] public float syncedFloat;
        [UdonSynced, FieldChangeCallback(nameof(Health))] private int _health = 100;
        public int healthCallbacks;
        public int Health
        {
            get => _health;
            set { _health = value; healthCallbacks++; }
        }

        public int customEvents;
        public int delayedEvents;
        public int networkEvents;
        public int netArgSum;
        public int deserializations;
        public int stationEnters;
        public int joins;
        public bool sawNetworkCallContext;
        public string joinedName = "";
        private VRCPlayerApi localPlayer;
        private float startTime;
        private int startFrame;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        void Start()
        {
            localPlayer = Networking.LocalPlayer;
            startTime = Time.time;
            startFrame = Time.frameCount;
        }

        public void RunTests()
        {
            // players
            Check(localPlayer != null && localPlayer.IsValid() && Utilities.IsValid(localPlayer), "LocalPlayer valid");
            Check(localPlayer.isLocal && localPlayer.playerId >= 1, "isLocal/playerId");
            Check(localPlayer.displayName.Length > 0, "displayName");
            Check(Networking.IsMaster && localPlayer.isMaster, "master in single-user world");
            Check(Networking.IsInstanceOwner && localPlayer.isInstanceOwner, "instance owner");
            Check(VRCPlayerApi.GetPlayerCount() >= 1, "GetPlayerCount");
            Check(VRCPlayerApi.GetPlayerById(localPlayer.playerId) == localPlayer, "GetPlayerById");
            Check(VRCPlayerApi.GetPlayerById(9999) == null, "GetPlayerById unknown → null");
            VRCPlayerApi[] players = new VRCPlayerApi[VRCPlayerApi.GetPlayerCount()];
            VRCPlayerApi.GetPlayers(players);
            Check(players[0] != null && players[0].playerId == localPlayer.playerId, "GetPlayers fills array");
            Check(!localPlayer.IsUserInVR(), "IsUserInVR false headless");
            Check(localPlayer.IsPlayerGrounded(), "IsPlayerGrounded default");
            localPlayer.TeleportTo(new Vector3(1, 2, 3), Quaternion.identity);
            Vector3 pos = localPlayer.GetPosition();
            Check(pos.magnitude >= 0f, "GetPosition callable: " + pos);
            VRCPlayerApi.TrackingData head = localPlayer.GetTrackingData(VRCPlayerApi.TrackingDataType.Head);
            Check(head.position.y >= pos.y, "tracking data head above origin");
            Check(localPlayer.GetTrackingData(VRCPlayerApi.TrackingDataType.LeftHand).rotation == localPlayer.GetRotation(), "tracking rotation");
            localPlayer.SetPlayerTag("team", "red");
            Check(localPlayer.GetPlayerTag("team") == "red", "player tags");
            localPlayer.ClearPlayerTags();
            Check(localPlayer.GetPlayerTag("team") == "", "ClearPlayerTags");
            localPlayer.SetVelocity(new Vector3(0, 1, 0));
            Check(Near(localPlayer.GetVelocity().y, 1f), "SetVelocity/GetVelocity");
            localPlayer.SetVoiceGain(10f);
            Check(Near(localPlayer.GetVoiceGain(), 10f), "voice gain");
            localPlayer.SetWalkSpeed(3f);
            Check(Near(localPlayer.GetWalkSpeed(), 3f), "walk speed");
            localPlayer.SetJumpImpulse(4f);
            Check(Near(localPlayer.GetJumpImpulse(), 4f), "jump impulse");
            localPlayer.Immobilize(true);
            localPlayer.Immobilize(false);
            localPlayer.PlayHapticEventInHand(VRC_Pickup.PickupHand.Left, 0.2f, 0.5f, 0.5f);
            Check(Near(localPlayer.GetAvatarEyeHeightAsMeters(), 1.6f), "eye height default");
            Check(localPlayer.GetBonePosition(HumanBodyBones.Head).magnitude >= 0f, "GetBonePosition callable");
            Check(Networking.Master == localPlayer, "Networking.Master");

            // ownership
            Check(Networking.IsOwner(gameObject) && Networking.IsOwner(localPlayer, gameObject), "owner by default");
            Check(Networking.GetOwner(gameObject) == localPlayer, "GetOwner");
            Networking.SetOwner(localPlayer, other.gameObject);
            Check(Networking.IsOwner(other.gameObject), "SetOwner to self");
            Check(Networking.IsObjectReady(gameObject) && Networking.IsNetworkSettled, "ready/settled");
            Check(!Networking.IsClogged, "not clogged");
            Check(Networking.GetServerTimeInMilliseconds() >= 0 && Networking.GetServerTimeInSeconds() >= 0.0, "server time");
            Check(Networking.GetUniqueName(gameObject).Length > 0, "GetUniqueName");

            // events
            other.SendCustomEvent(nameof(OnCustom));
            Check(other.customEvents == 1, "SendCustomEvent on another behaviour");
            SendCustomEvent("OnCustom");
            Check(customEvents == 1, "SendCustomEvent on self");
            other.SetProgramVariable("syncedInt", 41);
            Check((int)other.GetProgramVariable("syncedInt") == 41, "Get/SetProgramVariable");
            SendCustomEventDelayedFrames(nameof(OnDelayed), 1);
            SendCustomEventDelayedSeconds(nameof(OnDelayed), 0.05f);
            SendCustomNetworkEvent(NetworkEventTarget.All, nameof(OnNet), 5, "x");
            Check(networkEvents == 1 && netArgSum == 5 && sawNetworkCallContext, "SendCustomNetworkEvent(All) runs locally with args and NetworkCalling context");
            Check(!NetworkCalling.InNetworkCall, "InNetworkCall false outside");
            SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(OnNet), 2, "y");
            Check(networkEvents == 2 && netArgSum == 7, "Owner-targeted event delivered to owner (self)");
            SendCustomNetworkEvent(NetworkEventTarget.Others, nameof(OnNet), 100, "z");
            Check(networkEvents == 2, "Others-targeted event not run locally");
            other.SendCustomNetworkEvent(NetworkEventTarget.All, "OnNet", 1, "w");
            Check(other.networkEvents == 1, "network event to another behaviour");

            // sync
            syncedInt = 7;
            syncedFloat = 2.5f;
            Health = 90;
            Check(healthCallbacks == 1 && _health == 90, "property setter path");
            RequestSerialization();
            Check(true, "RequestSerialization callable");

            // pickup
            VRC_Pickup pickup = pickupObj.GetComponent<VRC_Pickup>();
            Check(pickup != null, "VRC_Pickup component");
            Check(!pickup.IsHeld && pickup.currentPlayer == null && pickup.currentHand == VRC_Pickup.PickupHand.None, "pickup initial state");
            pickup.pickupable = false;
            Check(!pickup.pickupable, "pickupable");
            pickup.pickupable = true;
            pickup.InteractionText = "Grab";
            pickup.proximity = 3f;
            pickup.orientation = VRC_Pickup.PickupOrientation.Gun;
            Check(pickup.InteractionText == "Grab" && Near(pickup.proximity, 3f) && pickup.orientation == VRC_Pickup.PickupOrientation.Gun, "pickup props");
            pickup.Drop();

            // station
            VRCStation station = stationObj.GetComponent<VRCStation>();
            Check(station != null, "VRCStation component");
            station.PlayerMobility = VRCStation.Mobility.Immobilize;
            station.disableStationExit = true;
            Check(station.PlayerMobility == VRCStation.Mobility.Immobilize && station.disableStationExit, "station props");
            station.UseStation(localPlayer);
            Check(stationEnters == 1, "OnStationEntered dispatched to the station's behaviour");
            station.ExitStation(localPlayer);

            // object sync
            VRCObjectSync sync = syncedObj.GetComponent<VRCObjectSync>();
            Check(sync != null, "VRCObjectSync component");
            syncedObj.transform.position = new Vector3(9, 9, 9);
            sync.Respawn();
            Check(syncedObj.transform.position.magnitude < 0.01f, "VRCObjectSync.Respawn restores spawn transform");
            sync.FlagDiscontinuity();
            sync.SetKinematic(true);
            sync.SetGravity(false);
            sync.TeleportTo(other.transform);

            // object pool
            VRCObjectPool pool = poolObj.GetComponent<VRCObjectPool>();
            Check(pool != null && pool.Pool.Length == 2, "VRCObjectPool with 2 children: " + (pool != null ? pool.Pool.Length : -1));
            GameObject a = pool.TryToSpawn();
            GameObject b = pool.TryToSpawn();
            GameObject c = pool.TryToSpawn();
            Check(a != null && b != null && c == null && a != b, "pool spawns two then null");
            Check(a.activeSelf, "spawned object active");
            pool.Return(a);
            Check(!a.activeSelf && pool.TryToSpawn() == a, "Return then respawn same object");
            pool.Shuffle();

            // player data
            PlayerData.SetInt("score", 12);
            PlayerData.SetString("name", "bob");
            PlayerData.SetVector3("pos", Vector3.one);
            Check(PlayerData.GetInt(localPlayer, "score") == 12 && PlayerData.GetString(localPlayer, "name") == "bob", "PlayerData set/get");
            Check(PlayerData.HasKey(localPlayer, "score") && !PlayerData.HasKey(localPlayer, "nope"), "PlayerData.HasKey");
            int sc;
            Check(PlayerData.TryGetInt(localPlayer, "score", out sc) && sc == 12, "PlayerData.TryGetInt");
            Check(PlayerData.GetVector3(localPlayer, "pos") == Vector3.one, "PlayerData vector");
            PlayerData.SetByte("lives", 3);
            byte lives;
            Check(PlayerData.TryGetByte(localPlayer, "lives", out lives) && lives == 3, "PlayerData.TryGetByte");
            string[] keys = PlayerData.GetKeys(localPlayer);
            Check(keys.Length >= 4, "PlayerData.GetKeys: " + keys.Length);
            Check(PlayerData.IsType(localPlayer, "name", typeof(string)), "PlayerData.IsType");
            Check(NetworkStats.RoundTripTime >= 0 && NetworkStats.TimeInRoom >= 0f && NetworkStats.TotalBytes(localPlayer) >= 0 && !NetworkStats.Sleeping(gameObject), "NetworkStats per-object stats");
            MidiBlock block = new MidiBlock();
            block.startTimeMs = 500f;
            block.endTimeMs = 1500f;
            block.note = 60;
            Check(Near(block.lengthSec, 1f) && Near(block.startTimeSec, 0.5f) && block.note == 60, "MidiBlock timing");
            PlayerData.Remove("score");
            Check(!PlayerData.HasKey(localPlayer, "score"), "PlayerData.Remove");

            // input
            Check(!Input.GetKey(KeyCode.Space) && !Input.GetKeyDown(KeyCode.E) && !Input.GetMouseButton(0), "Input keys idle");
            Check(Near(Input.GetAxis("Horizontal"), 0f), "Input axis idle");
            Check(!InputManager.IsUsingHandController(), "InputManager");

            // misc
            Check(Time.time >= startTime && Time.frameCount >= startFrame, "Time progressed since Start");
            Check(NetworkCalling.CallingPlayer == null, "CallingPlayer null outside network call");
            done = true;
        }

        public void OnCustom() { customEvents++; }
        public void OnDelayed() { delayedEvents++; }

        [NetworkCallable]
        public void OnNet(int n, string tag)
        {
            networkEvents++;
            netArgSum += n;
            if (NetworkCalling.InNetworkCall && NetworkCalling.CallingPlayer == Networking.LocalPlayer) sawNetworkCallContext = true;
        }

        public override void OnDeserialization() { deserializations++; }
        public override void OnStationEntered(VRCPlayerApi player) { stationEnters++; }
        public override void OnPlayerJoined(VRCPlayerApi player) { joins++; joinedName = player.displayName; }

        /// Runner calls this after a few frames and after adding a remote player to the provider.
        public void AfterFrames()
        {
            Check(delayedEvents == 2, "delayed events fired (frames + seconds): " + delayedEvents);
            Check(deserializations >= 1, "OnDeserialization ran after RequestSerialization (loopback): " + deserializations);
            Check(healthCallbacks >= 2, "FieldChangeCallback invoked by deserialization: " + healthCallbacks);
            Check(joins >= 2 && joinedName == "Remote", "OnPlayerJoined for a joining remote player: " + joins + " " + joinedName);
            Check(VRCPlayerApi.GetPlayerCount() == 2, "player count after join");
        }
    }
}
