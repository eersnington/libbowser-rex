package main

// A client of the Rex server that started us, on the same rex.control.v1
// channel the CLI uses. It only relabels blocks.
//
// We find the server through its runtime.json and talk to it only if the
// socket's peer is our parent process. A plugin inherits REX_SERVER from
// whoever started the server, which can be a different server entirely (a
// dev server started from a shell inside the user's Rex).

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const rexCallTimeout = 5 * time.Second

type labelRequest struct{ session, block, label string }

type rexClient struct {
	requests chan labelRequest
}

func newRexClient() *rexClient {
	r := &rexClient{requests: make(chan labelRequest, 64)}
	go r.run()
	return r
}

// setLabel never blocks; a backlog this long means the server is stuck.
func (r *rexClient) setLabel(session, block, label string) {
	if session == "" || block == "" {
		return
	}
	select {
	case r.requests <- labelRequest{session, block, label}:
	default:
		log.Printf("rex: dropping label %q for %s", label, block)
	}
}

// One connection per change, as the CLI does: a connection attached to a
// session gets its events, which nothing here would read.
func (r *rexClient) run() {
	for req := range r.requests {
		// Only the newest label of each block matters.
		latest := map[string]labelRequest{req.block: req}
		order := []string{req.block}
		for more := true; more; {
			select {
			case next := <-r.requests:
				if _, seen := latest[next.block]; !seen {
					order = append(order, next.block)
				}
				latest[next.block] = next
			default:
				more = false
			}
		}
		for _, block := range order {
			if err := relabel(latest[block]); err != nil {
				log.Printf("rex: labeling %s: %v", block, err)
			}
		}
	}
}

func relabel(req labelRequest) error {
	ws, err := dialServer()
	if err != nil {
		return err
	}
	defer ws.Close()
	attach, _ := json.Marshal(map[string]string{"session_id": req.session})
	if err := call(ws, "bowser-1", "session.attach", attach); err != nil {
		return err
	}
	label, _ := json.Marshal(map[string]string{"session_id": req.session, "block_id": req.block, "label": req.label})
	return call(ws, "bowser-2", "session.set_block_label", label)
}

func call(ws *wsConn, id, method string, payload json.RawMessage) error {
	b, _ := json.Marshal(message{Type: "request", ID: id, Method: method, Payload: payload})
	if err := ws.WriteText(b); err != nil {
		return err
	}
	ws.conn.SetReadDeadline(time.Now().Add(rexCallTimeout))
	defer ws.conn.SetReadDeadline(time.Time{})
	for {
		raw, err := ws.ReadMessage()
		if err != nil {
			return err
		}
		var m message
		if json.Unmarshal(raw, &m) != nil || m.Type != "response" || m.ID != id {
			continue // events
		}
		if m.Error != nil {
			return m.Error
		}
		return nil
	}
}

// dialServer connects to our parent's control socket and says hello.
func dialServer() (*wsConn, error) {
	path, err := serverSocket()
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("unix", path, rexCallTimeout)
	if err != nil {
		return nil, err
	}
	if pid, err := peerPID(conn); err != nil || pid != os.Getppid() {
		conn.Close()
		return nil, fmt.Errorf("%s belongs to pid %d, not our server %d", path, pid, os.Getppid())
	}
	ws, err := wsClient(conn, "rex", "/api/control", "rex.control.v1")
	if err != nil {
		conn.Close()
		return nil, err
	}
	hello, _ := json.Marshal(map[string]any{"type": "hello", "api_revision": 18})
	ws.WriteText(hello)
	ws.conn.SetReadDeadline(time.Now().Add(rexCallTimeout))
	defer ws.conn.SetReadDeadline(time.Time{})
	for {
		raw, err := ws.ReadMessage()
		if err != nil {
			ws.Close()
			return nil, fmt.Errorf("handshake: %w", err)
		}
		var m message
		json.Unmarshal(raw, &m)
		if m.Type == "welcome" {
			return ws, nil
		}
	}
}

// serverSocket finds the socket of the Rex server that started us: the
// runtime.json it writes under $HOME names its pid and endpoint.
func serverSocket() (string, error) {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, "Library/Application Support/rex/servers/*/runtime.json"))
	for _, f := range files {
		var rt struct {
			Endpoint string `json:"endpoint"`
			PID      int    `json:"pid"`
		}
		if b, err := os.ReadFile(f); err != nil || json.Unmarshal(b, &rt) != nil || rt.PID != os.Getppid() {
			continue
		}
		if path, ok := strings.CutPrefix(rt.Endpoint, "unix://"); ok {
			return url.PathUnescape(path)
		}
	}
	return "", errors.New("no runtime.json for our server, so blocks keep their labels")
}

// LOCAL_PEERPID, from <sys/un.h>: the pid at the other end of a Unix socket.
const solLocal, localPeerPID = 0, 2

func peerPID(conn net.Conn) (int, error) {
	raw, err := conn.(*net.UnixConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var gerr error
	raw.Control(func(fd uintptr) { pid, gerr = syscall.GetsockoptInt(int(fd), solLocal, localPeerPID) })
	return pid, gerr
}
