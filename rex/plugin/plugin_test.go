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
	splits  []map[string]any    // session.new_split calls, in order
	refuse  bool                // refuse new splits, as a server with no room would
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
		case m.Method == "session.new_split" && attached[in["session_id"]]:
			var split map[string]any
			json.Unmarshal(m.Payload, &split)
			r.mu.Lock()
			r.splits = append(r.splits, split)
			refuse := r.refuse
			r.mu.Unlock()
			resp.Payload = json.RawMessage(`{"block_ids":["block:new"]}`)
			if refuse {
				resp.Payload, resp.Error = nil, &rpcError{"conflict", "no room", 409}
			}
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

func TestTraceRecordsThePagesFramesOnTheReportedClock(t *testing.T) {
	r := startRex(t)
	anim := "data:text/html," + url.PathEscape(`<title>Anim</title><div id=b style="width:50px;height:50px;background:red"></div>`+
		`<script>function f(t){b.style.marginLeft=(t/5%300)+"px";requestAnimationFrame(f)}requestAnimationFrame(f)</script>`)
	// A windowed tab renders without a host for its first 3 s, as if Rex
	// were about to mount it; an OSR tab with no host draws nothing.
	b := r.createWith("block:a", map[string]any{"url": anim, "transport": "calayerhost"})
	r.event(b, "state", titled("Anim"))
	out := filepath.Join(t.TempDir(), "trace.json")

	if _, err := r.method(b, "trace_stop", map[string]any{"path": out}); err == nil {
		t.Fatal("stopping a trace that never started is an error")
	}
	clock, err := r.method(b, "trace_start", nil)
	if err != nil {
		t.Fatalf("trace_start: %v", err)
	}
	time.Sleep(time.Second)
	if _, err := r.method(b, "trace_stop", map[string]any{"path": out}); err != nil {
		t.Fatalf("trace_stop: %v", err)
	}
	var data []byte
	for deadline := time.Now().Add(15 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		var readErr error
		if data, readErr = os.ReadFile(out); readErr == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the engine writes the trace to the path it was given")
		}
	}
	var trace struct {
		TraceEvents []struct {
			Name string          `json:"name"`
			Ph   string          `json:"ph"`
			Ts   float64         `json:"ts"`
			Args json.RawMessage `json:"args"`
		} `json:"traceEvents"`
	}
	if jsonErr := json.Unmarshal(data, &trace); jsonErr != nil {
		t.Fatalf("the trace is complete JSON: %v", jsonErr)
	}
	// perf-trace.sh lines the trace up with other processes' mach time as is.
	start := clock["mach_us"].(float64)
	presented, reporters, lo, hi := 0, 0, 0.0, 0.0
	for _, e := range trace.TraceEvents {
		if e.Name == "PipelineReporter" && e.Ph == "b" {
			reporters++
			if lo == 0 || e.Ts < lo {
				lo = e.Ts
			}
			hi = max(hi, e.Ts)
		}
		if e.Name == "PipelineReporter" && e.Ph == "b" && strings.Contains(string(e.Args), "STATE_PRESENTED") &&
			e.Ts >= start && e.Ts <= start+3e6 {
			presented++
		}
	}
	if presented < 20 {
		t.Fatalf("1 s of an animating page shows at least 20 presented frames, in mach time, got %d "+
			"(%d frames from %.0f to %.0f µs; trace started at %.0f)", presented, reporters, lo, hi, start)
	}
	// A recorder throws traces away by stopping without a path; the trace
	// must end, or it could never start again.
	if _, err := r.method(b, "trace_start", nil); err != nil {
		t.Fatalf("trace_start after a written trace: %v", err)
	}
	if _, err := r.method(b, "trace_stop", nil); err != nil {
		t.Fatalf("trace_stop without a path: %v", err)
	}
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		if _, err := r.method(b, "trace_start", nil); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a trace thrown away has ended: a new one starts")
		}
	}
	r.method(b, "trace_stop", nil)
}

// An agent drives a page through block methods alone: it reads the page as
// a snapshot, acts on the snapshot's refs, and sees what a person would.
func TestAnAgentDrivesThePageFromItsSnapshot(t *testing.T) {
	r := startRex(t)
	form := "data:text/html," + url.PathEscape(`<title>Form</title>`+
		`<label>Name <input id=who></label> <button onclick="document.title='Saved '+who.value">Save</button>`+
		`<p style="margin-top:3000px"><a href="#" onclick="document.title='Far'">Far down</a></p>`)
	otherPage := "data:text/html," + url.PathEscape(`<title>Other</title><a href="#">One</a> <a href="#">Two</a>`+
		`<input id=who value=kept> <button>Three</button>`)
	a := r.createWith("block:a", map[string]any{"url": form, "transport": "calayerhost"})
	other := r.createWith("block:b", map[string]any{"url": otherPage, "transport": "calayerhost"})
	r.event(a, "state", titled("Form"))
	r.event(other, "state", titled("Other"))

	snap, err := r.method(a, "snapshot", nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	text := snap["snapshot"].(string)
	ref := func(line string) string {
		for _, l := range strings.Split(text, "\n") {
			if strings.Contains(l, line) {
				if i := strings.Index(l, "[ref="); i >= 0 {
					return l[i+5 : i+5+strings.Index(l[i+5:], "]")]
				}
			}
		}
		t.Fatalf("the snapshot has a ref for %s:\n%s", line, text)
		return ""
	}
	name, save, far := ref(`textbox "Name"`), ref(`button "Save"`), ref(`link "Far down"`)

	// Each block keeps its own refs: another block's snapshot changes none of a's.
	if _, err := r.method(other, "snapshot", nil); err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if _, err := r.method(a, "fill", map[string]any{"target": name, "text": "Ribbet"}); err != nil {
		t.Fatalf("fill: %v", err)
	}
	if _, err := r.method(a, "click", map[string]any{"target": save}); err != nil {
		t.Fatalf("click: %v", err)
	}
	r.event(a, "state", titled("Saved Ribbet"))
	// Off screen: click scrolls it into view first, and the link works.
	if _, err := r.method(a, "click", map[string]any{"target": far}); err != nil {
		t.Fatalf("click off screen: %v", err)
	}
	r.event(a, "state", titled("Far"))
	if v, err := r.method(other, "eval", map[string]any{"js": "document.title + ' ' + who.value"}); err != nil ||
		v["value"] != "Other kept" {
		t.Fatalf("the other block's page is untouched: %v %v", v, err)
	}

	// Typed keys reach the page as a person's do: Enter submits a search box.
	r.method(a, "eval", map[string]any{"js": `document.body.innerHTML = "<form onsubmit='document.title = \"Sent \" + q.value; return false'><input id=q></form>"; q.focus()`})
	if _, err := r.method(a, "type", map[string]any{"text": "hop\n"}); err != nil {
		t.Fatalf("type: %v", err)
	}
	r.event(a, "state", titled("Sent hop"))

	// Failures say what went wrong.
	for _, c := range []struct {
		method string
		args   map[string]any
		want   string
	}{
		{"click", map[string]any{"target": "#missing"}, "no element matches"},
		{"eval", map[string]any{"js": "nope()"}, "nope is not defined"},
		{"cdp", map[string]any{"method": "Nope.nope"}, "Nope.nope"},
	} {
		if _, err := r.method(a, c.method, c.args); err == nil || !strings.Contains(err.Message, c.want) {
			t.Errorf("%s %v: want an error with %q, got %v", c.method, c.args, c.want, err)
		}
	}
	r.method(a, "navigate", map[string]any{"url": page("Elsewhere")})
	r.event(a, "state", titled("Elsewhere"))
	if _, err := r.method(a, "click", map[string]any{"target": save}); err == nil ||
		!strings.Contains(err.Message, "snapshot") {
		t.Fatalf("a ref to a page that's gone asks for a new snapshot, got %v", err)
	}

	shot := filepath.Join(t.TempDir(), "page.png")
	if _, err := r.method(a, "screenshot", map[string]any{"path": shot}); err != nil {
		t.Fatalf("screenshot: %v", err)
	}
	if png, _ := os.ReadFile(shot); len(png) < 100 || string(png[1:4]) != "PNG" {
		t.Fatalf("screenshot writes a PNG, got %d bytes", len(png))
	}
}

// A link that opens a window opens a Rex pane beside the browser's. When Rex
// can't make one, the link opens in the browser's own pane.
func TestNewWindowLinksOpenRexPanes(t *testing.T) {
	r := startRex(t)
	target := page("New")
	links := "data:text/html," + url.PathEscape(`<title>Links</title><a id=go target=_blank href="`+target+`">Go</a>`)
	b := r.createWith("block:a", map[string]any{"url": links, "transport": "calayerhost"})
	r.event(b, "state", titled("Links"))

	if _, err := r.method(b, "click", map[string]any{"target": "#go"}); err != nil {
		t.Fatalf("click: %v", err)
	}
	var split map[string]any
	for deadline := time.Now().Add(10 * time.Second); split == nil; time.Sleep(50 * time.Millisecond) {
		r.mu.Lock()
		if len(r.splits) > 0 {
			split = r.splits[0]
		}
		r.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("the link asks Rex for a new pane")
		}
	}
	layout, _ := json.Marshal(split["layout"])
	if split["anchor_id"] != "block:a" || split["focus"] != true || !strings.Contains(string(layout), flavorName) ||
		!strings.Contains(string(layout), `"url":"`+target+`"`) {
		t.Fatalf("a browser pane with the link's page, beside block:a, in front: %v", split)
	}
	if v, _ := r.method(b, "eval", map[string]any{"js": "document.title"}); v["value"] != "Links" {
		t.Fatalf("the browser's own pane stays on its page, got %v", v)
	}

	r.mu.Lock()
	r.refuse = true
	r.mu.Unlock()
	r.method(b, "click", map[string]any{"target": "#go"})
	r.event(b, "state", titled("New"))
}
