//go:build !darwin

package desktopruntime

// DefaultRuntimeRoot 只由 macOS App 内置后台服务使用；其他平台继续要求调用方显式传入。
func DefaultRuntimeRoot() string { return "" }
