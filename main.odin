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
	sel:    Selection,
	mouse_btn:  int, // button held for drag reports, -1 none
	mouse_cell: [2]int,
	search:     term.Search,
	searching:  bool,
	query:      [dynamic]u8,
	node:       ^Node,
}

Sel_Mode :: enum u8 {
	Char,
	Word,
	Line,
}

Selection :: struct {
	active:   bool,
	dragging: bool,
	mode:     Sel_Mode,
	anchor:   term.Pos,
	a, b:     term.Pos,
}

App :: struct {
	ctx:         runtime.Context,
	win:         glfw.WindowHandle,
	r:           Renderer,
	f:           Fonts,
	spaces:      [dynamic]^Workspace,
	space:       int,
	drag:        ^Pane, // pane receiving a mouse drag
	tab_hits:    [dynamic]Tab_Hit,
	dirty:       bool,
	scale:       f32,
	mods:        term.Mods,
	skip_char:   bool,
	blink_on:    bool,
	last_input:  time.Tick,
	shell:       string,
	command:     []string,
	cfg:         Config,
	last_frame:  time.Tick,
	frame_time:  time.Duration,
	focused:     bool,
	clicks:      int,
	click_time:  f64,
	click_pos:   term.Pos,
	scroll_acc:  f64,
}

theme_of :: proc(c: ^Config) -> (th: term.Theme) {
	term.default_palette(&th.palette)
	for i in 0 ..< 16 do if c.palette_set[i] do th.palette[i] = c.palette[i]
	th.fg = c.fg
	th.bg = c.bg
	th.cursor_color = c.cursor_color
	th.shape = c.cursor_shape
	th.blink = c.cursor_blink
	return
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
	p.vt = term.make_term(cols, rows, app.cfg.scrollback)
	term.set_cell_size(p.vt, app.f.cell_w, app.f.cell_h)
	term.set_theme(p.vt, theme_of(&app.cfg))
	env := []string{"TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=votty"}
	ws := term.Winsize{u16(rows), u16(cols), u16(cols * app.f.cell_w), u16(rows * app.f.cell_h)}
	argv := app.command if len(app.command) > 0 else []string{app.shell}
	pty, ok := term.pty_spawn(argv, env, ws, notify_main, nil, cwd)
	if !ok {
		fmt.eprintln("votty: cannot spawn", app.shell)
		term.destroy_term(p.vt)
		free(p)
		return nil
	}
	p.pty = pty
	p.mouse_btn = -1
	return p
}

pane_close :: proc(app: ^App, p: ^Pane) {
	for img in p.vt.gfx.images do append(&p.vt.gfx.dropped, img.serial)
	release_textures(&app.r, &p.vt.gfx)
	term.pty_close(p.pty)
	term.destroy_term(p.vt)
	pane_gpu_free(&p.gpu)
	term.search_free(&p.search)
	delete(p.query)
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


pane_input :: proc(app: ^App, p: ^Pane, data: []u8) {
	if len(data) == 0 do return
	term.pty_write(p.pty, data)
	p.sel.active = false
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
	if p.vt.gfx.changed {
		p.vt.gfx.changed = false
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
		if p == focused(app) do update_title(app)
		app.dirty = true
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
	release_textures(r, &t.gfx)
	draw_grid(r, &p.gpu, f, ox, oy, 0)
	draw_images(r, f, t, ox, oy, true)
	draw_selection(app, p, ox, oy)
	if p.searching do draw_matches(app, p, ox, oy)
	draw_grid(r, &p.gpu, f, ox, oy, 1)
	draw_images(r, f, t, ox, oy, false)
	draw_cursor(app, p, ox, oy, focused)
	if p.searching do draw_search_bar(app, p)
}

draw_matches :: proc(app: ^App, p: ^Pane, ox, oy: int) {
	t := p.vt
	top := t.hist.total - t.view
	ms := make([dynamic]term.Match, context.temp_allocator)
	for l in top ..< top + t.rows do term.line_matches(t, &p.search, l, &ms)
	cur := p.search.current
	for m in ms {
		is_cur := p.search.found && m == cur
		color := pack(0xe0a030, 0.9) if is_cur else pack(0x807020, 0.6)
		highlight(app, p, ox, oy, {m.line, m.col}, {m.line, m.col + m.len - 1}, color)
	}
	flush_rects(&app.r, .Solid)
}

draw_search_bar :: proc(app: ^App, p: ^Pane) {
	r := &app.r
	f := &app.f
	h := f.cell_h + 2
	y := f32(p.y + p.h - h)
	s := &p.search
	status := "searching" if s.active else ("" if s.found || len(p.query) == 0 else "no match")
	mode := "Aa" if s.case_sensitive else "aa"
	label := "find: "
	right := fmt.tprintf("%s  [%s alt+c]  enter/shift+enter  esc", status, mode)
	rx := f32(p.x + p.w - PAD - text_width(f, right))
	qx := f32(p.x + PAD + text_width(f, label))
	qw := min(f32(text_width(f, string(p.query[:]))), max(rx - f32(f.cell_w) - qx, 0))
	push_rect(r, f32(p.x), y, f32(p.w), f32(h), pack(0x30343c, 1))
	push_rect(r, f32(p.x), y, f32(p.w), 1, pack(0x5577aa, 1))
	push_rect(r, qx + qw, y + 1, 2, f32(f.cell_h), pack(0xffffff, 1))
	flush_rects(r, .Solid)
	draw_text(r, f, f32(p.x + PAD), y + 1, label, pack(0x8899aa, 1))
	draw_text(r, f, qx, y + 1, string(p.query[:]), pack(0xffffff, 1), rx - f32(f.cell_w))
	draw_text(r, f, rx, y + 1, right, pack(0x8899aa, 1))
	flush_rects(r, .Glyph, f.tex)
}

// advances a running search and brings its match into view
pane_search_tick :: proc(app: ^App, p: ^Pane) {
	s := &p.search
	if !p.searching do return
	term.search_validate(p.vt, s)
	if !s.active do return
	if term.search_step(p.vt, s, 20000) && s.found do reveal(p.vt, s.current.line)
	app.dirty = true
}

reveal :: proc(t: ^term.Term, line: int) {
	top := t.hist.total - t.view
	if line >= top && line < top + t.rows do return
	term.scroll_view(t, (t.hist.total - (line - t.rows / 2)) - t.view)
}

// highlights an inclusive span of absolute positions in view coordinates
highlight :: proc(app: ^App, p: ^Pane, ox, oy: int, a, b: term.Pos, color: u32) {
	t := p.vt
	f := &app.f
	top := t.hist.total - t.view
	for l in max(a.line, top) ..= min(b.line, top + t.rows - 1) {
		x0 := a.col if l == a.line else 0
		x1 := b.col if l == b.line else t.cols - 1
		if x1 < x0 do continue
		y := l - top
		push_rect(&app.r, f32(ox + x0 * f.cell_w), f32(oy + y * f.cell_h), f32((x1 - x0 + 1) * f.cell_w), f32(f.cell_h), color)
	}
}

draw_selection :: proc(app: ^App, p: ^Pane, ox, oy: int) {
	if !p.sel.active do return
	a, b := term.ordered(p.sel.a, p.sel.b)
	highlight(app, p, ox, oy, a, b, pack(0x5577aa, 0.6))
	flush_rects(&app.r, .Solid)
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
	start := time.tick_now()
	w, h := glfw.GetFramebufferSize(app.win)
	fp := focused(app)
	bg := fp.vt.bg if fp != nil else app.cfg.bg
	begin_frame(&app.r, int(w), int(h), bg)
	if t := cur_tab(app); t != nil {
		for n in tab_panes(t) do draw_pane(app, n.pane, app.focused && n == t.focus)
	}
	draw_borders(app)
	no_clip(&app.r)
	draw_tab_bar(app)
	end_frame(&app.r)
	el := time.tick_since(start)
	app.r.stats.cpu += el
	app.r.stats.worst = max(app.r.stats.worst, el)
	glfw.SwapBuffers(app.win)
	app.dirty = false
	app.last_frame = time.tick_now()
}

usage :: proc() {
	fmt.eprintln("usage: votty [-c config] [-o key=value]... [-e command args...]")
	os.exit(2)
}

main :: proc() {
	app := new(App)
	defer free(app)
	app.ctx = context
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	config_defaults(&app.cfg)
	defer config_destroy(&app.cfg)
	args := os.args[1:]
	cfg_file := config_path()
	overrides := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-c", "--config":
			if i + 1 >= len(args) do usage()
			i += 1
			cfg_file = args[i]
		case "-o":
			if i + 1 >= len(args) do usage()
			i += 1
			append(&overrides, args[i])
		case "-e":
			if i + 1 >= len(args) do usage()
			app.command = args[i + 1:]
			i = len(args)
		case:
			usage()
		}
	}
	config_load(&app.cfg, cfg_file)
	for o in overrides {
		eq := strings.index_byte(o, '=')
		if eq < 0 || !config_set(&app.cfg, strings.trim_space(o[:eq]), strings.trim_space(o[eq + 1:])) {
			fmt.eprintln("votty: invalid option", o)
		}
	}
	app.shell = strings.clone(app.cfg.shell) if app.cfg.shell != "" else default_shell()
	defer delete(app.shell)

	switch app.cfg.platform {
	case "x11":
		glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11)
	case "wayland":
		glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_WAYLAND)
	}
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
	if app.cfg.opacity < 1 do glfw.WindowHint(glfw.TRANSPARENT_FRAMEBUFFER, true)

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
	if !renderer_init(&app.r, app.cfg.persistent && major * 10 + minor >= 44) {
		os.exit(1)
	}
	defer renderer_destroy(&app.r)
	app.r.opacity = app.cfg.opacity
	app.r.bold_bright = app.cfg.bold_bright

	sx, _ := glfw.GetWindowContentScale(app.win)
	app.scale = max(sx, 1)
	if !fonts_init(&app.f, app.cfg.font, app.cfg.font_size, app.scale) {
		fmt.eprintln("votty: no usable font found")
		os.exit(1)
	}
	defer fonts_destroy(&app.f)

	// size the window from the configured grid; glfw scales window coordinates itself
	ww, _ := glfw.GetWindowSize(app.win)
	fw, _ := glfw.GetFramebufferSize(app.win)
	k := f64(fw) / f64(max(ww, 1))
	glfw.SetWindowSize(app.win, i32(f64(app.cfg.width * app.f.cell_w + 2 * PAD) / k), i32(f64(app.cfg.height * app.f.cell_h + 2 * PAD) / k))

	if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
		app.frame_time = time.Second / 60
		if mode := glfw.GetVideoMode(glfw.GetPrimaryMonitor()); mode != nil && mode.refresh_rate > 0 {
			app.frame_time = time.Second / time.Duration(mode.refresh_rate)
		}
	}
	install_callbacks(app)
	if !new_workspace(app) do os.exit(1)
	defer {
		for len(app.spaces) > 0 do close_workspace(app)
		delete(app.spaces)
		delete(app.tab_hits)
	}
	app.blink_on = true
	app.focused = true
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
			if p := focused(app); p != nil && .Cursor_Blink in p.vt.modes do app.dirty = true
		}
		for p in all_panes(app) {
			if !pane_pump(app, p) {
				remove_pane(app, p)
				continue
			}
			pane_search_tick(app, p)
		}
		if len(app.spaces) == 0 do break
		if app.dirty && time.tick_since(app.last_frame) >= app.frame_time do render(app)
		free_all(context.temp_allocator)
	}
	if app.cfg.stats do print_stats(&app.r)
}
