package main

import "core:fmt"
import "core:time"
import "term"
import gl "vendor:OpenGL"

GRID_VS :: `#version 330 core
layout(location = 0) in uint a_glyph;
layout(location = 1) in uint a_fg;
layout(location = 2) in uint a_bg;
layout(location = 3) in uint a_flags;
layout(location = 4) in int a_row;
uniform vec2 u_origin;
uniform vec2 u_cell;
uniform vec2 u_screen;
uniform int u_cols;
out vec2 v_local;
flat out uint v_glyph;
flat out vec4 v_fg;
flat out vec4 v_bg;
flat out uint v_flags;
vec4 unpack(uint c) {
	return vec4(float(c & 0xffu), float((c >> 8) & 0xffu), float((c >> 16) & 0xffu), float(c >> 24)) / 255.0;
}
void main() {
	vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
	vec2 px = u_origin + (vec2(gl_InstanceID % u_cols, a_row) + corner) * u_cell;
	v_local = corner * u_cell;
	v_glyph = a_glyph;
	v_fg = unpack(a_fg);
	v_bg = unpack(a_bg);
	v_flags = a_flags;
	vec2 ndc = px / u_screen * 2.0 - 1.0;
	gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
`

GRID_FS :: `#version 330 core
in vec2 v_local;
flat in uint v_glyph;
flat in vec4 v_fg;
flat in vec4 v_bg;
flat in uint v_flags;
uniform sampler2D u_tex;
uniform int u_pass;
uniform int u_slots_x;
uniform vec2 u_cell;
uniform float u_underline;
uniform float u_thick;
uniform float u_strike;
out vec4 color;
void main() {
	if (u_pass == 0) {
		color = v_bg;
		return;
	}
	float a = 0.0;
	if (v_glyph != 0u) {
		ivec2 slot = ivec2(int(v_glyph) % u_slots_x, int(v_glyph) / u_slots_x) * ivec2(u_cell);
		a = texelFetch(u_tex, slot + ivec2(v_local), 0).r;
	}
	float y = v_local.y;
	if ((v_flags & 1u) != 0u && y >= u_underline && y < u_underline + u_thick) a = 1.0;
	if ((v_flags & 2u) != 0u) {
		float y2 = min(u_underline + 2.0 * u_thick, u_cell.y - u_thick);
		if ((y >= u_underline && y < u_underline + u_thick) || (y >= y2 && y < y2 + u_thick)) a = 1.0;
	}
	if ((v_flags & 4u) != 0u) {
		float w = u_underline + u_thick * (1.0 + sin(v_local.x / u_cell.x * 6.2831853));
		if (abs(y - w) < u_thick * 0.75) a = 1.0;
	}
	if ((v_flags & 8u) != 0u && y >= u_strike && y < u_strike + u_thick) a = 1.0;
	if ((v_flags & 16u) != 0u && y < u_thick) a = 1.0;
	if (a <= 0.0) discard;
	color = vec4(v_fg.rgb, v_fg.a * a);
}
`

RECT_VS :: `#version 330 core
layout(location = 0) in vec4 a_rect;
layout(location = 1) in vec4 a_uv;
layout(location = 2) in uint a_color;
uniform vec2 u_screen;
out vec2 v_uv;
flat out vec4 v_color;
void main() {
	vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
	vec2 px = a_rect.xy + corner * a_rect.zw;
	v_uv = mix(a_uv.xy, a_uv.zw, corner);
	v_color = vec4(float(a_color & 0xffu), float((a_color >> 8) & 0xffu), float((a_color >> 16) & 0xffu), float(a_color >> 24)) / 255.0;
	vec2 ndc = px / u_screen * 2.0 - 1.0;
	gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
`

RECT_FS :: `#version 330 core
in vec2 v_uv;
flat in vec4 v_color;
uniform sampler2D u_tex;
uniform int u_mode;
out vec4 color;
void main() {
	if (u_mode == 0) {
		color = v_color;
	} else if (u_mode == 1) {
		float a = texelFetch(u_tex, ivec2(v_uv), 0).r;
		if (a <= 0.0) discard;
		color = vec4(v_color.rgb, v_color.a * a);
	} else {
		color = texture(u_tex, v_uv) * v_color.a;
	}
}
`

Grid_Cell :: struct {
	glyph, fg, bg, flags: u32,
}

Rect :: struct {
	x, y, w, h:     f32,
	u0, v0, u1, v1: f32,
	color:          u32,
}

Rect_Mode :: enum i32 {
	Solid,
	Glyph,
	Image,
}

// gpu state for one terminal view
Pane_Gpu :: struct {
	vao, vbo, rowbuf: u32,
	mapped:           [^]Grid_Cell,
	staging:          []Grid_Cell,
	rowmap:           []i32,
	cols, rows:       int,
	generation:       int,
	view:             int,
	seq:              u64,
	selection_seq:    int,
	upload_lo:        int,
	upload_hi:        int,
}

Renderer :: struct {
	grid:       u32,
	rect:       u32,
	grid_u:     struct {
		origin, cell, screen, cols, tex, pass, slots_x, underline, thick, strike: i32,
	},
	rect_u:     struct {
		screen, tex, mode: i32,
	},
	rect_vao:   u32,
	rect_vbo:   u32,
	rect_cap:   int,
	rects:      [dynamic]Rect,
	persistent: bool,
	fence:      gl.sync_t,
	fb_w, fb_h: int,
	opacity:    f32,
	textures:   map[u64]u32, // image serial -> texture
	bold_bright: bool,
	stats:      struct {
		rows_written: int,
		full_syncs:   int,
		frames:       int,
		cpu:          time.Duration,
		worst:        time.Duration,
	},
}

compile :: proc(vs, fs: string) -> u32 {
	prog, ok := gl.load_shaders_source(vs, fs)
	if !ok {
		msg, kind := gl.get_last_error_message()
		fmt.eprintln("votty: shader error", kind, msg)
		return 0
	}
	return prog
}

renderer_init :: proc(r: ^Renderer, persistent_ok: bool) -> bool {
	r.grid = compile(GRID_VS, GRID_FS)
	r.rect = compile(RECT_VS, RECT_FS)
	if r.grid == 0 || r.rect == 0 do return false
	u :: proc(p: u32, name: cstring) -> i32 {return gl.GetUniformLocation(p, name)}
	r.grid_u = {
		origin    = u(r.grid, "u_origin"),
		cell      = u(r.grid, "u_cell"),
		screen    = u(r.grid, "u_screen"),
		cols      = u(r.grid, "u_cols"),
		tex       = u(r.grid, "u_tex"),
		pass      = u(r.grid, "u_pass"),
		slots_x   = u(r.grid, "u_slots_x"),
		underline = u(r.grid, "u_underline"),
		thick     = u(r.grid, "u_thick"),
		strike    = u(r.grid, "u_strike"),
	}
	r.rect_u = {u(r.rect, "u_screen"), u(r.rect, "u_tex"), u(r.rect, "u_mode")}
	gl.GenVertexArrays(1, &r.rect_vao)
	gl.GenBuffers(1, &r.rect_vbo)
	gl.BindVertexArray(r.rect_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.rect_vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 4, gl.FLOAT, false, size_of(Rect), 0)
	gl.VertexAttribDivisor(0, 1)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 4, gl.FLOAT, false, size_of(Rect), offset_of(Rect, u0))
	gl.VertexAttribDivisor(1, 1)
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribIPointer(2, 1, gl.UNSIGNED_INT, size_of(Rect), offset_of(Rect, color))
	gl.VertexAttribDivisor(2, 1)
	gl.BindVertexArray(0)
	// persistent mapping lets rows be written straight into gpu visible memory
	r.persistent = persistent_ok && gl.BufferStorage != nil
	r.opacity = 1
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	gl.DeleteProgram(r.grid)
	gl.DeleteProgram(r.rect)
	gl.DeleteVertexArrays(1, &r.rect_vao)
	gl.DeleteBuffers(1, &r.rect_vbo)
	if r.fence != nil do gl.DeleteSync(r.fence)
	for _, tex in r.textures {
		tex := tex
		gl.DeleteTextures(1, &tex)
	}
	delete(r.textures)
	delete(r.rects)
}

pane_gpu_free :: proc(g: ^Pane_Gpu) {
	if g.vao == 0 do return
	if g.mapped != nil {
		gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
		gl.UnmapBuffer(gl.ARRAY_BUFFER)
	}
	gl.DeleteVertexArrays(1, &g.vao)
	gl.DeleteBuffers(1, &g.vbo)
	gl.DeleteBuffers(1, &g.rowbuf)
	delete(g.staging)
	delete(g.rowmap)
	g^ = {}
}

@(private = "file")
pane_gpu_alloc :: proc(r: ^Renderer, g: ^Pane_Gpu, cols, rows: int) {
	pane_gpu_free(g)
	g.cols = cols
	g.rows = rows
	n := cols * rows
	gl.GenVertexArrays(1, &g.vao)
	gl.GenBuffers(1, &g.vbo)
	gl.GenBuffers(1, &g.rowbuf)
	gl.BindVertexArray(g.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	size := n * size_of(Grid_Cell)
	if r.persistent {
		flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
		gl.BufferStorage(gl.ARRAY_BUFFER, size, nil, flags)
		g.mapped = ([^]Grid_Cell)(gl.MapBufferRange(gl.ARRAY_BUFFER, 0, size, flags))
	}
	if g.mapped == nil {
		gl.BufferData(gl.ARRAY_BUFFER, size, nil, gl.DYNAMIC_DRAW)
		g.staging = make([]Grid_Cell, n)
	}
	for i in u32(0) ..< 4 {
		gl.EnableVertexAttribArray(i)
		gl.VertexAttribIPointer(i, 1, gl.UNSIGNED_INT, size_of(Grid_Cell), uintptr(i * 4))
		gl.VertexAttribDivisor(i, 1)
	}
	g.rowmap = make([]i32, rows)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.rowbuf)
	gl.BufferData(gl.ARRAY_BUFFER, rows * size_of(i32), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(4)
	gl.VertexAttribIPointer(4, 1, gl.INT, 4, 0)
	// one row index per terminal row of instances
	gl.VertexAttribDivisor(4, u32(cols))
	gl.BindVertexArray(0)
	g.generation = -1
}

pack :: #force_inline proc "contextless" (rgb: u32, a: f32) -> u32 {
	return (rgb >> 16) & 0xff | (rgb & 0xff00) | (rgb & 0xff) << 16 | u32(clamp(a, 0, 1) * 255) << 24
}

@(private = "file")
resolve :: proc(r: ^Renderer, t: ^term.Term, col: term.Color, is_fg, bold: bool) -> (rgb: u32, is_default: bool) {
	switch u32(col) & 0xff000000 {
	case term.COLOR_INDEXED:
		i := int(u32(col) & 0xff)
		if bold && r.bold_bright && i < 8 do i += 8
		return t.palette[i], false
	case term.COLOR_RGB:
		return u32(col) & 0xffffff, false
	}
	return t.fg if is_fg else t.bg, true
}

cell_colors :: proc(r: ^Renderer, t: ^term.Term, c: term.Cell) -> (fg, bg: u32) {
	f, _ := resolve(r, t, c.fg, true, .Bold in c.attrs)
	b, bdef := resolve(r, t, c.bg, false, false)
	if (.Inverse in c.attrs) != (.Reverse_Video in t.modes) {
		f, b = b, f
		bdef = false
	}
	if .Invisible in c.attrs do f = b
	if .Faint in c.attrs {
		f = (f >> 1) & 0x7f7f7f + (b >> 1) & 0x7f7f7f
	}
	return pack(f, 1), pack(b, r.opacity if bdef else 1)
}

@(private = "file")
style_of :: #force_inline proc(a: term.Attrs) -> Style {
	return Style(int(.Bold in a) | int(.Italic in a) << 1)
}

@(private = "file")
write_row :: proc(r: ^Renderer, g: ^Pane_Gpu, f: ^Fonts, t: ^term.Term, slot: int, cells: []term.Cell) {
	dst := g.mapped[slot * g.cols:] if g.mapped != nil else raw_data(g.staging[slot * g.cols:])
	wide_id: u32
	for x in 0 ..< g.cols {
		c := cells[x] if x < len(cells) else term.Cell{}
		out: Grid_Cell
		out.fg, out.bg = cell_colors(r, t, c)
		if .Spacer in c.attrs {
			out.glyph = wide_id + 1 if wide_id != 0 else 0
		} else if .Invisible not_in c.attrs {
			wide := .Wide in c.attrs
			out.glyph = glyph_slot(f, c.ch, c.mark, style_of(c.attrs), wide)
			wide_id = out.glyph if wide else 0
		}
		a := c.attrs
		if .Underline in a do out.flags |= 1
		if .Double_Underline in a do out.flags |= 2
		if .Curly_Underline in a do out.flags |= 4
		if .Strike in a do out.flags |= 8
		if .Overline in a do out.flags |= 16
		dst[x] = out
	}
	g.upload_lo = min(g.upload_lo, slot)
	g.upload_hi = max(g.upload_hi, slot + 1)
	r.stats.rows_written += 1
}

// brings the gpu copy of a terminal up to date, touching only dirty rows
sync_pane :: proc(r: ^Renderer, g: ^Pane_Gpu, f: ^Fonts, t: ^term.Term) {
	if g.cols != t.cols || g.rows != t.rows do pane_gpu_alloc(r, g, t.cols, t.rows)
	gen := f.generation
	full := t.all_dirty || g.generation != gen || g.view != t.view
	if full do r.stats.full_syncs += 1
	s := t.scr
	g.upload_lo, g.upload_hi = g.rows, 0
	remap := false
	if t.view > 0 {
		if full || g.seq != t.output_seq {
			base := t.hist.total - t.view
			for y in 0 ..< t.rows {
				cells, _, _ := term.get_line(t, base + y)
				write_row(r, g, f, t, y, cells)
				g.rowmap[y] = i32(y)
			}
			remap = true
		}
	} else {
		for p in 0 ..< t.rows {
			if full || s.dirty[p] do write_row(r, g, f, t, p, s.cells[p * t.cols:(p + 1) * t.cols])
		}
		if full || s.remapped {
			for y in 0 ..< t.rows do g.rowmap[s.lines[y]] = i32(y)
			remap = true
		}
	}
	// the atlas may have been reset while rows were written
	if f.generation != gen {
		sync_pane(r, g, f, t)
		return
	}
	for &d in s.dirty do d = false
	s.remapped = false
	t.all_dirty = false
	g.generation = gen
	g.view = t.view
	g.seq = t.output_seq
	if g.mapped == nil && g.upload_hi > g.upload_lo {
		gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
		lo, hi := g.upload_lo * g.cols, g.upload_hi * g.cols
		gl.BufferSubData(gl.ARRAY_BUFFER, lo * size_of(Grid_Cell), (hi - lo) * size_of(Grid_Cell), &g.staging[lo])
	}
	if remap {
		gl.BindBuffer(gl.ARRAY_BUFFER, g.rowbuf)
		gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(g.rowmap) * size_of(i32), raw_data(g.rowmap))
	}
}

begin_frame :: proc(r: ^Renderer, w, h: int, bg: u32) {
	r.fb_w, r.fb_h = w, h
	// the gpu must be done with last frame before mapped rows are rewritten
	if r.fence != nil {
		gl.ClientWaitSync(r.fence, gl.SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000)
		gl.DeleteSync(r.fence)
		r.fence = nil
	}
	gl.Viewport(0, 0, i32(w), i32(h))
	gl.Disable(gl.SCISSOR_TEST)
	c := pack(bg, r.opacity)
	gl.ClearColor(f32(c & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32((c >> 16) & 0xff) / 255, r.opacity)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	r.stats.frames += 1
}

print_stats :: proc(r: ^Renderer) {
	s := r.stats
	n := max(s.frames, 1)
	fmt.eprintfln("votty: %d frames, %d rows uploaded (%.1f per frame), %d full syncs, frame cpu avg %v worst %v",
		s.frames, s.rows_written, f64(s.rows_written) / f64(n), s.full_syncs, s.cpu / time.Duration(n), s.worst)
}

end_frame :: proc(r: ^Renderer) {
	if r.persistent do r.fence = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}

clip :: proc(r: ^Renderer, x, y, w, h: int) {
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(i32(x), i32(r.fb_h - y - h), i32(max(w, 0)), i32(max(h, 0)))
}

no_clip :: proc(r: ^Renderer) {
	gl.Disable(gl.SCISSOR_TEST)
}

draw_grid :: proc(r: ^Renderer, g: ^Pane_Gpu, f: ^Fonts, x, y: int, pass: i32) {
	gl.UseProgram(r.grid)
	gl.Uniform2f(r.grid_u.origin, f32(x), f32(y))
	gl.Uniform2f(r.grid_u.cell, f32(f.cell_w), f32(f.cell_h))
	gl.Uniform2f(r.grid_u.screen, f32(r.fb_w), f32(r.fb_h))
	gl.Uniform1i(r.grid_u.cols, i32(g.cols))
	gl.Uniform1i(r.grid_u.pass, pass)
	gl.Uniform1i(r.grid_u.slots_x, i32(f.slots_x))
	gl.Uniform1f(r.grid_u.underline, f32(f.underline))
	gl.Uniform1f(r.grid_u.thick, f32(f.thickness))
	gl.Uniform1f(r.grid_u.strike, f32(f.baseline) - f32(f.cell_h) * 0.28)
	gl.Uniform1i(r.grid_u.tex, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, f.tex)
	gl.BindVertexArray(g.vao)
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(g.cols * g.rows))
}

push_rect :: proc(r: ^Renderer, x, y, w, h: f32, color: u32) {
	append(&r.rects, Rect{x = x, y = y, w = w, h = h, color = color})
}

push_glyph :: proc(r: ^Renderer, f: ^Fonts, x, y: f32, slot: u32, wide: bool, color: u32) {
	if slot == 0 do return
	n := 2 if wide else 1
	sx := f32(int(slot) % f.slots_x * f.cell_w)
	sy := f32(int(slot) / f.slots_x * f.cell_h)
	w, h := f32(f.cell_w * n), f32(f.cell_h)
	append(&r.rects, Rect{x, y, w, h, sx, sy, sx + w, sy + h, color})
}

// draws pending rects with one texture binding and mode
flush_rects :: proc(r: ^Renderer, mode: Rect_Mode, tex: u32 = 0) {
	if len(r.rects) == 0 do return
	gl.UseProgram(r.rect)
	gl.Uniform2f(r.rect_u.screen, f32(r.fb_w), f32(r.fb_h))
	gl.Uniform1i(r.rect_u.mode, i32(mode))
	gl.Uniform1i(r.rect_u.tex, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.BindVertexArray(r.rect_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.rect_vbo)
	size := len(r.rects) * size_of(Rect)
	if size > r.rect_cap do r.rect_cap = max(size, 64 * size_of(Rect)) * 2
	// orphan so the driver does not stall on the previous draw
	gl.BufferData(gl.ARRAY_BUFFER, r.rect_cap, nil, gl.STREAM_DRAW)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, size, raw_data(r.rects))
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(len(r.rects)))
	clear(&r.rects)
}

// draws a utf-8 string with the atlas, returns the end x
draw_text :: proc(r: ^Renderer, f: ^Fonts, x, y: f32, s: string, color: u32, max_x: f32 = 1e9) -> f32 {
	x := x
	for ch in s {
		w := term.rune_width(ch)
		if w == 0 do continue
		if x + f32(f.cell_w * w) > max_x do break
		push_glyph(r, f, x, y, glyph_slot(f, ch, 0, .Regular, w == 2), w == 2, color)
		x += f32(f.cell_w * w)
	}
	return x
}

text_width :: proc(f: ^Fonts, s: string) -> int {
	n := 0
	for ch in s do n += term.rune_width(ch)
	return n * f.cell_w
}

texture_for :: proc(r: ^Renderer, img: ^term.Image) -> u32 {
	if tex, ok := r.textures[img.serial]; ok do return tex
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(img.w), i32(img.h), 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(img.rgba))
	r.textures[img.serial] = tex
	return tex
}

// releases textures of images the terminal has dropped
release_textures :: proc(r: ^Renderer, g: ^term.Graphics) {
	for serial in g.dropped {
		if tex, ok := r.textures[serial]; ok {
			tex := tex
			gl.DeleteTextures(1, &tex)
			delete_key(&r.textures, serial)
		}
	}
	clear(&g.dropped)
}

draw_images :: proc(r: ^Renderer, f: ^Fonts, t: ^term.Term, ox, oy: int, below: bool) {
	g := &t.gfx
	alt := t.scr == &t.alt
	top := t.hist.total - t.view
	for pl in g.placements {
		if pl.alt != alt || (pl.z < 0) != below do continue
		y := pl.line - top
		if y + pl.rows <= 0 || y >= t.rows do continue
		img := term.find_image(g, pl.image)
		if img == nil || img.w == 0 || img.h == 0 do continue
		tex := texture_for(r, img)
		px := f32(ox + pl.col * f.cell_w + pl.off[0])
		py := f32(oy + y * f.cell_h + pl.off[1])
		w, h := f32(pl.src[2]), f32(pl.src[3])
		if pl.fit {
			w = f32(pl.cols * f.cell_w - pl.off[0])
			h = f32(pl.rows * f.cell_h - pl.off[1])
		}
		iw, ih := f32(img.w), f32(img.h)
		append(&r.rects, Rect{px, py, w, h, f32(pl.src[0]) / iw, f32(pl.src[1]) / ih, f32(pl.src[0] + pl.src[2]) / iw, f32(pl.src[1] + pl.src[3]) / ih, 0xffffffff})
		flush_rects(r, .Image, tex)
	}
}
