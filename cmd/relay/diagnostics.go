package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"net/http"
)

// statusWriter фиксирует код ответа, чтобы логгер мог его вывести после
// завершения обработки запроса. Обязан делегировать интерфейсы ResponseWriter,
// которые использует gorilla/websocket при апгрейде: без Hijack() WS-апгрейд
// падает с 500.
type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(code int) {
	w.code = code
	w.ResponseWriter.WriteHeader(code)
}

// Hijack передаёт управление соединением нижележащему writer'у — требует
// gorilla/websocket для апгрейда HTTP → WS.
func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("underlying ResponseWriter does not support hijacking")
	}
	return hj.Hijack()
}

// Flush передаёт сброс буфера нижележащему writer'у.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// logRequests — диагностическая обёртка над всем HTTP/WS-трафиком. Каждый
// запрос пишется в лог с методом, путём, адресом клиента и кодом ответа.
// Служит единственным местом, где видно живые подключения телефона:
// успешный handshake /ws даёт статус 101, отказ авторизации — 401.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rw := &statusWriter{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf("http %s %s from %s -> %d", r.Method, r.URL.Path, r.RemoteAddr, rw.code)
	})
}