#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'optparse'
require 'uri'

owner = 'xaf'
repo = 'omni'
crate_name = 'omnicli'
target_file = nil
latest_file = nil
from_scratch = false

# Parse command line options
OptionParser.new do |option|
  option.banner = "Usage: #{File.basename(__FILE__)} [options]"

  option.on('-o', '--owner OWNER', "GitHub repository owner (default: #{owner})") { |o| owner = o }
  option.on('-r', '--repo REPO', "GitHub repository name (default: #{repo})") { |r| repo = r }

  option.on('--write FILE', 'Write all the releases to a file') do |f|
    target_file = f
  end

  option.on('--latest FILE', 'Write the latest release to a file (for compatibility)') do |f|
    latest_file = f
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

def parse_release_notes(markdown)
  return nil unless markdown && !markdown.strip.empty?

  notes = {
    features: [],
    fixes: [],
    breaking: [],
  }

  current_section = nil
  breaking_cause = false
  last_note = nil

  markdown.each_line do |line|
    line = line.rstrip

    # Detect emoji-labeled sections
    case line
    when /^###\s+:sparkles:/
      current_section = :features
    when /^###\s+:bug:/
      current_section = :fixes
    when /^###\s+:boom:/i, /^###\s+💥/
      current_section = :breaking
    when /^###/
      current_section = nil
    else
      next unless current_section

      # If the line corresponds to a commit or pull request
      if line =~ /^[-*]\s+(?:due to\s+)?(?:\[`(?<commit>[a-f0-9]+)`\]\((?<link>[^)]+)\)\s+-\s+)?(?:\*\*(?<scope>[^*]+)\*\*:\s+)?(?<emoji>[\p{So}\p{Sk}]+)\s+(?<summary>.+?)(?:\*?\((?:PR #(?<pr>\d+)|commit)\s+by\s+@(?<author>.+?)\)\*?)?:?$/iu
        entry = {
          commit: Regexp.last_match[:commit],
          link: Regexp.last_match[:link],
          scope: Regexp.last_match[:scope],
          author: Regexp.last_match[:author],
          emoji: Regexp.last_match[:emoji],
          pr: Regexp.last_match[:pr].to_i,
          summary: Regexp.last_match[:summary].strip,
        }
        entry.reject! { |k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        notes[current_section] << entry

        # Prepare to read a breaking change cause
        breaking_cause = current_section == :breaking

        # Prepare to read an issue addressed by this change
        last_note = notes[current_section][-1]

      # If the line corresponds to an issue that was addressed
      elsif last_note && line =~ /^  -\s+:arrow_lower_right:\s+\*addresses issue #(?<issue>\d+) opened by @(?<author>.+)\*$/iu
        last_note[:issues] ||= []
        last_note[:issues] << Regexp.last_match[:issue].to_i

      # If the line corresponds to a breaking change cause
      elsif breaking_cause && current_section == :breaking && line.start_with?("  ")
        last_note[:cause] ||= ""
        last_note[:cause] += " " unless last_note[:cause].empty?
        last_note[:cause] += line.strip
      end
    end
  end

  notes.reject! { |_k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
  notes.empty? ? nil : notes
end

# Initialize the versions data
versions_data = []

# If we have a target file, let's read it to avoid fetching the same data again, unless we are fetching from scratch
if target_file && !from_scratch
  begin
    versions_data = JSON.parse(File.read(target_file))
    if versions_data.is_a?(Hash)
      save = versions_data.dup || {}
      versions_data = []
      for v in save['versions']
        new_val = {'version' => v}
        new_val.merge!(save['data'][v])
        versions_data.push(new_val)
      end
    end
    versions_data = [] unless versions_data.is_a?(Array)
  rescue Errno::ENOENT
    STDERR.puts "Target file #{target_file} does not exist, will skip reading it."
  rescue JSON::ParserError
    STDERR.puts "Error parsing JSON from target file, will skip reading it."
  end
end

# Consider we are doing from scratch if we do not have data
from_scratch = true if !from_scratch && versions_data.empty?

# Check the yanked releases
crate_versions = fetch("https://crates.io/api/v1/crates/#{crate_name}/versions")
unless crate_versions.is_a?(Net::HTTPSuccess)
  puts "Error downloading crate versions: #{crate_versions.code} #{crate_versions.message}"
  exit(1)
end
crate_versions_json = JSON.parse(crate_versions.body)
unless crate_versions_json.is_a?(Hash) && crate_versions_json['versions'].is_a?(Array)
  puts "Error parsing JSON response from crates.io"
  exit(1)
end
yanked_versions = crate_versions_json['versions'].select { |v| v['yanked'] }.map { |v| v['num'] }

# Filter out yanked versions from the existing versions
versions_data.reject! { |v| v['version'] && yanked_versions.include?(v['version']) }

# Go through the releases
current_page = 0
might_have_more = true
existing_versions = versions_data.map { |v| v['version'] }.compact.uniq
new_versions_data = []
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
  if !from_scratch && existing_versions.any?
    found = releases.find { |release| existing_versions.include?(release['tag_name'].sub(/^v/, '')) }
    if found
      might_have_more = false
      releases = releases.take_while { |release| release['tag_name'] != found['tag_name'] }
    end
  end

  STDERR.puts "Found #{releases.length} new releases."

  # Prepare regex to parse name that should give us `omni-{version}-{target_arch}-{target_os}.(sha256|tar.gz)`
  bin_regex = Regexp.compile(/(?<asset>omni-(?<version>.*)-(?<arch>[^-]*)-(?<os>[^-]*))\.(?<type>sha256|tar.gz)/)

  # For each version, let's generate the data we need
  releases.each_with_object(new_versions_data) do |json, a|
    # Skip draft releases
    next if json['draft']

    STDERR.puts "Processing release: #{json['name']} (#{json['tag_name']})"

    # Get the tag name
    tag = json['tag_name']

    # Prepare the version
    version = tag
    version = version[1..-1] if version.start_with?('v')

    # Stop here if the version already exists in the data
    if existing_versions.include?(version) || a.any? { |d| d['version'] == version }
      STDERR.puts "Version #{version} already exists, stopping."
      break
    end

    # Skip if the version is yanked
    if yanked_versions.include?(version)
      STDERR.puts "Version #{version} is yanked, skipping."
      next
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
      "version" => version,
      "published_at" => json['published_at'],
      "build" => {
        "tag" => tag,
        "revision" => revision,
      },
      "binaries" => binaries.values,
    }

    if json['body'] && !json['body'].empty?
      notes = parse_release_notes(json['body'])
      version_data['notes'] = notes if notes
    end

    # Store the version data
    a << version_data
  end
end

# Merge new data with existing data, if needed
if from_scratch
  versions_data = new_versions_data
elsif new_versions_data.any?
  # The new versions data should be added as a prefix to the
  # existing versions data; i.e. if existing is 3, 2, 1 and
  # new is 5, 4, it should become 5, 4, 3, 2, 1
  versions_data ||= []
  versions_data.unshift(*new_versions_data)
end

# Error out if the versions data is empty
die "No versions data found." if versions_data.nil? || versions_data.empty?

# Write to latest file if specified
# This is for compatibility with older versions of the script
if latest_file
  begin
    # The latest data contains only the latest version
    File.open(latest_file, 'w') do |file|
      file.write(JSON.pretty_generate(versions_data.first))
    end
    STDERR.puts "Latest data written to #{latest_file}"
  rescue => e
    STDERR.puts "Error writing latest file: #{e.message}"
    exit(1)
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
    STDERR.puts "Error writing file: #{e.message}"
    exit(1)
  end
else
  # Print the result as JSON
  puts JSON.pretty_generate(versions_data)
end
