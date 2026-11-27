package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"
import "core:unicode/utf8"
import "term"
import "vendor:glfw"

CARD_W :: 360

Overview :: struct {
	open:      bool,
	sel:       ^Workspace,
	pan:       [2]f32, // framebuffer pixels
	zoom:      f32,
	target:    Target,
	drag:      enum u8 {
		None,
		Node,
		Pan,
	},
	grab:      [2]f32, // mouse position when the drag began
	grab_pos:  [2]f32, // node position or pan when the drag began
	moved:     bool,
	click_at:  f64,
	renaming:  bool, // editing text: a node name, or an after edge command
	fresh:     bool, // the first typed char replaces the old name
	link:      struct {
		active: bool,
		kind:   Edge_Kind,
		from:   int,
		to:     int, // target waiting for its command
	},
	edit:      [dynamic]u8,
	close_at:  time.Tick, // first press of a two step close
}

overview_free :: proc(app: ^App) {
	target_free(&app.ov.target)
	delete(app.ov.edit)
}

ov_scale :: proc(app: ^App) -> f32 {return app.ov.zoom * app.scale}

// card rectangle in framebuffer pixels and the height of its thumbnail
card_rect :: proc(app: ^App, ws: ^Workspace) -> (x, y, w, h, thumb: f32) {
	s := ov_scale(app)
	fw, fh := glfw.GetFramebufferSize(app.win)
	w = CARD_W * s
	thumb = w * f32(fh) / f32(max(fw, 1))
	h = f32(app.f.cell_h + 8) + thumb + f32(app.f.cell_h + 6)
	x = ws.pos.x * s + app.ov.pan.x
	y = ws.pos.y * s + app.ov.pan.y
	return
}

overview_toggle :: proc(app: ^App) {
	ov := &app.ov
	if ov.open {
		ov.open = false
		ov.renaming = false
		layout(app)
		return
	}
	if ov.zoom == 0 do ov.zoom = 1
	ov.open = true
	ov.sel = cur_space(app)
	ov.drag = .None
	fit_all(app)
	app.dirty = true
}

center_on :: proc(app: ^App, ws: ^Workspace) {
	fw, fh := glfw.GetFramebufferSize(app.win)
	_, _, w, h, _ := card_rect(app, ws)
	s := ov_scale(app)
	app.ov.pan = {f32(fw) / 2 - ws.pos.x * s - w / 2, f32(fh) / 2 - ws.pos.y * s - h / 2}
}

open_node :: proc(app: ^App, ws: ^Workspace) {
	i := space_index(app, ws)
	if i < 0 do return
	app.ov.open = false
	app.ov.renaming = false
	switch_space(app, i)
}

// the node nearest to the selection in a direction
step_selection :: proc(app: ^App, d: Dir) {
	sel := app.ov.sel
	if sel == nil {
		if len(app.spaces) > 0 do app.ov.sel = app.spaces[0]
		return
	}
	dirs := [Dir][2]f32 {
		.Left  = {-1, 0},
		.Right = {1, 0},
		.Up    = {0, -1},
		.Down  = {0, 1},
	}
	v := dirs[d]
	best: ^Workspace
	best_score := f32(math.F32_MAX)
	for ws in app.spaces {
		if ws == sel do continue
		dx, dy := ws.pos.x - sel.pos.x, ws.pos.y - sel.pos.y
		along := dx * v.x + dy * v.y
		if along <= 0 do continue
		across := abs(dx * v.y - dy * v.x)
		// prefer nodes straight ahead
		score := along + 2 * across
		if score < best_score do best, best_score = ws, score
	}
	if best != nil do app.ov.sel = best
}

close_space :: proc(app: ^App, ws: ^Workspace) {
	cur := cur_space(app)
	i := space_index(app, ws)
	if i < 0 do return
	app.space = i
	close_workspace(app)
	if cur != ws {
		if j := space_index(app, cur); j >= 0 do app.space = j
	}
	layout(app)
}

status_label :: proc(app: ^App, ws: ^Workspace) -> (text: string, color: u32) {
	st, _ := space_status(ws)
	switch st {
	case .Waiting:
		return "● needs you", 0xf0a030
	case .Running:
		return "● running", 0x6ab0f3
	case .Done:
		return fmt.tprintf("✓ %s", short_duration(ws.duration)), 0x7ec87a
	case .Failed:
		return fmt.tprintf("✗ exit %d", ws.exit_code), 0xe06060
	case .Idle:
	}
	return "idle", 0x8a93a3
}

short_duration :: proc(d: time.Duration) -> string {
	ms := int(d / time.Millisecond)
	switch {
	case ms < 100:
		return "<0.1s"
	case ms < 60_000:
		return fmt.tprintf("%.1fs", f64(ms) / 1000)
	}
	return fmt.tprintf("%dm%02ds", ms / 60_000, ms / 1000 % 60)
}

// zooms and pans so every node is on screen
fit_all :: proc(app: ^App) {
	if len(app.spaces) == 0 do return
	fw, fh := glfw.GetFramebufferSize(app.win)
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	app.ov.zoom = 1
	app.ov.pan = {}
	for ws in app.spaces {
		_, _, w, h, _ := card_rect(app, ws)
		s := ov_scale(app)
		lo = {min(lo.x, ws.pos.x), min(lo.y, ws.pos.y)}
		hi = {max(hi.x, ws.pos.x + w / s), max(hi.y, ws.pos.y + h / s)}
	}
	size := hi - lo
	avail := [2]f32{f32(fw) * 0.9, f32(int(fh) - app.f.cell_h - 6) * 0.9}
	app.ov.zoom = clamp(min(avail.x / (size.x * app.scale), avail.y / (size.y * app.scale)), 0.3, 1)
	s := ov_scale(app)
	app.ov.pan = {(f32(fw) - size.x * s) / 2 - lo.x * s, (f32(int(fh) - app.f.cell_h - 6) - size.y * s) / 2 - lo.y * s}
}

draw_overview :: proc(app: ^App, w, h: int) {
	r := &app.r
	f := &app.f
	ov := &app.ov
	begin_frame(r, w, h, 0x121317)
	// dotted canvas that moves with the pan
	step := 40 * ov_scale(app)
	if step >= 8 {
		ox := math.mod(ov.pan.x, step)
		oy := math.mod(ov.pan.y, step)
		for y := oy; y < f32(h); y += step do for x := ox; x < f32(w); x += step do push_rect(r, x, y, 2, 2, pack(0x2a2d35, 1))
		flush_rects(r, .Solid)
	}
	labels := make([dynamic]Edge_Label, context.temp_allocator)
	draw_edges(app, &labels)
	for ws in app.spaces do draw_card(app, ws, w, h)
	draw_edge_labels(app, labels[:])
	// key help along the bottom
	help := "enter open · n new · w worktree · r rename · p pipe · a after · u unlink · s send · x close · esc"
	if ov.renaming do help = "type a command  enter link  esc cancel" if ov.link.to != 0 else "type a name  enter save  esc cancel"
	if ov.link.active do help = "pick the target with the arrows  enter link  esc cancel"
	bh := f32(f.cell_h + 6)
	push_rect(r, 0, f32(h) - bh, f32(w), bh, pack(0x1c1e24, 0.95))
	flush_rects(r, .Solid)
	draw_text(r, f, f32(PAD * 2), f32(h) - bh + 3, help, pack(0x8a93a3, 1))
	flush_glyphs(r, f)
}

draw_card :: proc(app: ^App, ws: ^Workspace, w, h: int) {
	r := &app.r
	f := &app.f
	ov := &app.ov
	x, y, cw, ch, thumb := card_rect(app, ws)
	if x > f32(w) || y > f32(h) || x + cw < 0 || y + ch < 0 do return
	st, progress := space_status(ws)
	selected := ov.sel == ws
	head := f32(f.cell_h + 8)

	// live picture of the node's current tab, rendered at full size then mipmapped down
	if t := ws.tabs[ws.cur]; t != nil && t.root != nil {
		tx, ty, tw, th := tab_area(app)
		layout_node(app, t.root, tx, ty, tw, th)
		bg := t.focus.pane.vt.bg if t.focus != nil else app.cfg.bg
		target_begin(r, &ov.target, w, h, bg)
		r.opacity = 1
		for n in tab_panes(t) do draw_pane(app, n.pane, false)
		r.opacity = app.cfg.opacity
		target_end(r, &ov.target, w, h)
	}

	push_rect(r, x + 6, y + 8, cw, ch, pack(0x000000, 0.35))
	border := u32(0x3a3f4b)
	if st == .Waiting do border = 0xf0a030
	if selected do border = 0x6ab0f3
	bw := f32(3) if selected || st == .Waiting else 1
	push_rect(r, x - bw, y - bw, cw + 2 * bw, ch + 2 * bw, pack(border, 1))
	push_rect(r, x, y, cw, ch, pack(0x1d1f25, 1))
	push_rect(r, x, y, cw, head, pack(0x262932, 1))
	flush_rects(r, .Solid)
	// texture rows run bottom up
	append(&r.rects, Rect{x, y + head, cw, thumb, 0, 1, 1, 0, 0xffffffff})
	flush_rects(r, .Premultiplied, ov.target.tex)
	if progress.state != 0 {
		pc := f32(progress.percent) / 100 if progress.state != 3 else 1
		color := u32(0x6ab0f3)
		if progress.state == 2 do color = 0xe06060
		if progress.state == 4 do color = 0xf0a030
		push_rect(r, x, y + head, cw * pc, 3, pack(color, 1))
		flush_rects(r, .Solid)
	}

	label, lcolor := status_label(app, ws)
	lx := x + cw - f32(text_width(f, label)) - 8
	name := string(ov.edit[:]) if selected && ov.renaming else string(ws.name[:])
	nx := draw_text(r, f, x + 8, y + 4, fmt.tprintf("%d  ", ws.id), pack(0x6b7280, 1), lx)
	nx = draw_text(r, f, nx, y + 4, name, pack(0xe6e8ee, 1), lx - 8)
	caret := nx
	draw_text(r, f, lx, y + 4, label, pack(lcolor, 1))
	// footer: the latest notification, else where the node is working
	foot := string(ws.note[:])
	if foot == "" {
		if t := ws.tabs[ws.cur]; t != nil && t.focus != nil {
			foot = term.pty_cwd(t.focus.pane.pty, context.temp_allocator)
			home := os_home()
			if home != "" && len(foot) >= len(home) && foot[:len(home)] == home do foot = fmt.tprintf("~%s", foot[len(home):])
		}
	}
	fy := y + head + thumb + 3
	tabs := fmt.tprintf("%d tab%s", len(ws.tabs), "" if len(ws.tabs) == 1 else "s")
	tx := x + cw - f32(text_width(f, tabs)) - 8
	draw_text(r, f, x + 8, fy, foot, pack(0xa0a7b4 if len(ws.note) == 0 else 0xf0c070, 1), tx - 8)
	draw_text(r, f, tx, fy, tabs, pack(0x6b7280, 1))
	flush_glyphs(r, f)
	if selected && ov.renaming {
		push_rect(r, caret, y + 4, 2, f32(f.cell_h), pack(0xffffff, 1))
		flush_rects(r, .Solid)
	}
}

os_home :: proc() -> string {
	return os.get_env("HOME", context.temp_allocator)
}

// keys while the overview is open; everything is consumed
overview_key :: proc(app: ^App, key: i32, m: term.Mods) {
	ov := &app.ov
	app.dirty = true
	if ov.renaming {
		switch key {
		case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
			if ov.link.to != 0 {
				if len(ov.edit) > 0 do add_edge(app, ov.link.from, ov.link.to, .After, string(ov.edit[:]))
				ov.link = {}
			} else if ov.sel != nil && len(ov.edit) > 0 {
				clear(&ov.sel.name)
				append(&ov.sel.name, ..ov.edit[:])
			}
			ov.renaming = false
		case glfw.KEY_ESCAPE:
			ov.renaming = false
			ov.link = {}
		case glfw.KEY_BACKSPACE:
			ov.fresh = false
			n := len(ov.edit)
			for n > 0 {
				n -= 1
				if ov.edit[n] & 0xc0 != 0x80 do break
			}
			resize(&ov.edit, n)
		}
		return
	}
	if ov.link.active && (key == glfw.KEY_ESCAPE || key == glfw.KEY_ENTER || key == glfw.KEY_KP_ENTER) {
		if key != glfw.KEY_ESCAPE do finish_link(app)
		ov.link.active = false
		return
	}
	action := lookup_binding(&app.cfg, key, m)
	if action == .Overview || key == glfw.KEY_ESCAPE {
		overview_toggle(app)
		return
	}
	if action == .Jump_Waiting {
		jump_waiting(app)
		return
	}
	sel := ov.sel
	moves := [4]i32{glfw.KEY_LEFT, glfw.KEY_RIGHT, glfw.KEY_UP, glfw.KEY_DOWN}
	for k, i in moves {
		if key != k do continue
		if .Shift in m && sel != nil {
			deltas := [4][2]f32{{-40, 0}, {40, 0}, {0, -40}, {0, 40}}
			sel.pos += deltas[i]
		} else {
			step_selection(app, Dir(i))
		}
		return
	}
	switch key {
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
		if sel != nil do open_node(app, sel)
	case glfw.KEY_TAB:
		if len(app.spaces) > 0 {
			i := space_index(app, sel) if sel != nil else -1
			ov.sel = app.spaces[(i + 1) % len(app.spaces)]
		}
	case glfw.KEY_N:
		if ws := new_workspace(app, activate = false); ws != nil {
			if sel != nil do ws.pos = sel.pos + {420, 0}
			ov.sel = ws
		}
	case glfw.KEY_W:
		// a new node on its own git worktree of the selected node's repository
		if sel == nil do return
		t := sel.tabs[sel.cur]
		if t == nil || t.focus == nil do return
		dir, err := make_worktree(term.pty_cwd(t.focus.pane.pty, context.temp_allocator), "")
		if err != "" {
			set_note(sel, err)
			return
		}
		if ws := new_workspace(app, dir, nil, filepath.base(dir), false); ws != nil {
			ws.pos = sel.pos + {0, 380}
			ov.sel = ws
		}
	case glfw.KEY_R:
		if sel != nil {
			ov.renaming = true
			ov.fresh = true
			clear(&ov.edit)
			append(&ov.edit, ..sel.name[:])
			app.skip_char = true
		}
	case glfw.KEY_P, glfw.KEY_A:
		// pick a target with the arrows, enter links it
		if sel == nil do return
		ov.link = {active = true, kind = .Pipe if key == glfw.KEY_P else .After, from = sel.id}
	case glfw.KEY_U:
		if sel != nil do remove_edges(app, sel.id, from_only = true)
	case glfw.KEY_S:
		if sel != nil do send_output(app, sel)
	case glfw.KEY_X, glfw.KEY_DELETE:
		// closing kills the shells, so it takes a second press
		if sel == nil do return
		if ov.close_at != {} && time.tick_since(ov.close_at) < 2 * time.Second {
			ov.close_at = {}
			close_space(app, sel)
			ov.sel = cur_space(app)
			if len(app.spaces) == 0 do ov.open = false
		} else {
			ov.close_at = time.tick_now()
			clear(&sel.note)
			append(&sel.note, "press x again to close this node")
		}
	}
}

overview_char :: proc(app: ^App, ch: rune) {
	if !app.ov.renaming do return
	if app.ov.fresh do clear(&app.ov.edit)
	app.ov.fresh = false
	b, n := utf8.encode_rune(ch)
	append(&app.ov.edit, ..b[:n])
	app.dirty = true
}

card_at :: proc(app: ^App, mx, my: f32) -> ^Workspace {
	#reverse for ws in app.spaces {
		x, y, w, h, _ := card_rect(app, ws)
		if mx >= x && mx < x + w && my >= y && my < y + h do return ws
	}
	return nil
}

overview_button :: proc(app: ^App, button, action: i32) {
	ov := &app.ov
	mx, my := mouse_px(app)
	m := [2]f32{f32(mx), f32(my)}
	app.dirty = true
	if button != glfw.MOUSE_BUTTON_LEFT do return
	if action == glfw.RELEASE {
		ov.drag = .None
		return
	}
	ws := card_at(app, m.x, m.y)
	now := glfw.GetTime()
	if ws != nil && ws == ov.sel && now - ov.click_at < 0.4 {
		open_node(app, ws)
		return
	}
	ov.click_at = now
	ov.grab = m
	ov.moved = false
	if ws != nil {
		ov.sel = ws
		ov.drag = .Node
		ov.grab_pos = ws.pos
	} else {
		ov.drag = .Pan
		ov.grab_pos = ov.pan
	}
}

overview_motion :: proc(app: ^App) {
	ov := &app.ov
	if ov.drag == .None do return
	mx, my := mouse_px(app)
	d := [2]f32{f32(mx), f32(my)} - ov.grab
	switch ov.drag {
	case .Node:
		if ov.sel != nil do ov.sel.pos = ov.grab_pos + d / ov_scale(app)
	case .Pan:
		ov.pan = ov.grab_pos + d
	case .None:
	}
	app.dirty = true
}

overview_scroll :: proc(app: ^App, dy: f64) {
	ov := &app.ov
	mx, my := mouse_px(app)
	old := ov_scale(app)
	ov.zoom = clamp(ov.zoom * (1.1 if dy > 0 else 1 / 1.1), 0.3, 2.5)
	k := ov_scale(app) / old
	// zoom around the mouse
	ov.pan = {f32(mx) - (f32(mx) - ov.pan.x) * k, f32(my) - (f32(my) - ov.pan.y) * k}
	app.dirty = true
}

// the next node that needs attention, after the current one
jump_waiting :: proc(app: ^App) {
	n := len(app.spaces)
	start := space_index(app, app.ov.sel if app.ov.open && app.ov.sel != nil else cur_space(app))
	for k in 1 ..= n {
		ws := app.spaces[(start + k) % n]
		if !ws.attention do continue
		if app.ov.open {
			app.ov.sel = ws
			center_on(app, ws)
			app.dirty = true
		} else {
			switch_space(app, (start + k) % n)
		}
		return
	}
}

Edge_Kind :: enum u8 {
	Pipe, // send output on request
	After, // run a command when the source succeeds
}

Edge :: struct {
	from, to: int, // node ids
	kind:     Edge_Kind,
	command:  [dynamic]u8,
}

add_edge :: proc(app: ^App, from, to: int, kind: Edge_Kind, command := "") -> bool {
	if from == to || space_of(app, from) == nil || space_of(app, to) == nil do return false
	for &e in app.edges {
		if e.from == from && e.to == to && e.kind == kind {
			clear(&e.command)
			append(&e.command, command)
			return true
		}
	}
	e := Edge{from = from, to = to, kind = kind}
	append(&e.command, command)
	append(&app.edges, e)
	app.dirty = true
	return true
}

// drops edges touching a node, or only those leaving it
remove_edges :: proc(app: ^App, id: int, from_only := false) {
	#reverse for &e, i in app.edges {
		if e.from == id || (!from_only && e.to == id) {
			delete(e.command)
			ordered_remove(&app.edges, i)
		}
	}
	app.dirty = true
}

edges_free :: proc(app: ^App) {
	for &e in app.edges do delete(e.command)
	delete(app.edges)
}

finish_link :: proc(app: ^App) {
	ov := &app.ov
	if ov.sel == nil || ov.sel.id == ov.link.from do return
	if ov.link.kind == .Pipe {
		add_edge(app, ov.link.from, ov.sel.id, .Pipe)
		return
	}
	// an after edge needs the command it will run
	ov.link.to = ov.sel.id
	ov.renaming = true
	ov.fresh = false
	clear(&ov.edit)
}

set_note :: proc(ws: ^Workspace, text: string) {
	clear(&ws.note)
	append(&ws.note, text)
}

// what a node offers downstream: its selection, else its last command output
node_output :: proc(ws: ^Workspace) -> string {
	t := ws.tabs[ws.cur]
	if t == nil || t.focus == nil do return ""
	p := t.focus.pane
	if p.sel.active do return term.selection_text(p.vt, p.sel.a, p.sel.b, context.temp_allocator)
	return term.last_output(p.vt, context.temp_allocator)
}

node_input :: proc(app: ^App, ws: ^Workspace, data: []u8) {
	t := ws.tabs[ws.cur]
	if t == nil || t.focus == nil do return
	term.pty_write(t.focus.pane.pty, data)
	app.dirty = true
}

// pastes a node's output into every node its pipe edges point at
send_output :: proc(app: ^App, ws: ^Workspace) {
	text := node_output(ws)
	if text == "" {
		set_note(ws, "nothing to send: select text or finish a command")
		return
	}
	sent := 0
	for e in app.edges {
		if e.from != ws.id || e.kind != .Pipe do continue
		dst := space_of(app, e.to)
		if dst == nil do continue
		t := dst.tabs[dst.cur]
		if t == nil || t.focus == nil do continue
		out := make([dynamic]u8, context.temp_allocator)
		term.encode_paste(t.focus.pane.vt, text, &out)
		node_input(app, dst, out[:])
		set_note(dst, fmt.tprintf("received %d bytes from %s", len(text), string(ws.name[:])))
		dst.attention = dst != cur_space(app) || app.ov.open
		sent += 1
	}
	set_note(ws, fmt.tprintf("sent to %d node%s", sent, "" if sent == 1 else "s") if sent > 0 else "no pipe edges from this node")
}

// a finished command starts the after edges of its node when it succeeded
run_after_edges :: proc(app: ^App, ws: ^Workspace, code: int) {
	if code != 0 do return
	for e in app.edges {
		if e.from != ws.id || e.kind != .After do continue
		dst := space_of(app, e.to)
		if dst == nil do continue
		cmd := fmt.tprintf("%s\r", string(e.command[:]))
		node_input(app, dst, transmute([]u8)cmd)
		set_note(dst, fmt.tprintf("started by %s", string(ws.name[:])))
	}
}

Edge_Label :: struct {
	x, y:  f32,
	text:  string,
	color: u32,
}

@(private = "file")
hits_card :: proc(app: ^App, skip_a, skip_b: ^Workspace, x0, y0, x1, y1: f32) -> bool {
	for c in app.spaces {
		if c == skip_a || c == skip_b do continue
		cx, cy, cw, ch, _ := card_rect(app, c)
		if min(x0, x1) < cx + cw && max(x0, x1) > cx && min(y0, y1) < cy + ch && max(y0, y1) > cy do return true
	}
	return false
}

// an elbow connector between two cards, routed over the top when a card is in the way
@(private = "file")
draw_connector :: proc(app: ^App, a, b: ^Workspace, color: u32) -> (lx, ly: f32) {
	r := &app.r
	s := ov_scale(app)
	th := max(2 * s, 1.5)
	ax, ay, aw, ah, _ := card_rect(app, a)
	bx, by, bw, bh, _ := card_rect(app, b)
	sx, sy := ax + aw, ay + ah / 2
	ex, ey := bx, by + bh / 2
	midx := (sx + ex) / 2
	if ex > sx && !hits_card(app, a, b, sx, sy, midx, sy + th) && !hits_card(app, a, b, midx, sy, midx + th, ey) && !hits_card(app, a, b, midx, ey, ex, ey + th) {
		push_rect(r, sx, sy - th / 2, midx - sx, th, color)
		push_rect(r, midx - th / 2, min(sy, ey) - th / 2, th, abs(ey - sy) + th, color)
		push_rect(r, midx, ey - th / 2, ex - midx, th, color)
		push_rect(r, ex - 5 * th, ey - 3 * th, 5 * th, 6 * th, color)
		// the label rides above the first segment so the line stays visible
		return (sx + midx) / 2, sy - f32(app.f.cell_h)
	}
	// over the top: up from the source, across above every card in between, down into the target
	sx, sy = ax + aw / 2, ay
	ex, ey = bx + bw / 2, by
	top := min(ay, by)
	for c in app.spaces {
		cx, cy, cw, _, _ := card_rect(app, c)
		if cx < max(sx, ex) && cx + cw > min(sx, ex) do top = min(top, cy)
	}
	top -= 28 * s
	push_rect(r, sx - th / 2, top, th, sy - top, color)
	push_rect(r, min(sx, ex) - th / 2, top - th / 2, abs(ex - sx) + th, th, color)
	push_rect(r, ex - th / 2, top, th, ey - top, color)
	push_rect(r, ex - 3 * th, ey - 5 * th, 6 * th, 5 * th, color)
	return (sx + ex) / 2, top - f32(app.f.cell_h) * 0.7
}

// connectors go under the cards, their labels on top
draw_edges :: proc(app: ^App, labels: ^[dynamic]Edge_Label) {
	r := &app.r
	ov := &app.ov
	for e in app.edges {
		a, b := space_of(app, e.from), space_of(app, e.to)
		if a == nil || b == nil do continue
		color := u32(0x6ab0f3) if e.kind == .Pipe else 0x7ec87a
		lx, ly := draw_connector(app, a, b, pack(color, 0.9))
		text := "pipe" if e.kind == .Pipe else fmt.tprintf("after: %s", string(e.command[:]))
		if len(text) > 32 do text = fmt.tprintf("%s…", text[:31])
		append(labels, Edge_Label{lx, ly, text, color})
	}
	// the edge being drawn follows the selection
	if ov.link.active {
		if a := space_of(app, ov.link.from); a != nil && ov.sel != nil && ov.sel != a {
			draw_connector(app, a, ov.sel, pack(0xf0c070, 0.9))
		}
	}
	flush_rects(r, .Solid)
}

draw_edge_labels :: proc(app: ^App, labels: []Edge_Label) {
	r := &app.r
	f := &app.f
	for l in labels {
		w := f32(text_width(f, l.text))
		push_rect(r, l.x - w / 2 - 5, l.y - f32(f.cell_h) / 2 - 2, w + 10, f32(f.cell_h) + 4, pack(0x121317, 0.95))
		push_rect(r, l.x - w / 2 - 5, l.y - f32(f.cell_h) / 2 - 2, w + 10, 1, pack(l.color, 0.6))
	}
	flush_rects(r, .Solid)
	for l in labels do draw_text(r, f, l.x - f32(text_width(f, l.text)) / 2, l.y - f32(f.cell_h) / 2, l.text, pack(l.color, 1))
	flush_glyphs(r, f)
}

card_w :: proc(app: ^App) -> f32 {return CARD_W * ov_scale(app)}
