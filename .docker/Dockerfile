# Extends the upstream AVM azterraform image with:
#   - porch v0.2.6  (upstream ships v0.0.10; current avm-terraform-governance porch
#                    configs require the parallel/serial command types added in v0.2.0)
#   - PowerShell Core (pwsh) — absent from the base image; required by the pr-check
#                              porch config's pwsh command steps
#
# The resulting image is published to ghcr.io/kewalaka/azterraform:latest by the
# build-image.yml workflow and consumed by all CI workflows in this repository.

FROM mcr.microsoft.com/azterraform:latest

ARG PORCH_VERSION=0.2.6
ARG PWSH_VERSION=7.4.15

# /usr/local/bin is earlier in PATH than /usr/local/go/bin (where the base image keeps
# porch), so placing the new binary here shadows the old one without patching the base.
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    mkdir /tmp/porch-install && \
    curl -fsSL \
      "https://github.com/matt-FFFFFF/porch/releases/download/v${PORCH_VERSION}/porch_${PORCH_VERSION}_linux_${ARCH}.tar.gz" \
      | tar xz -C /tmp/porch-install && \
    install -m 0755 /tmp/porch-install/porch /usr/local/bin/porch && \
    rm -rf /tmp/porch-install

# PowerShell ships as a self-contained .NET tarball; no package manager required.
RUN ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/') && \
    mkdir -p /usr/local/lib/powershell && \
    curl -fsSL \
      "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${ARCH}.tar.gz" \
      | tar xz -C /usr/local/lib/powershell && \
    chmod +x /usr/local/lib/powershell/pwsh && \
    ln -sf /usr/local/lib/powershell/pwsh /usr/local/bin/pwsh
