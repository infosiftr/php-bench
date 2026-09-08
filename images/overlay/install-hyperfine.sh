#!/bin/sh
# Always installs the same prebuilt hyperfine release from upstream,
# rather than whatever version each distro happens to package, so the
# --export-json schema and behavior are identical across every target
# regardless of OS/release.
set -eu

HF_VERSION=1.19.0

if command -v apt-get >/dev/null 2>&1; then
	apt-get update
	apt-get install -y --no-install-recommends curl ca-certificates tar
	rm -rf /var/lib/apt/lists/*
	case "$(dpkg --print-architecture)" in
		amd64) HF_ARCH=x86_64 ;;
		arm64) HF_ARCH=aarch64 ;;
		*) echo "unsupported architecture for hyperfine: $(dpkg --print-architecture)" >&2; exit 1 ;;
	esac
	LIBC=gnu
elif command -v apk >/dev/null 2>&1; then
	apk add --no-cache curl ca-certificates tar
	case "$(apk --print-arch)" in
		x86_64) HF_ARCH=x86_64 ;;
		aarch64) HF_ARCH=aarch64 ;;
		*) echo "unsupported architecture for hyperfine: $(apk --print-arch)" >&2; exit 1 ;;
	esac
	LIBC=musl
else
	echo "no supported package manager found" >&2
	exit 1
fi

URL="https://github.com/sharkdp/hyperfine/releases/download/v${HF_VERSION}/hyperfine-v${HF_VERSION}-${HF_ARCH}-unknown-linux-${LIBC}.tar.gz"
curl -fsSL "$URL" -o /tmp/hyperfine.tar.gz
mkdir -p /tmp/hyperfine
tar -xzf /tmp/hyperfine.tar.gz -C /tmp/hyperfine --strip-components=1
install -m 0755 /tmp/hyperfine/hyperfine /usr/local/bin/hyperfine
rm -rf /tmp/hyperfine /tmp/hyperfine.tar.gz
