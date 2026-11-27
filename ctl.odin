package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "term"
import "vendor:glfw"

// requests are one line of fields split by FIELD_SEP, with \ and newlines escaped
FIELD_SEP :: '\x1f'
CTL_MAX_REQUEST :: 4 << 20

Ctl_Request :: struct {
	conn: posix.FD,
	args: []string,
}

Ctl_Waiter :: struct {
	conn:     posix.FD,
	node:     int,
	finished: int, // the node's finish count when the wait began
	deadline: time.Tick,
}

Ctl :: struct {
	path:    string,
	listen:  posix.FD,
	wake:    [2]posix.FD,
	reader:  ^thread.Thread,
	lock:    sync.Mutex,
	queue:   [dynamic]Ctl_Request,
	waiters: [dynamic]Ctl_Waiter,
}

escape_field :: proc(s: string, sb: ^strings.Builder) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case FIELD_SEP:
			strings.write_string(sb, "\\u")
		case:
			strings.write_byte(sb, s[i])
		}
	}
}

unescape_field :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':
				strings.write_byte(&sb, '\n')
			case 'u':
				strings.write_byte(&sb, FIELD_SEP)
			case:
				strings.write_byte(&sb, s[i])
			}
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

@(private = "file")
unix_addr :: proc(path: string) -> (addr: posix.sockaddr_un, ok: bool) {
	if len(path) >= len(addr.sun_path) do return
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	return addr, true
}

ctl_start :: proc(app: ^App) -> bool {
	c := &app.ctl
	dir := integration_dir()
	// sockets of instances that died without cleaning up
	if fis, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for fi in fis {
			if !strings.has_prefix(fi.name, "ctl-") || !strings.has_suffix(fi.name, ".sock") do continue
			pid, ok := strconv.parse_int(fi.name[4:len(fi.name) - 5], 10)
			if ok && posix.kill(posix.pid_t(pid), {}) != .OK && posix.errno() == .ESRCH do os.remove(fi.fullpath)
		}
	}
	c.path = fmt.aprintf("%s/ctl-%d.sock", dir, posix.getpid())
	addr, ok := unix_addr(c.path)
	if !ok do return false
	c.listen = posix.socket(.UNIX, .STREAM)
	if c.listen < 0 do return false
	posix.fcntl(c.listen, .SETFD, posix.FD_CLOEXEC)
	posix.unlink(strings.clone_to_cstring(c.path, context.temp_allocator))
	if posix.bind(c.listen, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(c.listen, 16) != .OK {
		posix.close(c.listen)
		return false
	}
	posix.chmod(strings.clone_to_cstring(c.path, context.temp_allocator), {.IRUSR, .IWUSR})
	if posix.pipe(&c.wake) != .OK do return false
	for fd in c.wake do posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	c.reader = thread.create_and_start_with_data(c, ctl_accept_loop)
	return true
}

ctl_stop :: proc(app: ^App) {
	c := &app.ctl
	if c.reader == nil do return
	one := [1]u8{1}
	posix.write(c.wake[1], raw_data(one[:]), 1)
	thread.join(c.reader)
	thread.destroy(c.reader)
	posix.close(c.listen)
	posix.close(c.wake[0])
	posix.close(c.wake[1])
	posix.unlink(strings.clone_to_cstring(c.path, context.temp_allocator))
	for r in c.queue {
		posix.close(r.conn)
		free_request(r)
	}
	for w in c.waiters do posix.close(w.conn)
	delete(c.queue)
	delete(c.waiters)
	delete(c.path)
}

// accepts connections and reads one request from each; the main loop answers
@(private = "file")
ctl_accept_loop :: proc(data: rawptr) {
	c := (^Ctl)(data)
	// requests cross threads, so they live on the plain heap on both sides
	context.allocator = runtime.heap_allocator()
	fds := [2]posix.pollfd{{fd = c.listen, events = {.IN}}, {fd = c.wake[0], events = {.IN}}}
	buf: [4096]u8
	for {
		if posix.poll(raw_data(fds[:]), 2, -1) < 0 do continue
		if .IN in fds[1].revents do return
		if .IN not_in fds[0].revents do continue
		conn := posix.accept(c.listen, nil, nil)
		if conn < 0 do continue
		posix.fcntl(conn, .SETFD, posix.FD_CLOEXEC)
		line := make([dynamic]u8)
		complete := false
		pfd := [1]posix.pollfd{{fd = conn, events = {.IN}}}
		for len(line) < CTL_MAX_REQUEST {
			// a client that stalls is dropped
			if posix.poll(raw_data(pfd[:]), 1, 2000) <= 0 do break
			n := posix.read(conn, &buf[0], len(buf))
			if n <= 0 do break
			append(&line, ..buf[:n])
			if i := strings.index_byte(string(line[:]), '\n'); i >= 0 {
				resize(&line, i)
				complete = true
				break
			}
		}
		if !complete {
			posix.close(conn)
			delete(line)
			continue
		}
		parts := strings.split(string(line[:]), "\x1f", context.temp_allocator)
		args := make([]string, len(parts))
		for p, i in parts do args[i] = unescape_field(p)
		delete(line)
		free_all(context.temp_allocator)
		sync.lock(&c.lock)
		append(&c.queue, Ctl_Request{conn, args})
		sync.unlock(&c.lock)
		glfw.PostEmptyEvent()
	}
}

@(private = "file")
reply :: proc(conn: posix.FD, ok: bool, body: string) {
	s := fmt.tprintf("%s\n%s", "ok" if ok else "error", body)
	data := transmute([]u8)s
	for len(data) > 0 {
		n := posix.write(conn, raw_data(data), uint(len(data)))
		if n <= 0 do break
		data = data[n:]
	}
	posix.close(conn)
}

@(private = "file")
free_request :: proc(r: Ctl_Request) {
	heap := runtime.heap_allocator()
	for a in r.args do delete(a, heap)
	delete(r.args, heap)
}

// answers queued requests and expired or satisfied waits; runs on the main thread
ctl_process :: proc(app: ^App) {
	c := &app.ctl
	if c.reader == nil do return
	sync.lock(&c.lock)
	reqs := c.queue
	c.queue = {}
	sync.unlock(&c.lock)
	for r in reqs {
		ok, body, wait := ctl_handle(app, r.args)
		if wait.node != 0 {
			wait.conn = r.conn
			append(&c.waiters, wait)
		} else {
			reply(r.conn, ok, body)
		}
		free_request(r)
	}
	delete(reqs)
	ctl_resolve(app)
}

// answers waits whose node finished, closed or ran out of time
ctl_resolve :: proc(app: ^App) {
	c := &app.ctl
	#reverse for w, i in c.waiters {
		ws := space_of(app, w.node)
		switch {
		case ws == nil:
			reply(w.conn, false, "node closed")
		case ws.finished > w.finished:
			reply(w.conn, ws.exit_code == 0, fmt.tprintf("exit %d", ws.exit_code))
		case w.deadline != {} && time.tick_diff(w.deadline, time.tick_now()) > 0:
			reply(w.conn, false, "timeout")
		case:
			continue
		}
		unordered_remove(&c.waiters, i)
	}
}

// the soonest wait deadline, so the main loop wakes for it
ctl_next_deadline :: proc(app: ^App) -> (f64, bool) {
	best := f64(-1)
	for w in app.ctl.waiters {
		if w.deadline == {} do continue
		d := time.duration_seconds(time.tick_diff(time.tick_now(), w.deadline))
		if best < 0 || d < best do best = max(d, 0)
	}
	return best, best >= 0
}

@(private = "file")
flag :: proc(args: ^[dynamic]string, name: string) -> bool {
	for a, i in args {
		if a == "--" do return false
		if a == name {
			ordered_remove(args, i)
			return true
		}
	}
	return false
}

@(private = "file")
option :: proc(args: ^[dynamic]string, name: string) -> (string, bool) {
	for a, i in args {
		if a == "--" do break
		if a == name && i + 1 < len(args) {
			v := args[i + 1]
			ordered_remove(args, i + 1)
			ordered_remove(args, i)
			return v, true
		}
	}
	return "", false
}

@(private = "file")
node_arg :: proc(app: ^App, s: string) -> ^Workspace {
	id, ok := strconv.parse_int(s, 10)
	if !ok do return nil
	return space_of(app, id)
}

status_word :: proc(ws: ^Workspace) -> string {
	st, _ := space_status(ws)
	switch st {
	case .Waiting:
		return "waiting"
	case .Running:
		return "running"
	case .Done:
		return "done"
	case .Failed:
		return "failed"
	case .Idle:
	}
	return "idle"
}

node_line :: proc(ws: ^Workspace) -> string {
	cwd := ""
	if t := ws.tabs[ws.cur]; t != nil && t.focus != nil do cwd = term.pty_cwd(t.focus.pane.pty, context.temp_allocator)
	exit := fmt.tprintf("%d", ws.exit_code) if ws.has_exit else "-"
	return fmt.tprintf("%d\t%s\t%s\t%s\t%s\t%s", ws.id, string(ws.name[:]), status_word(ws), exit, cwd, string(ws.note[:]))
}

CTL_HELP :: `commands:
  list                                   id, name, status, exit, cwd, note per node
  new [--name N] [--cwd D] [--bg] [-- CMD...]
  close ID | rename ID NAME | focus ID | overview
  send ID TEXT [--enter] [--wait]        type into a node; TEXT - reads stdin;
                                         --wait returns when that command finishes
  paste ID TEXT                          bracketed paste into a node
  read ID [--last] [--lines N]           screen text, or the last command output
  status ID
  wait ID [--timeout SECONDS]            until the node's next command finishes
  link FROM TO pipe|after [CMD] | unlink FROM [TO]
  notify ID TEXT                         flag a node as needing attention
ID may be "self" inside votty.`

// one request; a wait returns a waiter instead of a reply
ctl_handle :: proc(app: ^App, raw: []string) -> (ok: bool, body: string, wait: Ctl_Waiter) {
	if len(raw) == 0 do return false, CTL_HELP, {}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, ..raw[1:])
	app.dirty = true
	switch raw[0] {
	case "help":
		return true, CTL_HELP, {}
	case "list":
		sb := strings.builder_make(context.temp_allocator)
		for ws in app.spaces do fmt.sbprintf(&sb, "%s\n", node_line(ws))
		return true, strings.to_string(sb), {}
	case "overview":
		overview_toggle(app)
		return true, "", {}
	case "new":
		name, _ := option(&args, "--name")
		cwd, _ := option(&args, "--cwd")
		bg := flag(&args, "--bg")
		cmd: []string
		for a, i in args do if a == "--" {
			cmd = args[i + 1:]
			break
		}
		ws := new_workspace(app, cwd, cmd, name, !bg)
		if ws == nil do return false, "cannot start the node", {}
		if app.ov.open do app.ov.sel = ws
		return true, fmt.tprintf("%d", ws.id), {}
	case "link":
		if len(args) < 3 do return false, "usage: link FROM TO pipe|after [CMD]", {}
		a, b := node_arg(app, args[0]), node_arg(app, args[1])
		if a == nil || b == nil do return false, "no such node", {}
		kind: Edge_Kind
		switch args[2] {
		case "pipe":
			kind = .Pipe
		case "after":
			kind = .After
			if len(args) < 4 do return false, "an after link needs a command", {}
		case:
			return false, "kind must be pipe or after", {}
		}
		cmd := strings.join(args[3:], " ", context.temp_allocator) if len(args) > 3 else ""
		if !add_edge(app, a.id, b.id, kind, cmd) do return false, "cannot link a node to itself", {}
		return true, "", {}
	case "unlink":
		if len(args) < 1 do return false, "usage: unlink FROM [TO]", {}
		a := node_arg(app, args[0])
		if a == nil do return false, "no such node", {}
		if len(args) > 1 {
			b := node_arg(app, args[1])
			if b == nil do return false, "no such node", {}
			#reverse for &e, i in app.edges do if e.from == a.id && e.to == b.id {
				delete(e.command)
				ordered_remove(&app.edges, i)
			}
		} else {
			remove_edges(app, a.id, from_only = true)
		}
		return true, "", {}
	}
	// everything else acts on one node
	if len(args) < 1 do return false, fmt.tprintf("usage: %s ID ...", raw[0]), {}
	ws := node_arg(app, args[0])
	if ws == nil do return false, "no such node", {}
	rest := args[1:]
	switch raw[0] {
	case "close":
		close_space(app, ws)
		return true, "", {}
	case "rename":
		if len(rest) < 1 do return false, "usage: rename ID NAME", {}
		clear(&ws.name)
		append(&ws.name, strings.join(rest, " ", context.temp_allocator))
		return true, "", {}
	case "focus":
		open_node(app, ws)
		return true, "", {}
	case "status":
		return true, node_line(ws), {}
	case "notify":
		set_note(ws, strings.join(rest, " ", context.temp_allocator))
		ws.attention = true
		if !app.focused do glfw.RequestWindowAttention(app.win)
		return true, "", {}
	case "send", "paste":
		enter := flag(&args, "--enter")
		and_wait := flag(&args, "--wait")
		rest = args[1:]
		if len(rest) < 1 do return false, "nothing to send", {}
		text := strings.join(rest, " ", context.temp_allocator)
		t := ws.tabs[ws.cur]
		if t == nil || t.focus == nil do return false, "node has no pane", {}
		out := make([dynamic]u8, context.temp_allocator)
		if raw[0] == "paste" {
			term.encode_paste(t.focus.pane.vt, text, &out)
		} else {
			append(&out, text)
		}
		if enter do append(&out, '\r')
		node_input(app, ws, out[:])
		// registering before the command can finish avoids racing a separate wait
		if and_wait do return true, "", Ctl_Waiter{node = ws.id, finished = ws.finished}
		return true, "", {}
	case "read":
		last := flag(&args, "--last")
		lines_s, has_lines := option(&args, "--lines")
		t := ws.tabs[ws.cur]
		if t == nil || t.focus == nil do return false, "node has no pane", {}
		vt := t.focus.pane.vt
		if last do return true, term.last_output(vt, context.temp_allocator), {}
		n := vt.rows
		if has_lines {
			v, vok := strconv.parse_int(lines_s, 10)
			if !vok || v < 1 do return false, "bad --lines", {}
			n = v
		}
		// end at the cursor; rows below it are usually blank
		hi := vt.hist.total + (vt.primary.saved.y if vt.scr == &vt.alt else vt.cur.y)
		if vt.scr == &vt.alt do hi = term.last_line(vt)
		lo := max(hi - n + 1, term.first_line(vt))
		s := term.selection_text(vt, {lo, 0}, {hi, vt.cols - 1}, context.temp_allocator)
		return true, strings.trim_right(s, "\n "), {}
	case "wait":
		timeout_s, has_timeout := option(&args, "--timeout")
		w := Ctl_Waiter{node = ws.id, finished = ws.finished}
		if has_timeout {
			secs, sok := strconv.parse_f64(timeout_s)
			if !sok || secs < 0 do return false, "bad --timeout", {}
			w.deadline = time.tick_add(time.tick_now(), time.Duration(secs * f64(time.Second)))
		}
		return true, "", w
	}
	return false, fmt.tprintf("unknown command %q\n%s", raw[0], CTL_HELP), {}
}

// votty ctl ...: sends one request to the running instance and prints the answer
ctl_client :: proc(args: []string) -> int {
	path := os.get_env("VOTTY_SOCKET", context.temp_allocator)
	if path == "" {
		// outside votty, talk to the newest instance of this user
		dir := integration_dir()
		newest: time.Time
		if fis, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
			for fi in fis {
				if strings.has_prefix(fi.name, "ctl-") && strings.has_suffix(fi.name, ".sock") && time.diff(newest, fi.modification_time) > 0 {
					newest = fi.modification_time
					path = fi.fullpath
				}
			}
		}
	}
	if path == "" {
		fmt.eprintln("votty ctl: no running votty found")
		return 1
	}
	node := os.get_env("VOTTY_NODE", context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	for a, i in args {
		v := a
		if a == "self" {
			if node == "" {
				fmt.eprintln("votty ctl: self only works inside votty")
				return 1
			}
			v = node
		}
		if a == "-" && i > 0 && (args[0] == "send" || args[0] == "paste") {
			data, _ := os.read_entire_file(os.stdin, context.temp_allocator)
			v = string(data)
		}
		if i > 0 do strings.write_rune(&sb, FIELD_SEP)
		escape_field(v, &sb)
	}
	strings.write_byte(&sb, '\n')
	addr, ok := unix_addr(path)
	if !ok do return 1
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 || posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		fmt.eprintln("votty ctl: cannot connect to", path)
		return 1
	}
	req := transmute([]u8)strings.to_string(sb)
	for len(req) > 0 {
		n := posix.write(fd, raw_data(req), uint(len(req)))
		if n <= 0 do break
		req = req[n:]
	}
	resp := make([dynamic]u8, context.temp_allocator)
	buf: [65536]u8
	for {
		n := posix.read(fd, &buf[0], len(buf))
		if n <= 0 do break
		append(&resp, ..buf[:n])
	}
	posix.close(fd)
	s := string(resp[:])
	nl := strings.index_byte(s, '\n')
	if nl < 0 {
		fmt.eprintln("votty ctl: no answer")
		return 1
	}
	status, body := s[:nl], s[nl + 1:]
	if status != "ok" {
		fmt.eprintln("votty ctl:", body)
		return 1
	}
	if body != "" do fmt.println(strings.trim_right(body, "\n"))
	return 0
}
