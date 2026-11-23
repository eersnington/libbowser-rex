package main

// End to end: the real plugin binary, started the way Rex starts it, with the
// real bowser-cef engine. The test plays Rex twice: the client that calls the
// plugin's blocks, and the server whose session.set_block_label the plugin
// calls back. Pages are data: URLs; no network.

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

var pluginBin string

func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "rexplugin-test")
	pluginBin = filepath.Join(dir, "rexplugin")
	if out, err := exec.Command("go", "build", "-o", pluginBin, ".").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "building the plugin: %v\n%s", err, out)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// ---- Rex, as the plugin sees it -------------------------------------------

type fakeRex struct {
	t      *testing.T
	plugin *exec.Cmd
	ws     *wsConn

	mu      sync.Mutex
	nextID  int
	replies map[string]chan message
	events  chan map[string]any // block_event payloads
	queue   []map[string]any    // received, not yet matched
	labels  []map[string]string // set_block_label calls, in order
}

func startRex(t *testing.T) *fakeRex {
	engine, _ := filepath.Abs("../../build/bowser-cef.app/Contents/MacOS/bowser-cef")
	if _, err := os.Stat(engine); err != nil {
		t.Skip("no bowser-cef; run make cef")
	}
	// Unix socket paths are short; t.TempDir's are not.
	home, _ := os.MkdirTemp("/tmp", "rx")
	t.Cleanup(func() { os.RemoveAll(home) })
	r := &fakeRex{t: t, replies: map[string]chan message{}, events: make(chan map[string]any, 256)}

	// The server side: a runtime.json naming us, and a control socket.
	sock := filepath.Join(home, "s.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go http.Serve(ln, http.HandlerFunc(r.serveServer))
	rt := filepath.Join(home, "Library/Application Support/rex/servers/test")
	os.MkdirAll(rt, 0o755)
	info, _ := json.Marshal(map[string]any{"endpoint": "unix://" + url.PathEscape(sock), "pid": os.Getpid()})
	os.WriteFile(filepath.Join(rt, "runtime.json"), info, 0o644)

	pr, pw, _ := os.Pipe()
	cmd := exec.Command(pluginBin)
	cmd.ExtraFiles = []*os.File{pw} // fd 3
	cmd.Env = append(os.Environ(), "REX_BLOCKSERVER_INFO_FD=3", "HOME="+home, "BOWSER_ENGINE="+engine,
		"REXPLUGIN_LOG="+filepath.Join(home, "plugin.log"))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pw.Close()
	r.plugin = cmd
	t.Cleanup(func() {
		cmd.Process.Signal(syscall.SIGINT) // as Rex does on shutdown; the plugin stops the engine
		cmd.Wait()
		if t.Failed() {
			log, _ := os.ReadFile(filepath.Join(home, "plugin.log"))
			t.Logf("plugin log:\n%s", log)
		}
	})
	var conn struct {
		Addr string `json:"addr"`
	}
	if err := json.NewDecoder(pr).Decode(&conn); err != nil {
		t.Fatalf("connection info: %v", err)
	}
	c, err := net.Dial("unix", conn.Addr)
	if err != nil {
		t.Fatal(err)
	}
	if r.ws, err = wsClient(c, "rexplugin", "/api/control", "rex.control.v1"); err != nil {
		t.Fatal(err)
	}
	r.ws.WriteText([]byte(`{"type":"hello","api_revision":18}`))
	go r.read()
	return r
}

func (r *fakeRex) read() {
	for {
		raw, err := r.ws.ReadMessage()
		if err != nil {
			return
		}
		var m message
		json.Unmarshal(raw, &m)
		switch m.Type {
		case "response":
			r.mu.Lock()
			ch := r.replies[m.ID]
			r.mu.Unlock()
			if ch != nil {
				ch <- m
			}
		case "event":
			var outer struct {
				Type    string         `json:"type"`
				Payload map[string]any `json:"payload"`
			}
			json.Unmarshal(m.Payload, &outer)
			if outer.Type == "block_event" {
				r.events <- outer.Payload
			}
		}
	}
}

// serveServer is the Rex server's control channel, for the plugin's labels.
func (r *fakeRex) serveServer(w http.ResponseWriter, req *http.Request) {
	ws, err := wsUpgrade(w, req, "rex.control.v1")
	if err != nil {
		return
	}
	attached := map[string]bool{}
	for {
		raw, err := ws.ReadMessage()
		if err != nil {
			return
		}
		var m message
		json.Unmarshal(raw, &m)
		var in map[string]string
		json.Unmarshal(m.Payload, &in)
		resp := message{Type: "response", ID: m.ID, Payload: json.RawMessage(`{}`)}
		switch {
		case m.Type == "hello":
			ws.WriteText([]byte(`{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576}}`))
			continue
		case m.Method == "session.attach":
			attached[in["session_id"]] = true
		case m.Method == "session.set_block_label" && attached[in["session_id"]]:
			r.mu.Lock()
			r.labels = append(r.labels, in)
			r.mu.Unlock()
		default: // what the real server says
			resp.Payload = nil
			resp.Error = &rpcError{"bad_request", "stream is not attached to session " + in["session_id"], 400}
		}
		out, _ := json.Marshal(resp)
		ws.WriteText(out)
	}
}

func (r *fakeRex) call(method string, payload any) (json.RawMessage, *rpcError) {
	r.mu.Lock()
	r.nextID++
	id := fmt.Sprintf("control-%d", r.nextID)
	ch := make(chan message, 1)
	r.replies[id] = ch
	r.mu.Unlock()
	b, _ := json.Marshal(payload)
	out, _ := json.Marshal(message{Type: "request", ID: id, Method: method, Payload: b})
	r.ws.WriteText(out)
	select {
	case m := <-ch:
		return m.Payload, m.Error
	case <-time.After(30 * time.Second):
		r.t.Fatalf("%s: no response", method)
		return nil, nil
	}
}

func (r *fakeRex) create(sessionBlock, page string) string {
	return r.createWith(sessionBlock, map[string]any{"url": page, "transport": "iosurface"})
}

func (r *fakeRex) createWith(sessionBlock string, options map[string]any) string {
	out, err := r.call("block.create", map[string]any{
		"flavor": flavorName, "session_id": "session:test", "block_id": sessionBlock, "options": options,
	})
	if err != nil {
		r.t.Fatalf("block.create: %v", err)
	}
	var b struct {
		BlockID string `json:"block_id"`
	}
	json.Unmarshal(out, &b)
	return b.BlockID
}

func (r *fakeRex) method(block, name string, args any) (map[string]any, *rpcError) {
	if args == nil {
		args = map[string]any{}
	}
	out, err := r.call("block.method", map[string]any{"block_id": block, "method": name, "args": args})
	var m map[string]any
	json.Unmarshal(out, &m)
	return m, err
}

// event waits for a block event that matches. It and the block's earlier
// events are used up; other blocks' events wait for their own calls.
func (r *fakeRex) event(block, name string, match func(map[string]any) bool) map[string]any {
	deadline := time.After(15 * time.Second)
	for {
		for i, e := range r.queue {
			p, _ := e["payload"].(map[string]any)
			if e["block_id"] != block || e["name"] != name || (match != nil && !match(p)) {
				continue
			}
			rest := r.queue[:0:0]
			for j, o := range r.queue {
				if j > i || o["block_id"] != block {
					rest = append(rest, o)
				}
			}
			r.queue = rest
			return p
		}
		select {
		case e := <-r.events:
			r.queue = append(r.queue, e)
		case <-deadline:
			r.t.Fatalf("no %s event for %s", name, block)
			return nil
		}
	}
}

func (r *fakeRex) labelsFor(sessionBlock string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var got []string
	for _, l := range r.labels {
		if l["block_id"] == sessionBlock {
			got = append(got, l["label"])
		}
	}
	return got
}

func page(title string) string { return "data:text/html," + url.PathEscape("<title>"+title+"</title>") }

func titled(title string) func(map[string]any) bool {
	return func(s map[string]any) bool { return s["title"] == title && s["loading"] == false }
}

// ---- Tests ----------------------------------------------------------------

func TestBlocksShareOneEngineAndStayApart(t *testing.T) {
	r := startRex(t)
	a := r.create("block:a", page("Alpha"))
	b := r.createWith("block:b", map[string]any{"url": page("Beta")}) // the defaults
	r.event(a, "state", titled("Alpha"))
	r.event(b, "state", titled("Beta"))
	sa, _ := r.method(a, "state", nil)
	sb, _ := r.method(b, "state", nil)
	if sa["engine_pid"] == 0.0 || sa["engine_pid"] != sb["engine_pid"] {
		t.Fatalf("both blocks are surfaces of one engine: %v and %v", sa["engine_pid"], sb["engine_pid"])
	}
	if sb["transport"] != "calayerhost" || sb["mode"] != "windowed" || sa["mode"] != "osr" {
		t.Fatalf("a block is zero copy by default, and OSR on iosurface: %v/%v and %v/%v", sb["transport"],
			sb["mode"], sa["transport"], sa["mode"])
	}
	c := r.createWith("block:c", map[string]any{"url": page("Gamma"), "mode": "osr"})
	r.event(c, "state", titled("Gamma"))
	if sc, _ := r.method(c, "state", nil); sc["transport"] != "calayerhost" || sc["mode"] != "osr" {
		t.Fatalf("a block can ask for OSR on calayerhost: %v/%v", sc["transport"], sc["mode"])
	}
	if tk, err := r.method(a, "ticket", nil); err != nil || !strings.HasPrefix(tk["ticket"].(string), "bowser3:") {
		t.Fatalf("ticket: %v %v", tk, err)
	}

	long := strings.TrimSpace(strings.Repeat("Gamma ", 10)) // 59 runes
	if _, err := r.method(a, "navigate", map[string]any{"url": page(long)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}
	st := r.event(a, "state", titled(long))
	if st["can_go_back"] != true {
		t.Fatalf("navigating adds history: %v", st)
	}
	if _, err := r.method(a, "back", nil); err != nil {
		t.Fatalf("back: %v", err)
	}
	r.event(a, "state", titled("Alpha"))
	if _, err := r.method(a, "navigate", map[string]any{}); err == nil {
		t.Fatal("navigate without a url is refused")
	}

	time.Sleep(300 * time.Millisecond) // labels go through their own connection
	want := []string{"Alpha", long[:labelMax-1] + "…", "Alpha"}
	if got := r.labelsFor("block:a"); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("a is labeled once per title, truncated:\n want %q\n got  %q", want, got)
	}
	if got := r.labelsFor("block:b"); fmt.Sprint(got) != fmt.Sprint([]string{"Beta"}) {
		t.Fatalf("b keeps its own label, got %q", got)
	}
	if sb, _ := r.method(b, "state", nil); sb["title"] != "Beta" || sb["can_go_back"] != false {
		t.Fatalf("a's navigation never touched b: %v", sb)
	}
}

func TestEngineDeathErrorsEveryBlockAndRecovers(t *testing.T) {
	r := startRex(t)
	a := r.create("block:a", page("Alpha"))
	b := r.create("block:b", page("Beta"))
	r.event(a, "state", titled("Alpha"))
	r.event(b, "state", titled("Beta"))
	before, _ := r.method(a, "state", nil)
	pid := int(before["engine_pid"].(float64))

	syscall.Kill(pid, syscall.SIGKILL)
	r.event(a, "error", nil)
	r.event(b, "error", nil)
	if s, _ := r.method(b, "state", nil); s["engine_pid"] != 0.0 {
		t.Fatalf("a block without a surface says so: %v", s)
	}

	tk, err := r.method(a, "ticket", nil)
	if err != nil || tk["ticket"] == "" {
		t.Fatalf("the next call starts a new engine: %v %v", tk, err)
	}
	r.event(a, "state", titled("Alpha")) // reopened at its last page
	after, _ := r.method(a, "state", nil)
	if after["engine_pid"] == 0.0 || after["engine_pid"] == before["engine_pid"] {
		t.Fatalf("in a new engine: %v, was %v", after["engine_pid"], pid)
	}
}

// Closing the last block keeps the engine, so the next block doesn't wait
// most of a second for a new one.
func TestTheEngineOutlivesTheLastBlock(t *testing.T) {
	r := startRex(t)
	a := r.create("block:a", page("Alpha"))
	r.event(a, "state", titled("Alpha"))
	before, _ := r.method(a, "state", nil)
	if _, err := r.call("block.close", map[string]any{"block_id": a}); err != nil {
		t.Fatalf("block.close: %v", err)
	}
	b := r.create("block:b", page("Beta"))
	r.event(b, "state", titled("Beta"))
	after, _ := r.method(b, "state", nil)
	if after["engine_pid"] != before["engine_pid"] {
		t.Fatalf("the next block uses the same engine: %v, was %v", after["engine_pid"], before["engine_pid"])
	}
}
