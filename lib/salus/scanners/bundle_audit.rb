require 'bundler/audit/cli'
require 'salus/scanners/base'

# BundlerAudit scanner to check for CVEs in Ruby gems.
# https://github.com/rubysec/bundler-audit

module Salus::Scanners
  class BundleAudit < Base
    class UnvalidGemVulnError < StandardError; end

    def run
      # Ensure the DB is up to date
      unless Bundler::Audit::Database.update!(quiet: true)
        report_error("Error updating the bundler-audit DB!")
        return
      end

      ignore = ignore_list
      scanner = Bundler::Audit::Scanner.new(@repository.path_to_repo)
      @vulns = []
      run_scanner(scanner, ignore)

      local_db_path = @config['local_db']
      if !local_db_path.nil?
        if !valid_local_db?(local_db_path)
          local_db_path_err = "Invalid BundleAudit local_db path #{local_db_path}"
          report_warn(:bundle_audit_local_db_misconfiguration, local_db_path_err)
        else
          local_db = Bundler::Audit::Database.new(local_db_path)
          local_db_scanner = Bundler::Audit::Scanner.new(@repository.path_to_repo,
                                                         'Gemfile.lock', local_db)
          run_scanner(local_db_scanner, ignore)
        end
      end

      report_info(:ignored_cves, ignore)
      report_info(:vulnerabilities, @vulns)

      @vulns.empty? ? report_success : report_failure
    end

    def run_scanner(scanner, ignore)
      scanner.scan(ignore: ignore) do |result|
        hash = serialize_vuln(result)
        @vulns.push(hash)

        # TODO: we should tabulate these vulnerabilities in the same way
        # that we tabulate CVEs for Node packages - see NodeAudit scanner.
        log(JSON.pretty_generate(hash))
      end
    end

    # local DB should have a gems dir inside, and each subdir in gems
    # should be named after the actual gem, with yml's inside, like
    # like https://github.com/rubysec/ruby-advisory-db/tree/master/gems
    def valid_local_db?(dir)
      return false if !File.directory?(dir)

      File.directory?(File.join(dir, 'gems'))
    end

    def should_run?
      @repository.gemfile_lock_present?
    end

    def version
      Gem.loaded_specs['bundler-audit'].version.to_s
    end

    def self.supported_languages
      ['ruby']
    end

    private

    def ignore_list
      # We are deprecating this.  This will pull the list of CVEs from the ignore setting.
      list = @config.fetch('ignore', [])

      # combine with the newer exception entry
      (fetch_exception_ids + list).uniq
    end

    def serialize_vuln(vuln)
      case vuln
      when Bundler::Audit::Results::InsecureSource
        {
          type: 'InsecureSource',
          source: vuln.source
        }
      when Bundler::Audit::Results::UnpatchedGem
        {
          type: 'UnpatchedGem',
          name: vuln.gem.name,
          version: vuln.gem.version.to_s,
          cve: vuln.advisory.id,
          url: vuln.advisory.url,
          advisory_title: vuln.advisory.title,
          description: vuln.advisory.description,
          cvss: vuln.advisory.cvss_v2,
          osvdb: vuln.advisory.osvdb,
          patched_versions: vuln.advisory.patched_versions.map(&:to_s),
          unaffected_versions: vuln.advisory.unaffected_versions.map(&:to_s)
        }
      else
        raise UnvalidGemVulnError, "BundleAudit Scanner received a #{result} from the " \
                                   "bundler/audit gem, which it doesn't know how to handle"
      end
    end
  end
end
