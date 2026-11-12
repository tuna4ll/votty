package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "term"
import "vendor:glfw"

Action :: enum u8 {
	None,
	Copy,
	Paste,
	Search,
	Font_Up,
	Font_Down,
	Font_Reset,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Scroll_Top,
	Scroll_Bottom,
	New_Tab,
	Close_Tab,
	Next_Tab,
	Prev_Tab,
	Tab_1, Tab_2, Tab_3, Tab_4, Tab_5, Tab_6, Tab_7, Tab_8, Tab_9,
	Split_Right,
	Split_Down,
	Close_Pane,
	Focus_Left,
	Focus_Right,
	Focus_Up,
	Focus_Down,
	Resize_Left,
	Resize_Right,
	Resize_Up,
	Resize_Down,
	New_Workspace,
	Close_Workspace,
	Next_Workspace,
	Prev_Workspace,
}

Binding :: struct {
	key:    i32,
	mods:   term.Mods,
	action: Action,
}

Config :: struct {
	font:          string,
	font_size:     f32,
	shell:         string,
	scrollback:    int,
	width, height: int, // cells
	fg, bg:        u32,
	cursor_color:  u32,
	cursor_shape:  term.Cursor_Shape,
	cursor_blink:  bool,
	palette:       [16]u32,
	palette_set:   [16]bool,
	opacity:       f32,
	bold_bright:   bool,
	platform:      string,
	persistent:    bool,
	stats:         bool,
	bindings:      [dynamic]Binding,
}

DEFAULT_BINDINGS := [?]struct {
	keys:   string,
	action: Action,
} {
	{"ctrl+shift+c", .Copy},
	{"ctrl+shift+v", .Paste},
	{"ctrl+shift+f", .Search},
	{"ctrl+shift+equal", .Font_Up},
	{"ctrl+shift+minus", .Font_Down},
	{"ctrl+shift+0", .Font_Reset},
	{"shift+page_up", .Scroll_Page_Up},
	{"shift+page_down", .Scroll_Page_Down},
	{"shift+home", .Scroll_Top},
	{"shift+end", .Scroll_Bottom},
	{"ctrl+shift+t", .New_Tab},
	{"ctrl+shift+q", .Close_Tab},
	{"ctrl+shift+right", .Next_Tab},
	{"ctrl+shift+left", .Prev_Tab},
	{"ctrl+shift+1", .Tab_1},
	{"ctrl+shift+2", .Tab_2},
	{"ctrl+shift+3", .Tab_3},
	{"ctrl+shift+4", .Tab_4},
	{"ctrl+shift+5", .Tab_5},
	{"ctrl+shift+6", .Tab_6},
	{"ctrl+shift+7", .Tab_7},
	{"ctrl+shift+8", .Tab_8},
	{"ctrl+shift+9", .Tab_9},
	{"ctrl+shift+e", .Split_Right},
	{"ctrl+shift+o", .Split_Down},
	{"ctrl+shift+w", .Close_Pane},
	{"ctrl+shift+h", .Focus_Left},
	{"ctrl+shift+l", .Focus_Right},
	{"ctrl+shift+k", .Focus_Up},
	{"ctrl+shift+j", .Focus_Down},
	{"ctrl+shift+alt+h", .Resize_Left},
	{"ctrl+shift+alt+l", .Resize_Right},
	{"ctrl+shift+alt+k", .Resize_Up},
	{"ctrl+shift+alt+j", .Resize_Down},
	{"ctrl+shift+n", .New_Workspace},
	{"ctrl+shift+x", .Close_Workspace},
	{"ctrl+shift+page_down", .Next_Workspace},
	{"ctrl+shift+page_up", .Prev_Workspace},
}

KEY_NAMES := [?]struct {
	name: string,
	key:  i32,
} {
	{"space", glfw.KEY_SPACE},
	{"enter", glfw.KEY_ENTER},
	{"tab", glfw.KEY_TAB},
	{"escape", glfw.KEY_ESCAPE},
	{"backspace", glfw.KEY_BACKSPACE},
	{"insert", glfw.KEY_INSERT},
	{"delete", glfw.KEY_DELETE},
	{"left", glfw.KEY_LEFT},
	{"right", glfw.KEY_RIGHT},
	{"up", glfw.KEY_UP},
	{"down", glfw.KEY_DOWN},
	{"page_up", glfw.KEY_PAGE_UP},
	{"page_down", glfw.KEY_PAGE_DOWN},
	{"home", glfw.KEY_HOME},
	{"end", glfw.KEY_END},
	{"equal", glfw.KEY_EQUAL},
	{"plus", glfw.KEY_EQUAL},
	{"minus", glfw.KEY_MINUS},
	{"comma", glfw.KEY_COMMA},
	{"period", glfw.KEY_PERIOD},
	{"slash", glfw.KEY_SLASH},
	{"semicolon", glfw.KEY_SEMICOLON},
	{"apostrophe", glfw.KEY_APOSTROPHE},
	{"grave", glfw.KEY_GRAVE_ACCENT},
	{"bracket_left", glfw.KEY_LEFT_BRACKET},
	{"bracket_right", glfw.KEY_RIGHT_BRACKET},
	{"backslash", glfw.KEY_BACKSLASH},
}

parse_keys :: proc(s: string) -> (b: Binding, ok: bool) {
	rest := s
	for part in strings.split_iterator(&rest, "+") {
		p := strings.trim_space(part)
		switch p {
		case "ctrl", "control":
			b.mods += {.Ctrl}
		case "shift":
			b.mods += {.Shift}
		case "alt":
			b.mods += {.Alt}
		case "super":
			b.mods += {.Super}
		case:
			if b.key != 0 do return b, false
			switch {
			case len(p) == 1 && p[0] >= 'a' && p[0] <= 'z':
				b.key = glfw.KEY_A + i32(p[0] - 'a')
			case len(p) == 1 && p[0] >= '0' && p[0] <= '9':
				b.key = glfw.KEY_0 + i32(p[0] - '0')
			case len(p) >= 2 && p[0] == 'f':
				n, nok := strconv.parse_int(p[1:])
				if !nok || n < 1 || n > 12 do return b, false
				b.key = glfw.KEY_F1 + i32(n - 1)
			case:
				for k in KEY_NAMES do if k.name == p do b.key = k.key
				if b.key == 0 do return b, false
			}
		}
	}
	return b, b.key != 0
}

config_defaults :: proc(c: ^Config) {
	c.font = strings.clone("monospace")
	c.font_size = 11
	c.scrollback = 10000
	c.width = 100
	c.height = 30
	c.fg = term.DEFAULT_FG
	c.bg = term.DEFAULT_BG
	c.cursor_color = term.DEFAULT_FG
	c.cursor_blink = true
	c.opacity = 1
	c.bold_bright = true
	c.platform = strings.clone("auto")
	c.persistent = true
	for d in DEFAULT_BINDINGS {
		b, _ := parse_keys(d.keys)
		b.action = d.action
		append(&c.bindings, b)
	}
}

config_destroy :: proc(c: ^Config) {
	delete(c.font)
	delete(c.shell)
	delete(c.platform)
	delete(c.bindings)
}

config_path :: proc(allocator := context.temp_allocator) -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return strings.concatenate({x, "/votty/config"}, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.config/votty/config"}, allocator)
}

@(private = "file")
parse_bool :: proc(v: string) -> (bool, bool) {
	switch v {
	case "true", "yes", "on", "1":
		return true, true
	case "false", "no", "off", "0":
		return false, true
	}
	return false, false
}

// a missing file is fine; bad lines are reported and skipped
config_load :: proc(c: ^Config, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	text := string(data)
	n := 0
	for raw in strings.split_lines_iterator(&text) {
		n += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			fmt.eprintfln("votty: %s:%d: expected key = value", path, n)
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		if !config_set(c, key, val) do fmt.eprintfln("votty: %s:%d: invalid setting %q", path, n, line)
	}
}

config_set :: proc(c: ^Config, key, val: string) -> bool {
	color :: proc(v: string) -> (u32, bool) {
		return term.parse_color(v)
	}
	switch {
	case key == "font":
		if val == "" do return false
		delete(c.font)
		c.font = strings.clone(val)
	case key == "font_size":
		v, ok := strconv.parse_f32(val)
		if !ok || v < 4 || v > 200 do return false
		c.font_size = v
	case key == "shell":
		delete(c.shell)
		c.shell = strings.clone(val)
	case key == "scrollback":
		v, ok := strconv.parse_int(val)
		if !ok || v < 0 || v > 1_000_000 do return false
		c.scrollback = v
	case key == "columns":
		v, ok := strconv.parse_int(val)
		if !ok || v < 10 || v > 1000 do return false
		c.width = v
	case key == "rows":
		v, ok := strconv.parse_int(val)
		if !ok || v < 3 || v > 500 do return false
		c.height = v
	case key == "foreground":
		c.fg = color(val) or_return
	case key == "background":
		c.bg = color(val) or_return
	case key == "cursor_color":
		c.cursor_color = color(val) or_return
	case key == "cursor_shape":
		switch val {
		case "block":
			c.cursor_shape = .Block
		case "underline":
			c.cursor_shape = .Underline
		case "bar", "beam":
			c.cursor_shape = .Bar
		case:
			return false
		}
	case key == "cursor_blink":
		c.cursor_blink = parse_bool(val) or_return
	case key == "opacity":
		v, ok := strconv.parse_f32(val)
		if !ok || v < 0 || v > 1 do return false
		c.opacity = v
	case key == "bold_is_bright":
		c.bold_bright = parse_bool(val) or_return
	case key == "stats":
		c.stats = parse_bool(val) or_return
	case key == "persistent_buffers":
		c.persistent = parse_bool(val) or_return
	case key == "platform":
		if val != "auto" && val != "x11" && val != "wayland" do return false
		delete(c.platform)
		c.platform = strings.clone(val)
	case strings.has_prefix(key, "color"):
		i, ok := strconv.parse_int(key[5:])
		if !ok || i < 0 || i > 15 do return false
		c.palette[i] = color(val) or_return
		c.palette_set[i] = true
	case strings.has_prefix(key, "bind "):
		b := parse_keys(strings.trim_space(key[5:])) or_return
		action := Action.None
		if val != "none" {
			found := false
			for a in Action {
				name, _ := fmt.enum_value_to_string(a)
				if strings.equal_fold(name, val) {
					action = a
					found = true
				}
			}
			if !found do return false
		}
		// a later binding for the same keys replaces the earlier one
		for i := len(c.bindings) - 1; i >= 0; i -= 1 {
			if c.bindings[i].key == b.key && c.bindings[i].mods == b.mods do ordered_remove(&c.bindings, i)
		}
		b.action = action
		if action != .None do append(&c.bindings, b)
	case:
		return false
	}
	return true
}

lookup_binding :: proc(c: ^Config, key: i32, mods: term.Mods) -> Action {
	for b in c.bindings do if b.key == key && b.mods == mods do return b.action
	return .None
}
