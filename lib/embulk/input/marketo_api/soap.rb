require "savon"

module Embulk
  module Input
    module MarketoApi
      class Soap
        attr_reader :endpoint, :wsdl, :user_id, :encryption_key

        def initialize(endpoint, wsdl, user_id, encryption_key)
          @endpoint = endpoint
          @wsdl = wsdl
          @user_id = user_id
          @encryption_key = encryption_key
        end

        def lead_metadata
          # http://developers.marketo.com/documentation/soap/describemobject/
          response = savon.call(:describe_m_object, message: {object_name: "LeadRecord"})
          response.body[:success_describe_m_object][:result][:metadata][:field_list][:field]
        end

        def each_lead(last_updated_at, &block)
          # http://developers.marketo.com/documentation/soap/getmultipleleads/

          last_updated_at = Time.parse(last_updated_at).iso8601
          request = {
            lead_selector: {
              oldest_updated_at: last_updated_at,
            },
            attributes!: {
              lead_selector: {"xsi:type" => "ns1:LastUpdateAtSelector"}
            },
            batch_size: 1000,
          }

          stream_position = fetch_leads(request, &block)

          while stream_position
            stream_position = fetch_leads(request.merge(stream_position: stream_position), &block)
          end
        end

        def activity_log_metadata(last_updated_at)
          request = {
            :start_position => {
              :oldest_created_at => last_updated_at
            },
            :batch_size => 1000,
          }

          records = []
          response = savon.call(:get_lead_changes, message: request)

          activities = response.body[:success_get_lead_changes][:result][:lead_change_record_list][:lead_change_record]
          activities.each do |activity|
            record = {
              id: activity[:id],
              activity_date_time: activity[:activity_date_time],
              activity_type: activity[:activity_type],
              mktg_asset_name: activity[:mktg_asset_name],
              mkt_person_id: activity[:mkt_person_id],
            }

            activity[:activity_attributes][:attribute].each do |attributes|
              name = attributes[:attr_name]
              value = attributes[:attr_value]

              record[name] = value
            end

            records << record
          end

          records
        end

        private

        def fetch_leads(request = {}, &block)
          response = savon.call(:get_multiple_leads, message: request)

          remaining = response.xpath('//remainingCount').text.to_i
          Embulk.logger.info "Remaining records: #{remaining}"
          response.xpath('//leadRecordList/leadRecord').each do |lead|
            record = {
              "id" => {type: :integer, value: lead.xpath('Id').text.to_i},
              "email" => {type: :string, value: lead.xpath('Email').text}
            }
            lead.xpath('leadAttributeList/attribute').each do |attr|
              name = attr.xpath('attrName').text
              type = attr.xpath('attrType').text
              value = attr.xpath('attrValue').text
              record = record.merge(
                name => {
                  type: type,
                  value: value
                }
              )
            end

            block.call(record)
          end

          if remaining > 0
            response.xpath('//newStreamPosition').text
          else
            nil
          end
        end

        def savon
          headers = {
            'ns1:AuthenticationHeader' => {
              "mktowsUserId" => user_id,
            }.merge(signature)
          }
          # NOTE: Do not memoize this to use always fresh signature (avoid 20016 error)
          # ref. https://jira.talendforge.org/secure/attachmentzip/unzip/167201/49761%5B1%5D/Marketo%20Enterprise%20API%202%200.pdf (41 page)
          Savon.client(
            log: true,
            logger: Embulk.logger,
            wsdl: wsdl,
            soap_header: headers,
            endpoint: endpoint,
            open_timeout: 90,
            read_timeout: 300,
            raise_errors: true,
            namespace_identifier: :ns1,
            env_namespace: 'SOAP-ENV'
          )
        end

        def signature
          timestamp = Time.now.to_s
          encryption_string = timestamp + user_id
          digest = OpenSSL::Digest.new('sha1')
          hashed_signature = OpenSSL::HMAC.hexdigest(digest, encryption_key, encryption_string)
          {
            'requestTimestamp' => timestamp,
            'requestSignature' => hashed_signature.to_s
          }
        end
      end
    end
  end
end
