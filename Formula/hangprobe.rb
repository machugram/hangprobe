# typed: false
# frozen_string_literal: true

class Hangprobe < Formula
  desc "See why a Mac, Simulator, or Android app stopped answering"
  homepage "https://github.com/machugram/hangprobe"
  license "MIT"
  head "https://github.com/machugram/hangprobe.git", branch: "main"

  # After tagging v0.1.0, uncomment and set sha256 from:
  #   curl -fsSL -o /tmp/hp.tgz https://github.com/machugram/hangprobe/archive/refs/tags/v0.1.0.tar.gz
  #   shasum -a 256 /tmp/hp.tgz
  # url "https://github.com/machugram/hangprobe/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 "…"
  # version "0.1.0"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "hangprobe"
    bin.install ".build/release/hangprobe"
  end

  test do
    assert_match "MIT", shell_output("#{bin}/hangprobe version")
  end
end
