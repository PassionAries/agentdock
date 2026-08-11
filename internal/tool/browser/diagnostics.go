package browser

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"github.com/chromedp/cdproto/log"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/page"
	cdpruntime "github.com/chromedp/cdproto/runtime"
	"github.com/chromedp/chromedp"
)

type responseRecord struct {
	URL    string
	Method string
	Status int
}

type requestRecord struct {
	URL    string
	Method string
}

type diagnostics struct {
	mu sync.Mutex

	consoleErrors []ConsoleError
	networkErrors []NetworkError
	pageErrors    []PageError
	responses     []responseRecord
	requests      map[network.RequestID]requestRecord
	responseWake  chan struct{}
}

func newDiagnostics() *diagnostics {
	return &diagnostics{requests: make(map[network.RequestID]requestRecord), responseWake: make(chan struct{}, 1)}
}

func (d *diagnostics) attach(ctx context.Context) {
	chromedp.ListenTarget(ctx, func(ev any) {
		d.mu.Lock()
		defer d.mu.Unlock()
		switch event := ev.(type) {
		case *network.EventRequestWillBeSent:
			if event.Request != nil {
				d.requests[event.RequestID] = requestRecord{URL: event.Request.URL, Method: event.Request.Method}
			}
		case *network.EventResponseReceived:
			if event.Response == nil {
				return
			}
			record := responseRecord{URL: event.Response.URL, Status: int(event.Response.Status)}
			if request, ok := d.requests[event.RequestID]; ok {
				record.Method = request.Method
			}
			d.responses = append(d.responses, record)
			select {
			case d.responseWake <- struct{}{}:
			default:
			}
		case *network.EventLoadingFailed:
			request := d.requests[event.RequestID]
			d.networkErrors = appendBoundedNetwork(d.networkErrors, NetworkError{URL: request.URL, Method: request.Method, ErrorText: event.ErrorText})
		case *cdpruntime.EventConsoleAPICalled:
			if strings.EqualFold(string(event.Type), "error") || strings.EqualFold(string(event.Type), "assert") {
				d.consoleErrors = appendBoundedConsole(d.consoleErrors, ConsoleError{Message: consoleMessage(event.Args)})
			}
		case *cdpruntime.EventExceptionThrown:
			message := "unhandled page exception"
			if event.ExceptionDetails != nil {
				message = strings.TrimSpace(event.ExceptionDetails.Text)
				if event.ExceptionDetails.Exception != nil && strings.TrimSpace(event.ExceptionDetails.Exception.Description) != "" {
					message = strings.TrimSpace(event.ExceptionDetails.Exception.Description)
				}
			}
			d.pageErrors = appendBoundedPage(d.pageErrors, PageError{Message: message})
		case *log.EventEntryAdded:
			if event.Entry != nil && strings.EqualFold(string(event.Entry.Level), "error") {
				d.consoleErrors = appendBoundedConsole(d.consoleErrors, ConsoleError{Message: strings.TrimSpace(event.Entry.Text)})
			}
		}
	})
}

func (d *diagnostics) enable(parent, pageCtx context.Context) error {
	return runWithContext(parent, pageCtx,
		network.Enable(),
		cdpruntime.Enable(),
		log.Enable(),
		page.Enable(),
		page.SetLifecycleEventsEnabled(true),
	)
}

func (d *diagnostics) snapshot() ([]ConsoleError, []NetworkError, []PageError) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]ConsoleError(nil), d.consoleErrors...), append([]NetworkError(nil), d.networkErrors...), append([]PageError(nil), d.pageErrors...)
}

func (d *diagnostics) hasMatchingResponse(action WaitResponseAction) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, response := range d.responses {
		if responseMatches(response, action) {
			return true
		}
	}
	return false
}

func consoleMessage(args []*cdpruntime.RemoteObject) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		if arg == nil {
			continue
		}
		text := strings.TrimSpace(arg.Description)
		if text == "" && len(arg.Value) != 0 {
			text = strings.TrimSpace(string(arg.Value))
		}
		if text != "" {
			parts = append(parts, text)
		}
	}
	if len(parts) == 0 {
		return "console error"
	}
	return strings.Join(parts, " ")
}

func appendBoundedConsole(values []ConsoleError, value ConsoleError) []ConsoleError {
	if strings.TrimSpace(value.Message) == "" {
		return values
	}
	if len(values) >= 50 {
		return values
	}
	return append(values, value)
}

func appendBoundedNetwork(values []NetworkError, value NetworkError) []NetworkError {
	if len(values) >= 50 {
		return values
	}
	return append(values, value)
}

func appendBoundedPage(values []PageError, value PageError) []PageError {
	if len(values) >= 50 {
		return values
	}
	return append(values, value)
}

func formatResponse(record responseRecord) string {
	return fmt.Sprintf("%s %d %s", record.Method, record.Status, record.URL)
}
