## Guribo's UdonUtils (TLP) RuntimeTestingExample: the package's own TestController runs the test
## cases of the scene inside the imported world; the scenario starts the run and reports what the
## package's tests say. TestCaseStatus: 0 Ready, 1 Running, 2 Passed, 3 Failed, 4 NotRun.
extends RefCounted

const STATUS := ["Ready", "Running", "Passed", "Failed", "NotRun"]

func _tests(r) -> Array:
	var out: Array = []
	for n in r._all(r.root):
		if n.has_method("udon_class_chain") and n.udon_class_chain().has("TestCase"):
			out.append(n)
	return out

func run(r) -> void:
	await r.wait(60)
	var controllers: Array = []
	for n in r._all(r.root):
		if n.has_meta("udon_class") and str(n.get_meta("udon_class")) == "TestController":
			controllers.append(n)
	r.check(controllers.size() >= 1, "TestController behaviours in the scene: %d" % controllers.size())
	var tests: Array = _tests(r)
	r.check(tests.size() >= 1, "test cases found: %d" % tests.size())
	if controllers.is_empty() or tests.is_empty():
		return
	for tc in controllers:
		print("[scenario] starting ", tc.get_path())
		tc._StartTestRun()
	# the controller advances one step per Update; tests may wait for network round trips
	var t0: int = Time.get_ticks_msec()
	var done: bool = false
	while Time.get_ticks_msec() - t0 < 60000 and not done:
		await r.wait(30)
		done = true
		for t in tests:
			var st: int = int(t.get_Status()) if t.has_method("get_Status") else int(t.get("Status"))
			if st == 0 or st == 1:
				done = false
	var passed: int = 0
	var failed: int = 0
	var other: int = 0
	for t in tests:
		var st: int = int(t.get_Status()) if t.has_method("get_Status") else int(t.get("Status"))
		print("[scenario] %-40s %s" % [str(t.name), STATUS[clampi(st, 0, 4)]])
		if st == 2:
			passed += 1
		elif st == 3:
			failed += 1
		else:
			other += 1
	print("[scenario] package tests: %d passed, %d failed, %d not finished" % [passed, failed, other])
	r.check(passed >= 1, "at least one of the package's own tests passes: %d" % passed)
	r.check(other == 0, "every test reached a verdict within a minute: %d did not" % other)
	await r.shot("udonutils_tests")
