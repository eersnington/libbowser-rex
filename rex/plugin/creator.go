package main

// creatorList is the block_creator.list payload: what Rex shows in
// `rex block types` and validates nothing else against (see PROTOCOL.md).
var creatorList = map[string]any{
	"creators": []any{map[string]any{
		"name":        creatorName,
		"title":       "Bowser",
		"description": "Blocks that show a libbowser producer, such as a browser.",
		"flavors": []any{map[string]any{
			"name":        "browser",
			"flavor":      flavorName,
			"title":       "Browser",
			"description": "A browser tab in the shared bowser-cef engine. Hosts attach with a ticket.",
			"options_schema": obj(map[string]any{
				"url": map[string]any{"type": "string", "description": "The page to open, as typed into an address bar."},
				"transport": map[string]any{"type": "string", "enum": []string{"calayerhost", "iosurface"},
					"description": "How frames reach the host. Defaults to calayerhost."},
				"mode": map[string]any{"type": "string", "enum": []string{"windowed", "osr"},
					"description": "How the engine renders: windowed (zero copy, calayerhost only) or osr. Defaults to the engine's choice for the transport."},
			}),
		}},
		"api": map[string]any{
			"methods": map[string]any{
				"ticket": map[string]any{
					"description":  "Get a fresh single-use ticket to attach a host to this block's surface.",
					"input_schema": obj(map[string]any{}),
					"output_schema": obj(map[string]any{
						"ticket": map[string]any{"type": "string", "description": "Pass it to bowser_host_attach within 60 s."},
					}, "ticket"),
				},
				"state": map[string]any{
					"description":  "The page's newest state, and the block's engine.",
					"input_schema": obj(map[string]any{}),
					"output_schema": obj(stateProps(map[string]any{
						"transport": map[string]any{"type": "string", "enum": []string{"calayerhost", "iosurface"}},
						"mode": map[string]any{"type": "string", "enum": []string{"windowed", "osr"},
							"description": "windowed: zero copy, the default on calayerhost. osr: a copy per frame."},
						"engine_pid": map[string]any{"type": "integer", "minimum": 0, "description": "0 while the block has no surface."},
					})),
				},
				"navigate": map[string]any{
					"description": "Load what was typed: a URL, a host, or words to search for.",
					"input_schema": obj(map[string]any{
						"url": map[string]any{"type": "string"},
					}, "url"),
				},
				"back":    plainMethod("Go back in the page's history."),
				"forward": plainMethod("Go forward in the page's history."),
				"reload":  plainMethod("Reload the page."),
				"stop":    plainMethod("Stop loading the page."),
				"cdp": map[string]any{
					"description": "Run one Chrome DevTools Protocol method in the page, such as Runtime.evaluate. No debugging port is open: only Rex's callers can drive the page.",
					"input_schema": obj(map[string]any{
						"method": map[string]any{"type": "string", "description": "Domain.method"},
						"params": map[string]any{"type": "object"},
					}, "method"),
					"output_schema": obj(map[string]any{"result": map[string]any{"type": "object"}}),
				},
				"snapshot": map[string]any{
					"description": "The page's accessibility tree as text, one element per line. Elements an agent can act on get a ref, such as e3, for click and fill. Refs last until the next snapshot.",
					"input_schema": obj(map[string]any{
						"interactive": map[string]any{"type": "boolean", "description": "Only the elements with refs."},
					}),
					"output_schema": obj(map[string]any{"snapshot": map[string]any{"type": "string"}}, "snapshot"),
				},
				"click": map[string]any{
					"description":  "Click the middle of an element, as a mouse does, after scrolling it into view.",
					"input_schema": obj(map[string]any{"target": targetSchema}, "target"),
				},
				"fill": map[string]any{
					"description": "Replace the text of an input, a text area, or an editable element.",
					"input_schema": obj(map[string]any{
						"target": targetSchema,
						"text":   map[string]any{"type": "string"},
					}, "target", "text"),
				},
				"type": map[string]any{
					"description":  "Type text, one key at a time, into what has the keyboard. A newline presses Enter.",
					"input_schema": obj(map[string]any{"text": map[string]any{"type": "string"}}, "text"),
				},
				"press": map[string]any{
					"description":  "Press one key: a character or Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, with modifiers such as Shift+Tab.",
					"input_schema": obj(map[string]any{"key": map[string]any{"type": "string"}}, "key"),
				},
				"scroll": map[string]any{
					"description": "Scroll the page with the mouse wheel, from its middle. Positive dy scrolls down.",
					"input_schema": obj(map[string]any{
						"dx": map[string]any{"type": "number"},
						"dy": map[string]any{"type": "number"},
					}),
				},
				"eval": map[string]any{
					"description":   "Run a JavaScript expression in the page. A promise is awaited. Returns the value as JSON.",
					"input_schema":  obj(map[string]any{"js": map[string]any{"type": "string"}}, "js"),
					"output_schema": obj(map[string]any{"value": map[string]any{}}),
				},
				"screenshot": map[string]any{
					"description":   "Save what the page shows as a PNG.",
					"input_schema":  obj(map[string]any{"path": map[string]any{"type": "string", "description": "An absolute path."}}, "path"),
					"output_schema": obj(map[string]any{"path": map[string]any{"type": "string"}}),
				},
				"wait": map[string]any{
					"description": "Wait until an element shows (target), text shows (text), or, with neither, the page has loaded. At most 8 s.",
					"input_schema": obj(map[string]any{
						"target":     map[string]any{"type": "string", "description": "A CSS selector."},
						"text":       map[string]any{"type": "string"},
						"timeout_ms": map[string]any{"type": "integer", "minimum": 1, "description": "Default 5000."},
					}),
					"output_schema": obj(map[string]any{"waited_ms": map[string]any{"type": "integer"}}),
				},
				"trace_start": map[string]any{
					"description": "Start Chromium's trace of the whole engine. Returns its clock against mach time, in microseconds.",
					"input_schema": obj(map[string]any{
						"categories": map[string]any{"type": "string", "description": "Chromium trace categories; a frame-timing set if left out."},
					}),
					"output_schema": obj(map[string]any{
						"trace_us": map[string]any{"type": "number"},
						"mach_us":  map[string]any{"type": "number"},
					}, "trace_us", "mach_us"),
				},
				"trace_stop": map[string]any{
					"description": "Stop the trace. The engine writes it to path; the file appears when it is complete. Without path, the trace is thrown away.",
					"input_schema": obj(map[string]any{
						"path": map[string]any{"type": "string", "description": "An absolute path for the JSON trace."},
					}),
				},
			},
			"events": map[string]any{
				"state": obj(stateProps(nil)),
				"error": obj(map[string]any{
					"message": map[string]any{"type": "string"},
				}, "message"),
				"host_attached": obj(map[string]any{}),
				"host_detached": obj(map[string]any{}),
			},
		},
	}},
}

// The producer's state message (adapters/cef/README.md), plus extra.
func stateProps(extra map[string]any) map[string]any {
	props := map[string]any{
		"url":            map[string]any{"type": "string"},
		"title":          map[string]any{"type": "string"},
		"loading":        map[string]any{"type": "boolean"},
		"progress":       map[string]any{"type": "number", "minimum": 0, "maximum": 1},
		"can_go_back":    map[string]any{"type": "boolean"},
		"can_go_forward": map[string]any{"type": "boolean"},
	}
	for k, v := range extra {
		props[k] = v
	}
	return props
}

var targetSchema = map[string]any{"type": "string",
	"description": "A ref from the newest snapshot, such as e3, or a CSS selector."}

func plainMethod(description string) map[string]any {
	return map[string]any{"description": description, "input_schema": obj(map[string]any{})}
}

func obj(props map[string]any, required ...string) map[string]any {
	o := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		o["required"] = required
	}
	return o
}
