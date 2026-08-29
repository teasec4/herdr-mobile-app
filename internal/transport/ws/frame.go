package ws

import "encoding/json"

// Frame represents the WebSocket protocol envelope.
type Frame struct {
	Type   string          `json:"type"`
	ID     interface{}     `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	OK     *bool           `json:"ok,omitempty"`
	Result interface{}     `json:"result,omitempty"`
	Error  *FrameError     `json:"error,omitempty"`
	Event  string          `json:"event,omitempty"`
	Data   interface{}     `json:"data,omitempty"`
}

// FrameError represents an error in a frame response.
type FrameError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// OKFrame creates a success response frame.
func OKFrame(id interface{}, result interface{}) Frame {
	ok := true
	return Frame{
		Type:   "response",
		ID:     id,
		OK:     &ok,
		Result: result,
	}
}

// ErrorFrame creates an error response frame.
func ErrorFrame(id interface{}, code, message string) Frame {
	return Frame{
		Type: "response",
		ID:   id,
		Error: &FrameError{
			Code:    code,
			Message: message,
		},
	}
}

// PongFrame creates a pong frame in response to ping.
func PongFrame() Frame {
	return Frame{Type: "pong"}
}

// EventFrame creates an event frame.
func EventFrame(event string, data interface{}) Frame {
	return Frame{
		Type:  "event",
		Event: event,
		Data:  data,
	}
}
