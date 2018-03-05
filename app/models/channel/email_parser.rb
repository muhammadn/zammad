# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

# encoding: utf-8

require 'mail'
require 'encode'

class Channel::EmailParser

=begin

  parser = Channel::EmailParser.new
  mail = parser.parse(msg_as_string)

  mail = {
    from:              'Some Name <some@example.com>',
    from_email:        'some@example.com',
    from_local:        'some',
    from_domain:       'example.com',
    from_display_name: 'Some Name',
    message_id:        'some_message_id@example.com',
    to:                'Some System <system@example.com>',
    cc:                'Somebody <somebody@example.com>',
    subject:           'some message subject',
    body:              'some message body',
    content_type:      'text/html', # text/plain
    date:              Time.zone.now,
    attachments:       [
      {
        data:        'binary of attachment',
        filename:    'file_name_of_attachment.txt',
        preferences: {
          'content-alternative' => true,
          'Mime-Type'           => 'text/plain',
          'Charset:             => 'iso-8859-1',
        },
      },
    ],

    # ignore email header
    x-zammad-ignore: 'false',

    # customer headers
    x-zammad-customer-login:     '',
    x-zammad-customer-email:     '',
    x-zammad-customer-firstname: '',
    x-zammad-customer-lastname:  '',

    # ticket headers (for new tickets)
    x-zammad-ticket-group:    'some_group',
    x-zammad-ticket-state:    'some_state',
    x-zammad-ticket-priority: 'some_priority',
    x-zammad-ticket-owner:    'some_owner_login',

    # ticket headers (for existing tickets)
    x-zammad-ticket-followup-group:    'some_group',
    x-zammad-ticket-followup-state:    'some_state',
    x-zammad-ticket-followup-priority: 'some_priority',
    x-zammad-ticket-followup-owner:    'some_owner_login',

    # article headers
    x-zammad-article-internal: false,
    x-zammad-article-type:     'agent',
    x-zammad-article-sender:   'customer',

    # all other email headers
    some-header: 'some_value',
  }

=end

  def parse(msg)
    data = {}
    mail = Mail.new(msg)

    # set all headers
    mail.header.fields.each do |field|

      # full line, encode, ready for storage
      begin
        value = Encode.conv('utf8', field.to_s)
        if value.blank?
          value = field.raw_value
        end
        data[field.name.to_s.downcase.to_sym] = value
      rescue => e
        data[field.name.to_s.downcase.to_sym] = field.raw_value
      end

      # if we need to access the lines by objects later again
      data["raw-#{field.name.downcase}".to_sym] = field
    end

    # verify content, ignore recipients with non email address
    ['to', 'cc', 'delivered-to', 'x-original-to', 'envelope-to'].each do |field|
      next if data[field.to_sym].blank?
      next if data[field.to_sym].match?(/@/)
      data[field.to_sym] = ''
    end

    # get sender with @ / email address
    from = nil
    ['from', 'reply-to', 'return-path'].each do |item|
      next if data[item.to_sym].blank?
      next if data[item.to_sym] !~ /@/
      from = data[item.to_sym]
      break if from
    end

    # in case of no sender with email address - get sender
    if !from
      ['from', 'reply-to', 'return-path'].each do |item|
        next if data[item.to_sym].blank?
        from = data[item.to_sym]
        break if from
      end
    end

    # set x-any-recipient
    data['x-any-recipient'.to_sym] = ''
    ['to', 'cc', 'delivered-to', 'x-original-to', 'envelope-to'].each do |item|
      next if data[item.to_sym].blank?
      if data['x-any-recipient'.to_sym] != ''
        data['x-any-recipient'.to_sym] += ', '
      end
      data['x-any-recipient'.to_sym] += mail[item.to_sym].to_s
    end

    # set extra headers
    data = data.merge(Channel::EmailParser.sender_properties(from))

    # do extra encoding (see issue#1045)
    if data[:subject].present?
      data[:subject].sub!(/^=\?us-ascii\?Q\?(.+)\?=$/, '\1')
    end

    # compat headers
    data[:message_id] = data['message-id'.to_sym]

    # body
    #    plain_part = mail.multipart? ? (mail.text_part ? mail.text_part.body.decoded : nil) : mail.body.decoded
    #    html_part = message.html_part ? message.html_part.body.decoded : nil
    data[:attachments] = []

    # multi part email
    if mail.multipart?

      # html attachment/body may exists and will be converted to strict html
      if mail.html_part&.body
        data[:body] = mail.html_part.body.to_s
        data[:body] = Encode.conv(mail.html_part.charset.to_s, data[:body])
        data[:body] = data[:body].html2html_strict.to_s.force_encoding('utf-8')

        if !data[:body].force_encoding('UTF-8').valid_encoding?
          data[:body] = data[:body].encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
        end
        data[:content_type] = 'text/html'
      end

      # text attachment/body exists
      if data[:body].blank? && mail.text_part
        data[:body] = mail.text_part.body.decoded
        data[:body] = Encode.conv(mail.text_part.charset, data[:body])
        data[:body] = data[:body].to_s.force_encoding('utf-8')

        if !data[:body].valid_encoding?
          data[:body] = data[:body].encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
        end
        data[:content_type] = 'text/plain'
      end

      # any other attachments
      if data[:body].blank?
        data[:body] = 'no visible content'
        data[:content_type] = 'text/plain'
      end

      # add html attachment/body as real attachment
      if mail.html_part
        filename = 'message.html'
        headers_store = {
          'content-alternative' => true,
        }
        if mail.mime_type
          headers_store['Mime-Type'] = mail.html_part.mime_type
        end
        if mail.charset
          headers_store['Charset'] = mail.html_part.charset
        end
        attachment = {
          data: mail.html_part.body.to_s,
          filename: mail.html_part.filename || filename,
          preferences: headers_store
        }
        data[:attachments].push attachment
      end

      # get attachments
      mail.parts&.each do |part|

        # protect process to work fine with spam emails, see test/fixtures/mail15.box
        begin
          attachs = _get_attachment(part, data[:attachments], mail)
          data[:attachments].concat(attachs)
        rescue
          attachs = _get_attachment(part, data[:attachments], mail)
          data[:attachments].concat(attachs)
        end
      end

    # not multipart email

    # html part only, convert to text and add it as attachment
    elsif mail.mime_type && mail.mime_type.to_s.casecmp('text/html').zero?
      filename = 'message.html'
      data[:body] = mail.body.decoded
      data[:body] = Encode.conv(mail.charset, data[:body])
      data[:body] = data[:body].html2html_strict.to_s.force_encoding('utf-8')

      if !data[:body].valid_encoding?
        data[:body] = data[:body].encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
      end
      data[:content_type] = 'text/html'

      # add body as attachment
      headers_store = {
        'content-alternative' => true,
      }
      if mail.mime_type
        headers_store['Mime-Type'] = mail.mime_type
      end
      if mail.charset
        headers_store['Charset'] = mail.charset
      end
      attachment = {
        data: mail.body.decoded,
        filename: mail.filename || filename,
        preferences: headers_store
      }
      data[:attachments].push attachment

    # text part only
    elsif !mail.mime_type || mail.mime_type.to_s == '' || mail.mime_type.to_s.casecmp('text/plain').zero?
      data[:body] = mail.body.decoded
      data[:body] = Encode.conv(mail.charset, data[:body])

      if !data[:body].force_encoding('UTF-8').valid_encoding?
        data[:body] = data[:body].encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
      end
      data[:content_type] = 'text/plain'
    else
      filename = '-no name-'
      data[:body] = 'no visible content'
      data[:content_type] = 'text/plain'

      # add body as attachment
      headers_store = {
        'content-alternative' => true,
      }
      if mail.mime_type
        headers_store['Mime-Type'] = mail.mime_type
      end
      if mail.charset
        headers_store['Charset'] = mail.charset
      end
      attachment = {
        data: mail.body.decoded,
        filename: mail.filename || filename,
        preferences: headers_store
      }
      data[:attachments].push attachment
    end

    # strip not wanted chars
    data[:body].gsub!(/\n\r/, "\n")
    data[:body].gsub!(/\r\n/, "\n")
    data[:body].tr!("\r", "\n")

    # get mail date
    begin
      if mail.date
        data[:date] = Time.zone.parse(mail.date.to_s)
      end
    rescue
      data[:date] = nil
    end

    # remember original mail instance
    data[:mail_instance] = mail

    data
  end

  def _get_attachment(file, attachments, mail)

    # check if sub parts are available
    if file.parts.present?
      list = []
      file.parts.each do |p|
        attachment = _get_attachment(p, attachments, mail)
        list.concat(attachment)
      end
      return list
    end

    # ignore text/plain attachments - already shown in view
    return [] if mail.text_part&.body.to_s == file.body.to_s

    # ignore text/html - html part, already shown in view
    return [] if mail.html_part&.body.to_s == file.body.to_s

    # get file preferences
    headers_store = {}
    file.header.fields.each do |field|

      # full line, encode, ready for storage
      begin
        value = Encode.conv('utf8', field.to_s)
        if value.blank?
          value = field.raw_value
        end
        headers_store[field.name.to_s] = value
      rescue => e
        headers_store[field.name.to_s] = field.raw_value
      end
    end

    # cleanup content id, <> will be added automatically later
    if headers_store['Content-ID']
      headers_store['Content-ID'].gsub!(/^</, '')
      headers_store['Content-ID'].gsub!(/>$/, '')
    end

    # get filename from content-disposition
    filename = nil

    # workaround for: NoMethodError: undefined method `filename' for #<Mail::UnstructuredField:0x007ff109e80678>
    begin
      filename = file.header[:content_disposition].filename
    rescue
      begin
        if file.header[:content_disposition].to_s =~ /filename="(.+?)"/i
          filename = $1
        elsif file.header[:content_disposition].to_s =~ /filename='(.+?)'/i
          filename = $1
        elsif file.header[:content_disposition].to_s =~ /filename=(.+?);/i
          filename = $1
        end
      rescue
        Rails.logger.debug 'Unable to get filename'
      end
    end

    # as fallback, use raw values
    if filename.blank?
      if headers_store['Content-Disposition'].to_s =~ /filename="(.+?)"/i
        filename = $1
      elsif headers_store['Content-Disposition'].to_s =~ /filename='(.+?)'/i
        filename = $1
      elsif headers_store['Content-Disposition'].to_s =~ /filename=(.+?);/i
        filename = $1
      end
    end

    # for some broken sm mail clients (X-MimeOLE: Produced By Microsoft Exchange V6.5)
    filename ||= file.header[:content_location].to_s

    # generate file name based on content-id
    if filename.blank? && headers_store['Content-ID'].present?
      if headers_store['Content-ID'] =~ /(.+?)@.+?/i
        filename = $1
      end
    end

    # generate file name based on content type
    if filename.blank? && headers_store['Content-Type'].present?
      if headers_store['Content-Type'].match?(%r{^message/rfc822}i)
        begin
          parser = Channel::EmailParser.new
          mail_local = parser.parse(file.body.to_s)
          filename = if mail_local[:subject].present?
                       "#{mail_local[:subject]}.eml"
                     elsif headers_store['Content-Description'].present?
                       "#{headers_store['Content-Description']}.eml".to_s.force_encoding('utf-8')
                     else
                       'Mail.eml'
                     end
        rescue
          filename = 'Mail.eml'
        end
      end

      # e. g. Content-Type: video/quicktime; name="Video.MOV";
      if filename.blank?
        ['name="(.+?)"(;|$)', "name='(.+?)'(;|$)", 'name=(.+?)(;|$)'].each do |regexp|
          if headers_store['Content-Type'] =~ /#{regexp}/i
            filename = $1
            break
          end
        end
      end

      # e. g. Content-Type: video/quicktime
      if filename.blank?
        map = {
          'message/delivery-status': ['txt', 'delivery-status'],
          'text/plain': %w[txt document],
          'text/html': %w[html document],
          'video/quicktime': %w[mov video],
          'image/jpeg': %w[jpg image],
          'image/jpg': %w[jpg image],
          'image/png': %w[png image],
          'image/gif': %w[gif image],
        }
        map.each do |type, ext|
          next if headers_store['Content-Type'] !~ /^#{Regexp.quote(type)}/i
          filename = if headers_store['Content-Description'].present?
                       "#{headers_store['Content-Description']}.#{ext[0]}".to_s.force_encoding('utf-8')
                     else
                       "#{ext[1]}.#{ext[0]}"
                     end
          break
        end
      end
    end

    if filename.blank?
      filename = 'file'
    end

    attachment_count = 0
    local_filename = ''
    local_extention = ''
    if filename =~ /^(.*?)\.(.+?)$/
      local_filename = $1
      local_extention = $2
    end

    (1..1000).each do |count|
      filename_exists = false
      attachments.each do |attachment|
        if attachment[:filename] == filename
          filename_exists = true
        end
      end
      break if filename_exists == false
      filename = if local_extention.present?
                   "#{local_filename}#{count}.#{local_extention}"
                 else
                   "#{local_filename}#{count}"
                 end
    end

    # get mime type
    if file.header[:content_type]&.string
      headers_store['Mime-Type'] = file.header[:content_type].string
    end

    # get charset
    if file.header&.charset
      headers_store['Charset'] = file.header.charset
    end

    # remove not needed header
    headers_store.delete('Content-Transfer-Encoding')
    headers_store.delete('Content-Disposition')

    # workaround for mail gem
    # https://github.com/zammad/zammad/issues/928
    filename = Mail::Encodings.value_decode(filename)

    attach = {
      data: file.body.to_s,
      filename: filename,
      preferences: headers_store,
    }
    [attach]
  end

=begin

  parser = Channel::EmailParser.new
  ticket, article, user, mail = parser.process(channel, email_raw_string)

returns

  [ticket, article, user, mail]

do not raise an exception - e. g. if used by scheduler

  parser = Channel::EmailParser.new
  ticket, article, user, mail = parser.process(channel, email_raw_string, false)

returns

  [ticket, article, user, mail] || false

=end

  def process(channel, msg, exception = true)

    _process(channel, msg)
  rescue => e
    # store unprocessable email for bug reporting
    path = Rails.root.join('tmp', 'unprocessable_mail')
    FileUtils.mkpath path
    md5 = Digest::MD5.hexdigest(msg)
    filename = "#{path}/#{md5}.eml"
    message = "ERROR: Can't process email, you will find it for bug reporting under #{filename}, please create an issue at https://github.com/zammad/zammad/issues"
    p message # rubocop:disable Rails/Output
    p 'ERROR: ' + e.inspect # rubocop:disable Rails/Output
    Rails.logger.error message
    Rails.logger.error e
    File.open(filename, 'wb') do |file|
      file.write msg
    end
    return false if exception == false
    raise e.inspect + "\n" + e.backtrace.join("\n")
  end

  def _process(channel, msg)

    # parse email
    mail = parse(msg)

    # run postmaster pre filter
    UserInfo.current_user_id = 1
    filters = {}
    Setting.where(area: 'Postmaster::PreFilter').order(:name).each do |setting|
      filters[setting.name] = Kernel.const_get(Setting.get(setting.name))
    end
    filters.each do |key, backend|
      Rails.logger.debug "run postmaster pre filter #{key}: #{backend}"
      begin
        backend.run(channel, mail)
      rescue => e
        Rails.logger.error "can't run postmaster pre filter #{key}: #{backend}"
        Rails.logger.error e.inspect
        raise e
      end
    end

    # check ignore header
    if mail['x-zammad-ignore'.to_sym] == 'true' || mail['x-zammad-ignore'.to_sym] == true
      Rails.logger.info "ignored email with msgid '#{mail[:message_id]}' from '#{mail[:from]}' because of x-zammad-ignore header"
      return
    end

    # set interface handle
    original_interface_handle = ApplicationHandleInfo.current

    ticket       = nil
    article      = nil
    session_user = nil

    # use transaction
    Transaction.execute(interface_handle: "#{original_interface_handle}.postmaster") do

      # get sender user
      session_user_id = mail['x-zammad-session-user-id'.to_sym]
      if !session_user_id
        raise 'No x-zammad-session-user-id, no sender set!'
      end
      session_user = User.lookup(id: session_user_id)
      if !session_user
        raise "No user found for x-zammad-session-user-id: #{session_user_id}!"
      end

      # set current user
      UserInfo.current_user_id = session_user.id

      # get ticket# based on email headers
      if mail['x-zammad-ticket-id'.to_sym]
        ticket = Ticket.find_by(id: mail['x-zammad-ticket-id'.to_sym])
      end
      if mail['x-zammad-ticket-number'.to_sym]
        ticket = Ticket.find_by(number: mail['x-zammad-ticket-number'.to_sym])
      end

      # set ticket state to open if not new
      if ticket
        set_attributes_by_x_headers(ticket, 'ticket', mail, 'followup')

        # save changes set by x-zammad-ticket-followup-* headers
        ticket.save! if ticket.has_changes_to_save?

        state      = Ticket::State.find(ticket.state_id)
        state_type = Ticket::StateType.find(state.state_type_id)

        # set ticket to open again or keep create state
        if !mail['x-zammad-ticket-followup-state'.to_sym] && !mail['x-zammad-ticket-followup-state_id'.to_sym]
          new_state = Ticket::State.find_by(default_create: true)
          if ticket.state_id != new_state.id && !mail['x-zammad-out-of-office'.to_sym]
            ticket.state = Ticket::State.find_by(default_follow_up: true)
            ticket.save!
          end
        end
      end

      # create new ticket
      if !ticket

        preferences = {}
        if channel[:id]
          preferences = {
            channel_id: channel[:id]
          }
        end

        # get default group where ticket is created
        group = nil
        if channel[:group_id]
          group = Group.lookup(id: channel[:group_id])
        end
        if group.blank? || group.active == false
          group = Group.where(active: true).order('id ASC').first
        end
        if group.blank?
          group = Group.first
        end
        title = mail[:subject]
        if title.blank?
          title = '-'
        end
        ticket = Ticket.new(
          group_id: group.id,
          title: title,
          preferences: preferences,
        )
        set_attributes_by_x_headers(ticket, 'ticket', mail)

        # create ticket
        ticket.save!
      end

      # set attributes
      ticket.with_lock do
        article = Ticket::Article.new(
          ticket_id: ticket.id,
          type_id: Ticket::Article::Type.find_by(name: 'email').id,
          sender_id: Ticket::Article::Sender.find_by(name: 'Customer').id,
          content_type: mail[:content_type],
          body: mail[:body],
          from: mail[:from],
          reply_to: mail[:"reply-to"],
          to: mail[:to],
          cc: mail[:cc],
          subject: mail[:subject],
          message_id: mail[:message_id],
          internal: false,
        )

        # x-headers lookup
        set_attributes_by_x_headers(article, 'article', mail)

        # create article
        article.save!

        # store mail plain
        article.save_as_raw(msg)

        # store attachments
        mail[:attachments]&.each do |attachment|
          filename = attachment[:filename].force_encoding('utf-8')
          if !filename.force_encoding('UTF-8').valid_encoding?
            filename = filename.encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
          end
          Store.add(
            object: 'Ticket::Article',
            o_id: article.id,
            data: attachment[:data],
            filename: filename,
            preferences: attachment[:preferences]
          )
        end
      end
    end

    # run postmaster post filter
    filters = {}
    Setting.where(area: 'Postmaster::PostFilter').order(:name).each do |setting|
      filters[setting.name] = Kernel.const_get(Setting.get(setting.name))
    end
    filters.each_value do |backend|
      Rails.logger.debug "run postmaster post filter #{backend}"
      begin
        backend.run(channel, mail, ticket, article, session_user)
      rescue => e
        Rails.logger.error "can't run postmaster post filter #{backend}"
        Rails.logger.error e.inspect
      end
    end

    # return new objects
    [ticket, article, session_user, mail]
  end

  def self.check_attributes_by_x_headers(header_name, value)
    class_name = nil
    attribute = nil
    if header_name =~ /^x-zammad-(.+?)-(followup-|)(.*)$/i
      class_name = $1
      attribute = $3
    end
    return true if !class_name
    if class_name.downcase == 'article'
      class_name = 'Ticket::Article'
    end
    return true if !attribute
    key_short = attribute[ attribute.length - 3, attribute.length ]
    return true if key_short != '_id'

    class_object = Object.const_get(class_name.to_classname)
    return if !class_object
    class_instance = class_object.new

    return false if !class_instance.association_id_validation(attribute, value)
    true
  end

  def self.sender_properties(from)
    data = {}
    return data if from.blank?
    begin
      list = Mail::AddressList.new(from)
      list.addresses.each do |address|
        data[:from_email] = address.address
        data[:from_local]        = address.local
        data[:from_domain]       = address.domain
        data[:from_display_name] = address.display_name ||
                                   (address.comments && address.comments[0])
        break if data[:from_email].present? && data[:from_email] =~ /@/
      end
    rescue => e
      if from =~ /<>/ && from =~ /<.+?>/
        data = sender_properties(from.gsub(/<>/, ''))
      end
    end

    if data.blank? || data[:from_email].blank?
      from.strip!
      if from =~ /^(.+?)<(.+?)@(.+?)>$/
        data[:from_email]        = "#{$2}@#{$3}"
        data[:from_local]        = $2
        data[:from_domain]       = $3
        data[:from_display_name] = $1
      else
        data[:from_email]  = from
        data[:from_local]  = from
        data[:from_domain] = from
      end
    end

    # do extra decoding because we needed to use field.value
    data[:from_display_name] = Mail::Field.new('X-From', Encode.conv('utf8', data[:from_display_name])).to_s
    data[:from_display_name].delete!('"')
    data[:from_display_name].strip!
    data[:from_display_name].gsub!(/^'/, '')
    data[:from_display_name].gsub!(/'$/, '')

    data
  end

  def set_attributes_by_x_headers(item_object, header_name, mail, suffix = false)

    # loop all x-zammad-header-* headers
    item_object.attributes.each_key do |key|

      # ignore read only attributes
      next if key == 'updated_by_id'
      next if key == 'created_by_id'

      # check if id exists
      key_short = key[ key.length - 3, key.length ]
      if key_short == '_id'
        key_short = key[ 0, key.length - 3 ]
        header = "x-zammad-#{header_name}-#{key_short}"
        if suffix
          header = "x-zammad-#{header_name}-#{suffix}-#{key_short}"
        end

        # only set value on _id if value/reference lookup exists
        if mail[ header.to_sym ]

          Rails.logger.info "set_attributes_by_x_headers header #{header} found #{mail[header.to_sym]}"
          item_object.class.reflect_on_all_associations.map do |assoc|

            next if assoc.name.to_s != key_short

            Rails.logger.info "set_attributes_by_x_headers found #{assoc.class_name} lookup for '#{mail[header.to_sym]}'"
            item = assoc.class_name.constantize

            assoc_object = nil
            if item.respond_to?(:name)
              assoc_object = item.lookup(name: mail[header.to_sym])
            end
            if !assoc_object && item.respond_to?(:login)
              assoc_object = item.lookup(login: mail[header.to_sym])
            end

            if assoc_object.blank?

              # no assoc exists, remove header
              mail.delete(header.to_sym)
              next
            end

            Rails.logger.info "set_attributes_by_x_headers assign #{item_object.class} #{key}=#{assoc_object.id}"

            item_object[key] = assoc_object.id

          end
        end
      end

      # check if attribute exists
      header = "x-zammad-#{header_name}-#{key}"
      if suffix
        header = "x-zammad-#{header_name}-#{suffix}-#{key}"
      end
      if mail[header.to_sym]
        Rails.logger.info "set_attributes_by_x_headers header #{header} found. Assign #{key}=#{mail[header.to_sym]}"
        item_object[key] = mail[header.to_sym]
      end
    end
  end

=begin

process unprocessable_mails (tmp/unprocessable_mail/*.eml) again

  Channel::EmailParser.process_unprocessable_mails

=end

  def self.process_unprocessable_mails(params = {})
    path = Rails.root.join('tmp', 'unprocessable_mail')
    files = []
    Dir.glob("#{path}/*.eml") do |entry|
      ticket, article, user, mail = Channel::EmailParser.new.process(params, IO.binread(entry))
      next if ticket.blank?
      files.push entry
      File.delete(entry)
    end
    files
  end

end

module Mail

  # workaround to get content of no parseable headers - in most cases with non 7 bit ascii signs
  class Field
    def raw_value
      value = Encode.conv('utf8', @raw_value)
      return value if value.blank?
      value.sub(/^.+?:(\s|)/, '')
    end
  end

  # workaround to parse subjects with 2 different encodings correctly (e. g. quoted-printable see test/fixtures/mail9.box)
  module Encodings
    def self.value_decode(str)
      # Optimization: If there's no encoded-words in the string, just return it
      return str unless str.index('=?')

      str = str.gsub(/\?=(\s*)=\?/, '?==?') # Remove whitespaces between 'encoded-word's

      # Split on white-space boundaries with capture, so we capture the white-space as well
      str.split(/([ \t])/).map do |text|
        if text.index('=?') .nil?
          text
        else
          # Join QP encoded-words that are adjacent to avoid decoding partial chars
          #          text.gsub!(/\?\=\=\?.+?\?[Qq]\?/m, '') if text =~ /\?==\?/

          # Search for occurences of quoted strings or plain strings
          text.scan(/(                                  # Group around entire regex to include it in matches
          \=\?[^?]+\?([QB])\?[^?]+?\?\=  # Quoted String with subgroup for encoding method
          |                                # or
          .+?(?=\=\?|$)                    # Plain String
          )/xmi).map do |matches|
            string, method = *matches
            if    method == 'b' || method == 'B' # rubocop:disable Style/MultipleComparison
              b_value_decode(string)
            elsif method == 'q' || method == 'Q' # rubocop:disable Style/MultipleComparison
              q_value_decode(string)
            else
              string
            end
          end
        end
      end.join('')
    end
  end

  # issue#348 - IMAP mail fetching stops because of broken spam email (e. g. broken Content-Transfer-Encoding value see test/fixtures/mail43.box)
  # https://github.com/zammad/zammad/issues/348
  class Body
    def decoded
      if !Encodings.defined?(encoding)
        #raise UnknownEncodingType, "Don't know how to decode #{encoding}, please call #encoded and decode it yourself."
        Rails.logger.info "UnknownEncodingType: Don't know how to decode #{encoding}!"
        raw_source
      else
        Encodings.get_encoding(encoding).decode(raw_source)
      end
    end
  end

end
