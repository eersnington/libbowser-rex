package main

// Page actions, for agents: block methods that drive the block's page with
// DevTools protocol methods, run in the engine's process (its cdp command).
// No debugging port is open, so only Rex's callers can drive a page. The
// bowser CLI (rex/bowser) is their front end.
//
// A snapshot names the page's elements e1, e2, …; click and fill take those
// refs, or a CSS selector. Refs last until the next snapshot of the block.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Rex refuses messages over 1 MB; a snapshot stays well under.
const snapshotMax = 768 << 10

// cdp runs one DevTools protocol method in the block's page.
func (p *plugin) cdp(b *block, method string, params map[string]any) (json.RawMessage, error) {
	e, sid, err := p.surface(b)
	if err != nil {
		return nil, err
	}
	cmd := map[string]any{"cmd": "cdp", "surface": sid, "method": method}
	if params != nil {
		cmd["params"] = params
	}
	r, err := e.call(cmd)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	return r["result"], nil
}

// cdpInto runs a method and decodes its result into out.
func (p *plugin) cdpInto(b *block, method string, params map[string]any, out any) error {
	raw, err := p.cdp(b, method, params)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(raw, out)
}

// action runs one of actionMethods.
func (p *plugin) action(b *block, name string, raw json.RawMessage) (any, *rpcError) {
	var args struct {
		Method      string         `json:"method,omitempty"`
		Params      map[string]any `json:"params,omitempty"`
		Interactive bool           `json:"interactive,omitempty"`
		Target      string         `json:"target,omitempty"`
		Text        *string        `json:"text,omitempty"`
		Key         string         `json:"key,omitempty"`
		DX          float64        `json:"dx,omitempty"`
		DY          float64        `json:"dy,omitempty"`
		JS          string         `json:"js,omitempty"`
		Path        string         `json:"path,omitempty"`
		TimeoutMS   int            `json:"timeout_ms,omitempty"`
	}
	if err := decodeStrict(raw, &args); err != nil {
		return nil, errBadRequest(name + " args: " + err.Error())
	}
	need := func(ok bool, what string) *rpcError {
		if ok {
			return nil
		}
		return errBadRequest(name + " needs " + what)
	}
	text := ""
	if args.Text != nil {
		text = *args.Text
	}
	var out any
	var err error
	switch name {
	case "cdp":
		if e := need(args.Method != "", `{"method": "Domain.method"}`); e != nil {
			return nil, e
		}
		var res json.RawMessage
		if res, err = p.cdp(b, args.Method, args.Params); err == nil {
			out = map[string]any{"result": res}
		}
	case "snapshot":
		var s string
		if s, err = p.snapshot(b, args.Interactive); err == nil {
			out = map[string]any{"snapshot": s}
		}
	case "click":
		if e := need(args.Target != "", `a "target": a ref from snapshot, or a CSS selector`); e != nil {
			return nil, e
		}
		err = p.click(b, args.Target)
	case "fill":
		if e := need(args.Target != "" && args.Text != nil, `a "target" and a "text"`); e != nil {
			return nil, e
		}
		err = p.fill(b, args.Target, text)
	case "type":
		if e := need(args.Text != nil, `a "text"`); e != nil {
			return nil, e
		}
		err = p.typeText(b, text)
	case "press":
		if e := need(args.Key != "", `a "key", such as Enter or Shift+Tab`); e != nil {
			return nil, e
		}
		err = p.press(b, args.Key)
	case "scroll":
		if e := need(args.DX != 0 || args.DY != 0, `a "dy" or "dx" in CSS pixels`); e != nil {
			return nil, e
		}
		err = p.scroll(b, args.DX, args.DY)
	case "eval":
		if e := need(args.JS != "", `a "js" expression`); e != nil {
			return nil, e
		}
		var v json.RawMessage
		if v, err = p.eval(b, args.JS); err == nil {
			out = map[string]any{"value": v}
		}
	case "screenshot":
		if e := need(filepath.IsAbs(args.Path), `an absolute "path" for the PNG`); e != nil {
			return nil, e
		}
		if err = p.screenshot(b, args.Path); err == nil {
			out = map[string]any{"path": args.Path}
		}
	case "wait":
		var waited time.Duration
		if waited, err = p.wait(b, args.Target, args.Text, args.TimeoutMS); err == nil {
			out = map[string]any{"waited_ms": waited.Milliseconds()}
		}
	default:
		return nil, errNoMethod(name)
	}
	if err != nil {
		return nil, errBadRequest(err.Error())
	}
	return out, nil
}

var actionMethods = map[string]bool{"cdp": true, "snapshot": true, "click": true, "fill": true, "type": true,
	"press": true, "scroll": true, "eval": true, "screenshot": true, "wait": true}

// ---- Snapshot ---------------------------------------------------------

type axValue struct {
	Value any `json:"value"`
}

type axNode struct {
	NodeID     string   `json:"nodeId"`
	Ignored    bool     `json:"ignored"`
	Role       *axValue `json:"role"`
	Name       *axValue `json:"name"`
	Value      *axValue `json:"value"`
	ChildIDs   []string `json:"childIds"`
	ParentID   string   `json:"parentId"`
	BackendID  int64    `json:"backendDOMNodeId"`
	Properties []struct {
		Name  string  `json:"name"`
		Value axValue `json:"value"`
	} `json:"properties"`
}

func (v *axValue) str() string {
	if v == nil || v.Value == nil {
		return ""
	}
	if s, ok := v.Value.(string); ok {
		return s
	}
	return fmt.Sprint(v.Value)
}

// Roles an agent acts on: each gets a ref.
var interactiveRoles = map[string]bool{"button": true, "link": true, "textbox": true, "searchbox": true,
	"checkbox": true, "radio": true, "combobox": true, "listbox": true, "option": true, "menuitem": true,
	"menuitemcheckbox": true, "menuitemradio": true, "tab": true, "switch": true, "slider": true,
	"spinbutton": true, "treeitem": true}

// Roles that only group others: their children take their place.
var transparentRoles = map[string]bool{"generic": true, "none": true, "presentation": true,
	"RootWebArea": true, "WebArea": true}

// Properties worth showing, as Playwright's ARIA snapshots show them.
var shownProperties = []string{"level", "checked", "pressed", "selected", "expanded", "disabled", "required"}

// snapshot is the page's accessibility tree, one element per line, with a
// ref for each element an agent can act on.
func (p *plugin) snapshot(b *block, interactiveOnly bool) (string, error) {
	var tree struct {
		Nodes []axNode `json:"nodes"`
	}
	if err := p.cdpInto(b, "Accessibility.getFullAXTree", nil, &tree); err != nil {
		return "", err
	}
	byID := make(map[string]*axNode, len(tree.Nodes))
	for i := range tree.Nodes {
		byID[tree.Nodes[i].NodeID] = &tree.Nodes[i]
	}
	refs := map[string]int64{}
	var sb strings.Builder
	var walk func(id string, depth int, parentName string)
	walk = func(id string, depth int, parentName string) {
		n := byID[id]
		if n == nil || sb.Len() > snapshotMax {
			return
		}
		role, name := n.Role.str(), strings.Join(strings.Fields(n.Name.str()), " ")
		switch {
		case role == "InlineTextBox" || role == "LineBreak":
			return
		case role == "StaticText":
			// Text already in its parent's name, as in a link's, says nothing new.
			if !interactiveOnly && name != "" && !strings.Contains(parentName, name) {
				fmt.Fprintf(&sb, "%s- text: %s\n", indent(depth), quote(name))
			}
			return
		}
		shown := !n.Ignored && !transparentRoles[role]
		focusable := false
		for _, pr := range n.Properties {
			if pr.Name == "focusable" && pr.Value.Value == true {
				focusable = true
			}
		}
		ref := ""
		if shown && n.BackendID != 0 && (interactiveRoles[role] || focusable) {
			ref = fmt.Sprintf("e%d", len(refs)+1)
			refs[ref] = n.BackendID
		}
		if shown && (!interactiveOnly || ref != "") {
			line := indent(depth) + "- " + role
			if interactiveOnly {
				line = "- " + role
			}
			if name != "" {
				line += " " + quote(name)
			}
			for _, want := range shownProperties {
				for _, pr := range n.Properties {
					if pr.Name != want {
						continue
					}
					switch v := pr.Value.Value.(type) {
					case bool:
						if v {
							line += " [" + want + "]"
						}
					case string:
						if v != "" && v != "false" {
							line += " [" + want + "=" + v + "]"
						}
					case float64:
						line += fmt.Sprintf(" [%s=%g]", want, v)
					}
				}
			}
			if ref != "" {
				line += " [ref=" + ref + "]"
			}
			if v := n.Value.str(); v != "" {
				line += ": " + clip(v)
			}
			sb.WriteString(line + "\n")
			parentName = name
			depth++
		}
		for _, c := range n.ChildIDs {
			walk(c, depth, parentName)
		}
	}
	for i := range tree.Nodes {
		if tree.Nodes[i].ParentID == "" {
			walk(tree.Nodes[i].NodeID, 0, "")
		}
	}
	b.mu.Lock()
	b.refs = refs
	b.mu.Unlock()
	if sb.Len() > snapshotMax {
		return sb.String()[:snapshotMax] + "\n… (cut: the page is too big to list; use snapshot -i)\n", nil
	}
	if sb.Len() == 0 {
		return "(the page shows nothing an agent can read)\n", nil
	}
	return sb.String(), nil
}

func indent(depth int) string { return strings.Repeat("  ", depth) }

func clip(s string) string {
	if utf8.RuneCountInString(s) > 100 {
		s = string([]rune(s)[:99]) + "…"
	}
	return s
}

func quote(s string) string { b, _ := json.Marshal(clip(s)); return string(b) }

// ---- Elements ---------------------------------------------------------

var refPattern = regexp.MustCompile(`^@?(e\d+)$`)

// element resolves a ref from the last snapshot, or a CSS selector, to a
// remote object the protocol's element methods take.
func (p *plugin) element(b *block, target string) (string, error) {
	if m := refPattern.FindStringSubmatch(target); m != nil {
		b.mu.Lock()
		backend, ok := b.refs[m[1]]
		b.mu.Unlock()
		if !ok {
			return "", fmt.Errorf("no ref %s: take a snapshot first, and use a ref from the newest one", m[1])
		}
		var r struct {
			Object struct {
				ObjectID string `json:"objectId"`
			} `json:"object"`
		}
		if err := p.cdpInto(b, "DOM.resolveNode", map[string]any{"backendNodeId": backend}, &r); err != nil {
			return "", fmt.Errorf("ref %s is gone from the page; take a new snapshot", m[1])
		}
		return r.Object.ObjectID, nil
	}
	sel, _ := json.Marshal(target)
	var r struct {
		Result struct {
			ObjectID string `json:"objectId"`
			Subtype  string `json:"subtype"`
		} `json:"result"`
		Exception *struct {
			Text string `json:"text"`
		} `json:"exceptionDetails"`
	}
	if err := p.cdpInto(b, "Runtime.evaluate", map[string]any{"expression": "document.querySelector(" + string(sel) + ")"},
		&r); err != nil {
		return "", err
	}
	if r.Exception != nil {
		return "", fmt.Errorf("%q is not a CSS selector or a ref", target)
	}
	if r.Result.ObjectID == "" || r.Result.Subtype == "null" {
		return "", fmt.Errorf("no element matches %q", target)
	}
	return r.Result.ObjectID, nil
}

// center is where a click on the element lands: the middle of its first box,
// in the viewport's CSS pixels, after scrolling it into view.
func (p *plugin) center(b *block, object string) (x, y float64, err error) {
	p.cdp(b, "DOM.scrollIntoViewIfNeeded", map[string]any{"objectId": object})
	var q struct {
		Quads [][]float64 `json:"quads"`
	}
	if err := p.cdpInto(b, "DOM.getContentQuads", map[string]any{"objectId": object}, &q); err != nil || len(q.Quads) == 0 {
		return 0, 0, errors.New("the element isn't visible: it has no box on the page")
	}
	for i := 0; i < 8; i += 2 {
		x += q.Quads[0][i] / 4
		y += q.Quads[0][i+1] / 4
	}
	return x, y, nil
}

func (p *plugin) click(b *block, target string) error {
	object, err := p.element(b, target)
	if err != nil {
		return err
	}
	x, y, err := p.center(b, object)
	if err != nil {
		return err
	}
	for _, kind := range []string{"mouseMoved", "mousePressed", "mouseReleased"} {
		ev := map[string]any{"type": kind, "x": x, "y": y}
		if kind != "mouseMoved" {
			ev["button"], ev["clickCount"] = "left", 1
		}
		if _, err := p.cdp(b, "Input.dispatchMouseEvent", ev); err != nil {
			return err
		}
	}
	return nil
}

// fill replaces the element's text with text, as a person would by
// selecting it all and typing.
func (p *plugin) fill(b *block, target, text string) error {
	object, err := p.element(b, target)
	if err != nil {
		return err
	}
	if _, err := p.cdp(b, "DOM.focus", map[string]any{"objectId": object}); err != nil {
		return errors.New("the element can't take the keyboard")
	}
	selectAll := `function() {
		if (typeof this.select === "function") return this.select();
		const r = document.createRange(); r.selectNodeContents(this);
		const s = getSelection(); s.removeAllRanges(); s.addRange(r);
	}`
	if _, err := p.cdp(b, "Runtime.callFunctionOn", map[string]any{"objectId": object, "functionDeclaration": selectAll}); err != nil {
		return err
	}
	if text == "" {
		return p.press(b, "Backspace")
	}
	_, err = p.cdp(b, "Input.insertText", map[string]any{"text": text})
	return err
}

// ---- Keys -------------------------------------------------------------

type keyDef struct {
	code string
	vk   int
	text string
}

var namedKeys = map[string]keyDef{
	"Enter": {"Enter", 13, "\r"}, "Tab": {"Tab", 9, ""}, "Escape": {"Escape", 27, ""},
	"Backspace": {"Backspace", 8, ""}, "Delete": {"Delete", 46, ""}, "Space": {"Space", 32, " "},
	"ArrowLeft": {"ArrowLeft", 37, ""}, "ArrowUp": {"ArrowUp", 38, ""}, "ArrowRight": {"ArrowRight", 39, ""},
	"ArrowDown": {"ArrowDown", 40, ""}, "Home": {"Home", 36, ""}, "End": {"End", 35, ""},
	"PageUp": {"PageUp", 33, ""}, "PageDown": {"PageDown", 34, ""},
}

var modifierBits = map[string]int{"Alt": 1, "Control": 2, "Ctrl": 2, "Meta": 4, "Cmd": 4, "Shift": 8}

// press sends one key, with modifiers: "Enter", "Shift+Tab", "a".
func (p *plugin) press(b *block, combo string) error {
	parts := strings.Split(combo, "+")
	key := parts[len(parts)-1]
	mods := 0
	for _, m := range parts[:len(parts)-1] {
		bit, ok := modifierBits[m]
		if !ok {
			return fmt.Errorf("unknown modifier %q: use Alt, Control, Meta, or Shift", m)
		}
		mods |= bit
	}
	def, named := namedKeys[key]
	if key == "Space" {
		key = " "
	}
	if !named {
		if utf8.RuneCountInString(key) != 1 {
			return fmt.Errorf("unknown key %q: use one character, or a name such as Enter, Tab, Escape, ArrowDown", key)
		}
		def = keyDef{text: key}
		if r := []rune(strings.ToUpper(key))[0]; r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			def.code, def.vk = "Key"+string(r), int(r)
			if r <= '9' {
				def.code = "Digit" + string(r)
			}
		}
	}
	down := map[string]any{"type": "rawKeyDown", "key": key, "code": def.code, "windowsVirtualKeyCode": def.vk,
		"modifiers": mods}
	// A key with text, and no modifier but Shift, types it.
	if def.text != "" && mods&^8 == 0 {
		down["type"], down["text"], down["unmodifiedText"] = "keyDown", def.text, def.text
	}
	if _, err := p.cdp(b, "Input.dispatchKeyEvent", down); err != nil {
		return err
	}
	_, err := p.cdp(b, "Input.dispatchKeyEvent", map[string]any{"type": "keyUp", "key": key, "code": def.code,
		"windowsVirtualKeyCode": def.vk, "modifiers": mods})
	return err
}

// typeText types into whatever has the keyboard, one key at a time, so the
// page sees each key as it would a person's.
func (p *plugin) typeText(b *block, text string) error {
	for _, r := range text {
		var err error
		if r == '\n' {
			err = p.press(b, "Enter")
		} else {
			err = p.press(b, string(r))
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// ---- The rest ---------------------------------------------------------

func (p *plugin) scroll(b *block, dx, dy float64) error {
	var r struct {
		Result struct {
			Value []float64 `json:"value"`
		} `json:"result"`
	}
	if err := p.cdpInto(b, "Runtime.evaluate", map[string]any{"expression": "[innerWidth/2, innerHeight/2]",
		"returnByValue": true}, &r); err != nil || len(r.Result.Value) != 2 {
		return errors.New("the page has no viewport yet")
	}
	_, err := p.cdp(b, "Input.dispatchMouseEvent", map[string]any{"type": "mouseWheel", "x": r.Result.Value[0],
		"y": r.Result.Value[1], "deltaX": dx, "deltaY": dy})
	return err
}

// eval runs a JavaScript expression in the page and returns its value as
// JSON. A promise is awaited.
func (p *plugin) eval(b *block, js string) (json.RawMessage, error) {
	var r struct {
		Result struct {
			Value       json.RawMessage `json:"value"`
			Description string          `json:"description"`
			Type        string          `json:"type"`
		} `json:"result"`
		Exception *struct {
			Text      string `json:"text"`
			Exception struct {
				Description string `json:"description"`
			} `json:"exception"`
		} `json:"exceptionDetails"`
	}
	if err := p.cdpInto(b, "Runtime.evaluate", map[string]any{"expression": js, "returnByValue": true,
		"awaitPromise": true, "userGesture": true, "replMode": true}, &r); err != nil {
		return nil, err
	}
	if x := r.Exception; x != nil {
		msg := x.Exception.Description
		if msg == "" {
			msg = x.Text
		}
		return nil, errors.New(strings.SplitN(msg, "\n", 2)[0])
	}
	if len(r.Result.Value) == 0 {
		if r.Result.Type == "undefined" {
			return json.RawMessage("null"), nil
		}
		v, _ := json.Marshal(r.Result.Description) // a value JSON can't hold, such as a function
		return v, nil
	}
	return r.Result.Value, nil
}

func (p *plugin) screenshot(b *block, path string) error {
	var r struct {
		Data string `json:"data"`
	}
	if err := p.cdpInto(b, "Page.captureScreenshot", map[string]any{"format": "png"}, &r); err != nil {
		return err
	}
	png, err := base64.StdEncoding.DecodeString(r.Data)
	if err != nil {
		return err
	}
	return os.WriteFile(path, png, 0o644)
}

const (
	waitDefault = 5 * time.Second
	waitMax     = 8 * time.Second // under the engine's and Rex's call timeouts
)

// wait waits until the target shows, the text shows, or, with neither, the
// page has loaded.
func (p *plugin) wait(b *block, target string, text *string, timeoutMS int) (time.Duration, error) {
	timeout := waitDefault
	if timeoutMS > 0 {
		timeout = min(time.Duration(timeoutMS)*time.Millisecond, waitMax)
	}
	var check string
	var what string
	switch {
	case target != "" && refPattern.MatchString(target):
		return 0, errors.New("wait takes a CSS selector: a ref is already on the page")
	case target != "":
		sel, _ := json.Marshal(target)
		check = "(() => { const e = document.querySelector(" + string(sel) + "); return !!e && e.getClientRects().length > 0 })()"
		what = target
	case text != nil:
		t, _ := json.Marshal(*text)
		check = "!!document.body && document.body.innerText.includes(" + string(t) + ")"
		what = "the text " + string(t)
	default:
		check = `document.readyState === "complete"`
		what = "the page to load"
	}
	start := time.Now()
	for {
		loading := false
		if target == "" && text == nil {
			b.mu.Lock()
			json.Unmarshal(b.state["loading"], &loading)
			b.mu.Unlock()
		}
		v, err := p.eval(b, check)
		if err == nil && string(v) == "true" && !loading {
			return time.Since(start), nil
		}
		if time.Since(start) > timeout {
			return 0, fmt.Errorf("waited %s for %s", timeout, what)
		}
		time.Sleep(100 * time.Millisecond)
	}
}
