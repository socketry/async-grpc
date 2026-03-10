package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/envoyproxy/go-control-plane/pkg/cache/v3"
	"github.com/envoyproxy/go-control-plane/pkg/cache/types"
	serverv3 "github.com/envoyproxy/go-control-plane/pkg/server/v3"
	"github.com/envoyproxy/go-control-plane/pkg/resource/v3"

	discovery "github.com/envoyproxy/go-control-plane/envoy/service/discovery/v3"
	clusterv3 "github.com/envoyproxy/go-control-plane/envoy/config/cluster/v3"
	endpointv3 "github.com/envoyproxy/go-control-plane/envoy/config/endpoint/v3"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
)

var (
	port     = flag.Int("port", 18000, "xDS server port")
	upstream = flag.String("upstream", "backend-1:50051,backend-2:50052,backend-3:50053", "Comma-separated list of upstream endpoints")
)

// Custom hash function that accepts any node ID for testing
type anyNodeHash struct{}

func (h *anyNodeHash) ID(node *corev3.Node) string {
	return "any"
}

func main() {
	flag.Parse()

	ctx := context.Background()

	// Create snapshot with cluster and endpoints
	snapshot, err := createSnapshot(*upstream)
	if err != nil {
		log.Fatalf("Failed to create snapshot: %v", err)
	}
	
	// For testing, accept any node ID by using a custom hash that always returns the same key
	// This allows any client to connect and get the same snapshot
	snapshotCache := cache.NewSnapshotCache(false, &anyNodeHash{}, nil)
	if err := snapshotCache.SetSnapshot(ctx, "any", snapshot); err != nil {
		log.Fatalf("Failed to set snapshot: %v", err)
	}
	log.Printf("Set snapshot for any node ID")

	// Create callbacks for logging
	callbacks := serverv3.CallbackFuncs{
		StreamOpenFunc: func(ctx context.Context, streamID int64, typeURL string) error {
			log.Printf("Stream opened: streamID=%d, typeURL=%s", streamID, typeURL)
			return nil
		},
		StreamRequestFunc: func(streamID int64, request *discovery.DiscoveryRequest) error {
			log.Printf("Stream request: streamID=%d, typeURL=%s, resource_names=%v", streamID, request.TypeUrl, request.ResourceNames)
			return nil
		},
	}
	
	// Create xDS server with callbacks
	srv := serverv3.NewServer(ctx, snapshotCache, callbacks)

	// Start gRPC server
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", *port))
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	// Create gRPC server with insecure credentials (for testing without TLS)
	grpcServer := grpc.NewServer(grpc.Creds(insecure.NewCredentials()))
	discovery.RegisterAggregatedDiscoveryServiceServer(grpcServer, srv)

	log.Printf("xDS test server listening on :%d", *port)
	log.Printf("Serving cluster 'myservice' with endpoints: %s", *upstream)
	
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}

func createSnapshot(upstreams string) (*cache.Snapshot, error) {
	// Parse upstream endpoints
	endpoints := parseEndpoints(upstreams)
	
	// Create cluster
	cluster := &clusterv3.Cluster{
		Name:                 "myservice",
		ClusterDiscoveryType: &clusterv3.Cluster_Type{Type: clusterv3.Cluster_EDS},
		LbPolicy:             clusterv3.Cluster_ROUND_ROBIN,
		EdsClusterConfig: &clusterv3.Cluster_EdsClusterConfig{
			ServiceName: "myservice",
			EdsConfig: &corev3.ConfigSource{
				ConfigSourceSpecifier: &corev3.ConfigSource_Ads{},
			},
		},
	}

	// Create endpoint assignment
	lbEndpoints := make([]*endpointv3.LbEndpoint, 0, len(endpoints))
	for _, ep := range endpoints {
		lbEndpoints = append(lbEndpoints, &endpointv3.LbEndpoint{
			HostIdentifier: &endpointv3.LbEndpoint_Endpoint{
				Endpoint: &endpointv3.Endpoint{
					Address: &corev3.Address{
						Address: &corev3.Address_SocketAddress{
							SocketAddress: &corev3.SocketAddress{
								Protocol: corev3.SocketAddress_TCP,
								Address:  ep.host,
								PortSpecifier: &corev3.SocketAddress_PortValue{
									PortValue: ep.port,
								},
							},
						},
					},
				},
			},
			HealthStatus: corev3.HealthStatus_HEALTHY,
		})
	}

	endpointAssignment := &endpointv3.ClusterLoadAssignment{
		ClusterName: "myservice",
		Endpoints: []*endpointv3.LocalityLbEndpoints{
			{
				LbEndpoints: lbEndpoints,
			},
		},
	}

	// Create snapshot
	// types.Resource is proto.Message, which Cluster and ClusterLoadAssignment implement
	return cache.NewSnapshot(
		"1", // version
		map[resource.Type][]types.Resource{
			resource.ClusterType:  {cluster},
			resource.EndpointType: {endpointAssignment},
		},
	)
}

type endpoint struct {
	host string
	port uint32
}

func parseEndpoints(upstreams string) []endpoint {
	var endpoints []endpoint
	parts := splitComma(upstreams)
	for _, part := range parts {
		host, port := parseHostPort(part)
		endpoints = append(endpoints, endpoint{host: host, port: port})
	}
	return endpoints
}

func splitComma(s string) []string {
	return strings.Split(s, ",")
}

func parseHostPort(addr string) (string, uint32) {
	parts := strings.Split(addr, ":")
	if len(parts) == 2 {
		var port uint32
		fmt.Sscanf(parts[1], "%d", &port)
		if port > 0 {
			return parts[0], port
		}
	}
	return addr, 50051
}
