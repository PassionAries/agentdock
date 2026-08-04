//go:build windows

package desktopcontrol

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func endpointPath(runtimeRoot string) string {
	digest := sha256.Sum256([]byte(strings.ToLower(runtimeRoot)))
	return fmt.Sprintf(`\\.\pipe\agentdock-control-%x`, digest[:10])
}

func servePlatform(ctx context.Context, runtimeRoot string, handle func([]byte) []byte) error {
	security, err := currentUserPipeSecurity()
	if err != nil {
		return err
	}
	name, err := windows.UTF16PtrFromString(endpointPath(runtimeRoot))
	if err != nil {
		return err
	}
	for {
		pipe, err := windows.CreateNamedPipe(
			name,
			windows.PIPE_ACCESS_DUPLEX,
			windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT,
			windows.PIPE_UNLIMITED_INSTANCES,
			maxMessageBytes+4,
			maxMessageBytes+4,
			0,
			security,
		)
		if err != nil {
			return fmt.Errorf("create desktop control named pipe: %w", err)
		}
		connected := make(chan error, 1)
		go func() {
			connectErr := windows.ConnectNamedPipe(pipe, nil)
			if errors.Is(connectErr, windows.ERROR_PIPE_CONNECTED) {
				connectErr = nil
			}
			connected <- connectErr
		}()
		select {
		case <-ctx.Done():
			_ = windows.CloseHandle(pipe)
			<-connected
			return nil
		case connectErr := <-connected:
			if connectErr != nil {
				_ = windows.CloseHandle(pipe)
				return fmt.Errorf("connect desktop control named pipe: %w", connectErr)
			}
		}
		servePipe(pipe, handle)
	}
}

func servePipe(pipe windows.Handle, handle func([]byte) []byte) {
	defer windows.CloseHandle(pipe)
	defer windows.DisconnectNamedPipe(pipe)
	request, err := readPipeMessage(pipe)
	if err != nil {
		return
	}
	_ = writePipeMessage(pipe, handle(request))
	_ = windows.FlushFileBuffers(pipe)
}

func callPlatform(ctx context.Context, runtimeRoot string, data []byte) ([]byte, error) {
	name, err := windows.UTF16PtrFromString(endpointPath(runtimeRoot))
	if err != nil {
		return nil, err
	}
	deadline, hasDeadline := ctx.Deadline()
	if !hasDeadline {
		deadline = time.Now().Add(2 * time.Second)
	}
	var pipe windows.Handle
	for {
		pipe, err = windows.CreateFile(
			name,
			windows.GENERIC_READ|windows.GENERIC_WRITE,
			0,
			nil,
			windows.OPEN_EXISTING,
			0,
			0,
		)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) || time.Now().After(deadline) {
			return nil, fmt.Errorf("connect desktop control named pipe: %w", err)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
	defer windows.CloseHandle(pipe)
	if err := writePipeMessage(pipe, data); err != nil {
		return nil, fmt.Errorf("write desktop control named pipe: %w", err)
	}
	response, err := readPipeMessage(pipe)
	if err != nil {
		return nil, fmt.Errorf("read desktop control named pipe: %w", err)
	}
	return response, nil
}

func currentUserPipeSecurity() (*windows.SecurityAttributes, error) {
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return nil, fmt.Errorf("open current process token: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("read current user token: %w", err)
	}
	// 仅当前用户和 LocalSystem 可以访问控制管道，避免同机其他用户修改运行配置。
	descriptor, err := windows.SecurityDescriptorFromString(
		fmt.Sprintf("D:P(A;;GA;;;SY)(A;;GA;;;%s)", user.User.Sid.String()),
	)
	if err != nil {
		return nil, fmt.Errorf("create desktop control security descriptor: %w", err)
	}
	attributes := &windows.SecurityAttributes{
		SecurityDescriptor: descriptor,
		InheritHandle:      0,
	}
	attributes.Length = uint32(unsafe.Sizeof(*attributes))
	return attributes, nil
}

func writePipeMessage(pipe windows.Handle, data []byte) error {
	if len(data) > maxMessageBytes {
		return errors.New("desktop control message is too large")
	}
	buffer := make([]byte, 4+len(data))
	binary.LittleEndian.PutUint32(buffer[:4], uint32(len(data)))
	copy(buffer[4:], data)
	for len(buffer) > 0 {
		var written uint32
		if err := windows.WriteFile(pipe, buffer, &written, nil); err != nil {
			return err
		}
		if written == 0 {
			return io.ErrUnexpectedEOF
		}
		buffer = buffer[written:]
	}
	return nil
}

func readPipeMessage(pipe windows.Handle) ([]byte, error) {
	header := make([]byte, 4)
	if err := readPipeFull(pipe, header); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header)
	if size > maxMessageBytes {
		return nil, errors.New("desktop control message is too large")
	}
	data := make([]byte, size)
	if err := readPipeFull(pipe, data); err != nil {
		return nil, err
	}
	return data, nil
}

func readPipeFull(pipe windows.Handle, data []byte) error {
	for len(data) > 0 {
		var read uint32
		if err := windows.ReadFile(pipe, data, &read, nil); err != nil {
			return err
		}
		if read == 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[read:]
	}
	return nil
}
