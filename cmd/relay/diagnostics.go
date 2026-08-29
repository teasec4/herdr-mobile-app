package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"net/http"
)

// statusWriter records the response code so the logger can print it after the
// request completes. It must forward the ResponseWriter interfaces that
// gorilla/websocket uses when upgrading: without Hijack() the WS upgrade fails
// with 500.
type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(code int) {
	w.code = code
	w.ResponseWriter.WriteHeader(code)
}

// Hijack hands the connection to the underlying writer — required by
// gorilla/websocket for the HTTP → WS upgrade.
func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("underlying ResponseWriter does not support hijacking")
	}
	return hj.Hijack()
}

// Flush forwards the buffer flush to the underlying writer.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// logRequests is a diagnostic wrapper around all HTTP/WS traffic. Each request
// is logged with its method, path, client address and response code. It is the
// only place where live phone connections are visible: a successful /ws
// handshake logs 101, an auth rejection logs 401.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rw := &statusWriter{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf("http %s %s from %s -> %d", r.Method, r.URL.Path, r.RemoteAddr, rw.code)
	})
}