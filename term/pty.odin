package term

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"

foreign import libc "system:c"

foreign libc {
	@(link_name = "environ") c_environ: [^]cstring
}

TIOCSWINSZ :: 0x5414
TIOCSCTTY :: 0x540E
TIOCSPTLCK :: 0x40045431
TIOCGPTPEER :: 0x5441

// bound the bytes buffered between the reader thread and the parser
PENDING_MAX :: 4 << 20

Winsize :: struct {
	rows, cols, xpixel, ypixel: u16,
}

Pty :: struct {
	master:   linux.Fd,
	wake:     [2]linux.Fd,
	pid:      linux.Pid,
	reader:   ^thread.Thread,
	lock:     sync.Mutex,
	space:    sync.Cond,
	pending:  [dynamic]u8,
	eof:      bool,
	closing:  bool,
	outq:     [dynamic]u8,
	status:   u32,
	reaped:   bool,
	notify:   proc(data: rawptr),
	userdata: rawptr,
}

// spawns argv[0] on a fresh pty; extra env entries are "KEY=value"
pty_spawn :: proc(argv: []string, env: []string, ws: Winsize, notify: proc(data: rawptr) = nil, userdata: rawptr = nil) -> (p: ^Pty, ok: bool) {
	master, err := linux.open("/dev/ptmx", {.RDWR, .NOCTTY, .CLOEXEC, .NONBLOCK})
	if err != nil do return nil, false
	unlock: i32 = 0
	if linux.ioctl(master, TIOCSPTLCK, uintptr(&unlock)) != 0 {
		linux.close(master)
		return nil, false
	}
	slave_r := linux.ioctl(master, TIOCGPTPEER, uintptr(transmute(u32)linux.Open_Flags{.RDWR, .NOCTTY, .CLOEXEC}))
	if int(slave_r) < 0 {
		linux.close(master)
		return nil, false
	}
	slave := linux.Fd(slave_r)
	w := ws
	linux.ioctl(master, TIOCSWINSZ, uintptr(&w))

	p = new(Pty)
	p.master = master
	p.notify = notify
	p.userdata = userdata
	if linux.pipe2(&p.wake, {.CLOEXEC, .NONBLOCK}) != nil {
		linux.close(slave)
		linux.close(master)
		free(p)
		return nil, false
	}

	// build everything the child needs before fork
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	cenv := make([dynamic]cstring, context.temp_allocator)
	for e in env do append(&cenv, strings.clone_to_cstring(e, context.temp_allocator))
	outer: for i := 0; c_environ != nil && c_environ[i] != nil; i += 1 {
		s := string(c_environ[i])
		key := s[:strings.index_byte(s, '=') + 1]
		for e in env do if strings.has_prefix(e, key) do continue outer
		append(&cenv, c_environ[i])
	}
	append(&cenv, nil)

	pid, ferr := linux.fork()
	if ferr != nil {
		linux.close(slave)
		pty_free(p)
		return nil, false
	}
	if pid == 0 do child_exec(slave, raw_data(cargv), raw_data(cenv))

	linux.close(slave)
	p.pid = pid
	p.reader = thread.create_and_start_with_data(p, reader_loop)
	return p, true
}

@(private)
child_exec :: proc "contextless" (slave: linux.Fd, argv, envp: [^]cstring) -> ! {
	linux.setsid()
	linux.ioctl(slave, TIOCSCTTY, 0)
	linux.dup2(slave, 0)
	linux.dup2(slave, 1)
	linux.dup2(slave, 2)
	linux.close_range(3, ~linux.Fd(0), {})
	dfl: linux.Sig_Action
	for s in 1 ..< 32 {
		sig := linux.Signal(s)
		if sig == .SIGKILL || sig == .SIGSTOP do continue
		linux.rt_sigaction(sig, &dfl, nil)
	}
	empty: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
	linux.execve(argv[0], argv, envp)
	// fall back to a PATH lookup for non-absolute shells
	name := string(argv[0])
	if len(name) > 0 && name[0] != '/' {
		buf: [512]u8
		for dir in ([]string{"/usr/local/bin/", "/usr/bin/", "/bin/"}) {
			if len(dir) + len(name) + 1 > len(buf) do continue
			runtime.mem_copy_non_overlapping(&buf[0], raw_data(dir), len(dir))
			runtime.mem_copy_non_overlapping(&buf[len(dir)], raw_data(name), len(name))
			buf[len(dir) + len(name)] = 0
			linux.execve(cstring(&buf[0]), argv, envp)
		}
	}
	linux.exit(127)
}

@(private)
reader_loop :: proc(data: rawptr) {
	p := (^Pty)(data)
	buf: [65536]u8
	fds := [2]linux.Poll_Fd{{fd = p.master, events = {.IN}}, {fd = p.wake[0], events = {.IN}}}
	for {
		_, perr := linux.poll(fds[:], -1)
		if perr == .EINTR do continue
		if perr != nil || .IN in fds[1].revents do break
		if fds[0].revents == {} do continue
		n, err := linux.read(p.master, buf[:])
		if err == .EINTR || err == .EAGAIN do continue
		if n <= 0 do break
		sync.lock(&p.lock)
		for len(p.pending) + n > PENDING_MAX && !p.closing do sync.cond_wait(&p.space, &p.lock)
		closing := p.closing
		if !closing do append(&p.pending, ..buf[:n])
		sync.unlock(&p.lock)
		if closing do return
		if p.notify != nil do p.notify(p.userdata)
	}
	sync.lock(&p.lock)
	p.eof = true
	sync.unlock(&p.lock)
	if p.notify != nil do p.notify(p.userdata)
}

// swaps out buffered output; buf is cleared and reused by the reader
pty_take :: proc(p: ^Pty, buf: ^[dynamic]u8) -> (eof: bool) {
	clear(buf)
	sync.lock(&p.lock)
	p.pending, buf^ = buf^, p.pending
	eof = p.eof && len(buf) == 0
	sync.unlock(&p.lock)
	sync.cond_signal(&p.space)
	return
}

pty_write :: proc(p: ^Pty, data: []u8) {
	if len(p.outq) > 0 {
		append(&p.outq, ..data)
		pty_flush(p)
		return
	}
	rest := data
	for len(rest) > 0 {
		n, err := linux.write(p.master, rest)
		if err == .EINTR do continue
		if err != nil || n <= 0 do break
		rest = rest[n:]
	}
	if len(rest) > 0 do append(&p.outq, ..rest)
}

// returns true while queued input remains
pty_flush :: proc(p: ^Pty) -> bool {
	for len(p.outq) > 0 {
		n, err := linux.write(p.master, p.outq[:])
		if err == .EINTR do continue
		if err == .EAGAIN do return true
		if err != nil || n <= 0 {
			clear(&p.outq)
			return false
		}
		remove_range(&p.outq, 0, n)
	}
	return false
}

pty_resize :: proc(p: ^Pty, ws: Winsize) {
	w := ws
	// the kernel delivers SIGWINCH to the foreground process group
	linux.ioctl(p.master, TIOCSWINSZ, uintptr(&w))
}

// non-blocking check whether the child has exited
pty_reap :: proc(p: ^Pty) -> bool {
	if p.reaped do return true
	st: u32
	pid, err := linux.wait4(p.pid, &st, {.WNOHANG}, nil)
	if pid == p.pid || err == .ECHILD {
		p.status = st
		p.reaped = true
	}
	return p.reaped
}

pty_close :: proc(p: ^Pty) {
	if p == nil do return
	if !pty_reap(p) {
		linux.kill(-p.pid, .SIGHUP)
		linux.kill(p.pid, .SIGHUP)
	}
	sync.lock(&p.lock)
	p.closing = true
	sync.unlock(&p.lock)
	sync.cond_broadcast(&p.space)
	one := [1]u8{1}
	linux.write(p.wake[1], one[:])
	thread.join(p.reader)
	thread.destroy(p.reader)
	// give the shell a moment to exit on sighup, then insist
	for i in 0 ..< 50 {
		if pty_reap(p) do break
		if i == 20 do linux.kill(p.pid, .SIGKILL)
		ts := linux.Time_Spec{time_nsec = 2_000_000}
		linux.nanosleep(&ts, nil)
	}
	if !p.reaped {
		linux.wait4(p.pid, &p.status, {}, nil)
		p.reaped = true
	}
	pty_free(p)
}

@(private)
pty_free :: proc(p: ^Pty) {
	linux.close(p.master)
	linux.close(p.wake[0])
	linux.close(p.wake[1])
	delete(p.pending)
	delete(p.outq)
	free(p)
}

exit_code :: proc(p: ^Pty) -> int {
	if p.status & 0x7f == 0 do return int((p.status >> 8) & 0xff)
	return 128 + int(p.status & 0x7f)
}
