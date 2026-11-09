package term

import "core:strings"
import "core:unicode"

Pos :: struct {
	line: int, // absolute line
	col:  int,
}

pos_less :: proc(a, b: Pos) -> bool {
	return a.line < b.line || (a.line == b.line && a.col < b.col)
}

ordered :: proc(a, b: Pos) -> (Pos, Pos) {
	if pos_less(b, a) do return b, a
	return a, b
}

@(private)
is_word :: proc(ch: rune, extra: string) -> bool {
	if ch == 0 || ch == ' ' do return false
	return unicode.is_letter(ch) || unicode.is_digit(ch) || strings.contains_rune(extra, ch)
}

WORD_CHARS :: "-_./~:@%+#?&=,"

// expands a position to the surrounding word
word_bounds :: proc(t: ^Term, p: Pos, extra := WORD_CHARS) -> (Pos, Pos) {
	cells, _, ok := get_line(t, p.line)
	if !ok || p.col >= len(cells) do return p, p
	at :: proc(cells: []Cell, x: int) -> rune {
		c := cells[x]
		if .Spacer in c.attrs && x > 0 do return cells[x - 1].ch
		return c.ch
	}
	if !is_word(at(cells, p.col), extra) do return p, p
	a, b := p.col, p.col
	for a > 0 && is_word(at(cells, a - 1), extra) do a -= 1
	for b + 1 < len(cells) && is_word(at(cells, b + 1), extra) do b += 1
	return {p.line, a}, {p.line, b}
}

// the logical line containing p, following soft wraps both ways
line_bounds :: proc(t: ^Term, p: Pos) -> (Pos, Pos) {
	a := p.line
	for a > first_line(t) {
		_, wrapped, ok := get_line(t, a - 1)
		if !ok || !wrapped do break
		a -= 1
	}
	b := p.line
	for b < last_line(t) {
		_, wrapped, ok := get_line(t, b)
		if !ok || !wrapped do break
		b += 1
	}
	return {a, 0}, {b, max(t.cols - 1, 0)}
}

// text between two inclusive positions; soft wrapped lines are joined
selection_text :: proc(t: ^Term, from, to: Pos, allocator := context.allocator) -> string {
	a, b := ordered(from, to)
	sb := strings.builder_make(allocator)
	for l in max(a.line, first_line(t)) ..= min(b.line, last_line(t)) {
		cells, wrapped, ok := get_line(t, l)
		if !ok do continue
		x0 := a.col if l == a.line else 0
		x1 := min(b.col + 1 if l == b.line else len(cells), len(cells))
		start := len(sb.buf)
		for x in x0 ..< x1 {
			c := cells[x]
			if .Spacer in c.attrs do continue
			strings.write_rune(&sb, c.ch if c.ch != 0 else ' ')
			if c.mark != 0 do strings.write_rune(&sb, rune(c.mark))
		}
		joined := wrapped && l != b.line
		if !joined {
			// drop trailing blanks of hard lines
			n := len(sb.buf)
			for n > start && sb.buf[n - 1] == ' ' do n -= 1
			resize(&sb.buf, n)
			if l != b.line do strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}
