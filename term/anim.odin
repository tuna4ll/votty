package term

import "core:slice"

Frame :: struct {
	rgba: []u8,
	gap:  int, // milliseconds
}

Anim_State :: enum u8 {
	Stopped,
	Loading, // runs but holds on the last frame until more arrive
	Running,
}

// frame 1 is the image's own pixels; extra holds frames 2 and up
Animation :: struct {
	extra:    [dynamic]Frame,
	root_gap: int,
	current:  int, // 1-based
	state:    Anim_State,
	loops:    int, // 0 forever, otherwise plays left
	shown_at: i64, // ms timestamp the current frame appeared
	version:  u64, // bumped whenever the shown pixels change
}

DEFAULT_GAP :: 40

image_bytes :: proc(img: ^Image) -> int {
	n := len(img.rgba)
	for f in img.anim.extra do n += len(f.rgba)
	return n
}

free_image :: proc(img: ^Image) {
	delete(img.rgba)
	for f in img.anim.extra do delete(f.rgba)
	delete(img.anim.extra)
	free(img)
}

frame_count :: proc(img: ^Image) -> int {return 1 + len(img.anim.extra)}

frame_pixels :: proc(img: ^Image, n: int) -> []u8 {
	if n <= 1 do return img.rgba
	return img.anim.extra[n - 2].rgba
}

// pixels the image shows right now
shown_pixels :: proc(img: ^Image) -> []u8 {
	return frame_pixels(img, max(img.anim.current, 1))
}

@(private)
frame_gap :: proc(img: ^Image, n: int) -> ^int {
	if n <= 1 do return &img.anim.root_gap
	return &img.anim.extra[n - 2].gap
}

// draws w x h pixels at x, y into an image sized canvas, alpha blending unless replacing
@(private)
blit :: proc(dst: []u8, dw, dh: int, src: []u8, sw, sh, sx, sy, w, h, x, y: int, replace: bool) {
	for row in 0 ..< h {
		ty, fy := y + row, sy + row
		if ty < 0 || ty >= dh || fy < 0 || fy >= sh do continue
		for col in 0 ..< w {
			tx, fx := x + col, sx + col
			if tx < 0 || tx >= dw || fx < 0 || fx >= sw do continue
			s := src[(fy * sw + fx) * 4:][:4]
			d := dst[(ty * dw + tx) * 4:][:4]
			if replace || s[3] == 255 {
				copy(d, s)
				continue
			}
			a := u32(s[3])
			for k in 0 ..< 3 do d[k] = u8((u32(s[k]) * a + u32(d[k]) * (255 - a)) / 255)
			d[3] = u8(a + u32(d[3]) * (255 - a) / 255)
		}
	}
}

@(private)
find_target :: proc(g: ^Graphics, c: Gfx_Cmd) -> ^Image {
	if c.id != 0 do return find_image(g, c.id)
	#reverse for img in g.images do if img.number == c.number do return img
	return nil
}

// a=f: new frame or edit of frame r, built on frame c or a background color
add_frame :: proc(t: ^Term, c: Gfx_Cmd, data: []u8, w, h: int) {
	g := &t.gfx
	defer delete(data)
	img := find_target(g, c)
	if img == nil {
		gfx_reply(t, c, "ENOENT:image not found")
		return
	}
	n := frame_count(img)
	edit, base := c.rows, c.cols
	if edit > n || base > n {
		gfx_reply(t, c, "EINVAL:no such frame")
		return
	}
	canvas: []u8
	if edit > 0 {
		canvas = frame_pixels(img, edit)
	} else {
		canvas = make([]u8, img.w * img.h * 4)
		if base > 0 {
			copy(canvas, frame_pixels(img, base))
		} else if bgc := u32(c.off[1]); bgc != 0 {
			px := [4]u8{u8(bgc >> 24), u8(bgc >> 16), u8(bgc >> 8), u8(bgc)}
			for i := 0; i < len(canvas); i += 4 do copy(canvas[i:i + 4], px[:])
		}
	}
	blit(canvas, img.w, img.h, data, w, h, 0, 0, w, h, c.src[0], c.src[1], c.off[0] == 1)
	if edit == 0 {
		append(&img.anim.extra, Frame{canvas, DEFAULT_GAP})
		edit = frame_count(img)
		account(g, len(canvas))
	}
	if c.z != 0 do frame_gap(img, edit)^ = int(c.z)
	if edit == max(img.anim.current, 1) do img.anim.version += 1
	g.changed = true
	enforce_quota(g.budget)
	gfx_reply(t, c, "OK")
}

// a=a: s state, c current frame, r+z frame gap, v loop count
animation_control :: proc(t: ^Term, c: Gfx_Cmd) {
	g := &t.gfx
	img := find_target(g, c)
	if img == nil {
		gfx_reply(t, c, "ENOENT:image not found")
		return
	}
	a := &img.anim
	n := frame_count(img)
	switch c.width {
	case 1:
		a.state = .Stopped
	case 2:
		a.state = .Loading
	case 3:
		a.state = .Running
	}
	if c.rows > 0 && c.rows <= n && c.z != 0 do frame_gap(img, c.rows)^ = int(c.z)
	if c.cols > 0 && c.cols <= n && c.cols != a.current {
		a.current = c.cols
		a.version += 1
		a.shown_at = 0
	}
	if c.height > 0 do a.loops = 0 if c.height == 1 else c.height - 1
	g.changed = true
	gfx_reply(t, c, "OK")
}

// a=c: copies a rectangle of frame r onto frame c
compose :: proc(t: ^Term, c: Gfx_Cmd) {
	g := &t.gfx
	img := find_target(g, c)
	if img == nil {
		gfx_reply(t, c, "ENOENT:image not found")
		return
	}
	n := frame_count(img)
	src, dst := max(c.rows, 1), max(c.cols, 1)
	if src > n || dst > n {
		gfx_reply(t, c, "EINVAL:no such frame")
		return
	}
	w := c.src[2] if c.src[2] > 0 else img.w
	h := c.src[3] if c.src[3] > 0 else img.h
	from := frame_pixels(img, src)
	if src == dst do from = slice.clone(from, context.temp_allocator)
	blit(frame_pixels(img, dst), img.w, img.h, from, img.w, img.h, c.src[0], c.src[1], w, h, c.off[0], c.off[1], c.no_move)
	if dst == max(img.anim.current, 1) do img.anim.version += 1
	g.changed = true
	gfx_reply(t, c, "OK")
}

// advances running animations that are on screen; returns ms until the next change or -1
animate :: proc(t: ^Term, now: i64) -> int {
	g := &t.gfx
	next := -1
	for img in g.images {
		a := &img.anim
		n := frame_count(img)
		if a.state == .Stopped || n < 2 || !image_used(g, img.id) do continue
		a.current = max(a.current, 1)
		if a.shown_at == 0 do a.shown_at = now
		// a few steps at most so zero gaps cannot spin
		for _ in 0 ..< n {
			gap := max(frame_gap(img, a.current)^, 0)
			if now - a.shown_at < i64(gap) {
				wait := int(i64(gap) - (now - a.shown_at))
				if next < 0 || wait < next do next = wait
				break
			}
			if a.current == n {
				if a.state == .Loading do break
				if a.loops == 1 {
					a.state = .Stopped
					break
				}
				if a.loops > 1 do a.loops -= 1
				a.current = 1
			} else {
				a.current += 1
			}
			a.shown_at += i64(gap)
			if now - a.shown_at > 1000 do a.shown_at = now
			a.version += 1
			g.changed = true
		}
	}
	return next
}

// row and column diacritics of unicode placeholders, in index order
PLACEHOLDER :: rune(0x10EEEE)

DIACRITICS := [?]rune {
	0x305, 0x30D, 0x30E, 0x310, 0x312, 0x33D, 0x33E, 0x33F, 0x346, 0x34A,
	0x34B, 0x34C, 0x350, 0x351, 0x352, 0x357, 0x35B, 0x363, 0x364, 0x365,
	0x366, 0x367, 0x368, 0x369, 0x36A, 0x36B, 0x36C, 0x36D, 0x36E, 0x36F,
	0x483, 0x484, 0x485, 0x486, 0x487, 0x592, 0x593, 0x594, 0x595, 0x597,
	0x598, 0x599, 0x59C, 0x59D, 0x59E, 0x59F, 0x5A0, 0x5A1, 0x5A8, 0x5A9,
	0x5AB, 0x5AC, 0x5AF, 0x5C4, 0x610, 0x611, 0x612, 0x613, 0x614, 0x615,
	0x616, 0x617, 0x657, 0x658, 0x659, 0x65A, 0x65B, 0x65D, 0x65E, 0x6D6,
	0x6D7, 0x6D8, 0x6D9, 0x6DA, 0x6DB, 0x6DC, 0x6DF, 0x6E0, 0x6E1, 0x6E2,
	0x6E4, 0x6E7, 0x6E8, 0x6EB, 0x6EC, 0x730, 0x732, 0x733, 0x735, 0x736,
	0x73A, 0x73D, 0x73F, 0x740, 0x741, 0x743, 0x745, 0x747, 0x749, 0x74A,
	0x7EB, 0x7EC, 0x7ED, 0x7EE, 0x7EF, 0x7F0, 0x7F1, 0x7F3, 0x816, 0x817,
	0x818, 0x819, 0x81B, 0x81C, 0x81D, 0x81E, 0x81F, 0x820, 0x821, 0x822,
	0x823, 0x825, 0x826, 0x827, 0x829, 0x82A, 0x82B, 0x82C, 0x82D, 0x951,
	0x953, 0x954, 0xF82, 0xF83, 0xF86, 0xF87, 0x135D, 0x135E, 0x135F, 0x17DD,
	0x193A, 0x1A17, 0x1A75, 0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C,
	0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
	0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6,
	0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
	0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF,
	0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
	0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0,
	0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6,
	0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0,
	0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1,
	0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9,
	0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2,
	0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
	0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189,
	0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

diacritic_index :: proc(r: rune) -> int {
	i, found := slice.binary_search(DIACRITICS[:], r)
	return i if found else -1
}

Placeholder :: struct {
	image: u32,
	place: u32,
	row:   int,
	col:   int,
}

// decodes a placeholder cell; missing row or column continue from the cell before
placeholder_at :: proc(cells: []Cell, x: int, prev: Placeholder, has_prev: bool) -> (p: Placeholder, ok: bool) {
	c := cells[x]
	if base_rune(c.ch) != PLACEHOLDER do return
	color_id :: proc(col: Color) -> u32 {
		switch u32(col) & 0xff000000 {
		case COLOR_RGB:
			return u32(col) & 0xffffff
		case COLOR_INDEXED:
			return u32(col) & 0xff
		}
		return 0
	}
	p.image = color_id(c.fg)
	p.place = color_id(c.ul)
	marks: [3]int = {-1, -1, -1}
	buf: [4]u8
	i := 0
	for r in cell_text(c.ch, &buf) {
		if r == PLACEHOLDER do continue
		if i < 3 do marks[i] = diacritic_index(r)
		i += 1
	}
	if marks[2] >= 0 do p.image |= u32(marks[2]) << 24
	switch {
	case marks[0] >= 0 && marks[1] >= 0:
		p.row, p.col = marks[0], marks[1]
	case marks[0] >= 0:
		p.row = marks[0]
		p.col = prev.col + 1 if has_prev && prev.row == p.row && prev.image == p.image else 0
	case has_prev && prev.image == p.image:
		p.row, p.col = prev.row, prev.col + 1
	}
	return p, true
}
