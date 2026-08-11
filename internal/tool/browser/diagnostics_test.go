package browser

import "testing"

func TestBenignAbortAfterNoBodyResponse(t *testing.T) {
	tests := []struct {
		name      string
		errorText string
		response  responseRecord
		want      bool
	}{
		{name: "204 fetch", errorText: "net::ERR_ABORTED", response: responseRecord{Method: "GET", Status: 204}, want: true},
		{name: "HEAD response", errorText: "net::ERR_ABORTED", response: responseRecord{Method: "HEAD", Status: 200}, want: true},
		{name: "normal response abort", errorText: "net::ERR_ABORTED", response: responseRecord{Method: "GET", Status: 200}, want: false},
		{name: "real network failure", errorText: "net::ERR_CONNECTION_RESET", response: responseRecord{Method: "GET", Status: 204}, want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := benignAbortAfterNoBodyResponse(test.errorText, test.response); got != test.want {
				t.Fatalf("benignAbortAfterNoBodyResponse() = %v, want %v", got, test.want)
			}
		})
	}
}
