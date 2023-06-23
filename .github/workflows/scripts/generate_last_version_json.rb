#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'

owner = 'XaF'
repo = 'omni'

def fetch(uri_str, allow_redirect = 5)
  raise RuntimeError, 'Too many redirects' unless allow_redirect > 0

  url = URI.parse(uri_str)
  response = Net::HTTP.get_response(url)
  case response
  when Net::HTTPSuccess then
      response
  when Net::HTTPRedirection then
      fetch(response['location'], allow_redirect - 1)
  else
    response.error!
  end
end

# Get the latest release information
response = fetch("https://api.github.com/repos/#{owner}/#{repo}/releases/latest")
unless response.is_a?(Net::HTTPSuccess)
  puts "Error downloading latest release information: #{response.code} #{response.message}"
  exit(1)
end

# Parse the JSON
json = JSON.parse(response.body)
unless json.is_a?(Hash)
  puts "Error parsing JSON response"
  exit(1)
end

# Get the tag name
tag = json['tag_name']

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

# Prepare the version
version = tag
version = version[1..-1] if version.start_with?('v')

# Parse name that should give us `omni-{version}-{target_arch}-{target_os}.(sha256|tar.gz)`
bin_regex = Regexp.compile(/(?<asset>omni-#{version}-(?<arch>[^-]*)-(?<os>[^-]*))\.(?<type>sha256|tar.gz)/)

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

# Prepare the result
result = {
  "version" => version,
  "build" => {
    "tag" => tag,
    "revision" => revision,
  },
  "binaries" => binaries.values,
}

# Print the result as JSON
puts JSON.pretty_generate(result)
