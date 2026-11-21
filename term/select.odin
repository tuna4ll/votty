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
		if .Spacer in c.attrs && x > 0 do return base_rune(cells[x - 1].ch)
		return base_rune(c.ch)
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
			buf: [4]u8
			strings.write_string(&sb, cell_text(c.ch, &buf))
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

URL_SCHEMES :: [?]string{"https://", "http://", "file://", "ftp://", "mailto:", "ssh://", "git://"}

// the link under p: an osc 8 hyperlink, or a url written in the text; a and b span it
url_at :: proc(t: ^Term, p: Pos, allocator := context.allocator) -> (url: string, a, b: Pos, ok: bool) {
	cells, _, lok := get_line(t, p.line)
	if !lok || p.col >= len(cells) do return
	if id := cells[p.col].link; id != 0 {
		// extend over neighbouring cells of the same link, across soft wraps
		a, b = p, p
		for {
			c, _, cok := get_line(t, a.line)
			if !cok do break
			if a.col > 0 && c[a.col - 1].link == id {
				a.col -= 1
				continue
			}
			if a.col > 0 do break
			prev, pw, pok := get_line(t, a.line - 1)
			if !pok || !pw || len(prev) == 0 || prev[len(prev) - 1].link != id do break
			a = {a.line - 1, len(prev) - 1}
		}
		for {
			c, w, cok := get_line(t, b.line)
			if !cok do break
			if b.col + 1 < len(c) && c[b.col + 1].link == id {
				b.col += 1
				continue
			}
			if !w || b.col + 1 < len(c) do break
			next, _, nok := get_line(t, b.line + 1)
			if !nok || len(next) == 0 || next[0].link != id do break
			b = {b.line + 1, 0}
		}
		return strings.clone(link_uri(id), allocator), a, b, true
	}
	// plain text: walk the soft wrapped line as one run of cells
	la, lb := line_bounds(t, p)
	Spot :: struct {
		pos: Pos,
		ch:  rune,
	}
	run := make([dynamic]Spot, context.temp_allocator)
	at := -1
	for l in la.line ..= lb.line {
		c, _, _ := get_line(t, l)
		for cell, x in c {
			if .Spacer in cell.attrs do continue
			if l == p.line && x == p.col do at = len(run)
			append(&run, Spot{{l, x}, base_rune(cell.ch)})
		}
	}
	if at < 0 do return
	stop :: proc(r: rune) -> bool {
		return r == 0 || r == ' ' || r == '\t' || r == '"' || r == '\'' || r == '<' || r == '>' || r == '`' || r == '|'
	}
	if stop(run[at].ch) do return
	lo, hi := at, at
	for lo > 0 && !stop(run[lo - 1].ch) do lo -= 1
	for hi + 1 < len(run) && !stop(run[hi + 1].ch) do hi += 1
	sb := strings.builder_make(context.temp_allocator)
	for s in run[lo:hi + 1] do strings.write_rune(&sb, s.ch)
	word := strings.to_string(sb)
	// the url starts at the last scheme before the cursor
	start := -1
	for scheme in URL_SCHEMES {
		i := strings.index(word, scheme)
		if i >= 0 && (start < 0 || i < start) do start = i
	}
	if start < 0 do return
	text := word[start:]
	// trailing punctuation is usually prose, except a closing paren that has a partner
	for len(text) > 0 {
		last := text[len(text) - 1]
		if strings.index_byte(".,;:!?]}'", last) >= 0 || (last == ')' && strings.count(text, "(") < strings.count(text, ")")) {
			text = text[:len(text) - 1]
			continue
		}
		break
	}
	for scheme in URL_SCHEMES do if text == scheme do return
	first := lo + strings.rune_count(word[:start])
	last := first + strings.rune_count(text) - 1
	if at < first || at > last do return
	return strings.clone(text, allocator), run[first].pos, run[last].pos, true
}
