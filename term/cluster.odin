package term

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// grapheme clusters and hyperlinks are interned once and shared by every terminal,
// so a cell value means the same thing in every pane and in the glyph cache
CLUSTER_BASE :: rune(0x110000)
MAX_CLUSTERS :: 1 << 20
MAX_LINKS :: 0xffff

@(private)
interned: struct {
	clusters:    [dynamic]string,
	cluster_ids: map[string]rune,
	links:       [dynamic]string,
	link_ids:    map[string]u16,
}

is_cluster :: #force_inline proc "contextless" (ch: rune) -> bool {return ch >= CLUSTER_BASE}

// the utf-8 text of a cell character
cell_text :: proc(ch: rune, buf: ^[4]u8) -> string {
	if is_cluster(ch) do return interned.clusters[ch - CLUSTER_BASE]
	if ch == 0 {
		buf[0] = ' '
		return string(buf[:1])
	}
	b, n := utf8.encode_rune(ch)
	buf^ = b
	return string(buf[:n])
}

// first code point of a cell, for matching and word boundaries
base_rune :: proc(ch: rune) -> rune {
	if !is_cluster(ch) do return ch
	r, _ := utf8.decode_rune_in_string(interned.clusters[ch - CLUSTER_BASE])
	return r
}

// the cell char for ch followed by r; falls back to ch when the table is full
cluster_append :: proc(ch: rune, r: rune) -> rune {
	buf: [4]u8
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, cell_text(ch, &buf))
	strings.write_rune(&sb, r)
	s := strings.to_string(sb)
	if id, ok := interned.cluster_ids[s]; ok do return id
	if len(interned.clusters) >= MAX_CLUSTERS || len(s) > 256 do return ch
	// the table outlives any one terminal, so it never borrows a caller's allocator
	context.allocator = runtime.heap_allocator()
	owned := strings.clone(s)
	id := CLUSTER_BASE + rune(len(interned.clusters))
	append(&interned.clusters, owned)
	interned.cluster_ids[owned] = id
	return id
}

intern_link :: proc(uri: string) -> u16 {
	if uri == "" do return 0
	if id, ok := interned.link_ids[uri]; ok do return id
	// shortcut: links stop being recorded once the table is full; reset it if long sessions need more
	if len(interned.links) >= MAX_LINKS - 1 do return 0
	context.allocator = runtime.heap_allocator()
	owned := strings.clone(uri)
	append(&interned.links, owned)
	id := u16(len(interned.links))
	interned.link_ids[owned] = id
	return id
}

link_uri :: proc(id: u16) -> string {
	if id == 0 || int(id) > len(interned.links) do return ""
	return interned.links[id - 1]
}

intern_free :: proc() {
	context.allocator = runtime.heap_allocator()
	for s in interned.clusters do delete(s)
	for s in interned.links do delete(s)
	delete(interned.clusters)
	delete(interned.cluster_ids)
	delete(interned.links)
	delete(interned.link_ids)
	interned = {}
}
