# Forgejo Buildah Runner

The in-cluster Forgejo runner is designed for workflows that can build
containers with Buildah or ko without a Docker daemon. It intentionally avoids
Docker-in-Docker and host socket mounts.

Buildah needs user namespace syscalls for rootless builds. The Kubernetes pod is
not privileged and does not mount host paths, but it uses an unconfined seccomp
profile so `buildah bud --storage-driver=vfs --isolation=chroot` can run.

Use the `buildah` runner label for Containerfile or Dockerfile builds:

```yaml
runs-on: buildah
steps:
  - uses: actions/checkout@v4
  - run: buildah bud --storage-driver=vfs --isolation=chroot -t "$IMAGE" .
  - run: buildah push "$IMAGE"
```

Go services can also use ko from a workflow if the repository installs or
vendors it:

```yaml
runs-on: buildah
steps:
  - uses: actions/checkout@v4
  - run: ko build ./cmd/app
```

Some third-party actions assume a Docker daemon. Those workflows should be
rewritten for Buildah/ko or run on a separate Docker-capable runner outside the
cluster.
