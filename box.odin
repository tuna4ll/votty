package main

// arms per box char as up, right, down, left: 0 none, 1 light, 2 heavy, 3 double
BOX_ARMS := [?]string {
	"0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020",
	"0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200",
	"1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
	"1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",
	"0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
	"1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212",
	"1222", "2122", "2221", "2222", "0101", "0202", "1010", "2020", "0303", "3030", "0310", "0130",
	"0330", "0013", "0031", "0033", "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
	"3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303", "3101", "3303", "1313", "3131",
	"3333", "0110", "0011", "1001", "1100", "", "", "", "0001", "1000", "0100", "0010",
	"0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010",
}

// quadrant masks for U+2596..U+259F: 1 upper left, 2 upper right, 4 lower left, 8 lower right
QUADRANTS := [10]u8{4, 8, 1, 13, 9, 7, 11, 2, 6, 14}

is_box_char :: proc(ch: rune) -> bool {
	return (ch >= 0x2500 && ch <= 0x259f && !(ch >= 0x2571 && ch <= 0x2573))
}

@(private = "file")
fill :: proc(f: ^Fonts, x0, y0, x1, y1: int, v: u8 = 255) {
	sw := f.cell_w * 2
	for y in max(y0, 0) ..< min(y1, f.cell_h) {
		for x in max(x0, 0) ..< min(x1, f.cell_w) do f.scratch[y * sw + x] = v
	}
}

// draws box drawing and block elements procedurally so lines join across cells
draw_box_char :: proc(f: ^Fonts, ch: rune) {
	w, h := f.cell_w, f.cell_h
	if ch >= 0x2580 {
		switch ch {
		case 0x2580:
			fill(f, 0, 0, w, h / 2)
		case 0x2581 ..= 0x2588:
			fill(f, 0, h - h * int(ch - 0x2580) / 8, w, h)
		case 0x2589 ..= 0x258f:
			fill(f, 0, 0, w * int(0x2590 - ch) / 8, h)
		case 0x2590:
			fill(f, w / 2, 0, w, h)
		case 0x2591 ..= 0x2593:
			fill(f, 0, 0, w, h, u8(64 * int(ch - 0x2590)))
		case 0x2594:
			fill(f, 0, 0, w, max(h / 8, 1))
		case 0x2595:
			fill(f, w - max(w / 8, 1), 0, w, h)
		case:
			q := QUADRANTS[ch - 0x2596]
			if q & 1 != 0 do fill(f, 0, 0, w / 2, h / 2)
			if q & 2 != 0 do fill(f, w / 2, 0, w, h / 2)
			if q & 4 != 0 do fill(f, 0, h / 2, w / 2, h)
			if q & 8 != 0 do fill(f, w / 2, h / 2, w, h)
		}
		return
	}
	arms := BOX_ARMS[ch - 0x2500]
	if len(arms) != 4 do return
	t := max(f.thickness, 1)
	cx, cy := w / 2, h / 2
	for a, i in arms {
		weight := int(a - '0')
		if weight == 0 do continue
		th := t * 2 if weight == 2 else t
		lo := -th / 2
		// double lines are two light strokes around the center
		offs := []int{lo} if weight != 3 else []int{lo - t, lo + t}
		for o in offs {
			switch i {
			case 0:
				fill(f, cx + o, 0, cx + o + th, cy + t)
			case 1:
				fill(f, cx - t, cy + o, w, cy + o + th)
			case 2:
				fill(f, cx + o, cy - t, cx + o + th, h)
			case 3:
				fill(f, 0, cy + o, cx + t, cy + o + th)
			}
		}
	}
}
