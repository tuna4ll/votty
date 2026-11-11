package term

import "core:unicode"

// top byte tags the color kind; low bits hold an index or rgb
Color :: distinct u32

COLOR_DEFAULT :: Color(0)
COLOR_INDEXED :: 0x01000000
COLOR_RGB :: 0x02000000

color_index :: #force_inline proc "contextless" (i: int) -> Color {return Color(COLOR_INDEXED | u32(i & 0xff))}
color_rgb :: #force_inline proc "contextless" (r, g, b: int) -> Color {
	return Color(COLOR_RGB | u32(r & 0xff) << 16 | u32(g & 0xff) << 8 | u32(b & 0xff))
}

Attr :: enum u16 {
	Bold,
	Faint,
	Italic,
	Underline,
	Double_Underline,
	Curly_Underline,
	Blink,
	Inverse,
	Invisible,
	Strike,
	Overline,
	Wide, // first half of a double width char
	Spacer, // second half of a double width char
}
Attrs :: bit_set[Attr;u16]

// 16 bytes; the renderer reads rows of these directly
Cell :: struct {
	ch:    rune,
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
	// shortcut: one combining mark per cell from the bmp, extend if multi-mark scripts matter
	mark:  u16,
}
#assert(size_of(Cell) == 16)

Mode :: enum {
	Wrap,
	Origin,
	Insert,
	Newline,
	App_Cursor,
	App_Keypad,
	Cursor_Visible,
	Cursor_Blink,
	Reverse_Video,
	Bracketed_Paste,
	Mouse_X10,
	Mouse_Press, // 1000
	Mouse_Drag, // 1002
	Mouse_Motion, // 1003
	Mouse_Sgr,
	Focus_Events,
	Alt_Scroll,
	Alt_Screen,
	Sync_Output,
}
Modes :: bit_set[Mode]

MOUSE_MODES :: Modes{.Mouse_X10, .Mouse_Press, .Mouse_Drag, .Mouse_Motion}

Cursor_Shape :: enum u8 {
	Block,
	Underline,
	Bar,
}

Cursor :: struct {
	x, y:    int,
	pen:     Cell,
	wrap:    bool, // pending wrap at the right margin
	origin:  bool,
	charset: [2]u8,
	gl:      int,
}

Screen :: struct {
	cells:    []Cell,
	lines:    []int, // logical row -> physical row
	wrapped:  []bool, // by physical row
	dirty:    []bool, // by physical row
	remapped: bool,
	saved:    Cursor,
}

History_Line :: struct {
	cells:   [dynamic]Cell,
	wrapped: bool,
}

// ring of lines that scrolled off the primary screen
History :: struct {
	lines: []History_Line,
	head:  int,
	count: int,
	total: int, // lines ever pushed, the absolute line base of the screen
}

Term :: struct {
	cols, rows:   int,
	cell_w:       int,
	cell_h:       int,
	primary, alt: Screen,
	scr:          ^Screen,
	cur:          Cursor,
	top, bot:     int,
	modes:        Modes,
	tabs:         []bool,
	hist:         History,
	view:         int, // lines scrolled back into history
	parser:       Parser,
	shape:        Cursor_Shape,
	last_ch:      rune,
	palette:      [256]u32,
	fg, bg:       u32,
	cursor_color: u32,
	title:        [dynamic]u8,
	title_dirty:  bool,
	cwd:          [dynamic]u8,
	bell:         bool,
	clipboard:    [dynamic]u8,
	clip_dirty:   bool,
	out:          [dynamic]u8, // replies for the pty
	all_dirty:    bool,
	theme:        Theme,
	gfx:          Graphics,
	output_seq:   u64, // bumped on content changes, used by search
}

// user defaults restored by resets
Theme :: struct {
	palette:      [256]u32,
	fg, bg:       u32,
	cursor_color: u32,
	shape:        Cursor_Shape,
	blink:        bool,
}

DEFAULT_FG :: 0xd8d8d8
DEFAULT_BG :: 0x1a1b1e

default_palette :: proc(p: ^[256]u32) {
	base := [16]u32 {
		0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
		0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
	}
	copy(p[:16], base[:])
	steps := [6]u32{0, 95, 135, 175, 215, 255}
	for i in 0 ..< 216 {
		p[16 + i] = steps[i / 36] << 16 | steps[i / 6 % 6] << 8 | steps[i % 6]
	}
	for i in 0 ..< 24 {
		v := u32(8 + i * 10)
		p[232 + i] = v << 16 | v << 8 | v
	}
}

make_term :: proc(cols, rows: int, history_limit := 10000) -> ^Term {
	t := new(Term)
	t.cols = max(cols, 1)
	t.rows = max(rows, 1)
	t.cell_w = 8
	t.cell_h = 16
	screen_init(&t.primary, t.cols, t.rows)
	screen_init(&t.alt, t.cols, t.rows)
	t.scr = &t.primary
	t.hist.lines = make([]History_Line, max(history_limit, 1))
	t.tabs = make([]bool, t.cols)
	default_palette(&t.theme.palette)
	t.theme.fg = DEFAULT_FG
	t.theme.bg = DEFAULT_BG
	t.theme.cursor_color = DEFAULT_FG
	set_theme(t, t.theme)
	return t
}

destroy_term :: proc(t: ^Term) {
	screen_free(&t.primary)
	screen_free(&t.alt)
	for &l in t.hist.lines do delete(l.cells)
	delete(t.hist.lines)
	delete(t.tabs)
	delete(t.title)
	delete(t.cwd)
	delete(t.clipboard)
	delete(t.out)
	parser_free(&t.parser)
	graphics_free(&t.gfx)
	free(t)
}

set_theme :: proc(t: ^Term, th: Theme) {
	t.theme = th
	t.palette = th.palette
	t.fg = th.fg
	t.bg = th.bg
	t.cursor_color = th.cursor_color
	reset(t)
}

reset :: proc(t: ^Term) {
	t.modes = {.Wrap, .Cursor_Visible}
	if t.theme.blink do t.modes += {.Cursor_Blink}
	t.cur = {}
	t.cur.charset = {'B', 'B'}
	t.top = 0
	t.bot = t.rows - 1
	t.shape = t.theme.shape
	t.scr = &t.primary
	t.primary.saved = t.cur
	t.alt.saved = t.cur
	for i in 0 ..< t.cols do t.tabs[i] = i % 8 == 0
	screen_clear(t, &t.primary)
	screen_clear(t, &t.alt)
	t.all_dirty = true
}

@(private)
screen_init :: proc(s: ^Screen, cols, rows: int) {
	s.cells = make([]Cell, cols * rows)
	s.lines = make([]int, rows)
	s.wrapped = make([]bool, rows)
	s.dirty = make([]bool, rows)
	for i in 0 ..< rows do s.lines[i] = i
	s.remapped = true
}

@(private)
screen_free :: proc(s: ^Screen) {
	delete(s.cells)
	delete(s.lines)
	delete(s.wrapped)
	delete(s.dirty)
}

@(private)
screen_clear :: proc(t: ^Term, s: ^Screen) {
	for &c in s.cells do c = {}
	for i in 0 ..< t.rows {
		s.wrapped[i] = false
		s.dirty[i] = true
	}
}

// physical row slice for logical row y; marks it dirty
row :: #force_inline proc(t: ^Term, y: int) -> []Cell {
	p := t.scr.lines[y]
	t.scr.dirty[p] = true
	t.output_seq += 1
	return t.scr.cells[p * t.cols:(p + 1) * t.cols]
}

// read-only access to a screen row
screen_row :: #force_inline proc(t: ^Term, s: ^Screen, y: int) -> []Cell {
	p := s.lines[y]
	return s.cells[p * t.cols:(p + 1) * t.cols]
}

blank :: #force_inline proc(t: ^Term) -> Cell {
	return {bg = t.cur.pen.bg}
}

rune_width :: proc(r: rune) -> int {
	if r < 0x300 {
		return 1 if r >= 0x20 && (r < 0x7f || r >= 0xa0) else 0
	}
	if unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r) do return 0
	return unicode.normalized_east_asian_width(r)
}

// --- history

@(private)
history_push :: proc(t: ^Term, cells: []Cell, wrapped: bool) {
	h := &t.hist
	cap := len(h.lines)
	slot: ^History_Line
	if h.count < cap {
		slot = &h.lines[(h.head + h.count) % cap]
		h.count += 1
	} else {
		slot = &h.lines[h.head]
		h.head = (h.head + 1) % cap
		graphics_drop_before(t, h.total - h.count + 1)
	}
	n := len(cells)
	for n > 0 && cells[n - 1] == {} do n -= 1
	resize(&slot.cells, n)
	copy(slot.cells[:], cells[:n])
	slot.wrapped = wrapped
	h.total += 1
	if t.view > 0 do t.view = min(t.view + 1, h.count)
}

// removes the newest history line
@(private)
history_pop :: proc(t: ^Term) -> ^History_Line {
	h := &t.hist
	if h.count == 0 do return nil
	h.count -= 1
	h.total -= 1
	t.view = min(t.view, h.count)
	return &h.lines[(h.head + h.count) % len(h.lines)]
}

first_line :: proc(t: ^Term) -> int {return t.hist.total - t.hist.count}

// cells of an absolute line; lines past history come from the active screen
get_line :: proc(t: ^Term, abs: int) -> (cells: []Cell, wrapped: bool, ok: bool) {
	h := &t.hist
	if abs < h.total - h.count do return
	if abs < h.total {
		l := &h.lines[(h.head + abs - (h.total - h.count)) % len(h.lines)]
		return l.cells[:], l.wrapped, true
	}
	y := abs - h.total
	if y >= t.rows do return
	p := t.scr.lines[y]
	return t.scr.cells[p * t.cols:(p + 1) * t.cols], t.scr.wrapped[p], true
}

last_line :: proc(t: ^Term) -> int {return t.hist.total + t.rows - 1}

scroll_view :: proc(t: ^Term, delta: int) {
	v := clamp(t.view + delta, 0, t.hist.count if t.scr == &t.primary else 0)
	if v != t.view {
		t.view = v
		t.all_dirty = true
	}
}

// --- scrolling

scroll_up :: proc(t: ^Term, top, bot, count: int) {
	s := t.scr
	n := min(count, bot - top + 1)
	if n <= 0 do return
	push := s == &t.primary && top == 0 && bot == t.rows - 1
	if !push do graphics_scroll(t, top, bot, -n)
	b := blank(t)
	for _ in 0 ..< n {
		p := s.lines[top]
		cells := s.cells[p * t.cols:(p + 1) * t.cols]
		if push do history_push(t, cells, s.wrapped[p])
		copy(s.lines[top:bot], s.lines[top + 1:bot + 1])
		s.lines[bot] = p
		for &c in cells do c = b
		s.wrapped[p] = false
		s.dirty[p] = true
	}
	s.remapped = true
	t.output_seq += 1
}

scroll_down :: proc(t: ^Term, top, bot, count: int) {
	s := t.scr
	n := min(count, bot - top + 1)
	if n <= 0 do return
	graphics_scroll(t, top, bot, n)
	b := blank(t)
	for _ in 0 ..< n {
		p := s.lines[bot]
		copy(s.lines[top + 1:bot + 1], s.lines[top:bot])
		s.lines[top] = p
		for &c in s.cells[p * t.cols:(p + 1) * t.cols] do c = b
		s.wrapped[p] = false
		s.dirty[p] = true
	}
	s.remapped = true
	t.output_seq += 1
}

// --- cursor and editing

linefeed :: proc(t: ^Term) {
	if t.cur.y == t.bot {
		scroll_up(t, t.top, t.bot, 1)
	} else if t.cur.y < t.rows - 1 {
		t.cur.y += 1
	}
	t.cur.wrap = false
}

reverse_index :: proc(t: ^Term) {
	if t.cur.y == t.top {
		scroll_down(t, t.top, t.bot, 1)
	} else if t.cur.y > 0 {
		t.cur.y -= 1
	}
	t.cur.wrap = false
}

move_to :: proc(t: ^Term, x, y: int) {
	lo, hi := 0, t.rows - 1
	if t.cur.origin do lo, hi = t.top, t.bot
	t.cur.x = clamp(x, 0, t.cols - 1)
	t.cur.y = clamp(y, lo, hi)
	t.cur.wrap = false
}

// clear the other half of a wide char that is being split at x
@(private)
fix_wide :: proc(t: ^Term, r: []Cell, x: int) {
	if x < 0 || x >= len(r) do return
	if .Spacer in r[x].attrs && x > 0 {
		r[x - 1] = blank(t)
	}
	if .Wide in r[x].attrs && x + 1 < len(r) {
		r[x + 1] = blank(t)
	}
}

print :: proc(t: ^Term, ch: rune) {
	ch := ch
	w := rune_width(ch)
	if w == 0 {
		attach_mark(t, ch)
		return
	}
	if t.cur.charset[t.cur.gl] == '0' && ch >= 0x5f && ch <= 0x7e {
		ch = DEC_GRAPHICS[ch - 0x5f]
	}
	if t.cur.wrap && .Wrap in t.modes {
		t.scr.wrapped[t.scr.lines[t.cur.y]] = true
		linefeed(t)
		t.cur.x = 0
	}
	if w == 2 && t.cur.x == t.cols - 1 {
		if t.cols < 2 do return
		if .Wrap in t.modes {
			r := row(t, t.cur.y)
			fix_wide(t, r, t.cur.x)
			r[t.cur.x] = blank(t)
			t.scr.wrapped[t.scr.lines[t.cur.y]] = true
			linefeed(t)
			t.cur.x = 0
		} else {
			t.cur.x -= 1
		}
	}
	r := row(t, t.cur.y)
	x := t.cur.x
	if .Insert in t.modes {
		fix_wide(t, r, x)
		copy(r[x + w:], r[x:])
		if .Wide in r[t.cols - 1].attrs do r[t.cols - 1] = blank(t)
	}
	fix_wide(t, r, x)
	if w == 2 do fix_wide(t, r, x + 1)
	c := t.cur.pen
	c.ch = ch
	c.mark = 0
	if w == 2 {
		c.attrs += {.Wide}
		r[x] = c
		c.attrs = c.attrs - {.Wide} + {.Spacer}
		c.ch = 0
		r[x + 1] = c
	} else {
		r[x] = c
	}
	t.last_ch = ch
	if x + w >= t.cols {
		t.cur.x = t.cols - 1
		t.cur.wrap = .Wrap in t.modes
	} else {
		t.cur.x = x + w
	}
}

@(private)
attach_mark :: proc(t: ^Term, ch: rune) {
	if ch > 0xffff || !(unicode.is_nonspacing_mark(ch) || unicode.is_enclosing_mark(ch)) do return
	x := t.cur.x if t.cur.wrap else t.cur.x - 1
	if x < 0 do return
	r := row(t, t.cur.y)
	if .Spacer in r[x].attrs && x > 0 do x -= 1
	if r[x].ch != 0 && r[x].mark == 0 do r[x].mark = u16(ch)
}

erase_cells :: proc(t: ^Term, y, from, to: int) {
	x0, x1 := max(from, 0), min(to, t.cols)
	if x0 >= x1 do return
	r := row(t, y)
	fix_wide(t, r, x0)
	fix_wide(t, r, x1 - 1)
	b := blank(t)
	for x in x0 ..< x1 do r[x] = b
}

erase_display :: proc(t: ^Term, mode: int) {
	switch mode {
	case 0:
		erase_cells(t, t.cur.y, t.cur.x, t.cols)
		for y in t.cur.y + 1 ..< t.rows do erase_cells(t, y, 0, t.cols)
	case 1:
		for y in 0 ..< t.cur.y do erase_cells(t, y, 0, t.cols)
		erase_cells(t, t.cur.y, 0, t.cur.x + 1)
	case 2:
		for y in 0 ..< t.rows {
			erase_cells(t, y, 0, t.cols)
			t.scr.wrapped[t.scr.lines[y]] = false
		}
		graphics_clear_screen(t)
	case 3:
		graphics_drop_before(t, t.hist.total)
		for &l in t.hist.lines do clear(&l.cells)
		t.hist.count = 0
		t.hist.head = 0
		t.view = 0
		t.all_dirty = true
	}
	t.cur.wrap = false
}

insert_lines :: proc(t: ^Term, n: int) {
	if t.cur.y < t.top || t.cur.y > t.bot do return
	scroll_down(t, t.cur.y, t.bot, n)
	t.cur.x = 0
	t.cur.wrap = false
}

delete_lines :: proc(t: ^Term, count: int) {
	if t.cur.y < t.top || t.cur.y > t.bot do return
	// a deleted line never enters history
	s := t.scr
	n := min(count, t.bot - t.cur.y + 1)
	graphics_scroll(t, t.cur.y, t.bot, -n)
	b := blank(t)
	for _ in 0 ..< n {
		p := s.lines[t.cur.y]
		copy(s.lines[t.cur.y:t.bot], s.lines[t.cur.y + 1:t.bot + 1])
		s.lines[t.bot] = p
		for &c in s.cells[p * t.cols:(p + 1) * t.cols] do c = b
		s.wrapped[p] = false
		s.dirty[p] = true
	}
	s.remapped = true
	t.output_seq += 1
	t.cur.x = 0
	t.cur.wrap = false
}

insert_chars :: proc(t: ^Term, count: int) {
	r := row(t, t.cur.y)
	x := t.cur.x
	n := min(count, t.cols - x)
	fix_wide(t, r, x)
	copy(r[x + n:], r[x:])
	b := blank(t)
	for i in x ..< x + n do r[i] = b
	if .Wide in r[t.cols - 1].attrs do r[t.cols - 1] = b
	t.cur.wrap = false
}

delete_chars :: proc(t: ^Term, count: int) {
	r := row(t, t.cur.y)
	x := t.cur.x
	n := min(count, t.cols - x)
	fix_wide(t, r, x)
	fix_wide(t, r, x + n - 1)
	copy(r[x:], r[x + n:])
	b := blank(t)
	for i in t.cols - n ..< t.cols do r[i] = b
	if .Spacer in r[x].attrs do r[x] = b
	t.cur.wrap = false
}

tab_forward :: proc(t: ^Term, n: int) {
	for _ in 0 ..< n {
		x := t.cur.x + 1
		for x < t.cols - 1 && !t.tabs[x] do x += 1
		t.cur.x = min(x, t.cols - 1)
	}
	t.cur.wrap = false
}

tab_back :: proc(t: ^Term, n: int) {
	for _ in 0 ..< n {
		x := t.cur.x - 1
		for x > 0 && !t.tabs[x] do x -= 1
		t.cur.x = max(x, 0)
	}
	t.cur.wrap = false
}

save_cursor :: proc(t: ^Term) {
	t.scr.saved = t.cur
}

restore_cursor :: proc(t: ^Term) {
	t.cur = t.scr.saved
	t.cur.x = clamp(t.cur.x, 0, t.cols - 1)
	t.cur.y = clamp(t.cur.y, 0, t.rows - 1)
}

set_alt_screen :: proc(t: ^Term, on: bool, save: bool, clear_alt: bool) {
	if on == (t.scr == &t.alt) do return
	if on {
		if save do save_cursor(t)
		t.scr = &t.alt
		if clear_alt do screen_clear(t, &t.alt)
		t.modes += {.Alt_Screen}
		t.view = 0
	} else {
		t.scr = &t.primary
		t.modes -= {.Alt_Screen}
		if save do restore_cursor(t)
	}
	t.all_dirty = true
	t.scr.remapped = true
}

set_cell_size :: proc(t: ^Term, w, h: int) {
	t.cell_w = max(w, 1)
	t.cell_h = max(h, 1)
}

// --- resize

resize_term :: proc(t: ^Term, new_cols, new_rows: int) {
	cols, rows := max(new_cols, 1), max(new_rows, 1)
	if cols == t.cols && rows == t.rows do return
	on_alt := t.scr == &t.alt

	// keep the cursor row on screen by pushing lines into history
	cy := t.primary.saved.y if on_alt else t.cur.y
	shift := max(cy - rows + 1, 0)
	pull := 0
	if rows > t.rows && !on_alt {
		// bring back history when the window grows
		pull = min(rows - t.rows, t.hist.count)
	}

	old_scr := t.scr
	t.scr = &t.primary
	for y in 0 ..< shift {
		p := t.primary.lines[y]
		history_push(t, t.primary.cells[p * t.cols:(p + 1) * t.cols], t.primary.wrapped[p])
	}
	t.scr = old_scr

	np: Screen
	screen_init(&np, cols, rows)
	for i in 0 ..< pull {
		l := history_pop(t)
		y := pull - 1 - i
		n := min(len(l.cells), cols)
		copy(np.cells[y * cols:y * cols + n], l.cells[:n])
		np.wrapped[y] = l.wrapped
		clear(&l.cells)
	}
	for y in shift ..< t.rows {
		dy := y - shift + pull
		if dy >= rows do break
		copy_row(np.cells[dy * cols:(dy + 1) * cols], screen_row(t, &t.primary, y))
		np.wrapped[dy] = t.primary.wrapped[t.primary.lines[y]]
	}
	np.saved = t.primary.saved
	screen_free(&t.primary)
	t.primary = np

	na: Screen
	screen_init(&na, cols, rows)
	ashift := max(t.cur.y - rows + 1, 0) if on_alt else 0
	for y in ashift ..< t.rows {
		dy := y - ashift
		if dy >= rows do break
		copy_row(na.cells[dy * cols:(dy + 1) * cols], screen_row(t, &t.alt, y))
	}
	na.saved = t.alt.saved
	screen_free(&t.alt)
	t.alt = na
	t.scr = &t.alt if on_alt else &t.primary
	graphics_resize(t, shift - pull - ashift)

	if on_alt {
		t.cur.y -= ashift
		t.primary.saved.y = clamp(t.primary.saved.y - shift + pull, 0, rows - 1)
	} else {
		t.cur.y = t.cur.y - shift + pull
		t.primary.saved.y = clamp(t.primary.saved.y - shift + pull, 0, rows - 1)
	}

	delete(t.tabs)
	t.tabs = make([]bool, cols)
	for i in 0 ..< cols do t.tabs[i] = i % 8 == 0
	t.cols = cols
	t.rows = rows
	t.top = 0
	t.bot = rows - 1
	t.cur.x = clamp(t.cur.x, 0, cols - 1)
	t.cur.y = clamp(t.cur.y, 0, rows - 1)
	t.cur.wrap = false
	t.alt.saved.x = clamp(t.alt.saved.x, 0, cols - 1)
	t.alt.saved.y = clamp(t.alt.saved.y, 0, rows - 1)
	t.primary.saved.x = clamp(t.primary.saved.x, 0, cols - 1)
	t.view = min(t.view, t.hist.count)
	t.all_dirty = true
	t.output_seq += 1
}

@(private)
copy_row :: proc(dst, src: []Cell) {
	n := copy(dst, src)
	// a wide char cut at the new margin loses its spacer
	if n > 0 && n < len(src) && .Wide in dst[n - 1].attrs do dst[n - 1] = {}
}

// the vt100 line drawing set for 0x5f..0x7e
DEC_GRAPHICS := [32]rune {
	' ', '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└', '┼',
	'⎺', '⎻', '─', '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·',
}
