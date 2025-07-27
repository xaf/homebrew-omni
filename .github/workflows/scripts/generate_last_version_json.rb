#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'optparse'
require 'uri'

owner = 'xaf'
repo = 'omni'
target_file = nil
legacy_file = nil
from_scratch = false

# Parse command line options
OptionParser.new do |option|
  option.banner = "Usage: #{File.basename(__FILE__)} [options]"

  option.on('-o', '--owner OWNER', 'GitHub repository owner (default: xaf)') { |o| owner = o }
  option.on('-r', '--repo REPO', 'GitHub repository name (default: omni)') { |r| repo = r }

  option.on('--write FILE', 'Write the output to a file') do |f|
    target_file = f
  end

  option.on('--legacy FILE', 'Write the output to a legacy file (for compatibility)') do |f|
    legacy_file = f
  end

  option.on('--[no-]from-scratch', 'Fetch all releases from scratch (default: false)') do |fs|
    from_scratch = fs
  end

  option.on_tail('-h', '--help', 'Show this message') do
    puts option
    exit
  end
end.parse!

def fetch(uri_str, allow_redirect = 5)
  raise RuntimeError, 'Too many redirects' unless allow_redirect > 0

  uri = URI.parse(uri_str)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')

  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'OmniVersionsFetcher/1.0'
  if uri.host == 'api.github.com'
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'

    token = ENV['GITHUB_TOKEN']
    token = ENV['GH_TOKEN'] if token.nil? || token.empty?
    request['Authorization'] = "Bearer #{token}" if token && !token.empty?
  end

  response = http.request(request)
  case response
  when Net::HTTPSuccess then
      response
  when Net::HTTPRedirection then
      fetch(response['location'], allow_redirect - 1)
  else
    response.error!
  end
end

# Initialize the versions data
versions_data = {}

# If we have a target file, let's read it to avoid fetching the same data again, unless we are fetching from scratch
if target_file && !from_scratch
  begin
    versions_data = JSON.parse(File.read(target_file))
  rescue Errno::ENOENT
    STDERR.puts "Target file #{target_file} does not exist, will skip reading it."
  rescue JSON::ParserError
    STDERR.puts "Error parsing JSON from target file, will skip reading it."
  end
end

# Consider we are doing from scratch if we do not have data
from_scratch = true if !from_scratch && versions_data.empty?

# Go through the releases
current_page = 0
might_have_more = true
while might_have_more
  current_page += 1
  response = fetch("https://api.github.com/repos/#{owner}/#{repo}/releases?per_page=100&page=#{current_page}")
  STDERR.puts "Fetching page #{current_page} of releases for #{owner}/#{repo}..."
  unless response.is_a?(Net::HTTPSuccess)
    puts "Error downloading releases: #{response.code} #{response.message}"
    exit(1)
  end

  # Parse the JSON
  releases = JSON.parse(response.body)
  unless releases.is_a?(Array)
    puts "Error parsing JSON response"
    exit(1)
  end

  STDERR.puts "Found #{releases.length} releases for #{owner}/#{repo} on page #{current_page}."

  might_have_more = releases.length == 100

  # Find the first release that already exists
  if !from_scratch && versions_data['versions']
    found = releases.find { |release| versions_data['versions'].include?(release['tag_name'].sub(/^v/, '')) }
    if found
      might_have_more = false
      releases = releases.take_while { |release| release['tag_name'] != found['tag_name'] }
    end
  end

  STDERR.puts "Found #{releases.length} new releases."

  # Prepare regex to parse name that should give us `omni-{version}-{target_arch}-{target_os}.(sha256|tar.gz)`
  bin_regex = Regexp.compile(/(?<asset>omni-(?<version>.*)-(?<arch>[^-]*)-(?<os>[^-]*))\.(?<type>sha256|tar.gz)/)

  # For each version, let's generate the data we need
  releases.each_with_object(versions_data) do |json, h|
    # Skip draft releases
    next if json['draft']

    STDERR.puts "Processing release: #{json['name']} (#{json['tag_name']})"

    # Get the tag name
    tag = json['tag_name']

    # Prepare the version
    version = tag
    version = version[1..-1] if version.start_with?('v')

    # Stop here if the version already exists in the data
    if h['versions'] && h['versions'].include?(version)
      STDERR.puts "Version #{version} already exists, stopping."
      break
    end

    # Get the release files
    binaries = {}
    json['assets'].each do |asset|
      match = bin_regex.match(asset['name'])
      next unless match

      binaries[match[:asset]] ||= {
        "os" => match[:os],
        "arch" => match[:arch]
      }

      if match[:type] == 'sha256'
        # Download the checksum file to get the checksum value
        checksum_response = fetch(asset['browser_download_url'])
        checksum = checksum_response.body.split(' ')[0]

        binaries[match[:asset]][match[:type]] = checksum
      else
        binaries[match[:asset]]['url'] = asset['browser_download_url']
      end
    end

    # Skip if no binary
    if binaries.empty?
      STDERR.puts "No binaries found for release #{json['name']} (#{tag}), skipping."
      next
    end

    # Get revision for the tag
    revision_response = fetch("https://api.github.com/repos/#{owner}/#{repo}/git/refs/tags/#{tag}")
    unless revision_response.is_a?(Net::HTTPSuccess)
      puts "Error downloading revision information: #{revision_response.code} #{revision_response.message}"
      exit(1)
    end

    revision_json = JSON.parse(revision_response.body)
    unless revision_json.is_a?(Hash)
      puts "Error parsing JSON response (tag)"
      exit(1)
    end

    # Get the revision
    revision = revision_json['object']['sha']

    # Prepare the result
    version_data = {
      "build" => {
        "tag" => tag,
        "revision" => revision,
      },
      "binaries" => binaries.values,
    }

    version_data['notes'] = json['body'] if json['body'] && !json['body'].empty?

    # Store the version data
    h['versions'] ||= []
    h['versions'] << version

    h['data'] ||= {}
    h['data'][version] = version_data
  end
end

# Write to target file
if target_file
  begin
    File.open(target_file, 'w') do |file|
      file.write(JSON.pretty_generate(versions_data))
    end
    STDERR.puts "Data written to #{target_file}"
  rescue => e
    STDERR.puts "Error writing to file: #{e.message}"
    exit(1)
  end
end

# Write to legacy file if specified
# This is for compatibility with older versions of the script
if legacy_file
  begin
    # The legacy data contains only the latest version
    latest_version = versions_data['versions'].first
    legacy_data = versions_data['data'][latest_version].dup
    legacy_data['version'] = latest_version
    File.open(legacy_file, 'w') do |file|
      file.write(JSON.pretty_generate(legacy_data))
    end
    STDERR.puts "Legacy data written to #{legacy_file}"
  rescue => e
    STDERR.puts "Error writing legacy file: #{e.message}"
    exit(1)
  end
end

# Print the result as JSON
puts JSON.pretty_generate(versions_data)
