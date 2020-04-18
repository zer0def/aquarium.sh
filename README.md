# Aquarium - highly-opinionated Linux-centric scaffold for local multi-node Kubernetes development

## Summary

Aquarium's design goal is to leverage Docker (using k3s/k3d) or LXD (using proper Kubernetes through Kubedee) to provide a comparatively lightweight scaffold for launching multi-node Kubernetes development environments on your local machine, while trying to address some of a pain points of doing so.

### Usage

```
aquarium - Linux-centric scaffold for local K8S development

Usage: aquarium.sh [options] <up|down>

Options:
  --no-*                              disable installation of selected component
                                      (choice from: kata, registry-proxy, monitoring, serverless, service-mesh, storage)
                                      (env: non-zero value on INSTALL_*)
  -N <name>, --name <name>            cluster name (default: k3s-default, env: CLUSTER_NAME)
  -n <num>, --num <num>               number of workers (default: nproc/4, env: NUM_WORKERS)
  -r <runtime>, --runtime <runtime>   runtime choice (default: k3d, env: K8S_RUNTIME)
                                      (choice of: k3d, kubedee)
  -t <tag>, --tag <tag>               runtime version (env: RUNTIME_TAG)
```

### Project status

Highly bug-riddled alpha, YMMV. You probably should skim through, before using. You have been warned.

### Project rationale

#### Resource usage

Other solutions targeted for Kubernetes development (taking Minikube & friends as an example) can be resource-taxing due to hypervisor overhead, which this avoids through usage of OCI/system containers. For Windows and MacOS X users, in terms of memory, that potentially means packing more into their Hyper-V/xhyve Docker VM or WSL-based VM, than Minikube or Docker-packaged Kubernetes might, though at possible cost of added CPU overhead, since those are still hypervised.

#### Don't fight your tools when you don't need to

Even with constant various improvements in upstream projects, over the years there has been a number of barely-addressed crippling corner cases, solutions to some of which have rotten away in experimental branches before eventually getting upstreamed after everyone has abandoned them by virtue of not wanting to endlessly fight the tools they need.

#### Emulate your target environment without development/cloud-specific cruft

There's also an issue of developing (and, perhaps more importantly, adequately testing) Kubernetes manifests for things like solution resilience or scalability, which you cannot properly do on a single-node environment without making development-specific additions/exceptions to your manifests. This allows you to focus on your goal, not how to make it work within artificial constraints, most of the time.

## Dependencies

Binaries/scripts (but not OCI images or Helm charts) listed below are expected to be in your system's `PATH`.

### Hard dependencies

- Docker
- kubectl
- [Helm](https://github.com/helm/helm)
- [Helmfile](https://github.com/roboll/helmfile)
- either of:
    - [k3d](https://github.com/rancher/k3d) (and, by extension, [k3s](https://github.com/rancher/k3s))
    - [kubedee](https://github.com/schu/kubedee) (along with [cfssl](https://github.com/cloudflare/cfssl), [jq](https://github.com/stedolan/jq) and [lxd](https://github.com/lxc/lxd))

### Optional dependencies (enabled by default!)

- [docker-volume-loopback](https://github.com/ashald/docker-volume-loopback) (when Docker root is running on a filesystem not supporting overlays)
- [docker-registry-proxy](https://github.com/rpardini/docker-registry-proxy) (transparent proxy for caching OCI image layers)
- [Kata Containers](https://github.com/kata-containers/runtime) (along with QEMU, haven't gotten other hypervisors to work yet)

### Charts/software used, depending on component selection

Logical components are split into namespaces according to the following logic:

- storage:
    - [OpenEBS](https://github.com/openebs/openebs) in local volume provisioner mode
    - [MinIO](https://github.com/minio/minio) for object storage
    - [Patroni](https://github.com/zalando/patroni)/[Spilo](https://github.com/zalando/spilo) for PostgreSQL deployment
    - Redis
    - [Harbor](https://github.com/goharbor/harbor) for cluster-local registry
- network/service mesh: [Istio](https://github.com/istio/istio)
- monitoring: [Prometheus-Operator](https://github.com/coreos/prometheus-operator) with [Thanos](https://github.com/thanos-io/thanos)
- serverless: [Kubeless](https://github.com/kubeless/kubeless), possibly subject to change

## Known issues

- Kata Runtimes: while Firecracker and Cloud Hypervisor manifests exist, they might not work at this time
- Kubedee: Kata not deployed into worker system containers
- Kubedee: Registry proxy not deployed as an LXD container, making Docker a harder dependency than it genuinely needs to be
- cluster-wide pod security policies are just awful
- most likely inconsistent whitespace handling

## Legalese

Reality says "put it under WTFPL", but sure, let's try LGPL3.