package main

// One bowser-cef process serves every browser block: one surface per block,
// one profile, shared GPU and network processes. We drive it with JSON lines
// on its stdin and stdout (adapters/cef/README.md).

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const (
	engineStartTimeout = 20 * time.Second
	engineCallTimeout  = 10 * time.Second
	engineStopTimeout  = 5 * time.Second
)

// An event from the engine: {"event":"state","surface":"1",...}.
type engineEvent map[string]json.RawMessage

func (e engineEvent) str(key string) string {
	var s string
	json.Unmarshal(e[key], &s)
	return s
}

type engine struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	exited chan struct{} // closed once the process is gone
	status string        // how it ended, set before exited closes

	mu      sync.Mutex
	nextID  int
	waiting map[int]chan engineEvent
}

func enginePath() string {
	if p := os.Getenv("BOWSER_ENGINE"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Development/libbowser/build/bowser-cef.app/Contents/MacOS/bowser-cef")
}

// startEngine runs the engine and waits until it takes commands. onEvent gets
// every event after "ready", on one goroutine, in order.
func startEngine(onEvent func(*engine, engineEvent)) (*engine, error) {
	var args []string
	if dir := os.Getenv("BOWSER_PROFILE"); dir != "" {
		args = append(args, "--profile", dir)
	}
	cmd := exec.Command(enginePath(), args...)
	// Its own process group, so stop can end CEF's helpers with it.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = log.Writer()
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("starting engine: %w", err)
	}
	e := &engine{cmd: cmd, stdin: stdin, exited: make(chan struct{}), waiting: map[int]chan engineEvent{}}

	ready := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		started := false
		for sc.Scan() {
			var ev engineEvent
			if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
				log.Printf("engine: bad line %q", sc.Text())
				continue
			}
			if raw, ok := ev["id"]; ok {
				var id int
				json.Unmarshal(raw, &id)
				e.mu.Lock()
				ch := e.waiting[id]
				delete(e.waiting, id)
				e.mu.Unlock()
				if ch != nil {
					ch <- ev
				}
				continue
			}
			if ev.str("event") == "ready" && !started {
				started = true
				close(ready)
				continue
			}
			onEvent(e, ev)
		}
		// os/exec: Wait only after the pipe reader is done.
		err := cmd.Wait()
		e.status = "exited"
		if err != nil {
			e.status = err.Error()
		}
		close(e.exited)
		e.mu.Lock()
		for id, ch := range e.waiting {
			close(ch)
			delete(e.waiting, id)
		}
		e.mu.Unlock()
	}()

	select {
	case <-ready:
		log.Printf("engine %d ready", cmd.Process.Pid)
		return e, nil
	case <-e.exited:
		return nil, fmt.Errorf("engine exited before it was ready: %s", e.status)
	case <-time.After(engineStartTimeout):
		e.stop()
		return nil, fmt.Errorf("engine not ready within %s", engineStartTimeout)
	}
}

func (e *engine) alive() bool {
	select {
	case <-e.exited:
		return false
	default:
		return true
	}
}

var errEngineGone = errors.New("the browser engine exited")

// call sends one command and waits for its reply.
func (e *engine) call(cmd map[string]any) (engineEvent, error) {
	ch := make(chan engineEvent, 1)
	e.mu.Lock()
	e.nextID++
	id := e.nextID
	e.waiting[id] = ch
	e.mu.Unlock()
	cmd["id"] = id
	line, _ := json.Marshal(cmd)
	if _, err := e.stdin.Write(append(line, '\n')); err != nil {
		e.mu.Lock()
		delete(e.waiting, id)
		e.mu.Unlock()
		return nil, errEngineGone
	}
	select {
	case r, ok := <-ch:
		if !ok {
			return nil, errEngineGone
		}
		if msg := r.str("error"); msg != "" {
			return nil, errors.New(msg)
		}
		return r, nil
	case <-time.After(engineCallTimeout):
		e.mu.Lock()
		delete(e.waiting, id)
		e.mu.Unlock()
		return nil, fmt.Errorf("the browser engine didn't answer %v within %s", cmd["cmd"], engineCallTimeout)
	}
}

// stop closes stdin, which the engine takes as "quit", then signals its
// process group if it doesn't.
func (e *engine) stop() {
	e.stdin.Close()
	pid := e.cmd.Process.Pid
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL} {
		select {
		case <-e.exited:
			return
		case <-time.After(engineStopTimeout):
			syscall.Kill(-pid, sig)
		}
	}
	<-e.exited
}
