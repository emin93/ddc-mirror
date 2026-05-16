class DdcMirror < Formula
  desc "Sync built-in MacBook brightness to external displays"
  homepage "https://ddc-mirror.emin.ch"
  url "https://github.com/emin93/ddc-mirror/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/emin93/ddc-mirror.git", branch: "main"

  depends_on :macos
  depends_on arch: :arm64

  def install
    system "make"
    bin.install "ddc-mirror"
  end

  service do
    run [opt_bin/"ddc-mirror"]
    keep_alive true
    log_path var/"log/ddc-mirror.log"
    error_log_path var/"log/ddc-mirror.log"
  end

  test do
    assert_match "Usage: ddc-mirror", shell_output("#{bin}/ddc-mirror --help")
  end
end
