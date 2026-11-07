package main

import "core:fmt"
import "core:os"
import gl "vendor:OpenGL"
import "vendor:glfw"

main :: proc() {
	if !glfw.Init() {
		fmt.eprintln("votty: glfw init failed")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)

	win := glfw.CreateWindow(960, 600, "votty", nil, nil)
	if win == nil {
		fmt.eprintln("votty: cannot create window")
		os.exit(1)
	}
	defer glfw.DestroyWindow(win)
	glfw.MakeContextCurrent(win)
	glfw.SwapInterval(1)
	gl.load_up_to(4, 6, glfw.gl_set_proc_address)

	for !glfw.WindowShouldClose(win) {
		glfw.WaitEvents()
		w, h := glfw.GetFramebufferSize(win)
		gl.Viewport(0, 0, w, h)
		gl.ClearColor(0.1, 0.1, 0.12, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		glfw.SwapBuffers(win)
	}
}
