# frozen_string_literal: true

require "open3"
require "tempfile"

# Downloads a blob from Azure Blob Storage with the employee's Microsoft Entra
# sign-in, which the Azure CLI holds. Conservatory's formulae point at blobs in
# a container every employee can read through Entra RBAC, and use it with
# `url "...", using: EntraBlobDownloadStrategy`.
#
# It also stages an archive without changing into its lone top-level
# directory, so a formula's `bin.install` path is relative to the archive root,
# as an executable path is for Winget.
#
# These behaviours override Homebrew internals, checked against Homebrew 7.0.7
# (7.0.7-49-g012f02a). Recheck them when Homebrew changes these methods:
#   - CurlDownloadStrategy#fetch, #_curl_args, and #resolved_url_and_basename
#     (Library/Homebrew/download_strategy/curl_download_strategy.rb)
#   - AbstractDownloadStrategy#chdir
#     (Library/Homebrew/download_strategy/abstract_download_strategy.rb)
class EntraBlobDownloadStrategy < CurlDownloadStrategy
  # Lazy Dog Restaurants' Microsoft Entra tenant, so an Azure CLI signed in to
  # several tenants gets a token from this one.
  TENANT_ID = "9dc40017-026b-40ab-98be-7a43f88161e4"

  # Blob Storage needs x-ms-version 2017-11-09 or later with a bearer token.
  # This is the newest version Azure had fully deployed in October 2026.
  BLOB_SERVICE_VERSION = "2026-04-06"

  def initialize(url, name, version, **meta)
    meta[:headers] ||= []
    meta[:headers] << "x-ms-version: #{BLOB_SERVICE_VERSION}"
    super
  end

  # Overrides CurlDownloadStrategy#fetch to get the token when Homebrew
  # downloads, not when it loads the formula: loading happens for every
  # `brew info` or `brew outdated`, and since Homebrew 5.1.14 it hides
  # token-like environment variables. Every request #fetch makes carries the
  # token, including the HEAD request that checks a cached download is fresh.
  #
  # The `Authorization` header goes to curl in a file (`--header @file`, see
  # #_curl_args) that only this user can read and that's deleted afterwards,
  # so the token isn't in curl's command line, which `ps` and `brew --verbose`
  # show.
  def fetch(timeout: nil)
    token = azure_storage_token
    Tempfile.create(["entra-blob-download", ".headers"], HOMEBREW_TEMP) do |file|
      file.write("Authorization: Bearer #{token}\n")
      file.close
      @authorization_header_file = file.path
      super
    ensure
      @authorization_header_file = nil
    end
  end

  # Overrides CurlDownloadStrategy#_curl_args, which every curl call for this
  # download (the HEAD request and the download itself) starts with. Homebrew
  # drops the formula's `:headers` after a redirect to another host; curl
  # likewise doesn't send this custom `Authorization` header to another host.
  def _curl_args
    args = super
    args += ["--header", "@#{@authorization_header_file}"] if @authorization_header_file
    args
  end

  # Overrides AbstractDownloadStrategy#chdir, which Resource#unpack calls
  # (directly, or through AbstractDownloadStrategy#stage) after unpacking a
  # download into an empty directory. Homebrew's version changes into the
  # archive's lone top-level directory, if it has one; this one stays at the
  # archive root.
  def chdir
    raise "Empty archive" if Dir["*"].empty?

    yield
  end

  private

  # Overrides CurlDownloadStrategy#resolved_url_and_basename, which
  # AbstractFileDownloadStrategy#cached_location calls to name the cached file,
  # sometimes before #fetch. Homebrew's version asks the server for a
  # Content-Disposition file name, without the token, so Blob Storage would
  # refuse it; a blob's file name is the last segment of its URL.
  def resolved_url_and_basename(timeout: nil)
    [url, parse_basename(url)]
  end

  def azure_storage_token
    az = which("az", PATH.new(ORIGINAL_PATHS, HOMEBREW_PREFIX/"bin"))
    if az.nil?
      raise CurlDownloadStrategyError.new(url, <<~EOS.chomp)
        The Azure CLI (az) isn't installed, and it's needed to download #{name}.
        Install it with `brew install azure-cli`, run `az login`, then try again.
      EOS
    end

    stdout, stderr, status = Open3.capture3(
      az.to_s, "account", "get-access-token",
      "--resource", "https://storage.azure.com/",
      "--tenant", TENANT_ID,
      "--query", "accessToken",
      "--output", "tsv"
    )
    token = stdout.strip
    return token if status.success? && !token.empty?

    # The Azure CLI's last "ERROR:" line says why, for example "Please run 'az
    # login' to setup account."; an unexpected error adds a long traceback
    # after an "ERROR:" line that only announces it.
    reason = stderr.lines.reverse_each.find { |line| line.start_with?("ERROR: ") }&.delete_prefix("ERROR: ")&.strip
    raise CurlDownloadStrategyError.new(url, <<~EOS.chomp)
      The Azure CLI couldn't get a token to download #{name}#{": #{reason}" if reason.present?}
      Run `az login`, sign in with your Lazy Dog account, then try again.
    EOS
  end
end
