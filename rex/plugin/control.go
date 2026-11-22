package main

// The rex.control.v1 channel. Rex is the client: it sends hello, then requests.
// We answer each request and push events for our blocks.

import (
	"encoding/json"
	"log"
	"sync"
)

type message struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	Seq     *int            `json:"seq,omitempty"`
	Method  string          `json:"method,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Status  int    `json:"status"`
}

func (e *rpcError) Error() string { return e.Message }

func errBadRequest(msg string) *rpcError { return &rpcError{"bad_request", msg, 400} }
func errNotFound(msg string) *rpcError   { return &rpcError{"not_found", msg, 404} }
func errInternal(msg string) *rpcError   { return &rpcError{"internal", msg, 500} }

// method_not_found is the one code Rex reacts to: for block.restore it falls back to block.create.
func errNoMethod(m string) *rpcError {
	return &rpcError{"method_not_found", "rexplugin: no handler for method " + m, 404}
}

// conn is the live control channel. Events go to the latest one.
type conn struct {
	ws *wsConn
}

// Rex rejects a welcome without protocol or a positive limits.max_message_bytes.
var welcome = map[string]any{"type": "welcome", "protocol": "rex.control.v1", "limits": map[string]any{"max_message_bytes": 1 << 20}}

func (c *conn) sendRaw(v any) {
	b, _ := json.Marshal(v)
	if err := c.ws.WriteText(b); err != nil {
		log.Printf("writing: %v", err)
	}
}

func (c *conn) send(m message) {
	b, err := json.Marshal(m)
	if err != nil {
		log.Printf("encoding %s: %v", m.Type, err)
		return
	}
	if err := c.ws.WriteText(b); err != nil {
		log.Printf("writing %s: %v", m.Type, err)
	}
}

func (p *plugin) serve(ws *wsConn) {
	c := &conn{ws: ws}
	p.mu.Lock()
	p.conn = c
	p.mu.Unlock()
	defer func() {
		ws.Close()
		p.mu.Lock()
		if p.conn == c {
			p.conn = nil
		}
		p.mu.Unlock()
	}()

	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		b, err := ws.ReadMessage()
		if err != nil {
			log.Printf("control channel closed: %v", err)
			return
		}
		var m message
		if err := json.Unmarshal(b, &m); err != nil {
			log.Printf("bad control message: %v", err)
			continue
		}
		switch m.Type {
		case "hello":
			c.sendRaw(welcome)
		case "request":
			// Requests run concurrently: block.create waits for a producer to start.
			wg.Add(1)
			go func() {
				defer wg.Done()
				out, rerr := p.handle(m.Method, m.Payload)
				zero := 0
				resp := message{Type: "response", ID: m.ID, Seq: &zero}
				if rerr != nil {
					resp.Error = rerr
				} else if out != nil {
					b, err := json.Marshal(out)
					if err != nil {
						resp.Error = errInternal(err.Error())
					} else {
						resp.Payload = b
					}
				}
				c.send(resp)
			}()
		default:
			log.Printf("ignoring control message type %q", m.Type)
		}
	}
}

// emit sends a block event, as declared in the creator's api.events.
func (p *plugin) emit(blockID, name string, payload any) {
	p.mu.Lock()
	c := p.conn
	p.mu.Unlock()
	if c == nil {
		return
	}
	inner, _ := json.Marshal(map[string]any{"block_id": blockID, "name": name, "payload": payload})
	outer, _ := json.Marshal(map[string]any{"type": "block_event", "payload": json.RawMessage(inner)})
	c.send(message{Type: "event", Payload: outer})
}
