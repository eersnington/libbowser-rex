package main

// Minimal RFC 6455 server side: enough for Rex's rex.control.v1 channel.
// No extensions are negotiated, so frames are never compressed.

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type wsConn struct {
	conn net.Conn
	r    *bufio.Reader
	wmu  sync.Mutex
}

func wsUpgrade(w http.ResponseWriter, r *http.Request, subprotocol string) (*wsConn, error) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" || r.Header.Get("Upgrade") != "websocket" {
		http.Error(w, "websocket upgrade required", http.StatusBadRequest)
		return nil, errors.New("ws: not an upgrade")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("ws: hijack unsupported")
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	sum := sha1.Sum([]byte(key + wsGUID))
	resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n" +
		"Sec-WebSocket-Protocol: " + subprotocol + "\r\n\r\n"
	if _, err := conn.Write([]byte(resp)); err != nil {
		conn.Close()
		return nil, err
	}
	return &wsConn{conn: conn, r: rw.Reader}, nil
}

// ReadMessage returns the next text or binary message, answering pings and closes.
func (c *wsConn) ReadMessage() ([]byte, error) {
	var msg []byte
	for {
		var h [2]byte
		if _, err := io.ReadFull(c.r, h[:]); err != nil {
			return nil, err
		}
		fin, op := h[0]&0x80 != 0, h[0]&0x0f
		n := uint64(h[1] & 0x7f)
		switch n {
		case 126:
			var b [2]byte
			if _, err := io.ReadFull(c.r, b[:]); err != nil {
				return nil, err
			}
			n = uint64(binary.BigEndian.Uint16(b[:]))
		case 127:
			var b [8]byte
			if _, err := io.ReadFull(c.r, b[:]); err != nil {
				return nil, err
			}
			n = binary.BigEndian.Uint64(b[:])
		}
		if n > 16<<20 {
			return nil, errors.New("ws: frame too large")
		}
		var mask [4]byte
		masked := h[1]&0x80 != 0
		if masked {
			if _, err := io.ReadFull(c.r, mask[:]); err != nil {
				return nil, err
			}
		}
		p := make([]byte, n)
		if _, err := io.ReadFull(c.r, p); err != nil {
			return nil, err
		}
		if masked {
			for i := range p {
				p[i] ^= mask[i%4]
			}
		}
		switch op {
		case 0x8: // close: echo the status and stop
			c.writeFrame(0x8, p)
			return nil, io.EOF
		case 0x9:
			c.writeFrame(0xA, p)
			continue
		case 0xA:
			continue
		}
		msg = append(msg, p...)
		if fin {
			return msg, nil
		}
	}
}

func (c *wsConn) WriteText(p []byte) error { return c.writeFrame(0x1, p) }

func (c *wsConn) writeFrame(op byte, p []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	h := []byte{0x80 | op}
	switch n := len(p); {
	case n < 126:
		h = append(h, byte(n))
	case n <= 0xffff:
		h = append(h, 126, byte(n>>8), byte(n))
	default:
		h = binary.BigEndian.AppendUint64(append(h, 127), uint64(n))
	}
	_, err := c.conn.Write(append(h, p...))
	return err
}

func (c *wsConn) Close() error { return c.conn.Close() }
