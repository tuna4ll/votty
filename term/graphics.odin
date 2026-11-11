package term

import "core:bytes"
import "core:c"
import "core:compress/zlib"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"

// limits for untrusted image data
IMAGE_QUOTA :: 320 << 20
IMAGE_MAX_DIM :: 10000
IMAGE_MAX_PAYLOAD :: 400 << 20

Image :: struct {
	id:     u32,
	number: u32,
	w, h:   int,
	rgba:   []u8,
	serial: u64, // unique across terminals, keys gpu textures
	used:   u64, // insertion order for eviction
}

Placement :: struct {
	image:      u32,
	id:         u32,
	line:       int, // absolute line of the top row
	col:        int,
	cols, rows: int,
	src:        [4]int, // x, y, w, h in image pixels
	off:        [2]int,
	z:          i32,
	alt:        bool,
	fit:        bool, // scaled to cols x rows instead of natural size
}

Gfx_Cmd :: struct {
	action:   u8,
	quiet:    int,
	format:   int,
	medium:   u8,
	width:    int,
	height:   int,
	size:     int,
	offset:   int,
	id:       u32,
	number:   u32,
	pid:      u32,
	compress: u8,
	more:     bool,
	src:      [4]int,
	off:      [2]int,
	cols:     int,
	rows:     int,
	no_move:  bool,
	z:        i32,
	delete:   u8,
}

Graphics :: struct {
	images:     [dynamic]^Image,
	placements: [dynamic]Placement,
	loading:    bool,
	load_cmd:   Gfx_Cmd,
	load_data:  [dynamic]u8,
	load_bad:   bool,
	bytes:      int,
	next_id:    u32,
	clock:      u64,
	dropped:    [dynamic]u64, // serials whose textures can go
	changed:    bool,
}

@(private)
serial_counter: u64

graphics_free :: proc(g: ^Graphics) {
	for img in g.images {
		delete(img.rgba)
		free(img)
	}
	delete(g.images)
	delete(g.placements)
	delete(g.load_data)
	delete(g.dropped)
}

find_image :: proc(g: ^Graphics, id: u32) -> ^Image {
	for img in g.images do if img.id == id do return img
	return nil
}

@(private)
find_number :: proc(g: ^Graphics, n: u32) -> ^Image {
	#reverse for img in g.images do if img.number == n do return img
	return nil
}

@(private)
drop_image :: proc(g: ^Graphics, i: int) {
	img := g.images[i]
	g.bytes -= len(img.rgba)
	append(&g.dropped, img.serial)
	delete(img.rgba)
	free(img)
	ordered_remove(&g.images, i)
	g.changed = true
}

@(private)
image_used :: proc(g: ^Graphics, id: u32) -> bool {
	for p in g.placements do if p.image == id do return true
	return false
}

@(private)
parse_cmd :: proc(ctl: string) -> (c: Gfx_Cmd, ok: bool) {
	c.action = 't'
	c.format = 32
	c.medium = 'd'
	c.delete = 'a'
	rest := ctl
	for kv in strings.split_iterator(&rest, ",") {
		if len(kv) < 3 || kv[1] != '=' do return c, false
		key, val := kv[0], kv[2:]
		num := 0
		is_num := false
		if v, vok := strconv.parse_int(val, 10); vok {
			num = v
			is_num = true
		}
		u :: proc(n: int) -> u32 {return u32(clamp(n, 0, int(max(i32))))}
		switch key {
		case 'a':
			c.action = val[0]
		case 'q':
			c.quiet = num
		case 'f':
			c.format = num
		case 't':
			c.medium = val[0]
		case 's':
			c.width = num
		case 'v':
			c.height = num
		case 'S':
			c.size = num
		case 'O':
			c.offset = num
		case 'i':
			c.id = u(num)
		case 'I':
			c.number = u(num)
		case 'p':
			c.pid = u(num)
		case 'o':
			c.compress = val[0]
		case 'm':
			c.more = num == 1
		case 'x':
			c.src[0] = num
		case 'y':
			c.src[1] = num
		case 'w':
			c.src[2] = num
		case 'h':
			c.src[3] = num
		case 'X':
			c.off[0] = num
		case 'Y':
			c.off[1] = num
		case 'c':
			c.cols = num
		case 'r':
			c.rows = num
		case 'C':
			c.no_move = num == 1
		case 'z':
			c.z = i32(clamp(num, int(min(i32)), int(max(i32))))
		case 'd':
			c.delete = val[0]
		case 'U', 'P', 'Q', 'H', 'V':
		// unicode placeholders and relative placements are not supported
		}
		if !is_num && !strings.contains_rune("atodfU", rune(key)) do return c, false
		if is_num && num < 0 && key != 'z' do return c, false
	}
	return c, true
}

@(private)
gfx_reply :: proc(t: ^Term, c: Gfx_Cmd, msg: string) {
	is_ok := msg == "OK"
	if c.quiet >= 2 || (is_ok && c.quiet == 1) do return
	if c.id == 0 && c.number == 0 do return
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "\x1b_G")
	if c.id != 0 do fmt.sbprintf(&sb, "i=%d", c.id)
	if c.number != 0 do fmt.sbprintf(&sb, "%sI=%d", "," if c.id != 0 else "", c.number)
	if c.pid != 0 do fmt.sbprintf(&sb, ",p=%d", c.pid)
	fmt.sbprintf(&sb, ";%s\x1b\\", msg)
	append(&t.out, strings.to_string(sb))
}

// handles the body of an APC G sequence
graphics_command :: proc(t: ^Term, body: []u8) {
	g := &t.gfx
	s := string(body)
	semi := strings.index_byte(s, ';')
	ctl := s if semi < 0 else s[:semi]
	payload := "" if semi < 0 else s[semi + 1:]
	c, ok := parse_cmd(ctl)
	if g.loading {
		// continuation chunks carry only m and maybe q
		if !ok {
			g.load_bad = true
		}
		append_chunk(g, payload)
		if c.more do return
		g.loading = false
		finish_transmit(t, g.load_cmd)
		return
	}
	if !ok {
		gfx_reply(t, c, "EINVAL:bad control data")
		return
	}
	switch c.action {
	case 't', 'T', 'q':
		if c.id == 0 && c.number == 0 && c.action == 'q' do return
		clear(&g.load_data)
		g.load_bad = false
		g.load_cmd = c
		append_chunk(g, payload)
		if c.more {
			g.loading = true
			return
		}
		finish_transmit(t, c)
	case 'p':
		img := find_image(g, c.id) if c.id != 0 else find_number(g, c.number)
		if img == nil {
			gfx_reply(t, c, "ENOENT:image not found")
			return
		}
		c.id = img.id
		place(t, img, c)
		gfx_reply(t, c, "OK")
	case 'd':
		graphics_delete(t, c)
	case:
		gfx_reply(t, c, "EINVAL:unsupported action")
	}
}

@(private)
append_chunk :: proc(g: ^Graphics, payload: string) {
	if g.load_bad || len(payload) == 0 do return
	if len(g.load_data) + len(payload) * 3 / 4 > IMAGE_MAX_PAYLOAD {
		g.load_bad = true
		return
	}
	dec, err := base64.decode(payload, allocator = context.temp_allocator)
	if err != nil {
		g.load_bad = true
		return
	}
	append(&g.load_data, ..dec)
}

@(private)
finish_transmit :: proc(t: ^Term, c: Gfx_Cmd) {
	g := &t.gfx
	c := c
	defer {
		if cap(g.load_data) > 1 << 20 {
			delete(g.load_data)
			g.load_data = {}
		}
		clear(&g.load_data)
	}
	if g.load_bad {
		gfx_reply(t, c, "EINVAL:bad payload")
		return
	}
	data := g.load_data[:]
	switch c.medium {
	case 'd':
	case 'f', 't', 's':
		file, ferr := read_medium(c, string(data))
		if ferr != "" {
			gfx_reply(t, c, ferr)
			return
		}
		data = file
	case:
		gfx_reply(t, c, "EINVAL:unsupported transmission medium")
		return
	}
	if c.compress == 'z' {
		var: bytes.Buffer
		defer bytes.buffer_destroy(&var)
		if zlib.inflate(data, &var) != nil {
			gfx_reply(t, c, "EINVAL:zlib inflate failed")
			return
		}
		data = bytes.clone(bytes.buffer_to_bytes(&var), context.temp_allocator)
	}
	rgba, w, h, derr := decode_pixels(c, data)
	if derr != "" {
		gfx_reply(t, c, derr)
		return
	}
	if c.action == 'q' {
		delete(rgba)
		gfx_reply(t, c, "OK")
		return
	}
	if c.id == 0 {
		// numbered images get an id the client can learn from the reply
		g.next_id += 1
		for find_image(g, g.next_id | 0x80000000) != nil do g.next_id += 1
		c.id = g.next_id | 0x80000000 if c.number != 0 else 0
	}
	if old := find_image(g, c.id); old != nil && c.id != 0 {
		g.bytes -= len(old.rgba)
		append(&g.dropped, old.serial)
		delete(old.rgba)
		old.rgba = rgba
		old.w, old.h = w, h
		serial_counter += 1
		old.serial = serial_counter
		old.number = c.number
		g.bytes += len(rgba)
	} else {
		img := new(Image)
		img^ = {id = c.id, number = c.number, w = w, h = h, rgba = rgba}
		serial_counter += 1
		img.serial = serial_counter
		g.clock += 1
		img.used = g.clock
		append(&g.images, img)
		g.bytes += len(rgba)
	}
	enforce_quota(g)
	g.changed = true
	img := find_image(g, c.id)
	if c.action == 'T' && img != nil do place(t, img, c)
	gfx_reply(t, c, "OK")
}

@(private)
read_medium :: proc(c: Gfx_Cmd, name: string) -> (data: []u8, err: string) {
	path := name
	if c.medium == 's' {
		if strings.contains_rune(name, '/') do return nil, "EINVAL:bad shared memory name"
		path = strings.concatenate({"/dev/shm/", strings.trim_left(name, "/")}, context.temp_allocator)
	}
	if strings.has_prefix(path, "/proc/") || strings.has_prefix(path, "/sys/") || strings.has_prefix(path, "/dev/") && c.medium != 's' {
		return nil, "EPERM:refusing to read special files"
	}
	if c.medium == 't' && !strings.contains(path, "tty-graphics-protocol") {
		return nil, "EPERM:temporary file name must contain tty-graphics-protocol"
	}
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil || fi.type != .Regular do return nil, "EBADF:cannot read file"
	if fi.size > IMAGE_MAX_PAYLOAD do return nil, "EFBIG:file too large"
	raw, rerr := os.read_entire_file(path, context.temp_allocator)
	if c.medium == 't' || c.medium == 's' do os.remove(path)
	if rerr != nil do return nil, "EBADF:cannot read file"
	lo := min(c.offset, len(raw))
	hi := len(raw) if c.size == 0 else min(lo + c.size, len(raw))
	return raw[lo:hi], ""
}

@(private)
decode_pixels :: proc(cmd: Gfx_Cmd, data: []u8) -> (rgba: []u8, w, h: int, err: string) {
	switch cmd.format {
	case 100:
		if len(data) == 0 || len(data) > int(max(i32)) do return nil, 0, 0, "EBADPNG:empty or oversized data"
		iw, ih, comp: c.int
		if stbi.info_from_memory(raw_data(data), c.int(len(data)), &iw, &ih, &comp) == 0 {
			return nil, 0, 0, "EBADPNG:cannot decode image"
		}
		if iw <= 0 || ih <= 0 || iw > IMAGE_MAX_DIM || ih > IMAGE_MAX_DIM do return nil, 0, 0, "EFBIG:image too large"
		px := stbi.load_from_memory(raw_data(data), c.int(len(data)), &iw, &ih, &comp, 4)
		if px == nil do return nil, 0, 0, "EBADPNG:cannot decode image"
		defer stbi.image_free(px)
		n := int(iw) * int(ih) * 4
		rgba = make([]u8, n)
		copy(rgba, px[:n])
		return rgba, int(iw), int(ih), ""
	case 24, 32:
		w, h = cmd.width, cmd.height
		if w <= 0 || h <= 0 do return nil, 0, 0, "EINVAL:missing width or height"
		if w > IMAGE_MAX_DIM || h > IMAGE_MAX_DIM do return nil, 0, 0, "EFBIG:image too large"
		bpp := cmd.format / 8
		if len(data) < w * h * bpp do return nil, 0, 0, "ENODATA:insufficient image data"
		rgba = make([]u8, w * h * 4)
		if bpp == 4 {
			copy(rgba, data[:w * h * 4])
		} else {
			for i in 0 ..< w * h {
				rgba[i * 4 + 0] = data[i * 3 + 0]
				rgba[i * 4 + 1] = data[i * 3 + 1]
				rgba[i * 4 + 2] = data[i * 3 + 2]
				rgba[i * 4 + 3] = 255
			}
		}
		return rgba, w, h, ""
	}
	return nil, 0, 0, "EINVAL:unknown format"
}

// evicts the oldest unplaced images first, then the oldest overall
@(private)
enforce_quota :: proc(g: ^Graphics) {
	for g.bytes > IMAGE_QUOTA && len(g.images) > 1 {
		victim := -1
		for img, i in g.images {
			if !image_used(g, img.id) {
				victim = i
				break
			}
		}
		if victim < 0 {
			victim = 0
			id := g.images[0].id
			#reverse for p, i in g.placements do if p.image == id do ordered_remove(&g.placements, i)
		}
		drop_image(g, victim)
	}
}

@(private)
place :: proc(t: ^Term, img: ^Image, c: Gfx_Cmd) {
	g := &t.gfx
	src := c.src
	src[0] = min(src[0], img.w)
	src[1] = min(src[1], img.h)
	if src[2] == 0 || src[0] + src[2] > img.w do src[2] = img.w - src[0]
	if src[3] == 0 || src[1] + src[3] > img.h do src[3] = img.h - src[1]
	cols, rows := c.cols, c.rows
	pw, ph := src[2] + c.off[0], src[3] + c.off[1]
	if cols == 0 && rows == 0 {
		cols = (pw + t.cell_w - 1) / t.cell_w
		rows = (ph + t.cell_h - 1) / t.cell_h
	} else if cols == 0 {
		// keep the aspect ratio when only one dimension is given
		cols = max((rows * t.cell_h * src[2] / max(src[3], 1) + t.cell_w - 1) / t.cell_w, 1)
	} else if rows == 0 {
		rows = max((cols * t.cell_w * src[3] / max(src[2], 1) + t.cell_h - 1) / t.cell_h, 1)
	}
	cols, rows = clamp(cols, 1, 1000), clamp(rows, 1, 1000)
	p := Placement {
		image = img.id,
		id    = c.pid,
		line  = t.hist.total + t.cur.y,
		col   = t.cur.x,
		cols  = cols,
		rows  = rows,
		src   = src,
		off   = c.off,
		z     = c.z,
		alt   = t.scr == &t.alt,
		fit   = c.cols != 0 || c.rows != 0,
	}
	// the same image and placement id replaces the old placement
	replaced := false
	if c.pid != 0 {
		for &q in g.placements {
			if q.image == p.image && q.id == p.id {
				q = p
				replaced = true
			}
		}
	}
	if !replaced do append(&g.placements, p)
	g.changed = true
	if c.no_move do return
	for _ in 0 ..< rows - 1 do linefeed(t)
	t.cur.x = min(t.cur.x + cols, t.cols - 1)
	t.cur.wrap = false
	t.output_seq += 1
}

@(private)
graphics_delete :: proc(t: ^Term, c: Gfx_Cmd) {
	g := &t.gfx
	d := c.delete
	free_data := d >= 'A' && d <= 'Z'
	lower := d | 0x20
	alt := t.scr == &t.alt
	cell_x := c.src[0] - 1
	cell_y := c.src[1] - 1
	hits :: proc(t: ^Term, p: Placement, x, y: int) -> bool {
		top := p.line - t.hist.total
		return (x < 0 || (x >= p.col && x < p.col + p.cols)) && (y < 0 || (y >= top && y < top + p.rows))
	}
	target_id := c.id
	if lower == 'n' {
		img := find_number(g, c.number)
		if img == nil do return
		target_id = img.id
	}
	touched := make([dynamic]u32, context.temp_allocator)
	#reverse for p, i in g.placements {
		if p.alt != alt && lower != 'i' && lower != 'n' && lower != 'r' do continue
		del := false
		switch lower {
		case 'a':
			del = true
		case 'i', 'n':
			del = p.image == target_id && (c.pid == 0 || p.id == c.pid)
		case 'c':
			del = hits(t, p, t.cur.x, t.cur.y)
		case 'p':
			del = hits(t, p, cell_x, cell_y)
		case 'q':
			del = hits(t, p, cell_x, cell_y) && p.z == c.z
		case 'x':
			del = hits(t, p, cell_x, -1)
		case 'y':
			del = hits(t, p, -1, cell_y)
		case 'z':
			del = p.z == c.z
		case 'r':
			del = int(p.image) >= c.src[0] && int(p.image) <= c.src[1]
		}
		if del {
			append(&touched, p.image)
			ordered_remove(&g.placements, i)
			g.changed = true
		}
	}
	if !free_data do return
	// uppercase variants free images that no placement uses anymore
	if lower == 'i' || lower == 'n' do append(&touched, target_id)
	#reverse for img, i in g.images {
		hit := false
		for id in touched do if id == img.id do hit = true
		if hit && !image_used(g, img.id) do drop_image(g, i)
	}
}

// placements whose last row scrolled out of history go away
graphics_drop_before :: proc(t: ^Term, line: int) {
	g := &t.gfx
	#reverse for p, i in g.placements {
		if !p.alt && p.line + p.rows <= line {
			ordered_remove(&g.placements, i)
			g.changed = true
		}
	}
}

// moves placements inside a scrolled region of the active screen; n < 0 scrolls up
graphics_scroll :: proc(t: ^Term, top, bot, n: int) {
	g := &t.gfx
	alt := t.scr == &t.alt
	base := t.hist.total
	#reverse for &p, i in g.placements {
		if p.alt != alt do continue
		y := p.line - base
		if y < top || y > bot do continue
		y += n
		if y + p.rows <= top || y > bot {
			ordered_remove(&g.placements, i)
		} else {
			p.line = base + y
		}
		g.changed = true
	}
}

// a full screen erase removes the placements on it
graphics_clear_screen :: proc(t: ^Term) {
	g := &t.gfx
	alt := t.scr == &t.alt
	base := t.hist.total
	#reverse for p, i in g.placements {
		if p.alt == alt && p.line + p.rows > base {
			ordered_remove(&g.placements, i)
			g.changed = true
		}
	}
}

graphics_resize :: proc(t: ^Term, alt_delta: int) {
	g := &t.gfx
	for &p in g.placements do if p.alt do p.line += alt_delta
	g.changed = true
}

graphics_reset :: proc(t: ^Term) {
	g := &t.gfx
	clear(&g.placements)
	#reverse for _, i in g.images do drop_image(g, i)
	g.loading = false
	clear(&g.load_data)
}
