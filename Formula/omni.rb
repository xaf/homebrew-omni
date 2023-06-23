require "json"
require "digest"

OWNER = "XaF"
REPO = "omni"

class Omni < Formula
  desc "Omnipotent dev tool"
  homepage "https://github.com/#{OWNER}/#{REPO}"

  # Load the information from the JSON, so we can easily
  # programmatically update the formula when a new version
  # is released, vs. having to manually update the formula
  @@json_file = File.expand_path(
    File.join(
      File.dirname(__FILE__),
      "resources",
      "omni.json",
    ),
  )
  json_data = File.open(@@json_file) { |f| JSON.parse(f.read) }

  # Load the version from the file
  odie "version is not set" if json_data["version"].blank?
  version json_data["version"]

  # Check for --build-from-source and --HEAD in a case-insensitive way
  argv = ARGV.map(&:downcase)
  if argv.include?('--build-from-source') || argv.include?('--head')
    ENV["HOMEBREW_BUILD_FROM_SOURCE"] = "1"
  end
  build_from_source = ENV["HOMEBREW_BUILD_FROM_SOURCE"] == "1"

  # Check if we have a binary for the current platform, so
  # we can avoid building from source if possible
  binary = if !build_from_source && json_data["binaries"]
    json_data["binaries"].find do |bin|
      (!bin.key?("os") || bin["os"] == OS.kernel_name.downcase) &&
        (!bin.key?("arch") || bin["arch"] == Hardware::CPU.arch.to_s)
    end
  end
  if binary
    @@requires_build = false
    url binary["url"]
    sha256 binary["sha256"]
  else
    @@requires_build = true
    if json_data["build"]["tag"] && json_data["build"]["revision"]
      url "https://github.com/#{OWNER}/#{REPO}.git",
        :using => :git,
        :tag => json_data["build"]['tag'],
        :revision => json_data["build"]["revision"]
    elsif json_data["build"]["url"] && json_data["build"]["sha256"]
      url json_data["build"]["url"]
      sha256 json_data["build"]["sha256"]
    else
      odie "No build revision or URL/SHA256 available"
    end

    head "https://github.com/#{OWNER}/#{REPO}.git",
      :using => :git,
      :branch => "rust"

    depends_on "rust" => :build
  end

  resource "omni-json" do
    url "file://#{@@json_file}?#{Digest::SHA256.file(@@json_file).hexdigest}"
    sha256 Digest::SHA256.file(@@json_file).hexdigest
  end

  def install
    resource("omni-json").stage do
      (prefix/".brew/resources").install "omni.json"
    end

    if @@requires_build
      # Update Cargo.toml and Cargo.lock with the actual version
      inreplace "Cargo.toml", "0.0.0-git", version
      inreplace "Cargo.lock", "0.0.0-git", version

      system "cargo", "install", *std_cargo_args
    else
      bin.install "omni" => "omni"
    end
  end

  test do
    assert_match "omni version #{version}", shell_output("#{bin}/omni --version").strip
  end
end
