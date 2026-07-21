package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"openspeak/internal/filenode"
)

func main() {
	addr := env("OS_FILE_NODE_ADDR", ":27430")
	root := env("OS_FILE_NODE_ROOT", "/opt/openspeak-file-node/files")
	secret := os.Getenv("OS_FILE_NODE_SECRET")
	if secret == "" {
		log.Fatal("OS_FILE_NODE_SECRET is required")
	}
	server := &filenode.Server{Root: root, Secret: secret}
	go server.RunOrphanCleaner(context.Background(), time.Minute)
	log.Printf("OpenSpeak file node listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, server))
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
