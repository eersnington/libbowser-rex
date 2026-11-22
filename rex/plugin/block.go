package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	creatorName = "dev.libbowser"
	flavorName  = "dev.libbowser.browser"
	// bowser-test prints all its tickets at startup and has no way to mint more,
	// so we ask for a batch and hand them out one per ticket call.
	ticketBatch  = 16
	startTimeout = 10 * time.Second
	stopTimeout  = 2 * time.Second
)

type plugin struct {
	mu     sync.Mutex
	conn   *conn
	blocks map[string]*block // by hosted block ID
}

type block struct {
	id        string
	url       string
	transport string
	cmd       *exec.Cmd
	exited    chan struct{}

	onHost func(event string)

	mu      sync.Mutex
	tickets []string
	closing bool
}

func newPlugin() *plugin { return &plugin{blocks: map[string]*block{}} }

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

func (p *plugin) create(raw json.RawMessage) (any, *rpcError) {
	var in createInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, errBadRequest("decoding block.create: " + err.Error())
	}
	if in.Flavor != flavorName {
		return nil, errBadRequest(fmt.Sprintf("unknown flavor %q", in.Flavor))
	}
	// Rex does not check options against options_schema, so we do.
	var opts browserOptions
	if len(in.Options) > 0 {
		dec := json.NewDecoder(bytes.NewReader(in.Options))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&opts); err != nil {
			return nil, errBadRequest("options: " + err.Error())
		}
	}
	t := opts.Transport
	if t == "" {
		t = "calayerhost"
	}
	if t != "calayerhost" && t != "iosurface" {
		return nil, errBadRequest(fmt.Sprintf("transport %q: want calayerhost or iosurface", t))
	}

	b := &block{id: newBlockID(), url: opts.URL, transport: t, exited: make(chan struct{})}
	b.onHost = func(event string) { p.emit(b.id, event, map[string]any{}) }
	if err := b.start(); err != nil {
		return nil, errInternal(err.Error())
	}
	p.mu.Lock()
	p.blocks[b.id] = b
	p.mu.Unlock()
	log.Printf("%s: producer %d for session block %s", b.id, b.cmd.Process.Pid, in.BlockID)

	go func() {
		<-b.exited
		b.mu.Lock()
		closing := b.closing
		b.mu.Unlock()
		if !closing {
			p.emit(b.id, "producer_exited", map[string]any{"pid": b.cmd.Process.Pid, "status": b.cmd.ProcessState.String()})
		}
	}()
	return map[string]string{"block_id": b.id}, nil
}

func producerPath() string {
	if p := os.Getenv("BOWSER_PRODUCER"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Development/libbowser/build/bowser-test")
}

// start spawns the producer and waits for its first ticket.
func (b *block) start() error {
	args := []string{"--transport", b.transport, "--tickets", fmt.Sprint(ticketBatch)}
	if b.url != "" {
		args = append(args, "--url", b.url) // bowser-test ignores it; real browsers read it
	}
	cmd := exec.Command(producerPath(), args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // so close can stop its helpers too
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting producer: %w", err)
	}
	b.cmd = cmd

	// os/exec: Wait only after the pipe readers are done.
	var readers sync.WaitGroup
	readers.Add(2)
	first := make(chan error, 1)
	go func() {
		defer readers.Done()
		sc := bufio.NewScanner(stdout)
		n := 0
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			b.mu.Lock()
			b.tickets = append(b.tickets, line)
			b.mu.Unlock()
			if n++; n == 1 {
				first <- nil
			}
		}
		if n == 0 {
			first <- fmt.Errorf("producer printed no ticket")
		}
	}()
	go func() {
		defer readers.Done()
		// bowser-test logs "host attached" / "host detached" here, between fps stats.
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			switch strings.TrimSpace(sc.Text()) {
			case "host attached":
				b.onHost("host_attached")
			case "host detached":
				b.onHost("host_detached")
			}
		}
	}()
	go func() {
		readers.Wait()
		cmd.Wait()
		close(b.exited)
	}()

	select {
	case err := <-first:
		if err == nil {
			return nil
		}
		b.stop()
		return err
	case <-b.exited:
		return fmt.Errorf("producer exited before its first ticket: %s", cmd.ProcessState)
	case <-time.After(startTimeout):
		b.stop()
		return fmt.Errorf("producer printed no ticket within %s", startTimeout)
	}
}

// stop ends the producer's process group: SIGTERM, then SIGKILL.
func (b *block) stop() {
	b.mu.Lock()
	b.closing = true
	b.mu.Unlock()
	pid := b.cmd.Process.Pid
	syscall.Kill(-pid, syscall.SIGTERM)
	select {
	case <-b.exited:
	case <-time.After(stopTimeout):
		syscall.Kill(-pid, syscall.SIGKILL)
		<-b.exited
	}
}

func (p *plugin) take(id string) *block {
	p.mu.Lock()
	defer p.mu.Unlock()
	b := p.blocks[id]
	delete(p.blocks, id)
	return b
}

func (p *plugin) close(raw json.RawMessage) (any, *rpcError) {
	var in struct {
		BlockID string `json:"block_id"`
	}
	json.Unmarshal(raw, &in)
	b := p.take(in.BlockID)
	if b == nil {
		return nil, errNotFound("no block " + in.BlockID)
	}
	b.stop()
	log.Printf("%s: closed", b.id)
	return nil, nil
}

func (p *plugin) closeAll() {
	p.mu.Lock()
	var all []*block
	for id, b := range p.blocks {
		all = append(all, b)
		delete(p.blocks, id)
	}
	p.mu.Unlock()
	var wg sync.WaitGroup
	for _, b := range all {
		wg.Add(1)
		go func() { defer wg.Done(); b.stop() }()
	}
	wg.Wait()
}

func (p *plugin) method(raw json.RawMessage) (any, *rpcError) {
	var in struct {
		BlockID string          `json:"block_id"`
		Method  string          `json:"method"`
		Args    json.RawMessage `json:"args"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, errBadRequest("decoding block.method: " + err.Error())
	}
	// Rex does not check args against input_schema. Both methods take none.
	if len(in.Args) > 0 {
		dec := json.NewDecoder(bytes.NewReader(in.Args))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&struct{}{}); err != nil {
			return nil, errBadRequest(in.Method + " args: " + err.Error())
		}
	}
	p.mu.Lock()
	b := p.blocks[in.BlockID]
	p.mu.Unlock()
	if b == nil {
		return nil, errNotFound("no block " + in.BlockID)
	}
	running := true
	select {
	case <-b.exited:
		running = false
	default:
	}

	switch in.Method {
	case "ticket":
		if !running {
			return nil, errBadRequest("the producer has exited")
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		if len(b.tickets) == 0 {
			return nil, errBadRequest(fmt.Sprintf("all %d tickets are used; close and reopen the block", ticketBatch))
		}
		t := b.tickets[0]
		b.tickets = b.tickets[1:]
		return map[string]any{"ticket": t, "remaining": len(b.tickets)}, nil
	case "state":
		pid := 0
		if running {
			pid = b.cmd.Process.Pid
		}
		return map[string]any{"url": b.url, "transport": b.transport, "producer_pid": pid}, nil
	}
	return nil, errNoMethod(in.Method)
}

func newBlockID() string {
	var u [16]byte
	rand.Read(u[:])
	u[6] = u[6]&0x0f | 0x40 // version 4
	u[8] = u[8]&0x3f | 0x80
	return fmt.Sprintf("block:%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}
