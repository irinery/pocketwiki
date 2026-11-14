// Test-only host for the existing PocketKernel legacy HTTP adapter. It exposes
// no harness routes, so capability discovery receives a real 404.
package main

import (
    "fmt"
    "net"
    "net/http"
    "github.com/irinery/pocketkernel/kernel"
)

func main() {
    listener, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil { panic(err) }
    mux := http.NewServeMux()
    mux.Handle("/v1/kernel", kernel.NewHTTPAdapter(kernel.New(kernel.Dependencies{})))
    fmt.Println("LEGACY_READY", listener.Addr().String())
    if err := http.Serve(listener, mux); err != nil { panic(err) }
}
