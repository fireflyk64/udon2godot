## EmyChess (github.com/emymin/EmyChess, ExampleScene): both sides register, a standard game
## starts through the imported menu, legal moves go through the converted rules and illegal ones
## are rejected. Squares are (file, rank) from 0: white's e2 pawn is (4, 1).
extends RefCounted

func _move(r, piece: Node, x: int, y: int) -> void:
	# what VRC_Pickup does: OnPickup marks the legal squares, OnDrop lands on the nearest one
	piece.PiecePicked()
	await r.wait(3)
	piece.PieceDropped(x, y)
	await r.wait(8)

func run(r) -> void:
	await r.wait(30)
	var cm: Node = r.behaviour("ChessManager")
	var board: Node = r.behaviour("Board")
	r.check(cm != null and board != null, "ChessManager and Board behaviours present: %s %s" % [str(cm), str(board)])
	if cm == null or board == null:
		return
	r.check(board.get("currentRules") != null and board.get("chessManager") == cm, "Board references resolved (rules, manager)")
	# the menus hang on nodes of the FBX instances (UIHolder, TimerScreen)
	var start_btn: Node = r.find("StartButton")
	r.check(start_btn is BaseButton, "main menu imported under the model's UIHolder: " + str(start_btn))
	var placer: Node = r.behaviour("PiecePlacer")
	r.check(placer != null and placer.get("board") == board, "PiecePlacer.board set by a prefab-instance override: " + str(placer.get("board") if placer else null))
	cm._RegisterWhite()
	await r.wait(5)
	cm._RegisterBlack()
	await r.wait(5)
	r.check(cm.get("isWhiteRegistered") == true and cm.get("isBlackRegistered") == true, "both sides registered")
	# Start through the menu button when it is wired, the way a player would
	if start_btn is BaseButton:
		r.u().ui_press(start_btn)
		await r.wait(20)
	if cm.get("inProgress") != true:
		print("[scenario] StartButton did not start the game; calling _StartGame")
		cm._StartGame()
		await r.wait(20)
	r.check(cm.get("inProgress") == true and cm.get("currentSide") == true, "game in progress, white to move")
	r.check(int(board.GetPieceCount()) == 32, "32 pieces on the board: %d" % int(board.GetPieceCount()))
	var e2: Node = board.GetPiece(4, 1)
	r.check(e2 != null and str(e2.get("type")) == "pawn" and e2.get_white() == true, "white pawn on e2: " + str(e2.get("type") if e2 else null))
	var e8: Node = board.GetPiece(4, 7)
	r.check(e8 != null and str(e8.get("type")) == "king" and e8.get_white() == false, "black king on e8: " + str(e8.get("type") if e8 else null))
	if e2 == null:
		return
	# look at the board from white's side, above the table
	var bp: Vector3 = r.u().get_position(board)
	r._place_camera(r.u().to_gd_v(bp + Vector3(0.0, 0.75, -0.85)), r.u().to_gd_v(bp))
	await r.wait(2)
	await r.shot("start")
	# 1. e4
	var e2_pos: Vector3 = r.u().get_position(e2)
	await _move(r, e2, 4, 3)
	r.check(board.GetPiece(4, 3) == e2 and board.GetPiece(4, 1) == null and int(e2.get_x()) == 4 and int(e2.get_y()) == 3, "1. e4: the pawn is on e4 (%d, %d)" % [int(e2.get_x()), int(e2.get_y())])
	r.check(r.u().get_position(e2).distance_to(e2_pos) > 0.01, "the pawn's node moved with it")
	r.check(cm.get("currentSide") == false, "black to move after 1. e4")
	# illegal: the e7 pawn cannot jump three squares
	var e7: Node = board.GetPiece(4, 6)
	await _move(r, e7, 4, 3)
	r.check(board.GetPiece(4, 6) == e7 and board.GetPiece(4, 3) == e2 and cm.get("currentSide") == false, "illegal e7-e4 rejected, still black to move")
	# 1... e5
	await _move(r, e7, 4, 4)
	r.check(board.GetPiece(4, 4) == e7 and cm.get("currentSide") == true, "1... e5 played, white to move")
	# 2. Nf3, a knight jumps over the pawns
	var g1: Node = board.GetPiece(6, 0)
	r.check(g1 != null and str(g1.get("type")) == "knight", "white knight on g1")
	await _move(r, g1, 5, 2)
	r.check(board.GetPiece(5, 2) == g1 and cm.get("currentSide") == false, "2. Nf3")
	# 2... d5 and 3. exd5: a capture removes the pawn and scores for white
	var d7: Node = board.GetPiece(3, 6)
	await _move(r, d7, 3, 4)
	await _move(r, e2, 3, 4)
	r.check(board.GetPiece(3, 4) == e2 and int(board.GetPieceCount()) == 31, "3. exd5 captures: %d pieces left" % int(board.GetPieceCount()))
	r.check(int(cm.get("whiteScore")) > 0 and int(cm.get("blackScore")) == 0, "white scored the pawn: %s - %s" % [str(cm.get("whiteScore")), str(cm.get("blackScore"))])
	# a bishop cannot move through its own pawn
	var c8: Node = board.GetPiece(2, 7)
	await _move(r, c8, 0, 5)
	r.check(board.GetPiece(2, 7) == c8 and cm.get("currentSide") == false, "blocked bishop move rejected")
	await r.shot("after_moves")
	cm._EndGame()
	await r.wait(10)
	r.check(cm.get("inProgress") == false, "game ended")
