package term

import "core:unicode"

// inclusive span; a match may continue across soft wrapped rows
Match :: struct {
	line, col:         int,
	end_line, end_col: int,
}

Search :: struct {
	query:          [dynamic]rune,
	case_sensitive: bool,
	current:        Match,
	found:          bool,
	// incremental scan state
	active:         bool,
	dir:            int, // -1 towards older output
	line:           int,
	col:            int, // matches must start before (dir -1) or after (dir 1) this
	remaining:      int,
	wrapped:        bool,
	scratch:        [dynamic]Match,
}

search_free :: proc(s: ^Search) {
	delete(s.query)
	delete(s.scratch)
}

@(private)
fold :: #force_inline proc(ch: rune, sensitive: bool) -> rune {
	r := base_rune(ch) if is_cluster(ch) else ch
	if r == 0 do return ' '
	if sensitive || r < 'A' do return r
	if r <= 'Z' do return r + 32
	if r < 0x80 do return r
	return unicode.to_lower(r)
}

// end of a match of q starting at line, x
@(private)
match_at :: proc(t: ^Term, cells: []Cell, wrapped: bool, line, x: int, q: []rune, sensitive: bool) -> (end: Pos, ok: bool) {
	cells, wrapped, l := cells, wrapped, line
	i, cx := 0, x
	for i < len(q) {
		if cx >= len(cells) {
			if !wrapped do return
			l += 1
			cells, wrapped = get_line(t, l) or_return
			cx = 0
			continue
		}
		c := cells[cx]
		if .Spacer in c.attrs {
			cx += 1
			continue
		}
		if fold(c.ch, sensitive) != q[i] do return
		end = {l, cx}
		i += 1
		cx += 1
	}
	// cover the trailing spacer of a wide char
	if cx < len(cells) && .Spacer in cells[cx].attrs do end.col = cx
	return end, true
}

// appends every match starting on an absolute line, overlapping ones included
line_matches :: proc(t: ^Term, s: ^Search, line: int, out: ^[dynamic]Match) {
	if len(s.query) == 0 do return
	cells, wrapped, ok := get_line(t, line)
	if !ok do return
	first := s.query[0]
	for x in 0 ..< len(cells) {
		c := cells[x]
		if .Spacer in c.attrs || fold(c.ch, s.case_sensitive) != first do continue
		if end, mok := match_at(t, cells, wrapped, line, x, s.query[:], s.case_sensitive); mok {
			append(out, Match{line, x, end.line, end.col})
		}
	}
}

// sets a new query and starts looking from the given line towards older output
search_start :: proc(t: ^Term, s: ^Search, query: string, from_line: int) {
	clear(&s.query)
	for r in query do append(&s.query, fold(r, s.case_sensitive))
	s.found = false
	s.dir = -1
	s.line = clamp(from_line, first_line(t), last_line(t))
	s.col = max(int)
	s.remaining = last_line(t) - first_line(t) + 1
	s.wrapped = false
	s.active = len(s.query) > 0
}

// continues from the current match in a direction: -1 older, 1 newer
search_next :: proc(t: ^Term, s: ^Search, dir: int) {
	if len(s.query) == 0 do return
	s.dir = dir
	if s.found {
		s.line = s.current.line
		s.col = s.current.col
	} else {
		s.line = last_line(t) if dir < 0 else first_line(t)
		s.col = max(int) if dir < 0 else -1
	}
	s.line = clamp(s.line, first_line(t), last_line(t))
	s.remaining = last_line(t) - first_line(t) + 2
	s.wrapped = false
	s.active = true
}

// scans up to budget lines; returns true when the scan has finished
search_step :: proc(t: ^Term, s: ^Search, budget: int) -> bool {
	if !s.active do return true
	lo, hi := first_line(t), last_line(t)
	for _ in 0 ..< budget {
		if s.remaining <= 0 {
			s.active = false
			s.found = false
			return true
		}
		if s.line < lo || s.line > hi {
			// wrap around once
			s.line = hi if s.dir < 0 else lo
			s.col = max(int) if s.dir < 0 else -1
			s.wrapped = true
		}
		clear(&s.scratch)
		line_matches(t, s, s.line, &s.scratch)
		ms := s.scratch[:]
		best := -1
		for m, i in ms {
			if s.dir < 0 && m.col < s.col do best = i
			if s.dir > 0 && m.col > s.col && best < 0 do best = i
		}
		if best >= 0 {
			s.current = ms[best]
			s.found = true
			s.active = false
			return true
		}
		s.line += s.dir
		s.col = max(int) if s.dir < 0 else -1
		s.remaining -= 1
	}
	return false
}

// drops a stale match once its line has left history
search_validate :: proc(t: ^Term, s: ^Search) {
	if s.found && s.current.line < first_line(t) do s.found = false
	if s.active && s.line < first_line(t) do s.line = first_line(t)
}
