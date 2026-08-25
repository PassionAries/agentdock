package desktopruntime

import "testing"

func TestFindQuickTunnelURL(t *testing.T) {
	tests := []struct {
		name string
		log  string
		want string
	}{
		{
			name: "cloudflared success output",
			log: "2026-08-25T02:35:41Z INF Requesting new quick Tunnel on trycloudflare.com...\n" +
				"2026-08-25T02:35:42Z INF Your quick Tunnel has been created! Visit it at:\n" +
				"https://serves-chemical-remains-shows.trycloudflare.com\n" +
				"2026-08-25T02:35:43Z INF Registered tunnel connection\n",
			want: "https://serves-chemical-remains-shows.trycloudflare.com",
		},
		{
			name: "success marker and url on same line",
			log:  "INF Your quick Tunnel has been created! Visit it at: https://same-line.trycloudflare.com\n",
			want: "https://same-line.trycloudflare.com",
		},
		{
			name: "issue 28 provisioning failure",
			log: "2026-08-25T02:35:41Z INF Requesting new quick Tunnel on trycloudflare.com...\n" +
				"failed to request quick Tunnel: Post \"https://api.trycloudflare.com/tunnel\": read tcp 192.168.1.8:64268->104.16.231.132:443: wsarecv: An existing connection was forcibly closed by the remote host.\n",
		},
		{
			name: "unrelated trycloudflare url before success marker",
			log: "diagnostic endpoint https://api.trycloudflare.com\n" +
				"INF Your quick Tunnel has been created! Visit it at:\n" +
				"https://actual-tunnel.trycloudflare.com\n",
			want: "https://actual-tunnel.trycloudflare.com",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := findQuickTunnelURL([]byte(tt.log)); got != tt.want {
				t.Fatalf("findQuickTunnelURL() = %q, want %q", got, tt.want)
			}
		})
	}
}
