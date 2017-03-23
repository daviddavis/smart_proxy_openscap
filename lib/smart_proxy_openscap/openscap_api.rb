#
# Copyright (c) 2014--2015 Red Hat Inc.
#
# This software is licensed to you under the GNU General Public License,
# version 3 (GPLv3). There is NO WARRANTY for this software, express or
# implied, including the implied warranties of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv3
# along with this software; if not, see http://www.gnu.org/licenses/gpl.txt
#
require 'smart_proxy_openscap/openscap_lib'

module Proxy::OpenSCAP
  HTTP_ERRORS = [
    EOFError,
    Errno::ECONNRESET,
    Errno::EINVAL,
    Net::HTTPBadResponse,
    Net::HTTPHeaderSyntaxError,
    Net::ProtocolError,
    Timeout::Error
  ]

  class Api < ::Sinatra::Base
    include ::Proxy::Log
    helpers ::Proxy::Helpers
    authorize_with_ssl_client

    post "/arf/:policy" do
      # first let's verify client's certificate
      begin
        cn = Proxy::OpenSCAP::common_name request
      rescue Proxy::Error::Unauthorized => e
        log_halt 403, "Client authentication failed: #{e.message}"
      end
      date = Time.now.to_i
      policy = params[:policy]

      begin
        post_to_foreman = ForemanForwarder.new.post_arf_report(cn, policy, date, request.body.string)
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, cn, post_to_foreman['id'], date)
          .store_archive(request.body.string)
      rescue Proxy::OpenSCAP::StoreReportError => e
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.failed_dir, cn, post_to_foreman['id'], date)
          .store_failed(request.body.string)
        logger.error "Failed to save Report in reports directory (#{Proxy::OpenSCAP::Plugin.settings.reportsdir}). Failed with: #{e.message}.
                      Saving file in #{Proxy::OpenSCAP::Plugin.settings.failed_dir}. Please copy manually to #{Proxy::OpenSCAP::Plugin.settings.reportsdir}"
      rescue *HTTP_ERRORS => e
        ### If the upload to foreman fails then store it in the spooldir
        logger.error "Failed to upload to Foreman, saving in spool. Failed with: #{e.message}"
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.spooldir, cn, policy, date)
          .store_spool(request.body.string)
      rescue Proxy::OpenSCAP::StoreSpoolError => e
        log_halt 500, e.message
      end
    end

    get "/arf/:id/:cname/:date/:digest/xml" do
      content_type 'application/x-bzip2'
      begin
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, params[:cname], params[:id], params[:date])
          .get_arf_xml(params[:digest])
      rescue FileNotFound => e
        log_halt 500, "Could not find requested file, #{e.message}"
      end
    end

    delete "/arf/:id/:cname/:date/:digest" do
      begin
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, params[:cname], params[:id], params[:date])
          .delete_arf_file
      rescue FileNotFound => e
        log_halt 500, "Could not find requested file, #{e.message}"
      end
    end

    get "/arf/:id/:cname/:date/:digest/html" do
      begin
        Proxy::OpenSCAP::StorageFS.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, params[:cname], params[:id], params[:date])
          .get_arf_html(params[:digest])
      rescue FileNotFound => e
        log_halt 500, "Could not find requested file, #{e.message}"
      end
    end

    get "/policies/:policy_id/content" do
      content_type 'application/xml'
      begin
        Proxy::OpenSCAP::FetchScapContent.new.get_policy_content(params[:policy_id])
      rescue *HTTP_ERRORS => e
        log_halt e.response.code.to_i, "File not found on Foreman. Wrong policy id?"
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    post "/scap_content/policies" do
      content_parser = create_content_parser
      begin
        content_parser.extract_policies
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      ensure
        content_parser.cleanup
      end
    end

    post "/scap_content/validator" do
      begin
        Proxy::OpenSCAP::ContentParser.new(request.body.string).validate
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    post "/scap_content/guide/:policy" do
      content_parser = create_content_parser
      begin
        content_parser.guide(params[:policy])
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      ensure
        content_parser.cleanup
      end
    end

    def create_content_parser
      Proxy::OpenSCAP::ContentParser.new(request.body.string)
    end
  end
end
