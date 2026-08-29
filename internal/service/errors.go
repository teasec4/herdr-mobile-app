package service

import "errors"

var (
	// ErrInvalidTarget is returned when target agent ID is empty or invalid.
	ErrInvalidTarget = errors.New("invalid target agent ID")

	// ErrInvalidKeys is returned when keys array is empty.
	ErrInvalidKeys = errors.New("keys array cannot be empty")

	// ErrInvalidPrompt is returned when prompt text is empty.
	ErrInvalidPrompt = errors.New("prompt text cannot be empty")
)
