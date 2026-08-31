package main

import (
	"fmt"
	"os"

	"github.com/damacus/home-ops/internal/provisioning"
)

func main() {
	root, err := provisioning.FindRoot(".")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	os.Exit(provisioning.RunCLI(root, os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
