FROM mcr.microsoft.com/dotnet/samples:aspnetapp

# Patch OS packages to fix known CVEs (e.g. CVE-2026-22184 zlib)
USER root
RUN apk upgrade --no-cache
USER app
