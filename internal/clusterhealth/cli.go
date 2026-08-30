package clusterhealth

import (
	"context"
	"flag"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
)

type Options struct {
	Format                   string
	Verbose                  bool
	Raw                      bool
	Notify                   bool
	Timeout                  time.Duration
	Period                   string
	Top                      int
	SkipHTTP3                bool
	IncludeESPHomeCanary     bool
	ESPHomeWebSocketPath     string
	ESPHomeWebSocketContains string
}

var periodPattern = regexp.MustCompile(`^[1-9][0-9]*[smhdw]$`)

func RunCLI(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}
	for _, argument := range args[1:] {
		if argument == "--json" || strings.HasPrefix(argument, "--json=") {
			fmt.Fprintln(stderr, "--json was removed; use --format=ndjson")
			return 2
		}
		if argument == "--workers" || strings.HasPrefix(argument, "--workers=") {
			fmt.Fprintln(stderr, "--workers was removed; Task now composes checks deterministically")
			return 2
		}
	}

	command := args[0]
	options, ok := parseOptions(command, args[1:], stderr)
	if !ok {
		return 2
	}
	if options.Format != FormatText && options.Format != FormatNDJSON {
		fmt.Fprintf(stderr, "unsupported format %q; use text or ndjson\n", options.Format)
		return 2
	}
	if options.Timeout <= 0 {
		fmt.Fprintln(stderr, "timeout must be greater than zero")
		return 2
	}
	if options.Top <= 0 {
		fmt.Fprintln(stderr, "top must be greater than zero")
		return 2
	}
	if !periodPattern.MatchString(options.Period) {
		fmt.Fprintf(stderr, "invalid period %q; use a positive duration such as 1h or 30m\n", options.Period)
		return 2
	}

	checker := NewChecker(ExecRunner{Timeout: options.Timeout})
	results, known := checker.Run(ctx, command, options)
	if !known {
		fmt.Fprintf(stderr, "unknown check %q\n", command)
		printUsage(stderr)
		return 2
	}
	if err := WriteResults(stdout, results, options.Format, options.Verbose || options.Raw, checker.Now()); err != nil {
		fmt.Fprintf(stderr, "write report: %v\n", err)
		return 2
	}
	if options.Notify && AnyFailed(results) {
		if result := checker.Notify(ctx, results); result.ExitCode != 0 {
			fmt.Fprintf(stderr, "send notification: %s\n", outputMessage(result, "notification failed"))
		}
	}
	if AnyFailed(results) {
		return 1
	}
	return 0
}

func parseOptions(command string, args []string, stderr io.Writer) (Options, bool) {
	options := Options{
		Format:  FormatText,
		Timeout: 45 * time.Second,
		Period:  "1h",
		Top:     20,
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&options.Format, "format", options.Format, "output format: text or ndjson")
	flags.BoolVar(&options.Verbose, "verbose", false, "include evidence for healthy checks")
	flags.BoolVar(&options.Raw, "raw", false, "include full formatted evidence")
	flags.BoolVar(&options.Notify, "notify", false, "send a phone notification when checks fail")
	flags.DurationVar(&options.Timeout, "timeout", options.Timeout, "timeout for each subprocess")
	flags.StringVar(&options.Period, "period", options.Period, "Loki lookback period")
	flags.IntVar(&options.Top, "top", options.Top, "number of log producers to report")
	flags.BoolVar(&options.SkipHTTP3, "skip-http3", false, "skip informational HTTP/3 checks")
	flags.BoolVar(&options.IncludeESPHomeCanary, "include-esphome-canary", false, "include the ESPHome canary")
	flags.StringVar(&options.ESPHomeWebSocketPath, "esphome-websocket-path", "", "ESPHome canary WebSocket path")
	flags.StringVar(
		&options.ESPHomeWebSocketContains,
		"esphome-websocket-contains",
		"",
		"expected ESPHome WebSocket payload substring",
	)
	if err := flags.Parse(args); err != nil {
		return Options{}, false
	}
	if flags.NArg() != 0 {
		fmt.Fprintf(stderr, "unexpected arguments: %s\n", strings.Join(flags.Args(), " "))
		return Options{}, false
	}
	return options, true
}

func (c *Checker) Run(ctx context.Context, command string, options Options) ([]Result, bool) {
	switch command {
	case "nodes":
		return []Result{c.Nodes(ctx)}, true
	case "kube-vip":
		return []Result{c.KubeVIP(ctx)}, true
	case "cilium":
		return []Result{c.Cilium(ctx)}, true
	case "pods":
		return []Result{c.Pods(ctx)}, true
	case "deployments":
		return []Result{c.Deployments(ctx)}, true
	case "gitops-health":
		return []Result{c.GitOps(ctx)}, true
	case "external-secrets-health":
		return []Result{c.ExternalSecrets(ctx)}, true
	case "service-account-health":
		return []Result{c.ServiceAccounts(ctx)}, true
	case "cnpg-health":
		return []Result{c.CNPGClusters(ctx)}, true
	case "cnpg-backups":
		return []Result{c.CNPGBackups(ctx)}, true
	case "grafana-alerts":
		return []Result{c.GrafanaAlerts(ctx), c.Alertmanager(ctx)}, true
	case "edge-smoke":
		return []Result{c.EdgeSmoke(ctx, EdgeOptions{
			SkipHTTP3:                options.SkipHTTP3,
			IncludeESPHomeCanary:     options.IncludeESPHomeCanary,
			ESPHomeWebSocketPath:     options.ESPHomeWebSocketPath,
			ESPHomeWebSocketContains: options.ESPHomeWebSocketContains,
		})}, true
	case "log-noise":
		return []Result{c.LogNoise(ctx, options.Period, options.Top)}, true
	default:
		return nil, false
	}
}

func (c *Checker) Notify(ctx context.Context, results []Result) CommandOutput {
	failures := []string{}
	for _, result := range results {
		if result.Failed() {
			failures = append(failures, result.Name+": "+result.Summary)
		}
	}
	return c.Runner.Run(
		ctx,
		"scripts/notify",
		"--status", "failure",
		"--title", "Cluster health: action needed",
		"--message", strings.Join(failures, "; "),
	)
}

func printUsage(output io.Writer) {
	fmt.Fprintln(output, "usage: cluster-health <check> [options]")
	const checks = "checks: nodes, kube-vip, cilium, pods, deployments, " +
		"gitops-health, external-secrets-health, service-account-health, " +
		"cnpg-health, cnpg-backups, grafana-alerts, edge-smoke, log-noise"
	fmt.Fprintln(output, checks)
}
