// Temporary probe: publish an event to the daemon's events service using the
// repo's containerd v2 Go client.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/events"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"google.golang.org/protobuf/types/known/anypb"
)

func main() {
	sock := "/tmp/ctd-rootless/containerd.sock"
	if len(os.Args) > 1 {
		sock = os.Args[1]
	}
	ns := "default"
	if len(os.Args) > 2 {
		ns = os.Args[2]
	}
	client, err := containerd.New(sock, containerd.WithDefaultNamespace(ns))
	if err != nil {
		fmt.Printf("connect err: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()
	ctx := namespaces.WithNamespace(context.Background(), ns)

	payload, err := anypb.New(&events.TaskStart{ContainerID: "strim-smoke-probe"})
	if err != nil {
		fmt.Printf("anypb err: %v\n", err)
		os.Exit(1)
	}
	err = client.Publish(ctx, "/tasks/start", payload)
	if err != nil {
		fmt.Printf("publish err: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("published /tasks/start")
	time.Sleep(500 * time.Millisecond)
}