package main

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
}

handle_shortcut :: proc(app: ^App, key: i32, m: term.Mods) -> bool {
	if m != {.Ctrl, .Shift} do return false
	switch key {
	case glfw.KEY_EQUAL:
		set_font_size(app, app.f.size + 1)
	case glfw.KEY_MINUS:
		set_font_size(app, app.f.size - 1)
	case glfw.KEY_V:
		if s := glfw.GetClipboardString(app.win); s != "" && app.pane != nil {
			out := make([dynamic]u8, context.temp_allocator)
			term.encode_paste(app.pane.vt, s, &out)
			pane_input(app, app.pane, out[:])
		}
	case:
		return false
	}
	return true
}
