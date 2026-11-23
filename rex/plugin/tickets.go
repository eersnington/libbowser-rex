package main

// A ticket socket, for the Rex client: one line in, the session block ID of a
// browser pane; one JSON line out, {"ticket"} or {"error"}. It is the block's
// ticket method without a round trip through the Rex server, which the
// client can only reach by starting the rex CLI (about 25 ms). The socket is
// only as open as its directory.

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"os"
	"strings"
)

func (p *plugin) serveTickets(path string) {
	os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		log.Printf("ticket socket: %v", err)
		return
	}
	os.Chmod(path, 0o600)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("ticket socket: %v", err)
			return
		}
		go p.answerTickets(c)
	}
}

func (p *plugin) answerTickets(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	enc := json.NewEncoder(c)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		sessionBlock := strings.TrimSpace(line)
		var b *block
		p.mu.Lock()
		for _, x := range p.blocks {
			if x.sessionBlockID == sessionBlock {
				b = x
			}
		}
		p.mu.Unlock()
		if b == nil {
			enc.Encode(map[string]string{"error": "no browser pane " + sessionBlock})
			continue
		}
		ticket, err := p.ticket(b)
		if err != nil {
			enc.Encode(map[string]string{"error": err.Error()})
			continue
		}
		enc.Encode(map[string]string{"ticket": ticket})
	}
}
