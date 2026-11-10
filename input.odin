package main

import "core:strings"
import "core:unicode/utf8"
import "term"
import "vendor:glfw"

app_of :: proc "contextless" (w: glfw.WindowHandle) -> ^App {
	return (^App)(glfw.GetWindowUserPointer(w))
}

to_mods :: proc "contextless" (m: i32) -> (out: term.Mods) {
	if m & glfw.MOD_SHIFT != 0 do out += {.Shift}
	if m & glfw.MOD_ALT != 0 do out += {.Alt}
	if m & glfw.MOD_CONTROL != 0 do out += {.Ctrl}
	if m & glfw.MOD_SUPER != 0 do out += {.Super}
	return
}

map_key :: proc(key: i32) -> term.Key {
	switch key {
	case glfw.KEY_ENTER:
		return .Enter
	case glfw.KEY_TAB:
		return .Tab
	case glfw.KEY_BACKSPACE:
		return .Backspace
	case glfw.KEY_ESCAPE:
		return .Escape
	case glfw.KEY_UP:
		return .Up
	case glfw.KEY_DOWN:
		return .Down
	case glfw.KEY_RIGHT:
		return .Right
	case glfw.KEY_LEFT:
		return .Left
	case glfw.KEY_HOME:
		return .Home
	case glfw.KEY_END:
		return .End
	case glfw.KEY_INSERT:
		return .Insert
	case glfw.KEY_DELETE:
		return .Delete
	case glfw.KEY_PAGE_UP:
		return .Page_Up
	case glfw.KEY_PAGE_DOWN:
		return .Page_Down
	case glfw.KEY_F1 ..= glfw.KEY_F12:
		return term.Key(int(term.Key.F1) + int(key - glfw.KEY_F1))
	case glfw.KEY_KP_0 ..= glfw.KEY_KP_EQUAL:
		return term.Key(int(term.Key.KP_0) + int(key - glfw.KEY_KP_0))
	}
	return .None
}

// the character a key produces in the active layout, used for ctrl combos
key_char :: proc(key, scancode: i32) -> rune {
	name := glfw.GetKeyName(key, scancode)
	if len(name) > 0 {
		for r in name do return r
	}
	switch key {
	case glfw.KEY_SPACE:
		return ' '
	case glfw.KEY_A ..= glfw.KEY_Z:
		return 'a' + rune(key - glfw.KEY_A)
	case glfw.KEY_0 ..= glfw.KEY_9:
		return '0' + rune(key - glfw.KEY_0)
	}
	return 0
}

on_key :: proc "c" (w: glfw.WindowHandle, key, scancode, action, mods: i32) {
	app := app_of(w)
	context = app.ctx
	m := to_mods(mods)
	app.mods = m
	if action == glfw.RELEASE do return
	app.skip_char = false
	if app.pane != nil && app.pane.searching && search_key(app, app.pane, key, m) {
		app.skip_char = true
		return
	}
	if handle_shortcut(app, key, m) {
		app.skip_char = true
		return
	}
	p := app.pane
	if p == nil do return
	out := make([dynamic]u8, context.temp_allocator)
	if k := map_key(key); k != .None {
		term.encode_key(p.vt, k, m, &out)
	} else if .Ctrl in m {
		// ctrl combos produce no char event, encode them here
		if ch := key_char(key, scancode); ch != 0 {
			term.encode_char(ch, m - {.Shift}, &out)
			app.skip_char = true
		}
	}
	pane_input(app, p, out[:])
}

on_char :: proc "c" (w: glfw.WindowHandle, ch: rune) {
	app := app_of(w)
	context = app.ctx
	if app.skip_char {
		app.skip_char = false
		return
	}
	p := app.pane
	if p == nil do return
	if p.searching {
		b, n := utf8.encode_rune(ch)
		append(&p.query, ..b[:n])
		restart_search(p)
		app.dirty = true
		return
	}
	out := make([dynamic]u8, context.temp_allocator)
	term.encode_char(ch, app.mods & {.Alt}, &out)
	pane_input(app, p, out[:])
}

on_resize :: proc "c" (w: glfw.WindowHandle, width, height: i32) {
	app := app_of(w)
	context = app.ctx
	layout(app)
	render(app)
}

on_scale :: proc "c" (w: glfw.WindowHandle, sx, sy: f32) {
	app := app_of(w)
	context = app.ctx
	app.scale = max(sx, 1)
	set_font_size(app, app.f.size)
}

on_refresh :: proc "c" (w: glfw.WindowHandle) {
	app := app_of(w)
	context = app.ctx
	app.dirty = true
}

set_font_size :: proc(app: ^App, size: f32) {
	fonts_set_size(&app.f, size, app.scale)
	layout(app)
}

install_callbacks :: proc(app: ^App) {
	glfw.SetKeyCallback(app.win, on_key)
	glfw.SetCharCallback(app.win, on_char)
	glfw.SetFramebufferSizeCallback(app.win, on_resize)
	glfw.SetWindowContentScaleCallback(app.win, on_scale)
	glfw.SetWindowRefreshCallback(app.win, on_refresh)
	glfw.SetMouseButtonCallback(app.win, on_mouse_button)
	glfw.SetCursorPosCallback(app.win, on_cursor_pos)
	glfw.SetScrollCallback(app.win, on_scroll)
	glfw.SetWindowFocusCallback(app.win, on_focus)
}

handle_shortcut :: proc(app: ^App, key: i32, m: term.Mods) -> bool {
	action := lookup_binding(&app.cfg, key, m)
	if action == .None do return false
	return run_action(app, action)
}

run_action :: proc(app: ^App, action: Action) -> bool {
	p := app.pane
	if p == nil do return false
	t := p.vt
	#partial switch action {
	case .Copy:
		copy_selection(app, p)
	case .Paste:
		paste(app, p)
	case .Search:
		p.searching = true
		restart_search(p)
	case .Font_Up:
		set_font_size(app, app.f.size + 1)
	case .Font_Down:
		set_font_size(app, app.f.size - 1)
	case .Font_Reset:
		set_font_size(app, app.cfg.font_size)
	case .Scroll_Page_Up, .Scroll_Page_Down, .Scroll_Top, .Scroll_Bottom:
		// full screen apps get these keys themselves
		if t.scr != &t.primary do return false
		#partial switch action {
		case .Scroll_Page_Up:
			term.scroll_view(t, t.rows - 1)
		case .Scroll_Page_Down:
			term.scroll_view(t, -(t.rows - 1))
		case .Scroll_Top:
			term.scroll_view(t, t.hist.count)
		case .Scroll_Bottom:
			term.scroll_view(t, -t.view)
		}
	case:
		return false
	}
	app.dirty = true
	return true
}

// cell under the mouse, clamped to the pane grid
mouse_cell :: proc(app: ^App, p: ^Pane) -> (col, row: int) {
	mx, my := glfw.GetCursorPos(app.win)
	ww, _ := glfw.GetWindowSize(app.win)
	fw, _ := glfw.GetFramebufferSize(app.win)
	k := f64(fw) / f64(max(ww, 1))
	col = int((mx * k - f64(p.x + PAD)) / f64(app.f.cell_w))
	row = int((my * k - f64(p.y + PAD)) / f64(app.f.cell_h))
	return clamp(col, 0, p.vt.cols - 1), clamp(row, 0, p.vt.rows - 1)
}

reports_mouse :: proc(app: ^App, p: ^Pane) -> bool {
	// shift bypasses reporting so text can still be selected
	return p.vt.modes & term.MOUSE_MODES != {} && .Shift not_in app.mods
}

on_mouse_button :: proc "c" (w: glfw.WindowHandle, button, action, mods: i32) {
	app := app_of(w)
	context = app.ctx
	app.mods = to_mods(mods)
	p := app.pane
	if p == nil do return
	col, row := mouse_cell(app, p)
	// glfw orders buttons left, right, middle
	btns := [3]int{0, 2, 1}
	if button > 2 do return
	btn := btns[button]
	if reports_mouse(app, p) {
		out := make([dynamic]u8, context.temp_allocator)
		ev: term.Mouse_Event = .Press if action == glfw.PRESS else .Release
		term.encode_mouse(p.vt, ev, btn, col, row, app.mods, &out)
		p.mouse_btn = btn if action == glfw.PRESS else -1
		p.mouse_cell = {col, row}
		if len(out) > 0 do term.pty_write(p.pty, out[:])
		return
	}
	t := p.vt
	pos := term.Pos{t.hist.total - t.view + row, col}
	switch btn {
	case 0:
		if action == glfw.PRESS {
			now := glfw.GetTime()
			if now - app.click_time < 0.4 && pos == app.click_pos {
				app.clicks = app.clicks % 3 + 1
			} else {
				app.clicks = 1
			}
			app.click_time = now
			app.click_pos = pos
			p.sel.mode = Sel_Mode(app.clicks - 1)
			p.sel.anchor = pos
			p.sel.dragging = true
			p.sel.active = p.sel.mode != .Char
			extend_selection(p, pos)
		} else {
			p.sel.dragging = false
		}
	case 1:
		if action == glfw.PRESS do paste(app, p)
	}
	app.dirty = true
}

extend_selection :: proc(p: ^Pane, pos: term.Pos) {
	s := &p.sel
	a, b := term.ordered(s.anchor, pos)
	switch s.mode {
	case .Char:
		if pos != s.anchor do s.active = true
	case .Word:
		a, _ = term.word_bounds(p.vt, a)
		_, b = term.word_bounds(p.vt, b)
	case .Line:
		a, _ = term.line_bounds(p.vt, a)
		_, b = term.line_bounds(p.vt, b)
	}
	s.a, s.b = a, b
}

on_cursor_pos :: proc "c" (w: glfw.WindowHandle, x, y: f64) {
	app := app_of(w)
	context = app.ctx
	p := app.pane
	if p == nil do return
	col, row := mouse_cell(app, p)
	if reports_mouse(app, p) {
		if col == p.mouse_cell.x && row == p.mouse_cell.y do return
		p.mouse_cell = {col, row}
		out := make([dynamic]u8, context.temp_allocator)
		btn := p.mouse_btn if p.mouse_btn >= 0 else 3
		term.encode_mouse(p.vt, .Motion, btn, col, row, app.mods, &out)
		if len(out) > 0 do term.pty_write(p.pty, out[:])
		return
	}
	if p.sel.dragging {
		t := p.vt
		_, wy := glfw.GetCursorPos(app.win)
		// drag past the edges scrolls the view
		if wy < 0 do term.scroll_view(t, 1)
		if row == t.rows - 1 && wy > f64(p.y + p.h) do term.scroll_view(t, -1)
		extend_selection(p, {t.hist.total - t.view + row, col})
		app.dirty = true
	}
}

on_scroll :: proc "c" (w: glfw.WindowHandle, dx, dy: f64) {
	app := app_of(w)
	context = app.ctx
	p := app.pane
	if p == nil do return
	app.scroll_acc += dy
	notches := int(app.scroll_acc)
	if notches == 0 do return
	app.scroll_acc -= f64(notches)
	t := p.vt
	out := make([dynamic]u8, context.temp_allocator)
	if reports_mouse(app, p) {
		col, row := mouse_cell(app, p)
		for _ in 0 ..< abs(notches) do term.encode_mouse(t, .Press, 4 if notches > 0 else 5, col, row, app.mods, &out)
	} else if t.scr == &t.alt {
		// alternate scroll: wheel becomes cursor keys in full screen apps
		for _ in 0 ..< abs(notches) * 3 do term.encode_key(t, .Up if notches > 0 else .Down, {}, &out)
	} else {
		term.scroll_view(t, notches * 3)
		app.dirty = true
	}
	if len(out) > 0 do term.pty_write(p.pty, out[:])
}

on_focus :: proc "c" (w: glfw.WindowHandle, focused: i32) {
	app := app_of(w)
	context = app.ctx
	app.focused = focused != 0
	app.dirty = true
	p := app.pane
	if p != nil && .Focus_Events in p.vt.modes {
		term.pty_write(p.pty, transmute([]u8)string("\x1b[I" if app.focused else "\x1b[O"))
	}
}

paste :: proc(app: ^App, p: ^Pane) {
	s := glfw.GetClipboardString(app.win)
	if s == "" do return
	out := make([dynamic]u8, context.temp_allocator)
	term.encode_paste(p.vt, s, &out)
	pane_input(app, p, out[:])
}

copy_selection :: proc(app: ^App, p: ^Pane) {
	if !p.sel.active do return
	s := term.selection_text(p.vt, p.sel.a, p.sel.b, context.temp_allocator)
	glfw.SetClipboardString(app.win, strings.clone_to_cstring(s, context.temp_allocator))
}

restart_search :: proc(p: ^Pane) {
	t := p.vt
	term.search_start(t, &p.search, string(p.query[:]), t.hist.total - t.view + t.rows - 1)
}

// keys while the search bar is open; returns true when consumed
search_key :: proc(app: ^App, p: ^Pane, key: i32, m: term.Mods) -> bool {
	app.dirty = true
	switch key {
	case glfw.KEY_ESCAPE:
		p.searching = false
		p.search.found = false
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
		term.search_next(p.vt, &p.search, 1 if .Shift in m else -1)
	case glfw.KEY_UP:
		term.search_next(p.vt, &p.search, -1)
	case glfw.KEY_DOWN:
		term.search_next(p.vt, &p.search, 1)
	case glfw.KEY_BACKSPACE:
		n := len(p.query)
		for n > 0 {
			n -= 1
			if p.query[n] & 0xc0 != 0x80 do break
		}
		resize(&p.query, n)
		restart_search(p)
	case glfw.KEY_C:
		if m != {.Alt} do return false
		p.search.case_sensitive = !p.search.case_sensitive
		restart_search(p)
	case:
		#partial switch lookup_binding(&app.cfg, key, m) {
		case .Search:
			p.searching = false
			p.search.found = false
			return true
		case .Paste:
			append(&p.query, glfw.GetClipboardString(app.win))
			restart_search(p)
			return true
		}
		// swallow other control combos so they do not leak into the shell
		return m & {.Ctrl, .Alt, .Super} != {} || map_key(key) != .None
	}
	return true
}
