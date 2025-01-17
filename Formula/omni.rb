require "base64"
require "digest"
require "json"

OWNER = "xaf"
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
      # Verify signature of the tarball before proceeding
      verify_signature(cached_download)

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

  private

  def verify_signature(tarball_path)
    has_cosign = which("cosign")
    has_openssl = which("openssl")

    if !has_cosign && !has_openssl
      opoo "Neither cosign nor openssl found - skipping signature verification"
      return
    end

    ohai "Downloading keyless signature if available"

    sig_path = ("#{Dir.pwd}/keyless.sig").to_s
    cert_path = ("#{Dir.pwd}/keyless.pem").to_s

    sig_url = stable.url.sub(/\.tar\.gz$/, '') + "-keyless.sig"
    cert_url = stable.url.sub(/\.tar\.gz$/, '') + "-keyless.pem"

    if !download_if_exists(sig_url, sig_path) || !download_if_exists(cert_url, cert_path)
      opoo "Failed to download signature and certificate - skipping signature verification"
      return
    end

    tag = "v#{version}"
    cert_id_path = ".github/workflows/build-and-test-target.yaml@refs/tags/#{tag}"
    cert_id_reg = "^https://github.com/[xX]a[fF]/omni/#{cert_id_path}$"
    issuer = "https://token.actions.githubusercontent.com"

    # First try cosign if available
    if has_cosign
      ohai "Verifying signature and claims using Cosign"

      verify_sig = IO.popen([
        "cosign", "verify-blob",
        "--signature", sig_path,
        "--certificate", cert_path,
        "--certificate-oidc-issuer", issuer,
        "--certificate-identity-regexp", cert_id_reg,
        "--certificate-github-workflow-ref", "refs/tags/#{tag}",
        tarball_path,
      ], "r") { |f| f.read }

      if $?.success?
        ohai "Cosign signature verification succeeded"
        return
      end

      raise "Cosign signature verification failed"
    end

    # Fall back to OpenSSL if cosign isn't available or verification failed
    if has_openssl
      ohai "Verifying signature and claims using OpenSSL"

      decoded_cert = "#{Dir.pwd}/decoded.pem"
      decoded_sig = "#{Dir.pwd}/decoded.sig"
      pubkey = "#{Dir.pwd}/pubkey.pem"

      # Decode certificate, call command without using system
      File.write(decoded_cert, Base64.decode64(File.read(cert_path)))

      # Check OIDC claims
      oidc_claims = extract_oidc_claims(decoded_cert)
      raise "OIDC issuer claim does not match" unless oidc_claims["1"] == issuer
      raise "OIDC repository claim does not match" unless oidc_claims["5"] == "xaf/omni" || oidc_claims["5"] == "XaF/omni"
      raise "OIDC ref claim does not match" unless oidc_claims["6"] == "refs/tags/#{tag}"
      raise "OIDC identity claim does not match" unless Regexp.new(cert_id_reg).match?(oidc_claims["9"])

      # Extract public key
      File.open(pubkey, "w") do |f|
        # Execute openssl and redirect stdout to the file
        IO.popen([
          "openssl", "x509",
          "-pubkey", "-noout",
          "-in", decoded_cert,
        ], "r") do |openssl_output|
          # Write the output of the openssl command to the file
          f.write(openssl_output.read)
        end
      end

      # Decode signature
      File.write(decoded_sig, Base64.decode64(File.read(sig_path)))

      # Verify signature
      verify_sig = IO.popen([
        "openssl", "dgst", "-sha256",
        "-verify", pubkey,
        "-signature", decoded_sig,
        tarball_path,
      ], "r") { |f| f.read }

      if $?.success?
        ohai "OpenSSL signature verification succeeded"
        return true
      end

      raise "OpenSSL signature verification failed"
    end

    raise "No signature verification tool found, should be unreachable"
  end

  def extract_oidc_claims(cert_path)
    # OIDC claims are in the Certificate/Data/X509v3 extensions
    # They are in the shape `1.3.6.1.4.1.57264.1.x` where `x` is the claim number
    # The claims we care about are:
    #   (1) for the issuer
    #   (5) for the repository
    #   (6) for the ref
    #   (9) for the identity
    #
    # We need to call `openssl x509 -text -noout -in <cert>` and parse the output
    claims = {}
    claim_name = nil

    IO.popen([
      "openssl", "x509",
      "-text", "-noout",
      "-in", cert_path,
    ], "r") do |f|
      f.each_line do |line|
        line = line.strip
        if line.start_with?("1.3.6.1.4.1.57264.1.")
          # Remove the ending colon
          claim_name = line.gsub(/:$/, "").split(".").last
          # Verify that the claim name is a number
          claim_name = nil if claim_name !~ /^\d+$/
        elsif !claim_name.nil?
          # Remove any prefix in the claim value that's not a letter
          claims[claim_name] = line.gsub(/^[^a-zA-Z]+/, "")
          claim_name = nil
        end
      end
    end

    claims
  end

  def download_if_exists(url, target, redirect_limit: 10)
    require "net/http"
    require "uri"

    current_url = url
    referer = nil

    while redirect_limit > 0
      uri = URI(current_url)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "Homebrew"
        request["Accept"] = "*/*"
        request["Referer"] = referer unless referer.nil?

        response = http.request(request)

        case response
        when Net::HTTPSuccess
          File.write(target, response.body)
          return true
        when Net::HTTPFound, Net::HTTPMovedPermanently, Net::HTTPSeeOther, Net::HTTPTemporaryRedirect, Net::HTTPPermanentRedirect, Net::HTTPRedirection
          referer = current_url
          current_url = response['location']
          # Handle relative redirects
          unless current_url.start_with?('http')
            current_url = URI.join(url, current_url).to_s
          end
          redirect_limit -= 1
        else
          opoo "Failed to download #{url}: #{response.code} #{response.message}"
          return false
        end
      end
    end

    raise "Too many redirects"
  rescue StandardError => e
    opoo "Failed to download #{url}: #{e.message}"
    false
  end
end
