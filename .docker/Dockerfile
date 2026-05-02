# Extends the upstream AVM azterraform image with PowerShell Core (pwsh).
# pwsh is present in the avm image (Dockerfile.avm) but not in azterraform;
# it is required by the pr-check porch config's pwsh command steps.
#
# porch is NOT reinstalled here — mcr.microsoft.com/azterraform:latest already ships
# v0.2.6 (per container/version.env in avm-terraform-governance).
#
# The resulting image is published to ghcr.io/kewalaka/azterraform:latest by the
# build-image.yml workflow and consumed by all CI workflows in this repository.

FROM mcr.microsoft.com/azterraform:latest

RUN tdnf install -y powershell && \
    tdnf clean all
