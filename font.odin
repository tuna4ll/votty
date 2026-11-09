package main

import "core:c"
import "core:math"
import "core:os"
import "core:strings"
import stbtt "vendor:stb/truetype"
import gl "vendor:OpenGL"

foreign import fc "system:fontconfig"

Fc_Pattern :: struct {}
Fc_Charset :: struct {}

@(default_calling_convention = "c")
foreign fc {
	FcInit :: proc() -> b32 ---
	FcNameParse :: proc(name: cstring) -> ^Fc_Pattern ---
	FcConfigSubstitute :: proc(config: rawptr, p: ^Fc_Pattern, kind: c.int) -> b32 ---
	FcDefaultSubstitute :: proc(p: ^Fc_Pattern) ---
	FcFontMatch :: proc(config: rawptr, p: ^Fc_Pattern, result: ^c.int) -> ^Fc_Pattern ---
	FcPatternGetString :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, s: ^cstring) -> c.int ---
	FcPatternGetInteger :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, i: ^c.int) -> c.int ---
	FcPatternAddCharSet :: proc(p: ^Fc_Pattern, object: cstring, cs: ^Fc_Charset) -> b32 ---
	FcPatternDestroy :: proc(p: ^Fc_Pattern) ---
	FcCharSetCreate :: proc() -> ^Fc_Charset ---
	FcCharSetAddChar :: proc(cs: ^Fc_Charset, ch: u32) -> b32 ---
	FcCharSetDestroy :: proc(cs: ^Fc_Charset) ---
}

Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

Face :: struct {
	path:      string,
	data:      []u8,
	info:      stbtt.fontinfo,
	scale:     f32,
	fake_bold:   bool,
	fake_italic: bool,
}

Glyph_Key :: struct {
	ch:    rune,
	mark:  u16,
	style: Style,
}

ATLAS_SIZE :: 2048

Fonts :: struct {
	family:     string,
	size:       f32, // points
	px:         f32,
	faces:      [Style]^Face,
	fallbacks:  [dynamic]^Face,
	missing:    map[rune]bool, // no installed font covers these
	cell_w:     int,
	cell_h:     int,
	baseline:   int,
	underline:  int,
	thickness:  int,
	// atlas of cell sized slots; slot 0 stays empty
	tex:        u32,
	slots_x:    int,
	slots:      int,
	next:       int,
	ascii:      [Style][128]u32,
	cache:      map[Glyph_Key]u32,
	generation: int,
	scratch:    []u8,
}

fc_match :: proc(query: string, ch: rune = 0) -> (path: string, index: int, ok: bool) {
	pat := FcNameParse(strings.clone_to_cstring(query, context.temp_allocator))
	if pat == nil do return
	defer FcPatternDestroy(pat)
	if ch != 0 {
		cs := FcCharSetCreate()
		FcCharSetAddChar(cs, u32(ch))
		FcPatternAddCharSet(pat, "charset", cs)
		FcCharSetDestroy(cs)
	}
	FcConfigSubstitute(nil, pat, 0)
	FcDefaultSubstitute(pat)
	res: c.int
	m := FcFontMatch(nil, pat, &res)
	if m == nil do return
	defer FcPatternDestroy(m)
	file: cstring
	if FcPatternGetString(m, "file", 0, &file) != 0 do return
	idx: c.int
	FcPatternGetInteger(m, "index", 0, &idx)
	return strings.clone(string(file)), int(idx), true
}

load_face :: proc(path: string, index: int) -> ^Face {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil
	f := new(Face)
	f.path = path
	f.data = data
	off := stbtt.GetFontOffsetForIndex(raw_data(data), c.int(index))
	if off < 0 || !stbtt.InitFont(&f.info, raw_data(data), off) {
		delete(data)
		free(f)
		return nil
	}
	return f
}

free_face :: proc(f: ^Face) {
	delete(f.data)
	delete(f.path)
	free(f)
}

fonts_init :: proc(f: ^Fonts, family: string, size: f32, dpi_scale: f32) -> bool {
	FcInit()
	f.family = family
	f.size = size
	queries := [Style]string {
		.Regular     = family,
		.Bold        = strings.concatenate({family, ":weight=bold"}, context.temp_allocator),
		.Italic      = strings.concatenate({family, ":slant=italic"}, context.temp_allocator),
		.Bold_Italic = strings.concatenate({family, ":weight=bold:slant=italic"}, context.temp_allocator),
	}
	for q, s in queries {
		path, idx, ok := fc_match(q)
		if !ok do continue
		// a style that resolves to an already loaded upright face gets synthesized instead
		reg, bold := f.faces[.Regular], f.faces[.Bold]
		if s != .Regular && ((reg != nil && path == reg.path) || (s == .Bold_Italic && bold != nil && path == bold.path)) {
			delete(path)
			continue
		}
		f.faces[s] = load_face(path, idx)
		if f.faces[s] == nil do delete(path)
	}
	if f.faces[.Regular] == nil do return false
	// synthesize missing styles from the closest face
	if f.faces[.Bold] == nil do f.faces[.Bold] = fake_style(f.faces[.Regular], true)
	if f.faces[.Italic] == nil {
		f.faces[.Italic] = fake_style(f.faces[.Regular], false)
		f.faces[.Italic].fake_italic = true
	}
	if f.faces[.Bold_Italic] == nil {
		if f.faces[.Bold].fake_bold {
			f.faces[.Bold_Italic] = fake_style(f.faces[.Italic], true)
		} else {
			f.faces[.Bold_Italic] = fake_style(f.faces[.Bold], false)
			f.faces[.Bold_Italic].fake_italic = true
		}
	}
	fonts_set_size(f, size, dpi_scale)
	return true
}

@(private = "file")
fake_style :: proc(base: ^Face, bold: bool) -> ^Face {
	b := new(Face)
	b^ = base^
	b.path = strings.clone(base.path)
	b.data = nil
	if bold do b.fake_bold = true
	return b
}

fonts_destroy :: proc(f: ^Fonts) {
	for s in Style {
		face := f.faces[s]
		if face == nil do continue
		// styles may alias the same face
		for t in Style do if t > s && f.faces[t] == face do f.faces[t] = nil
		if face.data == nil {
			delete(face.path)
			free(face)
		} else {
			free_face(face)
		}
	}
	for fb in f.fallbacks do free_face(fb)
	delete(f.fallbacks)
	delete(f.missing)
	delete(f.cache)
	delete(f.scratch)
	if f.tex != 0 do gl.DeleteTextures(1, &f.tex)
}

fonts_set_size :: proc(f: ^Fonts, size: f32, dpi_scale: f32) {
	f.size = clamp(size, 4, 200)
	f.px = f.size * 96.0 / 72.0 * dpi_scale
	reg := f.faces[.Regular]
	scale := stbtt.ScaleForMappingEmToPixels(&reg.info, f.px)
	for face in f.faces do face.scale = scale
	for fb in f.fallbacks do fb.scale = stbtt.ScaleForMappingEmToPixels(&fb.info, f.px)
	asc, desc, gap: c.int
	stbtt.GetFontVMetrics(&reg.info, &asc, &desc, &gap)
	adv, lsb: c.int
	stbtt.GetGlyphHMetrics(&reg.info, stbtt.FindGlyphIndex(&reg.info, 'M'), &adv, &lsb)
	f.cell_w = max(int(math.round(f32(adv) * scale)), 1)
	f.cell_h = max(int(math.ceil(f32(asc - desc + gap) * scale)), 1)
	f.baseline = int(math.round(f32(asc) * scale + f32(gap) * scale / 2))
	f.thickness = max(int(math.round(f.px / 14)), 1)
	f.underline = min(f.baseline + f.thickness + 1, f.cell_h - f.thickness)
	atlas_reset(f)
}

atlas_reset :: proc(f: ^Fonts) {
	if f.tex == 0 {
		gl.GenTextures(1, &f.tex)
		gl.BindTexture(gl.TEXTURE_2D, f.tex)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, ATLAS_SIZE, ATLAS_SIZE, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
	}
	f.slots_x = ATLAS_SIZE / f.cell_w
	f.slots = f.slots_x * (ATLAS_SIZE / f.cell_h)
	f.next = 1
	clear(&f.cache)
	for s in Style do f.ascii[s] = {}
	f.generation += 1
	delete(f.scratch)
	f.scratch = make([]u8, f.cell_w * 2 * f.cell_h)
	// clear slot 0 so empty cells sample nothing
	gl.BindTexture(gl.TEXTURE_2D, f.tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, i32(f.cell_w), i32(f.cell_h), gl.RED, gl.UNSIGNED_BYTE, raw_data(f.scratch))
}

@(private = "file")
face_for :: proc(f: ^Fonts, ch: rune, style: Style) -> (^Face, c.int) {
	face := f.faces[style]
	if g := stbtt.FindGlyphIndex(&face.info, ch); g != 0 do return face, g
	if style != .Regular {
		face = f.faces[.Regular]
		if g := stbtt.FindGlyphIndex(&face.info, ch); g != 0 do return face, g
	}
	for fb in f.fallbacks {
		if g := stbtt.FindGlyphIndex(&fb.info, ch); g != 0 do return fb, g
	}
	if ch in f.missing do return nil, 0
	path, idx, ok := fc_match(f.family, ch)
	if ok {
		for fb in f.fallbacks do if fb.path == path {
			delete(path)
			f.missing[ch] = true
			return nil, 0
		}
		if path == f.faces[.Regular].path {
			delete(path)
		} else if fb := load_face(path, idx); fb != nil {
			if g := stbtt.FindGlyphIndex(&fb.info, ch); g != 0 {
				fb.scale = stbtt.ScaleForMappingEmToPixels(&fb.info, f.px)
				append(&f.fallbacks, fb)
				return fb, g
			}
			free_face(fb)
		} else {
			delete(path)
		}
	}
	f.missing[ch] = true
	return nil, 0
}

// draws a glyph into the scratch bitmap at pen x, max-blending coverage
@(private = "file")
draw_glyph :: proc(f: ^Fonts, face: ^Face, g: c.int, pen_x: f32, width: int) {
	scale := face.scale
	// shrink fallback glyphs that would overflow their cells
	adv, lsb: c.int
	stbtt.GetGlyphHMetrics(&face.info, g, &adv, &lsb)
	if face != f.faces[.Regular] && f32(adv) * scale > f32(width) * 1.05 && adv > 0 {
		scale = f32(width) / f32(adv)
	}
	x0, y0, x1, y1: c.int
	stbtt.GetGlyphBitmapBoxSubpixel(&face.info, g, scale, scale, 0, 0, &x0, &y0, &x1, &y1)
	gw, gh := int(x1 - x0), int(y1 - y0)
	if gw <= 0 || gh <= 0 || gw > 4096 || gh > 4096 do return
	tmp := make([]u8, gw * gh, context.temp_allocator)
	stbtt.MakeGlyphBitmapSubpixel(&face.info, raw_data(tmp), c.int(gw), c.int(gh), c.int(gw), scale, scale, 0, 0, g)
	ox := int(math.round(pen_x)) + int(x0)
	oy := f.baseline + int(y0)
	sw := f.cell_w * 2
	passes := 2 if face.fake_bold else 1
	for pass in 0 ..< passes {
		for y in 0 ..< gh {
			dy := oy + y
			if dy < 0 || dy >= f.cell_h do continue
			// shear rows for a synthetic slant
			slant := int(f32(f.baseline - dy) * 0.2) if face.fake_italic else 0
			for x in 0 ..< gw {
				dx := ox + x + pass + slant
				if dx < 0 || dx >= width do continue
				v := tmp[y * gw + x]
				d := &f.scratch[dy * sw + dx]
				if v > d^ do d^ = v
			}
		}
	}
}

// returns the atlas slot of a glyph, rasterizing on first use; wide glyphs own slot+1 too
glyph_slot :: proc(f: ^Fonts, ch: rune, mark: u16, style: Style, wide: bool) -> u32 {
	if ch <= ' ' && mark == 0 do return 0
	if ch < 128 && mark == 0 {
		if id := f.ascii[style][ch]; id != 0 do return id
	} else {
		if id, ok := f.cache[{ch, mark, style}]; ok do return id
	}
	n := 2 if wide else 1
	// keep both halves of a wide glyph on one atlas row
	if wide && f.next % f.slots_x == f.slots_x - 1 do f.next += 1
	if f.next + n > f.slots {
		atlas_reset(f)
		return glyph_slot(f, ch, mark, style, wide)
	}
	id := u32(f.next)
	f.next += n
	width := f.cell_w * n
	for &b in f.scratch do b = 0
	if is_box_char(ch) && !wide {
		draw_box_char(f, ch)
	} else if face, g := face_for(f, ch, style); face != nil {
		draw_glyph(f, face, g, 0, width)
		if mark != 0 && !(mark >= 0xfe00 && mark <= 0xfe0f) {
			if mface, mg := face_for(f, rune(mark), style); mface != nil {
				adv, lsb: c.int
				stbtt.GetGlyphHMetrics(&mface.info, mg, &adv, &lsb)
				pen: f32 = 0 if adv > 0 else f32(f.cell_w)
				draw_glyph(f, mface, mg, pen, width)
			}
		}
	} else if ch > ' ' {
		draw_box(f, width)
	}
	gl.BindTexture(gl.TEXTURE_2D, f.tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(f.cell_w * 2))
	sx := int(id) % f.slots_x * f.cell_w
	sy := int(id) / f.slots_x * f.cell_h
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(sx), i32(sy), i32(width), i32(f.cell_h), gl.RED, gl.UNSIGNED_BYTE, raw_data(f.scratch))
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	if ch < 128 && mark == 0 {
		f.ascii[style][ch] = id
	} else {
		f.cache[{ch, mark, style}] = id
	}
	return id
}

// hollow box for chars no font can draw
@(private = "file")
draw_box :: proc(f: ^Fonts, width: int) {
	sw := f.cell_w * 2
	x0, x1 := 1, width - 2
	y0, y1 := f.cell_h / 5, f.baseline
	if x1 <= x0 || y1 <= y0 do return
	for x in x0 ..= x1 {
		f.scratch[y0 * sw + x] = 160
		f.scratch[y1 * sw + x] = 160
	}
	for y in y0 ..= y1 {
		f.scratch[y * sw + x0] = 160
		f.scratch[y * sw + x1] = 160
	}
}
