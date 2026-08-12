package browser

import (
	"fmt"
	"testing"

	"github.com/chromedp/cdproto/network"
)

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

func TestDiagnosticsBoundsResponsesAndReleasesCompletedRequests(t *testing.T) {
	diagnostics := newDiagnostics()
	for index := 0; index < maxDiagnosticResponses+25; index++ {
		requestID := network.RequestID(fmt.Sprintf("request-%d", index))
		diagnostics.recordEvent(&network.EventRequestWillBeSent{
			RequestID: requestID,
			Request:   &network.Request{URL: fmt.Sprintf("https://example.test/%d", index), Method: "GET"},
		})
		diagnostics.recordEvent(&network.EventResponseReceived{
			RequestID: requestID,
			Response:  &network.Response{URL: fmt.Sprintf("https://example.test/%d", index), Status: 200},
		})
		diagnostics.recordEvent(&network.EventLoadingFinished{RequestID: requestID})
	}

	if got := len(diagnostics.responses); got != maxDiagnosticResponses {
		t.Fatalf("response history length = %d, want %d", got, maxDiagnosticResponses)
	}
	if len(diagnostics.requests) != 0 || len(diagnostics.responseByID) != 0 {
		t.Fatalf("completed request state leaked: requests=%d responses_by_id=%d", len(diagnostics.requests), len(diagnostics.responseByID))
	}
	if got := diagnostics.responses[0].URL; got != "https://example.test/25" {
		t.Fatalf("oldest retained response = %q, want newest bounded window", got)
	}
}
