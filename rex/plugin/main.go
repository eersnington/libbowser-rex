// Command rexplugin is a Rex block plugin that offers the dev.libbowser.browser
// block flavor. Every block is one surface of a shared bowser-cef engine,
// which hands out the tickets hosts attach with.
//
// Rex starts it from a --block-dir. See ../PROTOCOL.md for the wire protocol.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

func main() {
	log.SetPrefix("rexplugin: ")
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	// Rex points our stdout and stderr at /dev/null.
	if path := os.Getenv("REXPLUGIN_LOG"); path != "" {
		if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
			log.SetOutput(f)
		}
	}

	fd, err := strconv.Atoi(os.Getenv("REX_BLOCKSERVER_INFO_FD"))
	if err != nil {
		log.Fatal("REX_BLOCKSERVER_INFO_FD is not set: start me from a Rex --block-dir")
	}

	dir, err := os.MkdirTemp("", "rexplugin-")
	if err != nil {
		log.Fatal(err)
	}
	sock := filepath.Join(dir, "control.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		log.Fatal(err)
	}

	p := newPlugin()
	go p.warm()
	if path := os.Getenv("BOWSER_TICKET_SOCKET"); path != "" {
		go p.serveTickets(path)
	}
	cleanup := func() {
		p.closeAll()
		os.RemoveAll(dir)
	}

	// Rex sends SIGINT after it closes the control channel on shutdown.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		s := <-sigs
		log.Printf("got %v, stopping the engine", s)
		cleanup()
		os.Exit(0)
	}()
	// If the server dies without signalling us, we get reparented. Don't leak the engine.
	go func() {
		parent := os.Getppid()
		for range time.Tick(time.Second) {
			if os.Getppid() != parent {
				log.Print("server is gone, stopping the engine")
				cleanup()
				os.Exit(0)
			}
		}
	}()

	info, _ := json.Marshal(map[string]any{
		"network":  "unix",
		"addr":     sock,
		"base_url": "http://rexplugin",
		"pid":      os.Getpid(),
	})
	f := os.NewFile(uintptr(fd), "rex-info")
	if _, err := fmt.Fprintf(f, "%s\n", info); err != nil {
		log.Fatal(err)
	}
	f.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/control", func(w http.ResponseWriter, r *http.Request) {
		c, err := wsUpgrade(w, r, "rex.control.v1")
		if err != nil {
			log.Print(err)
			return
		}
		p.serve(c)
	})
	log.Fatal(http.Serve(ln, mux))
}
