// bowser drives Rex browser panes from a shell: open one beside your pane,
// read its page, and act on it. Agents use it the way a person uses the
// pane. Every command is a block method of the pane (rex/plugin/actions.go),
// called through the rex CLI, so it reaches only the Rex server you're in.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const creator = "dev.libbowser"

const usage = `bowser drives the browser panes of the Rex session you're in.

Usage: bowser [-b PANE] COMMAND [ARGS]

Panes:
  ls                              browser panes in this session
  open URL [--split right|left|down|up] [--size 0.2-0.95] [--no-focus]
                                  open a browser pane beside this pane; prints its id
  goto URL                        load URL, or a search, in the pane; waits for it
  back | forward | reload
  state                           the page's url, title, and loading state, as JSON

Read the page:
  snapshot [-i]                   the page's elements, one per line; -i: only those with refs
  eval JS                         run JavaScript in the page; prints the value as JSON
  screenshot [PATH]               save a PNG of the page; prints its path

Act on the page:
  click TARGET                    TARGET: a ref from the newest snapshot (e3, @e3) or a CSS selector
  fill TARGET TEXT                replace the text of a field
  type TEXT                       type into what has the keyboard; \n presses Enter
  press KEY                       Enter, Tab, Shift+Tab, Escape, Backspace, ArrowDown, a, …
  scroll [down|up|left|right] [PX]
  wait [SELECTOR | --text TEXT] [--timeout MS]
                                  until it shows; with neither, until the page has loaded
  cdp METHOD [PARAMS]             any Chrome DevTools Protocol method; PARAMS is a JSON object

PANE is a block id, or its start or end, from bowser ls. Without -b: the
session's only browser pane, or the only one in your window.

  bowser open localhost:3000 --split right --size 0.4
  bowser snapshot -i
  bowser fill e2 "ribbet@example.com" && bowser click e3 && bowser wait --text Welcome
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "bowser:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	pane := os.Getenv("BOWSER_PANE")
	if len(args) >= 2 && (args[0] == "-b" || args[0] == "--block") {
		pane, args = args[1], args[2:]
	}
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Print(usage)
		return nil
	}
	if err := sameServer(); err != nil {
		return err
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "ls":
		return list()
	case "open":
		return open(rest)
	}
	block, err := pick(pane)
	if err != nil {
		return err
	}
	call := func(method string, a any) (map[string]any, error) { return blockCall(block, method, a) }
	nargs := func(n int, form string) error {
		if len(rest) != n {
			return fmt.Errorf("usage: bowser %s %s", cmd, form)
		}
		return nil
	}

	switch cmd {
	case "goto":
		if err := nargs(1, "URL"); err != nil {
			return err
		}
		return navigated(block, func() error { _, err := call("navigate", map[string]any{"url": rest[0]}); return err })
	case "back", "forward", "reload":
		return navigated(block, func() error { _, err := call(cmd, nil); return err })
	case "state":
		return printJSON(call("state", nil))
	case "snapshot":
		interactive := len(rest) == 1 && (rest[0] == "-i" || rest[0] == "--interactive")
		if len(rest) > 0 && !interactive {
			return errors.New("usage: bowser snapshot [-i]")
		}
		r, err := call("snapshot", map[string]any{"interactive": interactive})
		if err != nil {
			return err
		}
		fmt.Print(r["snapshot"])
		return nil
	case "eval":
		if err := nargs(1, "JS"); err != nil {
			return err
		}
		r, err := call("eval", map[string]any{"js": rest[0]})
		if err != nil {
			return err
		}
		return printJSON(r["value"], nil)
	case "screenshot":
		path := filepath.Join(os.TempDir(), "bowser-"+time.Now().Format("20060102-150405.000")+".png")
		if len(rest) == 1 {
			path, _ = filepath.Abs(rest[0])
		} else if len(rest) > 1 {
			return errors.New("usage: bowser screenshot [PATH]")
		}
		if _, err := call("screenshot", map[string]any{"path": path}); err != nil {
			return err
		}
		fmt.Println(path)
		return nil
	case "click":
		if err := nargs(1, "TARGET"); err != nil {
			return err
		}
		_, err := call("click", map[string]any{"target": rest[0]})
		return err
	case "fill":
		if err := nargs(2, "TARGET TEXT"); err != nil {
			return err
		}
		_, err := call("fill", map[string]any{"target": rest[0], "text": rest[1]})
		return err
	case "type":
		if err := nargs(1, "TEXT"); err != nil {
			return err
		}
		_, err := call("type", map[string]any{"text": strings.ReplaceAll(rest[0], `\n`, "\n")})
		return err
	case "press":
		if err := nargs(1, "KEY"); err != nil {
			return err
		}
		_, err := call("press", map[string]any{"key": rest[0]})
		return err
	case "scroll":
		return scroll(call, rest)
	case "wait":
		return wait(call, rest)
	case "cdp":
		if len(rest) < 1 || len(rest) > 2 {
			return errors.New("usage: bowser cdp METHOD [PARAMS]")
		}
		a := map[string]any{"method": rest[0]}
		if len(rest) == 2 {
			var params map[string]any
			if err := json.Unmarshal([]byte(rest[1]), &params); err != nil {
				return fmt.Errorf("PARAMS is a JSON object: %w", err)
			}
			a["params"] = params
		}
		r, err := call("cdp", a)
		if err != nil {
			return err
		}
		return printJSON(r["result"], nil)
	}
	return fmt.Errorf("no command %q; see bowser --help", cmd)
}

// ---- Rex --------------------------------------------------------------

func rexBin() string {
	if p := os.Getenv("BOWSER_REX"); p != "" {
		return p
	}
	return "rex"
}

func rex(args ...string) ([]byte, error) {
	var out, errOut bytes.Buffer
	// Never start a server: bowser acts on panes of one that runs.
	c := exec.Command(rexBin(), append([]string{"--autostart=false"}, args...)...)
	c.Stdout, c.Stderr = &out, &errOut
	if err := c.Run(); err != nil {
		msg := strings.SplitN(strings.TrimSpace(errOut.String()), "\n", 2)[0]
		if msg == "" {
			msg = err.Error()
		}
		return nil, errors.New(rexNoise.ReplaceAllString(msg, ""))
	}
	return out.Bytes(), nil
}

// What Rex wraps a block's own error in: "Error: ", the hops it passed, and
// their statuses.
var rexNoise = regexp.MustCompile(`^Error: |stream response "[^"]*" failed: | \(status=\d+ code=\w+\)`)

func blockCall(block, method string, args any) (map[string]any, error) {
	a := []string{"block", "call", "-b", block, method}
	if args != nil {
		j, _ := json.Marshal(args)
		a = append(a, string(j))
	}
	out, err := rex(a...)
	if err != nil {
		return nil, err
	}
	var r map[string]any
	if len(bytes.TrimSpace(out)) > 0 {
		if err := json.Unmarshal(out, &r); err != nil {
			return nil, fmt.Errorf("%s: %w", method, err)
		}
	}
	return r, nil
}

type pane struct {
	ID     string `json:"block_id"`
	Label  string `json:"label"`
	Window string `json:"window_id"`
	Kind   string `json:"creator_name"`
}

func browsers() ([]pane, error) {
	out, err := rex("block", "ls", "--json")
	if err != nil {
		return nil, err
	}
	var ls struct {
		Blocks []pane `json:"blocks"`
	}
	if err := json.Unmarshal(out, &ls); err != nil {
		return nil, err
	}
	var found []pane
	for _, b := range ls.Blocks {
		if b.Kind == creator {
			found = append(found, b)
		}
	}
	return found, nil
}

type whoami struct {
	Session string `json:"session_id"`
	Window  string `json:"window_id"`
	Block   string `json:"block_id"`
}

// sameServer checks that rex reaches the server of the pane we run in. A
// shell of a second Rex server, such as a dev one, can reach the user's
// own server instead: never act on that one's panes.
func sameServer() error {
	pane := os.Getenv("REX_BLOCK")
	if pane == "" {
		return nil
	}
	if w := me(); w.Block != pane {
		return fmt.Errorf("rex reaches a Rex server that doesn't have this pane (%s); set REX_SERVER to this pane's server", short(pane))
	}
	return nil
}

func me() whoami {
	var w whoami
	if out, err := rex("whoami", "--json"); err == nil {
		json.Unmarshal(out, &w)
	}
	return w
}

// pick chooses the pane to act on: the one asked for, or the only browser
// pane of the session, or of the caller's window.
func pick(want string) (string, error) {
	all, err := browsers()
	if err != nil {
		return "", err
	}
	if want != "" {
		var hits []pane
		for _, b := range all {
			id := strings.TrimPrefix(b.ID, "block:")
			if b.ID == want || strings.HasPrefix(id, want) || strings.HasSuffix(id, want) {
				hits = append(hits, b)
			}
		}
		if len(hits) == 1 {
			return hits[0].ID, nil
		}
		return "", fmt.Errorf("%d browser panes match %q\n%s", len(hits), want, table(all))
	}
	switch len(all) {
	case 0:
		return "", errors.New("no browser pane in this session; open one: bowser open URL")
	case 1:
		return all[0].ID, nil
	}
	w := me().Window
	var mine []pane
	for _, b := range all {
		if b.Window == w {
			mine = append(mine, b)
		}
	}
	if len(mine) == 1 {
		return mine[0].ID, nil
	}
	return "", fmt.Errorf("several browser panes; pick one with -b PANE\n%s", table(all))
}

func short(id string) string {
	id = strings.TrimPrefix(id, "block:")
	return id[max(0, len(id)-6):]
}

func table(ps []pane) string {
	var sb strings.Builder
	for _, b := range ps {
		fmt.Fprintf(&sb, "  %s  %s\n", short(b.ID), b.Label)
	}
	return sb.String()
}

func list() error {
	all, err := browsers()
	if err != nil {
		return err
	}
	for _, b := range all {
		s, err := blockCall(b.ID, "state", nil)
		url := ""
		if err == nil {
			url, _ = s["url"].(string)
		}
		fmt.Printf("%s  %-40s  %s\n", short(b.ID), b.Label, url)
	}
	return nil
}

// ---- Commands ---------------------------------------------------------

// open makes a browser pane in a new split beside the caller's pane.
func open(args []string) error {
	var url string
	dir, size, focus := "right", 0.5, true
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--split" && i+1 < len(args):
			i++
			dir = args[i]
		case a == "--size" && i+1 < len(args):
			i++
			f, err := strconv.ParseFloat(args[i], 64)
			if err != nil || f < 0.2 || f > 0.95 {
				return errors.New("--size is a fraction from 0.2 to 0.95")
			}
			size = f
		case a == "--no-focus":
			focus = false
		case url == "" && !strings.HasPrefix(a, "--"):
			url = a
		default:
			return errors.New("usage: bowser open URL [--split right|left|down|up] [--size 0.2-0.95] [--no-focus]")
		}
	}
	if url == "" {
		return errors.New("usage: bowser open URL [--split right|left|down|up] [--size 0.2-0.95]")
	}
	split := map[string][2]string{"right": {"horizontal", "after"}, "left": {"horizontal", "before"},
		"down": {"vertical", "after"}, "up": {"vertical", "before"}}
	how, ok := split[dir]
	if !ok {
		return fmt.Errorf("--split %s: use right, left, down, or up", dir)
	}
	// The new pane gets size; ratio is the share of the part before the split.
	ratio := 1 - size
	if how[1] == "before" {
		ratio = size
	}
	w := me()
	if w.Session == "" {
		return errors.New("run bowser in a Rex pane: no Rex session here")
	}
	req := map[string]any{"session_id": w.Session, "direction": how[0], "side": how[1], "ratio": ratio, "focus": focus,
		"layout": map[string]any{"block": map[string]any{"flavor": creator + ".browser", "options": map[string]any{"url": url}}}}
	if w.Block != "" {
		req["anchor_id"] = w.Block
	}
	j, _ := json.Marshal(req)
	out, err := rex("api", "call", "session.new_split", string(j))
	if err != nil {
		return err
	}
	var r struct {
		Blocks []string `json:"block_ids"`
	}
	if json.Unmarshal(out, &r) != nil || len(r.Blocks) == 0 {
		return fmt.Errorf("rex made no pane: %s", out)
	}
	id := r.Blocks[0]
	// Ready for the next command: the page has loaded.
	waitLoaded(id)
	fmt.Println(id)
	return nil
}

// navigated runs a command that starts a navigation, then waits for the new
// page to load, so the next command sees it.
func navigated(block string, start func() error) error {
	before, _ := blockCall(block, "state", nil)
	if err := start(); err != nil {
		return err
	}
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		s, err := blockCall(block, "state", nil)
		if err == nil && (s["loading"] == true || s["url"] != before["url"]) {
			break
		}
	}
	return waitLoaded(block)
}

func waitLoaded(block string) error {
	var err error
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if _, err = blockCall(block, "wait", nil); err == nil {
			return nil
		}
	}
	return err
}

func scroll(call func(string, any) (map[string]any, error), args []string) error {
	dir, px := "down", 600.0
	for _, a := range args {
		if f, err := strconv.ParseFloat(a, 64); err == nil {
			px = f
		} else {
			dir = a
		}
	}
	d := map[string][2]float64{"down": {0, 1}, "up": {0, -1}, "right": {1, 0}, "left": {-1, 0}}[dir]
	if d == [2]float64{} {
		return errors.New("usage: bowser scroll [down|up|left|right] [PX]")
	}
	_, err := call("scroll", map[string]any{"dx": d[0] * px, "dy": d[1] * px})
	return err
}

func wait(call func(string, any) (map[string]any, error), args []string) error {
	a := map[string]any{}
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--text" && i+1 < len(args):
			i++
			a["text"] = args[i]
		case args[i] == "--timeout" && i+1 < len(args):
			i++
			ms, err := strconv.Atoi(args[i])
			if err != nil || ms <= 0 {
				return errors.New("--timeout is in milliseconds")
			}
			a["timeout_ms"] = ms
		case !strings.HasPrefix(args[i], "--") && a["target"] == nil:
			a["target"] = args[i]
		default:
			return errors.New("usage: bowser wait [SELECTOR | --text TEXT] [--timeout MS]")
		}
	}
	_, err := call("wait", a)
	return err
}

func printJSON(v any, err error) error {
	if err != nil {
		return err
	}
	out, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(out))
	return nil
}
