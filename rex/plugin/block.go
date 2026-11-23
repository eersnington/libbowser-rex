package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"unicode/utf8"
)

const (
	creatorName = "dev.libbowser"
	flavorName  = "dev.libbowser.browser"
	labelMax    = 40 // runes of the page title shown as the block's label
)

type plugin struct {
	mu     sync.Mutex
	conn   *conn
	blocks map[string]*block // by hosted block ID

	// engineMu serializes starting and stopping the engine. Take it before mu.
	engineMu sync.Mutex
	eng      *engine // nil until a block needs it, and after it exits

	rex *rexClient
}

// A browser block is one surface in the shared engine. The surface is gone
// when the engine exits; the block gets an error event, and its next method
// call opens a new surface, in a new engine, at the block's last URL.
type block struct {
	id             string // hosted
	sessionID      string
	sessionBlockID string
	transport      string

	// opening serializes opening the surface. It is held across a call to
	// the engine, so it must never be what the engine's event reader waits on.
	opening sync.Mutex
	mu      sync.Mutex // guards the fields below; never held across a call
	eng     *engine
	surface string
	url     string
	state   engineEvent // the newest state event
	label   string      // the label we last set
	closed  bool
}

func newPlugin() *plugin { return &plugin{blocks: map[string]*block{}, rex: newRexClient()} }

func (p *plugin) handle(method string, in json.RawMessage) (any, *rpcError) {
	switch method {
	case "block_creator.list":
		return creatorList, nil
	case "block.create":
		return p.create(in)
	case "block.close":
		return p.close(in)
	case "block.method":
		return p.method(in)
	case "block.event":
		// Session events (focus, client_connected, ...). We need none of them.
		return nil, nil
	default:
		// Includes block.snapshot and block.restore: Rex then recreates the block
		// from its saved flavor and options with block.create.
		return nil, errNoMethod(method)
	}
}

type createInput struct {
	Flavor    string          `json:"flavor"`
	SessionID string          `json:"session_id"`
	BlockID   string          `json:"block_id"`
	Options   json.RawMessage `json:"options"` // absent when the caller gives none
}

type browserOptions struct {
	URL       string `json:"url"`
	Transport string `json:"transport"`
}

// decodeStrict fills v from raw, refusing unknown keys: Rex checks neither
// options nor args against their schemas.
func decodeStrict(raw json.RawMessage, v any) error {
	if len(raw) == 0 {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func (p *plugin) create(raw json.RawMessage) (any, *rpcError) {
	var in createInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, errBadRequest("decoding block.create: " + err.Error())
	}
	if in.Flavor != flavorName {
		return nil, errBadRequest(fmt.Sprintf("unknown flavor %q", in.Flavor))
	}
	var opts browserOptions
	if err := decodeStrict(in.Options, &opts); err != nil {
		return nil, errBadRequest("options: " + err.Error())
	}
	t := opts.Transport
	if t == "" {
		t = "calayerhost"
	}
	if t != "calayerhost" && t != "iosurface" {
		return nil, errBadRequest(fmt.Sprintf("transport %q: want calayerhost or iosurface", t))
	}
	url := opts.URL
	if url == "" {
		url = "about:blank"
	}
	b := &block{id: newBlockID(), sessionID: in.SessionID, sessionBlockID: in.BlockID, transport: t, url: url}
	// Listed first, so its first state event finds it.
	p.mu.Lock()
	p.blocks[b.id] = b
	p.mu.Unlock()
	// Open now, so the page loads and its title labels the block before
	// anyone attaches.
	if _, _, err := p.surface(b); err != nil {
		p.mu.Lock()
		delete(p.blocks, b.id)
		p.mu.Unlock()
		return nil, errInternal(err.Error())
	}
	log.Printf("%s: surface %s for session block %s", b.id, b.surface, in.BlockID)
	return map[string]string{"block_id": b.id}, nil
}

// running returns the live engine, starting one if there is none.
func (p *plugin) running() (*engine, error) {
	p.engineMu.Lock()
	defer p.engineMu.Unlock()
	if p.eng != nil && p.eng.alive() {
		return p.eng, nil
	}
	e, err := startEngine(p.onEngineEvent)
	if err != nil {
		return nil, err
	}
	p.eng = e
	go func() {
		<-e.exited
		p.engineExited(e)
	}()
	return e, nil
}

// surface returns the block's surface, opening one if it has none.
func (p *plugin) surface(b *block) (*engine, string, error) {
	e, err := p.running()
	if err != nil {
		return nil, "", err
	}
	b.opening.Lock()
	defer b.opening.Unlock()
	b.mu.Lock()
	closed, have, sid, url := b.closed, b.eng == e && b.surface != "", b.surface, b.url
	b.mu.Unlock()
	if closed {
		return nil, "", fmt.Errorf("block %s is closed", b.id)
	}
	if have {
		return e, sid, nil
	}
	r, err := e.call(map[string]any{"cmd": "open", "url": url, "transport": b.transport})
	if err != nil {
		return nil, "", err
	}
	sid = r.str("surface")
	b.mu.Lock()
	b.eng, b.surface, b.state = e, sid, nil
	b.mu.Unlock()
	return e, sid, nil
}

func (p *plugin) blockFor(e *engine, surface string) *block {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, b := range p.blocks {
		b.mu.Lock()
		match := b.eng == e && b.surface == surface
		b.mu.Unlock()
		if match {
			return b
		}
	}
	return nil
}

func (p *plugin) onEngineEvent(e *engine, ev engineEvent) {
	b := p.blockFor(e, ev.str("surface"))
	if b == nil {
		return // the open's reply is still on its way; state comes again
	}
	switch ev.str("event") {
	case "state":
		delete(ev, "event")
		delete(ev, "surface")
		b.mu.Lock()
		b.state = ev
		if u := ev.str("url"); u != "" {
			b.url = u
		}
		label := truncate(ev.str("title"), labelMax)
		relabel := label != "" && label != b.label
		if relabel {
			b.label = label
		}
		b.mu.Unlock()
		p.emit(b.id, "state", ev)
		if relabel {
			p.rex.setLabel(b.sessionID, b.sessionBlockID, label)
		}
	case "attached":
		var attached bool
		json.Unmarshal(ev["attached"], &attached)
		name := "host_detached"
		if attached {
			name = "host_attached"
		}
		p.emit(b.id, name, map[string]any{})
	case "closed":
		b.mu.Lock()
		b.eng, b.surface = nil, ""
		b.mu.Unlock()
		p.emit(b.id, "error", map[string]any{"message": "the page closed itself"})
	}
}

// engineExited tells every block that had a surface in e.
func (p *plugin) engineExited(e *engine) {
	log.Printf("engine %d: %s", e.cmd.Process.Pid, e.status)
	p.engineMu.Lock()
	if p.eng == e {
		p.eng = nil
	}
	p.engineMu.Unlock()
	p.mu.Lock()
	var lost []*block
	for _, b := range p.blocks {
		b.mu.Lock()
		if b.eng == e {
			b.eng, b.surface = nil, ""
			if !b.closed {
				lost = append(lost, b)
			}
		}
		b.mu.Unlock()
	}
	p.mu.Unlock()
	for _, b := range lost {
		p.emit(b.id, "error", map[string]any{
			"message": "the browser engine exited (" + e.status + "); the next method call reopens the page",
		})
	}
}

func (p *plugin) close(raw json.RawMessage) (any, *rpcError) {
	var in struct {
		BlockID string `json:"block_id"`
	}
	json.Unmarshal(raw, &in)
	p.mu.Lock()
	b := p.blocks[in.BlockID]
	delete(p.blocks, in.BlockID)
	p.mu.Unlock()
	if b == nil {
		return nil, errNotFound("no block " + in.BlockID)
	}
	b.mu.Lock()
	b.closed = true
	e, sid := b.eng, b.surface
	b.mu.Unlock()
	if e != nil && sid != "" {
		e.call(map[string]any{"cmd": "close", "surface": sid})
	}
	p.stopEngineIfIdle()
	log.Printf("%s: closed", b.id)
	return nil, nil
}

// An engine with no blocks still holds a few hundred MB; the next block
// starts a new one in about a second.
func (p *plugin) stopEngineIfIdle() {
	p.engineMu.Lock()
	defer p.engineMu.Unlock()
	p.mu.Lock()
	idle := len(p.blocks) == 0
	p.mu.Unlock()
	if idle && p.eng != nil {
		p.eng.stop()
		p.eng = nil
	}
}

func (p *plugin) closeAll() {
	p.mu.Lock()
	for id, b := range p.blocks {
		b.mu.Lock()
		b.closed = true
		b.mu.Unlock()
		delete(p.blocks, id)
	}
	p.mu.Unlock()
	p.stopEngineIfIdle()
}

// Methods that send the browser message of the same name, with no body.
var plainMessages = map[string]bool{"back": true, "forward": true, "reload": true, "stop": true}

func (p *plugin) method(raw json.RawMessage) (any, *rpcError) {
	var in struct {
		BlockID string          `json:"block_id"`
		Method  string          `json:"method"`
		Args    json.RawMessage `json:"args"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, errBadRequest("decoding block.method: " + err.Error())
	}
	p.mu.Lock()
	b := p.blocks[in.BlockID]
	p.mu.Unlock()
	if b == nil {
		return nil, errNotFound("no block " + in.BlockID)
	}

	switch {
	case in.Method == "ticket":
		if err := decodeStrict(in.Args, &struct{}{}); err != nil {
			return nil, errBadRequest("ticket args: " + err.Error())
		}
		e, sid, err := p.surface(b)
		if err != nil {
			return nil, errInternal(err.Error())
		}
		r, err := e.call(map[string]any{"cmd": "ticket", "surface": sid})
		if err != nil {
			return nil, errInternal(err.Error())
		}
		return map[string]any{"ticket": r.str("ticket")}, nil
	case in.Method == "state":
		if err := decodeStrict(in.Args, &struct{}{}); err != nil {
			return nil, errBadRequest("state args: " + err.Error())
		}
		return b.describe(), nil
	case in.Method == "navigate":
		var args struct {
			URL string `json:"url"`
		}
		if err := decodeStrict(in.Args, &args); err != nil || args.URL == "" {
			return nil, errBadRequest(`navigate args: want {"url": "..."}`)
		}
		return nil, p.send(b, "navigate", map[string]any{"url": args.URL})
	case plainMessages[in.Method]:
		if err := decodeStrict(in.Args, &struct{}{}); err != nil {
			return nil, errBadRequest(in.Method + " args: " + err.Error())
		}
		return nil, p.send(b, in.Method, nil)
	}
	return nil, errNoMethod(in.Method)
}

func (p *plugin) send(b *block, name string, body map[string]any) *rpcError {
	e, sid, err := p.surface(b)
	if err != nil {
		return errInternal(err.Error())
	}
	cmd := map[string]any{"cmd": "message", "surface": sid, "name": name}
	if body != nil {
		cmd["body"] = body
	}
	if _, err := e.call(cmd); err != nil {
		return errBadRequest(err.Error())
	}
	return nil
}

// describe is the state method's answer: the newest state, plus the block's own.
func (b *block) describe() map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]any{"url": b.url, "title": "", "loading": false, "progress": 0.0, "can_go_back": false,
		"can_go_forward": false}
	for k, v := range b.state {
		out[k] = v
	}
	out["transport"] = b.transport
	pid := 0
	if b.eng != nil && b.eng.alive() && b.surface != "" {
		pid = b.eng.cmd.Process.Pid
	}
	out["engine_pid"] = pid
	return out
}

func truncate(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

func newBlockID() string {
	var u [16]byte
	rand.Read(u[:])
	u[6] = u[6]&0x0f | 0x40 // version 4
	u[8] = u[8]&0x3f | 0x80
	return fmt.Sprintf("block:%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}
