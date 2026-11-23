package main

// End to end: rex/browser.lua loaded by a real Rex server, with this plugin
// and the real engine. The action is driven the way a shell drives it,
// `rex do browser url=...`; ⇧⌘B runs the same action after its prompt.

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type realRex struct {
	t    *testing.T
	bin  string
	sock string
}

func startRealRex(t *testing.T) *realRex {
	home, _ := os.UserHomeDir()
	bin := filepath.Join(home, "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")
	if b := os.Getenv("REX_SERVER_BIN"); b != "" {
		bin = b
	}
	if _, err := os.Stat(bin); err != nil {
		t.Skip("no Rex server; set REX_SERVER_BIN")
	}
	engine, _ := filepath.Abs("../../build/bowser-cef.app/Contents/MacOS/bowser-cef")
	if _, err := os.Stat(engine); err != nil {
		t.Skip("no bowser-cef; run make cef")
	}
	lua, _ := filepath.Abs("../browser.lua")
	dir, _ := os.MkdirTemp("/tmp", "rx") // Unix socket paths are short
	t.Cleanup(func() { os.RemoveAll(dir) })
	os.MkdirAll(filepath.Join(dir, "blocks"), 0o755)
	if err := os.Link(pluginBin, filepath.Join(dir, "blocks/rexplugin")); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(dir, "init.lua")
	os.WriteFile(config, []byte(`dofile("`+lua+`")`+"\n"), 0o644)
	r := &realRex{t: t, bin: bin, sock: filepath.Join(dir, "s.sock")}

	cmd := exec.Command(bin, "server", "run", "--listen", "unix://"+r.sock, "--state-dir", filepath.Join(dir, "state"),
		"--config", config, "--restore=false", "--block-dir", filepath.Join(dir, "blocks"))
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "REX_") {
			env = append(env, kv)
		}
	}
	cmd.Env = append(env, "HOME="+dir, "REX_CONFIG="+config, "BOWSER_ENGINE="+engine,
		"REXPLUGIN_LOG="+filepath.Join(dir, "plugin.log"))
	log, _ := os.Create(filepath.Join(dir, "server.log"))
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Signal(os.Interrupt)
		cmd.Wait()
		if t.Failed() {
			for _, f := range []string{"server.log", "plugin.log"} {
				b, _ := os.ReadFile(filepath.Join(dir, f))
				t.Logf("%s:\n%s", f, b)
			}
		}
	})
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(r.sock); err == nil {
			return r
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the Rex server never listened")
	return nil
}

// rex runs the Rex CLI against this server and decodes its JSON output.
func (r *realRex) rex(args ...string) (map[string]any, error) {
	out, err := exec.Command(r.bin, append([]string{"--autostart=false", "-S", "unix://" + r.sock}, args...)...).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			r.t.Logf("rex %v: %s", args, ee.Stderr)
		}
		return nil, err
	}
	var v map[string]any
	if s := strings.TrimSpace(string(out)); s != "" && s != "null" {
		if err := json.Unmarshal([]byte(s), &v); err != nil {
			return nil, err
		}
	}
	return v, nil
}

func (r *realRex) must(args ...string) map[string]any {
	v, err := r.rex(args...)
	if err != nil {
		r.t.Fatalf("rex %v: %v", args, err)
	}
	return v
}

// panes maps each block in the session's first window to its rect.
func (r *realRex) panes(session string) map[string][]any {
	view := r.must("api", "call", "session.view", `{"session_id":"`+session+`"}`)
	out := map[string][]any{}
	var walk func(n map[string]any)
	walk = func(n map[string]any) {
		if id, ok := n["block_id"].(string); ok {
			out[id] = n["rect"].([]any)
		}
		if s, ok := n["split"].(map[string]any); ok {
			walk(s["before"].(map[string]any))
			walk(s["after"].(map[string]any))
		}
	}
	w := view["windows"].([]any)[0].(map[string]any)
	walk(w["layers"].([]any)[0].(map[string]any)["layout"].(map[string]any))
	return out
}

func TestBrowserActionOpensTheAddressBesideThePane(t *testing.T) {
	r := startRealRex(t)
	s := r.must("api", "call", "session.create",
		`{"initial_windows":[{"layout":{"block":{"flavor":"dev.libbowser.browser","options":{"url":"`+page("Alpha")+`"}}}}]}`)
	session := s["session_id"].(string)
	var anchor string
	for id := range r.panes(session) {
		anchor = id
	}

	res := r.must("do", "browser", "-s", session, "-b", anchor, "url="+page("Beta"))
	ids, _ := res["block_ids"].([]any)
	if len(ids) != 1 {
		t.Fatalf("one new pane, got %v", res)
	}
	added := ids[0].(string)
	p := r.panes(session)
	a, b := p[anchor], p[added]
	if a == nil || b == nil || a[0].(float64)+a[2].(float64) != b[0].(float64) || a[1] != b[1] {
		t.Fatalf("the new pane is right of the pane it was opened from: %v and %v", a, b)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		st, _ := r.rex("block", "call", "-b", added, "state")
		if st["title"] == "Beta" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the new pane shows the address it was given: %v", st)
		}
		time.Sleep(100 * time.Millisecond)
	}

	// A blank answer, as when the prompt is submitted empty, opens nothing.
	if _, err := r.rex("do", "browser", "-s", session, "-b", anchor, "url=   "); err != nil {
		t.Fatalf("a blank address is not an error: %v", err)
	}
	if n := len(r.panes(session)); n != 2 {
		t.Fatalf("a blank address opens no pane: %d panes", n)
	}
}
