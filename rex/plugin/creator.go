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
			"description": "Runs a libbowser producer and hands out tickets that a host attaches with.",
			"options_schema": obj(map[string]any{
				"url": map[string]any{"type": "string", "description": "The page to open. bowser-test ignores it."},
				"transport": map[string]any{"type": "string", "enum": []string{"calayerhost", "iosurface"},
					"description": "How frames reach the host. Defaults to calayerhost."},
			}),
		}},
		"api": map[string]any{
			"methods": map[string]any{
				"ticket": map[string]any{
					"description":  "Get a fresh single-use ticket to attach a host to this block's surface.",
					"input_schema": obj(map[string]any{}),
					"output_schema": obj(map[string]any{
						"ticket":    map[string]any{"type": "string", "description": "Pass it to bowser_host_attach."},
						"remaining": map[string]any{"type": "integer", "minimum": 0, "description": "Tickets left in this producer's batch."},
					}, "ticket", "remaining"),
				},
				"state": map[string]any{
					"description":  "Describe the block's producer.",
					"input_schema": obj(map[string]any{}),
					"output_schema": obj(map[string]any{
						"url":          map[string]any{"type": "string"},
						"transport":    map[string]any{"type": "string", "enum": []string{"calayerhost", "iosurface"}},
						"producer_pid": map[string]any{"type": "integer", "minimum": 0, "description": "0 once the producer has exited."},
					}, "url", "transport", "producer_pid"),
				},
			},
			"events": map[string]any{
				"producer_exited": obj(map[string]any{
					"pid":    map[string]any{"type": "integer"},
					"status": map[string]any{"type": "string", "description": "How it ended, such as \"exit status 1\" or \"signal: killed\"."},
				}, "pid", "status"),
				"host_attached": obj(map[string]any{}),
				"host_detached": obj(map[string]any{}),
			},
		},
	}},
}

func obj(props map[string]any, required ...string) map[string]any {
	o := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		o["required"] = required
	}
	return o
}
