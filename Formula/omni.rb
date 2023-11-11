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
      :branch => "main"

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
      # Try and get the version from git
      build_version = if build.head?
        dev_version = `git describe --tags --broken --dirty --match v* 2>/dev/null`.strip
        dev_version = "0.0.0-g{}".format(
          `git describe --tags --always --broken --dirty --match v*`.strip) if dev_version.blank?
        raise "Could not determine version" if dev_version.blank?
        dev_version.gsub(/^v/, "")
      else
        version
      end

      # Update Cargo.toml and Cargo.lock with the actual version
      inreplace "Cargo.toml", "0.0.0-git", build_version
      inreplace "Cargo.lock", "0.0.0-git", build_version

      system "cargo", "install", *std_cargo_args
    else
      bin.install "omni" => "omni"
    end
  end

  def caveats
    <<~EOS
      \x1B[1momni\x1B[0m depends on a shell integration to be fully functional. To enable it, you can add the following to your shell's configuration file:

        \x1B[96m eval "$(omni hook init bash)"   \x1B[90m# for bash\x1B[39m
        \x1B[96m eval "$(omni hook init zsh)"    \x1B[90m# for zsh\x1B[39m
        \x1B[96m omni hook init fish | source    \x1B[90m# for fish\x1B[39m

      Don't forget to restart your shell or run \x1B[96msource <path_to_rc_file>\x1B[39m for the changes to take effect.
    EOS
  end

  test do
    assert_match "omni version #{version}", shell_output("#{bin}/omni --version").strip
  end
end
