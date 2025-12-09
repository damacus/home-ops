# =============================================================================
# Packer ARM Builder Image
# =============================================================================
# Pre-built image with all dependencies for creating ARM images using Packer.
# Based on mkaczanowski/packer-builder-arm with additional tools.
# =============================================================================

ARG PACKER_BUILDER_VERSION=latest
FROM mkaczanowski/packer-builder-arm:${PACKER_BUILDER_VERSION}

ARG TIMEZONE=Europe/London
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=${TIMEZONE}

RUN mkdir -p /workspace/provisioning/packer/builds
RUN ln -fs /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ansible \
        curl \
        nfs-common \
        qemu-user-static \
        xz-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/provisioning/packer
CMD ["/bin/bash"]
