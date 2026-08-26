package nexusbridge

import "sync/atomic"

// ConnectionState 只记录当前节点桥接是否已完成 NexusDock 握手。
// 配置是否存在由启动配置判断，避免把“已配对”和“已连接”混成同一个状态。
type ConnectionState struct {
	connected atomic.Bool
}

func (s *ConnectionState) SetConnected(connected bool) {
	s.connected.Store(connected)
}

func (s *ConnectionState) Connected() bool {
	return s.connected.Load()
}
