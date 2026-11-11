package main

import "core:fmt"
import "core:strings"
import "term"
import "vendor:glfw"

GAP :: 2

// binary layout tree; leaves own a pane
Node :: struct {
	parent:     ^Node,
	pane:       ^Pane,
	stack:      bool, // children laid out top and bottom
	ratio:      f32,
	kids:       [2]^Node,
	x, y, w, h: int,
}

Tab :: struct {
	root:  ^Node,
	focus: ^Node,
}

Workspace :: struct {
	tabs: [dynamic]^Tab,
	cur:  int,
}

Dir :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

cur_space :: proc(app: ^App) -> ^Workspace {
	if len(app.spaces) == 0 do return nil
	return app.spaces[app.space]
}

cur_tab :: proc(app: ^App) -> ^Tab {
	ws := cur_space(app)
	if ws == nil || len(ws.tabs) == 0 do return nil
	return ws.tabs[ws.cur]
}

focused :: proc(app: ^App) -> ^Pane {
	t := cur_tab(app)
	if t == nil || t.focus == nil do return nil
	return t.focus.pane
}

leaves :: proc(n: ^Node, out: ^[dynamic]^Node) {
	if n == nil do return
	if n.pane != nil {
		append(out, n)
		return
	}
	leaves(n.kids[0], out)
	leaves(n.kids[1], out)
}

// every pane in every workspace, valid until the next tree change
all_panes :: proc(app: ^App) -> []^Pane {
	nodes := make([dynamic]^Node, context.temp_allocator)
	for ws in app.spaces do for t in ws.tabs do leaves(t.root, &nodes)
	out := make([]^Pane, len(nodes), context.temp_allocator)
	for n, i in nodes do out[i] = n.pane
	return out
}

tab_panes :: proc(t: ^Tab) -> []^Node {
	nodes := make([dynamic]^Node, context.temp_allocator)
	leaves(t.root, &nodes)
	return nodes[:]
}

show_tab_bar :: proc(app: ^App) -> bool {
	return len(app.spaces) > 1 || (cur_space(app) != nil && len(cur_space(app).tabs) > 1)
}

bar_height :: proc(app: ^App) -> int {
	return app.f.cell_h + 4 if show_tab_bar(app) else 0
}

// size a new pane will get when it replaces the whole tab area
tab_area :: proc(app: ^App) -> (x, y, w, h: int) {
	fw, fh := glfw.GetFramebufferSize(app.win)
	bh := bar_height(app)
	return 0, bh, int(fw), int(fh) - bh
}

make_leaf :: proc(app: ^App, w, h: int, cwd := "") -> ^Node {
	cols := max((w - 2 * PAD) / app.f.cell_w, 1)
	rows := max((h - 2 * PAD) / app.f.cell_h, 1)
	p := pane_open(app, cols, rows, cwd)
	if p == nil do return nil
	n := new(Node)
	n.pane = p
	p.node = n
	return n
}

focused_cwd :: proc(app: ^App) -> string {
	p := focused(app)
	if p == nil do return ""
	return term.pty_cwd(p.pty, context.temp_allocator)
}

new_tab :: proc(app: ^App) -> bool {
	ws := cur_space(app)
	if ws == nil do return false
	cwd := focused_cwd(app)
	// the bar may appear with the second tab
	append(&ws.tabs, new(Tab))
	_, _, w, h := tab_area(app)
	n := make_leaf(app, w, h, cwd)
	if n == nil {
		free(pop(&ws.tabs))
		return false
	}
	t := ws.tabs[len(ws.tabs) - 1]
	t.root = n
	t.focus = n
	ws.cur = len(ws.tabs) - 1
	layout(app)
	return true
}

new_workspace :: proc(app: ^App) -> bool {
	cwd := focused_cwd(app)
	append(&app.spaces, new(Workspace))
	app.space = len(app.spaces) - 1
	ws := app.spaces[app.space]
	_, _, w, h := tab_area(app)
	n := make_leaf(app, w, h, cwd)
	if n == nil {
		free(pop(&app.spaces))
		app.space = max(len(app.spaces) - 1, 0)
		return false
	}
	t := new(Tab)
	t.root = n
	t.focus = n
	append(&ws.tabs, t)
	layout(app)
	return true
}

split :: proc(app: ^App, stack: bool) {
	t := cur_tab(app)
	if t == nil || t.focus == nil do return
	old := t.focus
	w := old.w / 2 if !stack else old.w
	h := old.h / 2 if stack else old.h
	n := make_leaf(app, w, h, focused_cwd(app))
	if n == nil do return
	// the old leaf becomes the first child of a new split node
	parent := new(Node)
	parent.parent = old.parent
	parent.stack = stack
	parent.ratio = 0.5
	parent.kids = {old, n}
	if old.parent == nil {
		t.root = parent
	} else {
		k := 0 if old.parent.kids[0] == old else 1
		old.parent.kids[k] = parent
	}
	old.parent = parent
	n.parent = parent
	t.focus = n
	layout(app)
}

// detaches a pane's leaf from its tab and frees the pane; empty tabs and workspaces go too
remove_pane :: proc(app: ^App, p: ^Pane) {
	n := p.node
	for ws, wi in app.spaces {
		for t, ti in ws.tabs {
			found := false
			for l in tab_panes(t) do if l == n do found = true
			if !found do continue
			if n.parent == nil {
				t.root = nil
				t.focus = nil
				free(t)
				ordered_remove(&ws.tabs, ti)
				ws.cur = clamp(ws.cur, 0, max(len(ws.tabs) - 1, 0))
			} else {
				parent := n.parent
				sib := parent.kids[1] if parent.kids[0] == n else parent.kids[0]
				sib.parent = parent.parent
				if parent.parent == nil {
					t.root = sib
				} else {
					k := 0 if parent.parent.kids[0] == parent else 1
					parent.parent.kids[k] = sib
				}
				free(parent)
				if t.focus == n {
					first := sib
					for first.pane == nil do first = first.kids[0]
					t.focus = first
				}
			}
			if len(ws.tabs) == 0 {
				free(ws)
				ordered_remove(&app.spaces, wi)
				app.space = clamp(app.space, 0, max(len(app.spaces) - 1, 0))
			}
			if app.drag == p do app.drag = nil
			pane_close(app, p)
			free(n)
			layout(app)
			return
		}
	}
}

close_tab :: proc(app: ^App) {
	t := cur_tab(app)
	if t == nil do return
	for l in tab_panes(t) do remove_pane(app, l.pane)
}

close_workspace :: proc(app: ^App) {
	ws := cur_space(app)
	if ws == nil do return
	for len(app.spaces) > 0 && cur_space(app) == ws {
		close_tab(app)
	}
}

layout_node :: proc(app: ^App, n: ^Node, x, y, w, h: int) {
	n.x, n.y, n.w, n.h = x, y, w, h
	if n.pane != nil {
		pane_layout(app, n.pane, x, y, w, h)
		return
	}
	if n.stack {
		h0 := max(int(f32(h - GAP) * n.ratio), 1)
		layout_node(app, n.kids[0], x, y, w, h0)
		layout_node(app, n.kids[1], x, y + h0 + GAP, w, max(h - h0 - GAP, 1))
	} else {
		w0 := max(int(f32(w - GAP) * n.ratio), 1)
		layout_node(app, n.kids[0], x, y, w0, h)
		layout_node(app, n.kids[1], x + w0 + GAP, y, max(w - w0 - GAP, 1), h)
	}
}

layout :: proc(app: ^App) {
	app.dirty = true
	t := cur_tab(app)
	if t == nil || t.root == nil do return
	x, y, w, h := tab_area(app)
	layout_node(app, t.root, x, y, w, h)
	update_title(app)
}

update_title :: proc(app: ^App) {
	p := focused(app)
	title := "votty"
	if p != nil && len(p.vt.title) > 0 do title = string(p.vt.title[:])
	glfw.SetWindowTitle(app.win, strings.clone_to_cstring(title, context.temp_allocator))
}

// the closest pane whose edge touches the focused one in a direction
move_focus :: proc(app: ^App, d: Dir) {
	t := cur_tab(app)
	if t == nil || t.focus == nil do return
	f := t.focus
	best: ^Node
	best_dist, best_overlap := max(int), -1
	for c in tab_panes(t) {
		if c == f do continue
		dist, overlap: int
		switch d {
		case .Left:
			dist = f.x - (c.x + c.w)
			overlap = min(f.y + f.h, c.y + c.h) - max(f.y, c.y)
		case .Right:
			dist = c.x - (f.x + f.w)
			overlap = min(f.y + f.h, c.y + c.h) - max(f.y, c.y)
		case .Up:
			dist = f.y - (c.y + c.h)
			overlap = min(f.x + f.w, c.x + c.w) - max(f.x, c.x)
		case .Down:
			dist = c.y - (f.y + f.h)
			overlap = min(f.x + f.w, c.x + c.w) - max(f.x, c.x)
		}
		if dist < 0 || overlap <= 0 do continue
		if dist < best_dist || (dist == best_dist && overlap > best_overlap) {
			best, best_dist, best_overlap = c, dist, overlap
		}
	}
	if best != nil do focus_node(app, best)
}

focus_node :: proc(app: ^App, n: ^Node) {
	t := cur_tab(app)
	if t == nil || t.focus == n do return
	// panes that asked for focus reports learn about the change
	if t.focus != nil && .Focus_Events in t.focus.pane.vt.modes do term.pty_write(t.focus.pane.pty, transmute([]u8)string("\x1b[O"))
	if .Focus_Events in n.pane.vt.modes do term.pty_write(n.pane.pty, transmute([]u8)string("\x1b[I"))
	t.focus = n
	update_title(app)
	app.dirty = true
}

// moves the nearest divider of the matching orientation
resize_split :: proc(app: ^App, d: Dir) {
	t := cur_tab(app)
	if t == nil || t.focus == nil do return
	stack := d == .Up || d == .Down
	for n := t.focus.parent; n != nil; n = n.parent {
		if n.stack != stack do continue
		delta: f32 = 0.05 if d == .Right || d == .Down else -0.05
		n.ratio = clamp(n.ratio + delta, 0.1, 0.9)
		layout(app)
		return
	}
}

switch_tab :: proc(app: ^App, i: int) {
	ws := cur_space(app)
	if ws == nil || len(ws.tabs) == 0 do return
	ws.cur = (i + len(ws.tabs)) % len(ws.tabs)
	layout(app)
}

switch_space :: proc(app: ^App, i: int) {
	if len(app.spaces) == 0 do return
	app.space = (i + len(app.spaces)) % len(app.spaces)
	layout(app)
}

pane_at :: proc(app: ^App, x, y: int) -> ^Node {
	t := cur_tab(app)
	if t == nil do return nil
	for n in tab_panes(t) {
		if x >= n.x && x < n.x + n.w && y >= n.y && y < n.y + n.h do return n
	}
	return nil
}

Tab_Hit :: struct {
	x0, x1: f32,
	tab:    int,
}

draw_tab_bar :: proc(app: ^App) {
	clear(&app.tab_hits)
	if !show_tab_bar(app) do return
	r := &app.r
	f := &app.f
	fw, _ := glfw.GetFramebufferSize(app.win)
	h := f32(bar_height(app))
	push_rect(r, 0, 0, f32(fw), h, pack(0x25272c, 1))
	ws := cur_space(app)
	labels := make([dynamic]string, context.temp_allocator)
	for t, i in ws.tabs {
		title := "shell"
		if t.focus != nil && len(t.focus.pane.vt.title) > 0 do title = string(t.focus.pane.vt.title[:])
		if len(title) > 24 do title = title[:24]
		append(&labels, fmt.tprintf(" %d %s ", i + 1, title))
	}
	space := fmt.tprintf(" workspace %d/%d ", app.space + 1, len(app.spaces))
	x: f32 = 0
	for l, i in labels {
		w := f32(text_width(f, l))
		if i == ws.cur do push_rect(r, x, 0, w, h, pack(0x3d4350, 1))
		append(&app.tab_hits, Tab_Hit{x, x + w, i})
		x += w + 1
	}
	sx := f32(int(fw) - text_width(f, space))
	push_rect(r, sx, 0, f32(text_width(f, space)), h, pack(0x34495e, 1))
	flush_rects(r, .Solid)
	x = 0
	for l, i in labels {
		color := pack(0xffffff, 1) if i == ws.cur else pack(0x9099a8, 1)
		x = draw_text(r, f, x, 2, l, color, sx) + 1
	}
	draw_text(r, f, sx, 2, space, pack(0xd0d8e0, 1))
	flush_rects(r, .Glyph, f.tex)
}

draw_borders :: proc(app: ^App) {
	t := cur_tab(app)
	if t == nil do return
	nodes := tab_panes(t)
	if len(nodes) < 2 do return
	r := &app.r
	no_clip(r)
	for n in nodes {
		if n == t.focus do continue
		push_rect(r, f32(n.x), f32(n.y), f32(n.w), f32(n.h), pack(0x000000, 0.18))
	}
	// gaps between panes double as dividers
	f := t.focus
	c := pack(0x5577aa, 1)
	push_rect(r, f32(f.x), f32(f.y), f32(f.w), 1, c)
	push_rect(r, f32(f.x), f32(f.y + f.h - 1), f32(f.w), 1, c)
	push_rect(r, f32(f.x), f32(f.y), 1, f32(f.h), c)
	push_rect(r, f32(f.x + f.w - 1), f32(f.y), 1, f32(f.h), c)
	flush_rects(r, .Solid)
}
