package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "term"
import gl "vendor:OpenGL"
import "vendor:glfw"

PAD :: 4

Pane :: struct {
	vt:     ^term.Term,
	pty:    ^term.Pty,
	gpu:    Pane_Gpu,
	buf:    [dynamic]u8,
	x, y:   int,
	w, h:   int,
	exited: bool,
}

App :: struct {
	ctx:         runtime.Context,
	win:         glfw.WindowHandle,
	r:           Renderer,
	f:           Fonts,
	pane:        ^Pane,
	dirty:       bool,
	scale:       f32,
	mods:        term.Mods,
	skip_char:   bool,
	blink_on:    bool,
	last_input:  time.Tick,
	shell:       string,
	last_frame:  time.Tick,
	frame_time:  time.Duration,
}

notify_main :: proc(data: rawptr) {
	glfw.PostEmptyEvent()
}

default_shell :: proc() -> string {
	if s := os.get_env("SHELL", context.temp_allocator); s != "" do return strings.clone(s)
	if pw := posix.getpwuid(posix.getuid()); pw != nil && pw.pw_shell != nil {
		return strings.clone(string(pw.pw_shell))
	}
	return strings.clone("/bin/sh")
}

pane_open :: proc(app: ^App, cols, rows: int, cwd: string = "") -> ^Pane {
	p := new(Pane)
	p.vt = term.make_term(cols, rows)
	term.set_cell_size(p.vt, app.f.cell_w, app.f.cell_h)
	env := []string{"TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=votty"}
	ws := term.Winsize{u16(rows), u16(cols), u16(cols * app.f.cell_w), u16(rows * app.f.cell_h)}
	pty, ok := term.pty_spawn({app.shell}, env, ws, notify_main, nil)
	if !ok {
		fmt.eprintln("votty: cannot spawn", app.shell)
		term.destroy_term(p.vt)
		free(p)
		return nil
	}
	p.pty = pty
	return p
}

pane_close :: proc(p: ^Pane) {
	term.pty_close(p.pty)
	term.destroy_term(p.vt)
	pane_gpu_free(&p.gpu)
	delete(p.buf)
	free(p)
}

pane_layout :: proc(app: ^App, p: ^Pane, x, y, w, h: int) {
	p.x, p.y, p.w, p.h = x, y, w, h
	cols := max((w - 2 * PAD) / app.f.cell_w, 1)
	rows := max((h - 2 * PAD) / app.f.cell_h, 1)
	term.set_cell_size(p.vt, app.f.cell_w, app.f.cell_h)
	if cols != p.vt.cols || rows != p.vt.rows {
		term.resize_term(p.vt, cols, rows)
		term.pty_resize(p.pty, {u16(rows), u16(cols), u16(cols * app.f.cell_w), u16(rows * app.f.cell_h)})
	}
}

layout :: proc(app: ^App) {
	w, h := glfw.GetFramebufferSize(app.win)
	if app.pane != nil do pane_layout(app, app.pane, 0, 0, int(w), int(h))
	app.dirty = true
}

pane_input :: proc(app: ^App, p: ^Pane, data: []u8) {
	if len(data) == 0 do return
	term.pty_write(p.pty, data)
	if p.vt.view != 0 {
		p.vt.view = 0
		p.vt.all_dirty = true
	}
	app.last_input = time.tick_now()
	app.blink_on = true
	app.dirty = true
}

// drains pty output into the terminal; returns false once the child is gone
pane_pump :: proc(app: ^App, p: ^Pane) -> bool {
	eof := term.pty_take(p.pty, &p.buf)
	if len(p.buf) > 0 {
		term.feed(p.vt, p.buf[:])
		app.dirty = true
	}
	t := p.vt
	if len(t.out) > 0 {
		term.pty_write(p.pty, t.out[:])
		clear(&t.out)
	}
	term.pty_flush(p.pty)
	if t.title_dirty {
		t.title_dirty = false
		glfw.SetWindowTitle(app.win, strings.clone_to_cstring(string(t.title[:]), context.temp_allocator))
	}
	if t.clip_dirty {
		t.clip_dirty = false
		glfw.SetClipboardString(app.win, strings.clone_to_cstring(string(t.clipboard[:]), context.temp_allocator))
	}
	if eof && term.pty_reap(p.pty) do return false
	return !eof
}

draw_pane :: proc(app: ^App, p: ^Pane, focused: bool) {
	r := &app.r
	f := &app.f
	t := p.vt
	sync_pane(r, &p.gpu, f, t)
	ox, oy := p.x + PAD, p.y + PAD
	clip(r, p.x, p.y, p.w, p.h)
	push_rect(r, f32(p.x), f32(p.y), f32(p.w), f32(p.h), pack(t.bg, r.opacity))
	flush_rects(r, .Solid)
	draw_grid(r, &p.gpu, f, ox, oy, 0)
	draw_grid(r, &p.gpu, f, ox, oy, 1)
	draw_cursor(app, p, ox, oy, focused)
}

draw_cursor :: proc(app: ^App, p: ^Pane, ox, oy: int, focused: bool) {
	t := p.vt
	if t.view != 0 || .Cursor_Visible not_in t.modes do return
	if focused && .Cursor_Blink in t.modes && !app.blink_on do return
	r := &app.r
	f := &app.f
	cells := term.screen_row(t, t.scr, t.cur.y)
	c := cells[t.cur.x]
	x := t.cur.x
	if .Spacer in c.attrs && x > 0 {
		x -= 1
		c = cells[x]
	}
	wide := .Wide in c.attrs
	cw := f32(f.cell_w * (2 if wide else 1))
	px, py := f32(ox + x * f.cell_w), f32(oy + t.cur.y * f.cell_h)
	col := pack(t.cursor_color, 1)
	th := f32(max(f.thickness, 1))
	if !focused {
		push_rect(&app.r, px, py, cw, th, col)
		push_rect(&app.r, px, py + f32(f.cell_h) - th, cw, th, col)
		push_rect(&app.r, px, py, th, f32(f.cell_h), col)
		push_rect(&app.r, px + cw - th, py, th, f32(f.cell_h), col)
		flush_rects(r, .Solid)
		return
	}
	switch t.shape {
	case .Block:
		push_rect(r, px, py, cw, f32(f.cell_h), col)
		flush_rects(r, .Solid)
		style := Style(int(.Bold in c.attrs) | int(.Italic in c.attrs) << 1)
		slot := glyph_slot(f, c.ch, c.mark, style, wide)
		_, bg := cell_colors(r, t, c)
		push_glyph(r, f, px, py, slot, wide, bg | 0xff000000)
		flush_rects(r, .Glyph, f.tex)
	case .Underline:
		push_rect(r, px, py + f32(f.cell_h) - 2 * th, cw, 2 * th, col)
		flush_rects(r, .Solid)
	case .Bar:
		push_rect(r, px, py, 2 * th, f32(f.cell_h), col)
		flush_rects(r, .Solid)
	}
}

render :: proc(app: ^App) {
	w, h := glfw.GetFramebufferSize(app.win)
	bg := app.pane.vt.bg if app.pane != nil else term.DEFAULT_BG
	begin_frame(&app.r, int(w), int(h), bg)
	if app.pane != nil do draw_pane(app, app.pane, true)
	end_frame(&app.r)
	glfw.SwapBuffers(app.win)
	app.dirty = false
	app.last_frame = time.tick_now()
}

main :: proc() {
	app := new(App)
	defer free(app)
	app.ctx = context
	app.shell = default_shell()
	defer delete(app.shell)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	if !glfw.Init() {
		fmt.eprintln("votty: glfw init failed")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, true)

	app.win = glfw.CreateWindow(960, 600, "votty", nil, nil)
	if app.win == nil {
		fmt.eprintln("votty: cannot create window")
		os.exit(1)
	}
	defer glfw.DestroyWindow(app.win)
	glfw.MakeContextCurrent(app.win)
	// wayland vsync blocks on frame callbacks with some drivers; pace frames ourselves there
	glfw.SwapInterval(0 if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND else 1)
	gl.load_up_to(4, 6, glfw.gl_set_proc_address)
	glfw.SetWindowUserPointer(app.win, app)

	major := glfw.GetWindowAttrib(app.win, glfw.CONTEXT_VERSION_MAJOR)
	minor := glfw.GetWindowAttrib(app.win, glfw.CONTEXT_VERSION_MINOR)
	if !renderer_init(&app.r, major * 10 + minor >= 44) {
		os.exit(1)
	}
	defer renderer_destroy(&app.r)

	sx, _ := glfw.GetWindowContentScale(app.win)
	app.scale = max(sx, 1)
	if !fonts_init(&app.f, "monospace", 11, app.scale) {
		fmt.eprintln("votty: no usable font found")
		os.exit(1)
	}
	defer fonts_destroy(&app.f)

	if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
		app.frame_time = time.Second / 60
		if mode := glfw.GetVideoMode(glfw.GetPrimaryMonitor()); mode != nil && mode.refresh_rate > 0 {
			app.frame_time = time.Second / time.Duration(mode.refresh_rate)
		}
	}
	install_callbacks(app)
	w, h := glfw.GetFramebufferSize(app.win)
	cols := max((int(w) - 2 * PAD) / app.f.cell_w, 1)
	rows := max((int(h) - 2 * PAD) / app.f.cell_h, 1)
	app.pane = pane_open(app, cols, rows)
	if app.pane == nil do os.exit(1)
	layout(app)
	app.blink_on = true
	app.last_input = time.tick_now()
	blink_at := time.tick_now()

	for !glfw.WindowShouldClose(app.win) {
		if app.dirty {
			wait := app.frame_time - time.tick_since(app.last_frame)
			if wait > 0 {
				glfw.WaitEventsTimeout(time.duration_seconds(wait))
			} else {
				glfw.PollEvents()
			}
		} else {
			glfw.WaitEventsTimeout(0.5)
		}
		if time.tick_since(blink_at) >= 500 * time.Millisecond {
			blink_at = time.tick_now()
			app.blink_on = !app.blink_on
			if .Cursor_Blink in app.pane.vt.modes do app.dirty = true
		}
		if !pane_pump(app, app.pane) do break
		if app.dirty && time.tick_since(app.last_frame) >= app.frame_time do render(app)
		free_all(context.temp_allocator)
	}
	pane_close(app.pane)
}
