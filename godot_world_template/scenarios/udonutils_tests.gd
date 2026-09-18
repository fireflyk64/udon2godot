## Guribo's UdonUtils (TLP) RuntimeTestingExample: the package's own TestController runs the test
## cases of the scene inside the imported world; the scenario starts the runs and holds the
## package's verdicts against what a single player can expect.
## TestCaseStatus: 0 Ready, 1 Running, 2 Passed, 3 Failed, 4 NotRun.
extends RefCounted

const STATUS := ["Ready", "Running", "Passed", "Failed", "NotRun"]

## Tests that need a second player in the instance; their own message says so.
const TWO_PLAYERS := ["TestNetworkEvents", "OwnershipTransfer", "MaxSendRate"]

func _tests(r) -> Array:
	var out: Array = []
	for n in r._all(r.root):
		if n.has_method("udon_class_chain") and n.udon_class_chain().has("TestCase"):
			out.append(n)
	return out

func _needs_two_players(test_name: String) -> bool:
	for prefix in TWO_PLAYERS:
		if test_name.begins_with(prefix):
			return true
	return false

func run(r):
	await r.wait(60)
	var udon: Node = r.root.get_node("/root/Udon")
	# `--player-data <file>`: a first visit starts without the file, a later one finds what the
	# first stored (TestPlayerDataPersistence is about exactly that: "please rejoin the world")
	var data_file: String = udon.provider.player_data_file
	var revisit: bool = data_file != "" and not udon.provider.load_variant_file(data_file).is_empty() and udon.provider.player_data_get(udon.local_player(), "TLP/PersistenceTest/visits", -1) != -1
	var controllers: Array = []
	for n in r._all(r.root):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "TestController":
			controllers.append(n)
	r.check(controllers.size() == 2, "TestController behaviours in the scene: %d" % controllers.size())
	var tests: Array = _tests(r)
	r.check(tests.size() == 17, "test cases found: %d" % tests.size())
	if controllers.is_empty() or tests.is_empty():
		return true
	for tc in controllers:
		print("[scenario] starting ", tc.get_path())
		tc._StartTestRun()
	# the controller advances one step per Update
	var t0: int = Time.get_ticks_msec()
	var done: bool = false
	while Time.get_ticks_msec() - t0 < 60000 and not done:
		await r.wait(30)
		done = true
		for t in tests:
			var st: int = int(t.get("Status"))
			if st == 0 or st == 1:
				done = false
	var passed: int = 0
	var failed: int = 0
	var other: int = 0
	var wrong: Array = []
	var first_persistence: bool = true
	for t in tests:
		var st: int = int(t.get("Status"))
		var test_name: String = str(t.name)
		print("[scenario] %-40s %s" % [test_name, STATUS[clampi(st, 0, 4)]])
		if st == 2:
			passed += 1
		elif st == 3:
			failed += 1
		else:
			other += 1
		var expect_pass: bool = not _needs_two_players(test_name)
		if test_name == "TestPlayerDataPersistence" and first_persistence:
			# the first one to run reads what an earlier visit stored; the second one of the scene
			# already finds what the first wrote
			first_persistence = false
			expect_pass = revisit
		if (st == 2) != expect_pass:
			wrong.append("%s: %s" % [test_name, STATUS[clampi(st, 0, 4)]])
	print("[scenario] package tests: %d passed, %d failed, %d not finished (%s)" % [passed, failed, other, "revisit" if revisit else "first visit"])
	r.check(other == 0, "every test reached a verdict within a minute: %d did not" % other)
	r.check(wrong.is_empty(), "single-player tests pass, two-player tests say they need two players: " + str(wrong))
	r.check(passed == (8 if revisit else 7), "package tests passed: %d" % passed)
	# the visit counter this scenario keeps in the same store as the package
	var visits: int = int(udon.provider.player_data_get(udon.local_player(), "TLP/PersistenceTest/visits", 0))
	udon.provider.player_data_set("TLP/PersistenceTest/visits", visits + 1)
	await r.wait(3)
	if data_file != "":
		r.check(int(udon.provider.load_variant_file(data_file).get("TLP/PersistenceTest/visits", 0)) == visits + 1, "PlayerData reaches the file: visit %d" % (visits + 1))
	await r.shot("udonutils_tests")
	return true
