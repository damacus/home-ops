package main

import (
	"context"
	"os"

	"github.com/damacus/home-ops/internal/clusterhealth"
)

func main() {
	os.Exit(clusterhealth.RunCLI(context.Background(), os.Args[1:], os.Stdout, os.Stderr))
}
