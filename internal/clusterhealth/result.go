package clusterhealth

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"
)

type Status string

const (
	StatusPass Status = "pass"
	StatusFail Status = "fail"

	FormatText   = "text"
	FormatNDJSON = "ndjson"
)

type Result struct {
	Name    string   `json:"name"`
	Status  Status   `json:"status"`
	Summary string   `json:"summary"`
	Details []string `json:"details"`
}

func (r Result) Failed() bool {
	return r.Status == StatusFail
}

func NewResult(name string, failed bool, passSummary, failSummary string, details []string) Result {
	if details == nil {
		details = []string{}
	}
	if failed {
		return Result{Name: name, Status: StatusFail, Summary: failSummary, Details: details}
	}
	return Result{Name: name, Status: StatusPass, Summary: passSummary, Details: details}
}

func WriteResults(output io.Writer, results []Result, format string, fullEvidence bool, collectedAt time.Time) error {
	switch format {
	case FormatNDJSON:
		encoder := json.NewEncoder(output)
		encoder.SetEscapeHTML(false)
		for _, result := range results {
			if result.Details == nil {
				result.Details = []string{}
			}
			if err := encoder.Encode(result); err != nil {
				return fmt.Errorf("encode NDJSON: %w", err)
			}
		}
		return nil
	case FormatText:
		if collectedAt.IsZero() {
			collectedAt = time.Now().UTC()
		}
		if _, err := fmt.Fprintf(output, "Collected at %s\n\n", collectedAt.UTC().Format(time.RFC3339)); err != nil {
			return err
		}
		for _, result := range results {
			marker := strings.ToUpper(string(result.Status))
			if _, err := fmt.Fprintf(output, "[%s] %s: %s\n", marker, result.Name, result.Summary); err != nil {
				return err
			}
			if result.Failed() || fullEvidence {
				for _, detail := range result.Details {
					if _, err := fmt.Fprintf(output, "  - %s\n", detail); err != nil {
						return err
					}
				}
			}
			if _, err := fmt.Fprintln(output); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unsupported format %q; use text or ndjson", format)
	}
}

func AnyFailed(results []Result) bool {
	for _, result := range results {
		if result.Failed() {
			return true
		}
	}
	return false
}
