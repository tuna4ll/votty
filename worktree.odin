package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// runs a program without a shell and returns what it printed with its exit status
run_capture :: proc(argv: []string, allocator := context.temp_allocator) -> (out: string, code: int) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return "", -1
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return "", -1
	}
	if pid == 0 {
		posix.dup2(fds[1], 1)
		posix.dup2(fds[1], 2)
		posix.close(fds[0])
		posix.close(fds[1])
		posix.execvp(cargv[0], raw_data(cargv))
		posix._exit(127)
	}
	posix.close(fds[1])
	buf: [4096]u8
	sb := strings.builder_make(allocator)
	for {
		n := posix.read(fds[0], &buf[0], len(buf))
		if n <= 0 do break
		if len(sb.buf) < 1 << 20 do strings.write_bytes(&sb, buf[:n])
	}
	posix.close(fds[0])
	st: i32
	posix.waitpid(pid, &st, {})
	code = int((st >> 8) & 0xff) if st & 0x7f == 0 else 128 + int(st & 0x7f)
	return strings.trim_space(strings.to_string(sb)), code
}

@(private = "file")
worktree_counter: int

// adds a git worktree next to the repository that holds dir; branch defaults to votty/node-N
make_worktree :: proc(dir, branch: string) -> (path: string, err: string) {
	if dir == "" do return "", "no directory to start from"
	root, code := run_capture({"git", "-C", dir, "rev-parse", "--show-toplevel"})
	if code != 0 do return "", fmt.tprintf("not a git repository: %s", dir)
	b := branch
	if b == "" {
		worktree_counter += 1
		b = fmt.tprintf("votty/node-%d-%d", posix.getpid(), worktree_counter)
	}
	if strings.has_prefix(b, "-") do return "", "bad branch name"
	slug, _ := strings.replace_all(b, "/", "-", context.temp_allocator)
	parent := root[:max(strings.last_index_byte(root, '/'), 0)]
	target := fmt.tprintf("%s/%s-%s", parent, filepath.base(root), slug)
	msg: string
	msg, code = run_capture({"git", "-C", root, "worktree", "add", "-b", b, target})
	if code != 0 && branch != "" {
		// the branch may already exist
		msg, code = run_capture({"git", "-C", root, "worktree", "add", target, b})
	}
	if code != 0 do return "", fmt.tprintf("git worktree add failed: %s", msg)
	return target, ""
}
