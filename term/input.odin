package term

import "core:fmt"
import "core:unicode/utf8"

Key :: enum u8 {
	None,
	Enter,
	Tab,
	Backspace,
	Escape,
	Up,
	Down,
	Right,
	Left,
	Home,
	End,
	Insert,
	Delete,
	Page_Up,
	Page_Down,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	KP_0, KP_1, KP_2, KP_3, KP_4, KP_5, KP_6, KP_7, KP_8, KP_9,
	KP_Decimal,
	KP_Divide,
	KP_Multiply,
	KP_Subtract,
	KP_Add,
	KP_Enter,
	KP_Equal,
}

Mod :: enum u8 {
	Shift,
	Alt,
	Ctrl,
	Super,
}
Mods :: bit_set[Mod;u8]

// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl + 8*super
@(private)
mod_param :: proc(m: Mods) -> int {
	return 1 + int(.Shift in m) + 2 * int(.Alt in m) + 4 * int(.Ctrl in m) + 8 * int(.Super in m)
}

// appends the bytes for a special key to out; returns false if the key has no encoding
encode_key :: proc(t: ^Term, key: Key, mods: Mods, out: ^[dynamic]u8) -> bool {
	m := mod_param(mods)
	app_cursor := .App_Cursor in t.modes
	app_keypad := .App_Keypad in t.modes
	alt := "\x1b" if .Alt in mods else ""
	buf: [32]u8
	s: string
	csi_letter :: proc(buf: []u8, m: int, ss3: bool, c: u8) -> string {
		if m > 1 do return fmt.bprintf(buf, "\x1b[1;%d%c", m, c)
		return fmt.bprintf(buf, "\x1bO%c" if ss3 else "\x1b[%c", c)
	}
	csi_tilde :: proc(buf: []u8, m: int, n: int) -> string {
		if m > 1 do return fmt.bprintf(buf, "\x1b[%d;%d~", n, m)
		return fmt.bprintf(buf, "\x1b[%d~", n)
	}
	#partial switch key {
	case .Enter:
		s = fmt.bprintf(buf[:], "%s%s", alt, "\r\n" if .Newline in t.modes else "\r")
	case .Tab:
		if .Shift in mods {
			s = "\x1b[Z"
		} else {
			s = fmt.bprintf(buf[:], "%s\t", alt)
		}
	case .Backspace:
		s = fmt.bprintf(buf[:], "%s%c", alt, 0x08 if .Ctrl in mods else 0x7f)
	case .Escape:
		s = fmt.bprintf(buf[:], "%s\x1b", alt)
	case .Up:
		s = csi_letter(buf[:], m, app_cursor, 'A')
	case .Down:
		s = csi_letter(buf[:], m, app_cursor, 'B')
	case .Right:
		s = csi_letter(buf[:], m, app_cursor, 'C')
	case .Left:
		s = csi_letter(buf[:], m, app_cursor, 'D')
	case .Home:
		s = csi_letter(buf[:], m, app_cursor, 'H')
	case .End:
		s = csi_letter(buf[:], m, app_cursor, 'F')
	case .Insert:
		s = csi_tilde(buf[:], m, 2)
	case .Delete:
		s = csi_tilde(buf[:], m, 3)
	case .Page_Up:
		s = csi_tilde(buf[:], m, 5)
	case .Page_Down:
		s = csi_tilde(buf[:], m, 6)
	case .F1 ..= .F4:
		s = csi_letter(buf[:], m, true, 'P' + u8(key - .F1))
	case .F5 ..= .F12:
		codes := [8]int{15, 17, 18, 19, 20, 21, 23, 24}
		s = csi_tilde(buf[:], m, codes[key - .F5])
	case .KP_0 ..= .KP_Equal:
		if !app_keypad {
			chars := "0123456789./*-+\r="
			s = fmt.bprintf(buf[:], "%s%c", alt, chars[key - .KP_0])
		} else {
			finals := "pqrstuvwxynojmkMX"
			c := finals[key - .KP_0]
			s = fmt.bprintf(buf[:], "\x1bO%c", c) if m == 1 else fmt.bprintf(buf[:], "\x1bO%d%c", m, c)
		}
	case:
		return false
	}
	append(out, s)
	return true
}

// encodes a character typed with modifiers, applying ctrl and alt
encode_char :: proc(ch: rune, mods: Mods, out: ^[dynamic]u8) {
	ch := ch
	if .Ctrl in mods {
		switch ch {
		case 'a' ..= 'z':
			ch = ch - 'a' + 1
		case 'A' ..= 'Z':
			ch = ch - 'A' + 1
		case ' ', '@', '2':
			ch = 0
		case '[', '3':
			ch = 0x1b
		case '\\', '4':
			ch = 0x1c
		case ']', '5':
			ch = 0x1d
		case '^', '6', '~':
			ch = 0x1e
		case '_', '7', '/', '-':
			ch = 0x1f
		case '?', '8':
			ch = 0x7f
		}
	}
	if .Alt in mods do append(out, 0x1b)
	b, n := utf8.encode_rune(ch)
	append(out, ..b[:n])
}

Mouse_Event :: enum u8 {
	Press,
	Release,
	Motion,
}

// button: 0 left, 1 middle, 2 right, 3 none (motion), 4/5 wheel up/down
// returns false when the current mode does not report this event
encode_mouse :: proc(t: ^Term, ev: Mouse_Event, button: int, col, row: int, mods: Mods, out: ^[dynamic]u8) -> bool {
	mm := t.modes & MOUSE_MODES
	if mm == {} do return false
	switch ev {
	case .Release:
		if .Mouse_X10 in mm do return false
	case .Motion:
		if .Mouse_Motion not_in mm && !(.Mouse_Drag in mm && button != 3) do return false
	case .Press:
	}
	cb := button
	if button >= 4 do cb = 64 + (button - 4)
	if ev == .Motion do cb += 32
	if .Mouse_X10 not_in mm {
		if .Shift in mods do cb += 4
		if .Alt in mods do cb += 8
		if .Ctrl in mods do cb += 16
	}
	buf: [64]u8
	if .Mouse_Sgr in t.modes {
		final: u8 = 'm' if ev == .Release else 'M'
		append(out, fmt.bprintf(buf[:], "\x1b[<%d;%d;%d%c", cb, col + 1, row + 1, final))
		return true
	}
	if ev == .Release do cb = cb & ~int(3) | 3
	if col > 222 || row > 222 do return true
	append(out, fmt.bprintf(buf[:], "\x1b[M%c%c%c", u8(32 + cb), u8(33 + col), u8(33 + row)))
	return true
}

// wraps pasted text, dropping escapes that could end the bracket early
encode_paste :: proc(t: ^Term, text: string, out: ^[dynamic]u8) {
	bracket := .Bracketed_Paste in t.modes
	if bracket do append(out, "\x1b[200~")
	for i := 0; i < len(text); i += 1 {
		b := text[i]
		switch b {
		case '\n':
			if i > 0 && text[i - 1] == '\r' do continue
			append(out, '\r')
		case 0x1b:
			if !bracket do append(out, b)
		case:
			append(out, b)
		}
	}
	if bracket do append(out, "\x1b[201~")
}
