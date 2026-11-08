package term

import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"

MAX_PARAMS :: 32
OSC_MAX :: 1 << 20
APC_MAX :: 64 << 20
DCS_MAX :: 4096

State :: enum u8 {
	Ground,
	Escape,
	Escape_Inter,
	Csi_Entry,
	Csi_Param,
	Csi_Inter,
	Csi_Ignore,
	Osc,
	Dcs,
	Apc,
	Ignore_String, // sos and pm
	String_Esc, // esc seen inside a string, waiting for '\'
}

String_Kind :: enum u8 {
	None,
	Osc,
	Dcs,
	Apc,
	Ignore,
}

Parser :: struct {
	state:    State,
	kind:     String_Kind,
	params:   [MAX_PARAMS]int,
	sub:      [MAX_PARAMS]bool, // params[i] is a ':' subparameter of the one before it
	n:        int,
	private:  u8,
	inter:    u8,
	inter2:   u8,
	str:      [dynamic]u8,
	overflow: bool,
	utf_cp:   rune,
	utf_need: int,
	utf_min:  rune,
}

parser_free :: proc(p: ^Parser) {
	delete(p.str)
}

// feeds raw pty output; sequences may be split anywhere
feed :: proc(t: ^Term, data: []u8) {
	p := &t.parser
	for i := 0; i < len(data); i += 1 {
		b := data[i]
		switch p.state {
		case .Ground:
			if b >= 0x20 && b < 0x7f && p.utf_need == 0 {
				print(t, rune(b))
			} else if b >= 0x80 {
				utf8_byte(t, b)
			} else {
				if p.utf_need > 0 {
					p.utf_need = 0
					print(t, 0xfffd)
				}
				if b == 0x7f do continue
				execute(t, b)
			}
		case .Escape:
			if b < 0x20 {
				execute(t, b)
				continue
			}
			switch b {
			case '[':
				clear_params(p)
				p.state = .Csi_Entry
			case ']':
				start_string(p, .Osc)
			case 'P':
				clear_params(p)
				start_string(p, .Dcs)
			case '_':
				start_string(p, .Apc)
			case 'X', '^':
				start_string(p, .Ignore)
			case 0x20 ..= 0x2f:
				p.inter = b
				p.state = .Escape_Inter
			case:
				p.state = .Ground
				esc_dispatch(t, 0, b)
			}
		case .Escape_Inter:
			if b < 0x20 {
				execute(t, b)
			} else if b < 0x30 {
				p.inter2 = b
			} else {
				p.state = .Ground
				esc_dispatch(t, p.inter, b)
			}
		case .Csi_Entry, .Csi_Param:
			switch b {
			case '0' ..= '9':
				if p.n == 0 do p.n = 1
				v := &p.params[p.n - 1]
				v^ = min(v^ * 10 + int(b - '0'), 0xffff)
				p.state = .Csi_Param
			case ';', ':':
				if p.n == 0 do p.n = 1
				if p.n < MAX_PARAMS {
					p.sub[p.n] = b == ':'
					p.params[p.n] = 0
					p.n += 1
				}
				p.state = .Csi_Param
			case '<' ..= '?':
				if p.state == .Csi_Entry {
					p.private = b
					p.state = .Csi_Param
				} else {
					p.state = .Csi_Ignore
				}
			case 0x20 ..= 0x2f:
				p.inter = b
				p.state = .Csi_Inter
			case 0x40 ..= 0x7e:
				p.state = .Ground
				csi_dispatch(t, b)
			case 0x1b:
				p.state = .Escape
				p.inter = 0
			case 0x18, 0x1a:
				p.state = .Ground
			case 0x00 ..= 0x17, 0x19, 0x1c ..= 0x1f:
				execute(t, b)
			case:
				p.state = .Csi_Ignore
			}
		case .Csi_Inter:
			switch b {
			case 0x20 ..= 0x2f:
				p.inter2 = b
			case 0x40 ..= 0x7e:
				p.state = .Ground
				csi_dispatch(t, b)
			case 0x1b:
				p.state = .Escape
				p.inter = 0
			case 0x00 ..= 0x1a, 0x1c ..= 0x1f:
				execute(t, b)
			case:
				p.state = .Csi_Ignore
			}
		case .Csi_Ignore:
			switch b {
			case 0x40 ..= 0x7e:
				p.state = .Ground
			case 0x1b:
				p.state = .Escape
				p.inter = 0
			case 0x00 ..= 0x1a, 0x1c ..= 0x1f:
				execute(t, b)
			}
		case .Osc, .Dcs, .Apc, .Ignore_String:
			// bulk copy up to the next terminator
			j := i
			for j < len(data) && data[j] != 0x1b && data[j] != 0x07 && !(data[j] == 0x18 || data[j] == 0x1a) do j += 1
			if p.state != .Ignore_String do string_put(p, data[i:j])
			i = j
			if j == len(data) do break
			switch data[j] {
			case 0x1b:
				p.state = .String_Esc
			case 0x07:
				if p.kind == .Osc {
					finish_string(t)
				} else if p.kind != .Apc {
					p.state = .Ground
				}
			case:
				p.state = .Ground
			}
		case .String_Esc:
			if b == '\\' {
				finish_string(t)
			} else {
				// esc aborts the string and begins a new sequence
				p.state = .Escape
				p.inter = 0
				i -= 1
			}
		}
	}
}

@(private)
utf8_byte :: proc(t: ^Term, b: u8) {
	p := &t.parser
	if b & 0xc0 == 0x80 {
		if p.utf_need == 0 {
			print(t, 0xfffd)
			return
		}
		p.utf_cp = p.utf_cp << 6 | rune(b & 0x3f)
		p.utf_need -= 1
		if p.utf_need == 0 {
			cp := p.utf_cp
			if cp < p.utf_min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) do cp = 0xfffd
			print(t, cp)
		}
		return
	}
	if p.utf_need > 0 do print(t, 0xfffd)
	switch {
	case b & 0xe0 == 0xc0:
		p.utf_cp, p.utf_need, p.utf_min = rune(b & 0x1f), 1, 0x80
	case b & 0xf0 == 0xe0:
		p.utf_cp, p.utf_need, p.utf_min = rune(b & 0x0f), 2, 0x800
	case b & 0xf8 == 0xf0:
		p.utf_cp, p.utf_need, p.utf_min = rune(b & 0x07), 3, 0x10000
	case:
		p.utf_need = 0
		print(t, 0xfffd)
	}
}

@(private)
clear_params :: proc(p: ^Parser) {
	p.n = 0
	p.params[0] = 0
	p.sub[0] = false
	p.private = 0
	p.inter = 0
	p.inter2 = 0
}

@(private)
start_string :: proc(p: ^Parser, kind: String_Kind) {
	p.kind = kind
	p.overflow = false
	clear(&p.str)
	switch kind {
	case .Osc:
		p.state = .Osc
	case .Dcs:
		p.state = .Dcs
	case .Apc:
		p.state = .Apc
	case .Ignore, .None:
		p.state = .Ignore_String
	}
}

@(private)
string_put :: proc(p: ^Parser, b: []u8) {
	limit := OSC_MAX
	#partial switch p.kind {
	case .Apc:
		limit = APC_MAX
	case .Dcs:
		limit = DCS_MAX
	}
	if len(p.str) + len(b) > limit {
		p.overflow = true
		return
	}
	append(&p.str, ..b)
}

@(private)
finish_string :: proc(t: ^Term) {
	p := &t.parser
	p.state = .Ground
	kind := p.kind
	p.kind = .None
	if p.overflow {
		clear(&p.str)
		return
	}
	#partial switch kind {
	case .Osc:
		osc_dispatch(t, string(p.str[:]))
	case .Dcs:
		dcs_dispatch(t, string(p.str[:]))
	}
	// drop large buffers so a single image does not pin memory
	if cap(p.str) > 1 << 20 {
		delete(p.str)
		p.str = {}
	} else {
		clear(&p.str)
	}
}

@(private)
execute :: proc(t: ^Term, b: u8) {
	switch b {
	case 0x07:
		t.bell = true
	case 0x08:
		if t.cur.wrap {
			t.cur.wrap = false
		} else if t.cur.x > 0 {
			t.cur.x -= 1
		}
	case 0x09:
		tab_forward(t, 1)
	case 0x0a, 0x0b, 0x0c:
		linefeed(t)
		if .Newline in t.modes do t.cur.x = 0
	case 0x0d:
		t.cur.x = 0
		t.cur.wrap = false
	case 0x0e:
		t.cur.gl = 1
	case 0x0f:
		t.cur.gl = 0
	case 0x1b:
		t.parser.state = .Escape
		t.parser.inter = 0
		t.parser.inter2 = 0
	case 0x18, 0x1a:
		t.parser.state = .Ground
	}
}

@(private)
esc_dispatch :: proc(t: ^Term, inter, final: u8) {
	switch inter {
	case 0:
		switch final {
		case '7':
			save_cursor(t)
		case '8':
			restore_cursor(t)
		case 'D':
			linefeed(t)
		case 'E':
			linefeed(t)
			t.cur.x = 0
		case 'H':
			t.tabs[t.cur.x] = true
		case 'M':
			reverse_index(t)
		case 'c':
			full_reset(t)
		case '=':
			t.modes += {.App_Keypad}
		case '>':
			t.modes -= {.App_Keypad}
		case 'n':
			t.cur.gl = 1
		case 'o':
			t.cur.gl = 0
		}
	case '(', ')':
		t.cur.charset[0 if inter == '(' else 1] = final
	case '#':
		if final == '8' {
			// decaln fills the screen with E
			for y in 0 ..< t.rows {
				r := row(t, y)
				for &c in r do c = {ch = 'E'}
			}
			move_to(t, 0, 0)
		}
	}
}

full_reset :: proc(t: ^Term) {
	t.fg = DEFAULT_FG
	t.bg = DEFAULT_BG
	t.cursor_color = DEFAULT_FG
	default_palette(&t.palette)
	t.view = 0
	reset(t)
}

@(private)
param :: #force_inline proc(t: ^Term, i: int, def := 1) -> int {
	p := &t.parser
	if i >= p.n || p.params[i] == 0 do return def
	return p.params[i]
}

@(private)
reply :: proc(t: ^Term, format: string, args: ..any) {
	buf: [256]u8
	s := fmt.bprintf(buf[:], format, ..args)
	append(&t.out, s)
}

@(private)
csi_dispatch :: proc(t: ^Term, final: u8) {
	p := &t.parser
	if p.private == '?' {
		private_csi(t, final)
		return
	}
	if p.private == '>' {
		switch final {
		case 'c':
			reply(t, "\x1b[>1;10;0c")
		case 'q':
			reply(t, "\x1bP>|votty 0.1\x1b\\")
		}
		return
	}
	if p.private != 0 do return
	if p.inter != 0 {
		switch {
		case p.inter == ' ' && final == 'q':
			switch param(t, 0, 0) {
			case 0, 1, 2:
				t.shape = .Block
			case 3, 4:
				t.shape = .Underline
			case 5, 6:
				t.shape = .Bar
			}
			ps := param(t, 0, 0)
			if ps == 0 || ps % 2 == 1 {t.modes += {.Cursor_Blink}} else {t.modes -= {.Cursor_Blink}}
		case p.inter == '!' && final == 'p':
			soft_reset(t)
		case p.inter == '$' && final == 'p':
			mode_report(t, param(t, 0, 0), false)
		}
		return
	}
	c := &t.cur
	switch final {
	case '@':
		insert_chars(t, param(t, 0))
	case 'A':
		move_to(t, c.x, max(c.y - param(t, 0), t.top if c.y >= t.top else 0))
	case 'B', 'e':
		move_to(t, c.x, min(c.y + param(t, 0), t.bot if c.y <= t.bot else t.rows - 1))
	case 'C', 'a':
		move_to(t, c.x + param(t, 0), c.y)
	case 'D':
		move_to(t, c.x - param(t, 0), c.y)
	case 'E':
		move_to(t, 0, min(c.y + param(t, 0), t.bot if c.y <= t.bot else t.rows - 1))
	case 'F':
		move_to(t, 0, max(c.y - param(t, 0), t.top if c.y >= t.top else 0))
	case 'G', '`':
		move_to(t, param(t, 0) - 1, c.y)
	case 'H', 'f':
		y := param(t, 0) - 1
		if c.origin do y += t.top
		move_to(t, param(t, 1) - 1, y)
	case 'I':
		tab_forward(t, param(t, 0))
	case 'J':
		erase_display(t, param(t, 0, 0))
	case 'K':
		switch param(t, 0, 0) {
		case 0:
			erase_cells(t, c.y, c.x, t.cols)
		case 1:
			erase_cells(t, c.y, 0, c.x + 1)
		case 2:
			erase_cells(t, c.y, 0, t.cols)
		}
		c.wrap = false
	case 'L':
		insert_lines(t, param(t, 0))
	case 'M':
		delete_lines(t, param(t, 0))
	case 'P':
		delete_chars(t, param(t, 0))
	case 'S':
		scroll_up(t, t.top, t.bot, param(t, 0))
	case 'T':
		scroll_down(t, t.top, t.bot, param(t, 0))
	case 'X':
		erase_cells(t, c.y, c.x, c.x + param(t, 0))
		c.wrap = false
	case 'Z':
		tab_back(t, param(t, 0))
	case 'b':
		if t.last_ch != 0 {
			for _ in 0 ..< min(param(t, 0), t.cols * t.rows) do print(t, t.last_ch)
		}
	case 'c':
		if param(t, 0, 0) == 0 do reply(t, "\x1b[?62;22c")
	case 'd':
		y := param(t, 0) - 1
		if c.origin do y += t.top
		move_to(t, c.x, y)
	case 'g':
		switch param(t, 0, 0) {
		case 0:
			t.tabs[c.x] = false
		case 3:
			for &tab in t.tabs do tab = false
		}
	case 'h', 'l':
		on := final == 'h'
		for i in 0 ..< max(p.n, 1) {
			switch p.params[i] {
			case 4:
				set_mode(t, .Insert, on)
			case 20:
				set_mode(t, .Newline, on)
			}
		}
	case 'm':
		sgr(t)
	case 'n':
		switch param(t, 0, 0) {
		case 5:
			reply(t, "\x1b[0n")
		case 6:
			y := c.y - t.top if c.origin else c.y
			reply(t, "\x1b[%d;%dR", y + 1, c.x + 1)
		}
	case 'r':
		top := param(t, 0) - 1
		bot := param(t, 1, t.rows) - 1
		bot = min(bot, t.rows - 1)
		if top < bot {
			t.top = top
			t.bot = bot
			move_to(t, 0, t.top if c.origin else 0)
		}
	case 's':
		save_cursor(t)
	case 'u':
		restore_cursor(t)
	case 't':
		switch param(t, 0, 0) {
		case 14:
			reply(t, "\x1b[4;%d;%dt", t.rows * t.cell_h, t.cols * t.cell_w)
		case 16:
			reply(t, "\x1b[6;%d;%dt", t.cell_h, t.cell_w)
		case 18:
			reply(t, "\x1b[8;%d;%dt", t.rows, t.cols)
		}
	}
}

@(private)
soft_reset :: proc(t: ^Term) {
	t.modes = (t.modes & {.Alt_Screen}) + {.Wrap, .Cursor_Visible}
	t.cur.pen = {}
	t.cur.origin = false
	t.cur.charset = {'B', 'B'}
	t.cur.gl = 0
	t.cur.wrap = false
	t.top = 0
	t.bot = t.rows - 1
	t.scr.saved = t.cur
}

@(private)
set_mode :: proc(t: ^Term, m: Mode, on: bool) {
	if on {t.modes += {m}} else {t.modes -= {m}}
}

@(private)
private_mode :: proc(n: int) -> (m: Mode, ok: bool) {
	switch n {
	case 1:
		return .App_Cursor, true
	case 5:
		return .Reverse_Video, true
	case 6:
		return .Origin, true
	case 7:
		return .Wrap, true
	case 9:
		return .Mouse_X10, true
	case 12:
		return .Cursor_Blink, true
	case 25:
		return .Cursor_Visible, true
	case 1000:
		return .Mouse_Press, true
	case 1002:
		return .Mouse_Drag, true
	case 1003:
		return .Mouse_Motion, true
	case 1004:
		return .Focus_Events, true
	case 1006:
		return .Mouse_Sgr, true
	case 1007:
		return .Alt_Scroll, true
	case 47, 1047, 1049:
		return .Alt_Screen, true
	case 2004:
		return .Bracketed_Paste, true
	case 2026:
		return .Sync_Output, true
	}
	return
}

@(private)
mode_report :: proc(t: ^Term, n: int, private: bool) {
	state := 0
	if private {
		if n == 1048 {
			state = 2
		} else if m, ok := private_mode(n); ok {
			state = 1 if m in t.modes else 2
			if m == .Origin do state = 1 if t.cur.origin else 2
		}
		reply(t, "\x1b[?%d;%d$y", n, state)
	} else {
		switch n {
		case 4:
			state = 1 if .Insert in t.modes else 2
		case 20:
			state = 1 if .Newline in t.modes else 2
		}
		reply(t, "\x1b[%d;%d$y", n, state)
	}
}

@(private)
private_csi :: proc(t: ^Term, final: u8) {
	p := &t.parser
	if p.inter == '$' && final == 'p' {
		mode_report(t, param(t, 0, 0), true)
		return
	}
	if p.inter != 0 do return
	switch final {
	case 'h', 'l':
		on := final == 'h'
		for i in 0 ..< max(p.n, 1) {
			n := p.params[i]
			switch n {
			case 6:
				t.cur.origin = on
				move_to(t, 0, t.top if on else 0)
			case 47, 1047:
				set_alt_screen(t, on, false, n == 1047 && on)
			case 1049:
				set_alt_screen(t, on, true, true)
			case 1048:
				if on {save_cursor(t)} else {restore_cursor(t)}
			case 9, 1000, 1002, 1003:
				t.modes -= MOUSE_MODES
				if m, ok := private_mode(n); ok && on do t.modes += {m}
			case 5:
				set_mode(t, .Reverse_Video, on)
				t.all_dirty = true
			case:
				if m, ok := private_mode(n); ok do set_mode(t, m, on)
			}
		}
	case 'n':
		if param(t, 0, 0) == 6 {
			y := t.cur.y - t.top if t.cur.origin else t.cur.y
			reply(t, "\x1b[?%d;%dR", y + 1, t.cur.x + 1)
		}
	case 'J':
		erase_display(t, param(t, 0, 0))
	case 'K':
		switch param(t, 0, 0) {
		case 0:
			erase_cells(t, t.cur.y, t.cur.x, t.cols)
		case 1:
			erase_cells(t, t.cur.y, 0, t.cur.x + 1)
		case 2:
			erase_cells(t, t.cur.y, 0, t.cols)
		}
	}
}

@(private)
sgr :: proc(t: ^Term) {
	p := &t.parser
	pen := &t.cur.pen
	if p.n == 0 {
		pen^ = {}
		return
	}
	for i := 0; i < p.n; i += 1 {
		v := p.params[i]
		switch v {
		case 0:
			pen.attrs = {}
			pen.fg = COLOR_DEFAULT
			pen.bg = COLOR_DEFAULT
		case 1:
			pen.attrs += {.Bold}
		case 2:
			pen.attrs += {.Faint}
		case 3:
			pen.attrs += {.Italic}
		case 4:
			pen.attrs -= {.Underline, .Double_Underline, .Curly_Underline}
			style := 1
			if i + 1 < p.n && p.sub[i + 1] {
				i += 1
				style = p.params[i]
			}
			switch style {
			case 0:
			case 2:
				pen.attrs += {.Double_Underline}
			case 3:
				pen.attrs += {.Curly_Underline}
			case:
				pen.attrs += {.Underline}
			}
		case 5, 6:
			pen.attrs += {.Blink}
		case 7:
			pen.attrs += {.Inverse}
		case 8:
			pen.attrs += {.Invisible}
		case 9:
			pen.attrs += {.Strike}
		case 21:
			pen.attrs += {.Double_Underline}
		case 22:
			pen.attrs -= {.Bold, .Faint}
		case 23:
			pen.attrs -= {.Italic}
		case 24:
			pen.attrs -= {.Underline, .Double_Underline, .Curly_Underline}
		case 25:
			pen.attrs -= {.Blink}
		case 27:
			pen.attrs -= {.Inverse}
		case 28:
			pen.attrs -= {.Invisible}
		case 29:
			pen.attrs -= {.Strike}
		case 30 ..= 37:
			pen.fg = color_index(v - 30)
		case 39:
			pen.fg = COLOR_DEFAULT
		case 40 ..= 47:
			pen.bg = color_index(v - 40)
		case 49:
			pen.bg = COLOR_DEFAULT
		case 53:
			pen.attrs += {.Overline}
		case 55:
			pen.attrs -= {.Overline}
		case 90 ..= 97:
			pen.fg = color_index(v - 90 + 8)
		case 100 ..= 107:
			pen.bg = color_index(v - 100 + 8)
		case 38, 48, 58:
			col, next := extended_color(p, i)
			i = next
			if v == 38 {
				pen.fg = col
			} else if v == 48 {
				pen.bg = col
			}
		}
		// skip stray subparameters
		for i + 1 < p.n && p.sub[i + 1] do i += 1
	}
}

// parses 5;n / 2;r;g;b and their colon forms, returns the last consumed index
@(private)
extended_color :: proc(p: ^Parser, i: int) -> (Color, int) {
	if i + 1 >= p.n do return COLOR_DEFAULT, i
	colon := p.sub[i + 1]
	kind := p.params[i + 1]
	switch kind {
	case 5:
		if i + 2 >= p.n do return COLOR_DEFAULT, p.n - 1
		return color_index(p.params[i + 2]), i + 2
	case 2:
		j := i + 2
		// the colon form may carry a colorspace id before r:g:b
		if colon {
			k := j
			for k < p.n && p.sub[k] do k += 1
			if k - j >= 4 do j += 1
		}
		if j + 2 >= p.n do return COLOR_DEFAULT, p.n - 1
		return color_rgb(p.params[j], p.params[j + 1], p.params[j + 2]), j + 2
	}
	return COLOR_DEFAULT, i + 1
}

@(private)
osc_dispatch :: proc(t: ^Term, s: string) {
	semi := strings.index_byte(s, ';')
	code_str := s if semi < 0 else s[:semi]
	rest := "" if semi < 0 else s[semi + 1:]
	code, ok := strconv.parse_int(code_str, 10)
	if !ok do return
	switch code {
	case 0, 2:
		clear(&t.title)
		append(&t.title, rest[:min(len(rest), 1024)])
		t.title_dirty = true
	case 4:
		for len(rest) > 0 {
			idx_s := next_field(&rest)
			spec := next_field(&rest)
			idx, iok := strconv.parse_int(idx_s, 10)
			if !iok || idx < 0 || idx > 255 do break
			if spec == "?" {
				reply_color(t, "4;%d", idx, t.palette[idx])
			} else if c, cok := parse_color(spec); cok {
				t.palette[idx] = c
				t.all_dirty = true
			}
		}
	case 7:
		set_cwd(t, rest)
	case 10, 11, 12:
		target := [3]^u32{&t.fg, &t.bg, &t.cursor_color}
		if rest == "?" {
			reply_color(t, "%d", code, target[code - 10]^)
		} else if c, cok := parse_color(rest); cok {
			target[code - 10]^ = c
			t.all_dirty = true
		}
	case 52:
		data := rest[strings.index_byte(rest, ';') + 1:]
		if data == "?" do return
		dec, err := base64.decode(data, allocator = context.temp_allocator)
		if err != nil do return
		clear(&t.clipboard)
		append(&t.clipboard, ..dec)
		t.clip_dirty = true
	case 104:
		if rest == "" {
			default_palette(&t.palette)
		} else {
			def: [256]u32
			default_palette(&def)
			for f in strings.split_iterator(&rest, ";") {
				if n, nok := strconv.parse_int(f, 10); nok && n >= 0 && n < 256 do t.palette[n] = def[n]
			}
		}
		t.all_dirty = true
	case 110:
		t.fg = DEFAULT_FG
		t.all_dirty = true
	case 111:
		t.bg = DEFAULT_BG
		t.all_dirty = true
	case 112:
		t.cursor_color = DEFAULT_FG
	}
}

@(private)
next_field :: proc(s: ^string) -> string {
	i := strings.index_byte(s^, ';')
	if i < 0 {
		f := s^
		s^ = ""
		return f
	}
	f := s[:i]
	s^ = s[i + 1:]
	return f
}

@(private)
reply_color :: proc(t: ^Term, prefix: string, arg: int, c: u32) {
	r, g, b := (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
	buf: [32]u8
	head := fmt.bprintf(buf[:], prefix, arg)
	reply(t, "\x1b]%s;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\", head, r, r, g, g, b, b)
}

parse_color :: proc(s: string) -> (u32, bool) {
	if len(s) == 7 && s[0] == '#' {
		v, ok := strconv.parse_u64_of_base(s[1:], 16)
		return u32(v), ok
	}
	if !strings.has_prefix(s, "rgb:") do return 0, false
	rest := s[4:]
	out: u32
	for _ in 0 ..< 3 {
		i := strings.index_byte(rest, '/')
		part := rest if i < 0 else rest[:i]
		rest = "" if i < 0 else rest[i + 1:]
		if len(part) < 1 || len(part) > 4 do return 0, false
		v, ok := strconv.parse_u64_of_base(part, 16)
		if !ok do return 0, false
		// scale 1-4 hex digits to 8 bits
		maxv := u64(1) << (4 * uint(len(part))) - 1
		out = out << 8 | u32(v * 255 / maxv)
	}
	return out, true
}

@(private)
set_cwd :: proc(t: ^Term, uri: string) {
	path := uri
	if strings.has_prefix(path, "file://") {
		path = path[7:]
		slash := strings.index_byte(path, '/')
		if slash < 0 do return
		path = path[slash:]
	}
	clear(&t.cwd)
	for i := 0; i < len(path); i += 1 {
		if path[i] == '%' && i + 2 < len(path) {
			if v, ok := strconv.parse_u64_of_base(path[i + 1:i + 3], 16); ok {
				append(&t.cwd, u8(v))
				i += 2
				continue
			}
		}
		append(&t.cwd, path[i])
	}
}

@(private)
dcs_dispatch :: proc(t: ^Term, s: string) {
	switch {
	case strings.has_prefix(s, "$q"):
		q := s[2:]
		switch q {
		case "m":
			reply(t, "\x1bP1$r0m\x1b\\")
		case "r":
			reply(t, "\x1bP1$r%d;%dr\x1b\\", t.top + 1, t.bot + 1)
		case " q":
			n := [Cursor_Shape]int {
				.Block     = 2,
				.Underline = 4,
				.Bar       = 6,
			}
			reply(t, "\x1bP1$r%d q\x1b\\", n[t.shape] - (1 if .Cursor_Blink in t.modes else 0))
		case:
			reply(t, "\x1bP0$r\x1b\\")
		}
	case strings.has_prefix(s, "+q"):
		reply(t, "\x1bP0+r\x1b\\")
	}
}
