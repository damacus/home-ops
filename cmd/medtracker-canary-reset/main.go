package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/damacus/home-ops/internal/medtrackercanary"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 19*time.Minute)
	defer cancel()
	c, err := medtrackercanary.Load(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	db, err := medtrackercanary.Connect(ctx, c)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close(context.Background())
	kube, err := medtrackercanary.InCluster(c.Image)
	if err != nil {
		log.Fatal(err)
	}
	kube.Pulse = db.Pulse
	if err := medtrackercanary.Run(ctx, c, db, kube, time.Now()); err != nil {
		log.Fatal(err)
	}
	log.Print("canary reset complete")
}
