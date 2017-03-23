# encoding=utf-8
require 'openscap'
require 'openscap/ds/arf'
require 'openscap/xccdf/testresult'
require 'openscap/xccdf/ruleresult'
require 'openscap/xccdf/rule'
require 'openscap/xccdf/fix'
require 'openscap/xccdf/benchmark'
require 'json'
module Proxy::OpenSCAP
  class Parse
    def initialize(arf_data)
      OpenSCAP.oscap_init
      size         = arf_data.size
      @arf_digest  = Digest::SHA256.hexdigest(arf_data)
      @arf         = OpenSCAP::DS::Arf.new(:content => arf_data, :path => 'arf.xml.bz2', :length => size)
      @test_result  = @arf.test_result

      @results      = @test_result.rr
      @sds          = @arf.report_request
      bench_source = @sds.select_checklist!
      @benchmark    = OpenSCAP::Xccdf::Benchmark.new(bench_source)
      @items        = @benchmark.items
    end

    def cleanup
      @test_result.destroy if @test_result
      @benchmark.destroy if @benchmark
      @sds.destroy if @sds
      @arf.destroy if @arf
      OpenSCAP.oscap_cleanup
    end

    def as_json
      parse_report.to_json
    end

    private

    def parse_report
      report        = {}
      report[:logs] = []
      passed        = 0
      failed        = 0
      othered         = 0
      @results.each do |rr_id, result|
        next if result.result == 'notapplicable' || result.result == 'notselected'
        # get rules and their results
        rule_data = @items[rr_id]
        report[:logs] << populate_result_data(rr_id, result.result, rule_data)
        # create metrics for the results
        case result.result
          when 'pass', 'fixed'
            passed += 1
          when 'fail'
            failed += 1
          else
            othered += 1
        end
      end
      report[:digest]  = @arf_digest
      report[:metrics] = { :passed => passed, :failed => failed, :othered => othered }
      report
    end

    def populate_result_data(result_id, rule_result, rule_data)
      log               = {}
      log[:source]      = ascii8bit_to_utf8(result_id)
      log[:result]      = ascii8bit_to_utf8(rule_result)
      log[:title]       = ascii8bit_to_utf8(rule_data.title)
      log[:description] = ascii8bit_to_utf8(rule_data.description)
      log[:rationale]   = ascii8bit_to_utf8(rule_data.rationale)
      log[:references]  = hash_a8b(rule_data.references.map(&:to_hash))
      log[:fixes]       = hash_a8b(rule_data.fixes.map(&:to_hash))
      log[:severity]    = ascii8bit_to_utf8(rule_data.severity)
      log
    end

    # Unfortunately openscap in ruby 1.9.3 outputs data in Ascii-8bit.
    # We transform it to UTF-8 for easier json integration.

    # :invalid ::
    #   If the value is invalid, #encode replaces invalid byte sequences in
    #   +str+ with the replacement character.  The default is to raise the
    #   Encoding::InvalidByteSequenceError exception
    # :undef ::
    #   If the value is undefined, #encode replaces characters which are
    #   undefined in the destination encoding with the replacement character.
    #   The default is to raise the Encoding::UndefinedConversionError.
    # :replace ::
    #   Sets the replacement string to the given value. The default replacement
    #   string is "\uFFFD" for Unicode encoding forms, and "?" otherwise.
    def ascii8bit_to_utf8(string)
      string.to_s.encode('utf-8', :invalid => :replace, :undef => :replace, :replace => '_')
    end

    def hash_a8b(ary)
      ary.map do |hash|
        Hash[hash.map { |key, value| [ascii8bit_to_utf8(key), ascii8bit_to_utf8(value)] }]
      end
    end
  end
end
