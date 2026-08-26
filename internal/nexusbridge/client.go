package nexusbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/uvwt/agentdock/internal/app"
	"github.com/uvwt/agentdock/internal/buildinfo"
	"github.com/uvwt/agentdock/internal/httpx"
	"github.com/uvwt/agentdock/internal/mcp"
)

const (
	protocolVersion = "1"
	maxMessageBytes = 8 << 20
)

type message struct {
	Type        string          `json:"type"`
	RequestID   string          `json:"request_id,omitempty"`
	Operation   string          `json:"operation,omitempty"`
	Arguments   json.RawMessage `json:"arguments,omitempty"`
	Result      any             `json:"result,omitempty"`
	Error       *remoteError    `json:"error,omitempty"`
	Hello       *hello          `json:"hello,omitempty"`
	Protocol    string          `json:"protocol_version,omitempty"`
	HeartbeatMS int             `json:"heartbeat_ms,omitempty"`
}

type hello struct {
	DeviceID         string           `json:"device_id"`
	Version          string           `json:"version"`
	ProtocolVersion  string           `json:"protocol_version"`
	OS               string           `json:"os"`
	Arch             string           `json:"arch"`
	Capabilities     []string         `json:"capabilities"`
	ToolContractHash string           `json:"tool_contract_hash"`
	Tools            []map[string]any `json:"tools"`
}

type remoteError struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	Category  string         `json:"category,omitempty"`
	Retryable bool           `json:"retryable,omitempty"`
	Details   map[string]any `json:"details,omitempty"`
}

type Client struct {
	identity Identity
	server   *mcp.Server
	state    *ConnectionState
	writeMu  sync.Mutex
	cancelMu sync.Mutex
	cancels  map[string]context.CancelFunc
}

func NewClient(identity Identity, server *mcp.Server, state *ConnectionState) *Client {
	return &Client{identity: identity, server: server, state: state, cancels: make(map[string]context.CancelFunc)}
}

func (c *Client) Run(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		err := c.connect(ctx)
		if ctx.Err() != nil {
			return
		}
		slog.Warn("NexusDock connection lost", "error", err, "retry_in", backoff)
		timer := time.NewTimer(backoff + time.Duration(rand.IntN(500))*time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func (c *Client) connect(ctx context.Context) error {
	c.state.SetConnected(false)
	endpoint, err := url.Parse(c.identity.Endpoint)
	if err != nil {
		return err
	}
	if endpoint.Scheme == "https" {
		endpoint.Scheme = "wss"
	} else {
		endpoint.Scheme = "ws"
	}
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + "/v1/nodes/connect"
	header := http.Header{"Authorization": []string{"Bearer " + c.identity.DeviceToken}}
	socket, response, err := websocket.DefaultDialer.DialContext(ctx, endpoint.String(), header)
	if err != nil {
		if response != nil {
			return fmt.Errorf("连接 NexusDock（HTTP %d）: %w", response.StatusCode, err)
		}
		return fmt.Errorf("连接 NexusDock: %w", err)
	}
	defer socket.Close()
	socket.SetReadLimit(maxMessageBytes)

	tools := c.server.ToolNames()
	if err := c.write(socket, message{Type: "node.hello", Protocol: protocolVersion, Hello: &hello{
		DeviceID: c.identity.DeviceID, Version: buildinfo.Version, ProtocolVersion: protocolVersion,
		OS: runtime.GOOS, Arch: runtime.GOARCH, Capabilities: tools, ToolContractHash: c.server.ToolContractHash(),
		Tools: c.server.ToolDescriptors(),
	}}); err != nil {
		return err
	}
	var ready message
	if err := socket.ReadJSON(&ready); err != nil {
		return fmt.Errorf("读取 NexusDock 握手响应: %w", err)
	}
	if ready.Type != "node.ready" || ready.Protocol != protocolVersion {
		return errors.New("NexusDock 返回了不兼容的节点协议")
	}
	c.state.SetConnected(true)
	defer c.state.SetConnected(false)
	slog.Info("NexusDock node connected", "node_id", c.identity.NodeID, "endpoint", c.identity.Endpoint)
	heartbeat := time.Duration(ready.HeartbeatMS) * time.Millisecond
	if heartbeat <= 0 {
		heartbeat = 30 * time.Second
	}
	connectionCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go c.heartbeat(connectionCtx, socket, heartbeat)
	for {
		var incoming message
		if err := socket.ReadJSON(&incoming); err != nil {
			return err
		}
		switch incoming.Type {
		case "tool.invoke":
			go c.invoke(connectionCtx, socket, incoming)
		case "tool.cancel":
			c.cancel(incoming.RequestID)
		case "node.heartbeat":
		}
	}
}

func (c *Client) invoke(parent context.Context, socket *websocket.Conn, incoming message) {
	ctx, cancel := context.WithCancel(parent)
	c.cancelMu.Lock()
	c.cancels[incoming.RequestID] = cancel
	c.cancelMu.Unlock()
	defer func() {
		cancel()
		c.cancelMu.Lock()
		delete(c.cancels, incoming.RequestID)
		c.cancelMu.Unlock()
	}()

	var result map[string]any
	var err error
	switch incoming.Operation {
	case "runtime.request":
		var request httpx.RuntimeBridgeRequest
		if decodeErr := json.Unmarshal(incoming.Arguments, &request); decodeErr != nil {
			err = fmt.Errorf("解析 Runtime 请求: %w", decodeErr)
		} else {
			result, err = httpx.DispatchRuntimeBridgeRequest(ctx, c.server, request)
		}
	case "tool.call":
		var request struct {
			Tool      string         `json:"tool"`
			Arguments map[string]any `json:"arguments"`
		}
		if decodeErr := json.Unmarshal(incoming.Arguments, &request); decodeErr != nil {
			err = fmt.Errorf("解析工具请求: %w", decodeErr)
		} else {
			result, err = c.server.Invoke(ctx, request.Tool, request.Arguments)
		}
	default:
		err = fmt.Errorf("不支持的 NexusDock 节点操作: %s", incoming.Operation)
	}
	if err != nil {
		_ = c.write(socket, message{Type: "tool.error", RequestID: incoming.RequestID, Error: bridgeError(err)})
		return
	}
	_ = c.write(socket, message{Type: "tool.result", RequestID: incoming.RequestID, Result: result})
}

func (c *Client) heartbeat(ctx context.Context, socket *websocket.Conn, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := c.write(socket, message{Type: "node.heartbeat"}); err != nil {
				_ = socket.Close()
				return
			}
		}
	}
}

func (c *Client) write(socket *websocket.Conn, outgoing message) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return socket.WriteJSON(outgoing)
}

func (c *Client) cancel(requestID string) {
	c.cancelMu.Lock()
	cancel := c.cancels[requestID]
	c.cancelMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func bridgeError(err error) *remoteError {
	converted := &remoteError{Code: "NODE_OPERATION_FAILED", Message: err.Error()}
	var toolErr *app.ToolError
	if errors.As(err, &toolErr) {
		converted.Code = toolErr.Code
		converted.Message = toolErr.Message
		converted.Category = toolErr.Category
		converted.Retryable = toolErr.Retryable
		converted.Details = toolErr.Details
	}
	return converted
}
