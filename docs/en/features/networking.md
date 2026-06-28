# Networking and Routing

CLICD provides NAT4 port mapping, random available ports, public IPv4 assignment, IPv6 status checks, and IPv6 assignment. During container creation, you can use NAT only, public IPv4 only, IPv6 only, or a mixed network setup.

## NAT4

NAT4 forwards host ports to container internal ports. Common uses include:

- Forwarding SSH.
- Exposing web services.
- Assigning fixed external ports to sub-users.

Port mappings include:

| Field | Description |
| --- | --- |
| Name | A purpose label such as `ssh` or `web`. |
| Protocol | `tcp` or `udp`. |
| External port | The host port exposed to the outside. |
| Internal port | The service port inside the container. |

## IPv6

IPv6 assignment requires the host to have a routable IPv6 prefix, plus correct routing, neighbor discovery, or proxy configuration.

```http
GET /api/v1/ipv6/status
POST /api/v1/containers/{id}/ipv6
```

If the host has no public IPv6 or the upstream network is not routing the prefix correctly, assigned addresses will not be reachable from the public internet.

## Public IPv4

Public IPv4 assignment selects from public IPv4 addresses detected on the host, or from `public_ipv4s` specified through the API. Creation fields include:

| Field | Description |
| --- | --- |
| `assign_nat` | Whether to enable NAT port mappings. |
| `assign_ipv4` | Whether to assign public IPv4. |
| `ipv4_count` | Number of public IPv4 addresses to allocate automatically. |
| `public_ipv4s` | Explicit public IPv4 address list. |
| `assign_ipv6` | Whether to assign IPv6. |
| `ipv6_count` | Number of IPv6 addresses to allocate automatically. |
| `ipv6_addresses` | Explicit IPv6 address list. |

Public address pool APIs:

```http
GET /api/v1/routing
PUT /api/v1/routing
POST /api/v1/routing/ipv4-scan
```

## Routing Status

```http
GET /api/v1/routing
```

This endpoint shows runtime status for NAT, IPv4, IPv6, and port capacity.
