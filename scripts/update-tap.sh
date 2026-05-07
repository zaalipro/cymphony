#!/usr/bin/env bash
# Updates the Homebrew tap (zaalipro/homebrew-cymphony) for a published Cymphony release.
#
# Usage:
#   ./scripts/update-tap.sh 1.3.0                  # operates on default tap path
#   TAP_DIR=~/code/homebrew-cymphony ./scripts/update-tap.sh 1.3.0
#
# Prerequisites:
#   - The release tag (vX.Y.Z) has been pushed and the GitHub release workflow has
#     finished publishing all four assets (cymphony_linux, cymphony_macos_arm,
#     cymphony_macos_intel, plus the source tarball).
#   - The tap repo is checked out locally; defaults to ~/dev/homebrew-cymphony.
#
# What it does:
#   1. Downloads each binary asset and the source tarball, computes SHA256.
#   2. Rewrites Formula/cymphony.rb (bundled) and Formula/cymphony-lite.rb (source).
#   3. Stops short of committing — review with `git diff` then commit + push manually.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>   (e.g. $0 1.3.0)" >&2
  exit 64
fi

VERSION="$1"
TAG="v${VERSION}"
REPO="zaalipro/cymphony"
TAP_DIR="${TAP_DIR:-$HOME/dev/homebrew-cymphony}"

if [[ ! -d "$TAP_DIR/Formula" ]]; then
  echo "TAP_DIR='$TAP_DIR' does not look like a Homebrew tap (missing Formula/)" >&2
  exit 1
fi

base="https://github.com/${REPO}/releases/download/${TAG}"
src_url="https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"

echo "Fetching SHA256s for ${TAG}..."

sha_for() {
  local url="$1"
  curl -fsSL "$url" | shasum -a 256 | awk '{print $1}'
}

linux_sha=$(sha_for "${base}/cymphony_linux")
macos_arm_sha=$(sha_for "${base}/cymphony_macos_arm")
macos_intel_sha=$(sha_for "${base}/cymphony_macos_intel")
src_sha=$(sha_for "$src_url")

echo "  linux:        $linux_sha"
echo "  macos_arm:    $macos_arm_sha"
echo "  macos_intel:  $macos_intel_sha"
echo "  src tarball:  $src_sha"

cat > "$TAP_DIR/Formula/cymphony.rb" <<EOF
class Cymphony < Formula
  desc "Autonomous coding agent orchestrator (self-contained, bundles Erlang/Elixir)"
  homepage "https://github.com/${REPO}"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "${base}/cymphony_macos_arm"
      sha256 "${macos_arm_sha}"
    end

    on_intel do
      url "${base}/cymphony_macos_intel"
      sha256 "${macos_intel_sha}"
    end
  end

  on_linux do
    on_intel do
      url "${base}/cymphony_linux"
      sha256 "${linux_sha}"
    end
  end

  conflicts_with "cymphony-lite", because: "both install bin/cymphony"

  def install
    binary = Dir["cymphony*"].find { |f| File.file?(f) }
    odie "cymphony binary not found in archive" unless binary
    bin.install binary => "cymphony"
  end

  test do
    assert_match "cymphony", shell_output("#{bin}/cymphony 2>&1", 1)
  end
end
EOF

cat > "$TAP_DIR/Formula/cymphony-lite.rb" <<EOF
class CymphonyLite < Formula
  desc "Autonomous coding agent orchestrator (uses system Elixir/Erlang)"
  homepage "https://github.com/${REPO}"
  url "${src_url}"
  sha256 "${src_sha}"
  license "Apache-2.0"
  head "https://github.com/${REPO}.git", branch: "main"

  depends_on "elixir"

  conflicts_with "cymphony", because: "both install bin/cymphony"

  def install
    erlang_prefix = Formula["erlang"].opt_prefix
    ENV.prepend_path "PATH", "#{erlang_prefix}/bin"

    system "mix", "local.hex", "--force"
    system "mix", "local.rebar", "--force"
    system "mix", "deps.get"
    system "mix", "escript.build"
    bin.install "bin/cymphony"

    # Patch shebang to use Homebrew's Erlang, not whatever is on user's PATH
    inreplace bin/"cymphony", "#! /usr/bin/env escript",
      "#!#{Formula["erlang"].opt_bin}/escript"
  end

  test do
    assert_match "cymphony", shell_output("#{bin}/cymphony 2>&1", 1)
  end
end
EOF

echo
echo "Updated $TAP_DIR/Formula/cymphony.rb and cymphony-lite.rb"
echo "Review with: (cd '$TAP_DIR' && git diff)"
echo "Then commit + push the tap."
