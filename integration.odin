package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// prompt and command markers (osc 133) for shells that do not send them natively;
// fish 4 already does
BASH_RC :: `[ -f ~/.bashrc ] && . ~/.bashrc
__votty_prompt() { local s=$?; printf '\e]133;D;%s\a\e]133;A\a' "$s"; }
PROMPT_COMMAND="__votty_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS0="${PS0}\[\e]133;C\a\]"
PS1="${PS1}\[\e]133;B\a\]"
`

ZSH_ENV :: `if [[ -n $VOTTY_ZDOTDIR ]]; then ZDOTDIR=$VOTTY_ZDOTDIR; else unset ZDOTDIR; fi
unset VOTTY_ZDOTDIR
[[ -f ${ZDOTDIR:-$HOME}/.zshenv ]] && source ${ZDOTDIR:-$HOME}/.zshenv
if [[ -o interactive ]]; then
  __votty_precmd() { local s=$?; print -n "\e]133;D;$s\a\e]133;A\a"; }
  __votty_preexec() { print -n "\e]133;C\a"; }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd __votty_precmd
  add-zsh-hook preexec __votty_preexec
fi
`

USER_ONLY :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// a private directory for the integration files, created once per run
integration_dir :: proc(allocator := context.temp_allocator) -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := fmt.aprintf("%s/votty-%d", base, os.get_uid(), allocator = allocator)
	os.make_directory(dir, USER_ONLY)
	return dir
}

write_if_changed :: proc(path, content: string) -> bool {
	old, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil && string(old) == content do return true
	return os.write_entire_file(path, transmute([]u8)content) == nil
}

// rewrites argv and env so the shell reports prompts and commands
shell_integration :: proc(argv: []string, env: ^[dynamic]string) -> []string {
	name := filepath.base(argv[0])
	dir := integration_dir()
	switch name {
	case "bash":
		rc := strings.concatenate({dir, "/bashrc"}, context.temp_allocator)
		if !write_if_changed(rc, BASH_RC) do return argv
		out := make([dynamic]string, context.temp_allocator)
		append(&out, argv[0], "--rcfile", rc)
		append(&out, ..argv[1:])
		return out[:]
	case "zsh":
		zdir := strings.concatenate({dir, "/zsh"}, context.temp_allocator)
		os.make_directory(zdir, USER_ONLY)
		if !write_if_changed(strings.concatenate({zdir, "/.zshenv"}, context.temp_allocator), ZSH_ENV) do return argv
		if orig := os.get_env("ZDOTDIR", context.temp_allocator); orig != "" {
			append(env, strings.concatenate({"VOTTY_ZDOTDIR=", orig}, context.temp_allocator))
		}
		append(env, strings.concatenate({"ZDOTDIR=", zdir}, context.temp_allocator))
	}
	return argv
}
