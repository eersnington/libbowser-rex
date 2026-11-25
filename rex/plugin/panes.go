package main

// The browser as part of Rex: links that open a new window open a new pane
// beside this one, and Send to Agent pastes what was clicked into the agent
// running in a terminal pane beside it.

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"path"
	"strings"
)

const terminalCreator = "com.superlogical.terminal"

// Programs Send to Agent pastes into, by the name they were run as. Only
// agents: a shell could run a pasted line.
var agentNames = map[string]bool{"claude": true, "codex": true, "gemini": true, "cursor-agent": true, "opencode": true,
	"amp": true, "aider": true, "goose": true, "pi": true, "copilot": true, "crush": true, "droid": true, "qwen": true}

// openPane opens url in a new browser pane beside b. If Rex can't, b loads it.
func (p *plugin) openPane(b *block, url string, focus bool) {
	err := inSession(b.sessionID, func(call func(string, any) (json.RawMessage, error)) error {
		_, err := call("session.new_split", map[string]any{"session_id": b.sessionID, "anchor_id": b.sessionBlockID,
			"direction": "horizontal", "side": "after", "focus": focus,
			"layout": map[string]any{"block": map[string]any{"flavor": flavorName, "options": map[string]any{"url": url}}}})
		return err
	})
	if err != nil {
		log.Printf("%s: opening %s in a new pane: %v; opening it here", b.id, url, err)
		p.send(b, "navigate", map[string]any{"url": url})
	}
}

// describeAt says what the page shows at a point, for an agent: the element
// a person would mean (the link or button around what they clicked), a
// selector for it, and its HTML.
const describeElement = `function() {
	const el = this.closest("a,button,input,select,textarea,label,summary,[role],[onclick]") || this;
	const path = [];
	for (let e = el; e && e.nodeType === 1 && path.length < 6; e = e.parentElement) {
		if (e.id) { path.unshift("#" + CSS.escape(e.id)); break; }
		let s = e.localName + [...e.classList].slice(0, 2).map(c => "." + CSS.escape(c)).join("");
		const same = e.parentElement ? [...e.parentElement.children].filter(c => c.localName === e.localName) : [];
		if (same.length > 1) s += ":nth-of-type(" + (same.indexOf(e) + 1) + ")";
		path.unshift(s);
		if (e === document.body) break;
	}
	const html = el.outerHTML;
	return { selector: path.join(" > "), html: html.length > 1500 ? html.slice(0, 1500) + "…" : html };
}`

func (p *plugin) describeAt(b *block, x, y float64) (selector, html string, err error) {
	var at struct {
		BackendID int64 `json:"backendNodeId"`
	}
	if err := p.cdpInto(b, "DOM.getNodeForLocation", map[string]any{"x": int(x), "y": int(y)}, &at); err != nil {
		return "", "", err
	}
	var node struct {
		Object struct {
			ObjectID string `json:"objectId"`
		} `json:"object"`
	}
	if err := p.cdpInto(b, "DOM.resolveNode", map[string]any{"backendNodeId": at.BackendID}, &node); err != nil {
		return "", "", err
	}
	var r struct {
		Result struct {
			Value struct {
				Selector string `json:"selector"`
				HTML     string `json:"html"`
			} `json:"value"`
		} `json:"result"`
	}
	if err := p.cdpInto(b, "Runtime.callFunctionOn", map[string]any{"objectId": node.Object.ObjectID,
		"functionDeclaration": describeElement, "returnByValue": true}, &r); err != nil {
		return "", "", err
	}
	return r.Result.Value.Selector, r.Result.Value.HTML, nil
}

// sendToAgent pastes what the person right-clicked into the agent beside b.
func (p *plugin) sendToAgent(b *block, x, y float64, selection string) {
	if err := p.trySendToAgent(b, x, y, selection); err != nil {
		log.Printf("%s: send to agent: %v", b.id, err)
		p.emit(b.id, "error", map[string]any{"message": "Send to Agent: " + err.Error()})
	}
}

func (p *plugin) trySendToAgent(b *block, x, y float64, selection string) error {
	b.mu.Lock()
	title, url := b.state.str("title"), b.url
	b.mu.Unlock()
	var msg strings.Builder
	fmt.Fprintf(&msg, "From the browser pane: %s (%s)\n", title, url)
	if sel := strings.TrimSpace(selection); sel != "" {
		for _, line := range strings.Split(sel, "\n") {
			msg.WriteString("> " + line + "\n")
		}
	}
	if selector, html, err := p.describeAt(b, x, y); err == nil && html != "" {
		fmt.Fprintf(&msg, "Element: %s\n%s\n", selector, html)
	} else if selection == "" {
		return fmt.Errorf("nothing to send: %v", err)
	}

	return inSession(b.sessionID, func(call func(string, any) (json.RawMessage, error)) error {
		agent, err := findAgent(call, b)
		if err != nil {
			return err
		}
		if _, err := call("block.event", map[string]any{"session_id": b.sessionID, "block_id": agent,
			"event": map[string]any{"type": "paste", "payload": map[string]any{"text": msg.String()}}}); err != nil {
			return err
		}
		_, err = call("session.focus_block", map[string]any{"session_id": b.sessionID, "block_id": agent})
		return err
	})
}

// findAgent finds a terminal running an agent: in b's window first, then
// anywhere in the session.
func findAgent(call func(string, any) (json.RawMessage, error), b *block) (string, error) {
	raw, err := call("session.view", map[string]any{"session_id": b.sessionID})
	if err != nil {
		return "", err
	}
	var view struct {
		Windows []struct {
			Layers []struct {
				Blocks []struct {
					ID      string `json:"block_id"`
					Creator string `json:"creator_name"`
				} `json:"blocks"`
			} `json:"layers"`
		} `json:"windows"`
	}
	if err := json.Unmarshal(raw, &view); err != nil {
		return "", err
	}
	var near, far []string
	for _, w := range view.Windows {
		var terminals []string
		here := false
		for _, l := range w.Layers {
			for _, blk := range l.Blocks {
				here = here || blk.ID == b.sessionBlockID
				if blk.Creator == terminalCreator {
					terminals = append(terminals, blk.ID)
				}
			}
		}
		if here {
			near = append(near, terminals...)
		} else {
			far = append(far, terminals...)
		}
	}
	for _, id := range append(near, far...) {
		raw, err := call("block.method", map[string]any{"session_id": b.sessionID, "block_id": id, "method": "process"})
		if err != nil {
			continue
		}
		var proc struct {
			Foreground struct {
				Argv0 string `json:"argv0"`
				Name  string `json:"name"`
			} `json:"foreground"`
		}
		json.Unmarshal(raw, &proc)
		if agentNames[path.Base(proc.Foreground.Argv0)] || agentNames[proc.Foreground.Name] {
			return id, nil
		}
	}
	return "", errors.New("no agent runs in a terminal pane of this session")
}
