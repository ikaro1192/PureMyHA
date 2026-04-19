# HTTP API Reference

When `http.enabled: true` is set in the config, `puremyhad` exposes a lightweight read-only HTTP server for external health checks. All endpoints are `GET`-only; write operations remain Unix-socket-only.

## Endpoints

| Endpoint | Success | Failure | Use case |
|----------|---------|---------|----------|
| `GET /health` | `200 {"status":"ok"}` | — | Kubernetes liveness probe |
| `GET /cluster/:name/status` | `200 ClusterStatus JSON` | `404` if cluster not found | Readiness probe / LB routing |
| `GET /cluster/:name/topology` | `200 ClusterTopologyView JSON` | `404` if cluster not found | Monitoring dashboards |
| `GET /metrics` | `200` Prometheus text format | — | Grafana and other monitoring stacks |

`/health` returns `200` whenever the PureMyHA daemon is running and responsive. Use `/cluster/:name/status` to check individual cluster health.

`/metrics` exposes cluster health, replication lag, consecutive failures, and node role in Prometheus text exposition format.

## Examples

```bash
# Liveness probe
curl http://127.0.0.1:8080/health
# → {"status":"ok"}  (200)

# Cluster status — same JSON shape as `puremyha -j status`
curl http://127.0.0.1:8080/cluster/main/status | jq .
# → {"clusterName":"main","health":"Healthy","sourceHost":"db1","nodeCount":2,...}

# Topology — same JSON shape as `puremyha -j topology`
curl http://127.0.0.1:8080/cluster/main/topology | jq '.nodes[].host'
```

## Kubernetes Probe Example

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5

readinessProbe:
  httpGet:
    path: /cluster/main/status
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 3
```

## HAProxy Backend Check Example

```
backend mysql_source
    option httpchk GET /cluster/main/status
    server db1 db1:3306 check port 8080
    server db2 db2:3306 check port 8080
```

## Security headers

Every response (including `404` and `405`) carries the following headers as defence in depth against accidental browser access:

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Content-Type-Options` | `nosniff` | Disable MIME sniffing |
| `X-Frame-Options` | `DENY` | Block embedding in iframes (clickjacking) |
| `Cache-Control` | `no-store` | Keep responses out of intermediate caches |

These do not change the response body and are safe for `curl`, load balancers, Kubernetes probes, and Prometheus scrapers.

## Configuration

```yaml
http:
  enabled: true
  listen_address: "127.0.0.1"   # Use "0.0.0.0" to listen on all interfaces
  port: 8080
```
