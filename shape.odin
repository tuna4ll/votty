package main

import "core:c"
import stbi "vendor:stb/image"

foreign import hb "system:harfbuzz"

Hb_Blob :: struct {}
Hb_Face :: struct {}
Hb_Font :: struct {}
Hb_Buffer :: struct {}

Hb_Glyph_Info :: struct {
	codepoint: u32,
	mask:      u32,
	cluster:   u32,
	var1:      u32,
	var2:      u32,
}

Hb_Glyph_Position :: struct {
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
	var:       u32,
}

HB_MEMORY_MODE_READONLY :: 1

@(default_calling_convention = "c")
foreign hb {
	hb_blob_create :: proc(data: [^]u8, length: c.uint, mode: c.int, user_data: rawptr, destroy: rawptr) -> ^Hb_Blob ---
	hb_blob_destroy :: proc(b: ^Hb_Blob) ---
	hb_face_create :: proc(blob: ^Hb_Blob, index: c.uint) -> ^Hb_Face ---
	hb_face_destroy :: proc(f: ^Hb_Face) ---
	hb_face_get_upem :: proc(f: ^Hb_Face) -> c.uint ---
	hb_face_get_glyph_count :: proc(f: ^Hb_Face) -> c.uint ---
	hb_font_create :: proc(face: ^Hb_Face) -> ^Hb_Font ---
	hb_font_destroy :: proc(f: ^Hb_Font) ---
	hb_font_set_scale :: proc(f: ^Hb_Font, x, y: c.int) ---
	hb_font_get_nominal_glyph :: proc(f: ^Hb_Font, unicode: u32, glyph: ^u32) -> b32 ---
	hb_buffer_create :: proc() -> ^Hb_Buffer ---
	hb_buffer_destroy :: proc(b: ^Hb_Buffer) ---
	hb_buffer_clear_contents :: proc(b: ^Hb_Buffer) ---
	hb_buffer_add_utf32 :: proc(b: ^Hb_Buffer, text: [^]u32, length: c.int, offset: c.uint, item_length: c.int) ---
	hb_buffer_guess_segment_properties :: proc(b: ^Hb_Buffer) ---
	hb_buffer_get_glyph_infos :: proc(b: ^Hb_Buffer, length: ^c.uint) -> [^]Hb_Glyph_Info ---
	hb_buffer_get_glyph_positions :: proc(b: ^Hb_Buffer, length: ^c.uint) -> [^]Hb_Glyph_Position ---
	hb_shape :: proc(font: ^Hb_Font, buf: ^Hb_Buffer, features: rawptr, num_features: c.uint) ---
}

Shaped :: struct {
	glyph:  u32,
	rune_i: int, // index of the code point this glyph came from
	x, y:   f32, // pen position in pixels, y up
}

// opens the harfbuzz side of a face; data must outlive it
hb_open :: proc(f: ^Face, index: int) -> bool {
	f.hb_blob = hb_blob_create(raw_data(f.data), c.uint(len(f.data)), HB_MEMORY_MODE_READONLY, nil, nil)
	f.hb_face = hb_face_create(f.hb_blob, c.uint(index))
	if hb_face_get_glyph_count(f.hb_face) == 0 {
		hb_close(f)
		return false
	}
	f.upem = int(hb_face_get_upem(f.hb_face))
	f.hb_font = hb_font_create(f.hb_face)
	hb_font_set_scale(f.hb_font, c.int(f.upem), c.int(f.upem))
	return true
}

hb_close :: proc(f: ^Face) {
	if f.hb_font != nil do hb_font_destroy(f.hb_font)
	if f.hb_face != nil do hb_face_destroy(f.hb_face)
	if f.hb_blob != nil do hb_blob_destroy(f.hb_blob)
	f.hb_font, f.hb_face, f.hb_blob = nil, nil, nil
}

// shapes a cluster with one face; positions are scaled to pixels
shape :: proc(f: ^Face, text: []rune, out: ^[dynamic]Shaped) {
	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)
	hb_buffer_add_utf32(buf, cast([^]u32)raw_data(text), c.int(len(text)), 0, c.int(len(text)))
	hb_buffer_guess_segment_properties(buf)
	hb_shape(f.hb_font, buf, nil, 0)
	n: c.uint
	infos := hb_buffer_get_glyph_infos(buf, &n)
	pos := hb_buffer_get_glyph_positions(buf, &n)
	pen: f32
	for i in 0 ..< int(n) {
		p := pos[i]
		append(out, Shaped{infos[i].codepoint, int(infos[i].cluster), pen + f32(p.x_offset) * f.scale, f32(p.y_offset) * f.scale})
		pen += f32(p.x_advance) * f.scale
	}
}

@(private = "file")
be16 :: #force_inline proc(d: []u8, o: int) -> int {
	if o < 0 || o + 2 > len(d) do return 0
	return int(d[o]) << 8 | int(d[o + 1])
}

@(private = "file")
be32 :: #force_inline proc(d: []u8, o: int) -> int {
	if o < 0 || o + 4 > len(d) do return 0
	return int(d[o]) << 24 | int(d[o + 1]) << 16 | int(d[o + 2]) << 8 | int(d[o + 3])
}

// offset of an sfnt table, or -1
find_table :: proc(d: []u8, start: int, tag: string) -> int {
	n := be16(d, start + 4)
	for i in 0 ..< n {
		r := start + 12 + 16 * i
		if r + 16 > len(d) do break
		if string(d[r:r + 4]) == tag do return be32(d, r + 8)
	}
	return -1
}

// the png image of a glyph in a cbdt color bitmap font
cbdt_png :: proc(f: ^Face, glyph: u32) -> []u8 {
	d := f.data
	cblc, cbdt := f.cblc, f.cbdt
	if cblc < 0 || cbdt < 0 do return nil
	g := int(glyph)
	// pick the largest strike that has the glyph; emoji fonts usually ship one
	best, best_ppem := -1, -1
	sizes := be32(d, cblc + 4)
	for i in 0 ..< min(sizes, 64) {
		bs := cblc + 8 + 48 * i
		lo, hi := be16(d, bs + 40), be16(d, bs + 42)
		ppem := int(d[bs + 44]) if bs + 44 < len(d) else 0
		if g >= lo && g <= hi && ppem > best_ppem do best, best_ppem = bs, ppem
	}
	if best < 0 do return nil
	array := cblc + be32(d, best)
	count := be32(d, best + 8)
	for i in 0 ..< min(count, 4096) {
		e := array + 8 * i
		first, last := be16(d, e), be16(d, e + 2)
		if g < first || g > last do continue
		sub := array + be32(d, e + 4)
		index_format, image_format := be16(d, sub), be16(d, sub + 2)
		data_off := cbdt + be32(d, sub + 4)
		start, end := -1, -1
		switch index_format {
		case 1:
			start = data_off + be32(d, sub + 8 + 4 * (g - first))
			end = data_off + be32(d, sub + 8 + 4 * (g - first + 1))
		case 2:
			size := be32(d, sub + 8)
			start = data_off + size * (g - first)
			end = start + size
		case 3:
			start = data_off + be16(d, sub + 8 + 2 * (g - first))
			end = data_off + be16(d, sub + 8 + 2 * (g - first + 1))
		case 4:
			n := be32(d, sub + 8)
			for k in 0 ..< min(n, 65536) {
				p := sub + 12 + 4 * k
				if be16(d, p) == g {
					start = data_off + be16(d, p + 2)
					end = data_off + be16(d, p + 6)
					break
				}
			}
		case 5:
			size := be32(d, sub + 8)
			n := be32(d, sub + 20)
			for k in 0 ..< min(n, 65536) {
				if be16(d, sub + 24 + 2 * k) == g {
					start = data_off + size * k
					end = start + size
					break
				}
			}
		}
		if start < 0 || end > len(d) || end <= start do return nil
		png: int
		switch image_format {
		case 17:
			png = start + 5
		case 18:
			png = start + 8
		case 19:
			png = start
		case:
			return nil
		}
		n := be32(d, png)
		if png + 4 + n > end || n <= 0 do return nil
		return d[png + 4:png + 4 + n]
	}
	return nil
}

// decodes a color glyph and box filters it into the color scratch, centered in width x cell_h
draw_color :: proc(f: ^Fonts, face: ^Face, glyph: u32, width: int) -> bool {
	png := cbdt_png(face, glyph)
	if png == nil do return false
	w, h, comp: c.int
	px := stbi.load_from_memory(raw_data(png), c.int(len(png)), &w, &h, &comp, 4)
	if px == nil do return false
	defer stbi.image_free(px)
	s := min(f32(width) / f32(w), f32(f.cell_h) / f32(h))
	dw, dh := max(int(f32(w) * s), 1), max(int(f32(h) * s), 1)
	ox, oy := (width - dw) / 2, (f.cell_h - dh) / 2
	sw := f.cell_w * 2
	for y in 0 ..< dh {
		sy0, sy1 := int(f32(y) / s), max(int(f32(y + 1) / s), int(f32(y) / s) + 1)
		for x in 0 ..< dw {
			sx0, sx1 := int(f32(x) / s), max(int(f32(x + 1) / s), int(f32(x) / s) + 1)
			acc: [4]f32
			cnt: f32
			for yy in sy0 ..< min(sy1, int(h)) {
				for xx in sx0 ..< min(sx1, int(w)) {
					p := px[(yy * int(w) + xx) * 4:]
					a := f32(p[3]) / 255
					// accumulate premultiplied so edges do not darken
					acc += {f32(p[0]) * a, f32(p[1]) * a, f32(p[2]) * a, f32(p[3])}
					cnt += 1
				}
			}
			if cnt == 0 do continue
			o := ((oy + y) * sw + ox + x) * 4
			for k in 0 ..< 4 do f.cscratch[o + k] = u8(clamp(acc[k] / cnt, 0, 255))
		}
	}
	return true
}
